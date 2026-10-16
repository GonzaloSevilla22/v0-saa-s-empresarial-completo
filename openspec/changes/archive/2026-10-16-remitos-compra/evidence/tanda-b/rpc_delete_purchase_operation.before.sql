CREATE OR REPLACE FUNCTION public.rpc_delete_purchase_operation(p_purchase_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_purchase_ids         uuid[];
  v_row                  RECORD;
  v_supplier_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_bank_row             RECORD;
  v_reversed_type        text;
  -- caja-compras-cobranzas (D7):
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_purchase_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_purchase_operation: se requiere p_purchase_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_purchase_ids
    FROM public.purchases
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.purchases
    WHERE id = p_purchase_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_purchase_ids
      FROM public.purchases
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      v_operation_key := p_purchase_id;
      v_purchase_ids := ARRAY[p_purchase_id];
    END IF;
  END IF;

  IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- ── Cuenta corriente de proveedor: reversión del cargo (debit_note, P0425 si negativo) ──
  SELECT supplier_account_id, SUM(amount)
  INTO v_supplier_account_id, v_charge_amount
  FROM public.supplier_account_movements
  WHERE reference_id = v_operation_key AND movement_type = 'purchase'
  GROUP BY supplier_account_id;

  IF v_supplier_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'supplier', v_supplier_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── caja-compras-cobranzas (D7) — CAJA: contra-movimiento por EXISTENCIA ──
  -- Molde exacto de rpc_delete_expense. ⚠️ El guard es `<> 0`, NUNCA `> 0` ni
  -- `< 0`: existe movimiento de caja de la compra ⇒ SIEMPRE se compensa,
  -- cualquiera sea el signo. Condicionarlo al signo esperado dejaría pasar el
  -- borrado sin compensar y SIN levantar P0426 (el modo de falla exacto que
  -- motivó delete-guard-ledgers). La sesión ORIGINAL nunca se toca —
  -- append-only (RN-99); el contra-movimiento va SIEMPRE a la sesión abierta
  -- ACTUAL de la MISMA caja.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = v_operation_key AND movement_type = 'purchase_payment'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar esta compra'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento de la compra es NEGATIVO (egreso), así que -v_cash_amount
    -- da el INGRESO positivo que repone la plata en el cajón. Si por
    -- cualquier camino llegara con el signo contrario, la contra-partida sale
    -- negativa y compensa igual: el opuesto exacto de lo posteado.
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'purchase_payment_reversal', v_operation_key, 'Reversión por borrado de compra'
    );
  END IF;
  -- ── FIN CAJA ───────────────────────────────────────────────────────────────

  -- ── Banco: espejo con dirección invertida ─────────────────────────────────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'purchase' AND source_doc_ref = v_operation_key
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'purchase', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_purchase_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'purchase', COALESCE(p_reason, 'Compra eliminada'));
  END LOOP;

  -- ── Contable: emitir PurchaseDeleted (async, vía outbox) ──────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'PurchaseDeleted', 'Purchase', v_operation_key,
    jsonb_build_object(
      'account_id',   v_account_id,
      'operation_id', v_operation_key,
      'occurred_at',  now()
    ),
    now()
  );

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(v_purchase_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$
