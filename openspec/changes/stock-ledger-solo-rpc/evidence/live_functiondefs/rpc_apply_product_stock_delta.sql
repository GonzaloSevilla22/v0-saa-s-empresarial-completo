CREATE OR REPLACE FUNCTION public.rpc_apply_product_stock_delta(p_product_id uuid, p_delta numeric, p_branch_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_log_movement boolean DEFAULT true, p_allow_negative boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_product       RECORD;
  v_branch        RECORD;
  v_target_branch uuid;
  v_branch_qty    numeric(15,4);
  v_applied       numeric(15,4);
  v_before        numeric(15,4);
  v_after         numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la fila del producto = mutex por producto
  SELECT id, name, account_id INTO v_product
  FROM   public.products
  WHERE  id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF v_product.account_id IS DISTINCT FROM v_account_id THEN
    RAISE EXCEPTION 'Permission denied to product: %', p_product_id USING ERRCODE = 'P0403';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch destino resuelta (explícita o default operativa)
  v_target_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  v_applied := p_delta;

  IF p_delta < 0 AND v_branch_qty + p_delta < 0 THEN
    IF p_allow_negative THEN
      -- OQ-C: floor a 0 trazable — se aplica solo lo disponible y se registra
      -- el ajuste explícito (caso típico: reversa de compra ya vendida).
      v_applied := -v_branch_qty;
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reason, notes, performed_by, branch_id
      ) VALUES (
        v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
        v_applied, v_branch_qty, 0,
        'floor_on_purchase_delete',
        format('Reversa solicitada: %s, aplicada: %s (stock ya vendido)', p_delta, v_applied),
        v_uid, v_target_branch
      );
    ELSE
      RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_branch_qty, p_delta
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  v_before := v_branch_qty;
  v_after  := v_branch_qty + v_applied;

  IF v_applied <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, v_target_branch, v_applied);
  END IF;

  IF p_log_movement AND v_applied <> 0 THEN
    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reason, performed_by, branch_id
    ) VALUES (
      v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
      v_applied, v_before, v_after,
      p_reason, v_uid, v_target_branch
    );
  END IF;

  RETURN jsonb_build_object(
    'product_id',      p_product_id,
    'branch_id',       v_target_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'floored',         (v_applied <> p_delta)
  );
END;
$function$

