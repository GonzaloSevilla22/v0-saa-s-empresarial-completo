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
-- 2b. rpc_bulk_upsert_products: la rama Padre del importador fuerza price = 0 y
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

-- =============================================================================
-- 3. fn_product_base_unit_guard: re-derivado del cuerpo VIVO, con UN corte (D6)
-- =============================================================================
-- Base: pg_get_functiondef VIVO de prod (md5 sin CR 89b462c5169f867da49610d84b4d4962,
-- idéntico al de 20261069000001_remitos_venta.sql, medido el 2026-11-05). Sólo se
-- agrega el bloque marcado «productos-padre-variantes (D6)». Misma firma ():
-- CREATE OR REPLACE conserva el disparador trg_product_base_unit_guard y la ACL.
-- Cuerpo previo (rollback): el de 20261069000001_remitos_venta.sql.
CREATE OR REPLACE FUNCTION public.fn_product_base_unit_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_unit_system  boolean;
  v_unit_account uuid;
  v_parent_base  uuid;
  v_old_parent_base  uuid;
  v_old_eff      uuid;
  v_new_eff      uuid;
  v_self_changed      boolean;
  v_children_changed  boolean;
  v_self_assigned     boolean;
  v_children_assigned boolean;
  v_stash             jsonb;
  v_conflict_unit     uuid;
