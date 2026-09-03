-- =============================================================================
-- MIGRATION: 20261023000001_productos_categorias_sku.sql
-- CHANGE:    productos-categorias-sku
-- Design ref: openspec/changes/productos-categorias-sku/design.md
--
-- QUÉ AGREGA
--   1. Catálogo `product_categories` por cuenta — espejo estructural de
--      `payment_methods` SIN `kind` (una categoría es puro rótulo): RLS
--      account-direct, unique case-insensitive parcial sobre filas vivas,
--      sort_order + soft delete (D1/D3).
--   2. `products.category_id` FK nullable `ON DELETE RESTRICT` (D2) + índice
--      parcial, como fuente de verdad de la imputación.
--   3. Espejo desnormalizado `products.category` (TEXT) mantenido por DOS
--      triggers (D1): BEFORE INSERT/UPDATE sobre products (choke point que
--      valida tenencia con P0404 y copia el nombre) + AFTER UPDATE OF name
--      sobre product_categories (propaga el renombre, `IS DISTINCT FROM`,
--      filtrado por category_id). NINGÚN lector legacy de `category` cambia.
--   4. Alcance de unicidad del SKU: `idx_products_sku_user` UNIQUE(user_id,
--      sku) → `idx_products_sku_account_lower` UNIQUE(account_id, lower(sku))
--      parcial sobre filas vivas (D4), con verificación defensiva de
--      colisiones ANTES de crear el índice (0 en prod, 2026-09-03).
--   5. `rpc_bulk_upsert_products` reescrita desde su cuerpo VIVO de prod
--      (pg_get_functiondef, md5 dc56bfc24e7f31c85dc9f04463af26eb, 7080
--      bytes, 2026-09-03) con DOS ejes y sólo dos: (a) las tres resoluciones
--      (SKU existente, sku_parent, parent_name) + el WHERE del UPDATE pasan
--      de user_id a account_id, case-insensitive y sobre filas VIVAS — el
--      mismo alcance exacto que el índice nuevo, para que la clave de upsert
--      y la de unicidad nunca discrepen; (b) resolución/creación de la
--      categoría contra el catálogo de la cuenta (D6) con tope de 50 nuevas
--      por llamada (OQ-1, sign-off PO 2026-09-03) y categoría por defecto de
--      la cuenta para la fila sin categoría. La firma `(p_rows jsonb,
--      p_user_id uuid)` NO cambia → CREATE OR REPLACE, sin overload 42725;
--      ACLs re-declaradas idénticas a las vivas (postgres/authenticated/
--      service_role; anon SIN EXECUTE).
--   6. Sub-bloque 7) en `handle_new_user` (base EXACTA: pg_get_functiondef
--      vivo, md5 a1649f01213746263f3c237f002f29bb, 5888 bytes, 2026-09-03):
--      seed de las 7 categorías legacy, degrade-don't-fail (D13).
--   7. Backfill idempotente en dos pasos (D13): (1) las 7 categorías en cada
--      cuenta que todavía no tiene NINGUNA (predicado por ausencia total, no
--      por nombre — así una reaplicación nunca re-siembra una categoría que
--      el usuario renombró); (2) `products.category_id` resuelto por
--      `lower(btrim(category))` contra el catálogo de SU cuenta. Medición en
--      prod: 5.084 productos / 0 sin categoría / 0 fuera de la lista → cobertura
--      total; igual se escribe tolerante (residuo → NULL + WARNING, nunca la
--      categoría de otra cuenta).
--   8. `v_products_with_stock` gana `category_id` como ÚLTIMA columna
--      (CREATE OR REPLACE VIEW sólo admite agregar al final) conservando
--      `security_invoker = true` y la lista de columnas viva byte a byte.
--      Es la única forma de que `category_id` llegue a `ProductOut` sin
--      tocar los cuatro lectores del repositorio — desvío ADITIVO respecto
--      del design (que no preveía tocar la vista), declarado en el apply.
--
-- QUÉ NO TOCA
--   `idx_products_barcode_unique` (mismo residuo user_id — task 4.5,
--   candidato anotado, fuera de superficie de este change). La jerarquía
--   Padre/Variante, el acarreo a branch_stock y product_attributes de la
--   RPC (byte a byte). Ninguna función que escriba dinero, el outbox.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE
--   La integración GitHub de Supabase auto-aplica y puede reaplicar: CREATE
--   TABLE/INDEX IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, DROP POLICY/TRIGGER
--   IF EXISTS + CREATE, CREATE OR REPLACE de funciones y vista, DROP INDEX IF
--   EXISTS, backfills por NOT EXISTS / category_id IS NULL.
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
-- ROLLBACK: el TEXT `category` nunca deja de ser la columna que todo lector
--   consume → revertir backend/frontend deja el sistema en el comportamiento
--   previo aunque la tabla siga. El único paso no trivial es el swap del
--   índice de SKU: se revierte recreando `idx_products_sku_user` (criterio
--   más laxo, no puede fallar).
-- =============================================================================


