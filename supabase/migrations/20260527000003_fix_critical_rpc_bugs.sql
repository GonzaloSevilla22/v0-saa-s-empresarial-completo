-- =============================================================================
-- MIGRATION: 20260527000003_fix_critical_rpc_bugs.sql
-- DESCRIPTION: Fixes 5 critical bugs identified in the architecture audit.
--
-- Fix 1 — rpc_stock_adjustment: physical_count race condition
--   Problem: client computed delta = newQty - stale_UI_stock. If a concurrent
--            sale changed the stock between UI render and submit, the delta
--            was wrong and physical_count produced an incorrect final stock.
--   Fix:    Add p_target_quantity (nullable). When set, the RPC computes the
--           delta AFTER acquiring the FOR UPDATE lock on the product row.
--           The old 6-arg signature is dropped to avoid overload ambiguity;
--           the new 7-arg function is backward-compatible via DEFAULT NULL.
--   Also:   Add stock_control_type validation (variant_only/untracked blocked).
--           Allow delta=0 for physical_count (records a "confirmation" event).
--
-- Fix 2 — rpc_atomic_create_sale + rpc_atomic_create_purchase: p_user_id spoofing
--   Problem: Neither RPC validated that p_user_id == auth.uid(). A caller could
--            pass a different user's UUID and have movements attributed to them.
--   Fix:    Reject if auth.uid() is set (client call) and differs from p_user_id.
--           Service-role edge functions have auth.uid() = NULL → skip check (trusted).
--
-- Fix 3 — rpc_atomic_create_sale: v_stock_remaining declared as integer
--   Problem: products.stock is NUMERIC(15,4) but v_stock_remaining was integer.
--            Fractional stock was silently truncated in the UPDATE and movement record.
--   Fix:    Redeclare v_stock_remaining as numeric.
--
-- Fix 4 — rpc_atomic_update_purchase_operation: reversal can produce negative stock
--   Problem: STEP 1 subtracts old purchase quantities without checking the result.
--            If post-purchase sales consumed most of the stock, reversal produces
--            stock < 0 in the DB — physically invalid.
--   Fix:    Check v_qty_after >= 0 after the RETURNING; raise a descriptive exception
--            that tells the user WHY the edit is blocked.
--
-- Fix 5 — rpc_atomic_update_sale_operation: sale_return movements have no reference_id
--   Problem: STEP 1 selected only (product_id, quantity) from old sales rows.
--            The resulting sale_return movement had no reference_id, making it
--            impossible to trace which sale was reversed.
--   Fix:    Add id to the STEP 1 cursor SELECT; pass it as reference_id in the INSERT.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1 — rpc_stock_adjustment: physical_count race condition + stockControlType guard
-- ─────────────────────────────────────────────────────────────────────────────

