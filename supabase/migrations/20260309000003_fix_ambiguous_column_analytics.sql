-- Comprehensive fix for ambiguous column references in Admin Analytics RPCs
-- Ensures compatibility with Postgres 14+ where RETURNS TABLE columns are in scope

-- 1. Fix rpc_admin_weekly_usage_distribution
CREATE OR REPLACE FUNCTION public.rpc_admin_weekly_usage_distribution(
  date_from timestamptz,
  date_to timestamptz
)
RETURNS TABLE (
  week_start timestamptz,
  active_days integer,
  users_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  RETURN QUERY
  WITH user_active_days AS (
    SELECT 
      user_id,
      date_trunc('week', created_at) AS week_period,
      COUNT(DISTINCT date_trunc('day', created_at))::integer AS val_active_days
    FROM public.analytics_events
    WHERE event_name = 'operation_created'
      AND created_at BETWEEN date_from AND date_to
    GROUP BY user_id, date_trunc('week', created_at)
  )
  SELECT 
    week_period AS week_start,
    val_active_days AS active_days,
    COUNT(user_id) AS users_count
  FROM user_active_days
  GROUP BY 1, 2
  ORDER BY 1, 2;
END;
$$;

-- 2. Fix rpc_admin_retention_30d
CREATE OR REPLACE FUNCTION public.rpc_admin_retention_30d(
  cohort_granularity text DEFAULT 'week',
  date_from timestamptz DEFAULT (now() - interval '90 days'),
  date_to timestamptz DEFAULT now()
)
RETURNS TABLE (
  cohort_start timestamptz,
  cohort_size bigint,
  retained_30d bigint,
  retention_rate numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    ROUND((COALESCE(rs.retained_users, 0)::numeric / cs.total_users::numeric) * 100, 2) AS retention_rate
  FROM cohort_sizes cs
  LEFT JOIN retained_sizes rs ON cs.cohort_period = rs.cohort_period
  ORDER BY 1;
END;
$$;
