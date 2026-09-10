-- =============================================================================
-- MIGRATION: 20261042000001_products_cost_nullable.sql
-- CHANGE: productos-costo-nullable
--
-- QUÉ: `products.cost` pasa de NUMERIC NOT NULL DEFAULT 0 a NUMERIC NULLABLE
-- sin default. NULL = "no se cargó el costo"; 0 = "el costo es cero,
-- declarado". Backfill de los 2.617 productos con cost=0 → NULL (OQ-1,
-- sign-off del PO: todos, ninguno tiene evidencia de cero real — 0 de 2.617
-- comprados alguna vez con costo positivo). Reescritura de 4 funciones desde
-- su CUERPO VIVO de prod (regla de integridad de función — hashes abajo) para
-- que la cascada canónica RN-D2 pueda rendir NULL sin que ningún consumidor
-- lo sustituya por cero.
--
-- POR QUÉ: un producto sin costo hoy aparenta margen 100% (indistinguible de
-- uno medido) y encabeza todo ranking por rentabilidad. Ver design.md
-- (D1-D14) y proposal.md del change.
--
-- IDEMPOTENCIA:
--   - Paso 1 (DROP NOT NULL / DROP DEFAULT): idempotente por naturaleza.
--   - Paso 2 (backfill): idempotente por el WHERE (2da corrida no matchea).
--   - Pasos 3-6 (DROP+CREATE / CREATE OR REPLACE de funciones + ACLs):
--     idempotentes (DROP FUNCTION IF EXISTS, CREATE reemplaza, GRANT/REVOKE
--     son absolutos, no aditivos).
--
-- CUERPOS VIVOS verificados contra prod 2026-09-10 (~01:30 UTC), md5 sobre
-- pg_get_functiondef con \r stripped (gotcha CRLF checkout Windows ya
-- registrado — comparación por líneas, no por archivo crudo):
--   reporting_sales_lines_in_window(uuid,date,date,uuid,text) = 23be1e64c7490c3b4675dd05161475a4 (1817b)
--   rpc_product_ranking(9 args)                               = ed695c2c88a0dfa733430e6827ed1907 (4169b)
--   rpc_product_sales_evolution(7 args)                       = 018b549017fc31905dec06b3ee2c3830 (8037b)
--   rpc_bulk_upsert_products(jsonb,uuid)                      = d76c6b6b232ef8b6fd956def9597005d (11593b)
--   rpc_dashboard_kpi_summary(5 args)                         = 8c459a12e345edd7999682eb2571addf (10229b)
-- (rpc_product_profitability, check_low_margin, op_line_snapshot: verificados
-- idénticos, NO se tocan — D5/D6/D8 del design).
--
-- EXCEPCIÓN DECLARADA A RN-D2 (revisión ronda 2, ver design.md Non-Goals y
-- specs/reporting-invariants/spec.md): `rpc_dashboard_kpi_summary.cogs`/
-- `prev_cogs` (dentro de sales_agg, NO se tocan) y `rpc_dashboard_channel_
-- margin` (NO se toca, ninguna de sus 5 apariciones de COALESCE) SIGUEN
-- tratando un costo ausente como cero — comportamiento idéntico al de antes
-- de este change (`pr.cost` ya era 0, nunca NULL, para estos productos).
-- Gate de regresión: test_productos_costo_nullable.sql T14.
--
-- HALLAZGO DEL CHECKPOINT (task 1.2, ver tasks.md grupo 1): la base local
-- compartida tenía la migración `20261040000001_productos_categoria_text_
-- retiro.sql` (ya en main) sin aplicar — por eso `rpc_product_ranking` local
-- seguía usando `hp.category` en vez de `hpc.name`/`product_categories`. Se
-- aplicó esa migración antes de escribir ésta para partir del cuerpo vivo
-- real. Esta migración parte de los cuerpos de PROD (arriba), no de lo que
-- tuviera el archivo de migración anterior.
--
-- ROLLBACK EXACTO (si hay que revertir):
--   UPDATE public.products SET cost = 0 WHERE cost IS NULL;
--   ALTER TABLE public.products ALTER COLUMN cost SET NOT NULL, ALTER COLUMN cost SET DEFAULT 0;
--   -- + restaurar los 4 cuerpos previos (hashes arriba; el pg_get_functiondef
--   --   completo de cada uno queda en el registro del apply / tasks.md).
-- =============================================================================

