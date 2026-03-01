-- Migration: 20260228000500_fix_purchase_description.sql
-- Description: Adds description to purchases and updates RPC to match Edge Function

ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS description text;

-- Redefine Purchase RPC to accept p_description
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id uuid,
  p_amount numeric,
  p_quantity integer,
  p_user_id uuid,
  p_description text DEFAULT null
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

  INSERT INTO purchases (user_id, product_id, amount, quantity, total, description, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_description, DEFAULT)
  RETURNING id INTO v_purchase_id;

  UPDATE products
  SET stock = stock + p_quantity
  WHERE id = p_product_id;

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;
