-- =============================================================================
-- MIGRATION: 20260803000003_credit_note_producer.sql
-- CHANGE:    journal-entry-outbox
-- Design ref: openspec/changes/journal-entry-outbox/design.md (D9, D10)
--
-- Crea rpc_issue_credit_note: la función que emite el evento CreditNoteIssued
-- al outbox en la MISMA transacción que la actualización de la cuenta corriente.
--
-- El evento lleva en el payload:
--   account_id, source_sales_order_id, source_fiscal_document_id (si existe),
--   amount, client_id, occurred_at.
--
-- El Consumer 3 (JournalEntry) usa source_sales_order_id para localizar el
-- asiento original de la venta (por source_doc_ref = source_sales_order_id).
--
-- Task 4.2 (TDD RED→GREEN→TRIANGULATE):
--   RED: test que emitir NC commitea 1 evento CreditNoteIssued con referencia al original.
--   GREEN: productor RPC creado.
--   TRIANGULATE: NC sin asiento original → el evento queda pending (retry en el dispatch).
--
-- IDEMPOTENCIA: idempotency_key propio de la NC.
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- =============================================================================

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

  Registro la nota de crédito como movimiento en la cuenta corriente del cliente
  (credit_note → reduce el saldo deudor) Y emite el evento CreditNoteIssued al
  outbox en la MISMA transacción.

  El Consumer 3 (JournalEntry) recibe el evento y crea el asiento espejo de
  la venta original (lados invertidos + status='reversed' en el original).

  Payload del evento:
    {
      account_id, source_sales_order_id, source_fiscal_document_id,
      amount, client_id, occurred_at
    }

  source_sales_order_id es la referencia clave que _journal_post_from_event
  usa para localizar el journal_entry original (source_doc_ref = sales_order_id).

  Idempotencia: (user_id, p_idempotency_key) en operation_idempotency.
  En replay NO se emite evento duplicado.
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

    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'credit_note', v_new_cn_id)
    ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        -- Replay: retornar el resultado anterior sin emitir evento duplicado
        SELECT operation_id INTO v_existing_cn
        FROM public.operation_idempotency
        WHERE user_id = v_uid AND idempotency_key = p_idempotency_key;

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

REVOKE ALL     ON FUNCTION public.rpc_issue_credit_note(text, uuid, numeric, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_issue_credit_note(text, uuid, numeric, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_issue_credit_note(text, uuid, numeric, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_issue_credit_note IS
    'journal-entry-outbox (D9/D10, Task 4.2): emisión de nota de crédito. '
    'Registra movimiento credit_note en la cuenta corriente del cliente (si existe) '
    'y emite CreditNoteIssued al outbox en la MISMA transacción (DEC-20). '
    'Payload: {account_id, source_sales_order_id, source_fiscal_document_id, amount, client_id}. '
    'El Consumer 3 (JournalEntry) usa source_sales_order_id para revertir el asiento '
    'original de la venta. En replay (idempotency hit) NO emite evento duplicado. '
    'SECURITY DEFINER. REVOCADO de anon/PUBLIC.';