-- =============================================================================
-- 1. Tabla product_categories (espejo de payment_methods sin kind)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.product_categories (
    id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    name        text          NOT NULL,
    is_active   boolean       NOT NULL DEFAULT true,
    sort_order  integer       NOT NULL DEFAULT 0,
    created_at  timestamptz   NOT NULL DEFAULT now(),
    deleted_at  timestamptz   NULL,
    deleted_by  uuid          NULL
);

COMMENT ON TABLE  public.product_categories            IS 'productos-categorias-sku: catálogo plano de categorías de producto por cuenta. Espejo estructural de payment_methods sin kind — una categoría es puro rótulo del usuario.';
COMMENT ON COLUMN public.product_categories.account_id IS 'Cuenta propietaria (RLS por account_id, tenancy account-direct).';
COMMENT ON COLUMN public.product_categories.name       IS 'Etiqueta editable por el usuario (única case-insensitive por cuenta entre filas vivas). Renombrarla se propaga a products.category por trigger.';
COMMENT ON COLUMN public.product_categories.is_active  IS 'Baja lógica REVERSIBLE: FALSE oculta del selector de altas nuevas pero conserva las imputaciones (D3).';
COMMENT ON COLUMN public.product_categories.sort_order IS 'Orden del selector. Las 7 sembradas nacen 1..7 (Otros al final); el usuario puede reordenar.';
COMMENT ON COLUMN public.product_categories.deleted_at IS 'Soft delete (RN-B1, Modelo V3 §4): NOT NULL = borrado, sale de toda lectura por defecto. Convive con is_active.';
COMMENT ON COLUMN public.product_categories.deleted_by IS 'Autoría del borrado (RN-B2). Referencia lógica a auth.users (sin FK dura).';

