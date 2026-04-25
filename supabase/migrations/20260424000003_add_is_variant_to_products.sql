-- ────────────────────────────────────────────────────────────────────────────
-- Phase 2: add is_variant column to products
--
-- Rules:
--   is_variant = false → root product (parent catalogue entry or standalone)
--   is_variant = true  → SKU variant (always has parent_id set)
--
-- Existing products:
--   • products with parent_id   → backfilled to is_variant = true
--   • products without parent_id → remain false (no change)
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS is_variant boolean NOT NULL DEFAULT false;

-- Backfill: any product already linked to a parent is a variant
UPDATE public.products
  SET is_variant = true
  WHERE parent_id IS NOT NULL;

-- Performance indexes (safe to run more than once)
CREATE INDEX IF NOT EXISTS idx_products_parent_id  ON public.products (parent_id);
CREATE INDEX IF NOT EXISTS idx_products_is_variant ON public.products (is_variant);
