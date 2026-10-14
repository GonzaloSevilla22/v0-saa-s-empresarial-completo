-- =============================================================================
-- MIGRATION: 20261079000001_importador_productos_stock_apertura.sql
-- FIX AD-HOC: importador-productos-stock-apertura (2026-10-14) — governance MEDIA con
--         un tramo ALTO: reescribe la función que escribe el ledger de stock del
--         importador de productos. Pedido directo del PO tras la auditoría del
--         movimiento de stock del 2026-10-13 («corregí todo lo que encontraste»);
--         urgente: el PO importa el catálogo de un cliente nuevo la semana próxima.
--
-- PROBLEMA (R1, reproducido en el stack local —smoke_stock.sql S16b/S16d—):
--   · rpc_bulk_upsert_products escribía el stock del archivo con
--       ON CONFLICT (product_id, branch_id) DO UPDATE SET quantity = EXCLUDED.quantity
--     un SET ABSOLUTO que corría también para el producto que YA existía (match por
--     SKU). Reimportar otro archivo con el mismo SKU PISABA el stock vivo: vendí 5 de
--     20, reimporto 20, vuelve a 20 (el ledger dejaba de reconciliar y la venta
--     desaparecía del saldo sin dejar rastro).
--   · el import jamás escribía stock_movements: el stock inicial no dejaba renglón en
--     el historial (el alta manual sí deja «Stock inicial»).
--   · las celdas vacías de Stock mínimo, al EDITAR, reseteaban el umbral de alerta de
--     la sucursal a 0 (el EXCLUDED traía COALESCE(min_stock, 0)): apagaba la alerta de
--     stock crítico de un producto existente sin que nadie lo pidiera.
--   · la sucursal que recibía el stock era «la más antigua de la cuenta», sin filtrar
--     activas (ORDER BY created_at LIMIT 1): en una cuenta cuya primera sucursal se
--     desactivó, el stock importado quedaba en una sucursal en la que no se vende.
--
-- QUÉ HACE (D1-D4), en la ÚNICA función tocada:
--   D1  La sucursal de la apertura es c26_default_branch(cuenta): la principal
--       OPERATIVA canónica que ya usan la venta, la compra y el gasto sin sucursal
--       elegida. Lazy-create (activa, con status y opened_at, igual que
--       c21_apply_branch_stock_delta) sólo si la cuenta no tiene ninguna.
--   D2  El stock del archivo se aplica ÚNICAMENTE al producto que este lote CREA
--       (v_is_new: no existía por SKU). Un producto existente conserva su saldo:
--       corregirlo es el ajuste de stock / el conteo físico de /stock, que dejan su
--       rastro. El resto de los campos (precio, costo, nombre, categoría, código…)
--       se sigue actualizando.
--   D3  La apertura entra por op_stock_movement —el helper canónico de operaciones
--       (c21_apply_branch_stock_delta + el movimiento con antes/después)—, no por un
--       camino nuevo: UN movimiento tipo 'adjustment' con motivo «Stock inicial
--       (importación)», el mismo tipo con que el alta manual registra «Stock inicial»,
--       sellado con cuenta, sucursal y autor. El CHECK stock_movements_manual_needs_
--       reason lo satisface (motivo no vacío). Delta 0 (celda vacía o 0) no deja
--       movimiento.
--   D4  La fila de saldo se asegura (cantidad 0, sin tocar el saldo) en el alta con una
--       celda de stock informada y en cualquier fila con un MÍNIMO informado; en la
--       edición el DO UPDATE toca sólo branch_stock.min_stock y sólo si vino: una celda
--       vacía CONSERVA el umbral vigente (mismo criterio null-preserving que ya tenían
--       costo, categoría, código de barras y código de balanza).
--
-- DECISIONES QUE CAMBIAN COMPORTAMIENTO VISIBLE (pedidas por el PO):
--   · Reimportar un SKU existente ya no modifica su stock (antes lo pisaba).
--   · El import deja un movimiento de apertura por cada producto creado con stock.
--   · Dentro de un MISMO archivo con un SKU repetido, la primera fila crea con su stock
--     y la segunda actualiza el resto de los campos sin pisarlo (antes la última fila
--     ganaba también en el stock).
--   El cliente (frontend/lib/import) deja de mandar 0 por una celda vacía de Precio,
--   Stock y Stock mínimo: manda null, que esta función ya trata como «conservar» al
--   editar y como 0 / sin stock al crear.
--
-- QUÉ NO TOCA. rpc_import_products (llama a esta función UNA vez con el archivo entero y
-- no duplica sus reglas), la ACL (sigue SIN EXECUTE para authenticated/anon: el backend
-- es el único camino), las reglas de categoría, SKU, jerarquía y código de balanza, el
-- gate de plan, y el rol exigido (cualquier escritor de la cuenta, como hasta hoy: la
-- apertura del import NO exige el rol de stock que sí exige el «Stock inicial» del
-- formulario de alta —decisión del importador, fuera de alcance de este fix—).
--
-- CUERPO DE PARTIDA (md5 de prosrc sin \r, verificado el 2026-10-14 contra producción
-- gxdhpxvdjjkmxhdkkwyb —327 migraciones, max(version)=20261078000001, sólo SELECT— y
-- contra la base local construida desde los archivos: IDÉNTICOS):
--   rpc_bulk_upsert_products  9c5368635161c4ad44e35b5043e3360b  (20261066000001_balanza_etiquetas_pos.sql)
-- Los helpers que invoca fueron verificados contra prod el mismo día (md5 de
-- pg_get_functiondef sin \r, idénticos a los locales): c26_default_branch
-- 5fa1096b4c1481b36d6e04c8eaadbfdc, op_stock_movement 70bb90494341b7a505d52624f592da49,
-- c21_apply_branch_stock_delta 8d98227d6d6556e3a2f3f545dae2b231.
--
-- Reescritura con CREATE OR REPLACE y la MISMA firma (sin DROP, sin overload, sin 42725):
-- la ACL viva se conserva y se re-emite idéntica (postgres + service_role). El COMMENT se
-- re-declara con la regla de apertura. El diff contra el cuerpo vivo es EXACTAMENTE lo de
-- D1-D4 más un comentario `-- importador-productos-stock-apertura (Dn):` en cada punto
-- tocado.
--
-- ROLLBACK (no hay datos que deshacer): CREATE OR REPLACE desde el cuerpo de partida
-- (20261066000001, sección 4) y su COMMENT. Los movimientos de apertura ya escritos son
-- ledger append-only y quedan.
--
-- Idempotente: preflight por md5 (acepta el cuerpo de partida o el que esta migración deja),
-- CREATE OR REPLACE, REVOKE/GRANT y COMMENT repetidos. KPI_Validation.yml la reaplica AL FINAL
-- de la cadena: la segunda pasada imprime el NOTICE «ya es el cuerpo de esta migración».
--
-- REGLA PARA EL PR SIGUIENTE: una migración posterior que redefina rpc_bulk_upsert_products
-- tiene que RETIRAR el bloque de reaplicación de esta migración en KPI_Validation.yml en el
-- mismo PR (su preflight abortaría, igual que el de 20261076000001).
--
-- Gate: supabase/tests/test_importador_stock_apertura.sql (ejecuta rpc_import_products como
-- authenticated). Frontend: lib/import (celda vacía = null) y aviso en el paso de revisión
-- del diálogo de importación.
-- =============================================================================