CREATE INDEX IF NOT EXISTS product_categories_account_id_idx
    ON public.product_categories (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS product_categories_account_name_lower_idx
    ON public.product_categories (account_id, lower(name))
    WHERE deleted_at IS NULL;

ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "product_categories_member_select" ON public.product_categories;
CREATE POLICY "product_categories_member_select" ON public.product_categories
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

DROP POLICY IF EXISTS "product_categories_writer_insert" ON public.product_categories;
CREATE POLICY "product_categories_writer_insert" ON public.product_categories
    FOR INSERT
    TO authenticated
    WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "product_categories_writer_update" ON public.product_categories;
CREATE POLICY "product_categories_writer_update" ON public.product_categories
    FOR UPDATE
    TO authenticated
    USING     (is_account_writer(account_id))
    WITH CHECK (is_account_writer(account_id));


-- =============================================================================
-- 2. products.category_id (D2: nullable en la base, ON DELETE RESTRICT)
-- =============================================================================

ALTER TABLE public.products
    ADD COLUMN IF NOT EXISTS category_id uuid NULL
        REFERENCES public.product_categories(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS products_category_id_idx
    ON public.products (category_id) WHERE category_id IS NOT NULL;

COMMENT ON COLUMN public.products.category_id IS
    'productos-categorias-sku (D1): FUENTE DE VERDAD de la categoría. FK al catálogo de la cuenta; products.category (TEXT) es un espejo mantenido por trigger — nunca escribirlo a mano.';
COMMENT ON COLUMN public.products.category IS
    'productos-categorias-sku (D1): ESPEJO desnormalizado del nombre de product_categories referenciada por category_id, mantenido por trg_product_category_mirror y trg_product_category_propagate_name. Se conserva para que ningún lector legacy (v_products_with_stock, IA, exportaciones) cambie. Su retiro es un change propio (OQ-3).';


-- =============================================================================
-- 3. Helper de normalización del nombre (task 5.8 — UN solo helper)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.product_category_normalize_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT NULLIF(regexp_replace(btrim(COALESCE(p_name, '')), '\s+', ' ', 'g'), '');
$function$;

COMMENT ON FUNCTION public.product_category_normalize_name(text) IS
    'productos-categorias-sku (D6): trim + colapso de espacios internos; vacío → NULL. Único helper de normalización del nombre de categoría (lo usa rpc_bulk_upsert_products; el backend normaliza igual).';

REVOKE ALL     ON FUNCTION public.product_category_normalize_name(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.product_category_normalize_name(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.product_category_normalize_name(text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.product_category_normalize_name(text) TO service_role;


-- =============================================================================
-- 4. Triggers de espejo (D1)
-- =============================================================================

-- 4a. BEFORE INSERT OR UPDATE sobre products — choke point. Dispara cuando
--     se escribe category_id, category o account_id: un camino que no toque
--     ninguna de las tres no puede desincronizar el espejo, y uno que las
--     toque (incluido un UPDATE legacy de category TEXT) pasa por acá.
CREATE OR REPLACE FUNCTION public.fn_product_category_mirror()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_name        text;
  v_cat_account uuid;
BEGIN
  IF NEW.category_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT pc.name, pc.account_id
    INTO v_name, v_cat_account
    FROM public.product_categories pc
   WHERE pc.id = NEW.category_id;

  IF NOT FOUND OR v_cat_account IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION 'product_category_not_found: la categoría no existe o no pertenece a la cuenta del producto'
      USING ERRCODE = 'P0404';
  END IF;

  NEW.category := v_name;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_product_category_mirror() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_product_category_mirror() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_product_category_mirror ON public.products;
CREATE TRIGGER trg_product_category_mirror
  BEFORE INSERT OR UPDATE OF category_id, category, account_id ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_product_category_mirror();

-- 4b. AFTER UPDATE OF name sobre product_categories — propaga el renombre.
--     WHEN (OLD.name IS DISTINCT FROM NEW.name) + filtro por category_id
--     (índice parcial) + `category IS DISTINCT FROM NEW.name`: cero filas
--     tocadas cuando el nombre no cambió (mitigación del riesgo de UPDATE
--     masivo — peor caso medido 2.951 filas en una cuenta).
CREATE OR REPLACE FUNCTION public.fn_product_category_propagate_name()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  UPDATE public.products
     SET category = NEW.name
   WHERE category_id = NEW.id
     AND category IS DISTINCT FROM NEW.name;
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_product_category_propagate_name() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_product_category_propagate_name() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_product_category_propagate_name ON public.product_categories;
CREATE TRIGGER trg_product_category_propagate_name
  AFTER UPDATE OF name ON public.product_categories
  FOR EACH ROW
  WHEN (OLD.name IS DISTINCT FROM NEW.name)
  EXECUTE FUNCTION public.fn_product_category_propagate_name();


-- =============================================================================
-- 5. Alcance de unicidad del SKU: user_id → account_id (D4)
-- =============================================================================

-- 5a. Verificación defensiva: si con el criterio nuevo hay colisiones, abortar
--     ruidosamente ANTES de crear el índice a medias (0 en prod, 2026-09-03).
DO $$
DECLARE
  v_collisions integer;
  v_detail     text;
BEGIN
  SELECT COUNT(*), string_agg(format('%s/%s (%s)', c.account_id, c.sku_lower, c.n), '; ')
    INTO v_collisions, v_detail
    FROM (
      SELECT account_id, lower(sku) AS sku_lower, COUNT(*) AS n
        FROM public.products
       WHERE sku IS NOT NULL AND sku <> '' AND deleted_at IS NULL
       GROUP BY account_id, lower(sku)
      HAVING COUNT(*) > 1
    ) c;

  IF v_collisions > 0 THEN
    RAISE EXCEPTION 'productos-categorias-sku: % colisiones de SKU por cuenta con criterio case-insensitive impiden crear idx_products_sku_account_lower — resolver a mano antes de reaplicar: %',
      v_collisions, v_detail;
  END IF;
END $$;

-- 5b. Índice nuevo (account_id, lower(sku)) sobre filas vivas con SKU.
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku_account_lower
    ON public.products (account_id, lower(sku))
    WHERE sku IS NOT NULL AND sku <> '' AND deleted_at IS NULL;

-- 5c. El índice viejo por user_id se retira: no conviven dos reglas de
--     unicidad discrepantes. `idx_products_sku` (no único, para búsqueda)
--     se conserva.
DROP INDEX IF EXISTS public.idx_products_sku_user;

-- 5d. task 4.5 — `idx_products_barcode_unique` (UNIQUE(user_id, barcode))
--     tiene el MISMO residuo de tenencia y NO se toca acá: el código de
--     barras no es superficie de este change. Candidato anotado en CHANGES.md.


-- =============================================================================
-- 6. rpc_bulk_upsert_products — base EXACTA viva (md5 dc56bfc2…, 2026-09-03)
--    Ejes (a) y (b) marcados "productos-categorias-sku"; el resto byte a byte.
-- =============================================================================

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
  -- productos-categorias-sku (D6): categoría por fila + default de la cuenta + tope.
  v_cat_name         text;
  v_category_id      uuid;
  v_default_category uuid;
  v_new_categories   int;
  c_max_new_categories CONSTANT int := 50;  -- OQ-1, sign-off PO 2026-09-03
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

  -- Default branch de la cuenta (la más antigua); lazy-create si no existe.
  SELECT b.id INTO v_default_branch
    FROM branches b
   WHERE b.account_id = v_account_id
   ORDER BY b.created_at ASC
   LIMIT 1;

  IF v_default_branch IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active)
    VALUES (v_account_id, 'Casa Central', TRUE)
    ON CONFLICT (account_id, name) DO NOTHING;

    SELECT b.id INTO v_default_branch
      FROM branches b
     WHERE b.account_id = v_account_id
     ORDER BY b.created_at ASC
     LIMIT 1;
  END IF;

  -- productos-categorias-sku (D6): categoría por defecto de la cuenta para
  -- la fila SIN categoría — "Otros" si sigue viva y activa; si el usuario la
  -- renombró o desactivó, la última activa por sort_order. Sin catálogo
  -- activo → NULL (la fila conserva el TEXT legacy, nunca falla por esto).
  SELECT pc.id INTO v_default_category
    FROM public.product_categories pc
   WHERE pc.account_id = v_account_id
     AND pc.deleted_at IS NULL
     AND pc.is_active
   ORDER BY (lower(pc.name) = 'otros') DESC, pc.sort_order DESC, pc.created_at ASC
   LIMIT 1;

  -- productos-categorias-sku (D6, tope OQ-1): contar las categorías NUEVAS
  -- distintas que trae la llamada ANTES de tocar nada. Superar el tope
  -- aborta toda la llamada (una sola transacción → nada creado): lo más
  -- probable es una columna mal mapeada, no un catálogo legítimo.
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

      IF v_existing_id IS NOT NULL THEN
        -- C-21 checkpoint #2: products.stock no existe — el stock va solo a branch_stock.
        -- productos-categorias-sku (eje b): category TEXT ya no se escribe a
        -- mano — lo mantiene el trigger de espejo desde category_id.
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category_id        = COALESCE(v_category_id,                   category_id),
          price              = COALESCE((v_row->>'price')::numeric,      price),
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
          min_stock          = COALESCE((v_row->>'min_stock')::integer,  min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),    barcode),
          parent_id          = COALESCE(v_resolved_pid,                  parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type),
          account_id         = COALESCE(account_id, v_account_id)
        WHERE id = v_existing_id AND account_id = v_account_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;

      ELSE
        INSERT INTO public.products (
          user_id, account_id, name, category, category_id, price, cost, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_account_id,
          v_row->>'name',
          COALESCE(v_cat_name, 'Otros'),
          COALESCE(v_category_id, v_default_category),
          COALESCE((v_row->>'price')::numeric,    0),
          COALESCE((v_row->>'cost')::numeric,     0),
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

      -- Stock del CSV → branch_stock (default branch), set absoluto.
      -- Sólo para filas no-Padre (stock > 0 o stock explícito en el CSV).
      IF v_default_branch IS NOT NULL
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

-- ACLs idénticas a las vivas en prod (2026-09-03):
-- {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
REVOKE ALL     ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO service_role;


-- =============================================================================
-- 7. handle_new_user — base EXACTA viva (md5 a1649f01…, 2026-09-03).
--    Único agregado: el sub-bloque 7) antes de RETURN new.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  user_name          text;
  user_last_name     text;
  user_phone         text;
  user_locality      text;
  user_province      text;
  user_terms_version text;
  user_email_optin   boolean;
  v_terms_accepted_at timestamptz;
  v_account_id       uuid;
  v_branch_id        uuid;
BEGIN
  user_name          := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_last_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'last_name', '')), '');
  user_phone         := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');
  user_province      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'province', '')), '');
  user_terms_version := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'terms_version', '')), '');
  user_email_optin   := COALESCE((new.raw_user_meta_data->>'email_notifications_opt_in')::boolean, false);
  v_terms_accepted_at := CASE WHEN user_terms_version IS NOT NULL THEN now() ELSE NULL END;

  -- 1) Perfil (sin cambios respecto a 20260801000003)
  INSERT INTO public.profiles (
    id, name, last_name, phone, locality, province, role,
    terms_accepted_at, terms_version, email_notifications_opt_in
  )
  VALUES (
    new.id, user_name, user_last_name, user_phone, user_locality, user_province, 'user',
    v_terms_accepted_at, user_terms_version, user_email_optin
  );

  -- 2) Tenant: cuenta propia + membresía como OWNER (sin cambios).
  INSERT INTO public.accounts (
    owner_user_id, billing_plan, billing_status,
    trial_plan, trial_started_at, trial_expires_at
  )
  SELECT new.id, p.billing_plan, p.billing_status,
         p.trial_plan, p.trial_started_at, p.trial_expires_at
  FROM   public.profiles p
  WHERE  p.id = new.id
  RETURNING id INTO v_account_id;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, new.id, 'owner')
  ON CONFLICT (account_id, user_id) DO NOTHING;

  -- 3) Mail de bienvenida (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 4) Aviso al administrador (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'new_user_admin_notice',
    'danielsevilla@alia-data.com',
    'Nuevo registro en ALIADATA',
    jsonb_build_object(
      'name',      COALESCE(user_name, 'Sin nombre'),
      'last_name', COALESCE(user_last_name, '-'),
      'full_name', NULLIF(TRIM(COALESCE(user_name, '') || ' ' || COALESCE(user_last_name, '')), ''),
      'email',     new.email,
      'phone',     COALESCE(user_phone, '-'),
      'locality',  COALESCE(user_locality, '-'),
      'province',  COALESCE(user_province, '-')
    )
  );

  -- 5) v3-provisioning-seed: sucursal default + caja default (EAGER).
  --    Aislado en su propio sub-bloque: un fallo acá degrada a WARNING y
  --    JAMÁS aborta el signup. El core de arriba (profile/account/membership/
  --    emails) queda fuera de este bloque a propósito — si eso falla, el
  --    signup DEBE fallar (comportamiento preexistente, correcto).
  BEGIN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (v_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(v_account_id);

    IF v_branch_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.cashboxes cb WHERE cb.branch_id = v_branch_id
    ) THEN
      INSERT INTO public.cashboxes (branch_id, name, currency)
      VALUES (v_branch_id, 'Caja Principal', 'ARS');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'v3-provisioning-seed: no se pudo sembrar branch/cashbox default para account_id=% (signup continúa; el lazy-create de c21_apply_branch_stock_delta sigue como red de seguridad). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  -- 6) metodos-pago-operaciones (D11 Parte B) + limpiezas-pagos-admin (OQ-1):
  --    catálogo de 7 formas de pago (6 originales + Cheque). Mismo criterio
  --    degrade-don't-fail que el sub-bloque de arriba — aislado, propia
  --    EXCEPTION, jamás aborta el signup.
  BEGIN
    -- limpiezas-pagos-admin (OQ-1): 'Cheque' (kind=check) se agrega como 7º
    -- método sembrado — el vocabulario del CHECK ya lo admitía desde
    -- 20260928000001 pero el seed original solo traía 6/7. sort_order=7
    -- (al final, no reordena los 6 existentes). Riesgo cero: el usuario
    -- puede desactivarlo desde el manager de Configuración si no lo usa.
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    SELECT v_account_id, v.name, v.kind, v.sort_order
    FROM (VALUES
        ('Efectivo',               'cash',     1),
        ('Transferencia bancaria', 'transfer', 2),
        ('Tarjeta',                'card',     3),
        ('Billetera virtual',      'wallet',   4),
        ('Cuenta corriente',       'credit',   5),
        ('Otro',                   'other',    6),
        ('Cheque',                 'check',    7)
    ) AS v(name, kind, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.payment_methods pm
      WHERE pm.account_id = v_account_id
        AND pm.kind       = v.kind
        AND pm.deleted_at IS NULL
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'metodos-pago-operaciones: no se pudo sembrar el catálogo de formas de pago para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  -- 7) productos-categorias-sku (D13): las 7 categorías de producto legacy,
  --    sort_order 1..7 con "Otros" al final. Mismo molde degrade-don't-fail
  --    que 5) y 6). Predicado por AUSENCIA TOTAL de catálogo (no por nombre):
  --    el nombre es editable por el usuario y no debe re-sembrarse si lo
  --    renombró — en el signup la cuenta es nueva, así que siembra siempre.
  BEGIN
    INSERT INTO public.product_categories (account_id, name, sort_order)
    SELECT v_account_id, v.name, v.sort_order
    FROM (VALUES
        ('Electrónica', 1),
        ('Ropa',        2),
        ('Alimentos',   3),
        ('Hogar',       4),
        ('Salud',       5),
        ('Accesorios',  6),
        ('Otros',       7)
    ) AS v(name, sort_order)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.product_categories pc
      WHERE pc.account_id = v_account_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'productos-categorias-sku: no se pudo sembrar el catálogo de categorías de producto para account_id=% (signup continúa). SQLERRM=%',
        v_account_id, SQLERRM;
  END;

  RETURN new;
