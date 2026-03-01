-- 2. Atomic RPC for Create Sale
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id uuid,
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
  v_sale_id uuid;
  v_stock_remaining integer;
  v_existing_first_op uuid;
  v_sale_record jsonb;
BEGIN
  -- Strict input validation
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  -- Verify product exists, belongs to user, and lock the row for update to prevent race conditions
  SELECT id, stock INTO v_product
  FROM products
  WHERE id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_stock_remaining := v_product.stock - p_quantity;

  IF v_stock_remaining < 0 THEN
    RAISE EXCEPTION 'Insufficient stock (409). Available: %, Requested: %', v_product.stock, p_quantity USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- 1) Insert Sale (Timestamp generated server-side explicitly)
  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_client_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_sale_id;

  -- 2) Update Stock
  UPDATE products
  SET stock = v_stock_remaining
  WHERE id = p_product_id;

  -- 3) Fire Analytics Events
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id), DEFAULT);

  -- Check if first operation
  SELECT id INTO v_existing_first_op
  FROM analytics_events
  WHERE user_id = p_user_id AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'first_operation', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id), DEFAULT);
  END IF;

  -- Return the inserted sale as JSON
  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;
