CREATE OR REPLACE FUNCTION public.rpc_adjust_branch_stock(p_product_id uuid, p_branch_id uuid, p_new_quantity numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_old_quantity numeric(15,4);
  v_product_name text;
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
      USING ERRCODE = 'P0403';
  END IF;

  -- Only owner/admin can adjust stock
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can adjust branch stock'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validate new quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RAISE EXCEPTION 'New quantity must be >= 0' USING ERRCODE = 'P0400';
  END IF;

  -- Verify branch belongs to this account and is operative (C-26)
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or unauthorized'
      USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Verify product exists
  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Get current quantity (default 0 if no row exists)
  SELECT quantity INTO v_old_quantity
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = p_branch_id;

  v_old_quantity := COALESCE(v_old_quantity, 0);

  -- Insert adjustment stock_movement
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, notes
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'adjustment',
    p_new_quantity - v_old_quantity, v_old_quantity, p_new_quantity,
    'adjustment', v_uid, p_branch_id, p_reason
  );

  -- UPSERT branch_stock
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_branch_id, p_new_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = p_new_quantity;

  RETURN jsonb_build_object(
    'product_id',   p_product_id,
    'branch_id',    p_branch_id,
    'old_quantity', v_old_quantity,
    'new_quantity', p_new_quantity
  );
END;
$function$

