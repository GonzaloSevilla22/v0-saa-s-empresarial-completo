-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: SKU column + product_attributes table
--
-- Purpose:
--   1. Add a `sku` column to products — stable identifier for upserts during
--      bulk CSV/XLSX imports.  Optional but unique per (user_id, sku).
--   2. Create product_attributes for dynamic variant attributes (color, size…).
--      Normalised as key/value rows per product, each key unique per product.
--
-- Safety:
--   • All ADD COLUMN / CREATE TABLE use IF NOT EXISTS — idempotent.
--   • Unique index on (user_id, sku) is partial (WHERE sku IS NOT NULL) so
--     products without SKUs never collide.
--   • RLS policies mirror the pattern already used by products table.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. SKU column on products -------------------------------------------------

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS sku text;

-- Partial unique index: SKU uniqueness is scoped per tenant
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku_user
  ON public.products (user_id, sku)
  WHERE sku IS NOT NULL;

-- Full-text speed index for barcode scanner / search
CREATE INDEX IF NOT EXISTS idx_products_sku
  ON public.products (sku);

COMMENT ON COLUMN public.products.sku IS
  'Optional human-readable SKU. Unique per user (tenant). Used as stable key for CSV upserts.';

-- 2. product_attributes table -----------------------------------------------

CREATE TABLE IF NOT EXISTS public.product_attributes (
  id         uuid    DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id uuid    NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  user_id    uuid    NOT NULL REFERENCES auth.users(id)      ON DELETE CASCADE,
  key        text    NOT NULL,   -- e.g. "color", "talle", "género", "material"
  value      text    NOT NULL,   -- e.g. "Rojo", "XL", "Mujer", "Algodón"
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),

  -- One value per attribute key per product
  UNIQUE (product_id, key)
);

CREATE INDEX IF NOT EXISTS idx_product_attributes_product
  ON public.product_attributes (product_id);

CREATE INDEX IF NOT EXISTS idx_product_attributes_user
  ON public.product_attributes (user_id);

COMMENT ON TABLE public.product_attributes IS
  'Dynamic key/value attributes for product variants (color, size, gender, etc.).';

-- 3. RLS for product_attributes ---------------------------------------------

ALTER TABLE public.product_attributes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read their own product attributes"
  ON public.product_attributes FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own product attributes"
  ON public.product_attributes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own product attributes"
  ON public.product_attributes FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own product attributes"
  ON public.product_attributes FOR DELETE
  USING (auth.uid() = user_id);

-- 4. RPC: bulk upsert products + attributes (used by CSV importer) ----------
-- Called from the import pipeline in a single network round-trip.
-- Input: JSONB array of product records with optional nested attributes.
-- Returns: summary { inserted int, updated int, errors jsonb[] }

CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(
  p_rows    jsonb,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row            jsonb;
  v_product_id     uuid;
  v_existing_id    uuid;
  v_resolved_pid   uuid;
  v_attr           jsonb;
  v_inserted       int := 0;
  v_updated        int := 0;
  v_errors         jsonb := '[]'::jsonb;
  v_error_detail   jsonb;
BEGIN
  -- Validate caller owns the user_id being written
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- Rows arrive pre-ordered: parents first, then variants, then standalone.
  -- This means when a variant row is processed, its parent has already been
  -- inserted in this same transaction and is visible to subsequent SELECTs.

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      -- ── Resolve existing product by SKU (upsert key) ──────────────────────
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku'
         LIMIT 1;
      ELSE
        v_existing_id := NULL;
      END IF;

      -- ── Resolve parent_id ─────────────────────────────────────────────────
      -- Priority:
      --   1. Explicit parent_id UUID in the payload (pre-resolved by the client).
      --   2. sku_parent field → look up by SKU within this tenant.
      --      This covers variants whose parent was inserted earlier in this batch.
      v_resolved_pid := NULL;
      IF v_row->>'parent_id' IS NOT NULL AND v_row->>'parent_id' <> '' THEN
        v_resolved_pid := (v_row->>'parent_id')::uuid;
      ELSIF v_row->>'sku_parent' IS NOT NULL AND v_row->>'sku_parent' <> '' THEN
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku_parent'
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'SKU Padre "%" no encontrado para la variante "%"',
            v_row->>'sku_parent', v_row->>'name';
        END IF;
      END IF;

      IF v_existing_id IS NOT NULL THEN
        -- ── UPDATE existing product ────────────────────────────────────────
        UPDATE public.products SET
          name               = COALESCE(v_row->>'name',                name),
          category           = COALESCE(v_row->>'category',            category),
          price              = COALESCE((v_row->>'price')::numeric,    price),
          cost               = COALESCE((v_row->>'cost')::numeric,     cost),
          stock              = COALESCE((v_row->>'stock')::integer,    stock),
          min_stock          = COALESCE((v_row->>'min_stock')::integer, min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),  barcode),
          parent_id          = COALESCE(v_resolved_pid,                parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(v_row->>'stock_control_type',  stock_control_type)
        WHERE id = v_existing_id AND user_id = p_user_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;
      ELSE
        -- ── INSERT new product ─────────────────────────────────────────────
        INSERT INTO public.products (
          user_id, name, category, price, cost, stock, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_row->>'name',
          COALESCE(v_row->>'category', 'Otros'),
          COALESCE((v_row->>'price')::numeric, 0),
          COALESCE((v_row->>'cost')::numeric, 0),
          COALESCE((v_row->>'stock')::integer, 0),
          COALESCE((v_row->>'min_stock')::integer, 0),
          NULLIF(v_row->>'barcode', ''),
          NULLIF(v_row->>'sku', ''),
          v_resolved_pid,
          COALESCE((v_row->>'is_variant')::boolean, false),
          COALESCE(v_row->>'stock_control_type', 'tracked')
        )
        RETURNING id INTO v_product_id;

        v_inserted := v_inserted + 1;
      END IF;

      -- ── Upsert attributes ────────────────────────────────────────────────
      IF v_row->'attributes' IS NOT NULL THEN
        FOR v_attr IN SELECT * FROM jsonb_array_elements(v_row->'attributes')
        LOOP
          INSERT INTO public.product_attributes (product_id, user_id, key, value, sort_order)
          VALUES (
            v_product_id,
            p_user_id,
            v_attr->>'key',
            v_attr->>'value',
            COALESCE((v_attr->>'sort_order')::integer, 0)
          )
          ON CONFLICT (product_id, key) DO UPDATE
            SET value      = EXCLUDED.value,
                sort_order = EXCLUDED.sort_order;
        END LOOP;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_error_detail := jsonb_build_object(
        'sku',     v_row->>'sku',
        'name',    v_row->>'name',
        'message', SQLERRM
      );
      v_errors := v_errors || jsonb_build_array(v_error_detail);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'inserted', v_inserted,
    'updated',  v_updated,
    'errors',   v_errors
  );
END;
$$;

-- Revoke public execute, grant only to authenticated users
REVOKE ALL ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_bulk_upsert_products IS
  'Bulk upsert products and their attributes from CSV import. Scoped per tenant. Returns {inserted, updated, errors}.';
