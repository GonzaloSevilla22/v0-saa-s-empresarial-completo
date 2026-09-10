-- =============================================================================
-- MIGRATION: 20261040000001_productos_categoria_text_retiro.sql
-- CHANGE:    productos-categoria-text-retiro
-- Design ref: openspec/changes/productos-categoria-text-retiro/design.md (D1-D7)
--
-- productos-categorias-sku (archivada 2026-09-04) dejó products.category
-- (TEXT) viva como espejo mantenido por trigger, con su OQ-3 declarando el
-- retiro como change propio. Medición en prod 2026-09-09: 5.096 productos,
-- 0 sin category_id, 0 con el espejo desincronizado, 0 con category nula —
-- el invariante que hace segura la derivación se cumple al 100%.
--
-- Verificado el 2026-09-09 contra el cuerpo VIVO de prod (== base local
-- migrada, MAX(version) 20261039000001, 288 migraciones), md5 de
-- pg_get_functiondef con \r stripped:
--   rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,int,int)
--     = 161226a414cd527a76c8409d053fc352 (4098 bytes)
--   rpc_product_sales_evolution(uuid,uuid,date,date,text,uuid,text)
--     = 54bec72cbdb4e5447ff286635c2da519 (7819)
--   rpc_bulk_upsert_products(jsonb,uuid)
--     = 75b344563abb1b92655ac3343a34c44c (11477)
--   fn_product_category_mirror()
--     = d988e2170e5d238da1c15ddebb8d7c30 (647)
--   fn_product_category_propagate_name()
--     = 1703961241568e79705d5f9b1278f8aa (286)
-- Todas las reescrituras de abajo parten byte a byte de estos cuerpos.
--
-- Orden (D5): vista derivada → guard de tenencia particionado → tres RPCs
-- reescritas → guarda de verificación → DROP COLUMN. Todo IF EXISTS/CREATE
-- OR REPLACE — Supabase auto-aplica y puede reaplicar (idempotente).
-- =============================================================================


-- =============================================================================
-- 1. v_products_with_stock deriva `category` por LEFT JOIN (D1). La columna
--    física sigue existiendo en este paso — el CREATE OR REPLACE es legal
--    porque no cambia tipo ni posición de ninguna columna existente.
--    LEFT JOIN, nunca INNER: la vista es security_invoker=true y
--    product_categories tiene RLS — un INNER haría desaparecer del catálogo
--    cualquier producto cuya categoría el invocador no pueda ver.
-- =============================================================================

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
           FROM branch_stock bs
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
           FROM branch_stock bs
          WHERE bs.product_id = p.id), 0::numeric) AS stock,
    p.category_id
   FROM public.products p
   LEFT JOIN public.product_categories pc ON pc.id = p.category_id;

COMMENT ON COLUMN public.v_products_with_stock.category IS
    'productos-categoria-text-retiro: derivada de product_categories.name vía category_id (LEFT JOIN). Ya NO es una columna física de products — se conserva el nombre para que ningún lector cambie (D1/OQ-1). NULL si el producto no tiene category_id.';

-- productos-categoria-text-retiro: el comentario de la VISTA (no de una
-- columna puntual) seguía anunciando el espejo TEXT ya retirado. Misma frase
-- viva de antes de este change, sin la cláusula del espejo.
COMMENT ON VIEW public.v_products_with_stock IS
    'C-21: vista de compatibilidad con stock = Σ branch_stock. productos-categorias-sku: + category_id (última columna) — la fuente de verdad de la categoría.';

-- productos-categoria-text-retiro: idem para products.category_id — el
-- comentario vivo describía category_id COMO SI todavía existiera un espejo
-- TEXT que "nunca escribir a mano". Misma frase, sin esa cláusula.
COMMENT ON COLUMN public.products.category_id IS
    'productos-categorias-sku (D1): FUENTE DE VERDAD de la categoría. FK al catálogo de la cuenta.';


