-- =============================================================================
-- CHANGE: estadisticas-ventas — Etapa E3 (grupo 9 de tasks.md)
-- Detalle por producto del módulo de estadísticas: rpc_product_sales_evolution
-- (evolución de UN producto por día / semana ISO / mes, agrupando sus
-- variantes bajo el padre con desglose por miembro — D12: la pantalla vive en
-- /estadisticas/productos/[id]). Consume el helper canónico
-- reporting_sales_lines_in_window y el clamp reporting_plan_window de E1
-- (20261024000001). Sin DDL sobre tablas, sin índices nuevos: el par
-- (account_id, date) ya está cubierto por idx_sales_account_date y el
-- filtro por producto recorta sobre esa población.
--
-- Los otros dos entregables de E3 no tocan la base: el export del ranking
-- lee rpc_product_ranking tal como está (generate-export), y ai-estadisticas
-- lee rpc_sales_evolution / rpc_product_ranking / rpc_sales_breakdown /
-- rpc_sales_top_clients con el JWT del usuario (Edge Function, DEC-15).
--
-- SÓLO LECTURA: esta función no inserta, actualiza ni borra una fila.
--
-- ── Checkpoints de verdad viva (2026-09-04, prod gxdhpxvdjjkmxhdkkwyb) ──────
--   · MAX(version) de supabase_migrations.schema_migrations = 20261025000001
--     (274 migraciones): E1 y E2 desplegadas, este archivo las sigue.
--   · reporting_sales_lines_in_window(uuid,date,date,uuid,text) y
--     reporting_plan_window(uuid,date,date): vivas, STABLE, sin EXECUTE para
--     anon/authenticated (se llaman desde SECURITY DEFINER).
--   · rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,
--     integer): viva; agrupa por products.parent_id cuando p_group_variants —
--     este detalle usa EXACTAMENTE la misma regla de grupo (el padre + los
--     productos cuyo parent_id es el padre), para que el total del detalle
--     sea idéntico a la fila del ranking (gate de identidad).
--   · products: id, account_id, name, sku, category, parent_id, deleted_at.
--     La tenencia se resuelve por account_id; deleted_at NO filtra — un
--     producto dado de baja que vendió en el período rankea (E1 no lo
--     filtra) y por lo tanto su detalle tiene que abrir.
--
-- ── Decisiones aplicadas (design.md) ────────────────────────────────────────
--   D1  Sobre el helper canónico; una RPC por forma de salida: tres clases
--       de fila (row_kind = total / bucket / member) para no re-agregar en
--       ningún consumidor. D3 bucketing por la fecha de negocio casteada,
--       NUNCA AT TIME ZONE — y como el detalle no deriva ninguna hora, el
--       gate de introspección prohíbe CUALQUIER AT TIME ZONE en el cuerpo.
--       D4 semana ISO (date_trunc('week') arranca el lunes). D7 no resta NC
--       (una NC no tiene producto atribuible; la UI lo declara). D8 clamp
--       de historial dentro del read-model, ventana declarada por fila.
--       D11 margen por cascada RN-D2 del helper + cobertura de snapshot;
--       margen NULL (nunca 0) cuando no hay líneas. D12 la ruta del detalle.
--
-- ── Desvíos respecto del design, declarados ─────────────────────────────────
--   · `p_account_id` como primer parámetro con guard de membresía P0401
--     (mismo molde que E1/E2: la consume el backend FastAPI) y `p_branch_id`
--     / `p_canal` para que el detalle respete el mismo filtro que llevó a él.
--   · El grupo incluye las ventas DIRECTAS del padre como miembro propio
--     (misma regla que el ranking agrupado); variant_count cuenta sólo las
--     variantes con ventas, nunca al padre. Una variante pedida directamente
--     muestra sólo lo suyo (no tiene hijos) con parent_id/parent_name de
--     contexto, idéntica a su fila del ranking sin agrupar.
--   · Producto ajeno o inexistente → P0404 con el mismo mensaje (no se
--     revela si existe); el backend lo traduce a 404 RFC 7807.
--   · Producto sin ventas en el período → fila total en cero con la
--     cabecera, buckets en cero, sin miembros: nunca un error ni un vacío.
--
-- Idempotente: CREATE OR REPLACE (firma nueva, sin overloads que dejar
-- vivos), REVOKE/GRANT re-ejecutables. Rollback: DROP de la función (nada
-- más la consume).
-- =============================================================================


