CREATE OR REPLACE FUNCTION public.rpc_receivables_report(p_account_id uuid)
 RETURNS TABLE(client_id uuid, client_name text, client_phone text, balance numeric, days_since_last_charge integer, days_since_last_payment integer, last_payment_date date, overdue_total numeric, amount_current numeric, amount_overdue_1_30 numeric, amount_overdue_31_60 numeric, amount_overdue_60_plus numeric, amount_no_due_date numeric, oldest_due_date date, days_overdue_max integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-panel (Etapa A) + cobranzas-vencimientos (Etapa B, D4/D5/D6):
  una fila por cliente deudor con el reparto de su saldo en cinco tramos,
  derivado FIFO por línea de flotación SIN materializar imputaciones:
    - cargos = movement_type 'sale' + 'adjustment' positivo, ordenados por
      (vencimiento o fecha local del posteo, created_at, id);
    - crédito disponible = suma NEGADA, con su propio signo, de todo lo demás
      (un cobro/nota suma crédito; una anulación de cobro lo RESTA — jamás es
      un cargo: rejuvenecería la mora);
    - abierto del cargo i = clamp(acumulado_i - crédito, 0, importe_i).
  Invariante de cierre: la suma de los 5 tramos = balance materializado.
  Clasificación (regla SEPARADA de la imputación, D5): sólo un cargo con
  vencimiento puede estar vencido; sin vencimiento = tramo propio, NUNCA se
  pliega a "al día". Día calendario argentino vía reporting_local_today().
*/
BEGIN
  -- Guard de membresía (D1 Etapa A): primera sentencia, antes de leer dato alguno.
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
    -- D4 Etapa A: el cargo es EXCLUSIVAMENTE movement_type = 'sale' para las
    -- antigüedades; el cobro es EXCLUSIVAMENTE 'payment_received'.
    SELECT
      m.customer_account_id                                                 AS ca_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'sale')             AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_received') AS last_payment_at
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.customer_account_id
  ),
  pool AS (
    SELECT m.customer_account_id AS ca_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
      AND NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.customer_account_id
  ),
  charges AS (
    SELECT m.customer_account_id AS ca_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.customer_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
      AND (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_items AS (
    SELECT ch.ca_id, ch.due_date,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.ca_id = ch.ca_id
  ),
  aging AS (
    SELECT oi.ca_id,
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
    GROUP BY oi.ca_id
  )
  SELECT
    c.id       AS client_id,
    c.name     AS client_name,
    -- cobranzas-vencimientos (D12): el recordatorio de WhatsApp de /cobranzas
    -- necesita el telefono del deudor — mismo dato que ya expone /clientes.
    c.phone    AS client_phone,
    ca.balance AS balance,
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
  FROM public.customer_accounts ca
  JOIN public.clients c ON c.id = ca.client_id
  LEFT JOIN last_moves lm ON lm.ca_id = ca.id
  LEFT JOIN aging ag ON ag.ca_id = ca.id
  CROSS JOIN today t
  -- D5 Etapa A: sólo deuda viva y clientes vigentes (mismo criterio que /clientes).
  WHERE ca.account_id = p_account_id
    AND ca.balance > 0
    AND c.deleted_at IS NULL
  ORDER BY ca.balance DESC;
END;
$function$