-- =============================================================================
-- 2. Guard de tenencia particionado (D4): fn_product_category_mirror() hacía
--    DOS cosas (espejo + rechazo P0404 de categoría ajena). El espejo se va;
--    el P0404 —único chequeo a nivel de base de ese invariante— sobrevive en
--    una función propia, reducida a esa sola responsabilidad. Mismo ERRCODE,
--    mismo texto (los clientes traducen por token).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_product_category_tenancy_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_cat_account uuid;
BEGIN
  IF NEW.category_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT pc.account_id
    INTO v_cat_account
    FROM public.product_categories pc
   WHERE pc.id = NEW.category_id;

  IF NOT FOUND OR v_cat_account IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION 'product_category_not_found: la categoría no existe o no pertenece a la cuenta del producto'
      USING ERRCODE = 'P0404';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_product_category_tenancy_guard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_product_category_tenancy_guard() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_product_category_tenancy_guard ON public.products;
CREATE TRIGGER trg_product_category_tenancy_guard
  BEFORE INSERT OR UPDATE OF category_id, account_id ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_product_category_tenancy_guard();

-- 2b. Retiro de los dos triggers/funciones de espejo — ya no hay columna que
--     mantener sincronizada, y el guard de tenencia vive en la función de
--     arriba. DROP FUNCTION antes de dropear la columna física (paso 5).
DROP TRIGGER IF EXISTS trg_product_category_mirror ON public.products;
DROP FUNCTION IF EXISTS public.fn_product_category_mirror();

DROP TRIGGER IF EXISTS trg_product_category_propagate_name ON public.product_categories;
DROP FUNCTION IF EXISTS public.fn_product_category_propagate_name();


