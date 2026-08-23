-- =============================================================================
-- cuentas-billetera-tipo — distingue banco real de billetera virtual en
-- bank_accounts (account_kind), con backfill de las 8 filas existentes.
-- =============================================================================
--
-- Pedido textual del PO (2026-08-22): "aca deberia haber otra que sea agregar
-- billetera virtual no solo agregar banco para diferenciarlos". La foto de
-- prod confirma el problema: las 4 cuentas activas son billeteras (MP,
-- Mercado Pago, Naranja X, UALA) y ninguna es un banco real; 0 filas con cbu
-- cargado. Ver design.md (openspec/changes/cuentas-billetera-tipo/) D1-D6.
--
-- MAX(version) prod verificado 2026-08-22 (task 1.1): 20261006000001 → este
-- archivo usa 20261007000001. Baseline VIVO de rpc_create_bank_account
-- capturado por pg_get_functiondef en
-- openspec/changes/cuentas-billetera-tipo/baseline/rpc_create_bank_account.sql
-- (task 1.2) — esta migración parte de ahí, no del archivo histórico
-- 20260804000002_bank_account_ledger.sql.
--
-- Censo de ERRCODEs re-corrido 2026-08-22 (task 1.1): el design proponía
-- P0412 para "account_kind inválido", pero P0412 YA está tomado (bank_account
-- no encontrada/inactiva, rpc_update_bank_account / rpc_register_bank_movement,
-- 20260804000002). Libre y usado acá: P0414 (siguiente hueco del cluster
-- bank-account: 400/401/403/410/411/412/413 ocupados).
--
-- rpc_create_bank_account NO figura en la cadena de reapply de
-- .github/workflows/KPI_Validation.yml (task 1.3, verificado por grep sobre
-- el archivo completo) — ninguna actualización necesaria ahí.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS; CHECK con guarda por pg_constraint;
-- backfill acotado a WHERE account_kind = 'bank' (D2: no pisa una
-- clasificación ya corregida); DROP FUNCTION IF EXISTS + CREATE (firma nueva)
-- + REVOKE/GRANT explícito en el mismo archivo (DROP+CREATE resetea el ACL —
-- gotcha con múltiples antecedentes en el proyecto, cubierto por
-- supabase/tests/test_function_acl_gate.sql y test_cuentas_billetera_tipo.sql).

-- =============================================================================
-- 1. Columna account_kind + CHECK de dominio cerrado
-- =============================================================================

ALTER TABLE public.bank_accounts
  ADD COLUMN IF NOT EXISTS account_kind text NOT NULL DEFAULT 'bank';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.bank_accounts'::regclass
      AND conname = 'bank_accounts_account_kind_check'
  ) THEN
    ALTER TABLE public.bank_accounts
      ADD CONSTRAINT bank_accounts_account_kind_check
      CHECK (account_kind IN ('bank', 'wallet'));
  END IF;
END $$;

COMMENT ON COLUMN public.bank_accounts.account_kind IS
  'cuentas-billetera-tipo: banco real (''bank'', default) vs billetera virtual '
  '(''wallet''). Atributo DESCRIPTIVO — no altera tratamiento contable, saldos '
  'ni conciliación de ninguna cuenta. Backfill por heurística de nombre (D2) '
  'en la sección 2 de esta migración.';

-- =============================================================================
-- 2. Backfill — heurística de nombre por lista cerrada (D2)
-- =============================================================================
-- Prioriza el falso negativo sobre el falso positivo: solo marca 'wallet' ante
-- coincidencia con una marca conocida; toda cuenta ambigua queda 'bank' (el
-- default seguro, statu quo actual). Sobre lower(name) y lower(bank_name):
--   - subcadena para marcas largas sin ambigüedad real (mercado pago, uala,
--     naranja x, personal pay, brubank, cuenta dni, bna+/bna mas);
--   - frontera de TOKEN COMPLETO para siglas/palabras cortas ambiguas (mp,
--     modo, belo, prex, lemon) — "Banco Comodoro" contiene "modo" como
--     subcadena pero NO como token, y debe quedar 'bank' (control negativo,
--     test 2.2 / spec bank-account "Una sigla contenida...").
-- Acotado a WHERE account_kind = 'bank': reaplicar la migración no pisa una
-- clasificación ya corregida a mano (idempotencia, test 2.3). Incluye filas
-- con deleted_at no nulo (D2: mismas billeteras duplicadas soft-deleted).

