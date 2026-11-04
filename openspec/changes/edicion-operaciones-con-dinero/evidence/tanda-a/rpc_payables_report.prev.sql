CREATE OR REPLACE FUNCTION public.rpc_payables_report(p_account_id uuid)
 RETURNS TABLE(supplier_id uuid, supplier_name text, balance numeric, days_since_last_charge integer, days_since_last_payment integer, last_payment_date date, overdue_total numeric, amount_current numeric, amount_overdue_1_30 numeric, amount_overdue_31_60 numeric, amount_overdue_60_plus numeric, amount_no_due_date numeric, oldest_due_date date, days_overdue_max integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D6): espejo TEXTUAL de rpc_receivables_report sobre
  supplier_accounts/suppliers — cargo = 'purchase' + 'adjustment' positivo;
  crédito = pagos/notas de débito/anulaciones con su signo. Mismas garantías:
  guard P0401 primera sentencia, invariante de cierre, día argentino,
  exclusión de balance = 0 y proveedores con deleted_at.
*/
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH today AS (
    SELECT public.reporting_local_today() AS d
  ),
  last_moves AS (
    SELECT
      m.supplier_account_id                                             AS sa_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'purchase')     AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_made') AS last_payment_at
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.supplier_account_id
  ),
  pool AS (
    SELECT m.supplier_account_id AS sa_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
      AND NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.supplier_account_id
  ),
  charges AS (
    SELECT m.supplier_account_id AS sa_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.supplier_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
      AND (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_items AS (
    SELECT ch.sa_id, ch.due_date,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.sa_id = ch.sa_id
  ),
  aging AS (
    SELECT oi.sa_id,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date <  t.d), 0) AS agg_overdue_total,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date >= t.d), 0) AS agg_current,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 1 AND 30), 0)  AS agg_1_30,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 31 AND 60), 0) AS agg_31_60,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) > 60), 0)              AS agg_60_plus,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NULL), 0)                                               AS agg_no_due,
      MIN(oi.due_date) FILTER (WHERE oi.open_amount > 0)                                    AS agg_oldest_due,
      MAX(t.d - oi.due_date) FILTER (WHERE oi.open_amount > 0 AND oi.due_date < t.d)        AS agg_days_max
    FROM open_items oi
    CROSS JOIN today t
    GROUP BY oi.sa_id
  )
  SELECT
    s.id       AS supplier_id,
    s.name     AS supplier_name,
    sa.balance AS balance,
    (t.d - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (t.d - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                  AS last_payment_date,
    COALESCE(ag.agg_overdue_total, 0) AS overdue_total,
    COALESCE(ag.agg_current, 0)       AS amount_current,
    COALESCE(ag.agg_1_30, 0)          AS amount_overdue_1_30,
    COALESCE(ag.agg_31_60, 0)         AS amount_overdue_31_60,
    COALESCE(ag.agg_60_plus, 0)       AS amount_overdue_60_plus,
    COALESCE(ag.agg_no_due, 0)        AS amount_no_due_date,
    ag.agg_oldest_due                 AS oldest_due_date,
    ag.agg_days_max::integer          AS days_overdue_max
  FROM public.supplier_accounts sa
  JOIN public.suppliers s ON s.id = sa.supplier_id
  LEFT JOIN last_moves lm ON lm.sa_id = sa.id
  LEFT JOIN aging ag ON ag.sa_id = sa.id
  CROSS JOIN today t
  WHERE sa.account_id = p_account_id
    AND sa.balance > 0
    AND s.deleted_at IS NULL
  ORDER BY sa.balance DESC;
END;
$function$

