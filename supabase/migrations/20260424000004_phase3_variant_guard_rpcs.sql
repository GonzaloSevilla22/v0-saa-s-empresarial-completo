-- ────────────────────────────────────────────────────────────────────────────
-- Phase 3: variant guard in atomic RPCs
--
-- Rule: a product with is_variant = false that has children (variants) is a
--       "parent catalogue entry" and MUST NOT be used in sales or purchases.
--       Users must select a specific variant (SKU) instead.
--
-- Change per RPC:
--   1. Add is_variant to the locked SELECT
--   2. After auth check: if parent catalogue entry → raise P422
-- ────────────────────────────────────────────────────────────────────────────

-- ── Sale RPC ─────────────────────────────────────────────────────────────────

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
  v_product           RECORD;
  v_sale_id           uuid;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
BEGIN
  -- 1. Input validation
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- 2. Lock product row (includes is_variant for Phase 3 guard)
  SELECT id, stock, price, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  -- 3. Ownership check
  IF v_product.user_id != p_user_id THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  -- 4. Phase 3 guard: reject parent catalogue entries
  --    A product is a parent if: is_variant = false AND has at least one child
  IF NOT v_product.is_variant THEN
    IF EXISTS (
      SELECT 1 FROM products
      WHERE parent_id = p_product_id
      LIMIT 1
    ) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- 5. Stock check
  IF v_product.stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  -- 6. Insert sale
  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (p_user_id, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, DEFAULT)
  RETURNING id INTO v_sale_id;

  -- 7. Deduct stock atomically
  UPDATE products
  SET stock = stock - p_quantity
  WHERE id = p_product_id;

  -- 8. Analytics
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

-- ── Purchase RPC ──────────────────────────────────────────────────────────────

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
  v_product        RECORD;
  v_purchase_id    uuid;
  v_purchase_record jsonb;
BEGIN
  -- 1. Input validation
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- 2. Lock product row (includes is_variant for Phase 3 guard)
  SELECT id, stock, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  -- 3. Ownership check
  IF v_product.user_id != p_user_id THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  -- 4. Phase 3 guard: reject parent catalogue entries
  IF NOT v_product.is_variant THEN
    IF EXISTS (
      SELECT 1 FROM products
      WHERE parent_id = p_product_id
      LIMIT 1
    ) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- 5. Insert purchase
  INSERT INTO purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  -- 6. Add stock atomically
  UPDATE products
  SET stock = stock + p_quantity
  WHERE id = p_product_id;

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;
