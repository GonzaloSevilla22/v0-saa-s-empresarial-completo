-- =============================================================================
-- GATE: test_cuentas_billetera_tipo.sql
-- CHANGE: cuentas-billetera-tipo (tasks 2.1-2.6 RED+GREEN, 3.1-3.7 RED+GREEN)
-- =============================================================================
--
-- Verifica, contra la DB resultante de TODAS las migraciones (incluida
-- 20261007000001_cuentas_billetera_tipo.sql):
--   (1) account_kind existe, NOT NULL, default 'bank'.
--   (2) el CHECK de dominio cerrado rechaza un valor fuera de ('bank','wallet').
--   (3) backfill: cada marca de la lista cerrada de D2 clasifica 'wallet';
--       "Banco Comodoro" (control negativo del falso positivo por subcadena
--       "modo") y una cuenta ambigua quedan 'bank'.
--   (4) idempotencia REAL: reaplicar el archivo de migración completo (\i,
--       dos veces sobre las filas sintéticas) no pisa una clasificación
--       corregida a mano en una fila que la heurística no alcanzó.
--   (5) rpc_create_bank_account acepta p_account_kind (8º parámetro) y lo
--       persiste; omitido, default 'bank'; fuera de dominio → P0414.
--   (6) anti-overload 42725: exactamente una firma de rpc_create_bank_account.
--   (7) ACLs: authenticated ejecuta, PUBLIC/anon no (DROP+CREATE resetea ACLs).
--
-- (4) reaplica el ARCHIVO REAL vía \i (sin duplicar la heurística de la
-- migración) — mismo principio que "Verify G1/G4 migrations are idempotent
-- on reapply" en KPI_Validation.yml, acá autocontenido en un solo gate.
-- \i resuelve rutas relativas al cwd del proceso psql (no del script que lo
-- invoca) — el mismo cwd (raíz del repo) que usa el `-f` de este archivo.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve cuenta (mismo patrón
-- que los demás gates de este archivo de tests), se emite NOTICE y no aborta.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _cbt_fixture (k text PRIMARY KEY, v uuid);
TRUNCATE _cbt_fixture;

