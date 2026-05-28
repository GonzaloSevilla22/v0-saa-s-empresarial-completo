-- =============================================================================
-- MIGRATION: 20260528000002_rpc_create_operation_aggregate.sql
-- DESCRIPTION: Atomic, idempotent, multi-item CREATE for sales and purchases.
--
-- WHY (the three orthogonal problems this closes):
--   1. Idempotency — a double-submit / retry / browser-resend with the same
--      idempotency_key now resolves to ONE operation. The key is claimed inside
--      the same transaction (operation_idempotency), so it commits/rolls-back
--      atomically with the operation: no orphan locks, no processing state.
--   2. CREATE multi-item atomicity — the entire cart is one transaction. Either
--      every line + stock change + movement commits, or none does. This replaces
--      the frontend `for (item of cart) await createSale(item)` loop that could
--      leave a sale half-applied.
--   3. Overload drift — this is a NEW function name. It does not collide with
--      the rpc_atomic_create_sale/purchase overloads (verified live: a 5-arg
--      and a 7-arg sale overload coexist; production resolves to the 7-arg one,
--      so the entire "inventory movements v2" work that updated the 5-arg
--      overload is dead code). A new name is resolved unambiguously by PostgREST.
--
-- PARITY WITH THE LIVE PRODUCTION PATH (verified via pg_get_functiondef):
--   The live 7-arg rpc_atomic_create_sale normalizes quantity by the unit factor
--   (units_of_measure.factor) before touching stock, and stores the RAW quantity
--   + unit_id on the sale row. This RPC preserves that exact behaviour per line,
--   so migrating callers does NOT regress unit-of-measure support.
--
-- SUPERIORITY OVER BOTH LIVE OVERLOADS:
--   The live path writes a thin movement (type, delta, reference only). This RPC
--   writes the FULL ERP-grade audit columns the movements_next_sprint migration
--   intended but never reached in production: quantity_before, quantity_after,
--   product_name, performed_by, and operation_group_id (the shared operation id).
--
-- REPLAY SEMANTICS (must be correct or it corrupts inventory):
--   The idempotency row is claimed with INSERT ... ON CONFLICT DO NOTHING.
--   - Row created (ROW_COUNT = 1) → first execution → apply all items once.
--   - Conflict (ROW_COUNT = 0) → a prior execution owns this key → reconstruct
--     and return the ORIGINAL aggregate WITHOUT touching stock. Two concurrent
--     calls with the same key serialize on the unique index: the loser blocks
--     until the winner commits, then takes the replay branch. If the winner
--     rolls back, the loser's INSERT succeeds and becomes the first execution.
--
-- LOCK ORDERING:
--   Items processed ORDER BY product_id (same as the update RPC) so concurrent
--   operations touching overlapping products lock rows in a consistent order.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- rpc_create_sale_operation — atomic idempotent multi-item sale
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
  p_idempotency_key text,
  p_client_id       uuid,
  p_date            date,
  p_currency        text,
  p_items           jsonb    -- [{product_id uuid|null, amount numeric, quantity numeric, unit_id uuid|null}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_unit_factor  numeric(20,10);
  v_qty_norm     numeric(15,4);
  v_inserted     integer;
BEGIN
  -- ── Auth ─────────────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Input validation ─────────────────────────────────────────────────────
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  -- ── Idempotency claim (atomic, inside this transaction) ──────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- ── REPLAY: key already used → return the ORIGINAL aggregate, no stock ───
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid AND idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  -- ── FIRST EXECUTION: apply every line atomically ─────────────────────────
  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id     -- deterministic lock order → no deadlocks
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    -- Resolve unit factor → normalized quantity (stock is always in base units).
    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id <> v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      -- A non-variant parent that HAS variants cannot be sold directly.
      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      IF v_product.stock < v_qty_norm THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      -- RAW quantity + unit_id stored on the sale; stock moves by NORMALIZED qty.
      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;

      UPDATE public.products
      SET    stock = stock - v_qty_norm
      WHERE  id = v_item.product_id
      RETURNING stock + v_qty_norm, stock
      INTO   v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id
      );

    ELSE
      -- Service / non-stock line (no product): no stock, no movement.
      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- rpc_create_purchase_operation — atomic idempotent multi-item purchase
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key text,
  p_date            date,
  p_description     text,
  p_items           jsonb    -- [{product_id uuid|null, amount numeric, quantity numeric, unit_id uuid|null}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_inserted        integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
  ON CONFLICT (user_id, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- ── REPLAY ───────────────────────────────────────────────────────────────
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid AND idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.purchases p
    WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  -- ── FIRST EXECUTION ────────────────────────────────────────────────────────
  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id <> v_uid THEN
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
        (user_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      UPDATE public.products
      SET    stock = stock + v_qty_norm
      WHERE  id = v_item.product_id
      RETURNING stock - v_qty_norm, stock
      INTO   v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_item.product_id, v_product.name, 'purchase',
        v_qty_norm, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase', v_uid,
        v_new_op_id
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) TO authenticated;
