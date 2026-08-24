-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-24, vía
-- pg_get_functiondef(oid) — task 1.5 de tenancy-guard-caja-outbox (tramo h1).
-- MAX(version) al momento de la captura: 20261012000001 (261 migraciones).
-- md5(pg_get_functiondef) = 914e0c3ce6fa15275822121c4dec51d0 · length = 1256.
-- REFERENCIA — no se toca: es el MOLDE del SELECT de resolución de cuenta
-- (cash_sessions -> cashboxes -> branches.account_id) que copia la capa 2 (D1 i).
-- prosecdef = true · anon=false · authenticated=true · service_role=true.

CREATE OR REPLACE FUNCTION public.rpc_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL::uuid, p_description text DEFAULT NULL::text)
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

  -- Delegar al helper intra-transacción (D2). banco-caja-historial-ajustes:
  -- propaga p_description — el CHECK cash_movements_adjustment_needs_reason
  -- es quien gobierna la obligatoriedad para movement_type='adjustment'.
  v_movement_id := public.c28_register_cash_movement(
    p_session_id, p_amount, p_type, p_reference_id, p_description
  );

  RETURN jsonb_build_object('movement_id', v_movement_id);
END;
$function$
