-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-24, vía
-- pg_get_functiondef(oid) — task 1.5 de tenancy-guard-caja-outbox (tramo h1).
-- MAX(version) al momento de la captura: 20261012000001 (261 migraciones).
-- md5(pg_get_functiondef) = 510adc8e150fb5c315e6e9a2635eaff8 · length = 2288.
-- prosecdef = false (SECURITY INVOKER) · anon=false · authenticated=true · service_role=true.

CREATE OR REPLACE FUNCTION public.c28_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_session      public.cash_sessions%ROWTYPE;
  v_branch_status text;
  v_prev_balance  numeric(12,2);
  v_balance_after numeric(12,2);
  v_movement_id   uuid;
  v_user_id       uuid;
BEGIN
  -- D3: lock de fila de la sesión para serializar cálculo de balance_after
  SELECT * INTO v_session
  FROM public.cash_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  -- Validar que la sesión esté open
  IF v_session.id IS NULL OR v_session.status <> 'open' THEN
    RAISE EXCEPTION 'no_open_session'
      USING ERRCODE = 'P0409';
  END IF;

  -- Validar que la sucursal esté activa
  SELECT b.status INTO v_branch_status
  FROM public.cashboxes cb
  JOIN public.branches b ON b.id = cb.branch_id
  WHERE cb.id = v_session.cashbox_id;

  IF v_branch_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'branch_closed'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular el saldo previo = opening_balance + SUM(amount de los movimientos previos).
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede BAJAR tras un egreso,
  --  y MAX devolvería el pico histórico, no el saldo actual. El FOR UPDATE de arriba
  --  serializa el cálculo, así que SUM es seguro. Mismo patrón que _register_bank_movement.)
  SELECT v_session.opening_balance + COALESCE(SUM(cm.amount), 0)
  INTO v_prev_balance
  FROM public.cash_movements cm
  WHERE cm.session_id = p_session_id;

  v_balance_after := v_prev_balance + p_amount;

  -- Resolver el usuario actual del JWT
  v_user_id := auth.uid();

  -- Insertar el movimiento (append-only). banco-caja-historial-ajustes:
  -- suma description — cash_movements_adjustment_needs_reason rechaza un
  -- adjustment sin motivo no vacío, sin código nuevo acá.
  INSERT INTO public.cash_movements
    (session_id, amount, movement_type, reference_id, balance_after, created_by, description)
  VALUES
    (p_session_id, p_amount, p_type, p_reference_id, v_balance_after, v_user_id, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$function$
