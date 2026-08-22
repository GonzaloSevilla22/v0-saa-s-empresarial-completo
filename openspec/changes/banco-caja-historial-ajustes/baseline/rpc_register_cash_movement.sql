-- Baseline vivo de prod (gxdhpxvdjjkmxhdkkwyb), capturado 2026-08-22 via
-- pg_get_functiondef('public.rpc_register_cash_movement(uuid,numeric,text,uuid)'::regprocedure)
-- ANTES de banco-caja-historial-ajustes. Toda reescritura de esta función
-- parte de este texto (regla de integridad de función del proyecto).

CREATE OR REPLACE FUNCTION public.rpc_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id  uuid;
  v_movement_id uuid;
BEGIN
  -- Resolver account_id vía cadena de FKs
  SELECT b.account_id INTO v_account_id
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches b   ON b.id  = cb.branch_id
  WHERE cs.id = p_session_id;

  IF v_account_id IS NULL THEN
    -- La sesión no existe — el helper emitirá no_open_session
    NULL;
  ELSIF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Delegar al helper intra-transacción (D2)
  v_movement_id := public.c28_register_cash_movement(
    p_session_id, p_amount, p_type, p_reference_id
  );

  RETURN jsonb_build_object('movement_id', v_movement_id);
END;
$function$