-- ── Fase 0: anchor sintético + fixture de filas "prod-shaped" ────────────────
DO $$
DECLARE
  v_anchor_email text := 'cuentas-billetera-tipo-gate@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_account_id   uuid;
  v_id           uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Cuentas Billetera Tipo'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE CUENTAS-BILLETERA-TIPO: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO _cbt_fixture VALUES ('user_id', v_user_id), ('account_id', v_account_id);

  -- ── (1) Columna: NOT NULL + default 'bank' ─────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bank_accounts'
      AND column_name = 'account_kind' AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'GATE CBT FAILED (1a): bank_accounts.account_kind no existe o admite NULL.';
  END IF;

  INSERT INTO public.bank_accounts (account_id, name, currency)
  VALUES (v_account_id, '__cbt_default__', 'ARS')
  RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('default_row', v_id);

  IF (SELECT account_kind FROM public.bank_accounts WHERE id = v_id) <> 'bank' THEN
    RAISE EXCEPTION 'GATE CBT FAILED (1b): una fila creada sin account_kind explícito debería quedar en default ''bank''.';
  END IF;
  RAISE NOTICE 'PASS (1): account_kind es NOT NULL con default ''bank''.';

  -- ── (2) CHECK rechaza dominio inválido ─────────────────────────────────
  BEGIN
    INSERT INTO public.bank_accounts (account_id, name, currency, account_kind)
    VALUES (v_account_id, '__cbt_invalid__', 'ARS', 'crypto');
    RAISE EXCEPTION 'GATE CBT FAILED (2): el CHECK debía rechazar account_kind=''crypto'' y no lo hizo.';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'PASS (2): el CHECK de tabla rechaza account_kind fuera de (''bank'',''wallet'').';
  END;

  -- ── Fixture (3): una fila por marca de la lista cerrada + control negativo
  -- + una fila AMBIGUA que ningún patrón alcanza (usada en (4), idempotencia).
  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency) VALUES
    (v_account_id, '__cbt_mp__',            NULL,            'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('mp', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_mercadopago__', 'mercado pago', 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('mercadopago', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_naranjax__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('naranjax', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_uala__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('uala', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_personalpay__', 'Personal Pay', 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('personalpay', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_brubank__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('brubank', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_lemon__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('lemon', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_belo__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('belo', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_prex__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('prex', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_cuentadni__', 'Cuenta DNI', 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('cuentadni', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_bnamas__', 'BNA+', 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('bnamas', v_id);

  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_modo__', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('modo', v_id);

  -- Control negativo: "modo" es subcadena de "Comodoro" pero NO token completo.
  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, 'Banco Comodoro', NULL, 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('comodoro', v_id);

  -- Ambigua: ningún patrón de la lista cerrada la alcanza — queda 'bank' tras
  -- el primer reapply; en (4) se corrige A MANO a 'wallet' y debe sobrevivir
  -- un segundo reapply.
  INSERT INTO public.bank_accounts (account_id, name, bank_name, currency)
  VALUES (v_account_id, '__cbt_ambigua__', 'Banco Regional del Este', 'ARS') RETURNING id INTO v_id;
  INSERT INTO _cbt_fixture VALUES ('ambigua', v_id);

  RAISE NOTICE 'FIXTURE (3): % filas sintéticas creadas para el backfill.', 13;
END $$;

-- ── Fase 1: primer reapply — ejercita el backfill sobre el fixture ──────────
\i supabase/migrations/20261007000001_cuentas_billetera_tipo.sql

-- ── Fase 2: assert backfill + control negativo ───────────────────────────────
DO $$
DECLARE
  v_key  text;
  v_id   uuid;
  v_kind text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _cbt_fixture WHERE k = 'account_id') THEN
    RETURN; -- fase 0 degradó, nada que verificar
  END IF;

  FOREACH v_key IN ARRAY ARRAY[
    'mp','mercadopago','naranjax','uala','personalpay','brubank','lemon','belo','prex','cuentadni','bnamas','modo'
  ]
  LOOP
    SELECT v INTO v_id FROM _cbt_fixture WHERE k = v_key;
    SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_id;
    IF v_kind <> 'wallet' THEN
      RAISE EXCEPTION 'GATE CBT FAILED (3): la fila "%" debía quedar account_kind=''wallet'' tras el backfill, quedó ''%''.', v_key, v_kind;
    END IF;
  END LOOP;

  SELECT v INTO v_id FROM _cbt_fixture WHERE k = 'comodoro';
  SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_id;
  IF v_kind <> 'bank' THEN
    RAISE EXCEPTION 'GATE CBT FAILED (3, control negativo): "Banco Comodoro" quedó ''%'' — el backfill clasificó por subcadena en vez de token completo (falso positivo de "modo").', v_kind;
  END IF;

  SELECT v INTO v_id FROM _cbt_fixture WHERE k = 'ambigua';
  SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_id;
  IF v_kind <> 'bank' THEN
    RAISE EXCEPTION 'GATE CBT FAILED (3, ambigua): una cuenta sin marca reconocida debía quedar ''bank'' (default seguro), quedó ''%''.', v_kind;
  END IF;

  RAISE NOTICE 'PASS (3): 12/12 marcas de la lista cerrada → wallet; "Banco Comodoro" y la cuenta ambigua → bank.';
END $$;

-- ── Fase 3: corrección manual de la fila ambigua (simula un admin) ──────────
DO $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _cbt_fixture WHERE k = 'account_id') THEN
    RETURN;
  END IF;

  SELECT v INTO v_id FROM _cbt_fixture WHERE k = 'ambigua';
  UPDATE public.bank_accounts SET account_kind = 'wallet' WHERE id = v_id;
END $$;

-- ── Fase 4: segundo reapply — idempotencia real del archivo completo ────────
\i supabase/migrations/20261007000001_cuentas_billetera_tipo.sql

-- ── Fase 5: assert idempotencia ──────────────────────────────────────────────
DO $$
DECLARE
  v_id   uuid;
  v_kind text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _cbt_fixture WHERE k = 'account_id') THEN
    RETURN;
  END IF;

  SELECT v INTO v_id FROM _cbt_fixture WHERE k = 'ambigua';
  SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_id;
  IF v_kind <> 'wallet' THEN
    RAISE EXCEPTION 'GATE CBT FAILED (4): reaplicar la migración pisó una clasificación corregida a mano (esperaba ''wallet'', quedó ''%'').', v_kind;
  END IF;

  SELECT v INTO v_id FROM _cbt_fixture WHERE k = 'comodoro';
  SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_id;
  IF v_kind <> 'bank' THEN
    RAISE EXCEPTION 'GATE CBT FAILED (4b): "Banco Comodoro" cambió de clasificación tras el segundo reapply (quedó ''%'').', v_kind;
  END IF;

  RAISE NOTICE 'PASS (4): reaplicar el archivo completo de migración (2 veces) es idempotente — la corrección manual de la fila ambigua sobrevive.';
END $$;

-- ── Fase 6: RPC — p_account_kind (8º param), default, dominio inválido ──────
DO $$
DECLARE
  v_user_id    uuid;
  v_account_id uuid;
  v_result     jsonb;
  v_new_id     uuid;
  v_kind       text;
  v_caught     boolean := false;
  v_count      integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _cbt_fixture WHERE k = 'account_id') THEN
    RETURN;
  END IF;

  SELECT v INTO v_user_id    FROM _cbt_fixture WHERE k = 'user_id';
  SELECT v INTO v_account_id FROM _cbt_fixture WHERE k = 'account_id';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE CUENTAS-BILLETERA-TIPO: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los casos de RPC, degradando sin abortar.';
  ELSE
    -- ── (5a) p_account_kind='wallet' explícito se persiste ─────────────────
    SELECT public.rpc_create_bank_account('__cbt_rpc_wallet__', NULL, NULL, NULL, 'ARS', 0, NULL, 'wallet') INTO v_result;
    v_new_id := (v_result->>'bank_account_id')::uuid;
    SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_new_id;
    IF v_kind <> 'wallet' THEN
      RAISE EXCEPTION 'GATE CBT FAILED (5a): rpc_create_bank_account con p_account_kind=''wallet'' persistió ''%''.', v_kind;
    END IF;
    IF v_result->>'account_kind' <> 'wallet' THEN
      RAISE EXCEPTION 'GATE CBT FAILED (5a-jsonb): el jsonb de retorno no incluye account_kind=''wallet'' (incluye: %).', v_result;
    END IF;

    -- ── (5b) omitido / llamada posicional de 7 args → default 'bank' ───────
    SELECT public.rpc_create_bank_account('__cbt_rpc_default__', NULL, NULL, NULL, 'ARS', 0, NULL) INTO v_result;
    v_new_id := (v_result->>'bank_account_id')::uuid;
    SELECT account_kind INTO v_kind FROM public.bank_accounts WHERE id = v_new_id;
    IF v_kind <> 'bank' THEN
      RAISE EXCEPTION 'GATE CBT FAILED (5b): rpc_create_bank_account llamada con 7 args (sin p_account_kind) debía persistir ''bank'', persistió ''%''. (ventana de despliegue: la llamada posicional vieja no debe romperse)', v_kind;
    END IF;

    -- ── (5c) dominio inválido → P0414, sin insertar fila ────────────────────
    SELECT count(*) INTO v_count FROM public.bank_accounts WHERE account_id = v_account_id;
    BEGIN
      PERFORM public.rpc_create_bank_account('__cbt_rpc_invalid__', NULL, NULL, NULL, 'ARS', 0, NULL, 'crypto');
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0414' THEN
          v_caught := true;
        ELSE
          RAISE EXCEPTION 'GATE CBT FAILED (5c): esperaba SQLSTATE P0414 para account_kind inválido, recibido % (%).', SQLSTATE, SQLERRM;
        END IF;
    END;
    IF NOT v_caught THEN
      RAISE EXCEPTION 'GATE CBT FAILED (5c): rpc_create_bank_account aceptó p_account_kind=''crypto'' sin rechazarlo.';
    END IF;
    IF (SELECT count(*) FROM public.bank_accounts WHERE account_id = v_account_id) <> v_count THEN
      RAISE EXCEPTION 'GATE CBT FAILED (5c): el rechazo P0414 insertó una fila de todos modos.';
    END IF;

    RAISE NOTICE 'PASS (5): p_account_kind persiste (''wallet'' explícito, ''bank'' por default, ''crypto'' → P0414 sin insertar).';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- ── Fase 7: anti-overload 42725 — exactamente una firma ─────────────────────
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_bank_account';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CBT FAILED (6, 42725): esperaba 1 firma de rpc_create_bank_account, hay % (overload ambiguo — ¿faltó el DROP FUNCTION de la firma de 7 args?).', v_count;
  END IF;

  RAISE NOTICE 'PASS (6): una sola firma de rpc_create_bank_account (sin overload 42725).';
END $$;

-- ── Fase 8: ACLs — authenticated sí, PUBLIC/anon no ──────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_create_bank_account'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE CBT FAILED (7a): authenticated no tiene EXECUTE sobre rpc_create_bank_account (¿faltó el GRANT tras el DROP+CREATE?).';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'rpc_create_bank_account'
        AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ) THEN
      RAISE EXCEPTION 'GATE CBT FAILED (7b): anon tiene EXECUTE sobre rpc_create_bank_account — el REVOKE no se re-emitió tras el DROP+CREATE.';
    END IF;
  END IF;

  RAISE NOTICE 'PASS (7): authenticated ejecuta rpc_create_bank_account; PUBLIC/anon no.';
