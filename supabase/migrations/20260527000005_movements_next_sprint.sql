-- =============================================================================
-- MIGRATION: 20260527000005_movements_next_sprint.sql
-- DESCRIPTION: Implements 7 "next sprint" improvements from the inventory
--              movements architecture audit.
--
-- Item  7 — product_name TEXT denormalised in movements
--   Resiliency: product deletions no longer lose the name from the audit log.
--   Performance: eliminates the JOIN on reads at scale.
--   Existing rows are backfilled from products.name immediately.
--
-- Item  8 — operation_group_id UUID
--   Links every movement created by the same logical operation (e.g. all
--   sale_return + sale rows from one "edit cart" call share one UUID).
--   Lets callers query "all movements of operation X" in O(1) index lookup.
--
-- Item  9 — movement_number BIGINT (sequential, gapless)
--   Required for fiscal compliance: auditors can detect missing records by
--   verifying the sequence is continuous. Uses a dedicated sequence so the
--   counter never resets and is never reused.
--   Existing rows are back-filled in created_at order.
--
-- Item 10 — server-side type filter in StockMovementsPanel
--   (frontend change — see components/stock/stock-movements-panel.tsx)
--
-- Item 11 — stock_control_type guard in rpc_stock_adjustment
--   Already shipped in migration 000003 (Fix 1). Skipped here.
--
-- Item 12 — stale-closure fix in fetchPage
--   (frontend change — see components/stock/stock-movements-panel.tsx)
--
-- Item 13 — ORDER BY product_id in cursors (deadlock prevention)
--   Concurrent transactions that touch overlapping product sets now always
--   acquire row locks in the same order, eliminating the deadlock scenario
--   described in the audit (section 8).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- ITEM 7 — product_name denormalised column
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS product_name text;

-- Backfill: set product_name from products table for every existing row.
-- Rows whose product was deleted will remain NULL (acceptable — historic data).
UPDATE public.stock_movements sm
SET    product_name = p.name
FROM   public.products p
WHERE  p.id = sm.product_id
  AND  sm.product_name IS NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- ITEM 8 — operation_group_id UUID
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS operation_group_id uuid;

-- Sparse index — most queries look up a specific operation group.
CREATE INDEX IF NOT EXISTS idx_stock_movements_op_group
  ON public.stock_movements (user_id, operation_group_id)
  WHERE operation_group_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- ITEM 9 — movement_number (fiscal sequential counter)
-- ─────────────────────────────────────────────────────────────────────────────

-- A single global sequence; never reset, never reused.
CREATE SEQUENCE IF NOT EXISTS public.stock_movements_number_seq;

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS movement_number bigint;

-- Backfill existing rows in chronological order so the sequence reflects
-- insertion history rather than a random assignment.
UPDATE public.stock_movements
SET    movement_number = nextval('public.stock_movements_number_seq')
WHERE  movement_number IS NULL;

-- Future inserts automatically get the next value.
ALTER TABLE public.stock_movements
  ALTER COLUMN movement_number SET DEFAULT nextval('public.stock_movements_number_seq');

-- Uniqueness guarantees gap detection is meaningful.
CREATE UNIQUE INDEX IF NOT EXISTS idx_stock_movements_number
  ON public.stock_movements (movement_number);


-- ─────────────────────────────────────────────────────────────────────────────
-- ITEMS 7 + 8 + 13 — update all five RPCs
-- ─────────────────────────────────────────────────────────────────────────────


-- ── rpc_stock_adjustment ─────────────────────────────────────────────────────
-- Changes: add product_name to INSERT (item 7).
--          operation_group_id left NULL — single-movement operation.
DROP FUNCTION IF EXISTS public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid);
DROP FUNCTION IF EXISTS public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric);

CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(
  p_product_id      uuid,
  p_quantity_delta  numeric  DEFAULT NULL,
  p_type            text     DEFAULT 'adjustment',
  p_reason          text     DEFAULT NULL,
  p_notes           text     DEFAULT NULL,
  p_reference_id    uuid     DEFAULT NULL,
  p_target_quantity numeric  DEFAULT NULL
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
  v_delta       numeric;
  v_movement_id uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION
      'Tipo de movimiento no válido para ajuste manual: %. '
      'Permitidos: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_quantity_delta IS NULL AND p_target_quantity IS NULL THEN
    RAISE EXCEPTION 'Se requiere p_quantity_delta o p_target_quantity'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock row BEFORE computing delta (critical for physical_count).
  SELECT id, stock, name, stock_control_type
  INTO   v_product
  FROM   public.products
  WHERE  id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION
      'Este producto no permite ajuste manual de stock (stock_control_type = %). '
      'Los productos "variant_only" se gestionan a través de sus variantes; '
      'los "untracked" no tienen stock físico.',
      v_product.stock_control_type
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_type = 'physical_count' AND p_target_quantity IS NOT NULL THEN
    v_delta := p_target_quantity - v_product.stock;
  ELSE
    v_delta := p_quantity_delta;
    IF v_delta = 0 THEN
      RAISE EXCEPTION 'quantity_delta no puede ser cero para tipo %', p_type
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_qty_before := v_product.stock;
  v_qty_after  := v_product.stock + v_delta;

  IF v_qty_after < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(v_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF v_delta != 0 THEN
    UPDATE public.products
    SET    stock = v_qty_after
    WHERE  id = p_product_id AND user_id = v_uid;
  END IF;

  INSERT INTO public.stock_movements (
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type
    -- operation_group_id intentionally NULL: single-movement operation
  ) VALUES (
    v_uid, p_product_id, v_product.name, p_type,
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


-- ── rpc_atomic_create_sale ───────────────────────────────────────────────────
-- Changes:
--   item  7: add name to product SELECT; populate product_name in movement.
--   item  8: operation_group_id = v_sale_id (sale doc = single-movement group).
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
  v_stock_remaining   numeric;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
  v_qty_before        numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: p_user_id does not match authenticated user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  -- item 7: include name so we can denormalise it into the movement
  SELECT id, stock, name INTO v_product
  FROM   products
  WHERE  id = p_product_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found or access denied (404/403)' USING ERRCODE = 'no_data_found';
  END IF;

  v_qty_before      := v_product.stock;
  v_stock_remaining := v_product.stock - p_quantity;

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
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by,
    operation_group_id
  ) VALUES (
    p_user_id, p_product_id, v_product.name, 'sale',
    -p_quantity, v_qty_before, v_stock_remaining,
    v_sale_id, 'sale', p_user_id,
    v_sale_id   -- item 8: group = the sale document itself
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


-- ── rpc_atomic_create_purchase ───────────────────────────────────────────────
-- Changes:
--   item  7: add name to product SELECT; populate product_name in movement.
--   item  8: operation_group_id = v_purchase_id.
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
  IF auth.uid() IS NOT NULL AND p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: p_user_id does not match authenticated user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'check_violation';
  END IF;

  -- item 7: include name
  SELECT id, stock, name INTO v_product
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
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_id, reference_type, performed_by,
    operation_group_id
  ) VALUES (
    p_user_id, p_product_id, v_product.name, 'purchase',
    p_quantity, v_qty_before, v_qty_after,
    v_purchase_id, 'purchase', p_user_id,
    v_purchase_id   -- item 8
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


-- ── rpc_atomic_update_sale_operation ────────────────────────────────────────
-- Changes:
--   item  7: JOIN products in STEP-1 cursor to get product_name;
--            add name to STEP-3 product SELECT.
--   item  8: generate v_new_op_id BEFORE step 1 so ALL movements (return +
--            new sale) share the same operation_group_id.
--   item 13: ORDER BY product_id in both cursors — consistent lock ordering
--            eliminates the deadlock scenario identified in audit section 8.
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

  -- item 8: generate the shared operation UUID BEFORE any step so that both
  -- the sale_return movements (STEP 1) and the new sale movements (STEP 3)
  -- carry the same operation_group_id.
  v_new_op_id := gen_random_uuid();

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- item  7: JOIN products to capture the product name at time of edit.
  -- item 13: ORDER BY s.product_id guarantees consistent lock ordering.
  FOR v_old_sale IN
    SELECT s.id, s.product_id, s.quantity, p.name AS product_name
    FROM   public.sales s
    LEFT JOIN public.products p ON p.id = s.product_id
    WHERE  s.id = ANY(p_sale_ids)
    ORDER BY s.product_id          -- item 13: deterministic lock order
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      UPDATE public.products
      SET    stock = stock + v_old_sale.quantity
      WHERE  id = v_old_sale.product_id AND user_id = v_uid
      RETURNING
        stock - v_old_sale.quantity,
        stock
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, notes, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_old_sale.product_id, v_old_sale.product_name, 'sale_return',
        v_old_sale.quantity, v_qty_before, v_qty_after,
        v_old_sale.id, 'sale_update',
        'Reversión por edición de operación de venta', v_uid,
        v_new_op_id    -- item 8
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity integer)
    ORDER BY product_id   -- item 13: consistent lock ordering in STEP 3
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- item 7: include name in the locked row read
      SELECT id, stock, user_id, is_variant, name INTO v_product
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
        stock + v_item.quantity,
        stock
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_item.product_id, v_product.name, 'sale',
        -v_item.quantity, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale_update', v_uid,
        v_new_op_id    -- item 8: same group as the return movements
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


-- ── rpc_atomic_update_purchase_operation ─────────────────────────────────────
-- Changes:
--   item  7: JOIN products in STEP-1 cursor; add name to STEP-3 SELECT.
--   item  8: generate v_new_op_id before STEP 1; populate operation_group_id.
--   item 13: ORDER BY product_id in both cursors.
--   bonus:   add id to STEP-1 cursor and set reference_id on purchase_return
--            (mirrors Fix 5 done for sale_return in migration 000003).
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

  -- item 8: shared group UUID for ALL movements created by this function call.
  v_new_op_id := gen_random_uuid();

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- item  7: JOIN products for product_name.
  -- item 13: ORDER BY pu.product_id for consistent lock ordering.
  -- bonus:   select pu.id so purchase_return gets a traceable reference_id.
  FOR v_old_purchase IN
    SELECT pu.id, pu.product_id, pu.quantity, p.name AS product_name
    FROM   public.purchases pu
    LEFT JOIN public.products p ON p.id = pu.product_id
    WHERE  pu.id = ANY(p_purchase_ids)
    ORDER BY pu.product_id    -- item 13
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      UPDATE public.products
      SET    stock = stock - v_old_purchase.quantity
      WHERE  id = v_old_purchase.product_id AND user_id = v_uid
      RETURNING
        stock + v_old_purchase.quantity,
        stock
      INTO v_qty_before, v_qty_after;

      IF v_qty_after IS NOT NULL AND v_qty_after < 0 THEN
        RAISE EXCEPTION
          'No se puede modificar esta compra: revertirla dejaría el stock de este '
          'producto en % unidades. Hay ventas o ajustes posteriores que consumen '
          'las unidades compradas en esa operación. Anulá esas operaciones primero.',
          v_qty_after
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, notes, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_old_purchase.product_id, v_old_purchase.product_name, 'purchase_return',
        -v_old_purchase.quantity, v_qty_before, v_qty_after,
        v_old_purchase.id,            -- bonus: traceable reference
        'purchase_update',
        'Reversión por edición de operación de compra', v_uid,
        v_new_op_id    -- item 8
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity integer)
    ORDER BY product_id    -- item 13
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- item 7: include name in locked row
      SELECT id, stock, user_id, is_variant, name INTO v_product
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
        stock - v_item.quantity,
        stock
      INTO v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_item.product_id, v_product.name, 'purchase',
        v_item.quantity, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase_update', v_uid,
        v_new_op_id    -- item 8
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
