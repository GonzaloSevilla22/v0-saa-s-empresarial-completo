-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-22, vía
-- pg_get_functiondef(oid) — task 1.1 de delete-guard-ledgers.
-- MAX(version) al momento de la captura: 20261004000002.
-- Sin cambios en este change: la RPC de borrado la invoca tal cual (#417).

CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_movement(p_reference_id uuid, p_reference_type text, p_reason text DEFAULT NULL::text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_movement     RECORD;
  v_new_type     text;
  v_new_ref_type text;
  v_delta_result jsonb;
  v_new_row      public.stock_movements;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_reference_type NOT IN ('purchase', 'sale') THEN
    RAISE EXCEPTION 'rpc_reverse_stock_movement: p_reference_type debe ser purchase o sale (recibido: %)', p_reference_type
      USING ERRCODE = 'P0400';
  END IF;

  v_new_type     := CASE p_reference_type WHEN 'purchase' THEN 'purchase_return' ELSE 'sale_return' END;
  v_new_ref_type := p_reference_type || '_reversal';

  -- Scope explícito por cuenta (defensa en profundidad — la RPC es SECURITY
  -- DEFINER, no depende de RLS, pero tampoco debe tocar movimientos de otra
  -- cuenta si p_reference_id colisionara).
  FOR v_movement IN
    SELECT *
    FROM public.stock_movements
    WHERE reference_id   = p_reference_id
      AND reference_type = p_reference_type
      AND account_id     = v_account_id
      AND product_id IS NOT NULL
      AND quantity_delta IS NOT NULL
  LOOP
    -- Reutiliza rpc_apply_product_stock_delta para la aritmética de stock
    -- (lock de producto, floor-a-cero trazable si ya se vendió, validación
    -- de sucursal) — p_log_movement=FALSE porque ESTA función es la dueña
    -- del movimiento que se registra (necesita su propio type/reference_type/
    -- metadata, no el genérico 'adjustment' que loguearía el RPC de stock).
    SELECT public.rpc_apply_product_stock_delta(
      v_movement.product_id, -v_movement.quantity_delta, v_movement.branch_id,
      NULL, FALSE, TRUE
    ) INTO v_delta_result;

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, reason, notes, performed_by, branch_id, metadata
    ) VALUES (
      v_uid, v_account_id, v_movement.product_id, v_movement.product_name, v_new_type,
      (v_delta_result->>'quantity_delta')::numeric,
      (v_delta_result->>'quantity_before')::numeric,
      (v_delta_result->>'quantity_after')::numeric,
      p_reference_id, v_new_ref_type,
      COALESCE(p_reason, format('Reversa de %s', p_reference_type)),
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id),
      v_uid, v_movement.branch_id,
      jsonb_build_object('reverses_movement_id', v_movement.id)
    )
    RETURNING * INTO v_new_row;

    RETURN NEXT to_jsonb(v_new_row);
  END LOOP;

  RETURN;
END;
$function$
