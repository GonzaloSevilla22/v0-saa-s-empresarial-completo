-- =============================================================================
-- CHANGE: cobranzas-panel (Etapa A del módulo de cobranzas)
-- Read-model agregado de cuentas por cobrar: rpc_receivables_report.
--
-- Una fila por cliente deudor del tenant (balance > 0, cliente no borrado) con
-- su saldo materializado y las antigüedades derivadas del ledger
-- customer_account_movements. Sólo lectura: no inserta, no actualiza, no borra,
-- no emite eventos. Sin DDL sobre tablas, sin índices nuevos (D12).
--
-- Molde: rpc_payment_method_report (20260928000001 §"reporte"): guard de
-- membresía P0401 como primera sentencia, SECURITY DEFINER, search_path fijado,
-- ACLs en el mismo archivo (DROP+CREATE resetea ACLs — gotcha conocido).
-- Idempotente: CREATE OR REPLACE + REVOKE/GRANT re-ejecutables (auto-apply de
-- Supabase GitHub reaplica el archivo).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_receivables_report(p_account_id uuid)
RETURNS TABLE(
    client_id               uuid,
    client_name             text,
    balance                 numeric,
    days_since_last_charge  integer,
    days_since_last_payment integer,
    last_payment_date       date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Guard de membresía (D1): primera sentencia, antes de leer dato alguno.
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH last_moves AS (
    -- D4: el cargo es EXCLUSIVAMENTE movement_type = 'sale' (credit_note
    -- revierte un cargo y adjustment es corrección manual — no cuentan);
    -- el cobro es EXCLUSIVAMENTE 'payment_received' (la reversa deshace un
    -- cobro — contarla rejuvenecería la deuda en pantalla).
    SELECT
      m.customer_account_id                                                 AS ca_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'sale')             AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_received') AS last_payment_at
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.customer_account_id
  )
  SELECT
    c.id       AS client_id,
    c.name     AS client_name,
    ca.balance AS balance,
    -- D4/RN-D5: día calendario argentino vía reporting_local_today(); nunca
    -- now()::date (UTC corre un día antes entre las 21:00 y las 00:00 ART).
    (public.reporting_local_today()
       - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (public.reporting_local_today()
       - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                AS last_payment_date
  FROM public.customer_accounts ca
  JOIN public.clients c ON c.id = ca.client_id
  LEFT JOIN last_moves lm ON lm.ca_id = ca.id
  -- D5: sólo deuda viva (balance > 0; el CHECK >= 0 garantiza que no hay
  -- saldos a favor) y sólo clientes vigentes (mismo criterio que /clientes).
  WHERE ca.account_id = p_account_id
    AND ca.balance > 0
    AND c.deleted_at IS NULL
  ORDER BY ca.balance DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_receivables_report(uuid) IS
    'cobranzas-panel: read-model agregado de cuentas por cobrar (una fila por '
    'cliente deudor del tenant, saldo materializado de customer_accounts). '
    'D4: days_since_last_charge sólo cuenta movement_type=sale (credit_note y '
    'adjustment NO son cargo); days_since_last_payment sólo payment_received '
    '(payment_received_reversal NO rejuvenece); días en calendario argentino '
    'vía reporting_local_today(). D5: excluye balance = 0 y clientes con '
    'deleted_at (mismo criterio que /clientes) — un deudor con cliente borrado '
    'queda invisible, decisión declarada. Sólo lectura; guard de membresía '
    'P0401 como primera sentencia.';

-- =============================================================================
-- ACLs — exigido por el gate supabase/tests/test_function_acl_gate.sql
--     (revocar anon explícitamente; REVOKE FROM PUBLIC no alcanza).
-- =============================================================================
REVOKE ALL     ON FUNCTION public.rpc_receivables_report(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_receivables_report(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_receivables_report(uuid) TO authenticated;

-- =============================================================================
-- Gate de introspección (corre SIEMPRE, también en prod).
-- =============================================================================
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname = 'rpc_receivables_report';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_receivables_report no existe tras la migración.';
  END IF;

  IF position('P0401' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_receivables_report no rechaza no miembros con P0401.';
  END IF;

  IF position('reporting_local_today' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_receivables_report no ancla los días a reporting_local_today() (RN-D5).';
  END IF;

  IF position('movement_type = ''sale''' in v_def) = 0
     OR position('movement_type = ''payment_received''' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_receivables_report debe derivar las antigüedades sólo de sale / payment_received (D4).';
  END IF;

  IF position('deleted_at IS NULL' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_receivables_report no excluye clientes dados de baja (D5).';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: rpc_receivables_report con guard P0401, D4 y D5.';
END $$;