-- ── Paso 1: NULLABLE sin default + semántica documentada en la base ─────────
ALTER TABLE public.products
  ALTER COLUMN cost DROP NOT NULL,
  ALTER COLUMN cost DROP DEFAULT;

COMMENT ON COLUMN public.products.cost IS
  'Costo del producto. NULL = no se cargó el costo (dato ausente, no cero). '
  '0 = costo cero declarado explícitamente por el usuario. Los dos estados '
  'son hechos distintos del negocio — ver capability product-cost. Un '
  'producto padre de variantes (stock_control_type = ''variant_only'') no '
  'tiene costo propio: el de cada variante es el que cuenta.';

-- ── Paso 2: backfill 0 → NULL (OQ-1, sign-off: todos) ────────────────────────
DO $$
DECLARE
  v_count int;
BEGIN
  UPDATE public.products SET cost = NULL WHERE cost = 0;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'productos-costo-nullable: backfill cost=0 -> NULL afectó % filas.', v_count;
END $$;

-- ── Paso 3: reporting_sales_lines_in_window — has_cost_snapshot -> has_cost ──
-- RETURNS TABLE cambia (renombra 1 columna) -> DROP + CREATE, nunca REPLACE
-- (gotcha 42725 ya registrado: CREATE OR REPLACE con distinto tipo de
-- retorno falla; con firma distinta deja un overload vivo).
DROP FUNCTION IF EXISTS public.reporting_sales_lines_in_window(uuid, date, date, uuid, text);

CREATE FUNCTION public.reporting_sales_lines_in_window(p_account_id uuid, p_start date, p_end date, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS TABLE(sale_id uuid, operation_key uuid, product_id uuid, client_id uuid, branch_id uuid, canal text, business_date date, created_at timestamp with time zone, quantity numeric, line_revenue numeric, unit_cost numeric, has_cost boolean)
 LANGUAGE sql
 STABLE
AS $function$
  SELECT
    s.id,
    COALESCE(s.operation_id, s.id),
    s.product_id,
    s.client_id,
    s.branch_id,
    s.canal,
    -- reporting-invariants (fecha de negocio vs instante): sales.date guarda el
    -- día calendario declarado a 00:00 UTC. Casteo DIRECTO — aplicarle
    -- AT TIME ZONE corre cada venta un día hacia atrás (218/218 medido).
    s.date::date,
    s.created_at,
    s.quantity,
    -- RN-D (revenue de línea consistente): COALESCE(total, amount), nunca
    -- amount solo (precio unitario).
    COALESCE(s.total, s.amount),
    -- RN-D2 cascada canónica: snapshot congelado de la línea; products.cost
    -- actual sólo cuando la línea no tiene snapshot. products-costo-nullable:
    -- la nulabilidad se propaga sola — el costo del catálogo es opcional.
    COALESCE(si.unit_cost_snapshot, pr.cost),
    -- productos-costo-nullable (D3): has_cost_snapshot -> has_cost. La
    -- pregunta que la spec product-ranking hace es "¿tiene costo?", no
    -- "¿tiene snapshot?" — una línea sin snapshot pero con costo de catálogo
    -- real tiene su margen perfectamente medido y debe contar como cubierta.
    (COALESCE(si.unit_cost_snapshot, pr.cost) IS NOT NULL)
  FROM public.sales s
  LEFT JOIN public.products   pr ON pr.id = s.product_id
  LEFT JOIN public.sale_items si ON si.sale_id = s.id AND si.product_id = s.product_id
  WHERE s.account_id = p_account_id
    -- RN-D5: bordes >= inicio y < fin + 1 día (ambos a medianoche UTC, como
    -- las filas). p_end NULL = sin borde superior (rpc_product_profitability).
    AND s.date >= p_start::timestamptz
    AND (p_end IS NULL OR s.date < (p_end + 1)::timestamptz)
    AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (p_canal     IS NULL OR s.canal     = p_canal);
$function$;

REVOKE ALL     ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) TO service_role;

