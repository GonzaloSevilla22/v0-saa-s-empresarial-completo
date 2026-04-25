-- Phase 3: variant guard — rpc_atomic_create_purchase
-- Companion to 20260424000004 (sale RPC).
-- One function per file: required by supabase db push prepared-statement execution.

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
  v_product         RECORD;
  v_purchase_id     uuid;
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
$$
