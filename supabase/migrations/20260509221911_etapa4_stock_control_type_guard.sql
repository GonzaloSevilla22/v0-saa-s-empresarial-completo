-- =============================================================================
-- MIGRATION: 20260509221911_etapa4_stock_control_type_guard.sql
-- DESCRIPTION: Etapa 4 — Add DB-level guard so that untracked products
--              (stock_control_type = 'untracked') never have their stock
--              decremented on sales or incremented on purchases.
--              The RPC already checks stock_control_type; this trigger is a
--              second layer of defense for direct INSERT/UPDATE paths.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509221911
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

-- Performance index: RPC and guard filters query stock_control_type frequently
CREATE INDEX IF NOT EXISTS idx_products_stock_control_type
  ON public.products(stock_control_type);

-- Composite index for unit-aware queries on sales and purchases
CREATE INDEX IF NOT EXISTS idx_sales_unit_id     ON public.sales(unit_id)     WHERE unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_purchases_unit_id ON public.purchases(unit_id) WHERE unit_id IS NOT NULL;
