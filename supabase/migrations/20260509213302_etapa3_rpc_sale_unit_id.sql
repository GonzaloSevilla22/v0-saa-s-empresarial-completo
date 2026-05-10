-- =============================================================================
-- MIGRATION: 20260509213302_etapa3_rpc_sale_unit_id.sql
-- DESCRIPTION: Etapa 3 — Update rpc_atomic_create_sale to accept p_unit_id
--              (uuid DEFAULT NULL) and p_quantity as NUMERIC (was INTEGER).
--              The RPC resolves the unit factor internally and normalizes the
--              quantity before updating products.stock and sales.quantity.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509213302
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   numeric,
  p_unit_id    uuid    DEFAULT NULL,
  p_currency   text    DEFAULT 'ARS',
  p_date       date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid               uuid;
  v_product           RECORD;
  v_unit              RECORD;
  v_factor            numeric;
  v_qty_base          numeric;
  v_sale_id           uuid;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, price, user_id, is_variant, stock_control_type INTO v_product
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

  IF v_product.stock_control_type = 'tracked' AND v_product.stock < v_qty_base THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, unit_id, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, p_unit_id, p_date)
  RETURNING id INTO v_sale_id;

  IF v_product.stock_control_type = 'tracked' THEN
    UPDATE products SET stock = stock - v_qty_base WHERE id = p_product_id;
  END IF;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));

  SELECT id INTO v_existing_first_op
  FROM analytics_events WHERE user_id = v_uid AND event_name = 'first_operation' LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'first_operation', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, uuid, text, date) TO authenticated;
