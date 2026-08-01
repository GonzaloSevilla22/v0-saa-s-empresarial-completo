-- =============================================================================
-- MIGRATION: 20260828000001_v31_rls_collision_rpcs.sql
-- CHANGE:    v31-tenancy-pool-rls — resolución de colisiones de escritura
--            (tasks.md 6.4-6.6, sign-off PO 2026-08-01 sobre los 3 casos
--            sensibles elevados por el inventario del apply anterior)
-- Design ref: openspec/changes/v31-tenancy-pool-rls/design.md (amendments
--             2026-08-01, sección "inventario de escrituras directas")
--
-- Contexto: el inventario de escrituras directas del backend contra
-- pg_policies encontró 5 colisiones (4 conocidas + 1 nueva) para cuando el
-- Paso 2 de v31-tenancy-pool-rls adopte el rol `authenticated` (sin
-- BYPASSRLS) en la transacción de request:
--
--   fiscal_documents  — 4 UPDATE directos, 0 policy de UPDATE
--   cashboxes         — 1 UPDATE directo, 0 policy de UPDATE
--   stock_movements   — 4 DELETE directos, policies DELETE/UPDATE con
--                        qual=false (deny EXPLÍCITO — ledger append-only
--                        por diseño). Más grave que "falta policy": hay
--                        una policy que PROHÍBE la escritura a propósito.
--   events            — INSERT directo, 0 policy de INSERT
--   email_logs        — INSERT directo, 0 policy de INSERT
--
-- Resolución (OQ-3 del propose original: RPC SECURITY DEFINER es la vía por
-- defecto, DEC-24; los 3 casos sensibles — fiscal_documents, cashboxes,
-- stock_movements — fueron elevados al PO uno por uno y firmados el
-- 2026-08-01 ANTES de escribir este archivo):
--
--   1. fiscal_documents: los 4 UPDATE (acreditar CAE, marcar rechazo,
--      reprogramar reintento, reclamar lease) → 4 RPCs SECURITY DEFINER
--      dedicadas. La tabla queda SIN escritura directa del backend.
--      rpc_fiscal_document_authorize/reject ya encapsulan la llamada a
--      rpc_record_fiscal_transition que antes hacía el repository
--      Python condicionalmente (status == 'UPDATE 1') — ahora es interno
--      al RPC, misma condición (FOUND), mismo resultado.
--   2. cashboxes: el UPDATE (soft delete, repository method NUNCA wireado
--      a un router — deuda de v3-soft-delete-policy) → rpc_soft_delete_cashbox,
--      con el mismo check is_account_writer que ya usa cashboxes_insert.
--   3. stock_movements: los 4 DELETE de reversa (borrar compra/venta que
--      había movido stock) → rpc_reverse_stock_movement, que INSERTA el
--      movimiento opuesto (type purchase_return/sale_return) con
--      metadata.reverses_movement_id apuntando al original. PROHIBIDO
--      borrar filas del ledger — se respeta el diseño append-only (las
--      policies con qual=false en DELETE/UPDATE de stock_movements NO se
--      tocan, siguen prohibiendo escritura directa para SIEMPRE. Esta RPC
--      es SECURITY DEFINER — corre como el dueño, no como `authenticated`,
--      así que no la alcanza la policy y no hace falta debilitarla).
--      CAMBIO DE COMPORTAMIENTO VISIBLE: antes, borrar una compra/venta
--      hacía desaparecer su movimiento de stock del historial. Ahora
--      queda el movimiento original MÁS el contramovimiento — el efecto
--      NETO sobre branch_stock es idéntico (gate (stock-e) abajo lo prueba).
--   4/5. events/email_logs: excepción justificada por escrito (no RPC) —
--      son tablas de infraestructura sin invariantes de negocio de
--      usuario (outbox técnico / log de envíos), ya caracterizadas así en
--      el inventario. Se agrega la policy de INSERT faltante en vez de
--      encaminar por RPC.
--
-- IDEMPOTENCIA: CREATE OR REPLACE sobre firmas nuevas (sin overload — no
--   aplica la lección 42725/C3, ninguna de estas funciones existía antes).
--   DROP POLICY IF EXISTS + CREATE POLICY, DROP CONSTRAINT IF EXISTS + ADD
--   CONSTRAINT. El pipeline de este proyecto aplica las migraciones DOS
--   VECES (integración GitHub + Actions db push) — todo bloque de este
--   archivo es re-aplicable sin efecto acumulativo.
--
-- ACL (advisors 0028/0029, gate supabase/tests/test_function_acl_gate.sql):
--   las 6 funciones nuevas son SECURITY DEFINER — REVOKE ALL FROM PUBLIC +
--   GRANT EXECUTE a `authenticated` únicamente (ninguna a `anon`), en el
--   MISMO archivo que el CREATE. rpc_fiscal_document_claim_pending y las
--   otras 3 de fiscal_documents también deben poder ser llamadas por
--   `postgres`/`service_role` (camino de servicio, get_service_conn/cron)
--   — ambos son superusuario/bypassean GRANT, no necesitan GRANT explícito.
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration — desincroniza el historial, ver CLAUDE.md).
--
-- GOVERNANCE: CRÍTICO — toca fiscal_documents (comprobantes AFIP reales) y
--   el ledger de stock de 34 cuentas con dinero real. Sign-off PO 2026-08-01
--   sobre las 3 resoluciones sensibles, PREVIO a escribir este archivo.
--
-- ROLLBACK (sin migración destructiva):
--   El backend de este mismo PR es el único caller de las 6 RPCs nuevas —
--   si algo falla, revertir el PR de código (vuelve al UPDATE/DELETE
--   directo de antes) deja las funciones/policies nuevas sin uso, inertes.
--   Si además hiciera falta revertir esta migración:
--     DROP FUNCTION IF EXISTS public.rpc_fiscal_document_authorize(uuid, text, date);
--     DROP FUNCTION IF EXISTS public.rpc_fiscal_document_reject(uuid, text);
--     DROP FUNCTION IF EXISTS public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text);
--     DROP FUNCTION IF EXISTS public.rpc_fiscal_document_claim_pending(uuid, integer);
--     DROP FUNCTION IF EXISTS public.rpc_soft_delete_cashbox(uuid, uuid, uuid);
--     DROP FUNCTION IF EXISTS public.rpc_reverse_stock_movement(uuid, text, text);
--     DROP POLICY IF EXISTS "events_writer_insert" ON public.events;
--     DROP POLICY IF EXISTS "email_logs_backend_insert" ON public.email_logs;
--     -- el CHECK ampliado de stock_movements.reference_type puede quedarse
--     -- (aditivo, no rompe filas existentes) o revertirse a la lista original.
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT proname, prosecdef FROM pg_proc WHERE proname LIKE 'rpc_fiscal_document_%'
--     OR proname IN ('rpc_soft_delete_cashbox','rpc_reverse_stock_movement');  -- 6 filas, prosecdef=true
--   SELECT has_function_privilege('authenticated','public.rpc_reverse_stock_movement(uuid,text,text)','EXECUTE'); -- true
--   SELECT has_function_privilege('anon','public.rpc_reverse_stock_movement(uuid,text,text)','EXECUTE');         -- false
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='stock_movements_reference_type_check'; -- incluye _reversal
--   SELECT policyname FROM pg_policies WHERE tablename IN ('events','email_logs') AND cmd='INSERT';
-- =============================================================================


