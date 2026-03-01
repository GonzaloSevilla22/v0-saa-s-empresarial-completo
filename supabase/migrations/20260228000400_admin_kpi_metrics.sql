-- Admin Metrics & KPI Aggregations

-- 1. RPC for Business KPIs (Adoption, Freemium, Community, IA)
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
  v_ai_reports bigint;
BEGIN
  -- Strict Authorization
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  -- 1. Adoption Metrics
  SELECT COUNT(*) INTO v_total_users FROM profiles;
  
  -- MAU (Users with any event in the last 30 days)
  SELECT COUNT(DISTINCT user_id) INTO v_mau 
  FROM analytics_events 
  WHERE created_at > (now() - interval '30 days');

  -- Activation (Users with 'first_operation')
  SELECT COUNT(DISTINCT user_id) INTO v_activated_users 
  FROM analytics_events 
  WHERE event_name = 'first_operation';

  -- 2. Freemium Metrics
  SELECT COUNT(*) INTO v_pro_users FROM profiles WHERE plan = 'pro';
  
  -- MRR Estimation (Pro users * $15 assumed price for MVP)
  v_mrr := v_pro_users * 15;

  -- 3. Community Metrics
  SELECT COUNT(*) INTO v_community_activity 
  FROM analytics_events 
  WHERE event_name IN ('post_created', 'reply_created')
    AND created_at BETWEEN date_from AND date_to;

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
      'active_pools', 3 -- Placeholder for MVP logic
    ),
    'ai', jsonb_build_object(
      'total_insights', v_ai_reports,
      'alerts_triggered', (SELECT COUNT(*) FROM analytics_events WHERE event_name = 'operation_created' AND (event_data->>'type' = 'stock_alert'))
    )
  ) INTO result;

  RETURN result;
END;
$$;

-- 2. RPC for Module-Specific Financial Totals
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
      'total_amount', COALESCE(SUM(total), 0),
      'count', COUNT(*),
      'avg_ticket', COALESCE(AVG(total), 0)
    ) INTO v_summary
    FROM sales 
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, SUM(total) as amount, COUNT(*) as count
      FROM sales
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;

  ELSIF p_module_type = 'compras' THEN
    SELECT jsonb_build_object(
      'total_amount', COALESCE(SUM(total), 0),
      'count', COUNT(*),
      'avg_cost', COALESCE(AVG(total), 0)
    ) INTO v_summary
    FROM purchases
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, SUM(total) as amount, COUNT(*) as count
      FROM purchases
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;

  ELSIF p_module_type = 'gastos' THEN
    SELECT jsonb_build_object(
      'total_amount', COALESCE(SUM(amount), 0),
      'count', COUNT(*),
      'avg_expense', COALESCE(AVG(amount), 0)
    ) INTO v_summary
    FROM expenses
    WHERE date BETWEEN p_date_from AND p_date_to;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', date) as period, SUM(amount) as amount, COUNT(*) as count
      FROM expenses
      WHERE date BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;
  
  ELSIF p_module_type = 'stock' THEN
    SELECT jsonb_build_object(
      'total_items', COALESCE(SUM(stock), 0),
      'low_stock_count', (SELECT COUNT(*) FROM products WHERE stock <= min_stock),
      'total_inventory_value', COALESCE(SUM(stock * cost), 0)
    ) INTO v_summary
    FROM products;
    
    v_series := '[]'::jsonb; -- Stock doesn't have a time series in this simplified version
    
  ELSIF p_module_type = 'clientes' THEN
    SELECT jsonb_build_object(
      'total_count', COUNT(*),
      'active_count', (SELECT COUNT(*) FROM clients WHERE status = 'activo')
    ) INTO v_summary
    FROM clients;

    SELECT jsonb_agg(d) INTO v_series FROM (
      SELECT date_trunc('day', created_at) as period, COUNT(*) as count
      FROM clients
      WHERE created_at BETWEEN p_date_from AND p_date_to
      GROUP BY 1 ORDER BY 1
    ) d;
  END IF;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'time_series', COALESCE(v_series, '[]'::jsonb)
  );
END;
$$;
