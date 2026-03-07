-- 20260307000300_expand_admin_module_stats.sql
-- Expansion of rpc_admin_module_stats to support AI, Simulator, Community, and Courses

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
      WITH community_stats AS (
        SELECT user_id, created_at FROM posts
        UNION ALL
        SELECT user_id, created_at FROM replies
      )
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM community_stats WHERE created_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM community_stats WHERE created_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
      ) d;

    WHEN 'cursos' THEN
      SELECT jsonb_build_object(
        'users_count', COUNT(DISTINCT user_id),
        'count', COUNT(*),
        'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
      ) INTO v_summary FROM course_progress WHERE last_accessed_at BETWEEN p_date_from AND p_date_to;

      SELECT jsonb_agg(d) INTO v_series FROM (
        SELECT date_trunc('day', last_accessed_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
        FROM course_progress WHERE last_accessed_at BETWEEN p_date_from AND p_date_to GROUP BY 1 ORDER BY 1
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
