-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: update rpc_bulk_upsert_products to support parent_name lookup
--
-- Adds a third parent-resolution strategy inside the RPC:
--   1. parent_id   (UUID pre-resolved by client)
--   2. sku_parent  (resolve by SKU — for parents with SKU)
--   3. parent_name (resolve by name — for parents without SKU)
--
-- This enables importing product hierarchies where SKU is absent,
-- using sequential grouping or explicit name references.
-- ─────────────────────────────────────────────────────────────────────────────

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
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- Rows arrive pre-ordered: parents first, then variants, then standalone.
  -- When a variant is processed its parent already exists in this transaction.

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      -- ── Resolve existing product by SKU (upsert key) ──────────────────────
      -- SKU is optional; if absent the row is always inserted as new.
      v_existing_id := NULL;
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku'
         LIMIT 1;
      END IF;

      -- ── Resolve parent_id (3-strategy cascade) ───────────────────────────
      -- Strategy 1: explicit UUID (pre-resolved by client for out-of-batch parents)
      -- Strategy 2: sku_parent → look up by SKU
      -- Strategy 3: parent_name → look up by name (for parents without SKU)
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

      ELSIF v_row->>'parent_name' IS NOT NULL AND v_row->>'parent_name' <> '' THEN
        -- Look up by exact name, scoped to this tenant, non-variant products only
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE user_id = p_user_id
           AND name = v_row->>'parent_name'
           AND (is_variant = false OR is_variant IS NULL)
           AND parent_id IS NULL
         ORDER BY created_at DESC
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'Producto Padre "%" no encontrado para la variante "%"',
            v_row->>'parent_name', v_row->>'name';
        END IF;
      END IF;

      -- ── Upsert product ────────────────────────────────────────────────────
      IF v_existing_id IS NOT NULL THEN
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category           = COALESCE(NULLIF(v_row->>'category',''),   category),
          price              = COALESCE((v_row->>'price')::numeric,      price),
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
          stock              = COALESCE((v_row->>'stock')::integer,      stock),
          min_stock          = COALESCE((v_row->>'min_stock')::integer,  min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),    barcode),
          parent_id          = COALESCE(v_resolved_pid,                  parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type)
        WHERE id = v_existing_id AND user_id = p_user_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;

      ELSE
        INSERT INTO public.products (
          user_id, name, category, price, cost, stock, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_row->>'name',
          COALESCE(NULLIF(v_row->>'category',''), 'Otros'),
          COALESCE((v_row->>'price')::numeric,    0),
          COALESCE((v_row->>'cost')::numeric,     0),
          COALESCE((v_row->>'stock')::integer,    0),
          COALESCE((v_row->>'min_stock')::integer, 0),
          NULLIF(v_row->>'barcode', ''),
          NULLIF(v_row->>'sku',     ''),
          v_resolved_pid,
          COALESCE((v_row->>'is_variant')::boolean, false),
          COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked')
        )
        RETURNING id INTO v_product_id;

        v_inserted := v_inserted + 1;
      END IF;

      -- ── Upsert attributes ─────────────────────────────────────────────────
      IF v_row->'attributes' IS NOT NULL AND jsonb_array_length(v_row->'attributes') > 0 THEN
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

REVOKE ALL ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO authenticated;
