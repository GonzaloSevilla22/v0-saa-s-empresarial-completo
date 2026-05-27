-- =============================================================================
-- MIGRATION: 20260430000007_fix_kpi_rpc_security.sql
-- DESCRIPTION: Security corrections for KPI RPCs introduced in the
--              KPI Engine Refactor (migrations 20260430000000-20260430000006).
--
-- PROBLEMS FIXED:
--
--  [CRITICAL] get_dashboard_financials(p_user_id uuid, ...) and
--             get_dashboard_critical_stock(p_user_id uuid) accepted user_id
--             from the caller. Any authenticated user could pass another
--             tenant's UUID to read their financial data.
--             Fix: Remove p_user_id parameter; use auth.uid() internally.
--             Drop old signatures to prevent overload bypass.
--
--  [HIGH]     get_admin_* functions had no access control. Any authenticated
--             user could call them to read aggregate platform analytics.
--             Fix: Add is_admin() check at the start of each function.
--
--  [MEDIUM]   Missing GRANT EXECUTE on all new RPCs.
--             Fix: Explicit grants added for each function.
-- =============================================================================

-- ── Drop old vulnerable signatures (created by PR #31 migrations) ─────────────
-- IF NOT EXISTS variants ensure this is safe whether PR #31 was merged or not.
DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.get_dashboard_financials(uuid, timestamptz, timestamptz);
  DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock(uuid);
END;
$$;

-- =============================================================================
-- SECTION 1 — Tenant-isolated dashboard KPIs (no p_user_id)
-- =============================================================================

-- ── get_dashboard_financials ──────────────────────────────────────────────────
-- Income, expenses, purchases and net profit for the authenticated user
-- within a given date range.
CREATE OR REPLACE FUNCTION public.get_dashboard_financials(
  p_date_from timestamptz,
  p_date_to   timestamptz
)
RETURNS TABLE (
  total_income    numeric,
  total_expenses  numeric,
  total_purchases numeric,
  net_profit      numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Inverted date range: return zeroes rather than crashing
  IF p_date_from > p_date_to THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, 0::numeric;
    RETURN;
  END IF;

  RETURN QUERY
  WITH ingresos AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.sales
    WHERE user_id = v_uid
      AND date >= p_date_from
      AND date <= p_date_to
  ),
  gastos AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.expenses
    WHERE user_id = v_uid
      AND date >= p_date_from
      AND date <= p_date_to
  ),
  compras AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.purchases
    WHERE user_id = v_uid
      AND date >= p_date_from
      AND date <= p_date_to
  )
  SELECT
    i.total                        AS total_income,
    g.total                        AS total_expenses,
    c.total                        AS total_purchases,
    (i.total - (g.total + c.total)) AS net_profit
  FROM ingresos i
  CROSS JOIN gastos g
  CROSS JOIN compras c;
END;
$$;

-- ── get_dashboard_critical_stock ──────────────────────────────────────────────
-- Count of products below min_stock for the authenticated user.
CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_count bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COUNT(id) INTO v_count
  FROM public.products
  WHERE user_id = v_uid
    AND min_stock > 0          -- exclude products with no threshold configured
    AND stock <= min_stock;

  RETURN COALESCE(v_count, 0);
END;
$$;

-- =============================================================================
-- SECTION 2 — Admin KPIs (guarded by is_admin())
-- =============================================================================

