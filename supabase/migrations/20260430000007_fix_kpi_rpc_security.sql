-- Applied directly via MCP on 2026-04-30. Stub recovered from supabase_migrations.schema_migrations.

DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.get_dashboard_financials(uuid, timestamptz, timestamptz);
  DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock(uuid);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_financials(p_date_from timestamptz, p_date_to timestamptz)
RETURNS TABLE (total_income numeric, total_expenses numeric, total_purchases numeric, net_profit numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_date_from > p_date_to THEN RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, 0::numeric; RETURN; END IF;
  RETURN QUERY
  WITH ingresos AS (SELECT COALESCE(SUM(amount), 0) AS total FROM public.sales WHERE user_id = v_uid AND date >= p_date_from AND date <= p_date_to),
  gastos AS (SELECT COALESCE(SUM(amount), 0) AS total FROM public.expenses WHERE user_id = v_uid AND date >= p_date_from AND date <= p_date_to),
  compras AS (SELECT COALESCE(SUM(amount), 0) AS total FROM public.purchases WHERE user_id = v_uid AND date >= p_date_from AND date <= p_date_to)
  SELECT i.total, g.total, c.total, (i.total - (g.total + c.total)) FROM ingresos i CROSS JOIN gastos g CROSS JOIN compras c;
END; $$;

CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock()
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_count bigint;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT COUNT(id) INTO v_count FROM public.products WHERE user_id = v_uid AND stock <= min_stock;
  RETURN COALESCE(v_count, 0);
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_activation_rate(p_date_from timestamptz, p_date_to timestamptz)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_date_from > p_date_to THEN RETURN 0::numeric; END IF;
  WITH cohort_users AS (SELECT id FROM public.profiles WHERE created_at >= p_date_from AND created_at <= p_date_to),
  activated AS (SELECT COUNT(DISTINCT ae.user_id) AS cnt FROM public.analytics_events ae INNER JOIN cohort_users cu ON ae.user_id = cu.id WHERE ae.event_name = 'first_operation')
  SELECT COALESCE(ROUND((a.cnt::numeric / NULLIF((SELECT COUNT(*) FROM cohort_users), 0)) * 100, 2), 0) INTO v_rate FROM activated a;
  RETURN v_rate;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_umv_rate(p_date_from timestamptz, p_date_to timestamptz)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_date_from > p_date_to THEN RETURN 0::numeric; END IF;
  WITH activated AS (SELECT DISTINCT user_id FROM public.analytics_events WHERE event_name = 'first_operation' AND created_at >= p_date_from AND created_at <= p_date_to),
  umv AS (SELECT DISTINCT ae.user_id FROM public.analytics_events ae INNER JOIN activated a ON ae.user_id = a.user_id WHERE ae.event_name = 'insight_generated' AND ae.created_at >= p_date_from AND ae.created_at <= p_date_to)
  SELECT COALESCE(ROUND(((SELECT COUNT(*) FROM umv)::numeric / NULLIF((SELECT COUNT(*) FROM activated), 0)) * 100, 2), 0) INTO v_rate;
  RETURN v_rate;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_paid_conversion_rate()
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT COALESCE(ROUND((COUNT(*) FILTER (WHERE plan = 'pro')::numeric / NULLIF(COUNT(*), 0)) * 100, 2), 0) INTO v_rate FROM public.profiles;
  RETURN v_rate;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_community_interactions(p_date_from timestamptz, p_date_to timestamptz)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_total bigint;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_date_from > p_date_to THEN RETURN 0::bigint; END IF;
  SELECT COALESCE((SELECT COUNT(*) FROM public.posts WHERE created_at >= p_date_from AND created_at <= p_date_to), 0) + COALESCE((SELECT COUNT(*) FROM public.replies WHERE created_at >= p_date_from AND created_at <= p_date_to), 0) INTO v_total;
  RETURN v_total;
END; $$;

CREATE OR REPLACE FUNCTION public.get_admin_insights_breakdown(p_date_from timestamptz, p_date_to timestamptz)
RETURNS TABLE (insight_type text, total bigint) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF p_date_from > p_date_to THEN RETURN; END IF;
  RETURN QUERY SELECT LOWER(COALESCE(event_data->>'type', 'uncategorized')), COUNT(*) FROM public.analytics_events WHERE event_name = 'insight_generated' AND created_at >= p_date_from AND created_at <= p_date_to GROUP BY 1 ORDER BY 2 DESC;
END; $$;

GRANT EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dashboard_critical_stock()                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_activation_rate(timestamptz, timestamptz)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_umv_rate(timestamptz, timestamptz)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_paid_conversion_rate()                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_community_interactions(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_insights_breakdown(timestamptz, timestamptz)     TO authenticated;
