-- =============================================================================
-- MIGRATION: 20260803000001_journal_entry_schema.sql
-- CHANGE:    journal-entry-outbox
-- Design ref: openspec/changes/journal-entry-outbox/design.md
--
-- Crea el schema de partida doble (journal_entries + journal_lines),
-- el helper _journal_post_from_event, y el Consumer 3 (JournalEntry) en
-- rpc_process_outbox_dispatch.
--
-- TDD tasks cubiertos (RED→GREEN→TRIANGULATE→REFACTOR):
--   Tasks 1.1-1.5 (schema + RLS)
--   Tasks 2.1-2.5 (helper skeleton + Consumer 3 + idempotencia)
--   Tasks 3.1-3.6 (mapeo de 5 eventos + ASSERT balance)
--
-- IDEMPOTENCIA: IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — regla del proyecto).
-- =============================================================================

-- =============================================================================
-- 1. SCHEMA: journal_entries + journal_lines
-- =============================================================================

-- ─── 1.1 journal_entries ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.journal_entries (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id       uuid          NOT NULL
                                   REFERENCES public.accounts(id) ON DELETE CASCADE,
    posted_at        timestamptz   NOT NULL DEFAULT now(),
    source_event_id  uuid          REFERENCES public.events(id) ON DELETE SET NULL,
    source_doc_type  text,
    source_doc_ref   uuid,
    status           text          NOT NULL DEFAULT 'posted'
                                   CHECK (status IN ('posted', 'reversed')),
    reversal_of      uuid          REFERENCES public.journal_entries(id) ON DELETE SET NULL,
    created_at       timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.journal_entries IS
    'journal-entry-outbox: asientos de partida doble generados asincrónicamente '
    'por el relay C-25 (Consumer 3 JournalEntry). Escritura solo vía '
    '_journal_post_from_event (SECURITY DEFINER) — sin política INSERT para authenticated.';

COMMENT ON COLUMN public.journal_entries.source_event_id IS
    'Referencia al evento del outbox que originó este asiento. '
    'Índice único parcial WHERE IS NOT NULL = idempotencia por evento (D6).';

COMMENT ON COLUMN public.journal_entries.status IS
    'posted = asiento vigente; reversed = anulado por nota de crédito. '
    'El balance se valida por ASSERT en _journal_post_from_event (D5), no por CHECK.';

COMMENT ON COLUMN public.journal_entries.reversal_of IS
    'Self-FK al asiento original cuando este asiento es una reversión '
    '(CreditNoteIssued). NULL para asientos normales.';

-- ─── 1.2 journal_lines ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.journal_lines (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id         uuid          NOT NULL
                                   REFERENCES public.journal_entries(id) ON DELETE CASCADE,
    account_id       uuid          NOT NULL,
    -- account_id denormalized from parent entry for RLS without per-row subquery (D7)
    account_code     text          NOT NULL,
    -- account_code TEXT without FK: natural key for future chart_of_accounts FK (V2.6, D1)
    cost_center_id   uuid          REFERENCES public.cost_centers(id) ON DELETE SET NULL,
    side             text          NOT NULL CHECK (side IN ('debit', 'credit')),
    amount           numeric(14,2) NOT NULL CHECK (amount > 0),
    line_no          int           NOT NULL
);

COMMENT ON TABLE  public.journal_lines IS
    'Líneas de partida doble de un asiento contable. ON DELETE CASCADE desde journal_entries.';

COMMENT ON COLUMN public.journal_lines.account_id IS
    'account_id denormalizado del entry padre. Permite RLS sin subquery por fila '
    '(D7 design.md). El relay lo copia al INSERT — valor inmutable.';

COMMENT ON COLUMN public.journal_lines.account_code IS
    'Código del plan de cuentas (TEXT sin FK). Clave natural para futura '
    'chart_of_accounts.code FK en V2.6 — sin reescribir datos históricos (D1).';

COMMENT ON COLUMN public.journal_lines.cost_center_id IS
    'Centro de costo analítico. NULL en líneas de ingreso (ventas). '
    'Propagado desde purchases.cost_center_id en línea 5100 de compra (D8).';

-- =============================================================================
-- 2. ÍNDICES
-- =============================================================================

-- 1.3 Índices según spec
CREATE INDEX IF NOT EXISTS idx_journal_entries_account_posted
    ON public.journal_entries (account_id, posted_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_journal_entries_source_event_uq
    ON public.journal_entries (source_event_id)
    WHERE source_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_journal_lines_entry_id
    ON public.journal_lines (entry_id);

CREATE INDEX IF NOT EXISTS idx_journal_lines_account_code
    ON public.journal_lines (account_code, entry_id);

CREATE INDEX IF NOT EXISTS idx_journal_lines_account_id
    ON public.journal_lines (account_id);

-- =============================================================================
-- 3. RLS (solo SELECT por account_id; escritura solo vía SECURITY DEFINER relay)
-- =============================================================================

-- 1.4 journal_entries
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "journal_entries_account_select" ON public.journal_entries;
CREATE POLICY "journal_entries_account_select" ON public.journal_entries
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

-- 1.4 journal_lines
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "journal_lines_account_select" ON public.journal_lines;
CREATE POLICY "journal_lines_account_select" ON public.journal_lines
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

-- =============================================================================
-- 4. HELPER: _journal_post_from_event
-- =============================================================================
-- 2.2 Definición del helper de posting (SECURITY DEFINER, SET search_path).
-- Contiene: dispatch por event_type, idempotencia, ASSERT de balance, INSERT entry+lines.
-- 3.1-3.6 Mapeo de los 5 eventos + ASSERT + reversión.

CREATE OR REPLACE FUNCTION public._journal_post_from_event(
    p_event public.events
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  journal-entry-outbox Consumer 3 — Helper de posting de asientos de partida doble.

  Responsabilidades:
    1. Filtrar por event_type (5 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'JournalEntry') en operation_idempotency.
    3. Calcular las líneas de débito/crédito según el mapeo hardcodeado (D1, D4).
    4. Validar Σdébito = Σcrédito (ASSERT — D5, ERRCODE P0450).
    5. INSERT journal_entries + journal_lines.

  Codigos de cuenta hardcodeados (D1 — plan mínimo PYME AR):
    1100 Caja / 1110 Banco (reservado) / 1300 Deudores por Ventas
    2100 Proveedores / 4100 Ventas / 4200 IVA Débito Fiscal
    5100 CMV/Compras / 5200 IVA Crédito Fiscal / 5300 Gastos (reservado)

  Notas de diseño:
    - El balance falla → RAISE EXCEPTION USING ERRCODE = 'P0450' → el event queda
      pending para retry; el batch NO aborta (BEGIN/EXCEPTION en rpc_process_outbox_dispatch).
    - account_id denormalizado en journal_lines (D7 — RLS sin subquery por fila).
    - SaleConfirmed: lookup JOIN sales_orders → fiscal_documents para neto/iva (D3/D9).
    - PurchaseCreated: neto/iva del payload (productor enriquecido en migración 2).
    - CreditNoteIssued: reversión del asiento original (D10).
    - SECURITY DEFINER + SET search_path: patrón C-25.

  ERRCODE custom:
    P0450 — balance falla (libre en espacio P04xx del proyecto).
    P0451 — asiento original no encontrado para NC (retry).
*/
DECLARE
    v_account_id      uuid;
    v_entry_id        uuid;
    v_payload         jsonb;
    v_event_type      text;

    -- Lookup fields
    v_total           numeric(14,2);
    v_payment_method  text;
    v_neto            numeric(14,2);
    v_iva             numeric(14,2);
    v_comp_type       text;
    v_cost_center_id  uuid;
    v_operation_id    uuid;

    -- Reversal
    v_original_id     uuid;
    v_orig_entry_id   uuid;

    -- Balance tracking
    v_sum_debit       numeric(14,2) := 0;
    v_sum_credit      numeric(14,2) := 0;
    v_line_no         int := 0;

    -- Idempotency
    v_claimed         bool;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 5 tipos en-scope ────────────────────────────────────
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'PaymentReceived',
        'PaymentMade', 'CreditNoteIssued'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'JournalEntry') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':JournalEntry',
        'event_consumer',
        p_event.id,
        'JournalEntry'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        -- Slot ya existía → skip idempotente (el asiento ya fue posteado)
        RETURN;
    END IF;

    -- ── Dispatch por event_type ───────────────────────────────────────────────

    IF v_event_type = 'SaleConfirmed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- SaleConfirmed: 1100/1300 → 4100 + 4200 (D3, D4)
        -- Lookup JOIN para comprobante_type/neto/iva_amount (D9 — no modificamos C-29)
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';

        -- Lookup fiscal_documents via sales_orders.fiscal_document_id
        SELECT
            fd.comprobante_type,
            fd.neto,
            fd.iva_amount
        INTO
            v_comp_type,
            v_neto,
            v_iva
        FROM public.sales_orders so
        LEFT JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
        WHERE so.id = (v_payload->>'sales_order_id')::uuid;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SalesOrder',
            (v_payload->>'sales_order_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Debit: 1100 Caja (cash/other) o 1300 Deudores (credit)
        v_line_no := 1;
        IF v_payment_method = 'credit' THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1300', 'debit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        END IF;
        v_sum_debit := v_sum_debit + v_total;

        -- Credit: 4100 + 4200 (Factura A/B con desglose) o 4100 solo (C/sin doc)
        IF v_comp_type IN ('factura_a', 'factura_b')
           AND v_neto IS NOT NULL
           AND v_iva IS NOT NULL
        THEN
            -- Factura A/B: crédito 4100 Ventas [neto] + 4200 IVA DF [iva]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_neto, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_neto;

            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4200', 'credit', v_iva, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_iva;
        ELSE
            -- Factura C / sin comprobante / sin desglose: crédito único 4100 [total]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_total;
        END IF;

    ELSIF v_event_type = 'PurchaseCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PurchaseCreated: 5100 + 5200 → 2100/1100 (D4, D8)
        -- Payload enriquecido por el productor (migración 2): neto, iva_amount, cost_center_id
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := COALESCE(v_payload->>'payment_method', 'credit');
        v_neto           := (v_payload->>'neto')::numeric(14,2);
        v_iva            := (v_payload->>'iva_amount')::numeric(14,2);
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_operation_id   := (v_payload->>'operation_id')::uuid;

        -- Si no hay cost_center_id en el payload, intentar lookup a purchases
        IF v_cost_center_id IS NULL AND v_operation_id IS NOT NULL THEN
            SELECT cost_center_id INTO v_cost_center_id
            FROM public.purchases
            WHERE operation_id = v_operation_id
            LIMIT 1;
        END IF;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'Purchase',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Debit: 5100 CMV [neto + cost_center] + 5200 IVA CF [iva, cc=NULL]
        -- o bien 5100 único [total] si no hay desglose
        v_line_no := 1;
        IF v_neto IS NOT NULL AND v_iva IS NOT NULL THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5100', 'debit', v_neto, v_line_no, v_cost_center_id);
            v_sum_debit := v_sum_debit + v_neto;

            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5200', 'debit', v_iva, v_line_no, NULL);
            v_sum_debit := v_sum_debit + v_iva;
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '5100', 'debit', v_total, v_line_no, v_cost_center_id);
            v_sum_debit := v_sum_debit + v_total;
        END IF;

        -- Credit: 2100 Proveedores (credit) o 1100 Caja (cash)
        v_line_no := v_line_no + 1;
        IF v_payment_method = 'cash' THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'credit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '2100', 'credit', v_total, v_line_no, NULL);
        END IF;
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentReceived' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentReceived: 1100 Caja → 1300 Deudores (D1, 3.4)
        -- ──────────────────────────────────────────────────────────────────────
        v_total := (v_payload->>'amount')::numeric(14,2);

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'CustomerAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '1300', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentMade' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentMade: 2100 Proveedores → 1100 Caja (D1, 3.4)
        -- Evento emitido por C-30 rpc_register_payment_made
        -- ──────────────────────────────────────────────────────────────────────
        v_total := (v_payload->>'amount')::numeric(14,2);

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SupplierAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '2100', 'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '1100', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'CreditNoteIssued' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- CreditNoteIssued: reversión del asiento de venta original (D10, 3.5)
        -- Localiza el original por source_sales_order_id del payload.
        -- Si no existe → RAISE para retry (P0451).
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'source_sales_order_id')::uuid;

        -- Buscar el asiento original posteado
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SalesOrder'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento original '
                'para SalesOrder % (CreditNoteIssued %). El evento quedará pending para retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- INSERT asiento espejo (reversal)
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), p_event.id, 'CreditNote',
            (v_payload->>'source_fiscal_document_id')::uuid, 'posted', v_orig_entry_id
        )
        RETURNING id INTO v_entry_id;

        -- Copiar líneas del original con lados invertidos (debit↔credit)
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        -- Sumar balance del asiento espejo para validación
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        -- Marcar el original como reversed
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    END IF;

    -- ── ASSERT de balance: Σdébito = Σcrédito (D5) ───────────────────────────
    -- Solo validar para eventos que crean líneas directamente (no para no-op)
    IF v_entry_id IS NOT NULL THEN
        -- Para los 4 primeros event_types (no reversal), calcular de la tabla
        -- (para CreditNoteIssued ya lo calculamos del espejo arriba)
        IF v_event_type != 'CreditNoteIssued' THEN
            SELECT
                COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
                COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
            INTO v_sum_debit, v_sum_credit
            FROM public.journal_lines
            WHERE entry_id = v_entry_id;
        END IF;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: Σdébito=% ≠ Σcrédito=% para evento % (ERRCODE P0450). '
                'El asiento no balancea — evento quedará pending para retry.',
                v_sum_debit, v_sum_credit, p_event.id
                USING ERRCODE = 'P0450';
        END IF;
    END IF;

