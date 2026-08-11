-- =============================================================================
-- MIGRATION: 20260906000001_operation_idempotency_h1_contract.sql
-- Cierra H-1 del informe QA del PR #361 + repara rpc_issue_credit_note
-- (hallazgo de la auditoría de escritores hecha para H-1).
--
-- (1) CHECK del contrato por-fila de operation_id.
--     El contrato real post-20260804000005 es: los marcadores del consumer del
--     outbox (operation_kind = 'event_consumer', dedup por event_id+consumer_type)
--     insertan operation_id NULL por diseño; TODO otro kind lo setea siempre.
--     Hasta ahora lo garantizaba solo test_idempotency.sql (assert de datos);
--     este CHECK lo garantiza en la DB. Auditados los 15 escritores vivos de
--     prod (2026-08-11): los 11 no-marcadores insertan siempre su operation_id;
--     los 4 marcadores (AuditLog, EmailNotification, JournalEntry, Notification)
--     insertan NULL. Datos de prod: 542 event_consumer todos NULL, 254 sale +
--     42 purchase con cero NULL. Patrón NOT VALID + VALIDATE (sin lock largo).
--
-- (2) Re-crea el CHECK de operation_kind con la UNIÓN vigente + 'credit_note'.
--     Lección C3 aplicada: enumerada la unión desde pg_get_constraintdef en
--     prod ANTES de escribir este archivo (2026-08-11):
--       sale, purchase, payment_received, payment_made, supplier_charge,
--       bank_movement, event_consumer, bank_statement_import,
--       cash_session_close, subscription_webhook
--     Se agrega 'credit_note': 20260803000003 creó rpc_issue_credit_note
--     insertando ese kind pero nunca lo agregó al CHECK (23514 asegurado).
--
-- (3) Repara rpc_issue_credit_note (rota desde su creación, 0 llamadas en
--     prod: 0 eventos CreditNoteIssued, ledger de cta cte vacío, único caller
--     es un test del backend — bomba dormida, no incendio):
--       a. ON CONFLICT (user_id, idempotency_key) → ese UNIQUE de 2 columnas
--          fue eliminado en 20260531230737: CADA llamada moría con 42P10.
--          Ahora usa el target real (user_id, operation_kind, idempotency_key).
--       b. El replay SELECT filtra por operation_kind = 'credit_note'
--          (aislamiento cross-kind, mismo contrato que sale/purchase).
--     CREATE OR REPLACE con la MISMA firma → conserva las ACLs que el lote 5b
--     (20260830000001) dejó a propósito como reserva documentada.
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- =============================================================================

-- ── (2) CHECK de operation_kind: unión vigente en prod + credit_note ──────────
ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale',
    'purchase',
    'payment_received',
    'payment_made',
    'supplier_charge',
    'bank_movement',
    'event_consumer',
    'bank_statement_import',
    'cash_session_close',
    'subscription_webhook',
    'credit_note'
  ]));

-- ── (1) CHECK del contrato por-fila de operation_id (H-1) ────────────────────
-- Idempotente: ADD CONSTRAINT no soporta IF NOT EXISTS → guard por catálogo.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.operation_idempotency'::regclass
      AND conname  = 'operation_idempotency_operation_id_contract'
  ) THEN
    ALTER TABLE public.operation_idempotency
      ADD CONSTRAINT operation_idempotency_operation_id_contract
      CHECK (operation_kind = 'event_consumer' OR operation_id IS NOT NULL)
      NOT VALID;
  END IF;
END $$;

-- VALIDATE es no-op si ya está validado (re-ejecución segura).
ALTER TABLE public.operation_idempotency
  VALIDATE CONSTRAINT operation_idempotency_operation_id_contract;

