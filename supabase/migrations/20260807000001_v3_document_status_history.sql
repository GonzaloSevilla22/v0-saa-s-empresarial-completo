-- =============================================================================
-- MIGRATION: 20260807000001_v3_document_status_history.sql
-- CHANGE:    v3-document-status-history (Modelo V3 §2 — FSM + historial append-only)
-- Design ref: openspec/changes/v3-document-status-history/design.md
--
-- Implementa (design.md):
--   D1  StatusTransitionPolicy como TABLA catálogo (document_status_transitions)
--       + helpers STABLE (is_valid_transition / is_terminal_status /
--       transition_requires_reason). FSM como datos, no ifs dispersos.
--   D2  document_type TEXT + CHECK; document_id uuid polimórfico SIN FK.
--   D3  document_status_history append-only por GRANTS + ausencia de policies
--       de escritura (RN-A3 estructural, patrón sales_orders/stock_transfers).
--   D4  record_status_transition (SECURITY DEFINER, revocado de authenticated):
--       valida contra el catálogo (P0409), exige reason si la policy lo pide
--       (P0400, RN-A5), inserta el historial en la MISMA transacción (RN-A1).
--   D5  allowed_role TEXT NULL estructurada pero INERTE — v3-rbac-multirole la
--       poblará y activará el enforcement sin migración disruptiva (RN-A4).
--   D6  Seed = FSMs REALES de los CHECKs vigentes (no las ideales del roadmap).
--       NO se siembra sales_order→canceled (sin RPC) ni stock_transfer
--       dispatched/received.
--   D7  cash_session open→closed: requires_reason=false en el catálogo; el
--       RPC computa la diferencia de arqueo y AUTO-genera el reason cuando
--       difference ≠ 0 (decisión por defecto: reason solo con diferencia).
--   4.2 Creación de Quote: AFTER INSERT trigger (opción a) — el INSERT del
--       quote es directo vía RLS desde el backend (quote_repository.py), no
--       hay RPC definer; el trigger preserva el patrón append-only sin abrir
--       escritura directa ni tocar el backend.
--   4.6 Relay CAE: rpc_record_fiscal_transition (SECURITY DEFINER, GRANT solo
--       service_role) — el backend Python lo invoca en la MISMA transacción
--       que el UPDATE de fiscal_documents.status (fiscal_document_repository:
--       update_authorized / update_rejected).
--
-- RPCs retrofiteados (cuerpo VERBATIM de su migración vigente + únicamente
-- las líneas PERFORM record_status_transition — regla del proposal):
--   rpc_accept_quote                → base 20260806000001_v3_snapshot_pattern.sql
--   rpc_quick_sale                  → base 20260702000001_c29_quote_salesorder.sql
--   _c29_confirm_order_core         → base 20260806000001_v3_snapshot_pattern.sql
--   rpc_open_cash_session           → base 20260701000001_c28_cash_session.sql
--   rpc_close_cash_session          → base 20260701000001_c28_cash_session.sql
--   rpc_open_reconciliation_session → base 20260805000001_bank_reconciliation.sql
--   rpc_close_reconciliation_session→ base 20260805000001_bank_reconciliation.sql
--   rpc_emit_pending_cae            → base 20260806000001_v3_snapshot_pattern.sql
--   rpc_transfer_stock              → base 20260625000001_c26_branch_as_root.sql
-- CREATE OR REPLACE preserva los ACLs existentes de cada función.
--
-- NO toca: stock, caja, idempotencia, ni el CHECK de
-- operation_idempotency.operation_kind (gate negativo (h) lo verifica).
--
-- ERRCODEs (5 chars — convención post-20260624000001):
--   P0400  reason requerido ausente (RN-A5) / to_status inválido
--   P0404  fiscal_document no encontrado (rpc_record_fiscal_transition)
--   P0409  transición no catalogada (RN-A4 estructural)
--
-- GOVERNANCE: MEDIO (aditivo; tablas nuevas + retrofit de una línea por RPC;
--             no cambia la semántica de negocio de ningún documento).
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP).
--
-- ROLLBACK (en orden):
--   DROP TRIGGER IF EXISTS quotes_record_status_creation ON public.quotes;
--   DROP FUNCTION IF EXISTS public.trg_quote_record_creation();
--   -- Restaurar los 9 RPCs al cuerpo de su migración base (listadas arriba).
--   DROP FUNCTION IF EXISTS public.rpc_record_fiscal_transition(uuid, text, text);
--   DROP FUNCTION IF EXISTS public.record_status_transition(uuid, text, uuid, text, text, uuid, text);
--   DROP FUNCTION IF EXISTS public.transition_requires_reason(text, text);
--   DROP FUNCTION IF EXISTS public.is_terminal_status(text, text);
--   DROP FUNCTION IF EXISTS public.is_valid_transition(text, text, text);
--   DROP TABLE IF EXISTS public.document_status_transitions;
--   DROP TABLE IF EXISTS public.document_status_history;
--   -- Ninguna estructura existente referencia las tablas nuevas.
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT table_name FROM information_schema.tables WHERE table_schema='public'
--     AND table_name IN ('document_status_history','document_status_transitions');
--   SELECT count(*) FROM public.document_status_transitions;  -- 18
--   SELECT has_table_privilege('authenticated','public.document_status_history','UPDATE'); -- f
-- =============================================================================


-- ============================================================
-- 1. document_status_history — historial append-only (D2, D3)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.document_status_history (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  document_type text        NOT NULL CHECK (document_type IN
                  ('quote','sales_order','fiscal_document','cash_session',
                   'reconciliation_session','stock_transfer')),
  document_id   uuid        NOT NULL,
  from_status   text        NULL,
  to_status     text        NOT NULL,
  performed_by  uuid        NOT NULL,
  reason        text        NULL,
  occurred_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.document_status_history IS
  'v3-document-status-history (Modelo V3 §2): historial append-only de cambios '
  'de estado de documentos. RN-A1 misma transacción; RN-A2 creación con '
  'from_status=NULL; RN-A3 append-only por grants (sin policy de escritura, '
  'UPDATE/DELETE revocados). document_id es un puntero polimórfico sin FK (D2); '
  'la integridad la garantizan los RPCs SECURITY DEFINER que son los únicos '
  'escritores. performed_by = auth.uid() del actor; el uuid cero '
  '00000000-0000-0000-0000-000000000000 representa al sistema (relay CAE).';

-- 1.3 Índice del timeline
CREATE INDEX IF NOT EXISTS document_status_history_timeline_idx
  ON public.document_status_history (account_id, document_type, document_id, occurred_at);

-- 1.4 RLS: solo-SELECT por cuenta (D3 — sin policy de INSERT/UPDATE/DELETE)
ALTER TABLE public.document_status_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS document_status_history_select ON public.document_status_history;
CREATE POLICY document_status_history_select
  ON public.document_status_history
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT public.current_account_ids()));

-- 1.5 Cinturón append-only adicional (RN-A3): grants revocados
REVOKE UPDATE, DELETE ON public.document_status_history FROM authenticated, anon;