END;
$fn$;

-- 2.5 REVOKE/GRANT (patrón C-25 — helper interno, solo callable desde dispatch SECURITY DEFINER)
REVOKE ALL     ON FUNCTION public._journal_post_from_event(public.events) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._journal_post_from_event(public.events) FROM anon;
REVOKE EXECUTE ON FUNCTION public._journal_post_from_event(public.events) FROM authenticated;
-- El helper es llamado SOLO desde rpc_process_outbox_dispatch (SECURITY DEFINER).
-- No se otorga EXECUTE a authenticated (patrón C-25 audit_log helper).

COMMENT ON FUNCTION public._journal_post_from_event IS
    'journal-entry-outbox (D2): helper de posting de asientos de partida doble. '
    'SECURITY DEFINER + SET search_path. Llamado solo desde el Consumer 3 de '
    'rpc_process_outbox_dispatch. REVOCADO de authenticated/anon/PUBLIC. '
    'Idempotencia: (event_id, JournalEntry) en operation_idempotency + '
    'unique partial index source_event_id en journal_entries. '
    'Balance ASSERT con ERRCODE P0450; NC original no encontrada = P0451 (retry). '
    'No-op para event_type fuera de los 5 en-scope.';

-- =============================================================================
-- 5. CONSUMER 3: Agregar JournalEntry consumer a rpc_process_outbox_dispatch
--    CREATE OR REPLACE preservando Consumers 1 (AuditLog) y 2 (EmailNotification).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  C-25 + journal-entry-outbox pure-SQL relay dispatch.

  Consumer order (per-event):
    1. AuditLog  (mandatory first — audit domain invariant)
    2. EmailNotification (sale_created/stock_adjusted/plan_changed)
    3. JournalEntry (SaleConfirmed/PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued)

  processed_at se escribe SOLO si los tres consumers activos del evento tienen éxito.
  Un consumer fallido deja processed_at NULL → retry en el próximo tick.
  Cada consumer está idempotency-guarded por (event_id, consumer_type).

  Per-event isolation: BEGIN/EXCEPTION/END por evento.
  SECURITY DEFINER: cross-account sin debilitar RLS. REVOCADO de anon/PUBLIC.
