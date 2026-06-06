-- C-12: RPC rpc_period_comparison — métricas comparativas entre dos períodos
-- Governance: MEDIO — nuevo RPC sin cambios de schema, datos existentes

CREATE OR REPLACE FUNCTION rpc_period_comparison(
  p_a_start DATE,
  p_a_end   DATE,
  p_b_start DATE,
  p_b_end   DATE
)
RETURNS TABLE (
  period_a_revenue      NUMERIC,
  period_a_expenses     NUMERIC,
  period_a_purchases    NUMERIC,
  period_a_operations   BIGINT,
  period_b_revenue      NUMERIC,
  period_b_expenses     NUMERIC,
  period_b_purchases    NUMERIC,
  period_b_operations   BIGINT,
  revenue_delta_pct     NUMERIC,
  expenses_delta_pct    NUMERIC,
  purchases_delta_pct   NUMERIC,
  operations_delta_pct  NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_accounts UUID[];
BEGIN
  v_accounts := ARRAY(SELECT current_account_ids());

  IF array_length(v_accounts, 1) IS NULL THEN
    RAISE EXCEPTION 'No active account found for this user'
      USING ERRCODE = 'P0403';
  END IF;

  RETURN QUERY
  WITH
    -- Período A
    sales_a AS (
      SELECT
        COALESCE(SUM(s.amount), 0) AS rev,
        COUNT(*)::BIGINT            AS ops
      FROM sales s
      WHERE s.account_id = ANY(v_accounts)
        AND s.date BETWEEN p_a_start AND p_a_end
    ),
    expenses_a AS (
      SELECT
        COALESCE(SUM(e.amount), 0) AS exp,
        COUNT(*)::BIGINT            AS ops
      FROM expenses e
      WHERE e.account_id = ANY(v_accounts)
        AND e.date BETWEEN p_a_start AND p_a_end
    ),
    purchases_a AS (
      SELECT
        COALESCE(SUM(p.amount), 0) AS pur,
        COUNT(*)::BIGINT            AS ops
      FROM purchases p
      WHERE p.account_id = ANY(v_accounts)
        AND p.date BETWEEN p_a_start AND p_a_end
    ),

    -- Período B
    sales_b AS (
      SELECT
        COALESCE(SUM(s.amount), 0) AS rev,
        COUNT(*)::BIGINT            AS ops
      FROM sales s
      WHERE s.account_id = ANY(v_accounts)
        AND s.date BETWEEN p_b_start AND p_b_end
    ),
    expenses_b AS (
      SELECT
        COALESCE(SUM(e.amount), 0) AS exp,
        COUNT(*)::BIGINT            AS ops
      FROM expenses e
      WHERE e.account_id = ANY(v_accounts)
        AND e.date BETWEEN p_b_start AND p_b_end
    ),
    purchases_b AS (
      SELECT
        COALESCE(SUM(p.amount), 0) AS pur,
        COUNT(*)::BIGINT            AS ops
      FROM purchases p
      WHERE p.account_id = ANY(v_accounts)
        AND p.date BETWEEN p_b_start AND p_b_end
    )

  SELECT
    -- Totales período A
    sa.rev                                                          AS period_a_revenue,
    ea.exp                                                          AS period_a_expenses,
    pa.pur                                                          AS period_a_purchases,
    (sa.ops + ea.ops + pa.ops)                                      AS period_a_operations,
    -- Totales período B
    sb.rev                                                          AS period_b_revenue,
    eb.exp                                                          AS period_b_expenses,
    pb.pur                                                          AS period_b_purchases,
    (sb.ops + eb.ops + pb.ops)                                      AS period_b_operations,
    -- Deltas porcentuales (NULL si período A = 0)
    ROUND((sb.rev - sa.rev) / NULLIF(sa.rev, 0) * 100, 2)          AS revenue_delta_pct,
    ROUND((eb.exp - ea.exp) / NULLIF(ea.exp, 0) * 100, 2)          AS expenses_delta_pct,
    ROUND((pb.pur - pa.pur) / NULLIF(pa.pur, 0) * 100, 2)          AS purchases_delta_pct,
    ROUND(
      ((sb.ops + eb.ops + pb.ops)::NUMERIC - (sa.ops + ea.ops + pa.ops)::NUMERIC)
      / NULLIF((sa.ops + ea.ops + pa.ops)::NUMERIC, 0) * 100,
      2
    )                                                               AS operations_delta_pct
  FROM
    sales_a sa
    CROSS JOIN expenses_a ea
    CROSS JOIN purchases_a pa
    CROSS JOIN sales_b sb
    CROSS JOIN expenses_b eb
    CROSS JOIN purchases_b pb;
END;
$$;

REVOKE ALL ON FUNCTION rpc_period_comparison(DATE, DATE, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_period_comparison(DATE, DATE, DATE, DATE) TO authenticated;