-- ── (3) rpc_issue_credit_note reparada ────────────────────────────────────────
-- Cuerpo idéntico al de 20260803000003 salvo los dos fixes marcados con [FIX].
CREATE OR REPLACE FUNCTION public.rpc_issue_credit_note(
    p_idempotency_key          text,
    p_sales_order_id           uuid,           -- orden de venta original a anular
    p_amount                   numeric,        -- monto de la NC (positivo)
    p_fiscal_document_id       uuid DEFAULT NULL  -- fiscal_document de la NC (opcional)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
/*
  journal-entry-outbox (Task 4.2 — D9/D10): productor de CreditNoteIssued.
  Reparada por 20260906000001: ON CONFLICT contra el UNIQUE real de 3 columnas
  (el de 2 columnas no existe desde 20260531230737 → 42P10 en cada llamada) y
  replay SELECT filtrado por operation_kind (aislamiento cross-kind).

  Registro la nota de crédito como movimiento en la cuenta corriente del cliente
  (credit_note → reduce el saldo deudor) Y emite el evento CreditNoteIssued al
  outbox en la MISMA transacción.

  El Consumer 3 (JournalEntry) recibe el evento y crea el asiento espejo de
  la venta original (lados invertidos + status='reversed' en el original).

  Idempotencia: (user_id, 'credit_note', p_idempotency_key) en
  operation_idempotency. En replay NO se emite evento duplicado.
*/
DECLARE
    v_uid                  uuid;
    v_account_id           uuid;
    v_sales_order          RECORD;
    v_customer_account_id  uuid;
    v_new_cn_id            uuid;
    v_inserted             integer;
    v_existing_cn          uuid;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT cai INTO v_account_id
    FROM   current_account_ids() AS cai
    LIMIT  1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa'
            USING ERRCODE = 'P403';
    END IF;

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    -- Verificar que la orden de venta existe y pertenece a esta cuenta
    SELECT id, client_id INTO v_sales_order
    FROM public.sales_orders
    WHERE id = p_sales_order_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'sales_order_not_found or access denied: %', p_sales_order_id
            USING ERRCODE = 'P404';
    END IF;

    -- Idempotencia: registrar la nota de crédito
    v_new_cn_id := gen_random_uuid();

    -- [FIX 42P10] target real: UNIQUE (user_id, operation_kind, idempotency_key)
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'credit_note', v_new_cn_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        -- Replay: retornar el resultado anterior sin emitir evento duplicado
        -- [FIX cross-kind] misma key usada para un sale no debe responder acá
        SELECT operation_id INTO v_existing_cn
        FROM public.operation_idempotency
        WHERE user_id = v_uid
          AND operation_kind = 'credit_note'
          AND idempotency_key = p_idempotency_key;

        RETURN jsonb_build_object(
            'credit_note_id',         v_existing_cn,
            'source_sales_order_id',  p_sales_order_id,
            'replayed',               true
        );
    END IF;

    -- Si el cliente tiene cuenta corriente, registrar el movimiento de NC
    -- (reduce el saldo deudor — espejo de payment_received pero tipo credit_note)
    IF v_sales_order.client_id IS NOT NULL THEN
        SELECT id INTO v_customer_account_id
        FROM public.customer_accounts
        WHERE account_id = v_account_id
          AND client_id  = v_sales_order.client_id;

        IF v_customer_account_id IS NOT NULL THEN
            PERFORM public.c30_register_customer_account_movement(
                v_customer_account_id,
                p_amount,
                'credit_note',
                p_sales_order_id   -- reference_id = la orden de venta original
            );
        END IF;
    END IF;

    -- ── Emitir CreditNoteIssued al outbox (DEC-20 — misma transacción) ────────
    INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
        v_account_id,
        'CreditNoteIssued',
        'CreditNote',
        v_new_cn_id,
        jsonb_build_object(
            'account_id',                v_account_id,
            'source_sales_order_id',     p_sales_order_id,
            'source_fiscal_document_id', p_fiscal_document_id,
            'amount',                    p_amount,
            'client_id',                 v_sales_order.client_id,
            'credit_note_id',            v_new_cn_id,
            'occurred_at',               now()
        ),
        now()
    );

    RETURN jsonb_build_object(
        'credit_note_id',         v_new_cn_id,
        'source_sales_order_id',  p_sales_order_id,
        'replayed',               false
    );
END;
$$;
