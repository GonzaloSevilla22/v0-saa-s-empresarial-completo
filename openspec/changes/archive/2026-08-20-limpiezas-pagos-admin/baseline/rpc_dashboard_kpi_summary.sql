CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(net_profit numeric, prev_net_profit numeric, avg_ticket numeric, prev_avg_ticket numeric, cost_per_sale numeric, prev_cost_per_sale numeric, stagnant_stock_value numeric, stagnant_stock_count integer, prev_stagnant_stock_value numeric, prev_stagnant_stock_count integer, sales_count integer, prev_sales_count integer, invoiced_revenue numeric, prev_invoiced_revenue numeric, collected_revenue numeric, prev_collected_revenue numeric)
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

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      -- v3-snapshot-pattern (D6): COGS = snapshot congelado (via sale_items),
      -- fallback a pr.cost actual solo si la línea no tiene snapshot.
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D1, grupo 6): la regla de NC —incluida la
  -- atribución de sucursal— vive en el helper único (D5) consumido también
  -- por get_dashboard_financials. p_branch_id ahora SÍ filtra (helper
  -- reescrito en esta migración).
  nc_agg AS (
    SELECT
      public.reporting_credit_notes_in_window(v_account_id, p_from,      p_to,      p_branch_id) AS nc,
      public.reporting_credit_notes_in_window(v_account_id, p_prev_from, p_prev_to, p_branch_id) AS prev_nc
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cargos a cuenta corriente del período. SIGUEN sin filtrar por sucursal
  -- (nivel cuenta) — no son la causa de collected_revenue = NULL bajo
  -- filtro, pero tampoco se filtran: ver el CASE del SELECT final.
  charges_agg AS (
    SELECT
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_from      AND p_to),      0) AS charges,
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_charges
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'sale'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cobros del período. payments_received no tiene sucursal atribuible
  -- (reference_sale_id opcional y en la práctica NULL) — no filtrable.
  payments_agg AS (
    SELECT
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_from      AND p_to),      0) AS payments,
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_payments
    FROM public.payments_received pr_
    WHERE pr_.account_id = v_account_id
      AND pr_.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D3, grupo 5): stock sin rotación por sucursal
  -- sobre branch_stock. Sin cambios en esta migración.
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_from AND p_to
          -- kpi-branch-consistency (D4): fail-open sobre ventas legacy sin
          -- sucursal. 75% de las filas de `sales` en producción tienen
          -- branch_id NULL (medido 2026-08-11) — una venta legacy es
          -- evidencia REAL de rotación y no se puede duplicar (EXISTS, no
          -- SUM); fail-closed marcaría como "sin rotación" a casi todo el
          -- catálogo apenas se selecciona una sucursal.
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  )
  SELECT
    (sa.revenue - na.nc)      - (ea.expenses      + pa.purchases)       AS net_profit,
    (sa.prev_revenue - na.prev_nc) - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count,
    -- v3-reporting-invariants (RN-D3): devengado neto de NC, filtrado por
    -- sucursal (el helper ya atribuye — D1, grupo 6).
    (sa.revenue - na.nc)                                      AS invoiced_revenue,
    (sa.prev_revenue - na.prev_nc)                            AS prev_invoiced_revenue,
    -- kpi-branch-consistency (D2, grupo 6): collected_revenue no es
    -- computable por sucursal — payments_received no tiene branch_id
    -- atribuible (reference_sale_id opcional y en la práctica NULL), y
    -- percibido = devengado - cargos + cobros es una identidad cuyos tres
    -- términos deben vivir en el mismo universo. Bajo filtro de sucursal se
    -- declara NULL (requirement de filtro uniforme, reporting-invariants)
    -- en vez de mezclar un devengado filtrado con cargos/cobros de toda la
    -- cuenta. Sin filtro, comportamiento sin cambios.
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.revenue - na.nc) - ca.charges + pay.payments
    END                                                        AS collected_revenue,
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.prev_revenue - na.prev_nc) - ca.prev_charges + pay.prev_payments
    END                                                        AS prev_collected_revenue
  FROM sales_agg sa
  CROSS JOIN nc_agg        na
  CROSS JOIN charges_agg   ca
  CROSS JOIN payments_agg  pay
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$
;

