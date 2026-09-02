CREATE OR REPLACE FUNCTION public.rpc_branch_report(p_account_id uuid, p_start date, p_end date)
 RETURNS TABLE(branch_id uuid, branch_name text, total_sales numeric, total_expenses numeric, operation_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    branch_sales AS (
      SELECT
        s.branch_id,
        -- RN-D — revenue de línea consistente: COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0) AS total_sales,
        -- RN-D — conteo de operaciones unificado: COALESCE(operation_id, id)
        -- para que las ventas legacy sin operation_id cuenten 1 c/u.
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT AS op_count
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.branch_id
    ),
    branch_expenses AS (
      SELECT
        e.branch_id,
        COALESCE(SUM(e.amount), 0) AS total_expenses
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        AND e.date >= p_start::timestamptz
        AND e.date <  (p_end + 1)::timestamptz
      GROUP BY e.branch_id
    ),
    all_branch_ids AS (
      SELECT DISTINCT branch_id FROM branch_sales
      UNION
      SELECT DISTINCT branch_id FROM branch_expenses
    )
  SELECT
    abi.branch_id,
    COALESCE(b.name, 'Sin sucursal')       AS branch_name,
    COALESCE(bs.total_sales, 0)            AS total_sales,
    COALESCE(be.total_expenses, 0)         AS total_expenses,
    COALESCE(bs.op_count, 0)              AS operation_count
  FROM all_branch_ids abi
  LEFT JOIN public.branches b  ON b.id = abi.branch_id
  LEFT JOIN branch_sales   bs  ON bs.branch_id IS NOT DISTINCT FROM abi.branch_id
  LEFT JOIN branch_expenses be ON be.branch_id IS NOT DISTINCT FROM abi.branch_id
  ORDER BY total_sales DESC NULLS LAST;
END;
$function$
