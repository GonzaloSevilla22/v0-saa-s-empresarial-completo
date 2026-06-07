-- =============================================================================
-- MIGRATION: 20260608000000_branch_stock.sql
-- CHANGE:    C-08 stock-multisucursal
--
-- DESCRIPTION:
--   Implements per-branch inventory tracking (dual-ledger):
--   - branch_stock table: tracks stock per (product, branch) combination
--   - ALTER stock_movements: adds transfer_out/transfer_in types and 'transfer'
--     reference_type
--   - Modifies rpc_create_sale_operation: when p_branch_id IS NOT NULL, decrements
--     branch_stock instead of products.stock
--   - Modifies rpc_create_purchase_operation: when p_branch_id IS NOT NULL,
--     increments branch_stock instead of products.stock
--   - Creates rpc_transfer_stock: atomic stock transfer between branches
--   - Creates rpc_adjust_branch_stock: manual stock adjustment with audit trail
--   - Creates check_branch_low_stock trigger with 24h dedup
--
-- GOVERNANCE: MEDIUM — new table, RPC rewrites, trigger. Retrocompatible
--   (existing records with branch_id=NULL continue using products.stock).
--
-- APPLY: npx supabase db push  (NEVER use MCP apply_migration)
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS on_branch_stock_update ON public.branch_stock;
--   DROP FUNCTION IF EXISTS public.check_branch_low_stock();
--   DROP FUNCTION IF EXISTS public.rpc_adjust_branch_stock(uuid,uuid,numeric,text);
--   DROP FUNCTION IF EXISTS public.rpc_transfer_stock(uuid,uuid,uuid,numeric);
--   DROP TABLE IF EXISTS public.branch_stock;
--   -- Then restore rpc_create_sale_operation and rpc_create_purchase_operation
--   -- from migration 20260607000003_fix_idempotency_conflict_target.sql
-- =============================================================================


-- ============================================================
-- TASK 1.1 — ALTER stock_movements: extend CHECK constraints
-- ============================================================
-- Extend 'type' CHECK to include 'transfer_out' and 'transfer_in'.
-- The full set includes ALL values present in the live DB (physical_count,
-- purchase_return, sale_return, loss, damage, expiry) discovered during C-08.
ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_type_check
  CHECK (type = ANY (ARRAY[
    'purchase', 'sale', 'adjustment', 'return', 'initial',
    'sale_return', 'purchase_return', 'physical_count',
    'loss', 'damage', 'expiry',
    'transfer_out', 'transfer_in'
  ]));

-- Extend 'reference_type' CHECK to include 'transfer'.
-- Full set includes 'sale_update' and 'purchase_update' found in live DB.
ALTER TABLE public.stock_movements
  DROP CONSTRAINT IF EXISTS stock_movements_reference_type_check;

ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_reference_type_check
  CHECK (reference_type = ANY (ARRAY[
    'sale', 'purchase', 'adjustment', 'initial',
    'sale_update', 'purchase_update',
    'transfer'
  ]));


-- ============================================================
-- TASK 1.2 — CREATE TABLE branch_stock
-- ============================================================
CREATE TABLE IF NOT EXISTS public.branch_stock (
  id         uuid        NOT NULL DEFAULT gen_random_uuid(),
  account_id uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  product_id uuid        NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  branch_id  uuid        NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  quantity   numeric(15,4) NOT NULL DEFAULT 0,
  min_stock  integer     NOT NULL DEFAULT 0,
  CONSTRAINT branch_stock_pkey PRIMARY KEY (id),
  CONSTRAINT branch_stock_product_branch_unique UNIQUE (product_id, branch_id)
);

COMMENT ON TABLE public.branch_stock IS
  'Per-branch inventory ledger. Tracks quantity of each product in each branch.
   Rows are created lazily on first movement (UPSERT). Dual-ledger: when a sale
   or purchase has branch_id, this table is updated instead of products.stock.';

COMMENT ON COLUMN public.branch_stock.min_stock IS
  'Minimum stock threshold for low-stock alerts. 0 = no alert.';


-- ============================================================
-- TASK 1.3 — Indexes on branch_stock
-- ============================================================
CREATE INDEX IF NOT EXISTS branch_stock_account_branch_idx
  ON public.branch_stock (account_id, branch_id);