-- Drop old 6-arg signature to avoid ambiguous overload resolution.
-- The new function has the same 6 positional params plus p_target_quantity at end.
DROP FUNCTION IF EXISTS public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(
  p_product_id      uuid,
  p_quantity_delta  numeric  DEFAULT NULL,   -- signed delta for all types except physical_count
  p_type            text     DEFAULT 'adjustment',
  p_reason          text     DEFAULT NULL,
  p_notes           text     DEFAULT NULL,
  p_reference_id    uuid     DEFAULT NULL,
  p_target_quantity numeric  DEFAULT NULL    -- for physical_count: absolute stock target
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_product     RECORD;
  v_qty_before  numeric;
  v_qty_after   numeric;
  v_delta       numeric;   -- resolved final delta
  v_movement_id uuid;
BEGIN
  -- ── Auth ────────────────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Validate type ────────────────────────────────────────────────────────────
  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION 'Tipo de movimiento no válido para ajuste manual: %. '
      'Permitidos: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  -- ── Require at least one quantity input ──────────────────────────────────────
  IF p_quantity_delta IS NULL AND p_target_quantity IS NULL THEN
    RAISE EXCEPTION
      'Se requiere p_quantity_delta o p_target_quantity'
      USING ERRCODE = 'check_violation';
  END IF;

  -- ── Lock product row FIRST (must happen before computing delta for physical_count) ──
  SELECT id, stock, name, stock_control_type
  INTO   v_product
  FROM   public.products
  WHERE  id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- ── FIX 1 (new): block adjustments on non-trackable products ─────────────────
  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION
      'Este producto no permite ajuste manual de stock (stock_control_type = %). '
      'Los productos "variant_only" se gestionan a través de sus variantes; '
      'los "untracked" no tienen stock físico.',
      v_product.stock_control_type
      USING ERRCODE = 'check_violation';
  END IF;

  -- ── FIX 1 (core): resolve delta — physical_count computed from LOCKED stock ──
  -- This eliminates the race condition where client delta was computed on stale UI state.
  -- The delta is now computed AFTER acquiring the row lock, so it always reflects
  -- the true current stock at the moment of the adjustment.
  IF p_type = 'physical_count' AND p_target_quantity IS NOT NULL THEN
    v_delta := p_target_quantity - v_product.stock;
    -- delta = 0 is valid for physical_count: it confirms the stock is correct.
  ELSE
    v_delta := p_quantity_delta;
    -- Reject explicit zero delta for non-physical-count types.
    IF v_delta = 0 THEN
      RAISE EXCEPTION 'quantity_delta no puede ser cero para tipo %', p_type
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- ── Compute before / after ───────────────────────────────────────────────────
  v_qty_before := v_product.stock;
  v_qty_after  := v_product.stock + v_delta;

  -- ── Prevent negative stock ───────────────────────────────────────────────────
  IF v_qty_after < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(v_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- ── Apply stock change (no-op for delta=0 physical_count confirmation) ────────
  IF v_delta != 0 THEN
    UPDATE public.products
    SET    stock = v_qty_after
    WHERE  id = p_product_id AND user_id = v_uid;
  END IF;

  -- ── Record movement (always — even delta=0 physical_count is an audit event) ─
  INSERT INTO public.stock_movements (
    user_id, product_id, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type
  ) VALUES (
    v_uid, p_product_id, p_type,
    v_delta, v_qty_before, v_qty_after,
    p_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'quantity_before', v_qty_before,
    'quantity_after',  v_qty_after,
    'quantity_delta',  v_delta,
    'type',            p_type
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2 + FIX 3 — rpc_atomic_create_sale: p_user_id spoofing + integer truncation
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
  v_product           RECORD;
  v_sale_id           uuid;
  v_stock_remaining   numeric;   -- FIX 3: was integer, now numeric to preserve fractional stock
  v_existing_first_op uuid;
  v_sale_record       jsonb;
  v_qty_before        numeric;
BEGIN
  -- FIX 2: Prevent p_user_id spoofing on direct client calls.
  -- Service-role edge functions have auth.uid() = NULL and are trusted implicitly.
  IF auth.uid() IS NOT NULL AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: p_user_id does not match authenticated user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  SELECT id, stock INTO v_product
  FROM   products
  WHERE  id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_qty_before      := v_product.stock;
  v_stock_remaining := v_product.stock - p_quantity;   -- FIX 3: numeric arithmetic

  IF v_stock_remaining < 0 THEN
    RAISE EXCEPTION 'Insufficient stock (409). Available: %, Requested: %',
      v_product.stock, p_quantity USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_client_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_sale_id;

  UPDATE products
  SET    stock = v_stock_remaining
  WHERE  id = p_product_id;

  INSERT INTO public.stock_movements (
    user_id, product_id, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by
  ) VALUES (
    p_user_id, p_product_id, 'sale',
    -p_quantity, v_qty_before, v_stock_remaining,
    v_sale_id, 'sale', p_user_id
  );

  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created',
          jsonb_build_object('type', 'sale', 'sale_id', v_sale_id), DEFAULT);

  SELECT id INTO v_existing_first_op
  FROM   analytics_events
  WHERE  user_id = p_user_id AND event_name = 'first_operation'
  LIMIT  1;

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
-- FIX 2 — rpc_atomic_create_purchase: p_user_id spoofing
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
  v_product           RECORD;
  v_purchase_id       uuid;
  v_existing_first_op uuid;
  v_purchase_record   jsonb;
  v_qty_before        numeric;
  v_qty_after         numeric;
BEGIN
  -- FIX 2: Prevent p_user_id spoofing on direct client calls.
  IF auth.uid() IS NOT NULL AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: p_user_id does not match authenticated user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  SELECT id, stock INTO v_product
  FROM   products
  WHERE  id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_qty_before := v_product.stock;
  v_qty_after  := v_product.stock + p_quantity;

  INSERT INTO purchases (user_id, product_id, amount, quantity, date)
  VALUES (p_user_id, p_product_id, p_amount, p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  UPDATE products
  SET    stock = stock + p_quantity
  WHERE  id = p_product_id;

  INSERT INTO public.stock_movements (
    user_id, product_id, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by
  ) VALUES (
    p_user_id, p_product_id, 'purchase',
    p_quantity, v_qty_before, v_qty_after,
    v_purchase_id, 'purchase', p_user_id
  );

  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'operation_created',
          jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id), DEFAULT);

  SELECT id INTO v_existing_first_op
  FROM   analytics_events
  WHERE  user_id = p_user_id AND event_name = 'first_operation'
  LIMIT  1;

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
-- FIX 5 — rpc_atomic_update_sale_operation: sale_return missing reference_id
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(
  p_sale_ids  uuid[],
  p_client_id uuid,
  p_date      date,
  p_currency  text,
  p_items     jsonb
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
  v_qty_before   numeric;
  v_qty_after    numeric;
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
    WHERE  id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- FIX 5: select id (was missing) so we can set reference_id on the movement.
  FOR v_old_sale IN
    SELECT id, product_id, quantity         -- FIX 5: added `id`
    FROM   public.sales
    WHERE  id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      UPDATE public.products
      SET    stock = stock + v_old_sale.quantity
      WHERE  id = v_old_sale.product_id AND user_id = v_uid
      RETURNING
        stock - v_old_sale.quantity,  -- qty_before (old value before this update)
        stock                          -- qty_after  (new value after this update)
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id,        -- FIX 5: now populated with the reversed sale's id
        reference_type, notes, performed_by
      ) VALUES (
        v_uid, v_old_sale.product_id, 'sale_return',
        v_old_sale.quantity, v_qty_before, v_qty_after,
        v_old_sale.id,       -- FIX 5: traceable link to the original sale row
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
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
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

      UPDATE public.products
      SET    stock = stock - v_item.quantity
      WHERE  id = v_item.product_id
      RETURNING
        stock + v_item.quantity,  -- qty_before
        stock                      -- qty_after
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
-- FIX 4 — rpc_atomic_update_purchase_operation: reversal can produce negative stock
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(
  p_purchase_ids uuid[],
  p_date         date,
  p_description  text,
  p_items        jsonb
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
  v_qty_before      numeric;
  v_qty_after       numeric;
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
    WHERE  id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_purchase IN
    SELECT product_id, quantity
    FROM   public.purchases
    WHERE  id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      UPDATE public.products
      SET    stock = stock - v_old_purchase.quantity
      WHERE  id = v_old_purchase.product_id AND user_id = v_uid
      RETURNING
        stock + v_old_purchase.quantity,  -- qty_before
        stock                              -- qty_after
      INTO v_qty_before, v_qty_after;

      -- FIX 4: Block the edit if reversing this purchase would drive stock negative.
      -- This happens when post-purchase sales have consumed more units than remain.
      -- The transaction is rolled back automatically by the RAISE EXCEPTION.
      IF v_qty_after IS NOT NULL AND v_qty_after < 0 THEN
        RAISE EXCEPTION
          'No se puede modificar esta compra: revertirla dejaría el stock de este '
          'producto en % unidades. Hay ventas o ajustes posteriores que consumen '
          'las unidades compradas en esa operación. Anulá esas operaciones primero.',
          v_qty_after
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

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
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
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

      UPDATE public.products
      SET    stock = stock + v_item.quantity
      WHERE  id = v_item.product_id
      RETURNING
        stock - v_item.quantity,  -- qty_before
        stock                      -- qty_after
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
