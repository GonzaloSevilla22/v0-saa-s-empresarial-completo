-- =============================================================================
-- 20261066000001_balanza_etiquetas_pos.sql
-- balanza-etiquetas-pos (governance MEDIA con tramos LOW; sign-off del PO
-- 2026-09-28: "ya pasó el validate kpi y aplica todo con recomendaciones").
--
-- Pedido del PO: integrar la balanza etiquetadora de una verdulería (Systel
-- Cuora Neo). Aliadata LEE la etiqueta (EAN-13 con cabecera 2x, PLU e importe)
-- con el lector común; no se conecta a la balanza (D1). Esta migración sólo
-- agrega los datos que esa lectura necesita:
--
--   1. products.scale_plu (D2): tercer código del producto — el número de
--      artículo (PLU) que la balanza imprime en la etiqueta. integer NULL,
--      CHECK 1..999999 (tiene que caber en el campo "Código" del EAN-13),
--      CHECK products_scale_plu_not_parent (un padre variant_only se vende a
--      través de sus variantes — la regla vive en la base para que la
--      sostengan el importador, la conversión en padre y cualquier escritura
--      directa) e índice único parcial por CUENTA sobre filas vivas (molde
--      exacto de idx_products_barcode_account_unique, 20261031000001, con su
--      verificación defensiva de colisiones).
--   2. v_products_with_stock + scale_plu como ÚLTIMA columna (CREATE OR
--      REPLACE desde la definición VIVA de prod leída el 2026-09-28 —
--      pg_get_viewdef equivalente a 20261062000001 L2989 —; ningún lector
--      cambia de posición; security_invoker, COMMENTs y ACLs conservados).
--   3. public.scale_settings (D3): configuración de la balanza por cuenta
--      (habilitada + los tres formatos A–D de la pantalla de la balanza). RLS:
--      SELECT miembros, INSERT/UPDATE is_account_writer, sin DELETE; disparador
--      SECURITY DEFINER que exige owner/admin (P0401) — la política de
--      escritura habilita a los 7 roles escritores, el mismo hueco que cerró
--      points_of_sale_guard_default_owner_admin (20261063000001). anon sin
--      privilegios.
--   4. rpc_bulk_upsert_products (D14): CREATE OR REPLACE desde el cuerpo VIVO
--      de prod (md5(prosrc) 06be318a8d9181056973ac9b849c8cc2 el 2026-09-28,
--      idéntico al de 20261044000001) con DOS cambios y sólo esos: persiste
--      scale_plu (celda ausente/vacía conserva, igual que barcode) y, en la
--      rama EXCEPTION por fila, el mensaje nombra el código de balanza para
--      las dos restricciones nuevas (el SQLERRM de un 23505 no trae el valor
--      de la clave). Misma firma → sin overload; COMMENT y ACLs conservados
--      (revocada de authenticated: sólo se alcanza vía rpc_import_products).
--
-- Ninguna RPC de venta, caja, banco, cuenta corriente, asiento ni fiscal
-- cambia (D16). Sin backfill: scale_plu nace NULL y scale_settings sin filas.
--
-- Idempotente (el auto-apply de Supabase GitHub reaplica): ADD COLUMN IF NOT
-- EXISTS, CHECKs guardados contra pg_constraint, índice IF NOT EXISTS, CREATE
-- OR REPLACE VIEW/FUNCTION con la misma forma, CREATE TABLE IF NOT EXISTS,
-- DROP POLICY/TRIGGER IF EXISTS + CREATE, REVOKE/GRANT idempotentes.
--
-- Gate: supabase/tests/test_balanza_etiquetas_pos.sql (EJECUTA
-- rpc_import_products como un owner real).
-- APPLY: vía CI al mergear a main. NUNCA con el MCP apply_migration.
-- ROLLBACK: re-aplicar el cuerpo de rpc_bulk_upsert_products de
--   20261044000001 en una migración nueva; columna y tabla quedan sin uso.
-- =============================================================================

-- ── 1. products.scale_plu ────────────────────────────────────────────────────
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS scale_plu integer;

COMMENT ON COLUMN public.products.scale_plu IS
  'balanza-etiquetas-pos (D2): código de artículo (PLU) con el que la balanza '
  'etiquetadora identifica al producto y que imprime en el EAN-13 de la '
  'etiqueta. Opcional, 1..999999, único por cuenta sobre filas vivas '
  '(idx_products_scale_plu_account_unique). Un padre variant_only no lleva PLU '
  '(CHECK products_scale_plu_not_parent). No es sku ni barcode.';

