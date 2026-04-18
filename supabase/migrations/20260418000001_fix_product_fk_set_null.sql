-- =============================================================================
-- MIGRATION: 20260418000001_fix_product_fk_set_null.sql
-- PURPOSE: Ensure all FK constraints that reference products(id) use
--          ON DELETE SET NULL so that products can be deleted even when
--          referenced by sales or purchases (records are preserved with
--          product_id = NULL, showing "Eliminado" in the UI).
--
-- ROOT CAUSE: The original FK constraints may have been created without
--             ON DELETE SET NULL (using the default RESTRICT), preventing
--             deletion of products that have associated sales/purchases.
-- =============================================================================

-- ─── sales.product_id ────────────────────────────────────────────────────────
-- Drop whatever constraint name currently exists on sales.product_id,
-- then re-create it with ON DELETE SET NULL.

DO $$
DECLARE
  v_constraint TEXT;
BEGIN
  -- Find the actual constraint name dynamically (it may vary between envs)
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.sales'::regclass
    AND contype = 'f'
    AND conkey = ARRAY(
      SELECT attnum FROM pg_attribute
      WHERE attrelid = 'public.sales'::regclass AND attname = 'product_id'
    );

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.sales DROP CONSTRAINT %I', v_constraint);
  END IF;
END $$;

ALTER TABLE public.sales
  ADD CONSTRAINT sales_product_id_fkey
  FOREIGN KEY (product_id)
  REFERENCES public.products(id)
  ON DELETE SET NULL;

-- ─── purchases.product_id ─────────────────────────────────────────────────────

DO $$
DECLARE
  v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.purchases'::regclass
    AND contype = 'f'
    AND conkey = ARRAY(
      SELECT attnum FROM pg_attribute
      WHERE attrelid = 'public.purchases'::regclass AND attname = 'product_id'
    );

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.purchases DROP CONSTRAINT %I', v_constraint);
  END IF;
END $$;

ALTER TABLE public.purchases
  ADD CONSTRAINT purchases_product_id_fkey
  FOREIGN KEY (product_id)
  REFERENCES public.products(id)
  ON DELETE SET NULL;

-- ─── products.parent_id (self-referential variants) ───────────────────────────

DO $$
DECLARE
  v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.products'::regclass
    AND contype = 'f'
    AND conkey = ARRAY(
      SELECT attnum FROM pg_attribute
      WHERE attrelid = 'public.products'::regclass AND attname = 'parent_id'
    );

  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.products DROP CONSTRAINT %I', v_constraint);
  END IF;
END $$;

ALTER TABLE public.products
  ADD CONSTRAINT products_parent_id_fkey
  FOREIGN KEY (parent_id)
  REFERENCES public.products(id)
  ON DELETE SET NULL;

-- Verification comment:
-- After this migration, deleting a product will:
--   - Set sales.product_id = NULL for related sales (shows "Eliminado" in UI)
--   - Set purchases.product_id = NULL for related purchases (shows "Eliminado" in UI)
--   - Set products.parent_id = NULL for variant products (they become standalone)
-- No data is lost. Business records remain intact.
