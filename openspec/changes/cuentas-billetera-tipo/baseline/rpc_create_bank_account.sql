-- Baseline VIVO de public.rpc_create_bank_account, capturado por
-- pg_get_functiondef(p.oid) contra prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-22,
-- ANTES de este change (cuentas-billetera-tipo, task 1.2).
--
-- MAX(version) en supabase_migrations.schema_migrations verificado en el
-- mismo momento = 20261006000001 (256 migraciones) — la migración nueva de
-- este change se numera 20261007000001.
--
-- Regla del proyecto: toda reescritura de RPC parte de la definición VIVA
-- (no del archivo de migración histórico 20260804000002_bank_account_ledger.sql,
-- que puede no coincidir con lo que corre hoy en prod). Este archivo es esa
-- fuente de verdad para la task 3.4 (DROP + CREATE con p_account_kind 8º
-- parámetro).

CREATE OR REPLACE FUNCTION public.rpc_create_bank_account(p_name text, p_bank_name text DEFAULT NULL::text, p_cbu text DEFAULT NULL::text, p_alias text DEFAULT NULL::text, p_currency text DEFAULT 'ARS'::text, p_opening_balance numeric DEFAULT 0, p_opening_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id      uuid;
  v_bank_account_id uuid;
BEGIN
  -- Resolver account_id de la sesión (misma mecánica que C-30)
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard D5: solo escritores autorizados
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar CBU (D7): cuando se provee, debe ser exactamente 22 dígitos numéricos
  IF p_cbu IS NOT NULL AND p_cbu !~ '^[0-9]{22}$' THEN
    RAISE EXCEPTION 'cbu_invalido: el CBU debe tener exactamente 22 dígitos numéricos, recibido: %', p_cbu
      USING ERRCODE = 'P0411';
  END IF;

  -- Validar nombre requerido
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required: el nombre de la cuenta es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  -- INSERT de la cuenta bancaria
  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, cbu, alias, currency, opening_balance, opening_date)
  VALUES
    (v_account_id, trim(p_name), p_bank_name, p_cbu, p_alias,
     COALESCE(p_currency, 'ARS'), COALESCE(p_opening_balance, 0), p_opening_date)
  RETURNING id INTO v_bank_account_id;

  RETURN jsonb_build_object(
    'bank_account_id',  v_bank_account_id,
    'account_id',       v_account_id,
    'name',             trim(p_name),
    'currency',         COALESCE(p_currency, 'ARS'),
    'opening_balance',  COALESCE(p_opening_balance, 0),
    'is_active',        true
  );
END;
$function$
