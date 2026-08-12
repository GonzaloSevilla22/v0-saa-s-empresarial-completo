-- =============================================================================
-- MIGRATION: 20260917000001_admin_kpi_refresh.sql
-- CHANGE:    admin-kpi-refresh (grupos 1-7 de tasks.md — APLICACIÓN PARCIAL)
--
-- QUÉ HACE (hallazgo F6, docs/plan-remediacion-kpis-2026-08-11.md Fase 4):
--   Los paneles /admin/analytics y /admin/metricas mentían de forma medible.
--   Esta migración corrige las definiciones en SQL para que el cliente deje
--   de re-agregar:
--
--   1. rpc_admin_kpi_overview (CREATE OR REPLACE, misma firma jsonb):
--      - community_active_users: COUNT(DISTINCT user_id) sobre
--        community.posts/replies del rango (antes: no existía; el cliente
--        sumaba active_users de community_engagement, agrupado por período Y
--        event_name — contaba una misma persona varias veces).
--      - total_activations_in_range / total_umv_in_range: redefinidos como
--        COUNT(DISTINCT user_id) sobre el rango completo (antes: SUM de
--        conteos por período — definicionalmente más frágil, aunque bajo la
--        unicidad estructural de first_operation no difiere hoy en valor).
--      - total_insights_in_range, umv_rate, avg_active_days_per_user_week:
--        nuevos, calculados en SQL (antes el cliente los derivaba con
--        reduce/Math.round sobre los arrays).
--      - summary.data_coverage: {last_operation_created_at,
--        last_first_operation_at, operation_events_stale_days} — declara el
--        agujero de telemetría en vez de dejar que un cero se lea como
--        "el negocio se detuvo" (D3 del design).
--      time_series / insights_breakdown / community_engagement quedan
--      intactos: siguen alimentando gráficos, no tarjetas.
--
--   2. rpc_admin_retention_30d (DROP + CREATE: cambia RETURNS TABLE, 42P13
--      con CREATE OR REPLACE): gana observation_window_days (=37, la ventana
--      vigente — NO cambia; eso es OQ-5, bloqueado) e is_mature (si la
--      cohorte ya vivió la ventana completa). Re-GRANT/REVOKE en esta misma
--      migración (el DROP resetea ACLs — gotcha del proyecto).
--
--   3. get_admin_community_interactions (CREATE OR REPLACE, misma firma):
--      lee community.posts/community.replies (schema calificado
--      explícitamente, sin ampliar search_path — D5) en vez de
--      public.posts/public.replies, que ya no existen desde C-23 (42P01).
--      Gana además el guard is_admin(auth.uid()) que nunca tuvo (cierra un
--      hueco de autorización preexistente: cualquier `authenticated` podía
--      invocarla directamente vía REST).
--
--   4. rpc_admin_module_stats (CREATE OR REPLACE, misma firma): rama
--      'comunidad' recalificada igual que (3). Rama 'cursos' tenía el MISMO
--      bug (course_progress también se movió a community.* en C-23) —
--      corregida de paso (tasks.md 5.2 lo pide explícitamente).
--
--   5. rpc_admin_business_kpis (CREATE OR REPLACE, misma firma): SOLO el
--      bloque `community` — active_pools pasa de literal 3 a
--      COUNT(*) FROM community.purchase_pools; total_activity reutiliza
--      get_admin_community_interactions en vez de recontar eventos. El
--      bloque `freemium` (MRR, pro_users, conversion_rate) NO SE TOCA —
--      sigue leyendo profiles.plan legacy hasta el sign-off de OQ-4 (grupo 8,
--      gateado, fuera de esta migración).
--
-- FUERA DE ALCANCE (bloqueado por sign-off del PO — grupos 8/9 de tasks.md):
--   MRR real (OQ-4) y redefinición de la ventana de retención (OQ-5). El
--   bloque freemium y la ventana [30,37) quedan exactamente como estaban.
--
-- GOVERNANCE: MEDIO — lectura agregada de KPIs admin, cero escritura de
--   negocio, cero cambio de billing/auth real (solo se agrega un guard
--   is_admin() a una función que no lo tenía).
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE: la integración GitHub de Supabase auto-
--   aplica migraciones al mergear a main ANTES del `db push` de Actions →
--   esta migración puede correr más de una vez.
--     - CREATE OR REPLACE para (1),(3),(4),(5): mismas firmas, sin riesgo de
--       overload (42725).
--     - DROP FUNCTION IF EXISTS + CREATE para (2): drop-then-create es
--       idempotente por construcción.
--     - GRANT/REVOKE son statements idempotentes (repetirlos es no-op).
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
--
-- ROLLBACK: cada función vuelve a su cuerpo previo con CREATE OR REPLACE
--   desde las migraciones de origen (20260227000100, 20260228000400,
--   20260311000010, 20260430000005); rpc_admin_retention_30d con DROP +
--   CREATE de la firma original (20260309000003) + su GRANT/REVOKE. Sin
--   migración de datos que revertir: el change es de lectura.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. rpc_admin_kpi_overview — conteos de cabecera + cobertura de datos
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_kpi_overview(
  date_from timestamptz,
  date_to timestamptz,
  granularity text DEFAULT 'day'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  WITH date_series AS (
    SELECT generate_series(
      date_trunc(granularity, date_from),
      date_trunc(granularity, date_to),
      (CASE WHEN granularity = 'week' THEN '1 week'::interval ELSE '1 day'::interval END)
    ) AS period
  ),

  activations AS (
    SELECT
      date_trunc(granularity, created_at) AS period,
      COUNT(DISTINCT user_id) as users_count
    FROM analytics_events
    WHERE event_name = 'first_operation'
      AND created_at BETWEEN date_from AND date_to
    GROUP BY 1
  ),

  user_activity AS (
    SELECT
      user_id,
      MIN(CASE WHEN event_name = 'first_operation' THEN created_at END) as first_op_time,
      MIN(CASE WHEN event_name = 'insight_generated' THEN created_at END) as first_insight_time
    FROM analytics_events
    GROUP BY user_id
  ),
  user_umv AS (
    SELECT
      user_id,
      GREATEST(first_op_time, first_insight_time) AS umv_achieved_at
    FROM user_activity
    WHERE first_op_time IS NOT NULL AND first_insight_time IS NOT NULL
  ),
  umv_series AS (
    SELECT
      date_trunc(granularity, umv_achieved_at) AS period,
      COUNT(DISTINCT user_id) AS umv_users_count
    FROM user_umv
    WHERE umv_achieved_at BETWEEN date_from AND date_to
    GROUP BY 1
  ),

  insights_series AS (
    SELECT
      date_trunc(granularity, created_at) AS period,
      event_data->>'type' AS insight_type,
      COUNT(*) as count
    FROM analytics_events
    WHERE event_name = 'insight_generated'
      AND created_at BETWEEN date_from AND date_to
    GROUP BY 1, 2
  ),

  community_series AS (
    SELECT
      date_trunc(granularity, created_at) AS period,
      event_name,
      COUNT(*) as count,
      COUNT(DISTINCT user_id) as active_users
    FROM analytics_events
    WHERE event_name IN ('post_created', 'reply_created')
      AND created_at BETWEEN date_from AND date_to
    GROUP BY 1, 2
  ),

  -- D5/D2: usuarios de comunidad se cuentan sobre las tablas transaccionales
  -- (community.posts/replies), no sobre analytics_events — misma regla que
  -- get_admin_community_interactions. Personas distintas, no filas.
  community_users_range AS (
    SELECT DISTINCT user_id FROM (
      SELECT user_id, created_at FROM community.posts
      UNION ALL
      SELECT user_id, created_at FROM community.replies
    ) c
    WHERE c.created_at BETWEEN date_from AND date_to
  ),

  -- D1 fila 115-117: la media ponderada que hoy hace el cliente sobre
  -- rpc_admin_weekly_usage_distribution es equivalente a un AVG simple sobre
  -- las filas usuario-semana sin bucketear (sum(active_days*users_count)/
  -- sum(users_count) == AVG(active_days) sobre las filas individuales).
  weekly_active_days AS (
    SELECT
      user_id,
      date_trunc('week', created_at) AS week_period,
      COUNT(DISTINCT date_trunc('day', created_at))::integer AS active_days
    FROM analytics_events
    WHERE event_name = 'operation_created'
      AND created_at BETWEEN date_from AND date_to
    GROUP BY user_id, date_trunc('week', created_at)
  ),

  -- D3: cobertura de datos — GLOBAL (no acotada al rango consultado): declara
  -- si la telemetría de operación está al día, independientemente de qué
  -- rango pida el panel.
  data_coverage_stats AS (
    SELECT
      MAX(created_at) FILTER (WHERE event_name = 'operation_created')  AS last_operation_created_at,
      MAX(created_at) FILTER (WHERE event_name = 'first_operation')    AS last_first_operation_at
    FROM analytics_events
  )

  SELECT jsonb_build_object(
    'time_series', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'period', ds.period,
          'activations', COALESCE(a.users_count, 0),
          'umv_achieved', COALESCE(u.umv_users_count, 0)
        ) ORDER BY ds.period
      )
      FROM date_series ds
      LEFT JOIN activations a ON ds.period = a.period
      LEFT JOIN umv_series u ON ds.period = u.period
    ),
    'insights_breakdown', (
      SELECT COALESCE(jsonb_agg(row_to_json(i)), '[]'::jsonb)
      FROM insights_series i
    ),
    'community_engagement', (
      SELECT COALESCE(jsonb_agg(row_to_json(c)), '[]'::jsonb)
      FROM community_series c
    ),
    'summary', jsonb_build_object(
      'total_activations_in_range', (SELECT COUNT(DISTINCT user_id) FROM analytics_events
        WHERE event_name = 'first_operation' AND created_at BETWEEN date_from AND date_to),
      'total_umv_in_range', (SELECT COUNT(DISTINCT user_id) FROM user_umv
        WHERE umv_achieved_at BETWEEN date_from AND date_to),
      'community_active_users', (SELECT COUNT(*) FROM community_users_range),
      'total_insights_in_range', (SELECT COUNT(*) FROM analytics_events
        WHERE event_name = 'insight_generated' AND created_at BETWEEN date_from AND date_to),
      'umv_rate', (
        SELECT CASE WHEN act.n > 0 THEN ROUND((umv.n::numeric / act.n) * 100) ELSE 0 END
        FROM
          (SELECT COUNT(DISTINCT user_id) AS n FROM analytics_events
             WHERE event_name = 'first_operation' AND created_at BETWEEN date_from AND date_to) act,
          (SELECT COUNT(DISTINCT user_id) AS n FROM user_umv
             WHERE umv_achieved_at BETWEEN date_from AND date_to) umv
      ),
      'avg_active_days_per_user_week', COALESCE(
        (SELECT ROUND(AVG(active_days), 1) FROM weekly_active_days), 0
      ),
      'data_coverage', (
        SELECT jsonb_build_object(
          'last_operation_created_at', dcs.last_operation_created_at,
          'last_first_operation_at', dcs.last_first_operation_at,
          'operation_events_stale_days', CASE
            WHEN dcs.last_operation_created_at IS NULL THEN NULL
            ELSE ROUND(EXTRACT(EPOCH FROM (now() - dcs.last_operation_created_at)) / 86400.0, 1)
          END
        )
        FROM data_coverage_stats dcs
      )
    )
  ) INTO result;

  RETURN result;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rpc_admin_retention_30d — madurez de cohorte (DROP: cambia RETURNS TABLE)
