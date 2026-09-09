-- =============================================================================
-- GATE: test_get_account_ids_for_user_guard.sql
-- CHANGE: get-account-ids-for-user-own-membership (candidato S3, h4 de
--         cuenta-corriente-party-guard, sign-off PO 2026-09-09)
-- =============================================================================
--
-- `get_account_ids_for_user(uuid)` es SECURITY DEFINER y, antes de
-- 20261037000001, devolvía la membresía de CUALQUIER user_id recibido por
-- parámetro sin compararlo contra auth.uid() — cualquier `authenticated` (o
-- `anon`) podía enumerar las cuentas de un tercero vía
-- `.rpc('get_account_ids_for_user', {p_user_id: <uuid ajeno>})`, bypasseando
-- la RLS de `account_members` porque la función es el propio helper que la
-- policy usa para NO recursar.
--
-- Este gate reproduce el mecanismo exacto de la policy
-- (`account_members_same_account_select`) y de `get_db_conn`
-- (`set_config('request.jwt.claims', ..., true)` + `SET LOCAL ROLE
-- authenticated`, mismo patrón que test_tenancy_rls_role.sql):
--
--   (1) Como A (SET LOCAL ROLE authenticated + claims de A):
--       get_account_ids_for_user(user_B) → CERO filas (RED antes de
--       20261037000001: devolvía la cuenta de B).
--   (2) Como A: get_account_ids_for_user(user_A) → la cuenta de A (control
--       positivo — el guard no sobre-bloquea el camino legítimo).
--   (3) La policy real: `SELECT * FROM account_members` como A devuelve SOLO
--       los miembros de A, ninguno de B (ejercita el ÚNICO caller vivo).
--   (4) Como `postgres` SIN claims (auth.uid() NULL): get_account_ids_for_user
--       (user_B) → CERO filas también (NULL IS NOT DISTINCT FROM user_B es
--       falso) — documenta que el backend nunca la llama sin sesión.
--   (5) Como `anon` (SET LOCAL ROLE anon, sin claims): get_account_ids_for_user
--       (user_B) → CERO filas, SIN ERROR (la función sigue siendo ejecutable
--       por anon — la allowlist de test_function_acl_gate.sql (2) no cambia).
--
-- Degrade-don't-fail: si el anchor sintético no resuelve cuenta (mismo
-- criterio que test_tenancy_rls_role.sql), o si el entorno no replica el
-- GRANT base de `authenticated`/`anon` sobre `account_members` (permission
-- denied, no RLS), el gate emite NOTICE y no aborta. Sólo una fuga de
-- membresía ajena hace fallar el gate.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_anchor_a_email text := 'get-account-ids-guard-a@test.local';
  v_anchor_b_email text := 'get-account-ids-guard-b@test.local';
  v_user_a         uuid := gen_random_uuid();
  v_user_b         uuid := gen_random_uuid();
  v_account_a      uuid;
  v_account_b      uuid;

  v_degraded       boolean := false;
  v_leak           boolean := false;
  v_count          integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate GetAccountIds A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate GetAccountIds B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD: no se pudo resolver cuenta para los anchors sintéticos — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── (4) Como postgres, SIN ningún claim seteado todavía (auth.uid() NULL) ──
  -- Va PRIMERO: request.jwt.claims es transaction-scoped (set_config con
  -- is_local=true), así que una vez fijado para A más abajo persistiría el
  -- resto de esta transacción si no se testeara antes.
  SELECT count(*) INTO v_count FROM public.get_account_ids_for_user(v_user_b);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD FAILED (4): como postgres sin claims (auth.uid() NULL), get_account_ids_for_user(user_B) devolvió % filas — debía devolver 0 (NULL IS NOT DISTINCT FROM user_B es falso).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4): sin sesión (auth.uid() NULL), get_account_ids_for_user(user_B) devuelve 0 filas.';

  -- ── Impersonar A con RLS real: claims + SET LOCAL ROLE authenticated ──────
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
      -- (1) A pide la membresía de B → CERO filas (RED antes del fix).
      SELECT count(*) INTO v_count FROM public.get_account_ids_for_user(v_user_b);
      IF v_count <> 0 THEN
        v_leak := true;
        RAISE NOTICE 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD (1): get_account_ids_for_user(user_B) devolvió % filas siendo A — fuga de membresía ajena.', v_count;
      END IF;

      -- (2) Control positivo: A pide su propia membresía → la cuenta de A.
      SELECT count(*) INTO v_count
      FROM public.get_account_ids_for_user(v_user_a) AS gaifu(account_id)
      WHERE gaifu.account_id = v_account_a;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD FAILED (2, control positivo): get_account_ids_for_user(user_A) no devolvió la cuenta de A bajo RLS real (%). El guard no debe sobre-bloquear el camino legítimo.', v_count;
      END IF;

      -- (3) La policy real: SELECT sobre account_members como A no ve las
      --     filas de B (ejercita el ÚNICO caller vivo de la función).
      IF EXISTS (SELECT 1 FROM public.account_members WHERE account_id = v_account_b) THEN
        v_leak := true;
        RAISE NOTICE 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD (3): la policy account_members_same_account_select dejó ver una fila de la cuenta B siendo A.';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE account_id = v_account_a AND user_id = v_user_a) THEN
        RAISE EXCEPTION 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD FAILED (3, control positivo): la policy no dejó ver a A su propia fila de membresía.';
      END IF;
    EXCEPTION
      WHEN insufficient_privilege THEN
        IF SQLERRM LIKE 'permission denied for table%' OR SQLERRM LIKE 'permission denied for function%' THEN
          v_degraded := true;
        ELSE
          RAISE;
        END IF;
    END;

    EXECUTE 'RESET ROLE';
    -- Reset explícito de los claims de A: son transaction-scoped, y (5)
    -- necesita simular anon SIN ningún claim de sesión previo.
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      RAISE;
  END;

  IF v_degraded THEN
    RAISE NOTICE 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD degradado en (1)-(3): el entorno no otorga el GRANT base de authenticated sobre account_members/get_account_ids_for_user (permission denied, no RLS) — omitido sin fallar.';
  ELSIF v_leak THEN
    RAISE EXCEPTION 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD FAILED: get_account_ids_for_user devolvió (o la policy dejó ver) membresía de la cuenta B a la cuenta A — guard de identidad roto.';
  ELSE
    RAISE NOTICE 'PASS (1)-(3): get_account_ids_for_user(user_B) siendo A devuelve 0 filas, get_account_ids_for_user(user_A) devuelve la cuenta propia, y la policy real de account_members respeta el mismo aislamiento.';
  END IF;

  -- ── (5) Como anon, sin ningún claim: 0 filas, SIN ERROR ───────────────────
  BEGIN
    EXECUTE 'SET LOCAL ROLE anon';
    BEGIN
      SELECT count(*) INTO v_count FROM public.get_account_ids_for_user(v_user_b);
      IF v_count <> 0 THEN
        RAISE EXCEPTION 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD FAILED (5): como anon, get_account_ids_for_user(user_B) devolvió % filas — debía devolver 0.', v_count;
      END IF;
      RAISE NOTICE 'PASS (5): como anon (sin claims), get_account_ids_for_user(user_B) devuelve 0 filas sin error.';
    EXCEPTION
      WHEN insufficient_privilege THEN
        IF SQLERRM LIKE 'permission denied for function%' THEN
          RAISE NOTICE 'GATE GET-ACCOUNT-IDS-FOR-USER-GUARD degradado en (5): el entorno no otorga EXECUTE a anon sobre get_account_ids_for_user (permission denied) — omitido sin fallar. En prod anon SÍ tiene EXECUTE (allowlist test_function_acl_gate.sql (2)).';
        ELSE
          RAISE;
        END IF;
    END;
    EXECUTE 'RESET ROLE';
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      RAISE;
  END;

  -- Cleanup (postgres bypassea RLS acá).
  DELETE FROM public.account_members WHERE user_id IN (v_user_a, v_user_b);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id IN (v_user_a, v_user_b);
  DELETE FROM auth.users WHERE id IN (v_user_a, v_user_b);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

ROLLBACK;
