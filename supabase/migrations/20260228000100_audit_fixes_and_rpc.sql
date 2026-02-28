-- =======================================================================================
-- MIGRATION: 20260228000100_audit_fixes_and_rpc.sql
-- DESCRIPTION: Atomic Transactions, Concurrency Locks, and GIN Index
-- =======================================================================================

-- 1. Analytics Optimization: Add GIN index on analytics_events.event_data
CREATE INDEX IF NOT EXISTS idx_analytics_events_event_data_gin 
ON public.analytics_events USING GIN (event_data);

-- ---------------------------------------------------------------------------------------
-- 2. Atomic RPC for Create Sale
-- Combines checking auth/limit, deducting stock, inserting sale, and logging events.
-- ---------------------------------------------------------------------------------------
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


-- ---------------------------------------------------------------------------------------
-- 3. Atomic RPC for Create Purchase
-- Combines checking auth/limit, increasing stock (or creating expense), inserting purchase.
-- ---------------------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------------------
-- 4. Atomic RPC for AI Insights Usage Tracking
-- Locks profile, checks limits, updates usage, inserts insight, records analytics.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(
  p_user_id uuid,
  p_type text,
  p_content text,
  p_source_function text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile RECORD;
  v_insight_id uuid;
  v_insight_record jsonb;
BEGIN
  -- Lock profile to avoid racing usage limits
  SELECT id, plan, insights_used, insights_reset_at INTO v_profile
  FROM profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found (404)' USING ERRCODE = 'no_data_found';
  END IF;

  -- Check limits dynamically natively
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan (403)' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1) Insert Insight (Server-Side timestamp)
  INSERT INTO insights (user_id, type, content, actionable)
  VALUES (p_user_id, p_type, p_content, 'actionable_extracted_from_content')
  RETURNING id INTO v_insight_id;

  -- 2) Increment Usage Safe
  UPDATE profiles
  SET insights_used = insights_used + 1
  WHERE id = p_user_id;

  -- 3) Telemetry (UMV logic tracking)
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'insight_generated', jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id), DEFAULT);

  -- 4) Check if UMV Reached contextually
  -- A user reaches UMV when they have both an 'insight_generated' and 'operation_created'
  IF EXISTS (
    SELECT 1 FROM analytics_events 
    WHERE user_id = p_user_id AND event_name = 'operation_created'
  ) AND NOT EXISTS (
    SELECT 1 FROM analytics_events 
    WHERE user_id = p_user_id AND event_name = 'umv_reached'
  ) THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'umv_reached', jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id), DEFAULT);
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$$;