UPDATE public.bank_accounts
SET account_kind = 'wallet'
WHERE account_kind = 'bank'
  AND (
    lower(name) ~ '(mercado pago|mercadopago|mercado libre|uala|ualá|naranja x|naranjax|naranja|personal pay|brubank|cuenta dni|bna\+|bna mas)'
    OR lower(COALESCE(bank_name, '')) ~ '(mercado pago|mercadopago|mercado libre|uala|ualá|naranja x|naranjax|naranja|personal pay|brubank|cuenta dni|bna\+|bna mas)'
    OR lower(name) ~ '(^|[^a-z0-9])(mp|modo|belo|prex|lemon)([^a-z0-9]|$)'
    OR lower(COALESCE(bank_name, '')) ~ '(^|[^a-z0-9])(mp|modo|belo|prex|lemon)([^a-z0-9]|$)'
  );

-- =============================================================================
-- 3. rpc_create_bank_account — 8º parámetro p_account_kind (DROP + CREATE)
-- =============================================================================
-- D4: CREATE OR REPLACE con una firma distinta CREA un overload (ambigüedad
-- 42725 en una llamada posicional de 7 argumentos) — se DROPea la firma
-- exacta de 7 args antes de crear la de 8. p_account_kind va ÚLTIMO con
-- DEFAULT 'bank': preserva la llamada posicional de 7 argumentos durante la
-- ventana de despliegue (el backend viejo sigue funcionando sin tocar).

-- DROP explícito de la firma VIEJA (7 args) evita el overload 42725 en la
-- PRIMERA aplicación (D4). CREATE OR REPLACE (no CREATE a secas) deja la
-- migración re-appliable: en una segunda pasada la firma NUEVA (8 args) ya
-- está viva, el DROP de arriba (7 args) es no-op, y OR REPLACE reemplaza esa
-- misma firma en vez de fallar con "already exists with same argument types".
DROP FUNCTION IF EXISTS public.rpc_create_bank_account(text, text, text, text, text, numeric, date);

CREATE OR REPLACE FUNCTION public.rpc_create_bank_account(
  p_name             text,
  p_bank_name        text DEFAULT NULL::text,
  p_cbu              text DEFAULT NULL::text,
  p_alias            text DEFAULT NULL::text,
  p_currency         text DEFAULT 'ARS'::text,
  p_opening_balance  numeric DEFAULT 0,
  p_opening_date     date DEFAULT NULL::date,
  p_account_kind     text DEFAULT 'bank'::text
)
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

  -- Validar CBU/CVU (D7 original; D3 de este change: cbu también rotula CVU
  -- para wallet — misma columna, misma validación de 22 dígitos)
  IF p_cbu IS NOT NULL AND p_cbu !~ '^[0-9]{22}$' THEN
    RAISE EXCEPTION 'cbu_invalido: el CBU debe tener exactamente 22 dígitos numéricos, recibido: %', p_cbu
      USING ERRCODE = 'P0411';
  END IF;

  -- Validar nombre requerido
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required: el nombre de la cuenta es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  -- cuentas-billetera-tipo (D1/D4): dominio cerrado de account_kind
  IF COALESCE(p_account_kind, 'bank') NOT IN ('bank', 'wallet') THEN
    RAISE EXCEPTION 'account_kind_invalido: el tipo de cuenta debe ser ''bank'' o ''wallet'', recibido: %', p_account_kind
      USING ERRCODE = 'P0414';
  END IF;

  -- INSERT de la cuenta bancaria
  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, cbu, alias, currency, opening_balance, opening_date, account_kind)
  VALUES
    (v_account_id, trim(p_name), p_bank_name, p_cbu, p_alias,
     COALESCE(p_currency, 'ARS'), COALESCE(p_opening_balance, 0), p_opening_date,
     COALESCE(p_account_kind, 'bank'))
  RETURNING id INTO v_bank_account_id;

  RETURN jsonb_build_object(
    'bank_account_id',  v_bank_account_id,
    'account_id',       v_account_id,
    'name',             trim(p_name),
    'currency',         COALESCE(p_currency, 'ARS'),
    'opening_balance',  COALESCE(p_opening_balance, 0),
    'account_kind',     COALESCE(p_account_kind, 'bank'),
    'is_active',        true
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) IS
  'cuentas-billetera-tipo: agrega p_account_kind (8º parámetro, DEFAULT ''bank'', '
  'dominio cerrado, ERRCODE P0414 si inválido). DROP+CREATE explícito de la '
  'firma de 7 args para evitar overload 42725 (D4). ACLs restituidas abajo — '
  'el DROP+CREATE resetea el default a EXECUTE-para-PUBLIC.';

-- D4: DROP+CREATE resetea las ACLs — restituir explícitamente en el mismo
-- archivo (gate: supabase/tests/test_function_acl_gate.sql).
REVOKE ALL ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date, text) TO authenticated;