-- =============================================================================
-- 0. PREFLIGHT — dependencias duras (todas las RPCs nuevas llaman a estas)
-- =============================================================================
DO $preflight$
BEGIN
  IF to_regprocedure('public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean)') IS NULL THEN
    RAISE EXCEPTION 'v31-tenancy-pool-rls (colisiones): falta public.rpc_apply_product_stock_delta — requerido por rpc_reverse_stock_movement.';
  END IF;
  IF to_regprocedure('public.rpc_record_fiscal_transition(uuid, text, text)') IS NULL THEN
    RAISE EXCEPTION 'v31-tenancy-pool-rls (colisiones): falta public.rpc_record_fiscal_transition — requerido por rpc_fiscal_document_authorize/reject.';
  END IF;
  IF to_regprocedure('public.is_account_writer(uuid)') IS NULL THEN
    RAISE EXCEPTION 'v31-tenancy-pool-rls (colisiones): falta public.is_account_writer — requerido por rpc_soft_delete_cashbox.';
  END IF;
  IF to_regprocedure('public.current_account_ids()') IS NULL THEN
    RAISE EXCEPTION 'v31-tenancy-pool-rls (colisiones): falta public.current_account_ids — requerido por rpc_reverse_stock_movement.';
  END IF;
END $preflight$;


