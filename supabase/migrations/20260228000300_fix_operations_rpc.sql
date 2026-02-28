-- Fix Sales table
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS total numeric;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS total numeric;

-- Redefine Purchase RPC
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
  v_purchase_record jsonb;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, user_id INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != p_user_id THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  INSERT INTO purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  UPDATE products
  SET stock = stock + p_quantity
  WHERE id = p_product_id;

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- Redefine Sales RPC
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id uuid,
  p_product_id uuid,
  p_amount numeric,
  p_quantity integer,
  p_user_id uuid,
  p_currency text DEFAULT 'ARS'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product RECORD;
  v_sale_id uuid;
  v_existing_first_op uuid;
  v_sale_record jsonb;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, price, user_id INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != p_user_id THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF v_product.stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (p_user_id, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, DEFAULT)
  RETURNING id INTO v_sale_id;

  UPDATE products
  SET stock = stock - p_quantity
  WHERE id = p_product_id;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (p_user_id, 'operation_created', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));

  SELECT id INTO v_existing_first_op
  FROM analytics_events
  WHERE user_id = p_user_id AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (p_user_id, 'first_operation', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;