-- ── Paso 4: rpc_product_ranking — único cambio real: el predicado del FILTER ─
-- Partido del cuerpo VIVO de prod (hash arriba). Firma, RETURNS TABLE, CTEs y
-- ORDER BY ... NULLS LAST intactos.
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
      -- productos-costo-nullable (D3/D4): has_cost_snapshot -> has_cost. La
      -- SUM ya rinde NULL sola cuando ningún costo del grupo resuelve — el
      -- único cambio es qué cuenta como "cubierto".
      ROUND(100.0 * COUNT(*) FILTER (WHERE k.has_cost) / COUNT(*), 1)              AS cost_coverage_pct,
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
GRANT  EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) TO authenticated, service_role;

-- ── Paso 4b: rpc_product_sales_evolution — las TRES expresiones de cobertura ─
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
           THEN ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost) / COUNT(l.sale_id), 1)
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
                THEN ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost) / COUNT(l.sale_id), 1)
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
           ROUND(100.0 * COUNT(*) FILTER (WHERE l.has_cost) / COUNT(*), 1) AS m_coverage,
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
GRANT  EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) TO authenticated, service_role;

-- ── Paso 5: rpc_bulk_upsert_products — celda vacía ≠ "0" en el ALTA (D10) ────
-- Partido del cuerpo VIVO de prod (hash arriba, ya post productos-categoria-
-- text-retiro — la columna category ya no es física en products, se resuelve
-- por category_id). ÚNICO cambio real: rama INSERT, línea `cost`, se retira
-- el `COALESCE(..., 0)`. La rama UPDATE (COALESCE(..., cost)) se conserva
-- BYTE A BYTE: la celda vacía sobre un producto existente conserva, no borra
-- (mismo tri-estado que sku/category_id). Firma sin cambios -> CREATE OR REPLACE.
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
          -- productos-costo-nullable (D10): celda vacía en la EDICIÓN
          -- conserva el costo que el producto tenía — no lo borra. Es la
          -- misma convención tri-estado-por-ausencia que sku/category_id.
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

-- ── Paso 6 (OQ-2 = a): rpc_dashboard_kpi_summary suma la columna de disclosure
-- Cambia el RETURNS TABLE (columna nueva) -> DROP + CREATE, re-GRANT en el
-- mismo archivo. La aritmética del total NO cambia (D13): un producto sin
-- costo sigue aportando 0, exactamente como uno con cost=0 hoy. Lo que se
-- agrega es la DECLARACIÓN de cuántos quedaron sin valorizar.
DROP FUNCTION IF EXISTS public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid);