-- =============================================================================
-- 3a. rpc_product_ranking — reescritura DESDE EL CUERPO VIVO (md5 de arriba).
--     CREATE OR REPLACE, MISMA firma, MISMO RETURNS TABLE. Único eje:
--     hp.category (columna física) → LEFT JOIN product_categories por
--     hp.category_id. No se toca ninguna otra CTE, el ORDER BY ni la firma.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_product_ranking(p_account_id uuid, p_start date, p_end date, p_order_by text DEFAULT 'units'::text, p_group_variants boolean DEFAULT true, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(rank integer, product_id uuid, product_name text, sku text, category text, parent_id uuid, parent_name text, is_group boolean, variant_count integer, units numeric, revenue numeric, operations bigint, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, cost_coverage_pct numeric, last_sale_date date, total_count bigint, window_start date, window_end date, history_days integer, window_clamped boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_w record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members am
    WHERE am.account_id = p_account_id AND am.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_order_by IS NULL OR p_order_by NOT IN ('units', 'revenue', 'margin') THEN
    RAISE EXCEPTION 'Invalid order: %', COALESCE(p_order_by, 'NULL') USING ERRCODE = 'P0400';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 OR p_offset IS NULL OR p_offset < 0 THEN
    RAISE EXCEPTION 'Invalid page: limit=% offset=%', p_limit, p_offset USING ERRCODE = 'P0400';
  END IF;

  SELECT * INTO v_w FROM public.reporting_plan_window(p_account_id, p_start, p_end);

  RETURN QUERY
  WITH lines AS (
    SELECT l.*
    FROM public.reporting_sales_lines_in_window(
           p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
    WHERE l.product_id IS NOT NULL
  ),
  keyed AS (
    SELECT l.*,
           pr.id AS pid,
           CASE WHEN p_group_variants AND pr.parent_id IS NOT NULL THEN pr.parent_id ELSE pr.id END AS group_id
    FROM lines l
    JOIN public.products pr ON pr.id = l.product_id
  ),
  agg AS (
    SELECT
      k.group_id,
      SUM(k.quantity)                                                                AS units,
      SUM(k.line_revenue)                                                            AS revenue,
      COUNT(DISTINCT k.operation_key)                                                AS ops,
      SUM(k.unit_cost * k.quantity)                                                  AS total_cost,
      ROUND(100.0 * COUNT(*) FILTER (WHERE k.has_cost_snapshot) / COUNT(*), 1)      AS cost_coverage_pct,
      MAX(k.business_date)                                                           AS last_sale_date,
      COUNT(DISTINCT k.pid) FILTER (WHERE k.pid <> k.group_id)                       AS variant_count
    FROM keyed k
    GROUP BY k.group_id
  ),
  ranked AS (
    SELECT
      a.*,
      hp.name        AS head_name,
      hp.sku         AS head_sku,
      hpc.name       AS head_category,
      hp.parent_id   AS head_parent_id,
      pp.name        AS head_parent_name,
      (a.revenue - a.total_cost) AS gross_margin,
      ROW_NUMBER() OVER (
        ORDER BY
          CASE p_order_by
            WHEN 'units'   THEN a.units
            WHEN 'revenue' THEN a.revenue
            ELSE                (a.revenue - a.total_cost)
          END DESC NULLS LAST,
          a.revenue DESC,
          hp.name ASC,
          a.group_id ASC
      ) AS rn,
      COUNT(*) OVER () AS total_count
    FROM agg a
    JOIN public.products hp ON hp.id = a.group_id
    LEFT JOIN public.products pp ON pp.id = hp.parent_id
    LEFT JOIN public.product_categories hpc ON hpc.id = hp.category_id
  )
  SELECT
    r.rn::integer,
    r.group_id,
    r.head_name,
    r.head_sku,
    r.head_category,
    r.head_parent_id,
    r.head_parent_name,
    (r.variant_count > 0),
    r.variant_count::integer,
    r.units,
    r.revenue,
    r.ops,
    r.total_cost,
    r.gross_margin,
    ROUND(r.gross_margin / NULLIF(r.revenue, 0) * 100, 2),
    r.cost_coverage_pct,
    r.last_sale_date,
    r.total_count,
    v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
  FROM ranked r
  ORDER BY r.rn
  LIMIT p_limit OFFSET p_offset;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) TO service_role;


-- =============================================================================
-- 3b. rpc_product_sales_evolution — ídem, pr.category (columna física) →
--     LEFT JOIN product_categories por pr.category_id, en la resolución de
--     v_head. Misma firma, mismo RETURNS TABLE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_product_sales_evolution(p_account_id uuid, p_product_id uuid, p_start date, p_end date, p_bucket text DEFAULT 'day'::text, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS TABLE(row_kind text, rank integer, product_id uuid, product_name text, product_sku text, product_category text, parent_id uuid, parent_name text, is_group boolean, variant_count integer, bucket_start date, bucket_end date, variant_id uuid, variant_name text, variant_sku text, units numeric, revenue numeric, operations bigint, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, cost_coverage_pct numeric, last_sale_date date, window_start date, window_end date, history_days integer, window_clamped boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_w    record;
  v_head record;
  v_step interval;
BEGIN
  -- Guard de membresía: primera sentencia, antes de leer dato alguno.
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members am
    WHERE am.account_id = p_account_id AND am.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_bucket IS NULL OR p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'Invalid bucket: %', COALESCE(p_bucket, 'NULL') USING ERRCODE = 'P0400';
  END IF;

  -- Tenencia del producto: sólo un producto de ESTA cuenta resuelve. Ajeno e
  -- inexistente reciben el mismo P0404 — no se revela si el id existe. El
  -- padre se rotula sólo si es de la misma cuenta (defensa en profundidad).
  -- productos-categoria-text-retiro: category ya no es columna física de pr —
  -- se deriva por LEFT JOIN contra product_categories (D1).
  SELECT pr.id, pr.name, pr.sku, prc.name AS category, pr.parent_id, pp.name AS parent_name
    INTO v_head
  FROM public.products pr
  LEFT JOIN public.products pp ON pp.id = pr.parent_id AND pp.account_id = p_account_id
  LEFT JOIN public.product_categories prc ON prc.id = pr.category_id
  WHERE pr.id = p_product_id AND pr.account_id = p_account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P0404';
  END IF;

  -- D8: clamp de historial (valida el rango, P0400 si está invertido).
  SELECT * INTO v_w FROM public.reporting_plan_window(p_account_id, p_start, p_end);

  v_step := CASE p_bucket
              WHEN 'day'  THEN interval '1 day'
              WHEN 'week' THEN interval '1 week'
              ELSE             interval '1 month'
            END;

  RETURN QUERY
  WITH members AS (
    -- El grupo: el producto pedido + sus variantes (parent_id = él), de la
    -- misma cuenta. Misma regla de agrupación que rpc_product_ranking.
    SELECT pr.id AS pid, pr.name AS pname, pr.sku AS psku
    FROM public.products pr
    WHERE pr.account_id = p_account_id
      AND (pr.id = p_product_id OR pr.parent_id = p_product_id)
  ),
  lines AS (
    -- Toda la población viene del helper canónico (D1): revenue de línea,
    -- bordes RN-D5, cascada de costo, filtros de sucursal / canal. El bucket
    -- se deriva de la fecha de negocio casteada (D3), semana ISO (D4).
    SELECT l.*,
           date_trunc(p_bucket, l.business_date::timestamp)::date AS b
    FROM public.reporting_sales_lines_in_window(
           p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
    JOIN members m ON m.pid = l.product_id
  ),
  total AS (
    SELECT
      COALESCE(SUM(l.quantity), 0)                                            AS t_units,
      COALESCE(SUM(l.line_revenue), 0)                                        AS t_revenue,
      COUNT(DISTINCT l.operation_key)                                         AS t_ops,
      SUM(l.unit_cost * l.quantity)                                           AS t_cost,
      CASE WHEN COUNT(l.sale_id) > 0
           THEN ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost_snapshot) / COUNT(l.sale_id), 1)
           ELSE NULL END                                                      AS t_coverage,
      MAX(l.business_date)                                                    AS t_last_sale,
      COUNT(DISTINCT l.product_id) FILTER (WHERE l.product_id <> p_product_id) AS t_variants
    FROM lines l
  ),
  buckets AS (
    SELECT gs::date                                             AS b,
           GREATEST(gs::date, v_w.window_start)                 AS b_from,
           LEAST((gs + v_step)::date - 1, v_w.window_end)        AS b_to
    FROM generate_series(
           date_trunc(p_bucket, v_w.window_start::timestamp),
           date_trunc(p_bucket, v_w.window_end::timestamp),
           v_step) AS gs
  ),
  bucket_agg AS (
    SELECT b.b, b.b_from, b.b_to,
           COALESCE(SUM(l.quantity), 0)                                        AS b_units,
           COALESCE(SUM(l.line_revenue), 0)                                    AS b_revenue,
           COUNT(DISTINCT l.operation_key)                                     AS b_ops,
           SUM(l.unit_cost * l.quantity)                                       AS b_cost,
           CASE WHEN COUNT(l.sale_id) > 0
                THEN ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost_snapshot) / COUNT(l.sale_id), 1)
                ELSE NULL END                                                  AS b_coverage,
           MAX(l.business_date)                                                AS b_last_sale
    FROM buckets b
    LEFT JOIN lines l ON l.b = b.b
    GROUP BY b.b, b.b_from, b.b_to
  ),
  member_agg AS (
    SELECT l.product_id                                                        AS m_pid,
           SUM(l.quantity)                                                     AS m_units,
           SUM(l.line_revenue)                                                 AS m_revenue,
           COUNT(DISTINCT l.operation_key)                                     AS m_ops,
           SUM(l.unit_cost * l.quantity)                                       AS m_cost,
           ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost_snapshot) / COUNT(*), 1) AS m_coverage,
           MAX(l.business_date)                                                AS m_last_sale
    FROM lines l
    GROUP BY l.product_id
  ),
  member_rows AS (
    SELECT ma.*, m.pname, m.psku,
           ROW_NUMBER() OVER (ORDER BY ma.m_revenue DESC, ma.m_units DESC, m.pname ASC, ma.m_pid ASC) AS rn
    FROM member_agg ma
    JOIN members m ON m.pid = ma.m_pid
  ),
  out_rows AS (
    SELECT 0 AS ord, NULL::date AS sk_date, 0::bigint AS sk,
           'total'::text AS kind, NULL::integer AS rk,
           NULL::date AS bs, NULL::date AS be,
           NULL::uuid AS vid, NULL::text AS vname, NULL::text AS vsku,
           t.t_units AS o_units, t.t_revenue AS o_revenue, t.t_ops AS o_ops,
           t.t_cost AS o_cost, t.t_coverage AS o_coverage, t.t_last_sale AS o_last_sale
    FROM total t
    UNION ALL
    SELECT 1, ba.b, 0::bigint,
           'bucket', NULL::integer,
           ba.b, ba.b_to,
           NULL::uuid, NULL::text, NULL::text,
           ba.b_units, ba.b_revenue, ba.b_ops,
           ba.b_cost, ba.b_coverage, ba.b_last_sale
    FROM bucket_agg ba
    UNION ALL
    SELECT 2, NULL::date, mr.rn,
           'member', mr.rn::integer,
           NULL::date, NULL::date,
           mr.m_pid, mr.pname, mr.psku,
           mr.m_units, mr.m_revenue, mr.m_ops,
           mr.m_cost, mr.m_coverage, mr.m_last_sale
    FROM member_rows mr
  )
  SELECT
    o.kind,
    o.rk,
    v_head.id,
    v_head.name,
    v_head.sku,
    v_head.category,
    v_head.parent_id,
    v_head.parent_name,
    (t.t_variants > 0),
    t.t_variants::integer,
    o.bs,
    o.be,
    o.vid,
    o.vname,
    o.vsku,
    o.o_units,
    o.o_revenue,
    o.o_ops,
    o.o_cost,
    (o.o_revenue - o.o_cost),
    ROUND((o.o_revenue - o.o_cost) / NULLIF(o.o_revenue, 0) * 100, 2),
    o.o_coverage,
    o.o_last_sale,
    v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
  FROM out_rows o
  CROSS JOIN total t
  ORDER BY o.ord, o.sk_date, o.sk;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) TO service_role;