-- Verificación defensiva de colisiones (molde 20261031000001 §1). En la
-- primera aplicación la columna nace vacía (0 colisiones); en una
-- reaplicación vuelve a medir contra el estado vivo.
DO $$
DECLARE
  v_collisions integer;
  v_detail     text;
BEGIN
  SELECT COUNT(*), string_agg(format('%s/%s (%s)', c.account_id, c.scale_plu, c.n), '; ')
    INTO v_collisions, v_detail
    FROM (
      SELECT account_id, scale_plu, COUNT(*) AS n
        FROM public.products
       WHERE scale_plu IS NOT NULL AND deleted_at IS NULL
       GROUP BY account_id, scale_plu
      HAVING COUNT(*) > 1
    ) c;

  IF v_collisions > 0 THEN
    RAISE EXCEPTION 'balanza-etiquetas-pos: % colisiones de código de balanza por cuenta impiden crear idx_products_scale_plu_account_unique — resolver a mano antes de reaplicar: %',
      v_collisions, v_detail;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.products'::regclass
      AND  conname  = 'products_scale_plu_range'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_scale_plu_range
      CHECK (scale_plu IS NULL OR scale_plu BETWEEN 1 AND 999999);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.products'::regclass
      AND  conname  = 'products_scale_plu_not_parent'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_scale_plu_not_parent
      CHECK (scale_plu IS NULL OR stock_control_type IS DISTINCT FROM 'variant_only');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_scale_plu_account_unique
    ON public.products (account_id, scale_plu)
    WHERE scale_plu IS NOT NULL AND deleted_at IS NULL;

-- ── 2. v_products_with_stock + scale_plu al final ────────────────────────────
-- Definición VIVA de prod (pg_get_viewdef 2026-09-28) + p.scale_plu. CREATE
-- OR REPLACE sólo admite AGREGAR columnas al final: las 19 existentes quedan
-- en su posición. Conserva security_invoker; COMMENTs de columnas y ACLs se
-- conservan con el OR REPLACE y se re-emiten igual abajo.
CREATE OR REPLACE VIEW public.v_products_with_stock
WITH (security_invoker=true) AS
 SELECT p.id,
    p.user_id,
    p.name,
    p.price,
    p.cost,
    p.created_at,
    pc.name AS category,
    COALESCE(( SELECT max(bs.min_stock) AS max
           FROM public.branch_stock bs
          WHERE bs.product_id = p.id), 0) AS min_stock,
    p.parent_id,
    p.barcode,
    p.is_variant,
    p.company_id,
    p.sku,
    p.account_id,
    p.deleted_at,
    p.stock_control_type,
    COALESCE(( SELECT sum(bs.quantity) AS sum
           FROM public.branch_stock bs
          WHERE bs.product_id = p.id), 0::numeric) AS stock,
    p.category_id,
    COALESCE(p.base_unit_id, pp.base_unit_id) AS base_unit_id,
    p.scale_plu
   FROM public.products p
   LEFT JOIN public.product_categories pc ON pc.id = p.category_id
   LEFT JOIN public.products pp ON pp.id = p.parent_id;

COMMENT ON COLUMN public.v_products_with_stock.scale_plu IS
    'balanza-etiquetas-pos (D2): código de balanza (PLU) del producto. Última columna (aditiva al final, ningún lector cambia de posición).';
COMMENT ON VIEW public.v_products_with_stock IS
    'C-21: vista de compatibilidad con stock = Σ branch_stock. productos-categorias-sku: + category_id (última columna) — la fuente de verdad de la categoría. ventas-unidades-conversion: min_stock numeric(15,4) (unidad base del producto). balanza-etiquetas-pos: + scale_plu (última columna).';

-- ACLs vivas de prod (relacl): anon / authenticated / service_role con ALL.
GRANT ALL ON public.v_products_with_stock TO anon, authenticated, service_role;

-- ── 3. scale_settings ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.scale_settings (
  account_id  uuid        PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  enabled     boolean     NOT NULL DEFAULT false,
  layouts     jsonb       NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid        NULL,
  -- Red de forma: la validación completa (reglas D4) vive en el esquema
  -- Pydantic del backend y en el zod del frontend, con casos compartidos.
  -- CASE y no AND: jsonb_array_length sobre un no-array LANZA en vez de dar
  -- false, y el orden de evaluación de un AND no está garantizado.
  CONSTRAINT scale_settings_layouts_shape CHECK (
    CASE WHEN jsonb_typeof(layouts) = 'array'
         THEN jsonb_array_length(layouts) = 3
         ELSE false
    END
  )
);