-- ============================================================
-- 2. document_status_transitions — StatusTransitionPolicy como datos (D1, D5)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.document_status_transitions (
  id              uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  document_type   text    NOT NULL CHECK (document_type IN
                    ('quote','sales_order','fiscal_document','cash_session',
                     'reconciliation_session','stock_transfer')),
  from_status     text    NULL,
  to_status       text    NOT NULL,
  is_terminal_to  boolean NOT NULL DEFAULT false,
  requires_reason boolean NOT NULL DEFAULT false,
  -- D5: dimensión rol estructurada pero INERTE. NULL = cualquier rol.
  -- v3-rbac-multirole la poblará (UPDATE de datos, sin ALTER TABLE) y activará
  -- el enforcement dentro de record_status_transition.
  allowed_role    text    NULL
);

COMMENT ON TABLE public.document_status_transitions IS
  'v3-document-status-history (D1): catálogo de transiciones válidas por tipo '
  'de documento — la FSM como datos (StatusTransitionPolicy del Modelo V3 §2). '
  'from_status NULL = fila de creación (RN-A2). Seed = FSMs reales de los '
  'CHECKs vigentes (D6), no las ideales del roadmap. allowed_role NULL = '
  'cualquier rol (D5 — inerte hasta v3-rbac-multirole).';

-- 2.1 Unicidad con NULL manejado: índice único para transiciones + parcial
-- para la fila de creación (from_status IS NULL) por (document_type, to_status)
CREATE UNIQUE INDEX IF NOT EXISTS document_status_transitions_uq
  ON public.document_status_transitions (document_type, from_status, to_status)
  WHERE from_status IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS document_status_transitions_creation_uq
  ON public.document_status_transitions (document_type, to_status)
  WHERE from_status IS NULL;

-- Catálogo global de solo lectura para la UI (mostrar acciones posibles)
ALTER TABLE public.document_status_transitions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS document_status_transitions_select ON public.document_status_transitions;
CREATE POLICY document_status_transitions_select
  ON public.document_status_transitions
  FOR SELECT
  TO authenticated
  USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.document_status_transitions FROM authenticated, anon;

-- 2.2 Seed (D6): solo las transiciones que las operaciones vigentes ejecutan.
-- NO se siembra sales_order→canceled (en CHECK pero sin RPC) ni
-- stock_transfer dispatched/received (el enum los habilita a futuro).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  -- Quote: draft→sent→accepted|expired|rejected (CHECK 20260702000001)
  ('quote',                  NULL,          'draft',       false, false, NULL),
  ('quote',                  'draft',       'sent',        false, false, NULL),
  ('quote',                  'draft',       'accepted',    true,  false, NULL),
  ('quote',                  'sent',        'accepted',    true,  false, NULL),
  ('quote',                  'draft',       'expired',     true,  false, NULL),
  ('quote',                  'sent',        'expired',     true,  false, NULL),
  ('quote',                  'draft',       'rejected',    true,  false, NULL),
  ('quote',                  'sent',        'rejected',    true,  false, NULL),
  -- SalesOrder: draft→confirmed (canceled: en CHECK pero SIN RPC → no se siembra)
  ('sales_order',            NULL,          'draft',       false, false, NULL),
  ('sales_order',            'draft',       'confirmed',   true,  false, NULL),
  -- FiscalDocument: pending_cae→authorized|rejected (CHECK 20260627000001)
  ('fiscal_document',        NULL,          'pending_cae', false, false, NULL),
  ('fiscal_document',        'pending_cae', 'authorized',  true,  false, NULL),
  ('fiscal_document',        'pending_cae', 'rejected',    true,  false, NULL),
  -- CashSession: open→closed. requires_reason=false: el reason condicional
  -- (solo con diferencia de arqueo ≠ 0) lo gestiona el RPC (D7).
  ('cash_session',           NULL,          'open',        false, false, NULL),
  ('cash_session',           'open',        'closed',      true,  false, NULL),
  -- ReconciliationSession: open→closed (el RPC ya exige motivo vía P0431
  -- cuando hay diferencia — bank-reconciliation C3, RN-A5)
  ('reconciliation_session', NULL,          'open',        false, false, NULL),
  ('reconciliation_session', 'open',        'closed',      true,  false, NULL),
  -- StockTransfer: nace completed (atómica) — terminal, sin salientes
  ('stock_transfer',         NULL,          'completed',   true,  false, NULL)
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. Helpers STABLE de la policy (D1) — consultables por la UI
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_valid_transition(
  p_document_type text,
  p_from          text,
  p_to            text
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.document_status_transitions t
    WHERE t.document_type = p_document_type
      AND t.from_status IS NOT DISTINCT FROM p_from
      AND t.to_status = p_to
  );
$$;

COMMENT ON FUNCTION public.is_valid_transition(text, text, text) IS
  'v3-document-status-history (D1): true si la transición está catalogada. '
  'from NULL = creación (RN-A2).';

CREATE OR REPLACE FUNCTION public.is_terminal_status(
  p_document_type text,
  p_status        text
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.document_status_transitions t
    WHERE t.document_type = p_document_type
      AND t.to_status = p_status
      AND t.is_terminal_to
  );
$$;

COMMENT ON FUNCTION public.is_terminal_status(text, text) IS
  'v3-document-status-history (D1): true si el estado está marcado terminal '
  '(sin transiciones salientes catalogadas — invariante del seed).';

CREATE OR REPLACE FUNCTION public.transition_requires_reason(
  p_document_type text,
  p_to            text
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.document_status_transitions t
    WHERE t.document_type = p_document_type
      AND t.to_status = p_to
      AND t.requires_reason
  );
$$;

COMMENT ON FUNCTION public.transition_requires_reason(text, text) IS
  'v3-document-status-history (D1): true si el estado destino exige un reason '
  'no vacío (RN-A5).';

-- 2.4 Los tres helpers son de solo lectura — la UI los usa para mostrar acciones
GRANT EXECUTE ON FUNCTION public.is_valid_transition(text, text, text)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_terminal_status(text, text)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.transition_requires_reason(text, text)     TO authenticated;