END;
$function$;

-- ACLs idénticas a las vivas en prod (2026-09-03):
-- {postgres=X/postgres,service_role=X/postgres} — sin anon ni authenticated.
REVOKE ALL     ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.handle_new_user() TO service_role;


-- =============================================================================
-- 8. Backfill idempotente (D13)
-- =============================================================================

-- 8a. Paso 1: las 7 categorías en cada cuenta existente que todavía no tiene
--     NINGUNA (mismo predicado que el sub-bloque 7 de handle_new_user).
INSERT INTO public.product_categories (account_id, name, sort_order)
SELECT a.id, v.name, v.sort_order
FROM   public.accounts a
CROSS JOIN (VALUES
    ('Electrónica', 1),
    ('Ropa',        2),
    ('Alimentos',   3),
    ('Hogar',       4),
    ('Salud',       5),
    ('Accesorios',  6),
    ('Otros',       7)
) AS v(name, sort_order)
WHERE NOT EXISTS (
    SELECT 1 FROM public.product_categories pc WHERE pc.account_id = a.id
);

-- 8b. Paso 2: products.category_id resuelto por lower(btrim(category)) contra
--     el catálogo de SU cuenta. Tolerante: lo que no resuelve queda NULL con
--     su category TEXT intacta — nunca la categoría de otra cuenta. Sólo
--     toca filas con category_id NULL → cero reescrituras al reaplicar.
UPDATE public.products p
SET    category_id = pc.id
FROM   public.product_categories pc
WHERE  p.category_id IS NULL
  AND  p.account_id IS NOT NULL
  AND  pc.account_id = p.account_id
  AND  pc.deleted_at IS NULL
  AND  lower(pc.name) = lower(btrim(p.category));

