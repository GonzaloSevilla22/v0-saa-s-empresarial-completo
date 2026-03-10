-- Fix ambiguous column reference "active_days" in rpc_admin_weekly_usage_distribution

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
    -- Count distinct active days per user per week
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
