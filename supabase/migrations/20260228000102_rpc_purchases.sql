-- 3. Atomic RPC for Create Purchase
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id uuid,
  p_amount numeric,
  p_quantity integer,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product RECORD;
  v_purchase_id uuid;
  v_existing_first_op uuid;
  v_purchase_record jsonb;
BEGIN
  -- Strict input validation
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  -- Lock row for update
  SELECT id, stock INTO v_product
  FROM products
  WHERE id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  -- 1) Insert Purchase (Server-Side timestamp)
  INSERT INTO purchases (user_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  -- 2) Update Stock natively locking
  UPDATE products
  SET stock = stock + p_quantity
  WHERE id = p_product_id;

  -- 3) Fire Analytics
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id), DEFAULT);

  -- Check first operation
  SELECT id INTO v_existing_first_op
  FROM analytics_events
  WHERE user_id = p_user_id AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'first_operation', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id), DEFAULT);
  END IF;

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;