-- ─────────────────────────────────────────────────────────────────────────────
-- 42P13: Postgres rechaza CREATE OR REPLACE cuando cambia el tipo de retorno.
-- El DROP resetea las ACLs → se reaplican GRANT/REVOKE abajo en esta misma
-- migración (origen: 20260823000002 / 20260824000001).
DROP FUNCTION IF EXISTS public.rpc_admin_retention_30d(text, timestamptz, timestamptz);

CREATE FUNCTION public.rpc_admin_retention_30d(
  cohort_granularity text DEFAULT 'week',
  date_from timestamptz DEFAULT (now() - interval '90 days'),
  date_to timestamptz DEFAULT now()
)
RETURNS TABLE (
  cohort_start timestamptz,
  cohort_size bigint,
  retained_30d bigint,
  retention_rate numeric,
  observation_window_days integer,
  is_mature boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- La ventana vigente [30,37) NO cambia acá — eso es OQ-5, bloqueado
  -- (grupo 9 de tasks.md). Este grupo sólo traslada la propiedad de la
  -- ventana del cliente (hoy hardcodeada, 37 días) a la RPC.
  c_observation_window_days CONSTANT integer := 37;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  RETURN QUERY
  WITH user_cohorts AS (
    SELECT
      user_id,
      date_trunc(cohort_granularity, created_at) AS cohort_period,
      created_at AS activation_time
    FROM public.analytics_events
    WHERE event_name = 'first_operation'
      AND created_at BETWEEN date_from AND date_to
  ),
  user_retention AS (
    SELECT DISTINCT
      c.user_id,
      c.cohort_period
    FROM user_cohorts c
    JOIN public.analytics_events e ON c.user_id = e.user_id
    WHERE e.event_name = 'operation_created'
      AND e.created_at >= c.activation_time + interval '30 days'
      AND e.created_at < c.activation_time + interval '37 days'
  ),
  cohort_sizes AS (
    SELECT cohort_period, COUNT(user_id) AS total_users
    FROM user_cohorts
    GROUP BY cohort_period
  ),
  retained_sizes AS (
    SELECT cohort_period, COUNT(user_id) AS retained_users
    FROM user_retention
    GROUP BY cohort_period
  )
  SELECT
    cs.cohort_period AS cohort_start,
    cs.total_users AS cohort_size,
    COALESCE(rs.retained_users, 0) AS retained_30d,
    ROUND((COALESCE(rs.retained_users, 0)::numeric / cs.total_users::numeric) * 100, 2) AS retention_rate,
    c_observation_window_days AS observation_window_days,
    (cs.cohort_period < now() - (c_observation_window_days || ' days')::interval) AS is_mature
  FROM cohort_sizes cs
  LEFT JOIN retained_sizes rs ON cs.cohort_period = rs.cohort_period
  ORDER BY cs.cohort_period;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz) FROM PUBLIC, anon;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. get_admin_community_interactions — schema calificado + guard is_admin
