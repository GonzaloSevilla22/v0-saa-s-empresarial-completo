-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-23, vía
-- pg_get_functiondef(oid) — task 1.4 de cuenta-corriente-party-guard.
-- MAX(version) al momento de la captura: 20261007000001.
-- md5(pg_get_functiondef) = 22d48ea02c6949f93c044c8a2f699c5d · length = 556.

CREATE OR REPLACE FUNCTION public.c30_get_or_create_supplier_account(p_account_id uuid, p_supplier_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance, created_by)
  VALUES (p_account_id, p_supplier_id, 0, auth.uid())
  ON CONFLICT (account_id, supplier_id) DO NOTHING;

  SELECT id INTO v_id
  FROM public.supplier_accounts
  WHERE account_id = p_account_id AND supplier_id = p_supplier_id;

  RETURN v_id;
END;
$function$
