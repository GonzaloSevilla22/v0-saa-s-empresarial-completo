CREATE OR REPLACE FUNCTION public.rpc_update_customer_charge_due_date(p_movement_id uuid, p_due_date date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_movement         public.customer_account_movements%ROWTYPE;
  v_open_amount       numeric(15,2);
  v_due_date_before   date;
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

  -- Tenencia: id + account_id — nunca revela si el cargo existe en OTRA cuenta.
  SELECT * INTO v_movement
  FROM public.customer_account_movements
  WHERE id = p_movement_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'charge_not_found: %', p_movement_id USING ERRCODE = 'P0404';
  END IF;

  -- Mismo vocabulario FIFO que rpc_receivables_report: sólo sale + adjustment
  -- positivo son CARGO. Un cobro/nota/reversa no tiene vencimiento propio que
  -- editar (D7 de cobranzas-vencimientos: due_date sólo existe en la fila del
  -- cargo — un no-cargo con due_date sería un estado nunca producido).
  IF NOT (v_movement.movement_type = 'sale'
          OR (v_movement.movement_type = 'adjustment' AND v_movement.amount > 0)) THEN
    RAISE EXCEPTION 'not_a_charge: movement_type=%, amount=%', v_movement.movement_type, v_movement.amount
      USING ERRCODE = 'P0400';
  END IF;

  -- open_amount del cargo (ANTES del cambio) — misma derivación FIFO que
  -- rpc_receivables_report, acotada al customer_account_id de este cargo.
  WITH pool AS (
    SELECT COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE m.customer_account_id = v_movement.customer_account_id
      AND NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  charges AS (
    SELECT m.id, m.amount,
           SUM(m.amount) OVER (
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE m.customer_account_id = v_movement.customer_account_id
      AND (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  )
  SELECT LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - p.credit))
  INTO v_open_amount
  FROM charges ch CROSS JOIN pool p
  WHERE ch.id = p_movement_id;

  IF COALESCE(v_open_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'charge_fully_settled: el cargo % no tiene saldo abierto', p_movement_id
      USING ERRCODE = 'P0400';
  END IF;

  v_due_date_before := v_movement.due_date;

  -- ÚNICA mutación de este ledger append-only: SOLO due_date, scoped por
  -- id + account_id (defensa en profundidad, ya validado arriba).
  UPDATE public.customer_account_movements
  SET due_date = p_due_date
  WHERE id = p_movement_id AND account_id = v_account_id;

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account_id, v_uid, 'customer_charge.due_date_changed', 'customer_account_movement', p_movement_id,
    jsonb_build_object(
      'due_date_before', v_due_date_before,
      'due_date_after',  p_due_date,
      'reason',          p_reason,
      'movement_type',   v_movement.movement_type,
      'amount',          v_movement.amount
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',       p_movement_id,
    'due_date',          p_due_date,
    'previous_due_date', v_due_date_before
  );
END;
$function$