CREATE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(net_profit numeric, prev_net_profit numeric, avg_ticket numeric, prev_avg_ticket numeric, cost_per_sale numeric, prev_cost_per_sale numeric, stagnant_stock_value numeric, stagnant_stock_count integer, stagnant_stock_without_cost_count integer, prev_stagnant_stock_value numeric, prev_stagnant_stock_count integer, sales_count integer, prev_sales_count integer, invoiced_revenue numeric, prev_invoiced_revenue numeric, collected_revenue numeric, prev_collected_revenue numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P0400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      -- v3-snapshot-pattern (D6): COGS = snapshot congelado (via sale_items),
      -- fallback a pr.cost actual solo si la línea no tiene snapshot.
      -- productos-costo-nullable: pr.cost puede ser NULL — el COALESCE final
      -- a 0 es el KPI de rentabilidad agregada de la cuenta (no un ranking
      -- por producto), donde un costo ausente sigue sin poder inventarse
      -- pero tampoco puede dejar el KPI entero en NULL.
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D1, grupo 6): la regla de NC —incluida la
  -- atribución de sucursal— vive en el helper único (D5) consumido también
  -- por get_dashboard_financials. p_branch_id ahora SÍ filtra (helper
  -- reescrito en esta migración).
  nc_agg AS (
    SELECT
      public.reporting_credit_notes_in_window(v_account_id, p_from,      p_to,      p_branch_id) AS nc,
      public.reporting_credit_notes_in_window(v_account_id, p_prev_from, p_prev_to, p_branch_id) AS prev_nc
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cargos a cuenta corriente del período. SIGUEN sin filtrar por sucursal
  -- (nivel cuenta) — no son la causa de collected_revenue = NULL bajo
  -- filtro, pero tampoco se filtran: ver el CASE del SELECT final.
  charges_agg AS (
    SELECT
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_from      AND p_to),      0) AS charges,
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_charges
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'sale'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cobros del período. payments_received no tiene sucursal atribuible
  -- (reference_sale_id opcional y en la práctica NULL) — no filtrable.
  payments_agg AS (
    SELECT
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_from      AND p_to),      0) AS payments,
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_payments
    FROM public.payments_received pr_
    WHERE pr_.account_id = v_account_id
      AND pr_.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D3, grupo 5): stock sin rotación por sucursal
  -- sobre branch_stock. productos-costo-nullable (OQ-2=a, D13): la
  -- aritmética NO cambia — un producto sin costo sigue aportando 0 al total
  -- (idéntico a un cost=0 de hoy) — lo que se agrega es CUÁNTOS de los
  -- productos sin rotación no tienen costo, para que el total sea auditable.
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0)                    AS value,
      COUNT(DISTINCT bs.product_id)::integer                                 AS cnt,
      COUNT(DISTINCT bs.product_id) FILTER (WHERE p.cost IS NULL)::integer   AS without_cost_cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_from AND p_to
          -- kpi-branch-consistency (D4): fail-open sobre ventas legacy sin
          -- sucursal. 75% de las filas de `sales` en producción tienen
          -- branch_id NULL (medido 2026-08-11) — una venta legacy es
          -- evidencia REAL de rotación y no se puede duplicar (EXISTS, no
          -- SUM); fail-closed marcaría como "sin rotación" a casi todo el
          -- catálogo apenas se selecciona una sucursal.
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  )
  SELECT
    (sa.revenue - na.nc)      - (ea.expenses      + pa.purchases)       AS net_profit,
    (sa.prev_revenue - na.prev_nc) - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sc.without_cost_cnt                                       AS stagnant_stock_without_cost_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count,
    -- v3-reporting-invariants (RN-D3): devengado neto de NC, filtrado por
    -- sucursal (el helper ya atribuye — D1, grupo 6).
    (sa.revenue - na.nc)                                      AS invoiced_revenue,
    (sa.prev_revenue - na.prev_nc)                            AS prev_invoiced_revenue,
    -- kpi-branch-consistency (D2, grupo 6): collected_revenue no es
    -- computable por sucursal — payments_received no tiene branch_id
    -- atribuible (reference_sale_id opcional y en la práctica NULL), y
    -- percibido = devengado - cargos + cobros es una identidad cuyos tres
    -- términos deben vivir en el mismo universo. Bajo filtro de sucursal se
    -- declara NULL (requirement de filtro uniforme, reporting-invariants)
    -- en vez de mezclar un devengado filtrado con cargos/cobros de toda la
    -- cuenta. Sin filtro, comportamiento sin cambios.
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.revenue - na.nc) - ca.charges + pay.payments
    END                                                        AS collected_revenue,
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.prev_revenue - na.prev_nc) - ca.prev_charges + pay.prev_payments
    END                                                        AS prev_collected_revenue
  FROM sales_agg sa
  CROSS JOIN nc_agg        na
  CROSS JOIN charges_agg   ca
  CROSS JOIN payments_agg  pay
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) TO authenticated, service_role;
