CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(p_product_id uuid, p_quantity_delta numeric DEFAULT NULL::numeric, p_type text DEFAULT 'adjustment'::text, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_reference_id uuid DEFAULT NULL::uuid, p_target_quantity numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_product      RECORD;
  v_account_id   uuid;
  v_stock_sum    numeric(15,4);
  v_target_branch uuid;
  v_branch_qty   numeric(15,4);
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_delta        numeric;
  v_movement_id  uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION
      'Tipo de movimiento no válido para ajuste manual: %. '
      'Permitidos: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_quantity_delta IS NULL AND p_target_quantity IS NULL THEN
    RAISE EXCEPTION 'Se requiere p_quantity_delta o p_target_quantity'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock row BEFORE computing delta (critical for physical_count).
  SELECT id, name, stock_control_type, account_id
  INTO   v_product
  FROM   public.products
  WHERE  id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION
      'Este producto no permite ajuste manual de stock (stock_control_type = %). '
      'Los productos "variant_only" se gestionan a través de sus variantes; '
      'los "untracked" no tienen stock físico.',
      v_product.stock_control_type
      USING ERRCODE = 'check_violation';
  END IF;

  v_account_id := COALESCE(
    v_product.account_id,
    (SELECT cai FROM current_account_ids() AS cai LIMIT 1)
  );

  SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
  FROM   public.branch_stock
  WHERE  product_id = p_product_id;

  IF p_type = 'physical_count' AND p_target_quantity IS NOT NULL THEN
    v_delta := p_target_quantity - v_stock_sum;
  ELSE
    v_delta := p_quantity_delta;
    IF v_delta = 0 THEN
      RAISE EXCEPTION 'quantity_delta no puede ser cero para tipo %', p_type
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_qty_before := v_stock_sum;
  v_qty_after  := v_stock_sum + v_delta;

  IF v_qty_after < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(v_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- C-26: el ajuste global aplica sobre la default operativa; con stock
  -- repartido en sucursales, el delta negativo no puede exceder lo que hay
  -- en ella (usar el ajuste por sucursal en ese caso).
  v_target_branch := public.c26_default_branch(v_account_id);

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  IF v_delta < 0 AND v_branch_qty + v_delta < 0 THEN
    RAISE EXCEPTION
      'El ajuste excede el stock de la sucursal principal (% disponibles). Usá el ajuste por sucursal.',
      v_branch_qty
      USING ERRCODE = 'P0409';
  END IF;

  IF v_delta != 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, v_target_branch, v_delta);
  END IF;

  INSERT INTO public.stock_movements (
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type,
    account_id, branch_id
    -- operation_group_id intentionally NULL: single-movement operation
  ) VALUES (
    v_uid, p_product_id, v_product.name, p_type,
    v_delta, v_qty_before, v_qty_after,
    p_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END,
    v_account_id, v_target_branch
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'quantity_before', v_qty_before,
    'quantity_after',  v_qty_after,
    'quantity_delta',  v_delta,
    'type',            p_type
  );
END;
$function$

