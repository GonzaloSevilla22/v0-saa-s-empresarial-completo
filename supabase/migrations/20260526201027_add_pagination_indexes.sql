-- Enterprise Pagination Indexes
--
-- Covers every ORDER BY / WHERE pattern used by the paginated list pages:
--   - sales      → ordered by date DESC, filtered by user_id + date range
--   - purchases  → same pattern
--   - expenses   → same pattern
--   - clients    → ordered by name, filtered by user_id + ilike search
--   - products   → ilike search on name per tenant
--
-- Note: CONCURRENTLY cannot run inside a transaction block (used by supabase migration tooling).
-- The IF NOT EXISTS guard makes the migration idempotent.
--
-- Multi-tenant note: user_id is the first column in every composite index so
-- Postgres can use index-only scans for the RLS .eq("user_id", uid) filter
-- without a heap fetch.

-- ─── sales ────────────────────────────────────────────────────────────────────

-- Primary list order: date DESC per tenant
CREATE INDEX IF NOT EXISTS idx_sales_user_date
  ON sales (user_id, date DESC);

-- Operation grouping: fetch all rows of one operation efficiently
CREATE INDEX IF NOT EXISTS idx_sales_user_operation
  ON sales (user_id, operation_id)
  WHERE operation_id IS NOT NULL;

-- Foreign-key join speed (product names in list)
CREATE INDEX IF NOT EXISTS idx_sales_product_id
  ON sales (product_id)
  WHERE product_id IS NOT NULL;

-- Foreign-key join speed (client names in list)
CREATE INDEX IF NOT EXISTS idx_sales_client_id
  ON sales (client_id)
  WHERE client_id IS NOT NULL;

-- ─── purchases ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_purchases_user_date
  ON purchases (user_id, date DESC);

CREATE INDEX IF NOT EXISTS idx_purchases_user_operation
  ON purchases (user_id, operation_id)
  WHERE operation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_purchases_product_id
  ON purchases (product_id)
  WHERE product_id IS NOT NULL;

-- ─── expenses ─────────────────────────────────────────────────────────────────

-- Primary list order + date-range filter
CREATE INDEX IF NOT EXISTS idx_expenses_user_date
  ON expenses (user_id, date DESC);

-- Full-text-style prefix search on description (text_pattern_ops enables LIKE 'x%')
CREATE INDEX IF NOT EXISTS idx_expenses_user_desc
  ON expenses (user_id, description text_pattern_ops);

-- ─── clients ──────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_clients_user_name
  ON clients (user_id, name text_pattern_ops);

CREATE INDEX IF NOT EXISTS idx_clients_user_created
  ON clients (user_id, created_at DESC);

-- ─── products ─────────────────────────────────────────────────────────────────

-- ilike name search per tenant (text_pattern_ops supports LIKE '%x%' with btree)
-- Note: for true full-text search, a GIN tsvector index would be better,
-- but this covers the common ILIKE '%term%' pattern used in the catalog.
CREATE INDEX IF NOT EXISTS idx_products_user_name
  ON products (user_id, name text_pattern_ops);

-- Hierarchy queries: fetch all variants of a parent
CREATE INDEX IF NOT EXISTS idx_products_parent_id
  ON products (parent_id)
  WHERE parent_id IS NOT NULL;

-- stock_control_type filter (dashboard low-stock query)
-- Guarded: column was added via MCP in prod and may not exist in CI test DB yet.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'products' AND column_name = 'stock_control_type'
  ) THEN
    EXECUTE $idx$
      CREATE INDEX IF NOT EXISTS idx_products_user_stock
        ON products (user_id, stock)
        WHERE stock_control_type = 'tracked'
    $idx$;
  END IF;
END $$;

-- ─── stock_movements (future module) ─────────────────────────────────────────

-- Pre-emptively index the audit log table if it exists
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'stock_movements') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_stock_movements_user_created
             ON stock_movements (user_id, created_at DESC)';
  END IF;
END $$;
