-- ============================================================
-- C-21 v20-inventory-unification: Dual-write branch_stock en rpc_bulk_upsert_products
-- Push 1 — parte de Migración A (no destructiva)
-- ============================================================
-- Actualiza rpc_bulk_upsert_products para escribir branch_stock (default branch)
-- además de products.stock durante la transición (Grupo 6.2 / Design D5).
--
-- La "default branch" = la branch más antigua de la cuenta del usuario
-- (creada en la migración anterior o ya existente como "Principal").
--
-- Idempotencia: ON CONFLICT (product_id, branch_id) DO UPDATE.
-- Mientras products.stock exista, se escribe en ambos (dual-write transición).
-- Tras el DROP de products.stock (Checkpoint PO #2), este RPC se simplifica
-- para sólo escribir branch_stock.
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_account_id     uuid;
  v_default_branch uuid;
  v_stock_qty      numeric;
BEGIN
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- Obtener account_id y branch por defecto del usuario (la más antigua)
  SELECT a.id INTO v_account_id
    FROM accounts a WHERE a.user_id = p_user_id LIMIT 1;

  IF v_account_id IS NOT NULL THEN
    SELECT b.id INTO v_default_branch
      FROM branches b
     WHERE b.account_id = v_account_id
     ORDER BY b.created_at ASC
     LIMIT 1;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      v_existing_id := NULL;
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku'
         LIMIT 1;
      END IF;

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

      v_stock_qty := COALESCE((v_row->>'stock')::numeric, 0);

      IF v_existing_id IS NOT NULL THEN
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category           = COALESCE(NULLIF(v_row->>'category',''),   category),
          price              = COALESCE((v_row->>'price')::numeric,      price),
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
          stock              = COALESCE(v_stock_qty::integer,            stock),
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
          COALESCE(v_stock_qty::integer,          0),
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

      -- C-21 Grupo 6.2: dual-write branch_stock (default branch)
      -- Mientras products.stock exista, escribimos ambos (transición).
      -- Sólo para filas no-Padre (stock > 0 o stock explícito en el CSV).
      IF v_default_branch IS NOT NULL
         AND v_account_id IS NOT NULL
         AND v_product_id IS NOT NULL
         AND (v_row->>'stock' IS NOT NULL OR v_stock_qty > 0)
      THEN
        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
        VALUES (
          v_account_id,
          v_product_id,
          v_default_branch,
          v_stock_qty,
          COALESCE((v_row->>'min_stock')::integer, 0)
        )
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET
            quantity  = EXCLUDED.quantity,
            min_stock = EXCLUDED.min_stock;
      END IF;

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
$function$;

COMMENT ON FUNCTION public.rpc_bulk_upsert_products IS
    'C-21: dual-write — escribe branch_stock (default branch) + products.stock durante la transición. '
    'Tras el DROP de products.stock (Checkpoint PO #2), remover la escritura a products.stock.';