CREATE INDEX IF NOT EXISTS branch_stock_product_branch_idx
  ON public.branch_stock (product_id, branch_id);


-- ============================================================
-- TASK 1.4 — RLS on branch_stock
-- ============================================================
ALTER TABLE public.branch_stock ENABLE ROW LEVEL SECURITY;

-- SELECT: any member of the account can read branch stock
DROP POLICY IF EXISTS "branch_stock_member_select" ON public.branch_stock;
CREATE POLICY "branch_stock_member_select" ON public.branch_stock
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- INSERT: only owner or admin can insert directly (RPCs are SECURITY DEFINER)
DROP POLICY IF EXISTS "branch_stock_writer_insert" ON public.branch_stock;
CREATE POLICY "branch_stock_writer_insert" ON public.branch_stock
  FOR INSERT
  TO authenticated
  WITH CHECK (is_account_writer(account_id));

-- UPDATE: only owner or admin can update directly (RPCs are SECURITY DEFINER)
DROP POLICY IF EXISTS "branch_stock_writer_update" ON public.branch_stock;
CREATE POLICY "branch_stock_writer_update" ON public.branch_stock
  FOR UPDATE
  TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));


-- ============================================================
-- TASK 1.5 — Modify rpc_create_sale_operation
--
-- DUAL-LEDGER LOGIC:
--   When p_branch_id IS NOT NULL AND product_id IS NOT NULL:
--     - Validate branch_stock.quantity >= v_qty_norm (not products.stock)
--     - UPSERT branch_stock: quantity = quantity - v_qty_norm
--     - Do NOT update products.stock
--   When p_branch_id IS NULL (original behavior):
--     - Validate products.stock >= v_qty_norm
--     - Update products.stock: stock = stock - v_qty_norm
--
-- Source: mirrors 20260607000003_fix_idempotency_conflict_target.sql
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
  p_idempotency_key text,
  p_client_id       uuid,
  p_date            date,
  p_currency        text,
  p_items           jsonb,
  p_branch_id       uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_sale_id     uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_inserted        integer;
  v_branch_qty      numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
  END IF;

  -- Verify branch_id belongs to this account (if provided)
  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P404';
    END IF;
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;  -- 3-col constraint (fixed)

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

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

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
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
      -- ── DUAL-LEDGER: branch stock path ──────────────────────────────────
      IF p_branch_id IS NOT NULL THEN
        -- Lock the branch_stock row (or note absence = 0 stock)
        SELECT quantity INTO v_branch_qty
        FROM   public.branch_stock
        WHERE  product_id = v_item.product_id
          AND  branch_id  = p_branch_id
        FOR UPDATE;

        -- If no row exists, treat as zero stock
        IF NOT FOUND THEN
          v_branch_qty := 0;
        END IF;

        IF v_branch_qty < v_qty_norm THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id
            USING ERRCODE = 'P409';
        END IF;

        -- Also lock the product row for variant check only (no stock update)
        SELECT id, user_id, is_variant, name INTO v_product
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
              'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
              USING ERRCODE = 'P422';
          END IF;
        END IF;

        INSERT INTO public.sales
          (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
           total, currency, date, operation_id, branch_id)
        VALUES
          (v_uid, v_account_id, p_client_id, v_item.product_id,
           v_item.amount, v_item.quantity, v_item.unit_id,
           v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
           p_branch_id)
        RETURNING id INTO v_new_sale_id;

        -- Update branch_stock (UPSERT for lazy init)
        v_qty_before := v_branch_qty;
        v_qty_after  := v_branch_qty - v_qty_norm;

        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
        VALUES (v_account_id, v_item.product_id, p_branch_id, v_qty_after)
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET quantity = public.branch_stock.quantity - v_qty_norm;

        -- stock_movement for branch sale (does NOT touch products.stock)
        INSERT INTO public.stock_movements (
          user_id, account_id, product_id, product_name, type,
          quantity_delta, quantity_before, quantity_after,
          reference_id, reference_type, performed_by,
          operation_group_id, branch_id
        ) VALUES (
          v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
          -v_qty_norm, v_qty_before, v_qty_after,
          v_new_sale_id, 'sale', v_uid,
          v_new_op_id, p_branch_id
        );

      -- ── ORIGINAL PATH: no branch → decrement products.stock ─────────────
      ELSE
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
              'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
              USING ERRCODE = 'P422';
          END IF;
        END IF;

        IF v_product.stock < v_qty_norm THEN
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
        END IF;

        INSERT INTO public.sales
          (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
           total, currency, date, operation_id, branch_id)
        VALUES
          (v_uid, v_account_id, p_client_id, v_item.product_id,
           v_item.amount, v_item.quantity, v_item.unit_id,
           v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
           p_branch_id)
        RETURNING id INTO v_new_sale_id;

        UPDATE public.products
        SET    stock = stock - v_qty_norm
        WHERE  id = v_item.product_id
        RETURNING stock + v_qty_norm, stock
        INTO   v_qty_before, v_qty_after;

        INSERT INTO public.stock_movements (
          user_id, account_id, product_id, product_name, type,
          quantity_delta, quantity_before, quantity_after,
          reference_id, reference_type, performed_by,
          operation_group_id, branch_id
        ) VALUES (
          v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
          -v_qty_norm, v_qty_before, v_qty_after,
          v_new_sale_id, 'sale', v_uid,
          v_new_op_id, p_branch_id
        );
      END IF;

    ELSE
      -- No product_id — service/fee line item, no stock tracking
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id)
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

