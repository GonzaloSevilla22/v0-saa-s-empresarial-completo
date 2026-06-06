-- =============================================================================
-- test_branch_stock.sql — branch_stock module correctness tests (C-08)
--
-- Verifies (structural / schema-level checks, no auth session required):
--   6.1 Schema: branch_stock table exists with correct columns
--   6.2 Schema: CHECK constraints on stock_movements include transfer types
--   6.3 Schema: RLS is enabled on branch_stock
--   6.4 Schema: UNIQUE(product_id, branch_id) constraint exists
--   6.5 Schema: rpc_transfer_stock exists and is SECURITY DEFINER
--   6.6 Schema: rpc_adjust_branch_stock exists and is SECURITY DEFINER
--   6.7 Schema: check_branch_low_stock trigger exists on branch_stock
--   6.8 Schema: rpc_create_sale_operation references branch_stock (body check)
--   6.9 Schema: rpc_create_purchase_operation references branch_stock (body check)
--
-- Runtime behavior tests (require authenticated session with test fixtures):
--   See comments at the bottom of this file for the 7 behavioral scenarios.
--
-- Uses RAISE EXCEPTION so psql returns exit code 1 on any failure.
-- =============================================================================

DO $$
DECLARE
  v_ok      boolean;
  v_count   integer;
  v_text    text;
BEGIN

  -- ── 6.1 branch_stock table exists with expected columns ──────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name   = 'branch_stock'
    AND column_name IN ('id','account_id','product_id','branch_id','quantity','min_stock');

  IF v_count < 6 THEN
    RAISE EXCEPTION '[FAIL] 6.1 branch_stock table missing expected columns (found %)', v_count;
  END IF;
  RAISE NOTICE '[PASS] 6.1 branch_stock table has all 6 expected columns';

  -- ── 6.2 quantity column is NUMERIC ───────────────────────────────────────────
  SELECT data_type INTO v_text
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name   = 'branch_stock'
    AND column_name  = 'quantity';

  IF v_text NOT IN ('numeric') THEN
    RAISE EXCEPTION '[FAIL] 6.2 branch_stock.quantity should be NUMERIC, got %', v_text;
  END IF;
  RAISE NOTICE '[PASS] 6.2 branch_stock.quantity is NUMERIC';

  -- ── 6.3 stock_movements CHECK includes transfer_out and transfer_in ───────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stock_movements'::regclass
      AND contype  = 'c'
      AND pg_get_constraintdef(oid) LIKE '%transfer_out%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.3 stock_movements.type CHECK does not include transfer_out/transfer_in';
  END IF;
  RAISE NOTICE '[PASS] 6.3 stock_movements type CHECK includes transfer types';

  -- ── 6.4 stock_movements CHECK includes transfer in reference_type ─────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stock_movements'::regclass
      AND contype  = 'c'
      AND pg_get_constraintdef(oid) LIKE '%transfer%'
      AND pg_get_constraintdef(oid) LIKE '%reference_type%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.4 stock_movements.reference_type CHECK does not include transfer';
  END IF;
  RAISE NOTICE '[PASS] 6.4 stock_movements reference_type CHECK includes transfer';

  -- ── 6.5 RLS is enabled on branch_stock ───────────────────────────────────────
  SELECT relrowsecurity INTO v_ok
  FROM pg_class
  WHERE oid = 'public.branch_stock'::regclass;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.5 RLS not enabled on branch_stock';
  END IF;
  RAISE NOTICE '[PASS] 6.5 RLS enabled on branch_stock';

  -- ── 6.6 UNIQUE(product_id, branch_id) constraint exists ─────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.branch_stock'::regclass
      AND contype  = 'u'
      AND pg_get_constraintdef(oid) LIKE '%product_id%'
      AND pg_get_constraintdef(oid) LIKE '%branch_id%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.6 UNIQUE(product_id, branch_id) constraint not found on branch_stock';
  END IF;
  RAISE NOTICE '[PASS] 6.6 UNIQUE(product_id, branch_id) constraint exists';

  -- ── 6.7 rpc_transfer_stock exists and is SECURITY DEFINER ────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_transfer_stock'
      AND p.prosecdef = true
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.7 rpc_transfer_stock not found or not SECURITY DEFINER';
  END IF;
  RAISE NOTICE '[PASS] 6.7 rpc_transfer_stock exists and is SECURITY DEFINER';

  -- ── 6.8 rpc_adjust_branch_stock exists and is SECURITY DEFINER ───────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_adjust_branch_stock'
      AND p.prosecdef = true
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.8 rpc_adjust_branch_stock not found or not SECURITY DEFINER';
  END IF;
  RAISE NOTICE '[PASS] 6.8 rpc_adjust_branch_stock exists and is SECURITY DEFINER';

  -- ── 6.9 check_branch_low_stock trigger exists on branch_stock ─────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'branch_stock'
      AND t.tgname  = 'on_branch_stock_update'
      AND NOT t.tgisinternal
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION '[FAIL] 6.9 on_branch_stock_update trigger not found on branch_stock';
  END IF;
  RAISE NOTICE '[PASS] 6.9 on_branch_stock_update trigger exists on branch_stock';

  -- ── 6.10 rpc_create_sale_operation body references branch_stock ───────────────
  SELECT prosrc INTO v_text
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rpc_create_sale_operation'
  LIMIT 1;

  IF v_text NOT LIKE '%branch_stock%' THEN
    RAISE EXCEPTION '[FAIL] 6.10 rpc_create_sale_operation body does not reference branch_stock';
  END IF;
  RAISE NOTICE '[PASS] 6.10 rpc_create_sale_operation references branch_stock';

  -- ── 6.11 rpc_create_purchase_operation body references branch_stock ───────────
  SELECT prosrc INTO v_text
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rpc_create_purchase_operation'
  LIMIT 1;

  IF v_text NOT LIKE '%branch_stock%' THEN
    RAISE EXCEPTION '[FAIL] 6.11 rpc_create_purchase_operation body does not reference branch_stock';
  END IF;
  RAISE NOTICE '[PASS] 6.11 rpc_create_purchase_operation references branch_stock';

  -- ── 6.12 Indexes exist on branch_stock ───────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename  = 'branch_stock'
    AND indexname IN (
      'branch_stock_account_branch_idx',
      'branch_stock_product_branch_idx'
    );

  IF v_count < 2 THEN
    RAISE EXCEPTION '[FAIL] 6.12 Expected 2 indexes on branch_stock, found %', v_count;
  END IF;
  RAISE NOTICE '[PASS] 6.12 Both performance indexes exist on branch_stock';

  RAISE NOTICE '';
  RAISE NOTICE '══════════════════════════════════════════════════════════════';
  RAISE NOTICE 'All structural tests passed for C-08 branch_stock (12/12)';
  RAISE NOTICE '══════════════════════════════════════════════════════════════';

