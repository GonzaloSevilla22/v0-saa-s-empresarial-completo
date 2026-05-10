-- =============================================================================
-- MIGRATION: 20260509210816_etapa2_numeric_stock_columns.sql
-- DESCRIPTION: Etapa 2 — Change stock and quantity columns from INTEGER to
--              NUMERIC(15,4) to support decimal quantities (weight, volume,
--              length). Also adds base_unit_id and stock_control_type to
--              products; unit_id to sales and purchases.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509210816
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

-- products: stock columns → NUMERIC(15,4)
ALTER TABLE public.products
  ALTER COLUMN stock    TYPE NUMERIC(15,4) USING stock::NUMERIC,
  ALTER COLUMN min_stock TYPE NUMERIC(15,4) USING min_stock::NUMERIC;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS base_unit_id       uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS stock_control_type text NOT NULL DEFAULT 'tracked'
    CONSTRAINT products_stock_control_type_check
    CHECK (stock_control_type IN ('tracked', 'untracked', 'variant_only'));

-- sales: quantity → NUMERIC(15,4); add unit_id
ALTER TABLE public.sales
  ALTER COLUMN quantity TYPE NUMERIC(15,4) USING quantity::NUMERIC;

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL;

-- purchases: quantity → NUMERIC(15,4); add unit_id
ALTER TABLE public.purchases
  ALTER COLUMN quantity TYPE NUMERIC(15,4) USING quantity::NUMERIC;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS unit_id uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL;
