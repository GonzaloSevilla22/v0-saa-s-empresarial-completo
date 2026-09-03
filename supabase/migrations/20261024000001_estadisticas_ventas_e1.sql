-- =============================================================================
-- CHANGE: estadisticas-ventas — Etapa E1 (grupo 2 de tasks.md)
-- Read-models del módulo de estadísticas de ventas: helper canónico de líneas
-- del período, clamp de historial por plan, evolución temporal con comparación
-- de período y ranking de productos; de-duplicación de rpc_product_profitability
-- sobre el helper (firma y columnas intactas) + fix del off-by-one de
-- last_sale_date (OQ-3); índice (account_id, date DESC) sobre sales (D10).
--
-- SÓLO LECTURA: ninguna función de este archivo inserta, actualiza ni borra
-- una fila de negocio. Sin DDL sobre tablas salvo el índice.
--
-- ── Checkpoints de verdad viva (2026-09-03, prod gxdhpxvdjjkmxhdkkwyb) ──────
--   · rpc_product_profitability(integer): UNA definición en pg_proc;
--     md5(pg_get_functiondef) = 0b125c91cec686008ccd8edd3ae52d18 (idéntico al
--     cuerpo de 20261016000001 §2 módulo CRLF del checkout local);
--     proacl = {postgres=X, authenticated=X, service_role=X} — sin anon, sin
--     PUBLIC. La reescritura de abajo parte de ESE cuerpo capturado.
--   · Defecto de last_sale_date medido: 218/218 productos con última venta
--     corrida un día ((MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')
--     ::date sobre una columna que guarda la fecha de negocio a 00:00 UTC).
--   · sales.date sin hora: 643 líneas en 90 días, 0 con hora, 1 hora distinta.
--   · plan_limits.history_days: gratis 30 / inicial 365 / avanzado 730 / pro 1825.
--   · get_effective_plan(uuid): STABLE SECURITY DEFINER, sin EXECUTE para
--     authenticated — se invoca desde dentro de funciones SECURITY DEFINER
--     (precedente 20260817000001).
--   · reporting_credit_notes_in_window(uuid,timestamptz,timestamptz,uuid):
--     STABLE, sin EXECUTE para anon/authenticated — ídem.
--   · Índice (account_id, date): NO existía (14 índices vivos; el más cercano,
--     idx_sales_account_client_date, es parcial WHERE client_id IS NOT NULL).
--
-- ── Decisiones aplicadas (design.md) ────────────────────────────────────────
--   D1  Un helper compartido (reporting_sales_lines_in_window) + una RPC por
--       FORMA de salida. D2 rpc_product_profitability consume el helper sin
--       cambiar firma. D3 fecha de negocio por casteo directo (::date), NUNCA
--       AT TIME ZONE; ventana >= p_start / < p_end + 1. D4 semana ISO (lunes).
--       D6 líneas de servicio dentro de la facturación, fuera del ranking, con
--       su importe declarado (service_revenue). D7 la evolución resta NC vía
--       reporting_credit_notes_in_window (misma regla que el Tablero); el
--       ranking no puede y no lo hace. D8 clamp de historial DENTRO del
--       read-model (reporting_plan_window → get_effective_plan →
--       plan_limits.history_days), recorta y devuelve la ventana aplicada,
--       fail-closed al plan más restrictivo. D10 índice sin CONCURRENTLY.
--       D11 margen por cascada snapshot→products.cost + cobertura de snapshot.
--
-- ── Desvíos respecto del design, declarados ─────────────────────────────────
--   · Las dos RPCs nuevas toman `p_account_id` como primer parámetro con guard
--     de membresía P0401 (molde 20261021000001 rpc_receivables_report), porque
--     las consume el backend FastAPI que ya resuelve la cuenta (get_account_id).
--   · El clamp se extrae a un helper propio (reporting_plan_window): lo consumen
--     las dos RPCs de E1 y lo consumirán las tres de E2/E3 — un solo lugar.
--   · rpc_sales_evolution devuelve además una fila period='current' (totales
--     del período) para que ningún consumidor re-agregue los buckets, y
--     bucket_end por fila. La fila 'previous' NO se recorta por plan: es un
--     agregado de comparación, igual que prev_invoiced_revenue del Tablero.
--   · Bajo filtro de canal la evolución NO resta NC (una NC no tiene canal
--     atribuible; fail-closed, misma excepción declarada para los desgloses).
--   · El helper acepta p_end NULL = sin borde superior, para que
--     rpc_product_profitability conserve exactamente su ventana abierta.
--
-- Idempotente: CREATE OR REPLACE (ninguna firma preexistente cambia — no hay
-- overloads que dejar vivos), CREATE INDEX IF NOT EXISTS, REVOKE/GRANT
-- re-ejecutables. Rollback: DROP de las 4 funciones nuevas (nada más las
-- consume), restaurar rpc_product_profitability desde el cuerpo capturado
-- (md5 arriba), DROP INDEX idx_sales_account_date.
-- =============================================================================


-- =============================================================================
-- 1. Helper canónico: "línea de venta del período" (D1, RN-D)
--    Resuelve UNA vez: revenue de línea COALESCE(total, amount), bordes RN-D5,
--    filtro de cuenta, filtros opcionales de sucursal/canal, fecha de negocio
--    por casteo directo, clave de operación COALESCE(operation_id, id) y la
--    cascada canónica de costo (snapshot de línea → products.cost, RN-D2).
--    STABLE, SECURITY INVOKER: sólo lo llaman funciones SECURITY DEFINER; toma
--    p_account_id, así que NO se expone a anon/authenticated (mismas ACLs que
--    reporting_credit_notes_in_window). Inlinable (sin SET) para que el
--    planner vea idx_sales_account_date desde las RPCs (task 2.13: con 60k
--    filas sintéticas elige el índice compuesto — 836 entradas / 549 bloques —
--    contra 20.000 entradas / 985 bloques con el índice de cuenta solo).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.reporting_sales_lines_in_window(
  p_account_id uuid,
  p_start      date,
  p_end        date,
  p_branch_id  uuid DEFAULT NULL,
  p_canal      text DEFAULT NULL
)
RETURNS TABLE(
  sale_id           uuid,
  operation_key     uuid,
  product_id        uuid,
  client_id         uuid,
  branch_id         uuid,
  canal             text,
  business_date     date,
  created_at        timestamptz,
  quantity          numeric,
  line_revenue      numeric,
  unit_cost         numeric,
  has_cost_snapshot boolean
)
LANGUAGE sql
STABLE
-- Sin SET search_path a propósito: una función SQL con SET no se inlinea y el
-- planner de la RPC que la envuelve queda ciego a idx_sales_account_date
-- (medido: Function Scan opaco vs Bitmap Index Scan al inlinear). Todos los
-- nombres del cuerpo van calificados con `public.`, así que el search_path de
-- la sesión no puede desviar ninguna referencia.
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
    -- actual sólo cuando la línea no tiene snapshot.
    COALESCE(si.unit_cost_snapshot, pr.cost),
    (si.unit_cost_snapshot IS NOT NULL)
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

COMMENT ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) IS
  'estadisticas-ventas D1: población canónica de líneas de venta del período (revenue COALESCE(total,amount), bordes RN-D5, fecha de negocio por casteo directo, cascada de costo RN-D2). Consumida por rpc_sales_evolution, rpc_product_ranking y rpc_product_profitability. No exponer a authenticated: toma p_account_id.';

