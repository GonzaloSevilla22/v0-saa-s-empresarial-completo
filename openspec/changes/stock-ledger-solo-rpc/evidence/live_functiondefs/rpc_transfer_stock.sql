CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(p_product_id uuid, p_from_branch_id uuid, p_to_branch_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from           RECORD;
  v_to             RECORD;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_transfer_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
  END IF;

  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed' USING ERRCODE = 'P0400';
  END IF;

  -- Ambas branches de la cuenta, existentes y OPERATIVAS (C-26)
  SELECT id, status INTO v_from
  FROM   public.branches
  WHERE  id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_from.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de origen está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT id, status INTO v_to
  FROM   public.branches
  WHERE  id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_to.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de destino está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de las filas de ledger (origen primero, destino si existe)
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_from_branch_id
  FOR UPDATE;

  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_to_branch_id
  FOR UPDATE;

  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P0409';
  END IF;

  -- C-26 (D3): la transferencia es una entidad con identidad propia
  INSERT INTO public.stock_transfers (
    account_id, product_id, from_branch_id, to_branch_id, quantity, status, created_by
  ) VALUES (
    v_account_id, p_product_id, p_from_branch_id, p_to_branch_id, p_quantity, 'completed', v_uid
  )
  RETURNING id INTO v_transfer_id;

  -- v3-document-status-history (RN-A2): la transferencia nace completed
  PERFORM public.record_status_transition(
    v_account_id, 'stock_transfer', v_transfer_id, NULL, 'completed', v_uid, NULL);

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id, v_transfer_id
  );

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id, v_transfer_id
  );

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  -- v3-notifications-realtime (5.4): productor de TransferDispatched al outbox.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'TransferDispatched', 'StockTransfer', v_transfer_id,
    jsonb_build_object(
      'transfer_id',            v_transfer_id,
      'source_branch_id',       p_from_branch_id,
      'destination_branch_id',  p_to_branch_id
    ),
    now()
  );

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$

