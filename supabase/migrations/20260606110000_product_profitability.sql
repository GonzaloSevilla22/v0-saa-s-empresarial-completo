-- C-11: RPC rpc_product_profitability — gross margin per SKU

CREATE OR REPLACE FUNCTION public.rpc_product_profitability(
  p_period_days INT DEFAULT 30
)
RETURNS TABLE (
  product_id       UUID,
  product_name     TEXT,
  total_revenue    NUMERIC,
  total_cost       NUMERIC,
  gross_margin     NUMERIC,
  gross_margin_pct NUMERIC,
  units_sold       NUMERIC,
  last_sale_date   DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  v_since_date := CURRENT_DATE - (p_period_days || ' days')::INTERVAL;

  -- CTEs avoid Cartesian product when aggregating two fact tables on the same key
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        s.product_id,
        SUM(s.amount)   AS total_revenue,
        SUM(s.quantity) AS units_sold,
        MAX(s.date)     AS last_sale_date
      FROM   public.sales s
      WHERE  s.account_id   = v_account_id
        AND  s.product_id  IS NOT NULL
        AND  s.date        >= v_since_date
      GROUP  BY s.product_id
    ),
    purchases_agg AS (
      SELECT
        pu.product_id,
        SUM(pu.amount) AS total_cost
      FROM   public.purchases pu
      WHERE  pu.account_id   = v_account_id
        AND  pu.product_id  IS NOT NULL
        AND  pu.date        >= v_since_date
      GROUP  BY pu.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    COALESCE(pa.total_cost, pr.cost * sa.units_sold)                          AS total_cost,
    sa.total_revenue - COALESCE(pa.total_cost, pr.cost * sa.units_sold)       AS gross_margin,
    ROUND(
      (sa.total_revenue - COALESCE(pa.total_cost, pr.cost * sa.units_sold))
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  LEFT   JOIN purchases_agg pa ON pa.product_id = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_product_profitability(INT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(INT) TO authenticated;