-- =============================================================================
-- 1. rpc_product_sales_evolution — evolución de un producto (y su grupo)
--    Filas:
--      row_kind='total'  : totales del grupo en la ventana aplicada, con la
--                          cabecera del producto pedido (nombre, sku,
--                          categoría, padre) — is_group / variant_count.
--      row_kind='bucket' : una por intervalo de la ventana (rellena en cero).
--      row_kind='member' : una por producto del grupo CON ventas (variantes
--                          y el padre si vendió directo), rank por importe.
--    La cabecera y la ventana viajan en todas las filas (como window_* en
--    E1/E2) para que ningún consumidor tenga que cruzar filas.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_sales_evolution(
  p_account_id uuid,
  p_product_id uuid,
  p_start      date,
  p_end        date,
  p_bucket     text DEFAULT 'day',
  p_branch_id  uuid DEFAULT NULL,
  p_canal      text DEFAULT NULL
)
RETURNS TABLE(
  row_kind          text,
  rank              integer,
  product_id        uuid,
  product_name      text,
  product_sku       text,
  product_category  text,
  parent_id         uuid,
  parent_name       text,
  is_group          boolean,
  variant_count     integer,
  bucket_start      date,
  bucket_end        date,
  variant_id        uuid,
  variant_name      text,
  variant_sku       text,
  units             numeric,
  revenue           numeric,
  operations        bigint,
  total_cost        numeric,
  gross_margin      numeric,
  gross_margin_pct  numeric,
  cost_coverage_pct numeric,
  last_sale_date    date,
  window_start      date,
  window_end        date,
  history_days      integer,
  window_clamped    boolean
)
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
  SELECT pr.id, pr.name, pr.sku, pr.category, pr.parent_id, pp.name AS parent_name
    INTO v_head
  FROM public.products pr
  LEFT JOIN public.products pp ON pp.id = pr.parent_id AND pp.account_id = p_account_id
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

COMMENT ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) IS
  'estadisticas-ventas E3 (D12): evolución de un producto y su grupo de variantes por día/semana ISO/mes (fecha de negocio casteada, sin AT TIME ZONE) — filas total / bucket / member sobre el helper canónico, misma regla de grupo que rpc_product_ranking, margen RN-D2 con cobertura, sin restar NC. Tenencia por account_id (P0404 ajeno o inexistente). Clamp de historial por plan aplicado y declarado. Guard P0401.';

REVOKE ALL     ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_sales_evolution(uuid, uuid, date, date, text, uuid, text) TO service_role;


-- =============================================================================
-- 2. Export del ranking (grupo 8): el 6º ExportType también en la base.
--    La lista de tipos de exportación estaba TRES veces: la unión y el array de
--    generate-export (unificados en _shared/export-ranking.ts) y este CHECK de
--    20260610000000. Sin ampliarlo, el archivo se genera y la cuota se cobra
--    pero el INSERT en export_logs falla ("non-fatal" en la Edge Function) y
--    el historial de /exportaciones nunca lista el ranking — hallazgo del run
--    real del apply (2026-09-04, stack local). Definición viva en prod
--    verificada idéntica a la local: los 5 literales de 20260610000000.
--    DROP IF EXISTS + ADD: idempotente y sin dejar dos CHECKs con el mismo
--    nombre.
-- =============================================================================
ALTER TABLE public.export_logs DROP CONSTRAINT IF EXISTS export_logs_type_values;
ALTER TABLE public.export_logs ADD CONSTRAINT export_logs_type_values CHECK (
  export_type IN ('sales_csv', 'purchases_csv', 'expenses_csv', 'stock_csv', 'full_report_xlsx', 'product_ranking_csv')
);


-- =============================================================================
-- 3. Gate de introspección — aborta la migración si algo quedó a medias
-- =============================================================================
DO $$
DECLARE
  v_sig text := 'public.rpc_product_sales_evolution(uuid,uuid,date,date,text,uuid,text)';
  v_def text;
  v_chk text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_chk
  FROM pg_constraint WHERE conrelid = 'public.export_logs'::regclass AND conname = 'export_logs_type_values';
  IF v_chk IS NULL OR v_chk !~ 'product_ranking_csv' OR v_chk !~ 'full_report_xlsx' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: export_logs_type_values debe admitir los 5 tipos legacy + product_ranking_csv (def: %).', COALESCE(v_chk, 'NULL');
  END IF;
  IF to_regprocedure(v_sig) IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no existe tras la migración.', v_sig;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_product_sales_evolution'
        AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_product_sales_evolution tiene más de una definición (overload vivo).';
  END IF;
  v_def := pg_get_functiondef(to_regprocedure(v_sig));
  IF v_def !~ 'reporting_sales_lines_in_window' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no consume el helper canónico (D1).', v_sig;
  END IF;
  IF v_def !~ 'reporting_plan_window' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no aplica reporting_plan_window (D8).', v_sig;
  END IF;
  -- El detalle no deriva ninguna hora: NINGÚN AT TIME ZONE admitido (D3).
  IF v_def ~* 'AT\s+TIME\s+ZONE' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % aplica AT TIME ZONE y el detalle no deriva ninguna hora (D3).', v_sig;
  END IF;
  IF v_def !~ 'P0404' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no rechaza el producto ajeno con P0404.', v_sig;
  END IF;
  IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: anon no debe ejecutar %.', v_sig;
  END IF;
  IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: authenticated debe ejecutar %.', v_sig;
  END IF;

  RAISE NOTICE 'estadisticas-ventas E3: rpc_product_sales_evolution (total / bucket / member) sobre el helper canónico y el clamp OK.';
END $$;