-- ─────────────────────────────────────────────────────────────────────────────
-- Misma firma (CREATE OR REPLACE conserva ACLs). D5: se califica el schema
-- explícitamente (community.posts/replies) en vez de ampliar search_path —
-- un search_path con dos schemas resuelve por orden y vuelve a hacer
-- invisible el próximo movimiento de tablas.
CREATE OR REPLACE FUNCTION public.get_admin_community_interactions(
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
BEGIN
  -- Esta función nunca tuvo el guard is_admin (hueco de autorización
  -- preexistente: cualquier `authenticated` podía invocarla directamente vía
  -- REST — frontend/lib/adminAnalytics.ts:fetchCommunityInteractions). Se
  -- cierra acá porque D11/M1 ya la toca para la calificación de schema.
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  -- Regla 3.6: Validar fechas invertidas devolviendo 0
  IF p_date_from > p_date_to THEN
    RETURN 0::bigint;
  END IF;

  -- Regla 3.6 / D5: Única Fuente de Verdad — tablas transaccionales del
  -- schema community (movidas desde public por C-23, 20260615000001).
  WITH posts_count AS (
    SELECT COUNT(*) as total
    FROM community.posts
    WHERE created_at >= p_date_from
      AND created_at <= p_date_to
  ),
  replies_count AS (
    SELECT COUNT(*) as total
    FROM community.replies
    WHERE created_at >= p_date_from
      AND created_at <= p_date_to
  )
  SELECT
    COALESCE((SELECT total FROM posts_count), 0) +
    COALESCE((SELECT total FROM replies_count), 0)
  INTO v_total;

  RETURN v_total;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. rpc_admin_module_stats — ramas 'comunidad' y 'cursos' recalificadas
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_module_stats(
  p_module_type text,
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_summary jsonb;
  v_series jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  CASE p_module_type
    WHEN 'ventas' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM sales WHERE date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM sales WHERE date BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'compras' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM purchases WHERE date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM purchases WHERE date BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'gastos' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM expenses WHERE date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM expenses WHERE date BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'stock' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM products;
      v_series := '[]'::jsonb;

    WHEN 'clientes' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM clients WHERE created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM clients WHERE created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'ai' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM analytics_events
      WHERE event_name = 'insight_generated'
      AND (event_data->>'type' = 'general' OR event_data->>'type' = 'prediction')
      AND created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM analytics_events
        WHERE event_name = 'insight_generated'
        AND (event_data->>'type' = 'general' OR event_data->>'type' = 'prediction')
        AND created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'simulador' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM analytics_events
      WHERE event_name = 'insight_generated'
      AND event_data->>'type' = 'simulation'
      AND created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM analytics_events
        WHERE event_name = 'insight_generated'
        AND event_data->>'type' = 'simulation'
        AND created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'comunidad' THEN
      -- D5: schema calificado explícitamente (community.posts/replies) —
      -- estas tablas se movieron desde public por C-23 (20260615000001);
      -- el panel /admin/metricas/comunidad fallaba con 42P01.
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM (
        SELECT user_id, created_at FROM community.posts
        UNION ALL
        SELECT user_id, created_at FROM community.replies
      ) community_stats WHERE created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM (
          SELECT user_id, created_at FROM community.posts
          UNION ALL
          SELECT user_id, created_at FROM community.replies
        ) community_stats WHERE created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'cursos' THEN
      -- Mismo bug de schema que 'comunidad': course_progress también se
      -- movió a community.* por C-23 — corregido de paso (tasks.md 5.2).
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM community.course_progress WHERE last_accessed_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', last_accessed_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM community.course_progress WHERE last_accessed_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    ELSE
      v_summary := '{}'::jsonb;
      v_series := '[]'::jsonb;
  END CASE;

  RETURN jsonb_build_object(
    'summary', COALESCE(v_summary, '{}'::jsonb),
    'time_series', COALESCE(v_series, '[]'::jsonb)
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. rpc_admin_business_kpis — SOLO el bloque `community` (freemium gateado)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_business_kpis(
  date_from timestamptz DEFAULT (now() - interval '30 days'),
  date_to timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
  v_total_users bigint;
  v_mau bigint;
  v_activated_users bigint;
  v_pro_users bigint;
  v_mrr numeric;
  v_community_activity bigint;
  v_active_pools bigint;
  v_ai_reports bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  -- 1. Adoption Metrics
  SELECT COUNT(*) INTO v_total_users FROM profiles;

  SELECT COUNT(DISTINCT user_id) INTO v_mau
  FROM analytics_events
  WHERE created_at > (now() - interval '30 days');

  SELECT COUNT(DISTINCT user_id) INTO v_activated_users
  FROM analytics_events
  WHERE event_name = 'first_operation';

  -- 2. Freemium Metrics — SIN CAMBIOS (gateado por OQ-4, grupo 8 de
  -- tasks.md). Sigue leyendo profiles.plan legacy hasta el sign-off del PO.
  SELECT COUNT(*) INTO v_pro_users FROM profiles WHERE plan = 'pro';
  v_mrr := v_pro_users * 15;

  -- 3. Community Metrics — D5: tablas transaccionales, no eventos.
  -- Reutiliza get_admin_community_interactions (regla de reutilización antes
  -- que repetición) en vez de recontar por su cuenta.
  v_community_activity := public.get_admin_community_interactions(date_from, date_to);
  SELECT COUNT(*) INTO v_active_pools FROM community.purchase_pools;

  -- 4. IA Metrics
  SELECT COUNT(*) INTO v_ai_reports
  FROM analytics_events
  WHERE event_name = 'insight_generated'
    AND created_at BETWEEN date_from AND date_to;

  SELECT jsonb_build_object(
    'adoption', jsonb_build_object(
      'total_users', v_total_users,
      'mau', v_mau,
      'activation_rate', CASE WHEN v_total_users > 0 THEN (v_activated_users::numeric / v_total_users * 100)::int ELSE 0 END
    ),
    'freemium', jsonb_build_object(
      'pro_users', v_pro_users,
      'conversion_rate', CASE WHEN v_total_users > 0 THEN (v_pro_users::numeric / v_total_users * 100)::numeric(10,2) ELSE 0 END,
      'mrr', v_mrr
    ),
    'community', jsonb_build_object(
      'total_activity', v_community_activity,
      'active_pools', v_active_pools
    ),
    'ai', jsonb_build_object(
      'total_insights', v_ai_reports,
      'alerts_triggered', (SELECT COUNT(*) FROM analytics_events WHERE event_name = 'operation_created' AND (event_data->>'type' = 'stock_alert'))
    )
  ) INTO result;

  RETURN result;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Superficie de autorización — GRANT/REVOKE idempotentes para las 5 RPCs
--    (defensa en profundidad: CREATE OR REPLACE conserva ACLs existentes;
--    sólo rpc_admin_retention_30d necesitaba el re-GRANT arriba porque usó
--    DROP+CREATE. Esto deja las 5 explícitas en la misma migración, igual
--    que el patrón de 20260823000002/20260824000001.)
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.rpc_admin_kpi_overview(timestamptz, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_community_interactions(timestamptz, timestamptz) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.rpc_admin_kpi_overview(timestamptz, timestamptz, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_admin_community_interactions(timestamptz, timestamptz) FROM PUBLIC, anon;

-- ── GATE — exactamente una definición por proname + ACLs correctas ──────────
DO $$
DECLARE
  v_sig      text;
  v_dup      int;
  v_fns      CONSTANT text[] := ARRAY[
    'public.rpc_admin_kpi_overview(timestamptz, timestamptz, text)',
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz)',
    'public.rpc_admin_module_stats(text, timestamptz, timestamptz)',
    'public.rpc_admin_business_kpis(timestamptz, timestamptz)',
    'public.get_admin_community_interactions(timestamptz, timestamptz)'
  ];
  v_pronames CONSTANT text[] := ARRAY[
    'rpc_admin_kpi_overview', 'rpc_admin_retention_30d', 'rpc_admin_module_stats',
    'rpc_admin_business_kpis', 'get_admin_community_interactions'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % sin EXECUTE para authenticated', v_sig;
    END IF;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % con EXECUTE para anon', v_sig;
    END IF;
  END LOOP;

  FOREACH v_sig IN ARRAY v_pronames LOOP
    SELECT COUNT(*) INTO v_dup
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = v_sig;

    IF v_dup <> 1 THEN
      RAISE EXCEPTION 'GATE FAILED: % tiene % definiciones (anti-42725)', v_sig, v_dup;
    END IF;
  END LOOP;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260917000001_admin_kpi_refresh.sql
-- =============================================================================