COMMENT ON TABLE public.scale_settings IS
  'balanza-etiquetas-pos (D3): configuración de la balanza etiquetadora por cuenta. '
  'Sin fila = lectura deshabilitada con los formatos de fábrica de la Systel Cuora Neo '
  '(el GET /scale-settings devuelve los defaults; el primer PUT inserta). '
  'Escritura sólo owner/admin (disparador trg_scale_settings_guard_owner_admin, P0401) '
  'además de la RLS is_account_writer; sin DELETE.';
COMMENT ON COLUMN public.scale_settings.enabled IS
  'balanza-etiquetas-pos (D3): lectura de etiquetas de balanza habilitada para la cuenta.';
COMMENT ON COLUMN public.scale_settings.layouts IS
  'balanza-etiquetas-pos (D3): array de 3 formatos [weighed, unit, multi], cada uno '
  '{kind, enabled, segments: [{field: fixed|plu|amount|quantity|ignored, digits, value?, decimals?}]} '
  '— los campos A–D como los muestra la pantalla "Formato de código de barras" de la balanza.';
COMMENT ON COLUMN public.scale_settings.updated_by IS
  'balanza-etiquetas-pos (D3): usuario que guardó la configuración por última vez (sin FK dura).';

ALTER TABLE public.scale_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "scale_settings_member_select" ON public.scale_settings;
CREATE POLICY "scale_settings_member_select" ON public.scale_settings
    FOR SELECT
    TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

DROP POLICY IF EXISTS "scale_settings_writer_insert" ON public.scale_settings;
CREATE POLICY "scale_settings_writer_insert" ON public.scale_settings
    FOR INSERT
    TO authenticated
    WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "scale_settings_writer_update" ON public.scale_settings;
CREATE POLICY "scale_settings_writer_update" ON public.scale_settings
    FOR UPDATE
    TO authenticated
    USING     (is_account_writer(account_id))
    WITH CHECK (is_account_writer(account_id));

REVOKE ALL ON public.scale_settings FROM anon;

-- Guard owner/admin (cuerpo espejo de points_of_sale_guard_default_owner_admin,
-- 20261063000001): toda escritura exige que el actor sea owner o admin de la
-- cuenta. Además, una fila no se muda de cuenta.
CREATE OR REPLACE FUNCTION public.scale_settings_guard_owner_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
    RAISE EXCEPTION 'unauthorized: scale_settings.account_id is immutable'
      USING ERRCODE = 'P0401';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM   public.account_members am
    JOIN   LATERAL unnest(public.member_active_roles(am.id)) AS r(code) ON true
    WHERE  am.account_id = NEW.account_id
      AND  am.user_id    = (SELECT auth.uid())
      AND  r.code IN ('owner', 'admin')
  ) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can change scale_settings'
      USING ERRCODE = 'P0401';
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.scale_settings_guard_owner_admin() IS
  'balanza-etiquetas-pos (D3): la RLS de scale_settings habilita INSERT/UPDATE a los '
  '7 roles is_writer=true (is_account_writer); este disparador restringe la escritura '
  'a owner/admin (P0401), la misma regla que el backend aplica con CAN_CONFIGURE. '
  'Sólo lo invoca el trigger: sin EXECUTE para PUBLIC/anon/authenticated.';

-- SECURITY DEFINER (lee account_members/member_active_roles sin depender de la
-- RLS del actor) pero NUNCA una RPC de usuario: sin este REVOKE,
-- test_function_acl_gate.sql (1) la marca como función trigger SECURITY
-- DEFINER ejecutable por anon/authenticated.
REVOKE ALL ON FUNCTION public.scale_settings_guard_owner_admin() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_scale_settings_guard_owner_admin ON public.scale_settings;
CREATE TRIGGER trg_scale_settings_guard_owner_admin
  BEFORE INSERT OR UPDATE ON public.scale_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.scale_settings_guard_owner_admin();

-- ── 4. rpc_bulk_upsert_products (D14) ────────────────────────────────────────
-- Desde el cuerpo VIVO de prod; el diff contra 20261044000001 son SÓLO las
-- líneas marcadas "balanza-etiquetas-pos (D14)": la variable v_constraint, la
-- columna scale_plu en el UPDATE y en el INSERT, y el mensaje de la rama
-- EXCEPTION por fila para las dos restricciones del código de balanza.
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

