-- =============================================================================
-- MIGRATION: 20260527000002_wire_movements_to_rpcs.sql
-- DESCRIPTION: Wire stock_movements inserts into all four atomic RPCs so that
--              every stock change is automatically recorded in the audit log.
--
-- RPCs updated:
--   1. rpc_atomic_create_sale       — records type='sale'     (negative delta)
--   2. rpc_atomic_create_purchase   — records type='purchase' (positive delta)
--   3. rpc_atomic_update_sale_operation     — records 'sale_return' on reverse,
--                                             'sale' on each new item
--   4. rpc_atomic_update_purchase_operation — records 'purchase_return' on reverse,
--                                             'purchase' on each new item
--
-- Design:
--   - quantity_before and quantity_after are tracked for every movement.
--   - For UPDATE operations, the RETURNING clause extracts before/after from
--     the single atomic UPDATE without an extra SELECT round-trip.
--   - All inserts run inside the same transaction as the stock mutation,
--     so movement records are ALWAYS consistent with product.stock.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. rpc_atomic_create_sale — adds movement record after stock deduction
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product        RECORD;
  v_sale_id        uuid;
  v_stock_remaining integer;
  v_existing_first_op uuid;
  v_sale_record    jsonb;
  v_qty_before     numeric;   -- NEW: for movement record
BEGIN
  -- Strict input validation
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  -- Verify product exists, belongs to user, and lock the row for update
  SELECT id, stock INTO v_product
  FROM products
  WHERE id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_qty_before      := v_product.stock;        -- capture before
  v_stock_remaining := v_product.stock - p_quantity;

  IF v_stock_remaining < 0 THEN
    RAISE EXCEPTION 'Insufficient stock (409). Available: %, Requested: %',
      v_product.stock, p_quantity USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- 1) Insert Sale
  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_client_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_sale_id;

  -- 2) Update Stock
  UPDATE products
  SET stock = v_stock_remaining
  WHERE id = p_product_id;

  -- 3) Record movement
  INSERT INTO public.stock_movements (
    user_id, product_id, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by
  ) VALUES (
    p_user_id, p_product_id, 'sale',
    -p_quantity, v_qty_before, v_stock_remaining,
    v_sale_id, 'sale', p_user_id
  );

  -- 4) Fire Analytics Events
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created',
          jsonb_build_object('type', 'sale', 'sale_id', v_sale_id), DEFAULT);

  SELECT id INTO v_existing_first_op
  FROM analytics_events
  WHERE user_id = p_user_id AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'first_operation',
            jsonb_build_object('type', 'sale', 'sale_id', v_sale_id), DEFAULT);
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rpc_atomic_create_purchase — adds movement record after stock addition
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product        RECORD;
  v_purchase_id    uuid;
  v_existing_first_op uuid;
  v_purchase_record jsonb;
  v_qty_before     numeric;   -- NEW: for movement record
  v_qty_after      numeric;   -- NEW: for movement record
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  SELECT id, stock INTO v_product
  FROM products
  WHERE id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_qty_before := v_product.stock;
  v_qty_after  := v_product.stock + p_quantity;

  -- 1) Insert Purchase
  INSERT INTO purchases (user_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  -- 2) Update Stock
  UPDATE products
  SET stock = stock + p_quantity
  WHERE id = p_product_id;

  -- 3) Record movement
  INSERT INTO public.stock_movements (
    user_id, product_id, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by
  ) VALUES (
    p_user_id, p_product_id, 'purchase',
    p_quantity, v_qty_before, v_qty_after,
    v_purchase_id, 'purchase', p_user_id
  );

  -- 4) Fire Analytics
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created',
          jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id), DEFAULT);

  SELECT id INTO v_existing_first_op
  FROM analytics_events
  WHERE user_id = p_user_id AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'first_operation',
            jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id), DEFAULT);
  END IF;

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. rpc_atomic_update_sale_operation — records sale_return (reverse) + sale (new)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(
  p_sale_ids  uuid[],
  p_client_id uuid,
  p_date      date,
  p_currency  text,
  p_items     jsonb    -- [{product_id uuid, amount numeric, quantity integer}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_old_sale     RECORD;
  v_item         RECORD;
  v_product      RECORD;
  v_new_op_id    uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;   -- NEW: for movement records
  v_qty_after    numeric;   -- NEW: for movement records
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- Restore stock for original sale items and record 'sale_return' movements.
  -- RETURNING captures before/after without an extra SELECT.
  FOR v_old_sale IN
    SELECT product_id, quantity
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      UPDATE public.products
      SET stock = stock + v_old_sale.quantity
      WHERE id = v_old_sale.product_id AND user_id = v_uid
      RETURNING
        stock - v_old_sale.quantity,   -- old value (before this update)
        stock                           -- new value (after this update)
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, type,
        quantity_delta, quantity_before, quantity_after,
        reference_type, notes, performed_by
      ) VALUES (
        v_uid, v_old_sale.product_id, 'sale_return',
        v_old_sale.quantity, v_qty_before, v_qty_after,
        'sale_update', 'Reversión por edición de operación de venta', v_uid
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      IF v_product.stock < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;

      -- Deduct stock and capture before/after via RETURNING
      UPDATE public.products
      SET stock = stock - v_item.quantity
      WHERE id = v_item.product_id
      RETURNING
        stock + v_item.quantity,   -- old value (before deduction)
        stock                       -- new value (after deduction)
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by
      ) VALUES (
        v_uid, v_item.product_id, 'sale',
        -v_item.quantity, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale_update', v_uid
      );

    ELSE
      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) FROM anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. rpc_atomic_update_purchase_operation — records purchase_return + purchase
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(
  p_purchase_ids uuid[],
  p_date         date,
  p_description  text,
  p_items        jsonb    -- [{product_id uuid, amount numeric, quantity integer}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_old_purchase    RECORD;
  v_item            RECORD;
  v_product         RECORD;
  v_new_op_id       uuid;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;   -- NEW: for movement records
  v_qty_after       numeric;   -- NEW: for movement records
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchases
    WHERE id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- Undo stock from original purchase items, record 'purchase_return' movements.
  FOR v_old_purchase IN
    SELECT product_id, quantity
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      UPDATE public.products
      SET stock = stock - v_old_purchase.quantity
      WHERE id = v_old_purchase.product_id AND user_id = v_uid
      RETURNING
        stock + v_old_purchase.quantity,   -- old value (before subtraction)
        stock                               -- new value (after subtraction)
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, type,
        quantity_delta, quantity_before, quantity_after,
        reference_type, notes, performed_by
      ) VALUES (
        v_uid, v_old_purchase.product_id, 'purchase_return',
        -v_old_purchase.quantity, v_qty_before, v_qty_after,
        'purchase_update', 'Reversión por edición de operación de compra', v_uid
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      INSERT INTO public.purchases
        (user_id, product_id, amount, quantity, total, description, date, operation_id)
      VALUES
        (v_uid, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      -- Add stock and capture before/after via RETURNING
      UPDATE public.products
      SET stock = stock + v_item.quantity
      WHERE id = v_item.product_id
      RETURNING
        stock - v_item.quantity,   -- old value (before addition)
        stock                       -- new value (after addition)
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by
      ) VALUES (
        v_uid, v_item.product_id, 'purchase',
        v_item.quantity, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase_update', v_uid
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, product_id, amount, quantity, total, description, date, operation_id)
      VALUES
        (v_uid, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$$;

GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb) FROM anon;