REVOKE ALL     ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reporting_sales_lines_in_window(uuid, date, date, uuid, text) TO service_role;


-- =============================================================================
-- 2. Clamp de historial por plan (D8, plan-gating "enforceable en el servidor")
--    Resuelve el plan efectivo CONTRA LA BASE (get_effective_plan: fail-closed
--    a 'gratis' ante cuenta inexistente o plan no reconocido), lee
--    plan_limits.history_days, recorta el inicio del rango a
--    reporting_local_today() - history_days y devuelve la ventana aplicada.
--    Recorta, no rechaza. Un rango enteramente anterior al historial queda
--    como ventana vacía del primer día permitido (nunca datos fuera del plan).
--    P0400 si el rango es nulo o invertido.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.reporting_plan_window(
  p_account_id uuid,
  p_start      date,
  p_end        date
)
RETURNS TABLE(
  window_start   date,
  window_end     date,
  history_days   integer,
  window_clamped boolean,
  plan           text
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_plan      text;
  v_history   integer;
  v_today     date;
  v_min_start date;
  v_start     date;
  v_end       date;
BEGIN
  IF p_start IS NULL OR p_end IS NULL OR p_start > p_end THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P0400';
  END IF;

  -- Definición normativa única del plan efectivo — nunca el claim del token
  -- (backend/core/auth.py cae a "pro" sin claim y el hook no está activo).
  v_plan := public.get_effective_plan(p_account_id);

  SELECT pl.history_days INTO v_history
  FROM public.plan_limits pl
  WHERE pl.plan = v_plan;

  -- Fail-closed: plan sin fila en plan_limits → el historial más restrictivo.
  IF v_history IS NULL THEN
    SELECT MIN(pl.history_days) INTO v_history FROM public.plan_limits pl;
  END IF;
  v_history := COALESCE(v_history, 30);

  -- RN-D5: "hoy" es el día calendario del tenant, no CURRENT_DATE UTC.
  v_today     := public.reporting_local_today();
  v_min_start := v_today - v_history;
  v_start     := GREATEST(p_start, v_min_start);
  v_end       := GREATEST(p_end, v_start);

  RETURN QUERY
  SELECT v_start, v_end, v_history, (v_start <> p_start OR v_end <> p_end), v_plan;
END;
$function$;

COMMENT ON FUNCTION public.reporting_plan_window(uuid, date, date) IS
  'estadisticas-ventas D8: recorta un rango al historial del plan efectivo de la cuenta (get_effective_plan → plan_limits.history_days, anclado a reporting_local_today) y devuelve la ventana aplicada. Fail-closed. No exponer a authenticated: toma p_account_id.';

REVOKE ALL     ON FUNCTION public.reporting_plan_window(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reporting_plan_window(uuid, date, date) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reporting_plan_window(uuid, date, date) TO service_role;


-- =============================================================================
-- 3. rpc_sales_evolution — evolución por día / semana / mes con comparación
--    Filas:
--      period='bucket'   : una por intervalo de la ventana aplicada (rellena
--                          en cero), con NC del intervalo y neto.
--      period='current'  : totales de la ventana aplicada (NC calculada UNA
--                          vez sobre toda la ventana — idéntica al Tablero).
--      period='previous' : totales del período inmediatamente anterior de
--                          igual longitud (sin recorte de plan: es un agregado
--                          de comparación, como prev_invoiced_revenue).
--    Semana ISO (date_trunc('week') arranca el lunes). Bucketing sobre la
--    fecha de negocio casteada (D3). operations = COUNT(DISTINCT
--    COALESCE(operation_id, id)) vía operation_key del helper.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_sales_evolution(
  p_account_id uuid,
  p_start      date,
  p_end        date,
  p_bucket     text DEFAULT 'day',
  p_branch_id  uuid DEFAULT NULL,
  p_canal      text DEFAULT NULL
)
RETURNS TABLE(
  period          text,
  bucket_start    date,
  bucket_end      date,
  revenue         numeric,
  credit_notes    numeric,
  net_revenue     numeric,
  units           numeric,
  operations      bigint,
  service_revenue numeric,
  window_start    date,
  window_end      date,
  history_days    integer,
  window_clamped  boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_w          record;
  v_step       interval;
  v_len        integer;
  v_prev_start date;
  v_prev_end   date;
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

  -- D8: clamp de historial (valida el rango, P0400 si está invertido).
  SELECT * INTO v_w FROM public.reporting_plan_window(p_account_id, p_start, p_end);

  v_step := CASE p_bucket
              WHEN 'day'  THEN interval '1 day'
              WHEN 'week' THEN interval '1 week'
              ELSE             interval '1 month'
            END;
  v_len        := v_w.window_end - v_w.window_start + 1;
  v_prev_end   := v_w.window_start - 1;
  v_prev_start := v_prev_end - v_len + 1;

  RETURN QUERY
  WITH lines AS (
    SELECT l.*,
           date_trunc(p_bucket, l.business_date::timestamp)::date AS b
    FROM public.reporting_sales_lines_in_window(
           p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
  ),
  buckets AS (
    SELECT gs::date AS b,
           GREATEST(gs::date, v_w.window_start)                          AS b_from,
           LEAST((gs + v_step)::date - 1, v_w.window_end)                 AS b_to
    FROM generate_series(
           date_trunc(p_bucket, v_w.window_start::timestamp),
           date_trunc(p_bucket, v_w.window_end::timestamp),
           v_step) AS gs
  ),
  bucket_agg AS (
    SELECT b.b, b.b_from, b.b_to,
           COALESCE(SUM(l.line_revenue), 0)                                        AS revenue,
           COALESCE(SUM(l.quantity), 0)                                            AS units,
           COUNT(DISTINCT l.operation_key)                                         AS ops,
           COALESCE(SUM(l.line_revenue) FILTER (WHERE l.product_id IS NULL), 0)    AS service_revenue
    FROM buckets b
    LEFT JOIN lines l ON l.b = b.b
    GROUP BY b.b, b.b_from, b.b_to
  ),
  bucket_rows AS (
    SELECT
      ba.b, ba.b_from, ba.b_to, ba.revenue, ba.units, ba.ops, ba.service_revenue,
      -- D7: NC por el helper compartido del Tablero, sobre los instantes del
      -- intervalo [b_from 00:00Z, b_to+1 00:00Z - 1µs]. Bajo filtro de canal
      -- no se resta (una NC no tiene canal atribuible — fail-closed).
      CASE WHEN p_canal IS NULL THEN
        public.reporting_credit_notes_in_window(
          p_account_id,
          ba.b_from::timestamptz,
          (ba.b_to + 1)::timestamptz - interval '1 microsecond',
          p_branch_id)
      ELSE 0 END AS credit_notes
    FROM bucket_agg ba
  ),
  current_total AS (
    SELECT
      COALESCE(SUM(l.line_revenue), 0)                                        AS revenue,
      COALESCE(SUM(l.quantity), 0)                                            AS units,
      COUNT(DISTINCT l.operation_key)                                         AS ops,
      COALESCE(SUM(l.line_revenue) FILTER (WHERE l.product_id IS NULL), 0)    AS service_revenue,
      CASE WHEN p_canal IS NULL THEN
        public.reporting_credit_notes_in_window(
          p_account_id,
          v_w.window_start::timestamptz,
          (v_w.window_end + 1)::timestamptz - interval '1 microsecond',
          p_branch_id)
      ELSE 0 END AS credit_notes
    FROM lines l
  ),
  previous_total AS (
    SELECT
      COALESCE(SUM(l.line_revenue), 0)                                        AS revenue,
      COALESCE(SUM(l.quantity), 0)                                            AS units,
      COUNT(DISTINCT l.operation_key)                                         AS ops,
      COALESCE(SUM(l.line_revenue) FILTER (WHERE l.product_id IS NULL), 0)    AS service_revenue,
      CASE WHEN p_canal IS NULL THEN
        public.reporting_credit_notes_in_window(
          p_account_id,
          v_prev_start::timestamptz,
          (v_prev_end + 1)::timestamptz - interval '1 microsecond',
          p_branch_id)
      ELSE 0 END AS credit_notes
    FROM public.reporting_sales_lines_in_window(
           p_account_id, v_prev_start, v_prev_end, p_branch_id, p_canal) l
  ),
  out_rows AS (
    SELECT 0 AS ord, br.b AS sort_key, 'bucket'::text AS period, br.b AS bucket_start, br.b_to AS bucket_end,
           br.revenue, br.credit_notes, br.revenue - br.credit_notes AS net_revenue,
           br.units, br.ops, br.service_revenue
    FROM bucket_rows br
    UNION ALL
    SELECT 1, v_w.window_start, 'current', v_w.window_start, v_w.window_end,
           ct.revenue, ct.credit_notes, ct.revenue - ct.credit_notes,
           ct.units, ct.ops, ct.service_revenue
    FROM current_total ct
    UNION ALL
    SELECT 2, v_prev_start, 'previous', v_prev_start, v_prev_end,
           pt.revenue, pt.credit_notes, pt.revenue - pt.credit_notes,
           pt.units, pt.ops, pt.service_revenue
    FROM previous_total pt
  )
  SELECT o.period, o.bucket_start, o.bucket_end,
         o.revenue, o.credit_notes, o.net_revenue, o.units, o.ops, o.service_revenue,
         v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
  FROM out_rows o
  ORDER BY o.ord, o.sort_key;
END;
$function$;

COMMENT ON FUNCTION public.rpc_sales_evolution(uuid, date, date, text, uuid, text) IS
  'estadisticas-ventas E1: evolución de ventas por día/semana/mes (fecha de negocio, semana ISO) con NC restadas vía reporting_credit_notes_in_window, fila current (totales) y previous (período anterior de igual longitud). Clamp de historial por plan aplicado y declarado (window_*). Guard P0401.';

REVOKE ALL     ON FUNCTION public.rpc_sales_evolution(uuid, date, date, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_sales_evolution(uuid, date, date, text, uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_evolution(uuid, date, date, text, uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_evolution(uuid, date, date, text, uuid, text) TO service_role;


-- =============================================================================
-- 4. rpc_product_ranking — más vendidos por unidades / importe / margen
--    Excluye las líneas de servicio (product_id NULL) — no son productos; su
--    importe lo declara rpc_sales_evolution.service_revenue (D6).
--    p_group_variants: la clave de agrupación es products.parent_id cuando no
--    es NULL, si no el propio producto. Una variante huérfana (padre borrado →
--    ON DELETE SET NULL) agrupa bajo sí misma. variant_count = variantes
--    distintas agregadas bajo la cabecera; is_group = variant_count > 0.
--    Margen: total_cost = SUM(unit_cost × quantity) con la cascada RN-D2 del
--    helper (NULL sólo si ninguna línea resolvió costo — la UI muestra "—");
--    cost_coverage_pct = % de líneas del grupo con snapshot congelado (D11).
--    Orden resuelto sobre el conjunto COMPLETO (ROW_NUMBER) y paginación
--    dentro de la RPC (p_limit/p_offset); total_count viaja por fila.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_ranking(
  p_account_id     uuid,
  p_start          date,
  p_end            date,
  p_order_by       text    DEFAULT 'units',
  p_group_variants boolean DEFAULT true,
  p_branch_id      uuid    DEFAULT NULL,
  p_canal          text    DEFAULT NULL,
  p_limit          integer DEFAULT 50,
  p_offset         integer DEFAULT 0
)
RETURNS TABLE(
  rank              integer,
  product_id        uuid,
  product_name      text,
  sku               text,
  category          text,
  parent_id         uuid,
  parent_name       text,
  is_group          boolean,
  variant_count     integer,
  units             numeric,
  revenue           numeric,
  operations        bigint,
  total_cost        numeric,
  gross_margin      numeric,
  gross_margin_pct  numeric,
  cost_coverage_pct numeric,
  last_sale_date    date,
  total_count       bigint,
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
      hp.category    AS head_category,
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

COMMENT ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) IS
  'estadisticas-ventas E1: ranking de productos del período por unidades/importe/margen, variantes agrupadas bajo el padre (opcional), líneas de servicio excluidas, margen por cascada RN-D2 con cobertura de snapshot, paginado sobre el conjunto completo. Clamp de historial por plan aplicado y declarado. Guard P0401.';

REVOKE ALL     ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_ranking(uuid, date, date, text, boolean, uuid, text, integer, integer) TO service_role;


-- =============================================================================
-- 5. rpc_product_profitability — de-duplicación sobre el helper (D2) + fix
--    del off-by-one de last_sale_date (D3 / OQ-3). FIRMA Y COLUMNAS INTACTAS.
--    Diferencias con el cuerpo vivo capturado (md5 0b125c91…):
--      · la población de líneas (filtro de cuenta, ventana, revenue de línea,
--        cascada de costo) viene del helper canónico, no de un SELECT propio;
--      · last_sale_date = MAX(business_date) — casteo directo de la fecha de
--        negocio, sin AT TIME ZONE (218/218 productos corridos un día en
--        prod). Sigue siendo `date`, así que el 42804 que motivó el cast
--        original no vuelve;
--      · desaparece la columna interna any_missing_snapshot, que se calculaba
--        y nunca se leía.
--    Guards, ventana (>= hoy local - N días, sin borde superior), orden y
--    LIMIT 200: sin cambios.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_profitability(p_period_days integer DEFAULT 30)
 RETURNS TABLE(product_id uuid, product_name text, total_revenue numeric, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, units_sold numeric, last_sale_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        UUID;
  v_account_id UUID;
  v_since_date DATE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Derive the caller's active account (C-05 D7 pattern)
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- v3-reporting-invariants (RN-D5): ancla a la fecha LOCAL del tenant, no a
  -- CURRENT_DATE (UTC del servidor) — evita que la ventana corra un día
  -- antes entre las 21:00 y las 00:00 hora Argentina.
  v_since_date := public.reporting_local_today() - (p_period_days || ' days')::INTERVAL;

  -- estadisticas-ventas (D2): la población de líneas —revenue de línea
  -- COALESCE(total, amount), cascada de costo snapshot→products.cost (RN-D2),
  -- filtro de cuenta y ventana— vive UNA sola vez en el helper canónico que
  -- también consume rpc_product_ranking. p_end NULL conserva la ventana
  -- abierta original (>= v_since_date, sin borde superior).
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        l.product_id,
        SUM(l.line_revenue)             AS total_revenue,
        SUM(l.quantity)                 AS units_sold,
        -- estadisticas-ventas (D3 / OQ-3): fecha de negocio por casteo
        -- directo (ya resuelta en el helper). El AT TIME ZONE anterior corría
        -- la última venta un día atrás para el 100% de los productos.
        MAX(l.business_date)            AS last_sale_date,
        SUM(l.unit_cost * l.quantity)   AS total_cost_snapshot
      FROM   public.reporting_sales_lines_in_window(v_account_id, v_since_date, NULL, NULL, NULL) l
      WHERE  l.product_id IS NOT NULL
      GROUP  BY l.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    sa.total_cost_snapshot                                                    AS total_cost,
    sa.total_revenue - sa.total_cost_snapshot                                 AS gross_margin,
    ROUND(
      (sa.total_revenue - sa.total_cost_snapshot)
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$function$;

-- ACLs = estado vivo capturado (postgres/authenticated/service_role, sin
-- PUBLIC, sin anon). CREATE OR REPLACE las preserva; se reafirman igual.
REVOKE ALL     ON FUNCTION public.rpc_product_profitability(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_profitability(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO service_role;


-- =============================================================================
-- 6. Índice (D10): el par (account_id, date) es el predicado exacto de todos
--    los agregados nuevos y ningún índice vivo lo cubría. Sin CONCURRENTLY:
--    las migraciones corren en transacción y con <1.000 filas el bloqueo es
--    instantáneo.
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_sales_account_date
  ON public.sales (account_id, date DESC);


-- =============================================================================
-- 7. Gate de introspección — aborta la migración si algo quedó a medias
-- =============================================================================
DO $$
DECLARE
  v_def text;
  v_sig text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.reporting_sales_lines_in_window(uuid,date,date,uuid,text)',
    'public.reporting_plan_window(uuid,date,date)',
    'public.rpc_sales_evolution(uuid,date,date,text,uuid,text)',
    'public.rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,integer)',
    'public.rpc_product_profitability(integer)'
  ] LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no existe tras la migración.', v_sig;
    END IF;
  END LOOP;

  FOREACH v_sig IN ARRAY ARRAY[
    'public.rpc_sales_evolution(uuid,date,date,text,uuid,text)',
    'public.rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,integer)',
    'public.rpc_product_profitability(integer)'
  ] LOOP
    v_def := pg_get_functiondef(to_regprocedure(v_sig));
    IF v_def !~ 'reporting_sales_lines_in_window' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no consume el helper canónico (D1/D2).', v_sig;
    END IF;
    IF v_def ~* '\.date\s*\)?\s*AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % aplica AT TIME ZONE sobre la fecha de negocio (D3).', v_sig;
    END IF;
  END LOOP;

  v_def := pg_get_functiondef(to_regprocedure('public.rpc_sales_evolution(uuid,date,date,text,uuid,text)'));
  IF v_def !~ 'reporting_credit_notes_in_window' OR v_def !~ 'reporting_plan_window' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_sales_evolution debe restar NC por reporting_credit_notes_in_window (D7) y aplicar reporting_plan_window (D8).';
  END IF;

  IF has_function_privilege('authenticated', 'public.reporting_sales_lines_in_window(uuid,date,date,uuid,text)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.reporting_plan_window(uuid,date,date)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: los helpers con p_account_id no deben ser ejecutables por authenticated.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'sales' AND indexname = 'idx_sales_account_date') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: idx_sales_account_date no existe.';
  END IF;

  RAISE NOTICE 'estadisticas-ventas E1: helper + clamp + rpc_sales_evolution + rpc_product_ranking + rpc_product_profitability (de-duplicada, last_sale_date corregido) + idx_sales_account_date OK.';
END $$;
