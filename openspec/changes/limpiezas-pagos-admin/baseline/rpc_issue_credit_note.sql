CREATE OR REPLACE FUNCTION public.rpc_issue_credit_note(p_idempotency_key text, p_sales_order_id uuid, p_amount numeric, p_fiscal_document_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