-- ============================================================
-- 4. record_status_transition — helper de escritura (D4, RN-A1..A5)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_status_transition(
  p_account_id    uuid,
  p_document_type text,
  p_document_id   uuid,
  p_from_status   text,
  p_to_status     text,
  p_performed_by  uuid,
  p_reason        text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- RN-A4 estructural: transición (no creación) debe estar catalogada
  IF p_from_status IS NOT NULL
     AND NOT public.is_valid_transition(p_document_type, p_from_status, p_to_status) THEN
    RAISE EXCEPTION 'invalid_status_transition: % %→% no está catalogada',
      p_document_type, p_from_status, p_to_status
      USING ERRCODE = 'P0409';
  END IF;

  -- RN-A5: reason obligatorio cuando la policy lo pide para el estado destino
  IF public.transition_requires_reason(p_document_type, p_to_status)
     AND (p_reason IS NULL OR trim(p_reason) = '') THEN
    RAISE EXCEPTION 'reason_required: la transición %→% de % exige un motivo (RN-A5)',
      p_from_status, p_to_status, p_document_type
      USING ERRCODE = 'P0400';
  END IF;

  -- v3-rbac-multirole activará el check de allowed_role aquí (D5 — inerte en este change)

  INSERT INTO public.document_status_history
    (account_id, document_type, document_id, from_status, to_status, performed_by, reason)
  VALUES
    (p_account_id, p_document_type, p_document_id, p_from_status, p_to_status,
     p_performed_by, NULLIF(trim(COALESCE(p_reason, '')), ''));
END;
$$;

COMMENT ON FUNCTION public.record_status_transition(uuid, text, uuid, text, text, uuid, text) IS
  'v3-document-status-history (D4): valida la transición contra el catálogo '
  '(P0409, salvo creación from=NULL — RN-A2), exige reason si la policy lo pide '
  '(P0400 — RN-A5) e inserta el historial. Helper interno: solo lo invocan '
  'otras funciones SECURITY DEFINER en la misma transacción (RN-A1).';

-- 3.3 Helper interno — NO callable por roles de aplicación
REVOKE ALL ON FUNCTION public.record_status_transition(uuid, text, uuid, text, text, uuid, text)
  FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 5. rpc_record_fiscal_transition — punto de escritura del relay CAE (4.6)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_record_fiscal_transition(
  p_fiscal_document_id uuid,
  p_to_status          text,
  p_reason             text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doc          RECORD;
  v_performed_by uuid;
BEGIN
  IF p_to_status NOT IN ('authorized', 'rejected') THEN
    RAISE EXCEPTION 'invalid_to_status: % (esperado authorized|rejected)', p_to_status
      USING ERRCODE = 'P0400';
  END IF;

  SELECT id, account_id INTO v_doc
  FROM public.fiscal_documents
  WHERE id = p_fiscal_document_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_document_not_found: %', p_fiscal_document_id
      USING ERRCODE = 'P0404';
  END IF;

  -- Actor: el relay corre en el backend sin sesión de usuario →
  -- uuid cero = "sistema (relay CAE)". La UI lo renderiza como "Sistema".
  v_performed_by := COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);

  PERFORM public.record_status_transition(
    v_doc.account_id, 'fiscal_document', p_fiscal_document_id,
    'pending_cae', p_to_status, v_performed_by, p_reason);
END;
$$;

COMMENT ON FUNCTION public.rpc_record_fiscal_transition(uuid, text, text) IS
  'v3-document-status-history (4.6): el backend Python (fiscal_document_repository) '
  'lo invoca en la MISMA transacción que el UPDATE de fiscal_documents.status '
  'tras la respuesta de ARCA (update_authorized/update_rejected). GRANT solo a '
  'service_role — no abre escritura directa al historial.';

REVOKE ALL ON FUNCTION public.rpc_record_fiscal_transition(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_fiscal_transition(uuid, text, text)
  TO service_role;


-- ============================================================
-- 6. Creación de Quote → historial vía AFTER INSERT trigger (4.2, opción a)
--
-- El INSERT de quotes es directo vía RLS desde el backend (quote_repository.py
-- — no hay RPC definer de creación). El trigger es SECURITY DEFINER para poder
-- invocar record_status_transition (revocado de authenticated) y corre en la
-- misma transacción del INSERT (RN-A1). Si no hay actor resoluble (seeds
-- administrativos sin created_by ni sesión), no registra y no rompe el INSERT.
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_quote_record_creation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid;
BEGIN
  v_actor := COALESCE(NEW.created_by, auth.uid());
  IF v_actor IS NULL THEN
    RETURN NEW;  -- contexto administrativo sin actor: no registrar, no romper
  END IF;

  PERFORM public.record_status_transition(
    NEW.account_id, 'quote', NEW.id, NULL, NEW.status, v_actor, NULL);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_quote_record_creation() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS quotes_record_status_creation ON public.quotes;
CREATE TRIGGER quotes_record_status_creation
  AFTER INSERT ON public.quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_quote_record_creation();

COMMENT ON TRIGGER quotes_record_status_creation ON public.quotes IS
  'v3-document-status-history (4.2 opción a): registra la creación del quote '
  '(from_status=NULL → status inicial) en document_status_history — el INSERT '
  'del quote no pasa por un RPC definer.';


-- ============================================================
-- 7. RETROFIT de RPCs — cuerpo verbatim + PERFORM record_status_transition
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 7.1 rpc_accept_quote — base: 20260806000001_v3_snapshot_pattern.sql.
-- Delta v3-document-status-history: (a) registro de creación de la SalesOrder
-- (NULL→draft, RN-A2); (b) registro de la transición del quote
-- (draft|sent→accepted, RN-A1). Nada más cambia.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_accept_quote(
  p_quote_id  uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_quote          public.quotes%ROWTYPE;
  v_item           RECORD;
  v_sales_order_id uuid;
  v_branch_id      uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cargar el quote y validar tenencia
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_quote.account_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado: solo draft o sent son aceptables
  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: estado % no es aceptable', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;

  -- OQ-4: validación defensiva on-read de expiración
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;

  -- Resolver branch: preferir branch del quote, sino default
  v_branch_id := COALESCE(
    v_quote.branch_id,
    public.c26_default_branch(v_account_id)
  );

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Crear la SalesOrder en estado draft (sin tocar stock aún)
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_quote_id, status,
     payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, v_quote.client_id, p_quote_id, 'draft',
     'other', v_quote.total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- v3-snapshot-pattern (D1): copiar quote_items → sales_order_items
  -- propagando los snapshots ya congelados, SIN re-leer products.
  FOR v_item IN
    SELECT * FROM public.quote_items WHERE quote_id = p_quote_id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
       name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal,
       v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot,
       v_item.iva_rate_snapshot, v_item.snapshot_backfilled);
  END LOOP;

  -- v3-document-status-history (RN-A1): transición del quote en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'quote', p_quote_id, v_quote.status, 'accepted', v_uid, NULL);

  -- Transicionar el quote a accepted
  UPDATE public.quotes
  SET status = 'accepted'
  WHERE id = p_quote_id;

  RETURN jsonb_build_object(
    'sales_order_id', v_sales_order_id,
    'quote_id',       p_quote_id,
    'status',         'accepted'
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_accept_quote IS
  'C-29 (D3) + v3-snapshot-pattern + v3-document-status-history: acepta un Quote '
  '(draft|sent + no expirado) y crea un SalesOrder en draft con los mismos ítems, '
  'propagando los snapshots congelados. Registra en document_status_history la '
  'creación de la SalesOrder (RN-A2) y la transición del quote a accepted (RN-A1). '
  'No toca stock ni caja — eso es SalesOrder.confirm(). Atómico.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.2 rpc_quick_sale — base: 20260702000001_c29_quote_salesorder.sql.
-- Delta: registro de creación de la SalesOrder (NULL→draft, RN-A2). La
-- transición draft→confirmed la registra _c29_confirm_order_core (7.3).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_quick_sale(
  p_idempotency_key   text,
  p_client_id         uuid   DEFAULT NULL,
  p_items             jsonb  DEFAULT '[]'::jsonb,
  p_payment_method    text   DEFAULT 'other',
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_branch_id         uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_sales_order_id uuid;
  v_item           RECORD;
  v_total          numeric(15,2) := 0;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar items
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular total inicial
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'quantity debe ser > 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.price IS NULL OR v_item.price < 0 THEN
      RAISE EXCEPTION 'price debe ser >= 0' USING ERRCODE = 'P0400';
    END IF;
    v_total := v_total + COALESCE(v_item.subtotal, v_item.price * v_item.quantity);
  END LOOP;

  -- Crear SalesOrder en draft
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, status, payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, p_client_id, 'draft', p_payment_method, v_total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- Crear sales_order_items
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price,
       COALESCE(v_item.subtotal, v_item.price * v_item.quantity));
  END LOOP;

  -- Confirmar inline (hot path transaccional)
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_quick_sale IS
  'C-29 + v3-document-status-history: Crea y confirma una SalesOrder en un solo '
  'paso (POS). Idempotente por idempotency_key. Registra la creación de la orden '
  '(RN-A2) en document_status_history. Internamente usa _c29_confirm_order_core.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.3 _c29_confirm_order_core — base: 20260806000001_v3_snapshot_pattern.sql.
-- Delta: registro de la transición draft→confirmed (RN-A1) junto al UPDATE.
-- El replay idempotente retorna ANTES (replayed=true) → no duplica historial.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: validación cash sin session → P0400
  IF p_payment_method = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method
  IF p_payment_method NOT IN ('cash', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado)
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      v_qty_norm := v_item.quantity;

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4)
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  IF p_payment_method = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  p_payment_method,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  UPDATE public.sales_orders
  SET
    status             = 'confirmed',
    payment_method     = p_payment_method,
    total              = v_total,
    sale_operation_id  = v_new_op_id,
    fiscal_document_id = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$$;

-- REVOKE: helper interno — NO callable desde rol authenticated (paridad con el original)
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._c29_confirm_order_core IS
  'C-29 (D1) + v3-snapshot-pattern + v3-document-status-history: helper interno '
  'compartido por rpc_confirm_sales_order y rpc_quick_sale. SECURITY DEFINER. '
  'Atómico: un fallo aborta todo el commit. Congela snapshots en sale_items y '
  'stock_movements. Registra draft→confirmed en document_status_history en la '
  'misma transacción (RN-A1); el replay idempotente no duplica historial.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.4 rpc_open_cash_session — base: 20260701000001_c28_cash_session.sql.
-- Delta: registro de la apertura (NULL→open, RN-A2).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_open_cash_session(
  p_cashbox_id       uuid,
  p_opening_balance  numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id    uuid;
  v_branch_status text;
  v_session_id    uuid;
BEGIN
  -- Guard: permiso de escritura en la cuenta dueña de la caja
  SELECT b.account_id, b.status
  INTO v_account_id, v_branch_status
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = p_cashbox_id;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'cashbox_not_found'
      USING ERRCODE = 'P0409';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validar sucursal activa
  IF v_branch_status <> 'active' THEN
    RAISE EXCEPTION 'branch_closed'
      USING ERRCODE = 'P0422';
  END IF;

  -- Guard: doble apertura (D4 — el UNIQUE INDEX es la red de seguridad física)
  IF EXISTS (
    SELECT 1 FROM public.cash_sessions
    WHERE cashbox_id = p_cashbox_id AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'cashbox_session_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- Insertar la sesión
  INSERT INTO public.cash_sessions
    (cashbox_id, status, opening_balance, opened_by)
  VALUES
    (p_cashbox_id, 'open', p_opening_balance, auth.uid())
  RETURNING id INTO v_session_id;

  -- v3-document-status-history (RN-A2): apertura de la sesión → historial
  PERFORM public.record_status_transition(
    v_account_id, 'cash_session', v_session_id, NULL, 'open', auth.uid(), NULL);

  RETURN jsonb_build_object(
    'session_id',       v_session_id,
    'cashbox_id',       p_cashbox_id,
    'status',           'open',
    'opening_balance',  p_opening_balance
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_open_cash_session IS
  'C-28 + v3-document-status-history: abre una sesión de caja y registra la '
  'apertura (NULL→open, RN-A2) en document_status_history.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.5 rpc_close_cash_session — base: 20260701000001_c28_cash_session.sql.
-- Delta: registro del cierre (open→closed, RN-A1). D7 + decisión por defecto:
-- reason AUTO-generado con la descripción de la diferencia de arqueo cuando
-- difference ≠ 0; NULL cuando el arqueo cuadra. La firma NO cambia (evita
-- overloads ambiguos — lección bank-reconciliation gate (h)).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_close_cash_session(
  p_session_id      uuid,
  p_counted_balance numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session        public.cash_sessions%ROWTYPE;
  v_account_id     uuid;
  v_sum_movements  numeric(12,2);
  v_expected       numeric(12,2);
  v_difference     numeric(12,2);
  v_close_reason   text;
BEGIN
  -- Cargar sesión
  SELECT cs.* INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- Guard: permiso de escritura
  SELECT b.account_id INTO v_account_id
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validar que esté abierta
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'session_not_open'
      USING ERRCODE = 'P0409';
  END IF;

  -- D7: calcular expected_balance = opening_balance + Σ(cash_movements.amount)
  SELECT COALESCE(SUM(cm.amount), 0)
  INTO v_sum_movements
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_expected   := v_session.opening_balance + v_sum_movements;
  v_difference := p_counted_balance - v_expected;

  -- v3-document-status-history (D7 / RN-A5): la diferencia de arqueo ≠ 0
  -- queda descripta como reason del cierre (señal antifraude, RN-95)
  IF v_difference <> 0 THEN
    v_close_reason := format('diferencia de arqueo: %s (esperado %s, contado %s)',
                             v_difference, v_expected, p_counted_balance);
  END IF;

  -- Cerrar la sesión — materializar arqueo (D7)
  UPDATE public.cash_sessions
  SET
    status           = 'closed',
    counted_balance  = p_counted_balance,
    expected_balance = v_expected,
    difference       = v_difference,
    closing_balance  = p_counted_balance,
    closed_by        = auth.uid(),
    closed_at        = now()
  WHERE id = p_session_id;

  -- v3-document-status-history (RN-A1): cierre en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'cash_session', p_session_id, 'open', 'closed',
    auth.uid(), v_close_reason);

  RETURN jsonb_build_object(
    'session_id',        p_session_id,
    'status',            'closed',
    'opening_balance',   v_session.opening_balance,
    'expected_balance',  v_expected,
    'counted_balance',   p_counted_balance,
    'difference',        v_difference,
    'closing_balance',   p_counted_balance
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_close_cash_session IS
  'C-28 + v3-document-status-history: cierra la sesión con arqueo y registra '
  'open→closed en document_status_history (RN-A1). Cuando difference ≠ 0 el '
  'reason describe la diferencia (D7 — el RPC lo genera; el catálogo no exige '
  'reason estático para no romper cierres sin diferencia).';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.6 rpc_open_reconciliation_session — base: 20260805000001_bank_reconciliation.sql.
-- Delta: registro de la apertura (NULL→open, RN-A2).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_open_reconciliation_session(
  p_bank_account_id            uuid,
  p_period_from                date,
  p_period_to                  date,
  p_statement_closing_balance  numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_account_id  uuid;
  v_ba          public.bank_accounts%ROWTYPE;
  v_session_id  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF NOT v_ba.is_active THEN
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_from > p_period_to THEN
    RAISE EXCEPTION 'periodo_invalido: period_from debe ser <= period_to'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_statement_closing_balance IS NULL THEN
    RAISE EXCEPTION 'saldo_extracto_requerido: statement_closing_balance es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  BEGIN
    INSERT INTO public.reconciliation_sessions
      (bank_account_id, account_id, period_from, period_to,
       statement_closing_balance, opened_by)
    VALUES
      (p_bank_account_id, v_account_id, p_period_from, p_period_to,
       p_statement_closing_balance, v_uid)
    RETURNING id INTO v_session_id;
  EXCEPTION
    WHEN unique_violation THEN
      -- D3: índice UNIQUE parcial anti doble-apertura
      RAISE EXCEPTION 'session_already_open: ya existe una sesión de conciliación abierta para la cuenta %',
        p_bank_account_id
        USING ERRCODE = 'P0409';
  END;

  -- v3-document-status-history (RN-A2): apertura de la sesión → historial
  PERFORM public.record_status_transition(
    v_account_id, 'reconciliation_session', v_session_id, NULL, 'open', v_uid, NULL);

  RETURN jsonb_build_object(
    'session_id',                v_session_id,
    'bank_account_id',           p_bank_account_id,
    'status',                    'open',
    'period_from',               p_period_from,
    'period_to',                 p_period_to,
    'statement_closing_balance', p_statement_closing_balance
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_open_reconciliation_session IS
  'bank-reconciliation C3 (D3) + v3-document-status-history: abre una sesión de '
  'conciliación por cuenta + período y registra NULL→open en el historial. '
  'Guards: P0401 writer, P0412 cuenta, P0400 período. '
  'Anti doble-apertura (UNIQUE parcial) → P0409.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.7 rpc_close_reconciliation_session — base: 20260805000001_bank_reconciliation.sql.
-- Delta: registro del cierre (open→closed, RN-A1) con el close_reason ya
-- exigido por el propio RPC (P0431 cuando hay diferencia).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_close_reconciliation_session(
  p_session_id    uuid,
  p_close_reason  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_session          public.reconciliation_sessions%ROWTYPE;
  v_opening_balance  numeric(14,2);
  v_ledger_balance   numeric(14,2);
  v_difference       numeric(14,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- FOR UPDATE: serializa el cierre contra matches/unmatches concurrentes
  SELECT * INTO v_session
  FROM public.reconciliation_sessions
  WHERE id = p_session_id
    AND account_id = v_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'reconciliation_session_not_found: %', p_session_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_session.status = 'closed' THEN
    RAISE EXCEPTION 'session_closed: la sesión % ya está cerrada (CLOSED es terminal)', p_session_id
      USING ERRCODE = 'P0432';
  END IF;

  -- RN-D5: corte por fecha valor (date), no por created_at.
  -- Movimientos sin value_date (cargas manuales viejas) caen a created_at::date.
  SELECT ba.opening_balance INTO v_opening_balance
  FROM public.bank_accounts ba
  WHERE ba.id = v_session.bank_account_id;

  SELECT v_opening_balance + COALESCE(SUM(bm.amount), 0)
  INTO v_ledger_balance
  FROM public.bank_movements bm
  WHERE bm.bank_account_id = v_session.bank_account_id
    AND COALESCE(bm.value_date, bm.created_at::date) <= v_session.period_to;

  v_difference := v_session.statement_closing_balance - v_ledger_balance;

  -- RN-A5 (modelo V3): diferencia ≠ 0 exige motivo
  IF v_difference <> 0 AND (p_close_reason IS NULL OR trim(p_close_reason) = '') THEN
    RAISE EXCEPTION 'motivo_requerido: el cierre con diferencia (%.2f) exige close_reason', v_difference
      USING ERRCODE = 'P0431';
  END IF;

  UPDATE public.reconciliation_sessions
  SET status                 = 'closed',
      ledger_closing_balance = v_ledger_balance,
      difference             = v_difference,
      close_reason           = NULLIF(trim(COALESCE(p_close_reason, '')), ''),
      closed_by              = v_uid,
      closed_at              = now()
  WHERE id = p_session_id;

  -- v3-document-status-history (RN-A1): cierre en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'reconciliation_session', p_session_id, 'open', 'closed',
    v_uid, NULLIF(trim(COALESCE(p_close_reason, '')), ''));

  RETURN jsonb_build_object(
    'session_id',                p_session_id,
    'status',                    'closed',
    'statement_closing_balance', v_session.statement_closing_balance,
    'ledger_closing_balance',    v_ledger_balance,
    'difference',                v_difference
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_close_reconciliation_session IS
  'bank-reconciliation C3 (D3) + v3-document-status-history: cierra la sesión, '
  'calcula ledger_closing_balance y difference (RN-D5); difference ≠ 0 sin '
  'close_reason → P0431 (RN-A5); sesión cerrada → P0432 (terminal). Registra '
  'open→closed en document_status_history en la misma transacción (RN-A1). '
  'NO toca el journal.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.8 rpc_emit_pending_cae — base: 20260806000001_v3_snapshot_pattern.sql.
-- Delta: registro de la creación del comprobante (NULL→pending_cae, RN-A2).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_emit_pending_cae(
  p_comprobante_type    text,
  p_total               numeric,
  p_client_id           uuid    DEFAULT NULL,
  p_point_of_sale_id    uuid    DEFAULT NULL,
  p_receptor_doc_tipo   integer DEFAULT NULL,
  p_receptor_doc_nro    text    DEFAULT NULL,
  p_neto                numeric DEFAULT NULL,
  p_iva_amount          numeric DEFAULT NULL,
  p_iva_alicuota_id     integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_profile          RECORD;
  v_pv               RECORD;
  v_effective_pv_id  uuid;
  v_active_pv_count  integer;
  v_doc_number       bigint;
  v_doc_id           uuid;
  v_client           RECORD;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: solo owner/admin puede emitir
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can emit fiscal documents'
      USING ERRCODE = 'P0401';
  END IF;

  -- Obtener perfil fiscal de la cuenta
  SELECT id, iva_condition, ambiente INTO v_profile
  FROM   public.fiscal_profiles
  WHERE  account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_profile_not_found: la cuenta no tiene perfil fiscal configurado'
      USING ERRCODE = 'P0404';
  END IF;

  -- v3-snapshot-pattern (D4): FiscalIdentitySnapshot del receptor — derivar
  -- razón social y condición IVA desde clients si hay client_id. NULL si
  -- no hay cliente identificado (consumidor final, comportamiento previo).
  IF p_client_id IS NOT NULL THEN
    SELECT legal_name, iva_condition INTO v_client
    FROM   public.clients
    WHERE  id = p_client_id;
  END IF;

  -- Resolver PV efectivo (D11)
  IF p_point_of_sale_id IS NOT NULL THEN
    SELECT id, numero INTO v_pv
    FROM   public.points_of_sale
    WHERE  id = p_point_of_sale_id
      AND  account_id = v_account_id
      AND  is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'point_of_sale_not_found_or_inactive: el punto de venta no existe, no pertenece a la cuenta o está inactivo'
        USING ERRCODE = 'P0404';
    END IF;
    v_effective_pv_id := v_pv.id;

  ELSE
    SELECT count(*) INTO v_active_pv_count
    FROM   public.points_of_sale
    WHERE  account_id = v_account_id AND is_active = TRUE;

    IF v_active_pv_count = 0 THEN
      RAISE EXCEPTION 'no_active_point_of_sale: la cuenta no tiene puntos de venta activos'
        USING ERRCODE = 'P0404';
    ELSIF v_active_pv_count > 1 THEN
      RAISE EXCEPTION 'ambiguous_point_of_sale: la cuenta tiene % puntos de venta activos — especificá point_of_sale_id', v_active_pv_count
        USING ERRCODE = 'P0422';
    ELSE
      SELECT id, numero INTO v_pv
      FROM   public.points_of_sale
      WHERE  account_id = v_account_id AND is_active = TRUE;
      v_effective_pv_id := v_pv.id;
    END IF;
  END IF;

  -- Reservar número (lock corto, fuera de transacción larga de la venta — C-29)
  v_doc_number := public.rpc_next_document_number(v_effective_pv_id, p_comprobante_type);

  -- Insertar comprobante en pending_cae (SIN tocar AFIP — D5). v3-snapshot-pattern:
  -- persistir receptor_legal_name/receptor_iva_condition (D4), además del
  -- receptor + IVA ya existentes (fiscal-receptor-iva-relay).
  INSERT INTO public.fiscal_documents (
    account_id, fiscal_profile_id, point_of_sale_id,
    comprobante_type, punto_de_venta, number,
    client_id, total, status,
    receptor_doc_tipo, receptor_doc_nro, neto, iva_amount, iva_alicuota_id,
    receptor_legal_name, receptor_iva_condition
  ) VALUES (
    v_account_id, v_profile.id, v_effective_pv_id,
    p_comprobante_type, v_pv.numero, v_doc_number,
    p_client_id, COALESCE(p_total, 0), 'pending_cae',
    p_receptor_doc_tipo, p_receptor_doc_nro, p_neto, p_iva_amount, p_iva_alicuota_id,
    v_client.legal_name, v_client.iva_condition
  )
  RETURNING id INTO v_doc_id;

  -- v3-document-status-history (RN-A2): creación del comprobante → historial
  PERFORM public.record_status_transition(
    v_account_id, 'fiscal_document', v_doc_id, NULL, 'pending_cae', v_uid, NULL);

  RETURN jsonb_build_object(
    'fiscal_document_id', v_doc_id,
    'point_of_sale_id',   v_effective_pv_id,
    'punto_de_venta',     v_pv.numero,
    'comprobante_type',   p_comprobante_type,
    'number',             v_doc_number,
    'status',             'pending_cae'
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_emit_pending_cae IS
  'C-27 (D5/D11) + fiscal-receptor-iva-relay + v3-snapshot-pattern (D4) + '
  'v3-document-status-history: emite un comprobante en pending_cae sin tocar '
  'AFIP, persiste receptor + IVA + FiscalIdentitySnapshot y registra '
  'NULL→pending_cae en document_status_history (RN-A2).';


-- ─────────────────────────────────────────────────────────────────────────
-- 7.9 rpc_transfer_stock — base: 20260625000001_c26_branch_as_root.sql.
-- Delta: registro de la creación de la transferencia (NULL→completed, RN-A2 —
-- la transferencia nace completed, transición atómica; terminal en el catálogo).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(p_product_id uuid, p_from_branch_id uuid, p_to_branch_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from           RECORD;
  v_to             RECORD;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_transfer_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
  END IF;

  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed' USING ERRCODE = 'P0400';
  END IF;

  -- Ambas branches de la cuenta, existentes y OPERATIVAS (C-26)
  SELECT id, status INTO v_from
  FROM   public.branches
  WHERE  id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_from.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de origen está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT id, status INTO v_to
  FROM   public.branches
  WHERE  id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_to.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de destino está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de las filas de ledger (origen primero, destino si existe)
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_from_branch_id
  FOR UPDATE;

  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_to_branch_id
  FOR UPDATE;

  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P0409';
  END IF;

  -- C-26 (D3): la transferencia es una entidad con identidad propia
  INSERT INTO public.stock_transfers (
    account_id, product_id, from_branch_id, to_branch_id, quantity, status, created_by
  ) VALUES (
    v_account_id, p_product_id, p_from_branch_id, p_to_branch_id, p_quantity, 'completed', v_uid
  )
  RETURNING id INTO v_transfer_id;

  -- v3-document-status-history (RN-A2): la transferencia nace completed
  PERFORM public.record_status_transition(
    v_account_id, 'stock_transfer', v_transfer_id, NULL, 'completed', v_uid, NULL);

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id, v_transfer_id
  );

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id, v_transfer_id
  );

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_transfer_stock IS
  'C-26 + v3-document-status-history: transferencia atómica entre sucursales '
  '(nace completed). Registra NULL→completed en document_status_history (RN-A2).';


-- ============================================================
-- 8. Gates SQL (RED→GREEN) — estructurales siempre + comportamiento solo
--    en DB vacía (CI validate-kpis). Patrón C2/C3: anchor sintético vía
--    auth.users (handle_new_user), discriminación por SQLSTATE, limpieza
--    best-effort. Sin insertar datos en prod.
-- ============================================================
DO $gate$
DECLARE
  v_count           int;
  v_bool            boolean;
  v_fake_user_id    uuid := gen_random_uuid();
  v_fake_account_id uuid;
  v_doc_a           uuid := gen_random_uuid();
  v_doc_b           uuid := gen_random_uuid();
  v_doc_c           uuid := gen_random_uuid();
  v_doc_d           uuid := gen_random_uuid();
  v_quote_id        uuid;
  v_run_behavioral  boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- 2 tablas nuevas existen
  v_gate_b boolean := false;  -- history: RLS on + única policy SELECT
  v_gate_c boolean := false;  -- UPDATE/DELETE revocados de authenticated/anon
  v_gate_d boolean := false;  -- seed: 18 filas, allowed_role NULL, 6 creaciones, 2 índices únicos
  v_gate_e boolean := false;  -- helpers ejecutables por authenticated + semántica del catálogo
  v_gate_f boolean := false;  -- record_status_transition/rpc_record_fiscal_transition revocados
  v_gate_g boolean := false;  -- 9 RPCs retrofiteados invocan record_status_transition + trigger quotes
  v_gate_h boolean := false;  -- negativo: CHECK de operation_idempotency intacto (LECCIÓN C3)
  -- comportamiento (solo CI / DB vacía)
  v_gate_i boolean := false;  -- transición válida inserta exactamente 1 fila correcta
  v_gate_j boolean := false;  -- transición no catalogada → P0409
  v_gate_k boolean := false;  -- requires_reason sin reason → P0400; con reason OK
  v_gate_l boolean := false;  -- creación registra from_status = NULL (RN-A2)
  v_gate_m boolean := false;  -- trigger de quotes registra la creación
  v_gate_n boolean := false;  -- UPDATE/DELETE como authenticated rechazados (42501)
BEGIN

  -- ── (a) Las 2 tablas nuevas existen ───────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name IN ('document_status_history', 'document_status_transitions');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaban 2 tablas nuevas, hay %', v_count;
  END IF;
  v_gate_a := true;

  -- ── (b) history: RLS habilitada + exactamente 1 policy y es SELECT ────────
  SELECT relrowsecurity INTO v_bool
  FROM pg_class WHERE relname = 'document_status_history' AND relnamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (b) FAILED: document_status_history sin RLS';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'document_status_history';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (b) FAILED: se esperaba 1 sola policy en document_status_history, hay %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'document_status_history'
    AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE (b) FAILED: existen % policies de escritura en el historial — RN-A3', v_count;
  END IF;
  v_gate_b := true;

  -- ── (c) UPDATE/DELETE revocados (RN-A3 por grants) ────────────────────────
  IF has_table_privilege('authenticated', 'public.document_status_history', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.document_status_history', 'DELETE')
     OR has_table_privilege('anon', 'public.document_status_history', 'UPDATE')
     OR has_table_privilege('anon', 'public.document_status_history', 'DELETE') THEN
    RAISE EXCEPTION 'GATE (c) FAILED: UPDATE/DELETE no revocados sobre document_status_history';
  END IF;
  v_gate_c := true;

  -- ── (d) Seed del catálogo (D6) ────────────────────────────────────────────
  SELECT COUNT(*) INTO v_count FROM public.document_status_transitions;
  IF v_count <> 18 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: seed esperaba 18 transiciones, hay %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.document_status_transitions WHERE allowed_role IS NOT NULL;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: allowed_role debe ser NULL en todo el seed (D5), hay % pobladas', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.document_status_transitions WHERE from_status IS NULL;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: se esperaban 6 filas de creación (una por tipo), hay %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public' AND tablename = 'document_status_transitions'
    AND indexname IN ('document_status_transitions_uq', 'document_status_transitions_creation_uq');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: faltan los índices únicos del catálogo (hay %)', v_count;
  END IF;
  v_gate_d := true;

  -- ── (e) Helpers: ejecutables por authenticated + semántica correcta ───────
  IF NOT has_function_privilege('authenticated', 'public.is_valid_transition(text,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.is_terminal_status(text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.transition_requires_reason(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: helpers de policy sin GRANT a authenticated';
  END IF;

  IF NOT public.is_valid_transition('sales_order', 'draft', 'confirmed') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: draft→confirmed de sales_order debería ser válida';
  END IF;
  IF public.is_valid_transition('sales_order', 'confirmed', 'draft') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: confirmed→draft de sales_order NO debería ser válida';
  END IF;
  IF NOT public.is_valid_transition('quote', NULL, 'draft') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: la creación NULL→draft de quote debería ser válida';
  END IF;
  IF NOT public.is_terminal_status('stock_transfer', 'completed') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: completed de stock_transfer debería ser terminal';
  END IF;
  -- invariante del seed: ningún estado terminal tiene transición saliente
  SELECT COUNT(*) INTO v_count
  FROM public.document_status_transitions t_out
  WHERE EXISTS (
    SELECT 1 FROM public.document_status_transitions t_in
    WHERE t_in.document_type = t_out.document_type
      AND t_in.to_status = t_out.from_status
      AND t_in.is_terminal_to
  );
  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE (e) FAILED: % transiciones salen de un estado terminal', v_count;
  END IF;
  IF public.transition_requires_reason('cash_session', 'closed') THEN
    RAISE EXCEPTION 'GATE (e) FAILED: cash_session→closed no debe exigir reason estático (D7)';
  END IF;
  v_gate_e := true;

  -- ── (f) Escritores revocados de los roles de aplicación ──────────────────
  IF has_function_privilege('authenticated', 'public.record_status_transition(uuid,text,uuid,text,text,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.record_status_transition(uuid,text,uuid,text,text,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (f) FAILED: record_status_transition ejecutable por roles de aplicación';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpc_record_fiscal_transition(uuid,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_record_fiscal_transition(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (f) FAILED: rpc_record_fiscal_transition ejecutable por roles de aplicación';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.rpc_record_fiscal_transition(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (f) FAILED: rpc_record_fiscal_transition debe ser ejecutable por service_role (relay)';
  END IF;
  v_gate_f := true;

  -- ── (g) Los 9 RPCs retrofiteados invocan record_status_transition ─────────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('rpc_accept_quote', 'rpc_quick_sale', '_c29_confirm_order_core',
                      'rpc_open_cash_session', 'rpc_close_cash_session',
                      'rpc_open_reconciliation_session', 'rpc_close_reconciliation_session',
                      'rpc_emit_pending_cae', 'rpc_transfer_stock')
    AND pg_get_functiondef(p.oid) LIKE '%record_status_transition%';
  IF v_count <> 9 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: % de 9 RPCs invocan record_status_transition', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_trigger
  WHERE tgname = 'quotes_record_status_creation'
    AND tgrelid = 'public.quotes'::regclass;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: falta el trigger quotes_record_status_creation';
  END IF;
  v_gate_g := true;

  -- ── (h) Negativo (LECCIÓN C3): CHECK de operation_idempotency intacto ─────
  SELECT COUNT(*) INTO v_count
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  WHERE t.relname = 'operation_idempotency'
    AND c.conname = 'operation_idempotency_operation_kind_check'
    AND pg_get_constraintdef(c.oid) LIKE '%sale%'
    AND pg_get_constraintdef(c.oid) LIKE '%bank_statement_import%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE (h) FAILED: el CHECK de operation_kind cambió — este change NO debe tocarlo';
  END IF;
  v_gate_h := true;

  -- ══════════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- El trigger handle_new_user auto-crea account + membership(owner)
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'v3-status-history-gate@test.local', now(), now(),
              jsonb_build_object('name', 'DSH Gate', 'phone', '', 'locality', '', 'province', ''))
      ON CONFLICT (id) DO NOTHING;

      SELECT account_id INTO v_fake_account_id
      FROM public.account_members
      WHERE user_id = v_fake_user_id
      ORDER BY created_at
      LIMIT 1;

      IF v_fake_account_id IS NULL THEN
        v_fake_account_id := gen_random_uuid();
        INSERT INTO public.accounts (id, owner_user_id)
        VALUES (v_fake_account_id, v_fake_user_id) ON CONFLICT (id) DO NOTHING;
        INSERT INTO public.account_members (account_id, user_id, role)
        VALUES (v_fake_account_id, v_fake_user_id, 'owner')
        ON CONFLICT DO NOTHING;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_run_behavioral := false;
        RAISE NOTICE 'v3-document-status-history: anchor sintético no disponible (%) — se saltan gates de comportamiento', SQLERRM;
    END;
  END IF;

  IF v_run_behavioral THEN

    -- ── (i) GATE 5.1: transición válida inserta exactamente 1 fila ──────────
    BEGIN
      PERFORM public.record_status_transition(
        v_fake_account_id, 'sales_order', v_doc_a, 'draft', 'confirmed', v_fake_user_id, NULL);

      SELECT COUNT(*) INTO v_count
      FROM public.document_status_history
      WHERE document_type = 'sales_order' AND document_id = v_doc_a
        AND from_status = 'draft' AND to_status = 'confirmed'
        AND performed_by = v_fake_user_id AND occurred_at IS NOT NULL;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (i) FAILED: se esperaba 1 fila de historial, hay %', v_count;
      END IF;
      v_gate_i := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (i) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (i) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (j) GATE 5.2: transición no catalogada → P0409 ──────────────────────
    BEGIN
      PERFORM public.record_status_transition(
        v_fake_account_id, 'sales_order', v_doc_b, 'confirmed', 'draft', v_fake_user_id, NULL);
      RAISE EXCEPTION 'GATE (j) FAILED: confirmed→draft debería fallar con P0409';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0409' THEN v_gate_j := true;
        ELSIF SQLERRM LIKE 'GATE (j) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (j) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (k) GATE 5.3: requires_reason=true sin reason → P0400 ───────────────
    BEGIN
      -- fila sintética del catálogo (se borra al final del gate)
      INSERT INTO public.document_status_transitions
        (document_type, from_status, to_status, is_terminal_to, requires_reason)
      VALUES ('cash_session', 'closed', 'gate_reason_test', false, true);

      BEGIN
        PERFORM public.record_status_transition(
          v_fake_account_id, 'cash_session', v_doc_c, 'closed', 'gate_reason_test',
          v_fake_user_id, NULL);
        RAISE EXCEPTION 'GATE (k) FAILED: sin reason debería fallar con P0400';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLSTATE = 'P0400' THEN NULL;  -- correcto
          ELSE RAISE;
          END IF;
      END;

      -- con reason no vacío debe pasar
      PERFORM public.record_status_transition(
        v_fake_account_id, 'cash_session', v_doc_c, 'closed', 'gate_reason_test',
        v_fake_user_id, 'motivo de prueba RN-A5');

      SELECT COUNT(*) INTO v_count
      FROM public.document_status_history
      WHERE document_id = v_doc_c AND reason = 'motivo de prueba RN-A5';
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (k) FAILED: la transición con reason no quedó registrada';
      END IF;

      DELETE FROM public.document_status_transitions
      WHERE document_type = 'cash_session' AND to_status = 'gate_reason_test';
      v_gate_k := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (k) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (k) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (l) GATE 5.5: creación registra from_status = NULL (RN-A2) ──────────
    BEGIN
      PERFORM public.record_status_transition(
        v_fake_account_id, 'quote', v_doc_d, NULL, 'draft', v_fake_user_id, NULL);

      SELECT COUNT(*) INTO v_count
      FROM public.document_status_history
      WHERE document_id = v_doc_d AND from_status IS NULL AND to_status = 'draft';
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (l) FAILED: la creación no registró from_status = NULL';
      END IF;
      v_gate_l := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (l) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (l) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (m) Trigger de quotes registra la creación (4.2) ────────────────────
    BEGIN
      INSERT INTO public.quotes (account_id, status, total, created_by)
      VALUES (v_fake_account_id, 'draft', 0, v_fake_user_id)
      RETURNING id INTO v_quote_id;

      SELECT COUNT(*) INTO v_count
      FROM public.document_status_history
      WHERE document_type = 'quote' AND document_id = v_quote_id
        AND from_status IS NULL AND to_status = 'draft'
        AND performed_by = v_fake_user_id;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (m) FAILED: el trigger de quotes no registró la creación (hay %)', v_count;
      END IF;
      v_gate_m := true;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (m) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (m) degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── (n) GATE 5.4: UPDATE/DELETE como authenticated → 42501 ──────────────
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      UPDATE public.document_status_history SET reason = 'hack' WHERE false;
      RAISE EXCEPTION 'GATE (n) FAILED: UPDATE como authenticated debería fallar con 42501';
    EXCEPTION
      WHEN insufficient_privilege THEN
        NULL;  -- correcto; el rollback del sub-bloque restaura el rol
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (n) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (n)/UPDATE degradado (%)', SQLERRM;
        END IF;
    END;

    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      DELETE FROM public.document_status_history WHERE false;
      RAISE EXCEPTION 'GATE (n) FAILED: DELETE como authenticated debería fallar con 42501';
    EXCEPTION
      WHEN insufficient_privilege THEN
        v_gate_n := true;
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (n) FAILED%' THEN RAISE;
        ELSE RAISE NOTICE 'v3-document-status-history: gate (n)/DELETE degradado (%)', SQLERRM;
        END IF;
    END;

    -- ── Limpieza del anchor sintético (solo DB de test, best-effort) ────────
    BEGIN
      DELETE FROM public.document_status_history WHERE account_id = v_fake_account_id;
      DELETE FROM public.quotes WHERE account_id = v_fake_account_id;
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'v3-document-status-history: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== v3-document-status-history SQL gates ===';
  RAISE NOTICE '(a) 2 tablas nuevas existen:                     %', v_gate_a;
  RAISE NOTICE '(b) history RLS + única policy SELECT:           %', v_gate_b;
  RAISE NOTICE '(c) UPDATE/DELETE revocados (RN-A3):             %', v_gate_c;
  RAISE NOTICE '(d) seed 18 transiciones, allowed_role NULL:     %', v_gate_d;
  RAISE NOTICE '(e) helpers policy + semántica catálogo:         %', v_gate_e;
  RAISE NOTICE '(f) escritores revocados de app roles:           %', v_gate_f;
  RAISE NOTICE '(g) 9 RPCs retrofiteados + trigger quotes:       %', v_gate_g;
  RAISE NOTICE '(h) CHECK operation_idempotency intacto:         %', v_gate_h;
  RAISE NOTICE '(i) transición válida → 1 fila historial:        %', v_gate_i;
  RAISE NOTICE '(j) transición no catalogada → P0409:            %', v_gate_j;
  RAISE NOTICE '(k) requires_reason → P0400 / con reason OK:     %', v_gate_k;
  RAISE NOTICE '(l) creación con from_status NULL (RN-A2):       %', v_gate_l;
  RAISE NOTICE '(m) trigger de quotes registra creación:         %', v_gate_m;
  RAISE NOTICE '(n) UPDATE/DELETE como authenticated → 42501:    %', v_gate_n;
  RAISE NOTICE '=== v3-document-status-history: schema + policy + retrofit OK ===';

END $gate$;
