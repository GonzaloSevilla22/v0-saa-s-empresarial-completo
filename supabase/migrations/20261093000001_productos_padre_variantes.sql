-- =============================================================================
-- productos-padre-variantes — TANDA A (DB + backend), governance MEDIO con un
-- tramo ALTO (la salida del guard de unidad base, sección 3).
--
-- Qué hace (design.md D3, D5, D6, D8, D9):
--   1. product_round_price(numeric): la UNA definición SQL del redondeo de precios
--      a pesos enteros (mitad hacia afuera del cero). La comparte, por tabla de
--      casos, con frontend/lib/product-pricing.ts (tanda B).
--   2. Padre sin precio/costo: backfill AUDITADO de los padres variant_only con
--      precio o costo (price = 0, cost = NULL; una fila product.parent_price_cleared
--      por producto con los valores anteriores) y CHECK
--      products_variant_only_no_price_cost. Sin herencia de precio/costo.
--   3. fn_product_base_unit_guard: re-derivado del cuerpo VIVO de prod, con UN
--      corte nuevo (GUC local products.unit_relabel_root atado a la raíz).
--   4. rpc_relabel_product_unit: corrección de la unidad de una familia SIN
--      convertir cantidades (relabel), con dry-run, rol, auditoría y conflicto.
--   5. rpc_bulk_adjust_prices: modificación de precios en lote con dry-run.
--   6. rpc_bulk_upsert_products: la rama Padre del importador fuerza
--      price = 0 y cost = NULL (el CHECK de 2 no admite otra cosa).
--
-- Reaplicable (idempotente): CREATE OR REPLACE / DROP IF EXISTS + CREATE, el
-- backfill sólo toca filas que aún no cumplen y el CHECK se agrega sólo si falta.
-- El gate supabase/tests/test_productos_padre_variantes.sql la reaplica con \i.
--
-- Rollback (design.md, Migration Plan §4): DROP CONSTRAINT del CHECK; DROP
-- FUNCTION de las dos RPCs y del helper; restaurar el cuerpo previo del guard
-- (el de 20261069000001_remitos_venta.sql) y el del importador (el de
-- 20261086000001). El backfill no se revierte: los valores anteriores quedan en
-- audit_logs (action = 'product.parent_price_cleared').
-- =============================================================================

