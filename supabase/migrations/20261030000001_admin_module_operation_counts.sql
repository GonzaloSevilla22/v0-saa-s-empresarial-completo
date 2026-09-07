-- kpi-canonical-audit: rpc_admin_module_stats exponía COUNT(*) bajo la unidad
-- "Operaciones Totales" para ventas y compras. Desde 20260418000003 una
-- operación puede tener varias líneas con el mismo operation_id; RN-D exige
-- COUNT(DISTINCT COALESCE(operation_id, id)).

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
        'users_count', COUNT(DISTINCT s.user_id),
        'count', COUNT(DISTINCT COALESCE(s.operation_id, s.id)),
        'avg_per_user', CASE
          WHEN COUNT(DISTINCT s.user_id) > 0
          THEN (
            COUNT(DISTINCT COALESCE(s.operation_id, s.id))::numeric
            / COUNT(DISTINCT s.user_id)::numeric
          )::numeric(10,1)
          ELSE 0
        END
      ) INTO v_summary
      FROM public.sales s
      WHERE s.date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT
          date_trunc('day', s.date) AS period,
          COUNT(DISTINCT s.user_id) AS users_count,
          COUNT(DISTINCT COALESCE(s.operation_id, s.id)) AS count
        FROM public.sales s
        WHERE s.date BETWEEN p_date_from AND p_date_to
        GROUP BY 1
        ORDER BY 1
      ) d;

    WHEN 'compras' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT p.user_id),
        'count', COUNT(DISTINCT COALESCE(p.operation_id, p.id)),
        'avg_per_user', CASE
          WHEN COUNT(DISTINCT p.user_id) > 0
          THEN (
            COUNT(DISTINCT COALESCE(p.operation_id, p.id))::numeric
            / COUNT(DISTINCT p.user_id)::numeric
          )::numeric(10,1)
          ELSE 0
        END
      ) INTO v_summary
      FROM public.purchases p
      WHERE p.date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT
          date_trunc('day', p.date) AS period,
          COUNT(DISTINCT p.user_id) AS users_count,
          COUNT(DISTINCT COALESCE(p.operation_id, p.id)) AS count
        FROM public.purchases p
        WHERE p.date BETWEEN p_date_from AND p_date_to
        GROUP BY 1
        ORDER BY 1
      ) d;

    WHEN 'gastos' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM public.expenses WHERE date BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', date) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
        FROM public.expenses WHERE date BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'stock' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM public.products WHERE deleted_at IS NULL;
      v_series := '[]'::jsonb;

    WHEN 'clientes' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM public.clients
      WHERE created_at BETWEEN p_date_from AND p_date_to
        AND deleted_at IS NULL;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
        FROM public.clients
        WHERE created_at BETWEEN p_date_from AND p_date_to
          AND deleted_at IS NULL
        GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'ai' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM public.analytics_events
      WHERE event_name = 'insight_generated'
        AND (event_data->>'type' = 'general' OR event_data->>'type' = 'prediction')
        AND created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
        FROM public.analytics_events
        WHERE event_name = 'insight_generated'
          AND (event_data->>'type' = 'general' OR event_data->>'type' = 'prediction')
          AND created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'simulador' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM public.analytics_events
      WHERE event_name = 'insight_generated'
        AND event_data->>'type' = 'simulation'
        AND created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
        FROM public.analytics_events
        WHERE event_name = 'insight_generated'
          AND event_data->>'type' = 'simulation'
          AND created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'comunidad' THEN
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
        SELECT date_trunc('day', created_at) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
        FROM (
          SELECT user_id, created_at FROM community.posts
          UNION ALL
          SELECT user_id, created_at FROM community.replies
        ) community_stats WHERE created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'cursos' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM community.course_progress WHERE last_accessed_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', last_accessed_at) AS period, COUNT(DISTINCT user_id) AS users_count, COUNT(*) AS count
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

GRANT EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) FROM PUBLIC, anon;

COMMENT ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) IS
  'Métricas admin por módulo. Ventas/compras cuentan operaciones distintas mediante COALESCE(operation_id,id); las demás ramas conservan su unidad transaccional.';

-- Gate estático de la migración: evita que una edición futura vuelva a
-- COUNT(*) para las dos tablas multilínea sin que falle el despliegue.
DO $$
DECLARE
  v_def text := pg_get_functiondef(
    'public.rpc_admin_module_stats(text,timestamptz,timestamptz)'::regprocedure
  );
BEGIN
  IF position('COUNT(DISTINCT COALESCE(s.operation_id, s.id))' IN v_def) = 0 THEN
    RAISE EXCEPTION 'KPI GATE: rpc_admin_module_stats no cuenta operaciones de venta de forma canónica';
  END IF;
  IF position('COUNT(DISTINCT COALESCE(p.operation_id, p.id))' IN v_def) = 0 THEN
    RAISE EXCEPTION 'KPI GATE: rpc_admin_module_stats no cuenta operaciones de compra de forma canónica';
  END IF;
  -- Soft delete: cada filtro se ancla al FROM de su propia rama (no a cualquier
  -- ocurrencia del literal en el cuerpo). \s+ tolera LF/CRLF e indentación.
  IF v_def !~ 'FROM public\.products\s+WHERE deleted_at IS NULL' THEN
    RAISE EXCEPTION 'KPI GATE: rpc_admin_module_stats no excluye productos soft-deleted';
  END IF;
  -- La rama 'clientes' filtra en DOS consultas (resumen y serie): exigir ambas.
  IF (SELECT count(*) FROM regexp_matches(
        v_def,
        'FROM public\.clients\s+WHERE created_at BETWEEN p_date_from AND p_date_to\s+AND deleted_at IS NULL',
        'g')) < 2 THEN
    RAISE EXCEPTION 'KPI GATE: rpc_admin_module_stats no excluye clientes soft-deleted';
  END IF;
END;
$$;