-- ── get_admin_activation_rate ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_activation_rate(
  p_date_from timestamptz,
  p_date_to   timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN 0::numeric;
  END IF;

  -- Single-scan approach: compute total cohort size and activated count in one pass
  -- to avoid evaluating the cohort_users CTE twice (PostgreSQL 12+ inlines CTEs).
  WITH cohort_counts AS (
    SELECT
      COUNT(DISTINCT p.id)                                             AS total_cohort,
      COUNT(DISTINCT ae.user_id)                                       AS activated_count
    FROM public.profiles p
    LEFT JOIN public.analytics_events ae
           ON ae.user_id    = p.id
          AND ae.event_name = 'first_operation'
    WHERE p.created_at >= p_date_from
      AND p.created_at <= p_date_to
  )
  SELECT COALESCE(
    ROUND(activated_count::numeric / NULLIF(total_cohort, 0) * 100, 2),
    0
  ) INTO v_rate
  FROM cohort_counts;

  RETURN v_rate;
END;
$$;

-- ── get_admin_umv_rate ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_umv_rate(
  p_date_from timestamptz,
  p_date_to   timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN 0::numeric;
  END IF;

  -- Denominator: users who activated within the selected period.
  -- Numerator:   those same users who generated an insight at ANY point —
  --              no upper-bound date so users who activated on day 1 but
  --              reached UMV on day 8 are counted correctly.
  WITH activated AS (
    SELECT DISTINCT user_id FROM public.analytics_events
    WHERE event_name = 'first_operation'
      AND created_at >= p_date_from AND created_at <= p_date_to
  ),
  umv AS (
    SELECT DISTINCT ae.user_id
    FROM public.analytics_events ae
    INNER JOIN activated a ON ae.user_id = a.user_id
    WHERE ae.event_name = 'insight_generated'
    -- Intentionally no date filter: did the user EVER reach UMV after activating?
  )
  SELECT COALESCE(
    ROUND(
      ((SELECT COUNT(*) FROM umv)::numeric / NULLIF((SELECT COUNT(*) FROM activated), 0)) * 100,
      2
    ), 0
  ) INTO v_rate;

  RETURN v_rate;
END;
$$;

-- ── get_admin_paid_conversion_rate ────────────────────────────────────────────
-- Optional date params allow period-scoped cohort analysis (profiles registered
-- between p_date_from and p_date_to). When omitted, returns the all-time snapshot.
-- The old 0-param overload is dropped first to prevent signature ambiguity.
DROP FUNCTION IF EXISTS public.get_admin_paid_conversion_rate();

CREATE OR REPLACE FUNCTION public.get_admin_paid_conversion_rate(
  p_date_from timestamptz DEFAULT NULL,
  p_date_to   timestamptz DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- When dates are supplied: % of the registered cohort that is on 'pro' plan.
  -- When NULL: all-time snapshot across all profiles (original behavior).
  SELECT COALESCE(
    ROUND(
      (COUNT(*) FILTER (WHERE plan = 'pro')::numeric / NULLIF(COUNT(*), 0)) * 100,
      2
    ), 0
  ) INTO v_rate
  FROM public.profiles
  WHERE (p_date_from IS NULL OR created_at >= p_date_from)
    AND (p_date_to   IS NULL OR created_at <= p_date_to);

  RETURN v_rate;
END;
$$;

-- ── get_admin_community_interactions ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_community_interactions(
  p_date_from timestamptz,
  p_date_to   timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN 0::bigint;
  END IF;

  SELECT
    COALESCE((SELECT COUNT(*) FROM public.posts  WHERE created_at >= p_date_from AND created_at <= p_date_to), 0) +
    COALESCE((SELECT COUNT(*) FROM public.replies WHERE created_at >= p_date_from AND created_at <= p_date_to), 0)
  INTO v_total;

  RETURN v_total;
END;
$$;

-- ── get_admin_insights_breakdown ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_insights_breakdown(
  p_date_from timestamptz,
  p_date_to   timestamptz
)
RETURNS TABLE (insight_type text, total bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    LOWER(COALESCE(event_data->>'type', 'uncategorized')) AS insight_type,
    COUNT(*) AS total
  FROM public.analytics_events
  WHERE event_name = 'insight_generated'
    AND created_at >= p_date_from
    AND created_at <= p_date_to
  GROUP BY LOWER(COALESCE(event_data->>'type', 'uncategorized'))
  ORDER BY total DESC;
END;
$$;

-- =============================================================================
-- SECTION 3 — Explicit GRANT EXECUTE (defense against future permission changes)
-- =============================================================================

GRANT EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_dashboard_critical_stock()                                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_activation_rate(timestamptz, timestamptz)                       TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_umv_rate(timestamptz, timestamptz)                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_paid_conversion_rate(timestamptz, timestamptz)                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_community_interactions(timestamptz, timestamptz)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_insights_breakdown(timestamptz, timestamptz)                    TO authenticated;

-- =============================================================================
-- SECTION 4 — Performance: expression index for insights_breakdown GROUP BY
-- =============================================================================
-- get_admin_insights_breakdown groups by LOWER(event_data->>'type').
-- Without this index, each call does a seq scan + runtime LOWER() on every row.
-- The partial index (WHERE event_name = 'insight_generated') keeps it small.
CREATE INDEX IF NOT EXISTS idx_ae_insight_type_lower
  ON public.analytics_events (LOWER(event_data->>'type'))
  WHERE event_name = 'insight_generated';
