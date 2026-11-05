CREATE OR REPLACE FUNCTION public._produce_receivables_overdue_digest()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D8/D9): UN aviso resumido por cuenta, por lado y
  por día calendario argentino, SOLO sobre lo VENCIDO (overdue_total > 0).
  La derivación FIFO es la misma línea de flotación de los read-models (D4);
  OQ-2 firmada: clientes/proveedores dados de baja EXCLUIDOS (mismo D5 de la
  Etapa A — el aviso no nombra partes que la aplicación no lista).
  Destinatario: el propietario de la cuenta (precedente PlanLimitExceeded).
  Solo lectura sobre los libros: no toca saldos, movimientos ni asientos.
*/
DECLARE
  n_recv  integer := 0;
  n_pay   integer := 0;
  v_today date := public.reporting_local_today();
BEGIN
  -- ── Lado POR COBRAR ────────────────────────────────────────────────────────
  WITH pool AS (
    SELECT m.customer_account_id AS ca_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.customer_account_id
  ),
  charges AS (
    SELECT m.customer_account_id AS ca_id, m.account_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.customer_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_overdue AS (
    SELECT ch.account_id, ch.ca_id,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.ca_id = ch.ca_id
    WHERE ch.due_date IS NOT NULL AND ch.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT ca.client_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.customer_accounts ca ON ca.id = oo.ca_id
    JOIN public.clients c ON c.id = ca.client_id
    WHERE ca.balance > 0 AND c.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (  -- D8 capa 2: dedup por día argentino, aunque cambien los importes
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'receivables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'receivables_overdue_digest', recipient,
           'Tenés deuda vencida por cobrar — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'ReceivablesOverdueDigest', 'ReceivablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_recv FROM ins_email;

  -- ── Lado POR PAGAR (espejo) ────────────────────────────────────────────────
  WITH pool AS (
    SELECT m.supplier_account_id AS sa_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.supplier_account_movements m
    WHERE NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.supplier_account_id
  ),
  charges AS (
    SELECT m.supplier_account_id AS sa_id, m.account_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.supplier_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.supplier_account_movements m
    WHERE (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_overdue AS (
    SELECT ch.account_id, ch.sa_id,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.sa_id = ch.sa_id
    WHERE ch.due_date IS NOT NULL AND ch.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT sa.supplier_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.supplier_accounts sa ON sa.id = oo.sa_id
    JOIN public.suppliers s ON s.id = sa.supplier_id
    WHERE sa.balance > 0 AND s.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'payables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'payables_overdue_digest', recipient,
           'Tenés deuda vencida con proveedores — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'PayablesOverdueDigest', 'PayablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_pay FROM ins_email;

  RETURN n_recv + n_pay;
END;
$function$

