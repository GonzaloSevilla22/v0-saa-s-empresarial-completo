-- =============================================================================
-- MIGRATION: 20260509000001_add_date_param_to_rpcs.sql
-- DESCRIPTION: Allow callers to supply a custom operation date for sales and
--              purchases, enabling backdating of historical records.
--
-- Before this migration the date column in both tables always received
-- DEFAULT (= now()), making it impossible for a user to record a sale or
-- purchase with a date in the past.
--
-- Changes:
--  • rpc_atomic_create_sale    — adds p_date date DEFAULT CURRENT_DATE
--  • rpc_atomic_create_purchase — adds p_date date DEFAULT CURRENT_DATE
--
-- Backward-compatible: callers that omit p_date get today's date (same
-- behaviour as before).  Edge Functions, services.ts, and form components
-- must also be updated to forward the user-supplied date.
-- =============================================================================

-- ── rpc_atomic_create_sale ────────────────────────────────────────────────────
-- Full body mirrors 20260425000001_security_hardening.sql (Section 1b),
-- with the only change being the new p_date parameter and its use in INSERT.

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_currency   text DEFAULT 'ARS',
  p_date       date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid               uuid;
  v_product           RECORD;
  v_sale_id           uuid;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
BEGIN
  -- Identity always comes from the JWT
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- Lock product row; includes is_variant for Phase 3 guard
  SELECT id, stock, price, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  -- Ownership: product must belong to the authenticated user
  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  -- Phase 3: reject parent catalogue entries (those with variant children)
  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  IF v_product.stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  -- Insert sale — use caller-supplied date (defaults to today)
  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, p_date)
  RETURNING id INTO v_sale_id;

  UPDATE products SET stock = stock - p_quantity WHERE id = p_product_id;

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

-- ── rpc_atomic_create_purchase ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    integer,
  p_description text DEFAULT NULL,
  p_date        date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_product         RECORD;
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

  SELECT id, stock, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- Insert purchase — use caller-supplied date (defaults to today)
  INSERT INTO purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_date)
  RETURNING id INTO v_purchase_id;

  UPDATE products SET stock = stock + p_quantity WHERE id = p_product_id;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- Re-grant EXECUTE with the updated signatures (idempotent — replaces old grant)
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, text, date)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, integer, text, date)      TO authenticated;
