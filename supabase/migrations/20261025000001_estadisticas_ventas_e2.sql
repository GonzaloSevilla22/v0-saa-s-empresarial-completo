-- =============================================================================
-- CHANGE: estadisticas-ventas — Etapa E2 (grupo 5 de tasks.md)
-- Dimensiones del módulo de estadísticas de ventas: rpc_sales_breakdown (una
-- sola RPC para canal / sucursal / día de la semana / horario de carga /
-- categoría — D1: una RPC por FORMA de salida, no por dimensión) y
-- rpc_sales_top_clients (top clientes del período, OQ-2). Las dos consumen el
-- helper canónico reporting_sales_lines_in_window y el clamp
-- reporting_plan_window de E1 (20261024000001). Sin DDL sobre tablas, sin
-- índices nuevos: el par (account_id, date) ya está cubierto por
-- idx_sales_account_date.
--
-- SÓLO LECTURA: ninguna función de este archivo inserta, actualiza ni borra
-- una fila de negocio.
--
-- ── Checkpoints de verdad viva (2026-09-04, prod gxdhpxvdjjkmxhdkkwyb) ──────
--   · MAX(version) de supabase_migrations.schema_migrations = 20261024000001
--     (273 migraciones): E1 desplegada, este archivo la sigue.
--   · reporting_sales_lines_in_window(uuid,date,date,uuid,text) y
--     reporting_plan_window(uuid,date,date): vivas, STABLE, sin EXECUTE para
--     anon/authenticated (se llaman desde SECURITY DEFINER).
--   · reporting_local_today(): `(now() AT TIME ZONE 'America/Argentina/Mendoza')
--     ::date` — la misma zona se usa acá para la hora de carga (D5).
--   · Últimos 90 días: 642 líneas; sin cliente 228 (36%), sin sucursal 418
--     (65%), sin canal 340 (53%); canales vivos: local / otro / instagram /
--     mercadolibre / whatsapp; created_at con 17 horas locales distintas
--     (la fecha de negocio sigue sin hora — OQ-1 no cambió de respuesta).
--   · product_categories(id, account_id, name, is_active, sort_order,
--     deleted_at, …) + products.category_id FK vivos (productos-categorias-sku,
--     20261023000001): 0 productos vivos sin category_id, 0 variantes sin
--     categoría cuyo padre sí la tenga → se agrupa por el category_id propio
--     del producto vendido, sin herencia del padre.
--   · 0 ventas con client_id de otra cuenta y 0 con client_id/branch_id
--     colgados: el guard de tenencia de abajo es defensa en profundidad, no
--     reparación.
--
-- ── Decisiones aplicadas (design.md) ────────────────────────────────────────
--   D1  Un helper + una RPC por forma de salida: rpc_sales_breakdown devuelve
--       (bucket_key, bucket_label, sort_order, revenue, units, operations,
--       window_*) para las cinco dimensiones. D3 día de la semana desde la
--       fecha de negocio casteada (isodow sobre business_date del helper),
--       NUNCA con conversión de zona. D5 la hora viaja cruda (0-23) desde
--       created_at convertido a Mendoza; la franja la arma la UI. D6 líneas de
--       servicio: dentro de canal / sucursal / día / hora / top clientes
--       (son facturación), fuera de categoría (no son productos) — la
--       evolución ya declara su importe (service_revenue). D7 ningún desglose
--       resta NC (una NC no tiene canal, sucursal, hora ni cliente
--       atribuible): la identidad es suma de tramos = revenue BRUTO de la
--       evolución. D8 clamp de historial en el read-model, ventana declarada
--       por fila. OQ-1 horario de CARGA (created_at), rotulado así en la UI.
--       OQ-2 top clientes excluye las ventas sin cliente y las devuelve
--       aparte en una fila propia.
--
-- ── Desvíos respecto del design, declarados ─────────────────────────────────
--   · `p_account_id` como primer parámetro con guard de membresía P0401
--     (mismo molde que E1: las consume el backend FastAPI).
--   · 'category' es la 5ª dimensión del breakdown, no una vista del ranking:
--     comparte exactamente la forma de salida (D1 traza la línea por forma),
--     agrupa por products.category_id y toma el nombre del catálogo (D15 —
--     productos-categorias-sku ya aterrizó); los productos sin categoría van
--     al tramo "Sin categoría". El ranking de E1 sigue devolviendo `category`
--     por fila, sin cambios.
--   · `sort_order` viaja como columna: por importe descendente en canal /
--     sucursal / categoría (el tramo "Sin …" cae donde su importe lo pone —
--     en prod es el mayor, y esconderlo al final sería mentir por acomodo);
--     isodow (1..7) y hora (0..23) en las temporales. Día y hora viajan
--     SIEMPRE completos (7 y 24 filas, en cero las vacías), como los buckets
--     de la evolución.
--   · rpc_sales_top_clients devuelve dos clases de fila (row_kind = 'client' /
--     'unassigned', molde de `period` en rpc_sales_evolution): el importe sin
--     cliente viaja aunque no haya ningún cliente identificado, y p_limit
--     acota sólo las filas de cliente. total_clients viaja por fila.
--   · Tenencia del cliente: el nombre se resuelve con LEFT JOIN a clients
--     scopeado por account_id; una venta de esta cuenta cuyo client_id sea
--     de OTRA cuenta rankea por su importe (la venta es real) pero con
--     client_id NULL y nombre "Cliente no disponible" — nunca expone datos
--     ajenos. Ídem sucursal / categoría ("… no disponible").
--
-- Idempotente: CREATE OR REPLACE (firmas nuevas, sin overloads que dejar
-- vivos), REVOKE/GRANT re-ejecutables. Rollback: DROP de las 2 funciones
-- (nada más las consume).
-- =============================================================================