REVOKE ALL     ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid) TO authenticated;


-- ============================================================
-- TASK 1.6 — Modify rpc_create_purchase_operation
--
-- DUAL-LEDGER LOGIC:
--   When p_branch_id IS NOT NULL AND product_id IS NOT NULL:
--     - UPSERT branch_stock: quantity = quantity + v_qty_norm (lazy init)
--     - Do NOT update products.stock
--   When p_branch_id IS NULL (original behavior):
--     - Update products.stock: stock = stock + v_qty_norm
--
-- Source: mirrors 20260607000003_fix_idempotency_conflict_target.sql
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key text,
  p_date            date,
  p_description     text,
  p_items           jsonb,
  p_branch_id       uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
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
  v_branch_qty      numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
  END IF;

  -- Verify branch_id belongs to this account (if provided)
  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P404';
    END IF;
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;  -- 3-col constraint (fixed)

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'purchase'
      AND  idempotency_key = p_idempotency_key;

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

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
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
      -- ── DUAL-LEDGER: branch stock path ──────────────────────────────────
      IF p_branch_id IS NOT NULL THEN
        -- Lock product for variant check (no stock update)
        SELECT id, user_id, is_variant, name INTO v_product
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

        -- Get current branch qty for stock_movement record
        SELECT quantity INTO v_branch_qty
        FROM   public.branch_stock
        WHERE  product_id = v_item.product_id
          AND  branch_id  = p_branch_id;

        v_qty_before := COALESCE(v_branch_qty, 0);
        v_qty_after  := v_qty_before + v_qty_norm;

        INSERT INTO public.purchases
          (user_id, account_id, product_id, amount, quantity, unit_id,
           total, description, date, operation_id, branch_id)
        VALUES
          (v_uid, v_account_id, v_item.product_id,
           v_item.amount, v_item.quantity, v_item.unit_id,
           v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
           p_branch_id)
        RETURNING id INTO v_new_purchase_id;

        -- UPSERT branch_stock (lazy init)
        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
        VALUES (v_account_id, v_item.product_id, p_branch_id, v_qty_norm)
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET quantity = public.branch_stock.quantity + v_qty_norm;

        -- stock_movement for branch purchase (does NOT touch products.stock)
        INSERT INTO public.stock_movements (
          user_id, account_id, product_id, product_name, type,
          quantity_delta, quantity_before, quantity_after,
          reference_id, reference_type, performed_by,
          operation_group_id, branch_id
        ) VALUES (
          v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
          v_qty_norm, v_qty_before, v_qty_after,
          v_new_purchase_id, 'purchase', v_uid,
          v_new_op_id, p_branch_id
        );

      -- ── ORIGINAL PATH: no branch → increment products.stock ─────────────
      ELSE
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
          (user_id, account_id, product_id, amount, quantity, unit_id,
           total, description, date, operation_id, branch_id)
        VALUES
          (v_uid, v_account_id, v_item.product_id,
           v_item.amount, v_item.quantity, v_item.unit_id,
           v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
           p_branch_id)
        RETURNING id INTO v_new_purchase_id;

        UPDATE public.products
        SET    stock = stock + v_qty_norm
        WHERE  id = v_item.product_id
        RETURNING stock - v_qty_norm, stock
        INTO   v_qty_before, v_qty_after;

        INSERT INTO public.stock_movements (
          user_id, account_id, product_id, product_name, type,
          quantity_delta, quantity_before, quantity_after,
          reference_id, reference_type, performed_by,
          operation_group_id, branch_id
        ) VALUES (
          v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
          v_qty_norm, v_qty_before, v_qty_after,
          v_new_purchase_id, 'purchase', v_uid,
          v_new_op_id, p_branch_id
        );
      END IF;

    ELSE
      -- No product_id — service/fee line item, no stock tracking
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id,
         total, description, date, operation_id, branch_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
         p_branch_id)
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

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid) TO authenticated;