-- 8c. Verificación del criterio de aceptación (6.6) — WARNING, no EXCEPTION:
--     el stack local puede traer productos de seed con un texto fuera del
--     catálogo; en prod la medición del propose (0/0) hace que esto sea 0.
DO $$
DECLARE
  v_unresolved integer;
BEGIN
  SELECT COUNT(*) INTO v_unresolved
    FROM public.products
   WHERE category_id IS NULL AND deleted_at IS NULL;

  IF v_unresolved > 0 THEN
    RAISE WARNING 'productos-categorias-sku: % productos vivos quedaron con category_id NULL tras el backfill (texto sin categoría equivalente en su cuenta o cuenta NULL) — conservan su category TEXT.', v_unresolved;
  ELSE
    RAISE NOTICE 'productos-categorias-sku: backfill completo — 0 productos vivos sin category_id.';
  END IF;
END $$;


-- =============================================================================
-- 9. v_products_with_stock — lista de columnas viva byte a byte + category_id
--    al FINAL (CREATE OR REPLACE VIEW sólo admite agregar columnas al final).
--    security_invoker = true se re-declara explícito (reloptions vivas).
-- =============================================================================

CREATE OR REPLACE VIEW public.v_products_with_stock
WITH (security_invoker = true)
AS
 SELECT id,
    user_id,
    name,
    price,
    cost,
    created_at,
    category,
    COALESCE(( SELECT max(bs.min_stock) AS max
           FROM branch_stock bs
          WHERE bs.product_id = p.id), 0) AS min_stock,
    parent_id,
    barcode,
    is_variant,
    company_id,
    sku,
    account_id,
    deleted_at,
    stock_control_type,
    COALESCE(( SELECT sum(bs.quantity) AS sum
           FROM branch_stock bs
          WHERE bs.product_id = p.id), 0::numeric) AS stock,
    category_id
   FROM products p;

COMMENT ON VIEW public.v_products_with_stock IS
    'C-21: vista de compatibilidad con stock = Σ branch_stock. productos-categorias-sku: + category_id (última columna) — la fuente de verdad de la categoría; `category` sigue siendo el espejo TEXT para los lectores legacy.';
