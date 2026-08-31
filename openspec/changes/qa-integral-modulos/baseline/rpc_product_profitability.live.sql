CREATE OR REPLACE FUNCTION public.rpc_product_profitability(p_period_days integer DEFAULT 30)
 RETURNS TABLE(product_id uuid, product_name text, total_revenue numeric, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, units_sold numeric, last_sale_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        UUID;
  v_account_id UUID;
  v_since_date DATE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Derive the caller's active account (C-05 D7 pattern)
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- v3-reporting-invariants (RN-D5): ancla a la fecha LOCAL del tenant, no a
  -- CURRENT_DATE (UTC del servidor) — evita que la ventana corra un día
  -- antes entre las 21:00 y las 00:00 hora Argentina.
  v_since_date := public.reporting_local_today() - (p_period_days || ' days')::INTERVAL;

  -- v3-snapshot-pattern (D6, RN-D2): el costo por línea deriva del snapshot
  -- congelado en sale_items (unit_cost_snapshot), no del maestro actual.
  -- Cascada de fallback: (1) unit_cost_snapshot de la línea; (2) products.cost
  -- actual solo cuando el snapshot es NULL (líneas muy viejas no backfilleadas).
  -- CTEs avoid Cartesian product when aggregating two fact tables on the same key
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        s.product_id,
        -- v3-reporting-invariants (RN-D — revenue de línea consistente):
        -- COALESCE(total, amount), nunca amount solo (precio unitario).
        SUM(COALESCE(s.total, s.amount))                           AS total_revenue,
        SUM(s.quantity)                                            AS units_sold,
        MAX(s.date)                                                AS last_sale_date,
        SUM(COALESCE(si.unit_cost_snapshot, pr2.cost) * s.quantity) AS total_cost_snapshot,
        bool_or(si.unit_cost_snapshot IS NULL)                     AS any_missing_snapshot
      FROM   public.sales s
      JOIN   public.products pr2 ON pr2.id = s.product_id
      LEFT   JOIN public.sale_items si
             ON si.sale_id = s.id AND si.product_id = s.product_id
      WHERE  s.account_id   = v_account_id
        AND  s.product_id  IS NOT NULL
        AND  s.date        >= v_since_date
      GROUP  BY s.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    sa.total_cost_snapshot                                                    AS total_cost,
    sa.total_revenue - sa.total_cost_snapshot                                 AS gross_margin,
    ROUND(
      (sa.total_revenue - sa.total_cost_snapshot)
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$function$
