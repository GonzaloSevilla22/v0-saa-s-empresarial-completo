-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-23, vía
-- pg_get_functiondef(oid) — task 1.4 de cuenta-corriente-party-guard.
-- MAX(version) al momento de la captura: 20261007000001.
-- md5(pg_get_functiondef) = 4f36921a7e02316dc3b916eea5443797 · length = 680.

CREATE OR REPLACE FUNCTION public.c30_get_or_create_customer_account(p_account_id uuid, p_client_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  -- INSERT idempotente: ON CONFLICT (account_id, client_id) DO NOTHING
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (p_account_id, p_client_id, 0, auth.uid())
  ON CONFLICT (account_id, client_id) DO NOTHING;

  -- SELECT garantizado (fila ya existe o fue recién insertada)
  SELECT id INTO v_id
  FROM public.customer_accounts
  WHERE account_id = p_account_id AND client_id = p_client_id;

  RETURN v_id;
END;
$function$
