-- Baseline vivo de prod (gxdhpxvdjjkmxhdkkwyb), capturado 2026-08-22 via
-- pg_get_functiondef('public.rpc_register_bank_movement(text,uuid,numeric,text,date,uuid,text)'::regprocedure)
-- ANTES de banco-caja-historial-ajustes. Toda reescritura de esta función
-- parte de este texto (regla de integridad de función del proyecto).

CREATE OR REPLACE FUNCTION public.rpc_register_bank_movement(p_idempotency_key text, p_bank_account_id uuid, p_amount numeric, p_type text, p_value_date date DEFAULT NULL::date, p_branch_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_ba            public.bank_accounts%ROWTYPE;
  v_inserted      integer;
  v_existing_op   uuid;
  v_new_op_id     uuid;
  v_movement_id   uuid;
  v_balance_after numeric(14,2);
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

  -- C3 amplía el subconjunto MANUAL (delta spec bank-movement, "solo anotar" V1):
  -- fee / tax_debit / interest dejan de estar reservados — cargos del extracto
  -- sin contraparte en el sistema se anotan y se concilian.
  -- card_settlement SIGUE reservado a los escritores automáticos (RPCs de pago C2).
  IF p_type NOT IN ('transfer_in', 'transfer_out', 'manual_adjustment',
                    'fee', 'tax_debit', 'interest') THEN
    RAISE EXCEPTION 'movement_type_reservado: % no está permitido en la carga manual. '
      'Tipo reservado a los escritores automáticos (C2): card_settlement. '
      'Tipos aceptados: transfer_in, transfer_out, manual_adjustment, fee, tax_debit, interest.',
      p_type
      USING ERRCODE = 'P0410';
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
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva y no acepta nuevos movimientos',
      p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- Idempotencia (D6 de C1) — sin cambios
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'bank_movement', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'bank_movement'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'movement_id',   NULL,
      'balance_after', NULL,
      'replayed',      true,
      'operation_id',  v_existing_op
    );
  END IF;

  v_movement_id := public._register_bank_movement(
    p_bank_account_id,
    p_amount,
    p_type,
    NULL,              -- source_doc_type (carga manual: sin documento fuente)
    NULL,              -- source_doc_ref
    p_value_date,
    p_branch_id,
    p_description
  );

  SELECT balance_after INTO v_balance_after
  FROM public.bank_movements
  WHERE id = v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',   v_movement_id,
    'balance_after', v_balance_after,
    'replayed',      false,
    'operation_id',  v_new_op_id
  );
END;
$function$
