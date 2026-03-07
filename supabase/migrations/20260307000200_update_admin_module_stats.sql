-- Update rpc_admin_module_stats to return module usage engagement instead of financial metrics

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

  IF p_module_type = 'ventas' THEN
    SELECT jsonb_build_object(
      'users_count', COUNT(DISTINCT user_id),
      'count', COUNT(*),
      'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
    ) INTO v_summary
    FROM sales 
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
      FROM sales
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;

  ELSIF p_module_type = 'compras' THEN
    SELECT jsonb_build_object(
      'users_count', COUNT(DISTINCT user_id),
      'count', COUNT(*),
      'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
    ) INTO v_summary
    FROM purchases
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
      FROM purchases
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;

  ELSIF p_module_type = 'gastos' THEN
    SELECT jsonb_build_object(
      'users_count', COUNT(DISTINCT user_id),
      'count', COUNT(*),
      'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
    ) INTO v_summary
    FROM expenses
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
      FROM expenses
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;
  
  ELSIF p_module_type = 'stock' THEN
    SELECT jsonb_build_object(
      'users_count', COUNT(DISTINCT user_id),
      'count', COUNT(*),
      'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
    ) INTO v_summary
    FROM products;
    
    v_series := '[]'::jsonb; 
    
  ELSIF p_module_type = 'clientes' THEN
    SELECT jsonb_build_object(
      'users_count', COUNT(DISTINCT user_id),
      'count', COUNT(*),
      'avg_per_user', CASE WHEN COUNT(DISTINCT user_id) > 0 THEN (COUNT(*)::numeric / COUNT(DISTINCT user_id)::numeric)::numeric(10,1) ELSE 0 END
    ) INTO v_summary
    FROM clients;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', created_at) as period, COUNT(DISTINCT user_id) as users_count, COUNT(*) as count
      FROM clients
      WHERE created_at BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;
  END IF;

  RETURN jsonb_build_object(
    'summary', COALESCE(v_summary, '{}'::jsonb),
    'time_series', COALESCE(v_series, '[]'::jsonb)
  );
END;
$$;