-- ─── 0. Preflight: integridad de función ───────────────────────────────────────
-- Se reescribe desde el cuerpo VIVO. Si el del stack que aplica esta migración no es ni el
-- de partida ni el que ella deja (una migración intermedia que nadie reconcilió), se ABORTA
-- en vez de pisarlo en silencio — regla de integridad de función (20261060000001, molde de
-- 20261076000001).
DO $$
DECLARE
  v_expected  text := '9c5368635161c4ad44e35b5043e3360b';
  v_rewritten text := '445474fe4d7ffcd2a593a5d50ca0ee35';
  v_md5       text;
BEGIN
  SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
  FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'rpc_bulk_upsert_products';

  IF v_md5 = v_expected THEN
    RAISE NOTICE 'importador-productos-stock-apertura: rpc_bulk_upsert_products se reescribe desde el cuerpo de partida verificado por md5';
  ELSIF v_md5 = v_rewritten THEN
    RAISE NOTICE 'importador-productos-stock-apertura: rpc_bulk_upsert_products ya es el cuerpo de esta migración (reaplicación)';
  ELSE
    RAISE EXCEPTION 'importador-productos-stock-apertura: el cuerpo vivo de rpc_bulk_upsert_products difiere del verificado contra prod el 2026-10-14 — reconciliar antes de reescribir: esperado % (partida) o % (reaplicación), vivo %',
      v_expected, v_rewritten, COALESCE(v_md5, '(no existe)');
  END IF;