*/
DECLARE
  v_event           public.events%ROWTYPE;
  v_processed_count int := 0;
  v_audit_claimed   bool;
  v_email_claimed   bool;
  v_subject         text;
  v_recipient       text;
BEGIN
  FOR v_event IN
    SELECT *
    FROM public.events
    WHERE processed_at IS NULL
    ORDER BY occurred_at
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN

      -- ── Consumer 1: AuditLog (mandatory first) ────────────────────────────
      INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
      VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        v_event.id::text || ':AuditLog',
        'event_consumer',
        v_event.id,
        'AuditLog'
      )
      ON CONFLICT (event_id, consumer_type)
      WHERE event_id IS NOT NULL
      DO NOTHING;

      GET DIAGNOSTICS v_audit_claimed = ROW_COUNT;

      IF v_audit_claimed THEN
        INSERT INTO public.audit_logs (account_id, action, created_at)
        VALUES (v_event.account_id, v_event.event_type, now());
      END IF;

      -- ── Consumer 2: EmailNotification ─────────────────────────────────────
      IF v_event.event_type IN ('sale_created', 'stock_adjusted', 'plan_changed') THEN

        INSERT INTO public.operation_idempotency
          (user_id, idempotency_key, operation_kind, event_id, consumer_type)
        VALUES (
          '00000000-0000-0000-0000-000000000000'::uuid,
          v_event.id::text || ':EmailNotification',
          'event_consumer',
          v_event.id,
          'EmailNotification'
        )
        ON CONFLICT (event_id, consumer_type)
        WHERE event_id IS NOT NULL
        DO NOTHING;

        GET DIAGNOSTICS v_email_claimed = ROW_COUNT;

        IF v_email_claimed THEN
          v_subject := CASE v_event.event_type
            WHEN 'sale_created'    THEN 'Nueva venta registrada'
            WHEN 'stock_adjusted'  THEN 'Ajuste de stock realizado'
            WHEN 'plan_changed'    THEN 'Tu plan ha sido actualizado'
            ELSE 'Evento: ' || v_event.event_type
          END;

          v_recipient := COALESCE(
            v_event.payload->>'email',
            'account:' || v_event.account_id::text
          );

          INSERT INTO public.email_logs
            (event_type, recipient, subject, status, metadata)
          VALUES (
            v_event.event_type,
            v_recipient,
            v_subject,
            'pending',
            jsonb_build_object(
              'event_id',   v_event.id::text,
              'account_id', v_event.account_id::text
            )
          )
          ON CONFLICT DO NOTHING;
        END IF;

      END IF;

      -- ── Consumer 3: JournalEntry (journal-entry-outbox) ───────────────────
      -- Solo para los 5 tipos en-scope; _journal_post_from_event hace no-op para el resto.
      -- La idempotencia (event_id, 'JournalEntry') se gestiona dentro del helper.
      -- Un fallo en el posting (balance, NC sin original) deja el evento pending
      -- para retry — el EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'PaymentReceived',
          'PaymentMade', 'CreditNoteIssued'
      ) THEN
        PERFORM public._journal_post_from_event(v_event);
      END IF;

      -- ── Mark processed (todos los consumers activos tuvieron éxito) ─────────
      UPDATE public.events
      SET processed_at = now()
      WHERE id = v_event.id;

      v_processed_count := v_processed_count + 1;

    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING
          'rpc_process_outbox_dispatch: fallo en evento % (type=%): %',
          v_event.id, v_event.event_type, SQLERRM;
    END;

  END LOOP;

  RETURN v_processed_count;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_process_outbox_dispatch(int) TO authenticated;

COMMENT ON FUNCTION public.rpc_process_outbox_dispatch IS
    'C-25 + journal-entry-outbox (D1 pivot, D4): dispatch in-DB del outbox transaccional. '
    'Consumer 1: AuditLog (mandatory first). '
    'Consumer 2: EmailNotification (sale_created/stock_adjusted/plan_changed). '
    'Consumer 3: JournalEntry (SaleConfirmed/PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued) '
    '— llama a _journal_post_from_event (SECURITY DEFINER). '
    'processed_at SOLO tras éxito de todos los consumers activos. '
    'Per-event isolation: BEGIN/EXCEPTION/END. REVOCADO de anon/PUBLIC.';