-- =============================================================================
-- 1. Redondeo de precios (D9)
-- =============================================================================
DROP FUNCTION IF EXISTS public.product_round_price(numeric);
CREATE FUNCTION public.product_round_price(p_value numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public
AS $function$
  SELECT round(p_value, 0)
$function$;

COMMENT ON FUNCTION public.product_round_price(numeric) IS
  $c$productos-padre-variantes (D9): UNA sola definición SQL del redondeo de precios a pesos enteros — round(numeric, 0), la mitad se aleja del cero (0,5 -> 1; 2,5 -> 3; -0,5 -> -1). Su par en TypeScript es roundToPesos (frontend/lib/product-pricing.ts); la paridad la sostiene supabase/tests/fixtures/product_round_price_cases.json. La usa rpc_bulk_adjust_prices; ningún otro camino redondea precios por su cuenta.$c$;

REVOKE ALL ON FUNCTION public.product_round_price(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_round_price(numeric) TO authenticated, service_role;

-- =============================================================================
-- 2. Padre sin precio ni costo (D3): backfill auditado + CHECK
-- =============================================================================
-- Incluye las filas borradas (deleted_at no nulo) para que el CHECK valide sin
-- NOT VALID. No reescribe ninguna línea de venta, compra ni presupuesto.
DO $backfill$
BEGIN
  INSERT INTO public.audit_logs (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  SELECT p.account_id, NULL, 'product.parent_price_cleared', 'product', p.id,
         jsonb_build_object(
           'price_before', p.price,
           'cost_before',  p.cost,
           'was_deleted',  p.deleted_at IS NOT NULL,
           'source',       'migration:20261093000001_productos_padre_variantes'),
         now()
    FROM public.products p
   WHERE p.stock_control_type = 'variant_only'
     AND (p.price IS DISTINCT FROM 0 OR p.cost IS NOT NULL);

  UPDATE public.products
     SET price = 0,
         cost  = NULL
   WHERE stock_control_type = 'variant_only'
     AND (price IS DISTINCT FROM 0 OR cost IS NOT NULL);
END
$backfill$;

DO $check$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.products'::regclass
                    AND conname = 'products_variant_only_no_price_cost') THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_variant_only_no_price_cost
      CHECK (stock_control_type IS DISTINCT FROM 'variant_only' OR (price = 0 AND cost IS NULL));
  END IF;
END
$check$;

COMMENT ON CONSTRAINT products_variant_only_no_price_cost ON public.products IS
  $c$productos-padre-variantes (D3): un producto padre variant_only no lleva precio ni costo — price = 0 y cost NULL para cualquier escritor (API, PostgREST, importador, función futura). El precio y el costo viven en cada variante; NO se heredan del padre. El servidor traduce el 23514 a 422 parent_field_not_allowed.$c$;

-- =============================================================================
-- 6. rpc_bulk_upsert_products: la rama Padre del importador fuerza price = 0 y
--    cost = NULL (checkpoint 1.3 de tasks.md; D3)
-- =============================================================================
-- Re-derivada del cuerpo VIVO de prod (md5 sin CR 30730c94469dc0a5ad98f1905608af46,
-- idéntico al de 20261086000001_importador_productos_stock_apertura.sql, medido el
-- 2026-11-05). Mismo nombre y firma: CREATE OR REPLACE conserva la ACL y el COMMENT.
-- Sólo cambian los dos bloques marcados con «productos-padre-variantes».
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
  -- importador-productos-stock-apertura (D2): la fila nació en ESTE lote (no existía por SKU).
  v_is_new         boolean;
  -- productos-categorias-sku (D6): categoría por fila + default de la cuenta + tope.
  v_cat_name         text;
  v_category_id      uuid;
  v_default_category uuid;
  v_new_categories   int;
  c_max_new_categories CONSTANT int := 50;  -- OQ-1, sign-off PO 2026-09-03
  -- balanza-etiquetas-pos (D14): nombre de la restricción violada en una fila.
  v_constraint       text;
BEGIN
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- C-21 checkpoint #2 (residuo task_29345f9d): la cuenta se resuelve vía
  -- current_account_ids() — funciona para dueños Y miembros. El método anterior
  -- (accounts.user_id) devolvía NULL para miembros no-dueños y generaba
  -- products huérfanos. Guard duro: sin cuenta no se importa.
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede importar productos'
      USING ERRCODE = 'P0403';
  END IF;

  -- importador-productos-stock-apertura (D1): la sucursal de la apertura es la
  -- principal OPERATIVA canónica de la cuenta — c26_default_branch, la misma que
  -- usan la venta, la compra y el gasto cuando no se elige sucursal (activa y
  -- abierta; recién si no hay ninguna, la más antigua a secas). Antes era "la más
  -- antigua, sin filtrar activas" (ORDER BY created_at LIMIT 1): una cuenta cuya
  -- primera sucursal se desactivó recibía el stock importado en una sucursal en la
  -- que no se vende. Lazy-create si la cuenta no tiene ninguna (mismos campos que
  -- c21_apply_branch_stock_delta).
  v_default_branch := public.c26_default_branch(v_account_id);

  IF v_default_branch IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (v_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_default_branch := public.c26_default_branch(v_account_id);
  END IF;

  -- categoria-default-configurable: primero el default EXPLÍCITO de la
  -- cuenta (accounts.default_product_category_id), sólo si sigue vivo y
  -- activo — una categoría desactivada o soft-deleteada nunca es un default
  -- válido, aunque el puntero siga seteado. Si no hay default configurado o
  -- quedó inactivo/borrado, cae en la heurística de siempre (D6, sin tocar):
  -- "Otros" si sigue viva y activa; si el usuario la renombró o desactivó,
  -- la última activa por sort_order. Sin catálogo activo → NULL (la fila
  -- conserva el TEXT legacy, nunca falla por esto).
  SELECT pc.id INTO v_default_category
    FROM public.accounts a
    JOIN public.product_categories pc
      ON pc.id = a.default_product_category_id
     AND pc.account_id = a.id
     AND pc.deleted_at IS NULL
     AND pc.is_active
   WHERE a.id = v_account_id;

  IF v_default_category IS NULL THEN
    SELECT pc.id INTO v_default_category
      FROM public.product_categories pc
     WHERE pc.account_id = v_account_id
       AND pc.deleted_at IS NULL
       AND pc.is_active
     ORDER BY (lower(pc.name) = 'otros') DESC, pc.sort_order DESC, pc.created_at ASC
     LIMIT 1;
  END IF;

  -- productos-categorias-sku (D6, tope OQ-1): contar las categorías NUEVAS
  -- distintas que trae la llamada ANTES de tocar nada. Superar el tope
  -- aborta toda la llamada (una sola transacción → nada creado): lo más
  -- probable es una columna mal mapeada, no un catálogo legítimo.
  --
  -- importador-productos-fastapi: con rpc_import_products invocando esta
  -- función UNA SOLA VEZ con el archivo entero (D1), este tope pasa a
  -- evaluarse sobre el ARCHIVO — antes, con el troceo de 200 filas del
  -- cliente, era un tope por sub-lote.
  SELECT COUNT(*) INTO v_new_categories
    FROM (
      SELECT DISTINCT lower(public.product_category_normalize_name(r->>'category')) AS n
        FROM jsonb_array_elements(p_rows) AS r
       WHERE public.product_category_normalize_name(r->>'category') IS NOT NULL
    ) d
   WHERE NOT EXISTS (
      SELECT 1 FROM public.product_categories pc
       WHERE pc.account_id = v_account_id
         AND pc.deleted_at IS NULL
         AND lower(pc.name) = d.n
   );

  IF v_new_categories > c_max_new_categories THEN
    RAISE EXCEPTION 'La importación introduce % categorías nuevas y el tope es %. Revisá que la columna "Categoría" del archivo esté bien mapeada (¿no será un código, una descripción o un precio?).',
      v_new_categories, c_max_new_categories
      USING ERRCODE = 'P0400';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      v_existing_id := NULL;
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        -- productos-categorias-sku (D4, eje a): alcance de CUENTA, case-insensitive,
        -- filas vivas — el mismo alcance exacto que idx_products_sku_account_lower.
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE account_id = v_account_id
           AND lower(sku) = lower(v_row->>'sku')
           AND deleted_at IS NULL
         LIMIT 1;
      END IF;

      v_resolved_pid := NULL;

      IF v_row->>'parent_id' IS NOT NULL AND v_row->>'parent_id' <> '' THEN
        v_resolved_pid := (v_row->>'parent_id')::uuid;

      ELSIF v_row->>'sku_parent' IS NOT NULL AND v_row->>'sku_parent' <> '' THEN
        -- productos-categorias-sku (D4, eje a): idem, por cuenta.
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE account_id = v_account_id
           AND lower(sku) = lower(v_row->>'sku_parent')
           AND deleted_at IS NULL
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'SKU Padre "%" no encontrado para la variante "%"',
            v_row->>'sku_parent', v_row->>'name';
        END IF;

      ELSIF v_row->>'parent_name' IS NOT NULL AND v_row->>'parent_name' <> '' THEN
        -- productos-categorias-sku (D4, eje a): idem, por cuenta.
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE account_id = v_account_id
           AND name = v_row->>'parent_name'
           AND (is_variant = false OR is_variant IS NULL)
           AND parent_id IS NULL
           AND deleted_at IS NULL
         ORDER BY created_at DESC
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'Producto Padre "%" no encontrado para la variante "%"',
            v_row->>'parent_name', v_row->>'name';
        END IF;
      END IF;

      -- productos-categorias-sku (D6, eje b): resolver la categoría contra el
      -- catálogo de la cuenta (case-insensitive, tolerante a espacios) y
      -- crearla si falta. Va DESPUÉS de la resolución del padre (que puede
      -- fallar) y DENTRO del sub-bloque de la fila: si el INSERT/UPDATE del
      -- producto falla, la creación se revierte con la fila.
      v_category_id := NULL;
      v_cat_name    := public.product_category_normalize_name(v_row->>'category');
      IF v_cat_name IS NOT NULL THEN
        SELECT pc.id INTO v_category_id
          FROM public.product_categories pc
         WHERE pc.account_id = v_account_id
           AND pc.deleted_at IS NULL
           AND lower(pc.name) = lower(v_cat_name)
         LIMIT 1;

        IF v_category_id IS NULL THEN
          INSERT INTO public.product_categories (account_id, name, sort_order)
          VALUES (
            v_account_id,
            v_cat_name,
            COALESCE((SELECT MAX(sort_order) + 1
                        FROM public.product_categories
                       WHERE account_id = v_account_id AND deleted_at IS NULL), 1)
          )
          RETURNING id INTO v_category_id;
        END IF;
      END IF;

      v_stock_qty := COALESCE((v_row->>'stock')::numeric, 0);
      v_is_new    := (v_existing_id IS NULL);

      IF v_existing_id IS NOT NULL THEN
        -- C-21 checkpoint #2: products.stock no existe — el stock va solo a branch_stock.
        -- productos-categoria-text-retiro: la columna TEXT de categoría ya no
        -- existe — el nombre lo deriva la vista desde category_id (D1).
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category_id        = COALESCE(v_category_id,                   category_id),
          -- productos-padre-variantes (D3, checkpoint 1.3): un padre variant_only no
          -- lleva precio ni costo (CHECK products_variant_only_no_price_cost). El
          -- tipo EFECTIVO es el de la fila si viene, si no el vigente; si es padre,
          -- se fuerza price = 0 y cost = NULL (también al convertir un producto
          -- existente en padre por SKU). Un producto simple no cambia.
          price              = CASE WHEN COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type) = 'variant_only'
                                    THEN 0
                                    ELSE COALESCE((v_row->>'price')::numeric,      price) END,
          -- productos-costo-nullable (D10): celda vacía en la EDICIÓN
          -- conserva el costo que el producto tenía — no lo borra. Es la
          -- misma convención tri-estado-por-ausencia que sku/category_id.
          cost               = CASE WHEN COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type) = 'variant_only'
                                    THEN NULL
                                    ELSE COALESCE((v_row->>'cost')::numeric,       cost) END,
          min_stock          = COALESCE((v_row->>'min_stock')::integer,  min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),    barcode),
          -- balanza-etiquetas-pos (D14): celda ausente o vacía conserva el código
          -- de balanza vigente (misma regla que barcode — el importador no desasigna).
          scale_plu          = COALESCE(NULLIF(v_row->>'scale_plu','')::int, scale_plu),
          parent_id          = COALESCE(v_resolved_pid,                  parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type),
          account_id         = COALESCE(account_id, v_account_id)
        WHERE id = v_existing_id AND account_id = v_account_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;

      ELSE
        -- productos-categoria-text-retiro: la columna de categoría se retiró
        -- del INSERT — no existe más la columna física ni el trigger que la pisaba.
        INSERT INTO public.products (
          user_id, account_id, name, category_id, price, cost, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type,
          scale_plu  -- balanza-etiquetas-pos (D14)
        ) VALUES (
          p_user_id,
          v_account_id,
          v_row->>'name',
          COALESCE(v_category_id, v_default_category),
          -- productos-padre-variantes (D3): el alta de un Padre (variant_only) nace
          -- con price = 0 y cost = NULL aunque el archivo traiga valores.
          CASE WHEN COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked') = 'variant_only'
               THEN 0 ELSE COALESCE((v_row->>'price')::numeric, 0) END,
          -- productos-costo-nullable (D10): celda vacía en el ALTA queda
          -- NULL (sin costo), no 0. Un padre variant_only fuerza NULL arriba.
          CASE WHEN COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked') = 'variant_only'
               THEN NULL ELSE (v_row->>'cost')::numeric END,
          COALESCE((v_row->>'min_stock')::integer, 0),
          NULLIF(v_row->>'barcode', ''),
          NULLIF(v_row->>'sku',     ''),
          v_resolved_pid,
          COALESCE((v_row->>'is_variant')::boolean, false),
          COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked'),
          NULLIF(v_row->>'scale_plu', '')::int
        )
        RETURNING id INTO v_product_id;

        v_inserted := v_inserted + 1;
      END IF;

      -- importador-productos-stock-apertura (D3/D4): fila de saldo en la principal
      -- operativa. Se asegura (sin tocar el saldo) en dos casos: el ALTA con una
      -- celda de stock informada, y cualquier fila con un MÍNIMO informado. En un
      -- alta nace con cantidad 0 (el stock entra por el movimiento de apertura de
      -- abajo, no por un set absoluto); en una EDICIÓN el DO UPDATE toca SÓLO el
      -- umbral, y sólo si vino — una celda vacía conserva el que había (antes el
      -- EXCLUDED lo pisaba con 0 y apagaba la alerta de stock crítico).
      IF v_default_branch IS NOT NULL
         AND v_product_id IS NOT NULL
         AND (v_row->>'min_stock' IS NOT NULL
              OR (v_is_new AND v_row->>'stock' IS NOT NULL))
      THEN
        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
        VALUES (
          v_account_id,
          v_product_id,
          v_default_branch,
          0,
          COALESCE((v_row->>'min_stock')::integer, 0)
        )
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET
            min_stock = COALESCE((v_row->>'min_stock')::integer, public.branch_stock.min_stock);
      END IF;

      -- importador-productos-stock-apertura (D2/D3): el stock del archivo es de
      -- APERTURA — sólo para el producto que este lote CREA. Entra por el helper
      -- canónico de operaciones (op_stock_movement: c21_apply_branch_stock_delta +
      -- el movimiento con antes/después), igual que toda otra escritura del ledger,
      -- y deja UN movimiento 'adjustment' con el motivo «Stock inicial …», el mismo
      -- tipo con que el alta manual registra el suyo, sellado con cuenta, sucursal y
      -- autor. Un producto que YA EXISTE (match por SKU) no recibe stock por esta
      -- vía: reimportar un archivo distinto pisaba el saldo vivo con la cuenta
      -- hecha al primer import (vendí 5 de 20, reimporto 20, vuelve a 20) y el
      -- ledger dejaba de reconciliar. Corregir el stock de un producto existente es
      -- el ajuste de stock / el conteo físico de /stock, que sí dejan su rastro.
      IF v_is_new
         AND v_default_branch IS NOT NULL
         AND v_product_id IS NOT NULL
         AND v_stock_qty <> 0
      THEN
        PERFORM public.op_stock_movement(
          v_account_id, p_user_id, v_product_id, v_row->>'name', v_default_branch,
          v_stock_qty, 'adjustment', NULL, NULL, NULL, NULL,
          'Stock inicial (importación)', NULL);
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
      -- balanza-etiquetas-pos (D14): el SQLERRM de un 23505 no trae el valor de
      -- la clave (viaja en PG_EXCEPTION_DETAIL); para las dos restricciones del
      -- código de balanza el mensaje nombra el código. El resto conserva SQLERRM.
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      v_error_detail := jsonb_build_object(
        'row',     (v_row->>'row_no')::int,   -- ← importador-productos-fastapi (D2): ÚNICA adición
        'sku',     v_row->>'sku',
        'name',    v_row->>'name',
        'message', CASE
                     WHEN SQLSTATE = '23505' AND v_constraint = 'idx_products_scale_plu_account_unique' THEN
                       format('El código de balanza %s ya lo usa otro producto de tu cuenta', v_row->>'scale_plu')
                     WHEN SQLSTATE = '23514' AND v_constraint = 'products_scale_plu_not_parent' THEN
                       'El código de balanza se asigna a cada variante, no al producto padre'
                     ELSE SQLERRM
                   END
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

REVOKE ALL ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO service_role;
