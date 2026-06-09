-- =============================================================================
-- MIGRATION: 20260610000001_fix_dashboard_financials_total_account.sql
-- Fix two reporting bugs in get_dashboard_financials, surfaced while debugging
-- the dashboard showing $0 for "Ventas / Gastos / Ganancia hoy".
--
-- BUG 1 — wrong column summed:
--   Operation inserts store amount = UNIT price and total = amount * quantity
--   (the line total). The RPC summed `amount`, undercounting every sale/purchase
--   with quantity > 1. Fix: sum COALESCE(total, amount) for sales & purchases.
--   (expenses have no quantity/total → keep amount.)
--
-- BUG 2 — stale user_id scoping:
--   After C-05 every operation row is sealed with account_id and RLS scopes by
--   account. This RPC was the lone holdout still filtering user_id = auth.uid(),
--   so a teammate's sales were invisible on the owner's dashboard. Fix: scope by
--   account_id IN (SELECT current_account_ids()). Verified safe in prod: 0 rows
--   have a NULL account_id (sales/purchases/expenses all fully backfilled).
--
-- NOTE: the "$0 today" SYMPTOM is fixed on the frontend (frontend/lib/date-range.ts):
--   the window was built from browser-local midnight (UTC-3 → 03:00Z) and pushed
--   every midnight-UTC row into the previous day's bucket. This migration makes
--   the figure CORRECT once the rows fall inside the window.
--
-- Signature unchanged → CREATE OR REPLACE, idempotent, safe to re-run.
-- =============================================================================

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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, 0::numeric;
    RETURN;
  END IF;

  RETURN QUERY
  WITH ingresos AS (
    SELECT COALESCE(SUM(COALESCE(total, amount)), 0) AS total
    FROM public.sales
    WHERE account_id IN (SELECT current_account_ids())
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  gastos AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.expenses
    WHERE account_id IN (SELECT current_account_ids())
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  compras AS (
    SELECT COALESCE(SUM(COALESCE(total, amount)), 0) AS total
    FROM public.purchases
    WHERE account_id IN (SELECT current_account_ids())
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
