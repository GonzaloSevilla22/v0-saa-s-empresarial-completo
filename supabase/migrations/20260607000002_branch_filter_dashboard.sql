-- Add optional p_branch_id filter to get_dashboard_financials (C-07)
-- Drop old 2-param signature first to avoid overload ambiguity.

DROP FUNCTION IF EXISTS public.get_dashboard_financials(timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.get_dashboard_financials(
  p_date_from  timestamptz,
  p_date_to    timestamptz,
  p_branch_id  uuid DEFAULT NULL
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
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  gastos AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.expenses
    WHERE user_id = v_uid
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  compras AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.purchases
    WHERE user_id = v_uid
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  )
  SELECT
    i.total                         AS total_income,
    g.total                         AS total_expenses,
    c.total                         AS total_purchases,
    (i.total - (g.total + c.total)) AS net_profit
  FROM ingresos i
  CROSS JOIN gastos g
  CROSS JOIN compras c;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz, uuid) TO authenticated;
