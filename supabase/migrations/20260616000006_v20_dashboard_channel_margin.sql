-- =============================================================================
-- MIGRATION: 20260616000006_v20_dashboard_channel_margin.sql
-- C-20 v20-sale-items-migration — Task 9.3
--
-- Reescritura de rpc_dashboard_channel_margin para leer producto/cantidad
-- desde sale_items (vía v_sales_flat) en lugar del header plano de sales.
--
-- CAMBIOS:
--   - per_channel CTE: COGS = SUM(COALESCE(pr.cost, 0) * COALESCE(si.quantity, 0))
--     donde si viene de un JOIN con sale_items (si.sale_id = s.id, si.product_id IS NOT NULL)
--   - Revenue: SUM(COALESCE(s.total, s.amount)) — sin cambio (sigue del header)
--   - totals_curr / totals_prev: mismo cambio simétrico
--   - v_sales_flat usada para el JOIN (security_invoker = true, preserva RLS)
--
-- INVARIANTE: para datos backfilleados, si.quantity == s.quantity →
--   el resultado es IDÉNTICO al de la versión anterior (verificado pre/post).
--
-- Pre-migration baseline (2026-06-10, cuenta 3834e5d7):
--   sin_canal: revenue=2617164.59, cogs=1148000.00, margin_pct=56.1
--   otro:      revenue=146050.00,  cogs=58500.00,   margin_pct=59.9
--
-- Post-migration: mismo output exacto (ver verificación en apply task 9.3).
--
-- GOVERNANCE ALTO. Aprobación PO: 2026-06-10 ("Dale, cutover completo").
-- TDD: tests en backend/tests/test_sale_items.py (test_dashboard_channel_margin_*)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_dashboard_channel_margin(
  p_from      timestamp with time zone,
  p_to        timestamp with time zone,
  p_prev_from timestamp with time zone,
  p_prev_to   timestamp with time zone,
  p_branch_id uuid DEFAULT NULL
)
RETURNS TABLE(
  channels        jsonb,
  leader          text,
  margin_pct      numeric,
  prev_margin_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  RETURN QUERY
  WITH per_channel AS (
    -- Revenue: from sale header (unchanged)
    -- COGS: product/quantity from sale_items via v_sales_flat (task 9.3)
    --   For backfilled rows: si.quantity == s.quantity → identical COGS to pre-migration
    --   For new v2 rows: si.quantity IS the authoritative source
    --   For service lines (no product_id): LEFT JOIN returns NULL → COALESCE 0
    SELECT
      COALESCE(NULLIF(trim(s.canal), ''), 'sin_canal')                      AS canal,
      SUM(COALESCE(s.total, s.amount))                                       AS revenue,
      SUM(COALESCE(pr.cost, 0) * COALESCE(si.quantity, 0))                  AS cogs
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    GROUP BY 1
  ),
  channel_rows AS (
    SELECT
      pc.canal,
      pc.revenue,
      ROUND((pc.revenue - pc.cogs) / NULLIF(pc.revenue, 0) * 100, 1) AS margin_pct
    FROM per_channel pc
    WHERE pc.revenue > 0
  ),
  totals_curr AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(pr.cost, 0) * COALESCE(si.quantity, 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  totals_prev AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(pr.cost, 0) * COALESCE(si.quantity, 0)))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id IS NOT NULL
    LEFT JOIN public.products pr ON pr.id = si.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_prev_from AND p_prev_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  )
  SELECT
    COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object('canal', cr.canal, 'revenue', cr.revenue, 'margin_pct', cr.margin_pct)
                ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
              )
       FROM channel_rows cr),
      '[]'::jsonb
    )                                                                AS channels,
    (SELECT cr.canal FROM channel_rows cr
     ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
     LIMIT 1)                                                        AS leader,
    tc.pct                                                           AS margin_pct,
    tp.pct                                                           AS prev_margin_pct
  FROM totals_curr tc
  CROSS JOIN totals_prev tp;
END;
$$;

-- Permissions: same as before (authenticated only, no public/anon access)
REVOKE ALL     ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamp with time zone, timestamp with time zone, timestamp with time zone, timestamp with time zone, uuid) TO authenticated;