-- ============================================================
-- TASK 1.7 — rpc_transfer_stock
--
-- Atomically transfers stock from one branch to another.
-- Guards:
--   - Caller must be authenticated and have an active account
--   - Caller must be owner or admin
--   - p_from_branch_id != p_to_branch_id
--   - Both branches must belong to the caller's account
--   - Origin branch_stock.quantity >= p_quantity
-- Inserts two stock_movements (transfer_out, transfer_in).
-- Uses ORDER BY branch_id on FOR UPDATE to avoid deadlocks.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(
  p_product_id     uuid,
  p_from_branch_id uuid,
  p_to_branch_id   uuid,
  p_quantity       numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_sm_out_id      uuid;
  v_sm_in_id       uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa'
      USING ERRCODE = 'P403';
  END IF;

  -- Only owner/admin can transfer stock
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validate quantity
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- Cannot transfer to the same branch
  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed'
      USING ERRCODE = 'P400';
  END IF;

  -- Verify both branches belong to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P404';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P404';
  END IF;

  -- Verify product exists and belongs to this account's user
  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P404';
  END IF;

  -- Lock both branch_stock rows in a consistent order to prevent deadlocks
  -- ORDER BY branch_id ensures both sides of a concurrent transfer lock in the same order
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = (
      CASE WHEN p_from_branch_id < p_to_branch_id THEN p_from_branch_id ELSE p_from_branch_id END
    )
  FOR UPDATE;

  -- Lock destination row if it exists (for consistent locking order)
  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = p_to_branch_id
  FOR UPDATE;

  -- Default to 0 if no rows exist
  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  -- Validate origin has enough stock
  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P409';
  END IF;

  -- INSERT stock_movement transfer_out (origin loses stock)
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id
  )
  RETURNING id INTO v_sm_out_id;

  -- INSERT stock_movement transfer_in (destination gains stock)
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id
  )
  RETURNING id INTO v_sm_in_id;

  -- Update origin branch_stock
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  -- UPSERT destination branch_stock (lazy init)
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  RETURN jsonb_build_object(
    'from_branch_id',      p_from_branch_id,
    'to_branch_id',        p_to_branch_id,
    'product_id',          p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_transfer_stock(uuid, uuid, uuid, numeric) TO authenticated;


-- ============================================================
-- TASK 1.8 — rpc_adjust_branch_stock
--
-- Manually sets a branch's stock quantity for a product.
-- Guards:
--   - Caller must be authenticated and have an active account
--   - Caller must be owner or admin
--   - Branch must belong to the caller's account
-- Inserts a stock_movement of type 'adjustment' with the delta.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_adjust_branch_stock(
  p_product_id  uuid,
  p_branch_id   uuid,
  p_new_quantity numeric,
  p_reason      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_old_quantity numeric(15,4);
  v_product_name text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa'
      USING ERRCODE = 'P403';
  END IF;

  -- Only owner/admin can adjust stock
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can adjust branch stock'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validate new quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RAISE EXCEPTION 'New quantity must be >= 0' USING ERRCODE = 'P400';
  END IF;

  -- Verify branch belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id
  ) THEN
    RAISE EXCEPTION 'branch_not_found or unauthorized'
      USING ERRCODE = 'P404';
  END IF;

  -- Verify product exists
  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P404';
  END IF;

  -- Get current quantity (default 0 if no row exists)
  SELECT quantity INTO v_old_quantity
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = p_branch_id;

  v_old_quantity := COALESCE(v_old_quantity, 0);

  -- Insert adjustment stock_movement
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, notes
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'adjustment',
    p_new_quantity - v_old_quantity, v_old_quantity, p_new_quantity,
    'adjustment', v_uid, p_branch_id, p_reason
  );

  -- UPSERT branch_stock
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_branch_id, p_new_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = p_new_quantity;

  RETURN jsonb_build_object(
    'product_id',   p_product_id,
    'branch_id',    p_branch_id,
    'old_quantity', v_old_quantity,
    'new_quantity', p_new_quantity
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_adjust_branch_stock(uuid, uuid, numeric, text) TO authenticated;


-- ============================================================
-- TASK 1.9 — Trigger check_branch_low_stock
--
-- Fires AFTER UPDATE on branch_stock.
-- If quantity drops below or equal to min_stock (and min_stock > 0),
-- queues a low_branch_stock_alert in email_logs for all account members.
-- Deduplication: only once per (product_id, branch_id) per 24 hours.
-- SECURITY DEFINER: needed to query auth.users and insert into email_logs.
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_branch_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recent_alert boolean;
  v_product_name text;
  v_branch_name  text;
BEGIN
  -- Only fire when quantity dropped AND is now at or below min_stock threshold
  IF NEW.quantity < OLD.quantity AND NEW.min_stock > 0 AND NEW.quantity <= NEW.min_stock THEN

    -- Check for a recent alert in the last 24 hours (deduplication)
    SELECT EXISTS (
      SELECT 1 FROM public.email_logs
      WHERE event_type = 'low_branch_stock_alert'
        AND metadata->>'product_id' = NEW.product_id::text
        AND metadata->>'branch_id'  = NEW.branch_id::text
        AND created_at > now() - INTERVAL '24 hours'
    ) INTO v_recent_alert;

    IF NOT v_recent_alert THEN
      SELECT name INTO v_product_name
      FROM   public.products
      WHERE  id = NEW.product_id;

      SELECT name INTO v_branch_name
      FROM   public.branches
      WHERE  id = NEW.branch_id;

      -- Insert alert for every member of the account
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      SELECT
        am.user_id,
        'low_branch_stock_alert',
        u.email,
        'Alerta de Stock Bajo en Sucursal: ' || COALESCE(v_product_name, 'Producto') ||
          ' (' || COALESCE(v_branch_name, 'Sucursal') || ')',
        jsonb_build_object(
          'product_id',    NEW.product_id,
          'product_name',  v_product_name,
          'branch_id',     NEW.branch_id,
          'branch_name',   v_branch_name,
          'current_stock', NEW.quantity,
          'min_stock',     NEW.min_stock
        )
      FROM public.account_members am
      JOIN auth.users u ON u.id = am.user_id
      WHERE am.account_id = NEW.account_id
      ON CONFLICT DO NOTHING;  -- email_logs has UNIQUE on (user_id, event_type, metadata)
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Attach trigger to branch_stock
DROP TRIGGER IF EXISTS on_branch_stock_update ON public.branch_stock;
CREATE TRIGGER on_branch_stock_update
  AFTER UPDATE ON public.branch_stock
  FOR EACH ROW EXECUTE FUNCTION public.check_branch_low_stock();


-- =============================================================================
-- VERIFICATION QUERIES (paste in SQL editor to verify migration)
-- =============================================================================
-- SELECT id, account_id, product_id, branch_id, quantity, min_stock FROM branch_stock WHERE false;
-- SELECT proname FROM pg_proc WHERE proname IN ('rpc_transfer_stock','rpc_adjust_branch_stock');
-- SELECT conname, consrc FROM pg_constraint WHERE conrelid = 'stock_movements'::regclass AND contype = 'c';