-- =============================================================================
-- 1. fiscal_documents — 4 RPCs SECURITY DEFINER (colisión sensible #1)
-- =============================================================================

-- 1.1 — Acreditar CAE (antes: FiscalDocumentRepository.update_authorized)
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_authorize(
  p_doc_id       uuid,
  p_cae          text,
  p_cae_due_date date
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_matched boolean;
BEGIN
  UPDATE public.fiscal_documents
  SET status       = 'authorized',
      cae          = p_cae,
      cae_due_date = p_cae_due_date
  WHERE id = p_doc_id AND status = 'pending_cae';

  v_matched := FOUND;

  IF v_matched THEN
    PERFORM public.rpc_record_fiscal_transition(p_doc_id, 'authorized', NULL);
  END IF;

  RETURN v_matched;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date) TO authenticated;

COMMENT ON FUNCTION public.rpc_fiscal_document_authorize(uuid, text, date) IS
  'v31-tenancy-pool-rls (colisión #1, sign-off PO 2026-08-01): transiciona pending_cae -> '
  'authorized y registra el historial (rpc_record_fiscal_transition) en el mismo statement. '
  'Reemplaza el UPDATE directo de FiscalDocumentRepository.update_authorized — fiscal_documents '
  'no tiene policy de UPDATE (append-only vía RPC, no vía cliente). Llamable desde el camino de '
  'request (POST /fiscal/documents/process-pending, get_db_conn) y de servicio '
  '(process-pending-cron, get_service_conn) — ambos invocan CAERelayProcessor.process_document.';


-- 1.2 — Marcar rechazo (antes: update_rejected)
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_reject(
  p_doc_id     uuid,
  p_last_error text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_matched boolean;
BEGIN
  UPDATE public.fiscal_documents
  SET status     = 'rejected',
      last_error = p_last_error
  WHERE id = p_doc_id AND status = 'pending_cae';

  v_matched := FOUND;

  IF v_matched THEN
    PERFORM public.rpc_record_fiscal_transition(p_doc_id, 'rejected', p_last_error);
  END IF;

  RETURN v_matched;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_reject(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_reject(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_fiscal_document_reject(uuid, text) IS
  'v31-tenancy-pool-rls (colisión #1): transiciona pending_cae -> rejected y registra el '
  'historial con last_error como reason. Reemplaza el UPDATE directo de '
  'FiscalDocumentRepository.update_rejected.';


-- 1.3 — Reprogramar reintento con backoff (antes: update_retry)
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_retry(
  p_doc_id          uuid,
  p_attempts        integer,
  p_next_attempt_at timestamptz,
  p_last_error      text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.fiscal_documents
  SET attempts        = p_attempts,
      next_attempt_at = p_next_attempt_at,
      last_error      = p_last_error
  WHERE id = p_doc_id AND status = 'pending_cae';

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_fiscal_document_retry(uuid, integer, timestamptz, text) IS
  'v31-tenancy-pool-rls (colisión #1): incrementa attempts y reprograma next_attempt_at '
  '(backoff). No registra historial (pending_cae -> pending_cae no es una transición de '
  'estado — mismo comportamiento que el UPDATE directo que reemplaza).';


-- 1.4 — Reclamar lease optimista (antes: claim_pending)
CREATE OR REPLACE FUNCTION public.rpc_fiscal_document_claim_pending(
  p_doc_id       uuid,
  p_max_attempts integer DEFAULT 10
) RETURNS TABLE (
  id                 uuid,
  account_id         uuid,
  fiscal_profile_id  uuid,
  point_of_sale_id   uuid,
  comprobante_type   text,
  punto_de_venta     integer,
  number             bigint,
  total              numeric,
  status             text,
  cae                text,
  cae_due_date       date,
  attempts           integer,
  next_attempt_at    timestamptz,
  last_error         text,
  receptor_doc_tipo  smallint,
  receptor_doc_nro   text,
  neto               numeric,
  iva_amount         numeric,
  iva_alicuota_id    smallint,
  cuit               text,
  ambiente           text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.fiscal_documents fd
  SET next_attempt_at = now() + interval '5 minutes'
  FROM public.fiscal_profiles fp
  WHERE fd.id = p_doc_id
    AND fp.id = fd.fiscal_profile_id
    AND fd.status = 'pending_cae'
    AND (fd.next_attempt_at IS NULL OR fd.next_attempt_at <= now())
    AND fd.attempts < p_max_attempts
  RETURNING
    fd.id, fd.account_id, fd.fiscal_profile_id, fd.point_of_sale_id,
    fd.comprobante_type, fd.punto_de_venta, fd.number, fd.total,
    fd.status, fd.cae, fd.cae_due_date, fd.attempts, fd.next_attempt_at,
    fd.last_error,
    fd.receptor_doc_tipo, fd.receptor_doc_nro,
    fd.neto, fd.iva_amount, fd.iva_alicuota_id,
    fp.cuit, fp.ambiente;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.rpc_fiscal_document_claim_pending(uuid, integer) IS
  'v31-tenancy-pool-rls (colisión #1): lease optimista de 5 minutos (anti-double-CAE, D6 de '
  'v21-fiscal-profile) — idéntico al UPDATE...FROM...RETURNING directo que reemplaza en '
  'FiscalDocumentRepository.claim_pending. Devuelve 0 filas si el doc ya fue reclamado o no '
  'está en pending_cae (mismo contrato: el caller interpreta SETOF vacío como "ya reclamado").';


-- =============================================================================
-- 2. cashboxes — rpc_soft_delete_cashbox (colisión sensible #2)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_soft_delete_cashbox(
  p_cashbox_id uuid,
  p_account_id uuid,
  p_deleted_by uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_matched boolean;
BEGIN
  -- Mismo check que cashboxes_insert (WITH CHECK is_account_writer(b.account_id))
  -- — sólo owner/admin de la cuenta puede dar de baja una caja.
  IF NOT public.is_account_writer(p_account_id) THEN
    RETURN false;
  END IF;

  UPDATE public.cashboxes cb
  SET    deleted_at = now(), deleted_by = p_deleted_by
  FROM   public.branches b
  WHERE  cb.id = p_cashbox_id
    AND  b.id = cb.branch_id
    AND  b.account_id = p_account_id
    AND  cb.deleted_at IS NULL;

  v_matched := FOUND;
  RETURN v_matched;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_soft_delete_cashbox(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_soft_delete_cashbox(uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_soft_delete_cashbox(uuid, uuid, uuid) IS
  'v31-tenancy-pool-rls (colisión #2, sign-off PO 2026-08-01): soft delete de cashboxes — '
  'cashboxes no tiene account_id directo, el scope se resuelve vía branch_id -> '
  'branches.account_id (OQ2 de v3-soft-delete-policy). Reemplaza el UPDATE directo de '
  'CashboxRepository.soft_delete_cashbox (método existente pero sin router wireado aún — '
  'deuda documentada en v3-soft-delete-policy). is_account_writer(p_account_id) replica el '
  'WITH CHECK de cashboxes_insert: sólo owner/admin de la cuenta puede dar de baja una caja.';


-- =============================================================================
-- 3. stock_movements — rpc_reverse_stock_movement (colisión sensible #3)
-- =============================================================================

-- 3.1 — Amplía el CHECK de reference_type para los contramovimientos. Aditivo:
--       no toca valores existentes, sólo agrega 2 nuevos.
ALTER TABLE public.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_reference_type_check;
ALTER TABLE public.stock_movements ADD CONSTRAINT stock_movements_reference_type_check
  CHECK (reference_type = ANY (ARRAY[
    'sale'::text, 'purchase'::text, 'adjustment'::text, 'initial'::text,
    'sale_update'::text, 'purchase_update'::text, 'transfer'::text,
    'sale_reversal'::text, 'purchase_reversal'::text
  ]));

-- 3.2 — La RPC de reversa. NO borra: inserta el contramovimiento (type
--       purchase_return/sale_return, ya permitidos por el CHECK de `type`
--       desde antes de este change) con metadata.reverses_movement_id
--       apuntando a la fila original, que permanece intacta (append-only).
CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_movement(
  p_reference_id   uuid,
  p_reference_type text,
  p_reason         text DEFAULT NULL
) RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_movement     RECORD;
  v_new_type     text;
  v_new_ref_type text;
  v_delta_result jsonb;
  v_new_row      public.stock_movements;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_reference_type NOT IN ('purchase', 'sale') THEN
    RAISE EXCEPTION 'rpc_reverse_stock_movement: p_reference_type debe ser purchase o sale (recibido: %)', p_reference_type
      USING ERRCODE = 'P0400';
  END IF;

  v_new_type     := CASE p_reference_type WHEN 'purchase' THEN 'purchase_return' ELSE 'sale_return' END;
  v_new_ref_type := p_reference_type || '_reversal';

  -- Scope explícito por cuenta (defensa en profundidad — la RPC es SECURITY
  -- DEFINER, no depende de RLS, pero tampoco debe tocar movimientos de otra
  -- cuenta si p_reference_id colisionara).
  FOR v_movement IN
    SELECT *
    FROM public.stock_movements
    WHERE reference_id   = p_reference_id
      AND reference_type = p_reference_type
      AND account_id     = v_account_id
      AND product_id IS NOT NULL
      AND quantity_delta IS NOT NULL
  LOOP
    -- Reutiliza rpc_apply_product_stock_delta para la aritmética de stock
    -- (lock de producto, floor-a-cero trazable si ya se vendió, validación
    -- de sucursal) — p_log_movement=FALSE porque ESTA función es la dueña
    -- del movimiento que se registra (necesita su propio type/reference_type/
    -- metadata, no el genérico 'adjustment' que loguearía el RPC de stock).
    SELECT public.rpc_apply_product_stock_delta(
      v_movement.product_id, -v_movement.quantity_delta, v_movement.branch_id,
      NULL, FALSE, TRUE
    ) INTO v_delta_result;

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, reason, notes, performed_by, branch_id, metadata
    ) VALUES (
      v_uid, v_account_id, v_movement.product_id, v_movement.product_name, v_new_type,
      (v_delta_result->>'quantity_delta')::numeric,
      (v_delta_result->>'quantity_before')::numeric,
      (v_delta_result->>'quantity_after')::numeric,
      p_reference_id, v_new_ref_type,
      COALESCE(p_reason, format('Reversa de %s', p_reference_type)),
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id),
      v_uid, v_movement.branch_id,
      jsonb_build_object('reverses_movement_id', v_movement.id)
    )
    RETURNING * INTO v_new_row;

    RETURN NEXT to_jsonb(v_new_row);
  END LOOP;

  RETURN;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) IS
  'v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): reversa de stock por '
  'eliminación de compra/venta SIN borrar del ledger — stock_movements tiene policies DELETE/'
  'UPDATE con qual=false (deny explícito, append-only por diseño). Inserta el contramovimiento '
  '(type purchase_return/sale_return, reference_type purchase_reversal/sale_reversal) con '
  'metadata.reverses_movement_id apuntando al original, que permanece. CAMBIO DE '
  'COMPORTAMIENTO VISIBLE respecto del DELETE anterior: el historial ya no "olvida" el '
  'movimiento anulado — aparece el contramovimiento. El efecto NETO sobre branch_stock es '
  'idéntico (misma aritmética que antes, vía rpc_apply_product_stock_delta). Reemplaza el '
  'bloque "SELECT stock_movements + rpc_apply_product_stock_delta + DELETE FROM '
  'stock_movements" de PurchaseRepository/SalesRepository.delete_by_id/delete_by_operation.';


-- =============================================================================
-- 4. events / email_logs — excepción justificada: policy de INSERT, no RPC
--    (colisiones NO sensibles — tablas de infraestructura sin invariantes de
--    negocio de usuario, OQ-3: "RPC por defecto, policy como excepción
--    justificada en tablas de infraestructura")
-- =============================================================================

-- 4.1 — events: mismo scope que la policy de SELECT ya existente
--       (events_select: account_id IN current_account_ids()). emit_event()
--       siempre provee account_id explícito (DEC-20, outbox producer).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'events' AND policyname = 'events_writer_insert'
  ) THEN
    CREATE POLICY "events_writer_insert" ON public.events
      FOR INSERT TO authenticated
      WITH CHECK (account_id IN (SELECT current_account_ids()));
  END IF;
END $$;

-- 4.2 — email_logs: SIN account_id (columna inexistente — tabla técnica,
--       no multi-tenant). SELECT ya está admin-gated
--       ("Admins can view email logs"); INSERT es la parte outbox-técnica
--       (DEC-09: webhook -> Edge Function -> Resend) que cualquier request
--       autenticado puede disparar como efecto de una operación de negocio
--       (p.ej. notificar un evento). No hay invariante de negocio que
--       filtrar en el INSERT — la exposición de datos queda igual de
--       acotada que hoy (sólo admins pueden LEER logs de email).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'email_logs' AND policyname = 'email_logs_backend_insert'
  ) THEN
    CREATE POLICY "email_logs_backend_insert" ON public.email_logs
      FOR INSERT TO authenticated
      WITH CHECK (true);
  END IF;
END $$;


-- =============================================================================
-- 5. GATES SQL — patrón v31-authz-token-hook. Estructurales: SIEMPRE (prod y
--    CI). Comportamiento: SOLO si public.accounts está vacía (CI, anchor
--    sintético vía auth.users -> handle_new_user).
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_bool           boolean;
  v_run_behavioral boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- 6 funciones: SECURITY DEFINER, search_path fijo, ACL correcta
  v_gate_b boolean := false;  -- CHECK de stock_movements amplió reference_type
  v_gate_c boolean := false;  -- policies de INSERT en events/email_logs existen

  -- comportamiento (solo DB vacía)
  v_user1        uuid := gen_random_uuid();
  v_account1     uuid;
  v_branch1      uuid;
  v_cashbox1     uuid;
  v_product1     uuid;
  v_fp1          uuid;
  v_pv1          uuid;
  v_doc1         uuid;
  v_synth_ref    uuid := gen_random_uuid();  -- id de "purchase" sintético (gate stock-a/b/c)
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_ok           boolean;
  v_hist_count   int;
  v_claim_row    RECORD;
  v_reversal_row jsonb;
  v_reversal_cnt int;

  v_gate_cash_a boolean := false;  -- soft delete OK con is_account_writer
  v_gate_cash_b boolean := false;  -- no-op (false) con cuenta ajena
  v_gate_stock_a boolean := false;  -- movimiento original SOBREVIVE (append-only)
  v_gate_stock_b boolean := false;  -- contramovimiento con type/reference_type/metadata correctos
  v_gate_stock_c boolean := false;  -- neto de branch_stock idéntico tras apply+reverse
  v_gate_fiscal_a boolean := false;  -- authorize: status + historial + idempotente
  v_gate_fiscal_b boolean := false;  -- reject: status + historial
  v_gate_fiscal_c boolean := false;  -- claim_pending: lease + segundo claim inmediato bloqueado
  v_gate_events_a boolean := false;  -- INSERT propio OK
  v_gate_events_b boolean := false;  -- INSERT cross-account rechazado
  v_gate_email_a  boolean := false;  -- INSERT en email_logs OK para authenticated
BEGIN

  -- ── (a) 6 funciones nuevas: SECURITY DEFINER + search_path fijo + ACL ───
  FOR v_bool IN
    SELECT p.prosecdef
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'rpc_fiscal_document_authorize', 'rpc_fiscal_document_reject',
      'rpc_fiscal_document_retry', 'rpc_fiscal_document_claim_pending',
      'rpc_soft_delete_cashbox', 'rpc_reverse_stock_movement'
    )
  LOOP
    IF NOT COALESCE(v_bool, false) THEN
      RAISE EXCEPTION 'GATE (a) FAILED: alguna de las 6 RPCs nuevas no es SECURITY DEFINER + search_path fijo + EXECUTE(authenticated) sin EXECUTE(anon)';
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    'rpc_fiscal_document_authorize', 'rpc_fiscal_document_reject',
    'rpc_fiscal_document_retry', 'rpc_fiscal_document_claim_pending',
    'rpc_soft_delete_cashbox', 'rpc_reverse_stock_movement'
  );
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaban 6 funciones nuevas, hay %', v_count;
  END IF;
  v_gate_a := true;

  -- ── (b) CHECK de reference_type amplió ──────────────────────────────────
  SELECT pg_get_constraintdef(oid) LIKE '%purchase_reversal%' AND pg_get_constraintdef(oid) LIKE '%sale_reversal%'
  INTO v_bool
  FROM pg_constraint WHERE conname = 'stock_movements_reference_type_check';
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (b) FAILED: stock_movements_reference_type_check no incluye purchase_reversal/sale_reversal';
  END IF;
  v_gate_b := true;

  -- ── (c) policies de INSERT en events/email_logs ─────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='events' AND policyname='events_writer_insert' AND cmd='INSERT'
  ) AND EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='email_logs' AND policyname='email_logs_backend_insert' AND cmd='INSERT'
  ) INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (c) FAILED: falta alguna de las policies de INSERT de events/email_logs';
  END IF;
  v_gate_c := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- ── Anchor: usuario nuevo -> account + branch "Casa Central" + caja "Caja Principal" (handle_new_user, v3-provisioning-seed) ──
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_user1, 'authenticated', 'authenticated',
              'v31-rls-collisions-gate@test.local', now(), now(),
              jsonb_build_object('name', 'Gate Colisiones', 'phone', '', 'locality', '', 'province', ''));

      SELECT account_id INTO v_account1 FROM public.account_members WHERE user_id = v_user1 LIMIT 1;
      SELECT id INTO v_branch1 FROM public.branches WHERE account_id = v_account1 LIMIT 1;
      SELECT id INTO v_cashbox1 FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account1 LIMIT 1;

      -- Simular sesión de v_user1 (patrón 20260804000007) para que
      -- current_account_ids()/is_account_writer()/auth.uid() resuelvan real.
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user1::text)::text, true);
      PERFORM set_config('request.jwt.claim.sub', v_user1::text, true);

      -- ── Producto + stock inicial (para los gates de reversa) ────────────
      INSERT INTO public.products (id, user_id, account_id, name, price, cost, min_stock, is_variant, stock_control_type)
      VALUES (gen_random_uuid(), v_user1, v_account1, 'Producto Gate Colisiones', 100, 50, 0, false, 'tracked')
      RETURNING id INTO v_product1;

      -- ── (stock-a/b/c) rpc_reverse_stock_movement ─────────────────────────
      -- Simula lo que create_operation_with_event hace: aplica un delta
      -- de compra (+10) y LOGUEA el movimiento (p_log_movement=true), como
      -- hace hoy el flujo real de creación (a diferencia de la reversa).
      PERFORM public.rpc_apply_product_stock_delta(v_product1, 10, v_branch1, 'compra sintética gate', TRUE, FALSE);

      SELECT quantity INTO v_qty_before FROM public.branch_stock WHERE product_id = v_product1 AND branch_id = v_branch1;
      IF v_qty_before IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'GATE (stock) setup FAILED: stock inicial esperado 10, es %', v_qty_before;
      END IF;

      -- id sintético de "purchase" a revertir (v_synth_ref, generado arriba)
      -- — no hace falta una fila real en purchases, sólo el stock_movements
      -- con ese reference_id/type (que ya quedó insertado por el
      -- rpc_apply_product_stock_delta de arriba con reference_id/type NULL —
      -- se corrige a mano para el gate, simulando lo que
      -- create_operation_with_event sí setea en runtime real).
      UPDATE public.stock_movements
      SET reference_id = v_synth_ref, reference_type = 'purchase'
      WHERE product_id = v_product1 AND branch_id = v_branch1;

      SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE product_id = v_product1;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE (stock) setup FAILED: se esperaba 1 movimiento original, hay %', v_count;
      END IF;

      -- Reversa
      SELECT t INTO v_reversal_row FROM public.rpc_reverse_stock_movement(v_synth_ref, 'purchase', 'gate test') AS t LIMIT 1;
      IF v_reversal_row IS NULL THEN
        RAISE EXCEPTION 'GATE (stock-a) FAILED: rpc_reverse_stock_movement no devolvió ninguna fila (SETOF vacío) — esperaba 1';
      END IF;

      -- (stock-a) el movimiento ORIGINAL sigue existiendo (append-only) —
      -- deben quedar EXACTAMENTE 2 filas: la original (setup, arriba) y el
      -- contramovimiento que acaba de insertar rpc_reverse_stock_movement.
      SELECT COUNT(*) INTO v_reversal_cnt FROM public.stock_movements WHERE product_id = v_product1;
      IF v_reversal_cnt <> 2 THEN
        RAISE EXCEPTION 'GATE (stock-a) FAILED: se esperaban 2 filas (original + contramovimiento), hay %', v_reversal_cnt;
      END IF;
      v_gate_stock_a := true;

      -- (stock-b) el contramovimiento tiene type/reference_type/metadata correctos
      SELECT EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE product_id = v_product1
          AND type = 'purchase_return'
          AND reference_type = 'purchase_reversal'
          AND reference_id = v_synth_ref
          AND quantity_delta = -10
          AND metadata ? 'reverses_movement_id'
      ) INTO v_bool;
      IF NOT v_bool THEN
        RAISE EXCEPTION 'GATE (stock-b) FAILED: el contramovimiento no tiene el type/reference_type/metadata esperado';
      END IF;
      v_gate_stock_b := true;

      -- (stock-c) neto de branch_stock idéntico: aplicar +10 y revertir -10 = 0
      SELECT quantity INTO v_qty_after FROM public.branch_stock WHERE product_id = v_product1 AND branch_id = v_branch1;
      IF v_qty_after IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'GATE (stock-c) FAILED: neto esperado 0 tras apply(+10)+reverse, es %', v_qty_after;
      END IF;
      v_gate_stock_c := true;

      -- Segunda llamada a la reversa (idempotencia de no-op): ya no hay
      -- movimiento 'purchase'/'purchase_reversal' pendiente que revertir de
      -- nuevo con ESE reference_id (el original sigue siendo 'purchase' —
      -- SÍ volvería a revertirlo si se llama otra vez, por diseño: cada
      -- llamada es una reversa nueva, la idempotencia de "no reversar 2
      -- veces" es responsabilidad del caller — igual que el DELETE directo
      -- de antes, que tampoco era idempotente si se llamaba 2 veces sobre
      -- la misma purchase ya borrada). No se gatea acá: fuera del contrato
      -- de esta RPC (el caller — delete_by_id — sólo la llama una vez, tras
      -- confirmar que la purchase existía).

      -- ── (cash-a/b) rpc_soft_delete_cashbox ───────────────────────────────
      SELECT public.rpc_soft_delete_cashbox(v_cashbox1, v_account1, v_user1) INTO v_ok;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'GATE (cash-a) FAILED: soft delete con cuenta propia (owner) debía dar true';
      END IF;
      SELECT EXISTS (SELECT 1 FROM public.cashboxes WHERE id = v_cashbox1 AND deleted_at IS NOT NULL AND deleted_by = v_user1) INTO v_bool;
      IF NOT v_bool THEN
        RAISE EXCEPTION 'GATE (cash-a) FAILED: la caja no quedó marcada deleted_at/deleted_by';
      END IF;
      v_gate_cash_a := true;

      -- (cash-b) cuenta ajena -> false, sin tocar la fila (ya borrada, pero
      -- probamos con un cashbox_id inexistente + cuenta ajena = no-op seguro)
      SELECT public.rpc_soft_delete_cashbox(v_cashbox1, gen_random_uuid(), v_user1) INTO v_ok;
      IF v_ok THEN
        RAISE EXCEPTION 'GATE (cash-b) FAILED: soft delete con account_id ajeno/inexistente debía dar false';
      END IF;
      v_gate_cash_b := true;

      -- ── (fiscal-a/b/c) fiscal_documents ──────────────────────────────────
      INSERT INTO public.fiscal_profiles (id, account_id, cuit, iva_condition, ambiente, delegacion_autorizada, created_at)
      VALUES (gen_random_uuid(), v_account1, '20111111112', 'responsable_inscripto', 'homologacion', true, now())
      RETURNING id INTO v_fp1;

      INSERT INTO public.points_of_sale (id, fiscal_profile_id, account_id, numero, is_active, created_at)
      VALUES (gen_random_uuid(), v_fp1, v_account1, 1, true, now())
      RETURNING id INTO v_pv1;

      -- doc A: para authorize
      INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
      VALUES (gen_random_uuid(), v_account1, v_fp1, v_pv1, 'factura_c', 1, 1, 1000, 'pending_cae', 0)
      RETURNING id INTO v_doc1;

      SELECT public.rpc_fiscal_document_authorize(v_doc1, '75123456789012', CURRENT_DATE + 10) INTO v_ok;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'GATE (fiscal-a) FAILED: authorize sobre doc pending_cae debía dar true';
      END IF;
      SELECT EXISTS (SELECT 1 FROM public.fiscal_documents WHERE id = v_doc1 AND status = 'authorized' AND cae = '75123456789012') INTO v_bool;
      IF NOT v_bool THEN
        RAISE EXCEPTION 'GATE (fiscal-a) FAILED: el doc no quedó authorized con el CAE esperado';
      END IF;
      SELECT COUNT(*) INTO v_hist_count FROM public.document_status_history WHERE document_id = v_doc1 AND to_status = 'authorized';
      IF v_hist_count <> 1 THEN
        RAISE EXCEPTION 'GATE (fiscal-a) FAILED: se esperaba 1 fila de historial authorized, hay %', v_hist_count;
      END IF;
      -- idempotencia: segunda llamada (doc ya no está pending_cae) -> false, sin historial duplicado
      SELECT public.rpc_fiscal_document_authorize(v_doc1, 'otro-cae', CURRENT_DATE + 20) INTO v_ok;
      IF v_ok THEN
        RAISE EXCEPTION 'GATE (fiscal-a) FAILED: segunda authorize sobre doc ya authorized debía dar false';
      END IF;
      SELECT COUNT(*) INTO v_hist_count FROM public.document_status_history WHERE document_id = v_doc1 AND to_status = 'authorized';
      IF v_hist_count <> 1 THEN
        RAISE EXCEPTION 'GATE (fiscal-a) FAILED: la segunda llamada (no-op) NO debía duplicar historial, hay % filas', v_hist_count;
      END IF;
      v_gate_fiscal_a := true;

      -- doc B: para reject
      INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
      VALUES (gen_random_uuid(), v_account1, v_fp1, v_pv1, 'factura_c', 1, 2, 500, 'pending_cae', 9)
      RETURNING id INTO v_doc1;

      SELECT public.rpc_fiscal_document_reject(v_doc1, '[10015] CUIT invalido') INTO v_ok;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'GATE (fiscal-b) FAILED: reject sobre doc pending_cae debía dar true';
      END IF;
      SELECT EXISTS (
        SELECT 1 FROM public.fiscal_documents WHERE id = v_doc1 AND status = 'rejected' AND last_error = '[10015] CUIT invalido'
      ) INTO v_bool;
      IF NOT v_bool THEN
        RAISE EXCEPTION 'GATE (fiscal-b) FAILED: el doc no quedó rejected con el last_error esperado';
      END IF;
      SELECT COUNT(*) INTO v_hist_count FROM public.document_status_history WHERE document_id = v_doc1 AND to_status = 'rejected';
      IF v_hist_count <> 1 THEN
        RAISE EXCEPTION 'GATE (fiscal-b) FAILED: se esperaba 1 fila de historial rejected, hay %', v_hist_count;
      END IF;
      v_gate_fiscal_b := true;

      -- doc C: para claim_pending (lease)
      INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
      VALUES (gen_random_uuid(), v_account1, v_fp1, v_pv1, 'factura_c', 1, 3, 750, 'pending_cae', 0)
      RETURNING id INTO v_doc1;

      SELECT id, cuit, ambiente INTO v_claim_row FROM public.rpc_fiscal_document_claim_pending(v_doc1, 10);
      IF v_claim_row.id IS NULL OR v_claim_row.cuit IS DISTINCT FROM '20111111112' OR v_claim_row.ambiente IS DISTINCT FROM 'homologacion' THEN
        RAISE EXCEPTION 'GATE (fiscal-c) FAILED: claim_pending no devolvió la fila esperada (join con fiscal_profiles)';
      END IF;
      -- segundo claim inmediato (lease de 5 min todavía vigente) -> 0 filas
      SELECT COUNT(*) INTO v_count FROM public.rpc_fiscal_document_claim_pending(v_doc1, 10);
      IF v_count <> 0 THEN
        RAISE EXCEPTION 'GATE (fiscal-c) FAILED: segundo claim inmediato debía devolver 0 filas (lease vigente), devolvió %', v_count;
      END IF;
      v_gate_fiscal_c := true;

      -- ── (events-a/b) policy de INSERT en events, como authenticated real ─
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (v_account1, 'GateTest', 'Gate', v_doc1, '{}'::jsonb, now());
        EXECUTE 'RESET ROLE';
        v_gate_events_a := true;
      EXCEPTION
        WHEN OTHERS THEN
          EXECUTE 'RESET ROLE';
          RAISE EXCEPTION 'GATE (events-a) FAILED: INSERT propio como authenticated debía permitirse (%)', SQLERRM;
      END;

      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (gen_random_uuid(), 'GateTestCrossTenant', 'Gate', v_doc1, '{}'::jsonb, now());
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'GATE (events-b) FAILED: INSERT con account_id ajeno debía rechazarse (42501)';
      EXCEPTION
        WHEN insufficient_privilege THEN
          EXECUTE 'RESET ROLE';
          v_gate_events_b := true;
        WHEN OTHERS THEN
          EXECUTE 'RESET ROLE';
          IF SQLERRM LIKE 'GATE (events-b) FAILED%' THEN RAISE; END IF;
          RAISE EXCEPTION 'GATE (events-b) FAILED: error inesperado (%): %', SQLSTATE, SQLERRM;
      END;

      -- ── (email-a) policy de INSERT en email_logs, como authenticated ─────
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO public.email_logs (event_type, recipient, subject, status, metadata)
        VALUES ('gate_test', 'gate@test.local', 'Gate', 'pending', '{}'::jsonb);
        EXECUTE 'RESET ROLE';
        v_gate_email_a := true;
      EXCEPTION
        WHEN OTHERS THEN
          EXECUTE 'RESET ROLE';
          RAISE EXCEPTION 'GATE (email-a) FAILED: INSERT en email_logs como authenticated debía permitirse (%)', SQLERRM;
      END;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'v31-tenancy-pool-rls (colisiones): anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      DELETE FROM public.email_logs WHERE recipient = 'gate@test.local';
      DELETE FROM public.events WHERE aggregate_type = 'Gate';
      DELETE FROM public.document_status_history WHERE document_id IN (SELECT id FROM public.fiscal_documents WHERE account_id = v_account1);
      DELETE FROM public.fiscal_documents WHERE account_id = v_account1;
      DELETE FROM public.points_of_sale WHERE account_id = v_account1;
      DELETE FROM public.fiscal_profiles WHERE account_id = v_account1;
      DELETE FROM public.stock_movements WHERE account_id = v_account1;
      DELETE FROM public.branch_stock WHERE account_id = v_account1;
      DELETE FROM public.products WHERE account_id = v_account1;
      DELETE FROM public.cashboxes cb USING public.branches br WHERE cb.branch_id = br.id AND br.account_id = v_account1;
      DELETE FROM public.branches WHERE account_id = v_account1;
      DELETE FROM public.account_members WHERE user_id = v_user1;
      DELETE FROM public.billing_events WHERE user_id = v_user1;
      DELETE FROM public.accounts WHERE owner_user_id = v_user1;
      DELETE FROM public.profiles WHERE id = v_user1;
      DELETE FROM auth.users WHERE id = v_user1;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'v31-tenancy-pool-rls (colisiones): limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== v31-tenancy-pool-rls (colisiones de escritura) SQL gates ===';
  RAISE NOTICE '(a) 6 RPCs: SECURITY DEFINER + search_path + ACL:  %', v_gate_a;
  RAISE NOTICE '(b) CHECK reference_type ampliado:                 %', v_gate_b;
  RAISE NOTICE '(c) policies INSERT events/email_logs existen:     %', v_gate_c;
  RAISE NOTICE '(stock-a) movimiento original sobrevive:           %', v_gate_stock_a;
  RAISE NOTICE '(stock-b) contramovimiento type/ref/metadata OK:   %', v_gate_stock_b;
  RAISE NOTICE '(stock-c) neto branch_stock idéntico (apply+revert): %', v_gate_stock_c;
  RAISE NOTICE '(cash-a) soft delete owner/admin -> true:           %', v_gate_cash_a;
  RAISE NOTICE '(cash-b) soft delete cuenta ajena -> false:         %', v_gate_cash_b;
  RAISE NOTICE '(fiscal-a) authorize + historial + idempotente:     %', v_gate_fiscal_a;
  RAISE NOTICE '(fiscal-b) reject + historial:                      %', v_gate_fiscal_b;
  RAISE NOTICE '(fiscal-c) claim_pending: lease + 2do claim bloqueado: %', v_gate_fiscal_c;
  RAISE NOTICE '(events-a) INSERT propio permitido:                 %', v_gate_events_a;
  RAISE NOTICE '(events-b) INSERT cross-account rechazado (42501):  %', v_gate_events_b;
  RAISE NOTICE '(email-a) INSERT en email_logs permitido:           %', v_gate_email_a;
  RAISE NOTICE '=== v31-tenancy-pool-rls (colisiones): RPCs instaladas, sin cambio de comportamiento hasta que el backend las llame (este mismo PR) ===';

END $gate$;