END $$;

-- ── Fase 9: cleanup ───────────────────────────────────────────────────────────
DO $$
DECLARE
  v_user_id    uuid;
  v_account_id uuid;
BEGIN
  SELECT v INTO v_user_id    FROM _cbt_fixture WHERE k = 'user_id';
  SELECT v INTO v_account_id FROM _cbt_fixture WHERE k = 'account_id';

  IF v_account_id IS NOT NULL THEN
    -- Cubre las filas '__cbt_*' (fixture + RPC) y 'Banco Comodoro' (control
    -- negativo, nombre literal sin prefijo __cbt_).
    DELETE FROM public.bank_accounts
    WHERE account_id = v_account_id
      AND (name LIKE '\_\_cbt\_%' ESCAPE '\' OR name = 'Banco Comodoro');
  END IF;

  IF v_user_id IS NOT NULL THEN
    DELETE FROM public.account_members WHERE user_id = v_user_id;
    -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
    SET session_replication_role = replica;
    DELETE FROM public.accounts        WHERE owner_user_id = v_user_id;
    SET session_replication_role = DEFAULT;
    DELETE FROM public.profiles        WHERE id = v_user_id;
    DELETE FROM auth.users             WHERE id = v_user_id;
  END IF;

  RAISE NOTICE 'GATE CUENTAS-BILLETERA-TIPO: cleanup completo.';
END $$;

DROP TABLE IF EXISTS _cbt_fixture;