BEGIN
  -- Cuarta revisión: DELETE físico de un PADRE. products_parent_id_fkey es ON
  -- DELETE SET NULL: la acción referencial desengancha a las variantes que
  -- sobreviven, y cuando ese UPDATE llega a este trigger el padre ya no es
  -- visible — la unidad que heredaban se perdía sin control ("5 kg" → "5
  -- uds"; `authenticated` tiene DELETE por products_writer_delete). Acá se
  -- toman FOR UPDATE las variantes que heredan (serializa con una venta o
  -- compra de la variante) y la unidad del padre queda en un GUC LOCAL de la
  -- transacción; la rama UPDATE la lee cuando no encuentra al padre y decide
  -- con el stock de la variante que QUEDA. Borrar el padre junto con sus
  -- variantes en la misma sentencia no traba nada: la acción referencial corre
  -- al final de la sentencia y ya no las encuentra.
  IF TG_OP = 'DELETE' THEN
    IF OLD.base_unit_id IS NOT NULL THEN
      PERFORM 1 FROM public.products v
       WHERE v.parent_id = OLD.id AND v.base_unit_id IS NULL
       ORDER BY v.id
       FOR UPDATE;
      IF FOUND THEN
        v_stash := COALESCE(NULLIF(current_setting('ventas_uom.deleted_parent_base', true), ''), '{}')::jsonb;
        PERFORM set_config('ventas_uom.deleted_parent_base',
                           (v_stash || jsonb_build_object(OLD.id::text, OLD.base_unit_id::text))::text, true);
      END IF;
    END IF;
    RETURN OLD;
  END IF;

  -- Tenencia: sólo cuando la unidad base (o la cuenta) efectivamente cambia.
  IF NEW.base_unit_id IS NOT NULL AND (
       TG_OP = 'INSERT'
       OR NEW.base_unit_id IS DISTINCT FROM OLD.base_unit_id
       OR NEW.account_id   IS DISTINCT FROM OLD.account_id) THEN
    SELECT COALESCE(u.is_system, false), u.account_id
      INTO v_unit_system, v_unit_account
      FROM public.units_of_measure u
     WHERE u.id = NEW.base_unit_id;
    IF NOT FOUND OR (NOT v_unit_system AND v_unit_account IS DISTINCT FROM NEW.account_id) THEN
      RAISE EXCEPTION 'base_unit_not_found: la unidad base no existe o no pertenece a la cuenta del producto'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- productos-padre-variantes (D6, ÚNICO cambio respecto del cuerpo vivo): salida del
  -- guard para la CORRECCIÓN EXPLÍCITA de la unidad de una familia
  -- (rpc_relabel_product_unit). La RPC escribe el GUC LOCAL
  -- products.unit_relabel_root con el id de la RAÍZ del grupo que ya bloqueó; sólo
  -- las filas de ESE grupo (la raíz y sus variantes) pasan sin los chequeos de
  -- stock/historia, y sólo si no cambian de padre ni de cuenta: re-parentar, mover de
  -- cuenta o tocar otro producto en la misma transacción siguen pasando por el
  -- guard completo. Va DESPUÉS del chequeo de tenencia de la unidad (la unidad nueva
  -- se valida igual). `authenticated` no puede escribir este GUC por PostgREST
  -- (set_config vive en pg_catalog, fuera de los esquemas expuestos): un PATCH
  -- directo sigue recibiendo P0409 base_unit_locked. Anidado, no con AND: OLD no
  -- existe en un INSERT y el orden de evaluación de un AND no está garantizado.
  IF TG_OP = 'UPDATE' THEN
    IF NULLIF(current_setting('products.unit_relabel_root', true), '') = COALESCE(NEW.parent_id, NEW.id)::text THEN
      IF NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id AND NEW.account_id = OLD.account_id THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  -- Tercera revisión: la unidad base EFECTIVA de una variante que hereda
  -- también cambia si se la RE-PARENTA (o se la desengancha): `authenticated`
  -- tiene UPDATE sobre products.parent_id, y re-parentar 5 kg a un padre en
  -- 'u' los dejaba leyéndose 5 u (reproducido por PostgREST).
  IF TG_OP = 'INSERT'
     OR (NEW.base_unit_id IS NOT DISTINCT FROM OLD.base_unit_id
         AND NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id) THEN
    RETURN NEW;
  END IF;

  -- Unidad base EFECTIVA antes y después: la propia o la heredada del padre
  -- (misma regla que _uom_normalize_quantity y v_products_with_stock) — el
  -- padre de OLD para la de antes y el de NEW para la de después.
  IF OLD.parent_id IS NOT NULL THEN
    SELECT p.base_unit_id INTO v_old_parent_base FROM public.products p WHERE p.id = OLD.parent_id;
    IF NOT FOUND THEN
      -- Cuarta revisión: el padre se está borrando en esta misma sentencia
      -- (este UPDATE es la acción referencial ON DELETE SET NULL); su unidad
      -- la dejó la rama DELETE en el GUC local.
      v_old_parent_base := NULLIF(
        COALESCE(NULLIF(current_setting('ventas_uom.deleted_parent_base', true), ''), '{}')::jsonb
          ->> OLD.parent_id::text, '')::uuid;
    END IF;
  END IF;
  IF NEW.parent_id IS NOT NULL THEN
    IF NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
      -- Cuarta revisión (write skew): re-parentar bajo P2 mientras otra
      -- transacción cambia la unidad base de P2. El FK sólo toma KEY SHARE
      -- sobre P2, que no choca con el NO KEY UPDATE del cambio de base, y ese
      -- cambio no ve todavía a esta variante como hija: los dos pasaban.
      -- FOR SHARE sí choca: el que llega segundo espera y decide sobre lo
      -- commiteado (test_ventas_unidades_conversion_race.sh, (d) y (e)).
      SELECT p.base_unit_id INTO v_parent_base FROM public.products p WHERE p.id = NEW.parent_id FOR SHARE;
    ELSE
      SELECT p.base_unit_id INTO v_parent_base FROM public.products p WHERE p.id = NEW.parent_id;
    END IF;
  END IF;
  v_old_eff := COALESCE(OLD.base_unit_id, v_old_parent_base);
  v_new_eff := COALESCE(NEW.base_unit_id, v_parent_base);

  -- Sin cambio efectivo no hay nada que proteger. Dos grupos, cada uno con su
  -- condición:
  --   · el producto mismo, si SU unidad efectiva cambia (base propia o padre);
  --   · las variantes que HEREDAN su base propia, si la base PROPIA cambia
  --     (re-parentar al producto no las toca: heredan NEW.base_unit_id, no la
  --     unidad efectiva de NEW).
  -- CAMBIAR (de una unidad a otra, o quitarla) con stock o movimientos → P0409.
  -- ASIGNAR (de ninguna a una) — cuarta revisión: también → P0409 si el grupo
  -- tiene stock o movimientos Y alguna línea grabada con una unidad EXPLÍCITA
  -- distinta de la que se asigna. Un producto sin unidad base admite líneas
  -- en cualquier unidad base (kg, L, u): con historia en kg, asignarle 'g'
  -- dejaba el stock 1000 veces menor, y con historia en 'u', asignarle 'kg'
  -- lo reinterpretaba en kilos (redteam-3a/30-31). Las líneas SIN unidad no
  -- declaran ninguna: sobre ellas la asignación sigue permitida (D-C).
  v_self_changed      := v_old_eff IS NOT NULL AND v_old_eff IS DISTINCT FROM v_new_eff;
  v_children_changed  := OLD.base_unit_id IS NOT NULL AND NEW.base_unit_id IS DISTINCT FROM OLD.base_unit_id;
  v_self_assigned     := v_old_eff IS NULL AND v_new_eff IS NOT NULL;
  v_children_assigned := OLD.base_unit_id IS NULL AND NEW.base_unit_id IS NOT NULL;
  IF NOT (v_self_changed OR v_children_changed OR v_self_assigned OR v_children_assigned) THEN
    RETURN NEW;
  END IF;

  -- Las variantes que heredan se toman FOR UPDATE (orden de id) para
  -- serializar con las ventas/compras, que toman la fila de su producto.
  IF v_children_changed OR v_children_assigned THEN
    PERFORM 1 FROM public.products v
     WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL
     ORDER BY v.id
     FOR UPDATE;
  END IF;

  IF (v_self_changed OR v_children_changed) AND (
       EXISTS (
         SELECT 1 FROM public.branch_stock bs
          WHERE bs.quantity <> 0
            AND ((v_self_changed AND bs.product_id = NEW.id)
                 OR (v_children_changed
                     AND bs.product_id IN (SELECT v.id FROM public.products v
                                            WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL))))
       OR EXISTS (
         SELECT 1 FROM public.stock_movements sm
          WHERE (v_self_changed AND sm.product_id = NEW.id)
             OR (v_children_changed
                 AND sm.product_id IN (SELECT v.id FROM public.products v
                                        WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL)))) THEN
    RAISE EXCEPTION 'base_unit_locked: el producto % ya tiene stock o movimientos en su unidad base actual; cambiarla haría que las cantidades se lean en otra unidad. Creá un producto nuevo con la unidad correcta y pasale el stock con un ajuste.', NEW.id
      USING ERRCODE = 'P0409';
  END IF;

  IF v_self_assigned OR v_children_assigned THEN
    -- Los productos cuya unidad efectiva se asigna, cada uno con la unidad
    -- que pasaría a tener; y la primera línea grabada en otra unidad.
    WITH grp AS (
      SELECT NEW.id AS product_id, v_new_eff AS target WHERE v_self_assigned
      UNION ALL
      SELECT v.id, NEW.base_unit_id FROM public.products v
       WHERE v_children_assigned AND v.parent_id = NEW.id AND v.base_unit_id IS NULL
    ), lines AS (
      SELECT s.product_id, s.unit_id FROM public.sales s WHERE s.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      SELECT pu.product_id, pu.unit_id FROM public.purchases pu WHERE pu.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      SELECT si.product_id, si.unit_id FROM public.sale_items si WHERE si.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      SELECT pi.product_id, pi.unit_id FROM public.purchase_items pi WHERE pi.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      SELECT soi.product_id, soi.unit_id FROM public.sales_order_items soi WHERE soi.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      SELECT qi.product_id, qi.unit_id FROM public.quote_items qi WHERE qi.product_id IN (SELECT g.product_id FROM grp g)
      UNION ALL
      -- remitos-venta (D14): las líneas del remito también graban la unidad.
      SELECT dni.product_id, dni.unit_id FROM public.delivery_note_items dni WHERE dni.product_id IN (SELECT g.product_id FROM grp g)
    )
    SELECT l.unit_id INTO v_conflict_unit
      FROM lines l JOIN grp g ON g.product_id = l.product_id
     WHERE l.unit_id IS NOT NULL AND l.unit_id IS DISTINCT FROM g.target
     LIMIT 1;

    IF v_conflict_unit IS NOT NULL AND (
         EXISTS (
           SELECT 1 FROM public.branch_stock bs
            WHERE bs.quantity <> 0
              AND ((v_self_assigned AND bs.product_id = NEW.id)
                   OR (v_children_assigned
                       AND bs.product_id IN (SELECT v.id FROM public.products v
                                              WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL))))
         OR EXISTS (
           SELECT 1 FROM public.stock_movements sm
            WHERE (v_self_assigned AND sm.product_id = NEW.id)
               OR (v_children_assigned
                   AND sm.product_id IN (SELECT v.id FROM public.products v
                                          WHERE v.parent_id = NEW.id AND v.base_unit_id IS NULL)))) THEN
      RAISE EXCEPTION 'base_unit_locked: el producto % tiene stock o movimientos y operaciones cargadas en otra unidad (%); asignarle la unidad base % haría que esas cantidades se lean en la unidad nueva. Asignale la unidad en que ya lo venías cargando, o creá un producto nuevo con la unidad correcta y pasale el stock con un ajuste.',
        NEW.id,
        COALESCE((SELECT u.symbol FROM public.units_of_measure u WHERE u.id = v_conflict_unit), v_conflict_unit::text),
        COALESCE((SELECT u.symbol FROM public.units_of_measure u WHERE u.id = COALESCE(v_new_eff, NEW.base_unit_id)), COALESCE(v_new_eff, NEW.base_unit_id)::text)
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
-- COMMENT y ACL: se conservan los vivos (CREATE OR REPLACE no los toca).

-- =============================================================================
-- 4. rpc_relabel_product_unit (D5): corrección de la unidad de una FAMILIA, sin
--    convertir cantidades
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_relabel_product_unit(uuid, uuid, boolean);
CREATE FUNCTION public.rpc_relabel_product_unit(
  p_product_id  uuid,
  p_new_unit_id uuid,
  p_dry_run     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_account       uuid;
  v_root          uuid;
  v_unit_before   uuid;
  v_group         uuid[];
  v_variants      integer;
  v_variants_own  integer;
  v_with_stock    integer;
  v_movements     integer;
  v_conflict      uuid;
  v_own_before    jsonb;
  v_result        jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- 1. El producto y su cuenta. Inexistente, borrado o de una cuenta que no es la
  --    activa del usuario: el MISMO P0404 (no revela si existe en otro lado).
  SELECT p.account_id, COALESCE(p.parent_id, p.id)
    INTO v_account, v_root
    FROM public.products p
   WHERE p.id = p_product_id AND p.deleted_at IS NULL;
  IF v_account IS NULL OR NOT EXISTS (SELECT 1 FROM public.current_account_ids() AS cai WHERE cai = v_account) THEN
    RAISE EXCEPTION 'product_not_found: el producto no existe o no pertenece a tu cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- Rol: sin escritura en la cuenta P0401; con escritura pero sin ser dueño o
  -- administrador P0403 insufficient_role. Corregir la unidad reinterpreta el stock
  -- de toda la familia: es una acción de configuración, no de operación.
  PERFORM public._account_assert_capability(
    v_account, ARRAY['owner', 'admin'],
    'tu rol no permite corregir la unidad de medida (requiere administrador o dueño)');

  IF p_new_unit_id IS NULL THEN
    RAISE EXCEPTION 'unit_required: elegí la unidad de medida de la familia'
      USING ERRCODE = 'P0400';
  END IF;
  -- Misma regla de tenencia que el trigger de la unidad base: del sistema o de la cuenta.
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure u
                  WHERE u.id = p_new_unit_id
                    AND (COALESCE(u.is_system, false) OR u.account_id = v_account)) THEN
    RAISE EXCEPTION 'base_unit_not_found: la unidad no existe o no pertenece a tu cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- 2. Locks: la raíz y luego las variantes vivas POR ORDEN DE ID (el mismo orden
  --    que el trigger de la unidad base y que las RPCs de venta/compra, que toman
  --    la fila del producto antes de normalizar): sin interbloqueo posible.
  SELECT p.base_unit_id INTO v_unit_before
    FROM public.products p
   WHERE p.id = v_root AND p.account_id = v_account AND p.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found: el producto no existe o no pertenece a tu cuenta'
      USING ERRCODE = 'P0404';
  END IF;
  PERFORM 1
    FROM public.products v
   WHERE v.parent_id = v_root AND v.account_id = v_account AND v.deleted_at IS NULL
   ORDER BY v.id
   FOR UPDATE;

  -- 3. Impacto (igual en dry-run). El grupo es la raíz más sus variantes vivas.
  SELECT count(*), count(*) FILTER (WHERE v.base_unit_id IS NOT NULL),
         COALESCE(jsonb_agg(jsonb_build_object('id', v.id, 'unit_before', v.base_unit_id) ORDER BY v.id)
                  FILTER (WHERE v.base_unit_id IS NOT NULL), '[]'::jsonb)
    INTO v_variants, v_variants_own, v_own_before
    FROM public.products v
   WHERE v.parent_id = v_root AND v.account_id = v_account AND v.deleted_at IS NULL;
  v_group := ARRAY[v_root] || COALESCE(
    (SELECT array_agg(v.id) FROM public.products v
      WHERE v.parent_id = v_root AND v.account_id = v_account AND v.deleted_at IS NULL), '{}'::uuid[]);
  SELECT count(DISTINCT bs.product_id) INTO v_with_stock
    FROM public.branch_stock bs
   WHERE bs.account_id = v_account AND bs.product_id = ANY (v_group) AND bs.quantity <> 0;
  SELECT count(*) INTO v_movements
    FROM public.stock_movements sm
   WHERE sm.account_id = v_account AND sm.product_id = ANY (v_group);

  v_result := jsonb_build_object(
    'changed',                false,
    'root_id',                v_root,
    'unit_before',            v_unit_before,
    'unit_after',             p_new_unit_id,
    'variants',               v_variants,
    'variants_with_own_unit', v_variants_own,
    'products_with_stock',    v_with_stock,
    'movements',              v_movements,
    'conflict_unit',          NULL);

  -- 4. Sin efecto: la raíz ya tiene esa unidad y ninguna variante declara una propia.
  --    Idempotente: no escribe, no audita, y no mira conflictos (nada cambiaría).
  IF v_unit_before IS NOT DISTINCT FROM p_new_unit_id AND v_variants_own = 0 THEN
    RETURN v_result;
  END IF;

  -- 5. Conflicto: alguna línea del grupo se grabó con una unidad EXPLÍCITA distinta de
  --    la nueva. Es el mismo UNION de líneas de fn_product_base_unit_guard (ramas de
  --    asignación) y de has_lines_in_other_unit. Un relabel que las dejara así
  --    reinterpretaría esas cantidades en silencio.
  SELECT l.unit_id INTO v_conflict
    FROM (
      SELECT s.unit_id   FROM public.sales s               WHERE s.product_id   = ANY (v_group)
      UNION ALL
      SELECT pu.unit_id  FROM public.purchases pu          WHERE pu.product_id  = ANY (v_group)
      UNION ALL
      SELECT si.unit_id  FROM public.sale_items si         WHERE si.product_id  = ANY (v_group)
      UNION ALL
      SELECT pi.unit_id  FROM public.purchase_items pi     WHERE pi.product_id  = ANY (v_group)
      UNION ALL
      SELECT soi.unit_id FROM public.sales_order_items soi WHERE soi.product_id = ANY (v_group)
      UNION ALL
      SELECT qi.unit_id  FROM public.quote_items qi        WHERE qi.product_id  = ANY (v_group)
      UNION ALL
      SELECT dni.unit_id FROM public.delivery_note_items dni WHERE dni.product_id = ANY (v_group)
    ) l
   WHERE l.unit_id IS NOT NULL AND l.unit_id <> p_new_unit_id
   LIMIT 1;

  v_result := jsonb_set(v_result, '{changed}', 'true'::jsonb);
  IF v_conflict IS NOT NULL THEN
    IF p_dry_run THEN
      -- La vista previa lo informa en vez de lanzar: el diálogo lo explica.
      RETURN jsonb_set(v_result, '{conflict_unit}', to_jsonb(v_conflict));
    END IF;
    RAISE EXCEPTION 'unit_relabel_conflict: la familia tiene operaciones cargadas en %; corregir la unidad a otra distinta reinterpretaría esas cantidades. Corregila a esa unidad o creá un producto nuevo con la unidad correcta.',
      COALESCE((SELECT u.symbol FROM public.units_of_measure u WHERE u.id = v_conflict), v_conflict::text)
      USING ERRCODE = 'P0409';
  END IF;

  IF p_dry_run THEN
    RETURN v_result;
  END IF;

  -- 6. Escritura. El GUC es LOCAL a la transacción y lo escribe SÓLO esta función: le
  --    avisa a fn_product_base_unit_guard que estas filas (las de ESTE grupo, ya
  --    bloqueadas) cambian de unidad por una corrección explícita. Se vuelve a vaciar
  --    apenas termina.
  PERFORM set_config('products.unit_relabel_root', v_root::text, true);
  UPDATE public.products
     SET base_unit_id = p_new_unit_id
   WHERE id = v_root AND account_id = v_account;
  UPDATE public.products
     SET base_unit_id = NULL
   WHERE parent_id = v_root AND account_id = v_account AND deleted_at IS NULL AND base_unit_id IS NOT NULL;
  PERFORM set_config('products.unit_relabel_root', '', true);

  -- 7. Auditoría: lo que hace falta para revertir con otro relabel.
  INSERT INTO public.audit_logs (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account, auth.uid(), 'product.unit_relabel', 'product', v_root,
    jsonb_build_object(
      'unit_before',                    v_unit_before,
      'unit_after',                     p_new_unit_id,
      'variants',                       v_variants,
      'variants_with_own_unit_before',  v_own_before,
      'products_with_stock',            v_with_stock,
      'movements',                      v_movements),
    now());

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_relabel_product_unit(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_relabel_product_unit(uuid, uuid, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_relabel_product_unit(uuid, uuid, boolean) IS
  $c$productos-padre-variantes (D5): corrige la unidad base de una FAMILIA (el producto normalizado a su raíz y todas sus variantes) como un CAMBIO DE RÓTULO: ninguna cantidad de branch_stock, stock_movements ni de ninguna línea se convierte. La raíz queda con la unidad nueva y todas las variantes vivas heredándola (base_unit_id NULL). Sólo dueño o administrador (P0403 insufficient_role); producto ajeno/inexistente P0404 product_not_found; sin unidad P0400 unit_required; unidad ajena P0404 base_unit_not_found; una línea del grupo con otra unidad explícita P0409 unit_relabel_conflict (en dry-run viaja en conflict_unit). Sin efecto -> changed=false sin escribir ni auditar. Audita product.unit_relabel con lo necesario para revertir con otro relabel. Es la ÚNICA excepción al bloqueo base_unit_locked: lo reconoce fn_product_base_unit_guard por el GUC local products.unit_relabel_root, atado a la raíz.$c$;

-- =============================================================================
-- 5. rpc_bulk_adjust_prices (D8): modificación de precios en lote
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_bulk_adjust_prices(uuid[], text, text, numeric, boolean);
CREATE FUNCTION public.rpc_bulk_adjust_prices(
  p_product_ids uuid[],
  p_mode        text,
  p_direction   text,
  p_value       numeric,
  p_dry_run     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_account    uuid;
  v_sign       integer;
  v_requested  integer;
  v_eligible   integer;
  v_skipped    integer;
  v_rows       jsonb;
  v_changed    integer;
  v_clamped    integer;
  v_sample     jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  SELECT cai INTO v_account FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  -- Rol: sin escritura P0401; sin ser dueño o administrador P0403 insufficient_role.
  PERFORM public._account_assert_capability(
    v_account, ARRAY['owner', 'admin'],
    'tu rol no permite modificar precios en lote (requiere administrador o dueño)');

  -- Validación (P0400 con literal estable; la API lo devuelve como 422, sin escribir).
  IF p_mode IS NULL OR p_mode NOT IN ('percent', 'amount') THEN
    RAISE EXCEPTION 'bulk_price_invalid_mode: el modo tiene que ser porcentaje o importe fijo' USING ERRCODE = 'P0400';
  END IF;
  IF p_direction IS NULL OR p_direction NOT IN ('increase', 'decrease') THEN
    RAISE EXCEPTION 'bulk_price_invalid_direction: la dirección tiene que ser aumento o baja' USING ERRCODE = 'P0400';
  END IF;
  IF p_value IS NULL OR p_value <= 0 THEN
    RAISE EXCEPTION 'bulk_price_invalid_value: el valor tiene que ser mayor que 0' USING ERRCODE = 'P0400';
  END IF;
  -- Porcentaje efectivo entre -90 y +1000.
  IF p_mode = 'percent'
     AND ((p_direction = 'decrease' AND p_value > 90) OR (p_direction = 'increase' AND p_value > 1000)) THEN
    RAISE EXCEPTION 'bulk_price_out_of_range: el porcentaje tiene que estar entre una baja del 90 %% y un aumento del 1000 %%' USING ERRCODE = 'P0400';
  END IF;
  IF p_product_ids IS NULL OR cardinality(p_product_ids) = 0 THEN
    RAISE EXCEPTION 'bulk_price_no_products: elegí al menos un producto' USING ERRCODE = 'P0400';
  END IF;
  IF cardinality(p_product_ids) > 500 THEN
    RAISE EXCEPTION 'bulk_price_too_many_ids: como máximo 500 productos por llamada' USING ERRCODE = 'P0400';
  END IF;

  v_sign := CASE p_direction WHEN 'increase' THEN 1 ELSE -1 END;
  SELECT count(DISTINCT x) INTO v_requested FROM unnest(p_product_ids) AS x;

  -- Al aplicar, la familia se toma FOR UPDATE por orden de id: dos lotes concurrentes
  -- no se pisan con un cálculo hecho sobre un precio viejo. La vista previa no bloquea.
  IF NOT p_dry_run THEN
    PERFORM 1
      FROM public.products p
     WHERE p.account_id = v_account AND p.deleted_at IS NULL
       AND COALESCE(p.parent_id, p.id) IN (
             SELECT COALESCE(r.parent_id, r.id) FROM public.products r
              WHERE r.id = ANY (p_product_ids) AND r.account_id = v_account AND r.deleted_at IS NULL)
     ORDER BY p.id
     FOR UPDATE;
  END IF;

  -- Alcance y cálculo (UNA sola definición, la misma para la vista previa y la aplicación):
  -- los ids se normalizan a su raíz y se expanden a la raíz más sus variantes vivas; los
  -- padres variant_only no tienen precio y se omiten. El filtro de cuenta es el guard de
  -- tenencia: un id ajeno o borrado no produce error ni revela existencia.
  WITH req AS (
    SELECT DISTINCT COALESCE(p.parent_id, p.id) AS root_id
      FROM public.products p
     WHERE p.id = ANY (p_product_ids) AND p.account_id = v_account AND p.deleted_at IS NULL
  ), fam AS (
    SELECT p.id, p.name, p.price, (p.stock_control_type IS NOT DISTINCT FROM 'variant_only') AS is_parent
      FROM public.products p
      JOIN req r ON (p.id = r.root_id OR p.parent_id = r.root_id)
     WHERE p.account_id = v_account AND p.deleted_at IS NULL
  ), calc AS (
    SELECT f.id, f.name, f.price AS price_before, f.is_parent,
           CASE p_mode
             WHEN 'percent' THEN public.product_round_price(f.price * (1 + v_sign * p_value / 100))
             ELSE public.product_round_price(f.price + v_sign * p_value)
           END AS raw_price
      FROM fam f
  ), final AS (
    SELECT c.*, GREATEST(0, c.raw_price) AS price_after FROM calc c
  )
  SELECT count(*) FILTER (WHERE NOT is_parent),
         count(*) FILTER (WHERE is_parent),
         COALESCE(jsonb_agg(jsonb_build_object(
                    'id', id, 'name', name, 'price_before', price_before, 'price_after', price_after,
                    'clamped', raw_price < 0) ORDER BY name, id)
                  FILTER (WHERE NOT is_parent AND price_after <> price_before), '[]'::jsonb)
    INTO v_eligible, v_skipped, v_rows
    FROM final;

  v_changed := jsonb_array_length(v_rows);
  SELECT count(*) INTO v_clamped FROM jsonb_array_elements(v_rows) AS e WHERE (e ->> 'clamped')::boolean;
  SELECT COALESCE(jsonb_agg(s.x - 'clamped'), '[]'::jsonb) INTO v_sample
    FROM (SELECT t.x FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS t(x, n) ORDER BY t.n LIMIT 10) s;

  IF NOT p_dry_run AND v_changed > 0 THEN
    -- UN solo UPDATE atómico por llamada.
    UPDATE public.products p
       SET price = (r ->> 'price_after')::numeric
      FROM jsonb_array_elements(v_rows) AS r
     WHERE p.id = (r ->> 'id')::uuid
       AND p.account_id = v_account
       AND p.price IS DISTINCT FROM (r ->> 'price_after')::numeric;

    INSERT INTO public.audit_logs (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
    VALUES (
      v_account, auth.uid(), 'product.bulk_price_adjusted', 'product', NULL,
      jsonb_build_object(
        'mode',        p_mode,
        'direction',   p_direction,
        'value',       p_value,
        'changed',     v_changed,
        'clamped',     v_clamped,
        'product_ids', (SELECT jsonb_agg(e -> 'id') FROM jsonb_array_elements(v_rows) AS e)),
      now());
  END IF;

  RETURN jsonb_build_object(
    'requested',       v_requested,
    'eligible',        v_eligible,
    'changed',         v_changed,
    'unchanged',       v_eligible - v_changed,
    'skipped_parents', v_skipped,
    'clamped',         v_clamped,
    'sample',          v_sample);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bulk_adjust_prices(uuid[], text, text, numeric, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_adjust_prices(uuid[], text, text, numeric, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_bulk_adjust_prices(uuid[], text, text, numeric, boolean) IS
  $c$productos-padre-variantes (D8): modifica el PRECIO (nunca el costo) de varios productos a la vez. Modo percent (precio por 1 ± valor/100) o amount (precio ± valor, piso 0), redondeado con product_round_price; porcentaje efectivo entre -90 y +1000; 1 a 500 ids (fuera de rango o valor/modo/dirección inválidos: P0400 sin escribir). Cada id se normaliza a su raíz y se expande a la raíz más sus variantes vivas; los padres variant_only se omiten (skipped_parents); ids ajenos o borrados no dan error ni revelan existencia. Una fila cuyo precio no cambia no se escribe. UN solo UPDATE atómico. Sólo dueño o administrador (P0403 insufficient_role). p_dry_run = true devuelve el mismo resultado sin escribir ni auditar (la vista previa); una aplicación con cambios audita product.bulk_price_adjusted.$c$;

-- =============================================================================
-- 7. Introspección final: la migración ABORTA si algo no quedó como se espera
-- =============================================================================
DO $verify$
DECLARE
  v_def  text;
  v_bad  text[] := '{}';
BEGIN
  -- Corte del guard.
  v_def := pg_get_functiondef('public.fn_product_base_unit_guard()'::regprocedure);
  IF position('products.unit_relabel_root' in v_def) = 0
     OR position('NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id' in v_def) = 0
     OR position('NEW.account_id = OLD.account_id' in v_def) = 0 THEN
    v_bad := v_bad || 'el guard de la unidad base no quedó con el corte atado a la raíz'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass
                  AND tgname = 'trg_product_base_unit_guard' AND tgenabled = 'O') THEN
    v_bad := v_bad || 'falta el disparador trg_product_base_unit_guard'::text;
  END IF;

  -- CHECK validado y sin padres fuera de forma.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.products'::regclass
                  AND conname = 'products_variant_only_no_price_cost' AND convalidated) THEN
    v_bad := v_bad || 'el CHECK products_variant_only_no_price_cost no existe o no está validado'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE stock_control_type = 'variant_only' AND (price IS DISTINCT FROM 0 OR cost IS NOT NULL)) THEN
    v_bad := v_bad || 'quedan padres variant_only con precio o costo'::text;
  END IF;

  -- ACLs: sin EXECUTE para anon; authenticated sólo en las dos RPCs; el guard y el importador internos.
  IF has_function_privilege('anon', 'public.rpc_relabel_product_unit(uuid,uuid,boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_bulk_adjust_prices(uuid[],text,text,numeric,boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.product_round_price(numeric)', 'EXECUTE') THEN
    v_bad := v_bad || 'anon tiene EXECUTE sobre una función nueva'::text;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpc_relabel_product_unit(uuid,uuid,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_bulk_adjust_prices(uuid[],text,text,numeric,boolean)', 'EXECUTE') THEN
    v_bad := v_bad || 'authenticated no tiene EXECUTE sobre las RPCs nuevas'::text;
  END IF;
  IF has_function_privilege('authenticated', 'public.fn_product_base_unit_guard()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rpc_bulk_upsert_products(jsonb,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_bulk_upsert_products(jsonb,uuid)', 'EXECUTE') THEN
    v_bad := v_bad || 'el guard o el importador quedaron expuestos'::text;
  END IF;

  -- Una sola firma viva por función.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('rpc_relabel_product_unit', 'rpc_bulk_adjust_prices', 'product_round_price', 'rpc_bulk_upsert_products')) <> 4 THEN
    v_bad := v_bad || 'alguna de las cuatro funciones tiene un overload vivo'::text;
  END IF;

  -- La rama Padre del importador fuerza precio y costo.
  v_def := pg_get_functiondef('public.rpc_bulk_upsert_products(jsonb,uuid)'::regprocedure);
  IF position('productos-padre-variantes' in v_def) = 0 THEN
    v_bad := v_bad || 'el importador no quedó con la rama Padre sin precio/costo'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'productos-padre-variantes: introspección fallida: %', array_to_string(v_bad, '; ');
  END IF;
END
$verify$;