END;
$$;


-- =============================================================================
-- RUNTIME BEHAVIOR TESTS (require authenticated session + test fixtures)
-- =============================================================================
-- These tests verify the 7 behavioral scenarios from tasks.md.
-- They must run in an authenticated Supabase session with:
--   - A test account with an owner user
--   - Two branches (branch_a, branch_b)
--   - A test product with known product_id
--
-- Scenario 6.1: Venta con branch_id reduce branch_stock, NO toca products.stock
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup:
--   INSERT INTO branch_stock (account_id, product_id, branch_id, quantity)
--   VALUES (:account_id, :product_id, :branch_a_id, 10);
--
-- Call:
--   SELECT rpc_create_sale_operation(
--     'key-test-01', :client_id, CURRENT_DATE, 'ARS',
--     '[{"product_id": ":product_id", "amount": 100, "quantity": 3}]',
--     :branch_a_id
--   );
--
-- Verify:
--   SELECT quantity FROM branch_stock WHERE product_id = :product_id AND branch_id = :branch_a_id;
--   -- Expected: 7
--   SELECT stock FROM products WHERE id = :product_id;
--   -- Expected: UNCHANGED (same value as before the sale)
--   SELECT type, quantity_delta, branch_id FROM stock_movements
--   WHERE reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
--   -- Expected: type='sale', quantity_delta=-3, branch_id=:branch_a_id
--
-- Scenario 6.2: Venta falla si branch_stock insuficiente
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: branch_stock.quantity = 2 for :product_id in :branch_a_id
-- Call with quantity=5 → must RAISE EXCEPTION 'insufficient_branch_stock'
-- Verify: branch_stock.quantity and products.stock are unchanged (rollback)
--
-- Scenario 6.3: Compra con branch_id incrementa branch_stock (lazy init desde 0)
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: No branch_stock row for :product_id in :branch_b_id
-- Call rpc_create_purchase_operation with branch_id=:branch_b_id, quantity=5
-- Verify:
--   SELECT quantity FROM branch_stock WHERE product_id=:product_id AND branch_id=:branch_b_id;
--   -- Expected: 5 (lazy init)
--   SELECT stock FROM products WHERE id=:product_id;
--   -- Expected: UNCHANGED
--
-- Scenario 6.4: rpc_transfer_stock exitoso
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: branch_a has 10, branch_b has 0
-- Call rpc_transfer_stock(:product_id, :branch_a_id, :branch_b_id, 4)
-- Verify:
--   branch_a.quantity = 6, branch_b.quantity = 4
--   Two stock_movements: type='transfer_out' (branch_a), type='transfer_in' (branch_b)
--   Both with reference_type='transfer'
--
-- Scenario 6.5: rpc_transfer_stock falla si stock insuficiente en origen
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: branch_a has 2
-- Call rpc_transfer_stock(:product_id, :branch_a_id, :branch_b_id, 10)
-- Expected: RAISE EXCEPTION 'insufficient_branch_stock'
-- Verify: NO rows modified (atomic rollback)
--
-- Scenario 6.6: rpc_adjust_branch_stock — ajuste exitoso
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: branch_stock.quantity = 5
-- Call rpc_adjust_branch_stock(:product_id, :branch_a_id, 8, 'Inventario físico')
-- Verify:
--   branch_stock.quantity = 8
--   stock_movements: type='adjustment', quantity_delta=3, quantity_before=5, quantity_after=8
--
-- Scenario 6.7: member (no owner/admin) NO puede llamar a rpc_transfer_stock ni rpc_adjust_branch_stock
-- ──────────────────────────────────────────────────────────────────────────────
-- Setup: Authenticate as a 'member' role user (not owner/admin)
-- Call rpc_transfer_stock(...)  → Expected: RAISE EXCEPTION 'unauthorized'
-- Call rpc_adjust_branch_stock(...) → Expected: RAISE EXCEPTION 'unauthorized'