-- COMMENT y ACL vivos, re-emitidos idénticos (el OR REPLACE ya los conserva).
COMMENT ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) IS
  'Alta masiva de productos. Invocable SOLO desde rpc_import_products (SECURITY DEFINER) y service_role — importador-productos-fastapi (D4) le retira EXECUTE a authenticated: el backend es el único camino de importación.';
REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC, anon, authenticated;

-- ── 5. Introspección (sólo catálogo) ─────────────────────────────────────────
DO $$
DECLARE
  v_bad      text[] := '{}';
  v_last_col text;
  v_count    integer;
  v_def      text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'products'
      AND column_name = 'scale_plu' AND data_type = 'integer' AND is_nullable = 'YES'
  ) THEN
    v_bad := v_bad || 'products.scale_plu no es integer NULL'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.products'::regclass AND conname = 'products_scale_plu_range') THEN
    v_bad := v_bad || 'falta products_scale_plu_range'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.products'::regclass AND conname = 'products_scale_plu_not_parent') THEN
    v_bad := v_bad || 'falta products_scale_plu_not_parent'::text;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE i.indrelid = 'public.products'::regclass AND c.relname = 'idx_products_scale_plu_account_unique' AND i.indisunique
  ) THEN
    v_bad := v_bad || 'falta idx_products_scale_plu_account_unique'::text;
  END IF;

  SELECT column_name INTO v_last_col
  FROM   information_schema.columns
  WHERE  table_schema = 'public' AND table_name = 'v_products_with_stock'
  ORDER  BY ordinal_position DESC LIMIT 1;
  IF v_last_col IS DISTINCT FROM 'scale_plu' THEN
    v_bad := v_bad || format('la última columna de v_products_with_stock es %s, no scale_plu', v_last_col);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.v_products_with_stock'::regclass AND reloptions @> ARRAY['security_invoker=true']) THEN
    v_bad := v_bad || 'v_products_with_stock perdió security_invoker'::text;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.scale_settings'::regclass AND relrowsecurity) THEN
    v_bad := v_bad || 'scale_settings sin RLS'::text;
  END IF;
  SELECT count(*) INTO v_count FROM pg_policies WHERE schemaname = 'public' AND tablename = 'scale_settings';
  IF v_count <> 3 OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'scale_settings' AND cmd IN ('DELETE', 'ALL')) THEN
    v_bad := v_bad || format('scale_settings debía tener 3 políticas sin DELETE; tiene %s', v_count);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.scale_settings'::regclass AND tgname = 'trg_scale_settings_guard_owner_admin') THEN
    v_bad := v_bad || 'falta trg_scale_settings_guard_owner_admin'::text;
  END IF;
  IF has_function_privilege('anon', 'public.scale_settings_guard_owner_admin()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.scale_settings_guard_owner_admin()', 'EXECUTE') THEN
    v_bad := v_bad || 'scale_settings_guard_owner_admin() ejecutable por anon/authenticated'::text;
  END IF;
  IF has_table_privilege('anon', 'public.scale_settings', 'SELECT')
     OR has_table_privilege('anon', 'public.scale_settings', 'INSERT')
     OR has_table_privilege('anon', 'public.scale_settings', 'UPDATE')
     OR has_table_privilege('anon', 'public.scale_settings', 'DELETE') THEN
    v_bad := v_bad || 'anon conserva privilegios sobre scale_settings'::text;
  END IF;

  v_def := pg_get_functiondef('public.rpc_bulk_upsert_products(jsonb, uuid)'::regprocedure);
  IF v_def NOT LIKE '%scale_plu%' OR v_def NOT LIKE '%CONSTRAINT_NAME%' THEN
    v_bad := v_bad || 'rpc_bulk_upsert_products sin scale_plu o sin CONSTRAINT_NAME'::text;
  END IF;
  IF has_function_privilege('authenticated', 'public.rpc_bulk_upsert_products(jsonb, uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_bulk_upsert_products(jsonb, uuid)', 'EXECUTE') THEN
    v_bad := v_bad || 'rpc_bulk_upsert_products ejecutable por authenticated/anon'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'balanza-etiquetas-pos (introspección) FAILED:\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'balanza-etiquetas-pos (introspección): OK — última columna de v_products_with_stock = %', v_last_col;
END $$;