-- =============================================================================
-- 1. rpc_sales_breakdown — facturación, unidades y operaciones del período por
--    canal / sucursal / día de la semana / hora de carga / categoría.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_sales_breakdown(
  p_account_id uuid,
  p_start      date,
  p_end        date,
  p_dimension  text DEFAULT 'canal',
  p_branch_id  uuid DEFAULT NULL,
  p_canal      text DEFAULT NULL
)
RETURNS TABLE(
  bucket_key     text,
  bucket_label   text,
  sort_order     integer,
  revenue        numeric,
  units          numeric,
  operations     bigint,
  window_start   date,
  window_end     date,
  history_days   integer,
  window_clamped boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_w record;
BEGIN
  -- Guard de membresía: primera sentencia, antes de leer dato alguno.
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members am
    WHERE am.account_id = p_account_id AND am.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_dimension IS NULL OR p_dimension NOT IN ('canal', 'branch', 'weekday', 'hour', 'category') THEN
    RAISE EXCEPTION 'Invalid dimension: %', COALESCE(p_dimension, 'NULL') USING ERRCODE = 'P0400';
  END IF;

  -- D8: clamp de historial (valida el rango, P0400 si está invertido).
  SELECT * INTO v_w FROM public.reporting_plan_window(p_account_id, p_start, p_end);

  -- Toda la población de líneas viene del helper canónico (D1): revenue de
  -- línea, bordes RN-D5, filtro de cuenta y filtros de sucursal / canal
  -- aplicados uniformemente (fail-closed: bajo filtro de sucursal la venta sin
  -- sucursal queda fuera en todas las dimensiones por igual).

  IF p_dimension = 'canal' THEN
    RETURN QUERY
    WITH agg AS (
      SELECT l.canal                          AS k,
             COALESCE(SUM(l.line_revenue), 0) AS rev,
             COALESCE(SUM(l.quantity), 0)     AS qty,
             COUNT(DISTINCT l.operation_key)  AS ops
      FROM public.reporting_sales_lines_in_window(
             p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
      GROUP BY l.canal
    ),
    ranked AS (
      SELECT a.*, ROW_NUMBER() OVER (ORDER BY a.rev DESC, a.k ASC NULLS LAST) AS rn
      FROM agg a
    )
    SELECT r.k,
           COALESCE(r.k, 'Sin canal'),
           r.rn::integer,
           r.rev, r.qty, r.ops,
           v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
    FROM ranked r
    ORDER BY r.rn;

  ELSIF p_dimension = 'branch' THEN
    RETURN QUERY
    WITH agg AS (
      SELECT l.branch_id                      AS k,
             COALESCE(SUM(l.line_revenue), 0) AS rev,
             COALESCE(SUM(l.quantity), 0)     AS qty,
             COUNT(DISTINCT l.operation_key)  AS ops
      FROM public.reporting_sales_lines_in_window(
             p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
      GROUP BY l.branch_id
    ),
    ranked AS (
      SELECT a.*, b.name AS bname,
             ROW_NUMBER() OVER (ORDER BY a.rev DESC, b.name ASC NULLS LAST, a.k ASC NULLS LAST) AS rn
      FROM agg a
      -- Scopeado por cuenta: nunca se rotula con el nombre de una sucursal
      -- ajena. Las inactivas conservan su nombre (ventas históricas).
      LEFT JOIN public.branches b ON b.id = a.k AND b.account_id = p_account_id
    )
    SELECT r.k::text,
           CASE WHEN r.k IS NULL THEN 'Sin sucursal' ELSE COALESCE(r.bname, 'Sucursal no disponible') END,
           r.rn::integer,
           r.rev, r.qty, r.ops,
           v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
    FROM ranked r
    ORDER BY r.rn;

  ELSIF p_dimension = 'weekday' THEN
    -- D3 / reporting-invariants: business_date ya es el día calendario del
    -- tenant (casteo directo en el helper). isodow: lunes = 1 … domingo = 7,
    -- consistente con date_trunc('week') de la evolución (D4). Los 7 días
    -- viajan siempre.
    RETURN QUERY
    WITH agg AS (
      SELECT EXTRACT(ISODOW FROM l.business_date)::integer AS d,
             COALESCE(SUM(l.line_revenue), 0)               AS rev,
             COALESCE(SUM(l.quantity), 0)                   AS qty,
             COUNT(DISTINCT l.operation_key)                AS ops
      FROM public.reporting_sales_lines_in_window(
             p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
      GROUP BY 1
    ),
    days AS (
      SELECT gs AS d FROM generate_series(1, 7) AS gs
    )
    SELECT d.d::text,
           (ARRAY['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'])[d.d],
           d.d,
           COALESCE(a.rev, 0), COALESCE(a.qty, 0), COALESCE(a.ops, 0),
           v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
    FROM days d
    LEFT JOIN agg a ON a.d = d.d
    ORDER BY d.d;

  ELSIF p_dimension = 'hour' THEN
    -- D5 / OQ-1: la hora deriva del INSTANTE de registro (created_at), que sí
    -- requiere la conversión a la zona del tenant — nunca de la fecha de
    -- negocio, que no tiene hora. Cruda 0-23; la franja la arma la UI. Las 24
    -- horas viajan siempre.
    RETURN QUERY
    WITH agg AS (
      SELECT EXTRACT(HOUR FROM (l.created_at AT TIME ZONE 'America/Argentina/Mendoza'))::integer AS h,
             COALESCE(SUM(l.line_revenue), 0) AS rev,
             COALESCE(SUM(l.quantity), 0)     AS qty,
             COUNT(DISTINCT l.operation_key)  AS ops
      FROM public.reporting_sales_lines_in_window(
             p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
      GROUP BY 1
    ),
    hours AS (
      SELECT gs AS h FROM generate_series(0, 23) AS gs
    )
    SELECT h.h::text,
           lpad(h.h::text, 2, '0') || ':00',
           h.h,
           COALESCE(a.rev, 0), COALESCE(a.qty, 0), COALESCE(a.ops, 0),
           v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
    FROM hours h
    LEFT JOIN agg a ON a.h = h.h
    ORDER BY h.h;

  ELSE  -- 'category'
    -- D6 / D15: agrupa por products.category_id (fuente de verdad del
    -- catálogo) y rotula con product_categories.name; las líneas de servicio
    -- (product_id NULL) no son productos y quedan fuera — su importe lo
    -- declara rpc_sales_evolution.service_revenue.
    RETURN QUERY
    WITH agg AS (
      SELECT pr.category_id                   AS k,
             COALESCE(SUM(l.line_revenue), 0) AS rev,
             COALESCE(SUM(l.quantity), 0)     AS qty,
             COUNT(DISTINCT l.operation_key)  AS ops
      FROM public.reporting_sales_lines_in_window(
             p_account_id, v_w.window_start, v_w.window_end, p_branch_id, p_canal) l
      JOIN public.products pr ON pr.id = l.product_id
      WHERE l.product_id IS NOT NULL
      GROUP BY pr.category_id
    ),
    ranked AS (
      SELECT a.*, pc.name AS cname,
             ROW_NUMBER() OVER (ORDER BY a.rev DESC, pc.name ASC NULLS LAST, a.k ASC NULLS LAST) AS rn
      FROM agg a
      LEFT JOIN public.product_categories pc ON pc.id = a.k AND pc.account_id = p_account_id
    )
    SELECT r.k::text,
           CASE WHEN r.k IS NULL THEN 'Sin categoría' ELSE COALESCE(r.cname, 'Categoría no disponible') END,
           r.rn::integer,
           r.rev, r.qty, r.ops,
           v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
    FROM ranked r
    ORDER BY r.rn;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.rpc_sales_breakdown(uuid, date, date, text, uuid, text) IS
  'estadisticas-ventas E2: desglose del período por canal / sucursal / día de la semana (fecha de negocio) / hora de carga (created_at en Mendoza) / categoría (category_id del catálogo), con tramo explícito "Sin …", sin restar NC (una NC no tiene dimensión atribuible), líneas de servicio fuera sólo de categoría. Clamp de historial por plan aplicado y declarado. Guard P0401.';

REVOKE ALL     ON FUNCTION public.rpc_sales_breakdown(uuid, date, date, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_sales_breakdown(uuid, date, date, text, uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_breakdown(uuid, date, date, text, uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_breakdown(uuid, date, date, text, uuid, text) TO service_role;


-- =============================================================================
-- 2. rpc_sales_top_clients — clientes con mayor facturación del período.
--    Filas row_kind='client' (rank 1..p_limit sobre el conjunto completo) y
--    UNA fila row_kind='unassigned' con el importe de las ventas sin cliente
--    (OQ-2: no compiten, se declaran aparte). total_clients viaja por fila.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_sales_top_clients(
  p_account_id uuid,
  p_start      date,
  p_end        date,
  p_branch_id  uuid    DEFAULT NULL,
  p_limit      integer DEFAULT 10
)
RETURNS TABLE(
  row_kind       text,
  rank           integer,
  client_id      uuid,
  client_name    text,
  revenue        numeric,
  units          numeric,
  operations     bigint,
  last_sale_date date,
  total_clients  bigint,
  window_start   date,
  window_end     date,
  history_days   integer,
  window_clamped boolean
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

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'Invalid limit: %', COALESCE(p_limit::text, 'NULL') USING ERRCODE = 'P0400';
  END IF;

  SELECT * INTO v_w FROM public.reporting_plan_window(p_account_id, p_start, p_end);

  RETURN QUERY
  WITH lines AS (
    SELECT l.*
    FROM public.reporting_sales_lines_in_window(
           p_account_id, v_w.window_start, v_w.window_end, p_branch_id, NULL) l
  ),
  by_client AS (
    SELECT l.client_id                      AS cid,
           SUM(l.line_revenue)              AS rev,
           SUM(l.quantity)                  AS qty,
           COUNT(DISTINCT l.operation_key)  AS ops,
           MAX(l.business_date)             AS last_sale
    FROM lines l
    WHERE l.client_id IS NOT NULL
    GROUP BY l.client_id
  ),
  ranked AS (
    SELECT bc.*,
           c.id   AS own_id,
           c.name AS cname,
           ROW_NUMBER() OVER (ORDER BY bc.rev DESC, bc.ops DESC, c.name ASC NULLS LAST, bc.cid ASC) AS rn,
           COUNT(*) OVER () AS n_clients
    FROM by_client bc
    -- Tenencia: sólo un cliente de ESTA cuenta resuelve id y nombre; un
    -- client_id ajeno rankea por su importe con id NULL y sin nombre.
    LEFT JOIN public.clients c ON c.id = bc.cid AND c.account_id = p_account_id
  ),
  unassigned AS (
    SELECT COALESCE(SUM(l.line_revenue), 0) AS rev,
           COALESCE(SUM(l.quantity), 0)     AS qty,
           COUNT(DISTINCT l.operation_key)  AS ops,
           MAX(l.business_date)             AS last_sale
    FROM lines l
    WHERE l.client_id IS NULL
  ),
  out_rows AS (
    SELECT 0 AS ord, r.rn AS sk, 'client'::text AS kind, r.rn::integer AS rk,
           r.own_id AS cid, COALESCE(r.cname, 'Cliente no disponible') AS cname,
           r.rev, r.qty, r.ops, r.last_sale, r.n_clients
    FROM ranked r
    WHERE r.rn <= p_limit
    UNION ALL
    SELECT 1, 0::bigint, 'unassigned', NULL::integer,
           NULL::uuid, NULL::text,
           u.rev, u.qty, u.ops, u.last_sale,
           (SELECT COUNT(*) FROM by_client)
    FROM unassigned u
  )
  SELECT o.kind, o.rk, o.cid, o.cname, o.rev, o.qty, o.ops, o.last_sale, o.n_clients,
         v_w.window_start, v_w.window_end, v_w.history_days, v_w.window_clamped
  FROM out_rows o
  ORDER BY o.ord, o.sk;
END;
$function$;

COMMENT ON FUNCTION public.rpc_sales_top_clients(uuid, date, date, uuid, integer) IS
  'estadisticas-ventas E2 (OQ-2): top clientes del período por importe (filas row_kind=client, rank sobre el conjunto completo, p_limit 1..200) + UNA fila row_kind=unassigned con el importe de las ventas sin cliente, declarado aparte. Nombre resuelto sólo para clientes de la cuenta. Sin restar NC. Clamp de historial por plan aplicado y declarado. Guard P0401.';

REVOKE ALL     ON FUNCTION public.rpc_sales_top_clients(uuid, date, date, uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_sales_top_clients(uuid, date, date, uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_top_clients(uuid, date, date, uuid, integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_sales_top_clients(uuid, date, date, uuid, integer) TO service_role;


-- =============================================================================
-- 3. Gate de introspección — aborta la migración si algo quedó a medias
-- =============================================================================
DO $$
DECLARE
  v_def  text;
  v_rest text;
  v_sig  text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.rpc_sales_breakdown(uuid,date,date,text,uuid,text)',
    'public.rpc_sales_top_clients(uuid,date,date,uuid,integer)'
  ] LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no existe tras la migración.', v_sig;
    END IF;
    v_def := pg_get_functiondef(to_regprocedure(v_sig));
    IF v_def !~ 'reporting_sales_lines_in_window' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no consume el helper canónico (D1).', v_sig;
    END IF;
    IF v_def !~ 'reporting_plan_window' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no aplica reporting_plan_window (D8).', v_sig;
    END IF;
    IF v_def ~* '\.date\s*\)?\s*AT\s+TIME\s+ZONE' OR v_def ~* 'business_date\s*\)?\s*AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % aplica una conversión de zona sobre la fecha de negocio (D3).', v_sig;
    END IF;
    -- El único AT TIME ZONE admitido en estas RPCs es sobre created_at.
    v_rest := regexp_replace(v_def, 'created_at\s+AT\s+TIME\s+ZONE', '', 'gi');
    IF v_rest ~* 'AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % convierte de zona algo que no es created_at.', v_sig;
    END IF;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: anon no debe ejecutar %.', v_sig;
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: authenticated debe ejecutar %.', v_sig;
    END IF;
  END LOOP;

  v_def := pg_get_functiondef(to_regprocedure('public.rpc_sales_breakdown(uuid,date,date,text,uuid,text)'));
  IF v_def !~* 'created_at\s+AT\s+TIME\s+ZONE\s+''America/Argentina/Mendoza''' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: la hora de carga debe derivar de created_at convertido a Mendoza (D5 / OQ-1).';
  END IF;

  RAISE NOTICE 'estadisticas-ventas E2: rpc_sales_breakdown (canal/branch/weekday/hour/category) + rpc_sales_top_clients sobre el helper canónico y el clamp OK.';
END $$;