-- =============================================================================
-- 3c. rpc_bulk_upsert_products — reescritura DESDE EL CUERPO VIVO (md5 de
--     arriba). CREATE OR REPLACE, MISMA firma (jsonb, uuid). Único eje: se
--     quita `category` de la lista de columnas del INSERT y su valor
--     COALESCE(v_cat_name, 'Otros') — un 'Otros' hardcodeado que el trigger
--     de espejo pisaba acto seguido y que ya no tiene destino. No se toca la
--     resolución/creación de categorías, el tope, la resolución de padre ni
--     el EXCEPTION por fila.
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
        -- productos-categoria-text-retiro: la columna de categoría se retiró
        -- del INSERT — no existe más la columna física ni el trigger que la pisaba.
        INSERT INTO public.products (
          user_id, account_id, name, category_id, price, cost, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_account_id,
          v_row->>'name',
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

-- ACLs idénticas a las vivas (no cambian con esta reescritura):
-- {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
REVOKE ALL     ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) TO service_role;


-- =============================================================================
-- 4. Guarda de verificación ANTES del DROP (D5, paso 4): si existiera algún
--    producto con category_id NULL pero con texto legacy no vacío, dropear la
--    columna perdería ese dato. Medido 0 en prod el 2026-09-09 — la guarda
--    convierte esa medición en garantía que no vence: si un camino nuevo
--    escribiera category a mano sin category_id entre el propose y el merge,
--    la migración falla ruidosamente en vez de dropear en silencio.
-- =============================================================================

DO $$
DECLARE
  v_orphans       int;
  v_column_exists boolean;
BEGIN
  -- Idempotencia: en una reaplicación, la columna física ya fue dropeada por
  -- la corrida anterior — el chequeo no tiene nada que verificar (y no debe
  -- intentar referenciar una columna que ya no existe).
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'category'
  ) INTO v_column_exists;

  IF v_column_exists THEN
    SELECT COUNT(*) INTO v_orphans
      FROM public.products
     WHERE category_id IS NULL
       AND category IS NOT NULL
       AND category <> '';

    IF v_orphans > 0 THEN
      RAISE EXCEPTION 'productos-categoria-text-retiro: % producto(s) tienen una categoría de texto legacy sin category_id — el DROP COLUMN perdería ese dato. Backfill de category_id requerido antes de continuar.', v_orphans;
    END IF;
  END IF;
END $$;


-- =============================================================================
-- 5. DROP COLUMN — única representación física restante: category_id.
-- =============================================================================

ALTER TABLE public.products DROP COLUMN IF EXISTS category;