END $$;

-- ─── 1. rpc_bulk_upsert_products ───────────────────────────────────────────────
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
          price              = COALESCE((v_row->>'price')::numeric,      price),
          -- productos-costo-nullable (D10): celda vacía en la EDICIÓN
          -- conserva el costo que el producto tenía — no lo borra. Es la
          -- misma convención tri-estado-por-ausencia que sku/category_id.
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
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
          COALESCE((v_row->>'price')::numeric,    0),
          -- productos-costo-nullable (D10): celda vacía en el ALTA queda
          -- NULL (sin costo), no 0. Un padre variant_only (rama "Padre" del
          -- importador) manda cost NULL desde el frontend — acá no se
          -- distingue el caso, simplemente se propaga lo que llegó.
          (v_row->>'cost')::numeric,
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

-- ACL (CREATE OR REPLACE la conserva; se re-emite idéntica por si un entorno la perdió): sólo
-- rpc_import_products (DEFINER) y service_role la invocan; authenticated y anon, nunca.
REVOKE ALL ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO service_role;

COMMENT ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) IS
  'Alta masiva de productos. Invocable SOLO desde rpc_import_products (SECURITY DEFINER) y service_role — importador-productos-fastapi (D4) le retira EXECUTE a authenticated: el backend es el único camino de importación. importador-productos-stock-apertura: el stock del archivo es de APERTURA — se aplica sólo al producto que el lote CREA, en la sucursal principal operativa (c26_default_branch), y deja UN movimiento «Stock inicial (importación)» vía op_stock_movement; un producto existente (match por SKU) conserva su saldo y las celdas vacías de precio, costo, stock y stock mínimo conservan el valor vigente.';

-- ─── 2. Introspección ───────────────────────────────────────────────────────────
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_bad text[] := '{}';
  v_n   integer;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpc_bulk_upsert_products';
  IF v_n <> 1 THEN
    v_bad := v_bad || format('rpc_bulk_upsert_products tiene %s firmas (debía ser 1)', v_n);
  END IF;

  v_oid := 'public.rpc_bulk_upsert_products(jsonb, uuid)'::regprocedure;
  v_def := pg_get_functiondef(v_oid);
  IF position('c26_default_branch' in v_def) = 0 OR position('op_stock_movement' in v_def) = 0
     OR position('v_is_new' in v_def) = 0 THEN
    v_bad := v_bad || 'el cuerpo no resuelve la sucursal con c26_default_branch / no abre con op_stock_movement / no distingue el alta';
  END IF;
  IF position('EXCLUDED.quantity' in v_def) > 0 THEN
    v_bad := v_bad || 'el cuerpo todavía pisa la cantidad con EXCLUDED.quantity';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    v_bad := v_bad || 'dejó de ser SECURITY DEFINER';
  END IF;
  IF (SELECT 'search_path=public' = ANY (proconfig) FROM pg_proc WHERE oid = v_oid) IS NOT TRUE THEN
    v_bad := v_bad || 'perdió SET search_path = public';
  END IF;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    v_bad := v_bad || 'ACL: debía ser sin EXECUTE para authenticated/anon y con EXECUTE para service_role';
  END IF;
  IF position('apertura' in COALESCE(obj_description(v_oid, 'pg_proc'), '')) = 0 THEN
    v_bad := v_bad || 'el COMMENT no documenta la regla de apertura';
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION 'importador-productos-stock-apertura (introspección) FAILED: %', array_to_string(v_bad, ' | ');
  END IF;
  RAISE NOTICE 'importador-productos-stock-apertura (introspección) OK: una firma, DEFINER con search_path, sucursal c26 + apertura por op_stock_movement, sin set absoluto, ACL y COMMENT';
END $$;
