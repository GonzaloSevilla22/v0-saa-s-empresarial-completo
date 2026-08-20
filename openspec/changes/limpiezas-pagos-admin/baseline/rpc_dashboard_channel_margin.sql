CREATE OR REPLACE FUNCTION public.rpc_dashboard_channel_margin(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(channels jsonb, leader text, margin_pct numeric, prev_margin_pct numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- v3-snapshot-pattern (D6): COGS = snapshot congelado, fallback a pr.cost
    -- actual solo si la línea no tiene snapshot (histórica no backfilleada).
    SELECT
      COALESCE(NULLIF(trim(s.canal), ''), 'sin_canal')                                          AS canal,
      SUM(COALESCE(s.total, s.amount))                                                           AS revenue,
      SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0))                AS cogs
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
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0)))
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
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * COALESCE(si.quantity, 0)))
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
$function$
;

