-- =============================================================================
-- MIGRATION: 20260509213410_etapa3_rpc_purchase_unit_id.sql
-- DESCRIPTION: Etapa 3 — Update rpc_atomic_create_purchase to accept p_unit_id
--              (uuid DEFAULT NULL) and p_quantity as NUMERIC (was INTEGER).
--              Resolves unit factor internally, normalizes quantity for stock.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509213410
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    numeric,
  p_unit_id     uuid    DEFAULT NULL,
  p_description text    DEFAULT NULL,
  p_date        date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_product         RECORD;
  v_unit            RECORD;
  v_factor          numeric;
  v_qty_base        numeric;
  v_purchase_id     uuid;
  v_purchase_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, user_id, is_variant, stock_control_type INTO v_product
  FROM products WHERE id = p_product_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- Resolve unit factor (defaults to 1 when no unit specified)
  v_factor := 1;
  IF p_unit_id IS NOT NULL THEN
    SELECT factor INTO v_unit FROM units_of_measure WHERE id = p_unit_id;
    IF FOUND THEN v_factor := v_unit.factor; END IF;
  END IF;

  v_qty_base := p_quantity * v_factor;

  INSERT INTO purchases (user_id, product_id, amount, quantity, total, unit_id, description, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_unit_id, p_description, p_date)
  RETURNING id INTO v_purchase_id;

  IF v_product.stock_control_type = 'tracked' THEN
    UPDATE products SET stock = stock + v_qty_base WHERE id = p_product_id;
  END IF;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, numeric, uuid, text, date) TO authenticated;
