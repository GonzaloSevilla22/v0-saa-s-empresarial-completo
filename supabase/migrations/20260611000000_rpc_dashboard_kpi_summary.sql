-- =============================================================================
-- MIGRATION: 20260611000000_rpc_dashboard_kpi_summary.sql
-- Bloque Resumen KPI (Fase A) — change: dashboard-kpi-summary-block
--
-- Un solo RPC agregador devuelve 4 KPIs mensuales del período actual Y del
-- período anterior (para el badge de variación) en una llamada:
--   - net_profit      = SUM(sales.total) − (SUM(expenses.amount) + SUM(purchases.total))
--   - avg_ticket      = ingreso / nº operaciones de venta
--   - cost_per_sale   = COGS / nº operaciones (COGS = products.cost * sales.quantity;
--                       decisión del usuario 2026-06-08: COGS, no costo operativo)
--   - stagnant stock  = productos con stock y SIN ventas en el período
--                       (excluye untracked / variant_only)
--
-- Convenciones del proyecto:
--   - SUM(COALESCE(total, amount)): total = línea (amount*qty); amount = precio
--     unitario (filas legacy sin total caen al fallback).
--   - Operación de venta = COALESCE(operation_id, id): filas legacy sin
--     operation_id cuentan como una operación cada una.
--   - Scope SIEMPRE por account_id (C-05); gate auth.uid(); SECURITY DEFINER.
--   - "Margen por Canal" NO está acá: llega en Fase B (campo sales.canal,
--     governance HIGH) — la tarjeta muestra "—" mientras tanto.
--
-- Limitaciones documentadas (v1):
--   - p_branch_id filtra ventas/gastos/compras; el stock sin rotación es global
--     de la cuenta (no hay snapshot histórico de stock por sucursal).
--   - El stock sin rotación del período ANTERIOR usa el stock ACTUAL del
--     producto (no hay snapshot histórico): la comparación es por rotación,
--     no por valor histórico exacto.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(
  p_from       timestamptz,
  p_to         timestamptz,
  p_prev_from  timestamptz,
  p_prev_to    timestamptz,
  p_branch_id  uuid DEFAULT NULL
)
RETURNS TABLE (
  net_profit                 numeric,
  prev_net_profit            numeric,
  avg_ticket                 numeric,
  prev_avg_ticket            numeric,
  cost_per_sale              numeric,
  prev_cost_per_sale         numeric,
  stagnant_stock_value       numeric,
  stagnant_stock_count       integer,
  prev_stagnant_stock_value  numeric,
  prev_stagnant_stock_count  integer,
  sales_count                integer,
  prev_sales_count           integer
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
      COALESCE(SUM(COALESCE(pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
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
  -- Stock sin rotación: productos vendibles con stock, sin líneas de venta en la ventana.
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.products p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_from AND p_to
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.products p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
      )
  )
  SELECT
    sa.revenue      - (ea.expenses      + pa.purchases)       AS net_profit,
    sa.prev_revenue - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count
  FROM sales_agg sa
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) TO authenticated;
