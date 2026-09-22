-- =============================================================================
-- GATE: test_accounts_privilege_columns.sql
-- CHANGE: accounts-profiles-privilege-columns, vía
--         20261053000001_accounts_profiles_privilege_columns.sql
--         (governance CRÍTICO: billing + seguridad; PO 2026-09-21)
-- =============================================================================
--
-- QUÉ PRUEBA. Que las columnas de privilegio de las dos tablas de identidad
-- (`public.accounts`: billing/trial/exención/titular; `public.profiles`:
-- billing/trial/rol/plan/contadores de cuota) NO son escribibles por
-- `authenticated` ni por `anon`, que la allow-list es EXACTA (una columna
-- nueva que `authenticated` pueda escribir y no esté declarada acá hace
-- FALLAR el gate — el hueco original nació así: `profiles` tenía un trigger
-- que enumeraba `role`/`plan` y seis semanas después le agregaron las
-- columnas de billing sin tocarlo), que el camino legítimo sigue funcionando,
-- y que ninguna de las variantes de la MATRIZ DE EVASIÓN llega a la columna.
--
-- POR QUÉ NO ALCANZA CON MIRAR EL SQLSTATE. Postgres usa el MISMO 42501
-- (`insufficient_privilege`) para cuatro cosas distintas que acá importan
-- distinguir:
--   · falta el privilegio de tabla/columna  → "permission denied for ..."
--   · la RLS rechazó la fila               → "new row violates row-level
--                                              security policy ..."
--   · `trg_prevent_profile_escalation`     → "Cannot change profile role
--                                              directly. Use admin panel."
--   · los guards P0401/P0403 de las RPCs   → ERRCODE propio, no 42501
-- Un gate que sólo mirara el SQLSTATE habría estado en VERDE todo este tiempo:
-- el 42501 de `profiles.role` YA lo producía el trigger y el de una fila ajena
-- YA lo producía la RLS. Por eso cada chequeo negativo exige, además del
-- sqlstate, que el TEXTO empiece con "permission denied" y que NO sea ninguno
-- de los otros dos mensajes — es la única forma de afirmar que fue la CAPA DE
-- PRIVILEGIO la que frenó la escritura. (Mismo razonamiento y mismo molde que
-- supabase/tests/test_anon_table_writes_revoked.sql chequeo (d).)
--
-- Aislamiento: todo el archivo corre dentro de BEGIN … ROLLBACK. Crea usuarios
-- sintéticos `@test.local` (el INSERT en auth.users dispara `handle_new_user`,
-- que es justamente el camino de alta que este change NO debe romper) y no
-- toca ninguna fila de negocio preexistente. Degrade-don't-fail en los
-- bloques que dependen de poder construir la fixture; los chequeos de
-- metadata y los negativos de privilegio no degradan nunca.
-- =============================================================================

BEGIN;


-- ── (a) Metadata: ni `authenticated` ni `anon` conservan escritura a nivel
--       TABLA sobre accounts/profiles ────────────────────────────────────────
DO $$
DECLARE
  v_role text;
  v_tbl  text;
  v_priv text;
  v_bad  text := '';
BEGIN
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    FOREACH v_tbl IN ARRAY ARRAY['public.accounts', 'public.profiles'] LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF has_table_privilege(v_role, v_tbl, v_priv) THEN
          v_bad := v_bad || format('%s/%s/%s ', v_role, v_tbl, v_priv);
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (a): privilegio de escritura a nivel TABLA que debería estar revocado por 20261053000001: %. Con el grant de TABLA puesto, el grant por columna no protege nada (la tabla cubre todas las columnas, presentes y futuras).', v_bad;
  END IF;

  RAISE NOTICE 'PASS (a): authenticated y anon sin INSERT/UPDATE/DELETE/TRUNCATE de tabla sobre accounts y profiles.';
END $$;


-- ── (b) accounts: allow-list VACÍA. Ninguna columna escribible, y las de
--       privilegio nombradas una por una (documentación + detector de
--       re-alta con otro nombre) ─────────────────────────────────────────────
DO $$
DECLARE
  -- Allow-list de accounts declarada por el change: VACÍA a propósito. Toda
  -- escritura entra por función SECURITY DEFINER o por el contexto de
  -- servicio del backend. Si alguna vez hiciera falta otorgar una columna,
  -- va acá Y en la migración, en el MISMO PR.
  v_allowed_account_cols CONSTANT text[] := ARRAY[]::text[];
  -- Las que el hallazgo explotaba: si un rename/re-alta las hiciera
  -- reaparecer escribibles, (b) lo grita con nombre y apellido.
  v_privilege_cols CONSTANT text[] := ARRAY[
    'billing_plan', 'billing_status', 'plan_expires_at',
    'trial_plan', 'trial_started_at', 'trial_expires_at',
    'billing_exempt', 'billing_exempt_reason', 'billing_exempt_granted_at',
    'billing_exempt_granted_by', 'owner_user_id', 'id'
  ];
  v_role text;
  v_col  RECORD;
  v_name text;
  v_bad  text := '';
  v_n    integer := 0;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    -- has_any_column_privilege SÍ ve los grants de columna (has_table_privilege
    -- no) — sin esto, un GRANT UPDATE (billing_exempt) pasaría desapercibido.
    IF has_any_column_privilege(v_role, 'public.accounts', 'UPDATE') THEN
      v_bad := v_bad || format('%s puede UPDATE alguna columna de accounts; ', v_role);
    END IF;
    IF has_any_column_privilege(v_role, 'public.accounts', 'INSERT') THEN
      v_bad := v_bad || format('%s puede INSERT alguna columna de accounts; ', v_role);
    END IF;
  END LOOP;

  -- Enumeración desde el catálogo: cualquier columna escribible fuera de la
  -- allow-list declarada (hoy vacía) hace fallar el gate, incluidas las que
  -- todavía no existen.
  FOR v_col IN
    SELECT c.column_name
    FROM   information_schema.columns c
    WHERE  c.table_schema = 'public' AND c.table_name = 'accounts'
  LOOP
    v_n := v_n + 1;
    IF has_column_privilege('authenticated', 'public.accounts', v_col.column_name, 'UPDATE')
       AND NOT (v_col.column_name = ANY (v_allowed_account_cols))
    THEN
      v_bad := v_bad || format('authenticated puede UPDATE accounts.%s, fuera de la allow-list declarada; ', v_col.column_name);
    END IF;
  END LOOP;

  FOREACH v_name IN ARRAY v_privilege_cols LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'accounts' AND column_name = v_name
    ) AND has_column_privilege('authenticated', 'public.accounts', v_name, 'UPDATE') THEN
      v_bad := v_bad || format('authenticated puede UPDATE la columna de PRIVILEGIO accounts.%s; ', v_name);
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (b): %', v_bad;
  END IF;

  RAISE NOTICE 'PASS (b): las % columnas de accounts son de sólo lectura para authenticated/anon (allow-list declarada: vacía).', v_n;
END $$;


-- ── (c) profiles: allow-list EXACTA de 11 columnas ─────────────────────────
DO $$
DECLARE
  -- MISMA lista que el GRANT de la sección 2 de
  -- 20261053000001_accounts_profiles_privilege_columns.sql. Las 7 primeras las
  -- escribe `updateProfile` (lib/profile-update.ts), las 4 últimas
  -- `updatePreferences` (contexts/auth-context.tsx).
  v_allowed_profile_cols CONSTANT text[] := ARRAY[
    'name', 'last_name', 'business_name', 'phone', 'locality', 'bio',
    'avatar_url', 'currency', 'timezone', 'date_format', 'language'
  ];
  -- Las que el segundo hallazgo explotaba (billing/trial + cuota de IA/export)
  -- más las dos que el trigger ya cubría.
  v_privilege_cols CONSTANT text[] := ARRAY[
    'id', 'role', 'plan',
    'billing_plan', 'billing_status', 'trial_plan', 'trial_started_at',
    'trial_expires_at', 'billing_provider_customer_id',
    'ai_queries_used', 'ai_advice_used', 'exports_used', 'insights_used',
    'usage_reset_at', 'insights_reset_at',
    'terms_accepted_at', 'terms_version'
  ];
  v_col  RECORD;
  v_name text;
  v_bad  text := '';
  v_n    integer := 0;
BEGIN
  FOR v_col IN
    SELECT c.column_name
    FROM   information_schema.columns c
    WHERE  c.table_schema = 'public' AND c.table_name = 'profiles'
  LOOP
    v_n := v_n + 1;

    IF has_column_privilege('authenticated', 'public.profiles', v_col.column_name, 'UPDATE')
       AND NOT (v_col.column_name = ANY (v_allowed_profile_cols))
    THEN
      v_bad := v_bad || format('authenticated puede UPDATE profiles.%s, fuera de la allow-list declarada; ', v_col.column_name);
    END IF;

    IF has_column_privilege('anon', 'public.profiles', v_col.column_name, 'UPDATE') THEN
      v_bad := v_bad || format('anon puede UPDATE profiles.%s; ', v_col.column_name);
    END IF;
  END LOOP;

  FOREACH v_name IN ARRAY v_privilege_cols LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = v_name
    ) AND has_column_privilege('authenticated', 'public.profiles', v_name, 'UPDATE') THEN
      v_bad := v_bad || format('authenticated puede UPDATE la columna de PRIVILEGIO profiles.%s; ', v_name);
    END IF;
  END LOOP;

  -- Control positivo de metadata: el camino legítimo no se sobre-cerró.
  FOREACH v_name IN ARRAY v_allowed_profile_cols LOOP
    IF NOT has_column_privilege('authenticated', 'public.profiles', v_name, 'UPDATE') THEN
      v_bad := v_bad || format('authenticated PERDIÓ el UPDATE de profiles.%s, que está en la allow-list (el perfil o las preferencias quedan rotos); ', v_name);
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (c): %', v_bad;
  END IF;

  RAISE NOTICE 'PASS (c): de las % columnas de profiles, authenticated escribe exactamente las % declaradas.', v_n, array_length(v_allowed_profile_cols, 1);
END $$;


-- ── (d) Vistas: una vista actualizable sobre accounts/profiles sólo es
--       aceptable si delega el chequeo en el rol invocante
--       (security_invoker) — si no, el privilegio se evaluaría con el del
--       PROPIETARIO (postgres) y la allow-list de (b)/(c) sería letra muerta ─
DO $$
DECLARE
  v_bad text := '';
  r     RECORD;
  v_n   integer := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS rel,
           pg_relation_is_updatable(c.oid, true) AS mask,
           coalesce(array_to_string(c.reloptions, ','), '') AS opts
    FROM   pg_class c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  c.relkind IN ('v', 'm')
      AND  n.nspname IN ('public', 'community')   -- los 2 schemas servidos por la API de datos
      AND  EXISTS (
             SELECT 1
             FROM   pg_depend d
             JOIN   pg_rewrite rw ON rw.oid = d.objid
             JOIN   pg_class t    ON t.oid = d.refobjid
             JOIN   pg_namespace tn ON tn.oid = t.relnamespace
             WHERE  rw.ev_class = c.oid
               AND  d.classid = 'pg_rewrite'::regclass
               AND  d.refclassid = 'pg_class'::regclass
               AND  tn.nspname = 'public'
               AND  t.relname IN ('accounts', 'profiles')
           )
  LOOP
    v_n := v_n + 1;
    -- bit 1<<CMD_UPDATE = 4
    IF (r.mask & 4) = 4
       AND r.opts NOT ILIKE '%security_invoker=true%'
       AND r.opts NOT ILIKE '%security_invoker=on%'
    THEN
      v_bad := v_bad || format('%s.%s es actualizable y NO es security_invoker (reloptions=%s); ', r.sch, r.rel, r.opts);
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (d): %', v_bad;
  END IF;

  RAISE NOTICE 'PASS (d): las % vistas sobre accounts/profiles en public+community son o de sólo lectura o security_invoker.', v_n;
END $$;


-- ── (e) MATRIZ DE EVASIÓN ejecutada, con fixture real e impersonación
--       (SET LOCAL ROLE authenticated + request.jwt.claims, el mismo
--       mecanismo que usa PostgREST y que usa get_db_conn del backend) ──────
DO $$
DECLARE
  v_email_a   text := 'sec-privcols-owner@test.local';
  v_email_b   text := 'sec-privcols-member@test.local';
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_member_b  uuid;
  v_cat_ajena uuid := gen_random_uuid();

  v_bad       text := '';
  v_sqlstate  text;
  v_msg       text;
  v_exempt    boolean;
  v_plan      text;
  v_status    text;
  v_expires   timestamptz;
  v_name      text;
  v_counter   integer;
  v_result    jsonb;
  v_b_outcome text;

  -- Cada intento hostil se corre igual: EXECUTE dentro de un sub-bloque,
  -- y se exige que el rechazo venga de la CAPA DE PRIVILEGIO.
  v_note      text := 'ver encabezado: 42501 + "permission denied" y NUNCA el mensaje de la RLS ni el del trigger';
BEGIN
  -- ── Fixture: el INSERT en auth.users dispara handle_new_user (perfil +
  --    cuenta + membresía owner + seeds). Es, además, la prueba de que el
  --    alta de cuenta NO depende del grant de tabla que este change revoca.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate PrivCols Owner'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members WHERE user_id = v_user_a
  ORDER  BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (e, fixture): el INSERT en auth.users no derivó en una cuenta con membresía — handle_new_user dejó de crear el tenant, que es exactamente el camino que este change NO debe romper.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_a) THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (e, fixture): handle_new_user no creó el perfil.';
  END IF;
  RAISE NOTICE 'PASS (e0): alta de usuario → perfil + cuenta + membresía owner creados por handle_new_user (account=%).', v_account_a;

  -- Plan pago para poder ejercitar la cancelación legítima al final, y
  -- contadores distintos de cero para probar que no se pueden resetear.
  UPDATE public.accounts
  SET    billing_plan = 'pro', billing_status = 'active', plan_expires_at = NULL,
         billing_exempt = false, billing_exempt_reason = NULL
  WHERE  id = v_account_a;
  UPDATE public.profiles
  SET    ai_queries_used = 7, billing_plan = 'gratis', trial_expires_at = now() + interval '3 days'
  WHERE  id = v_user_a;

  -- ── Impersonación real ───────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- (e1) UPDATE directo de la exención — EL exploit del hallazgo.
  BEGIN
    EXECUTE format(
      'UPDATE public.accounts SET billing_exempt = true, billing_exempt_reason = %L WHERE id = %L',
      'gate-evasion-e1', v_account_a);
    v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%'
          AND v_msg NOT ILIKE '%row-level security%') THEN
    v_bad := v_bad || format('(e1) UPDATE accounts SET billing_exempt: sqlstate=%s msg=%s [%s]; ', v_sqlstate, v_msg, v_note);
  END IF;

  -- (e2) La misma escritura con RETURNING (variante que PostgREST emite
  --      cuando el cliente pide `Prefer: return=representation`).
  BEGIN
    EXECUTE format(
      'UPDATE public.accounts SET billing_plan = %L, plan_expires_at = %L WHERE id = %L RETURNING id',
      'pro', (now() + interval '99 years')::text, v_account_a);
    v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE … RETURNING tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%'
          AND v_msg NOT ILIKE '%row-level security%') THEN
    v_bad := v_bad || format('(e2) UPDATE accounts … RETURNING: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e3) Upsert: INSERT … ON CONFLICT DO UPDATE, el camino que PostgREST
  --      expone como `Prefer: resolution=merge-duplicates`.
  BEGIN
    EXECUTE format(
      'INSERT INTO public.accounts (id, owner_user_id, billing_plan) VALUES (%L, %L, %L)
         ON CONFLICT (id) DO UPDATE SET billing_exempt = true',
      v_account_a, v_user_a, 'pro');
    v_sqlstate := 'NO_ERROR'; v_msg := 'el upsert tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%'
          AND v_msg NOT ILIKE '%row-level security%') THEN
    v_bad := v_bad || format('(e3) upsert accounts ON CONFLICT DO UPDATE: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e4) profiles: billing + cuota de IA (el 2º hallazgo) y las dos que el
  --      trigger ya cubría — acá se exige que frene el PRIVILEGIO, no el
  --      trigger (mismo sqlstate, mensaje distinto).
  BEGIN
    EXECUTE format('UPDATE public.profiles SET billing_plan = %L, trial_expires_at = %L WHERE id = %L',
                   'pro', '2099-01-01T00:00:00Z', v_user_a);
    v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
    v_bad := v_bad || format('(e4a) UPDATE profiles SET billing_plan/trial_expires_at: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  BEGIN
    EXECUTE format('UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, exports_used = 0, insights_used = 0 WHERE id = %L', v_user_a);
    v_sqlstate := 'NO_ERROR'; v_msg := 'el reseteo de cuota tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
    v_bad := v_bad || format('(e4b) reseteo de contadores de cuota en profiles: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  BEGIN
    EXECUTE format('UPDATE public.profiles SET role = %L WHERE id = %L', 'admin', v_user_a);
    v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE de role tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
    v_bad := v_bad || format('(e4c) UPDATE profiles SET role=admin: se esperaba el rechazo de la capa de PRIVILEGIO ("permission denied"), no el del trigger ni otro — sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e5) Vista actualizable sobre profiles: la columna protegida no se
  --      alcanza ni por ahí, y la permitida sí (security_invoker hace que la
  --      allow-list gobierne también este camino).
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'community' AND c.relname = 'profiles' AND c.relkind = 'v') THEN
    BEGIN
      EXECUTE format('UPDATE community.profiles SET id = %L WHERE id = %L', gen_random_uuid(), v_user_a);
      v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE por la vista tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
      v_bad := v_bad || format('(e5a) UPDATE community.profiles SET id (vista actualizable): sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
    END IF;

    BEGIN
      EXECUTE format('UPDATE community.profiles SET name = %L WHERE id = %L', 'Nombre por vista', v_user_a);
      v_sqlstate := 'NO_ERROR';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF v_sqlstate <> 'NO_ERROR' THEN
      v_bad := v_bad || format('(e5b, control positivo) UPDATE community.profiles SET name debía funcionar: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
    END IF;
  ELSE
    RAISE NOTICE 'GATE (e5) degradado: community.profiles no existe en este entorno.';
  END IF;

  -- (e6) Camino legítimo del perfil y de las preferencias.
  BEGIN
    EXECUTE format('UPDATE public.profiles SET name = %L, bio = %L, currency = %L WHERE id = %L',
                   'Gate PrivCols', 'bio de prueba', 'ARS', v_user_a);
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(e6, control positivo) el UPDATE de perfil/preferencias de la allow-list debía funcionar: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e7) Las RPCs con EXECUTE para authenticated que escriben accounts, con
  --      parámetros hostiles: la validación que el PATCH crudo salteaba.
  BEGIN
    PERFORM public.rpc_set_default_payment_terms((-5)::smallint);
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'P0400' THEN
    v_bad := v_bad || format('(e7a) rpc_set_default_payment_terms(-5) debía dar P0400: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  BEGIN
    PERFORM public.rpc_set_default_product_category(v_cat_ajena);
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'P0404' THEN
    v_bad := v_bad || format('(e7b) rpc_set_default_product_category(<uuid ajeno>) debía dar P0404: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  BEGIN
    PERFORM public.rpc_set_default_payment_terms((30)::smallint);
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(e7c, control positivo) rpc_set_default_payment_terms(30) debía funcionar (Configuración ▸ Cobranzas): sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e8) La cancelación migrada: es el ÚNICO camino que le queda a
  --      `authenticated` para tocar billing, y no acepta plan ni fecha.
  BEGIN
    v_result := public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(e8) rpc_request_subscription_cancellation() como titular con plan pago debía funcionar: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  ELSIF (v_result->>'from_plan') <> 'pro' THEN
    v_bad := v_bad || format('(e8) la RPC devolvió from_plan=%s, se esperaba pro; ', v_result->>'from_plan');
  END IF;

  -- Segunda llamada: ya está programada → conflicto explícito, no un no-op.
  BEGIN
    PERFORM public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> 'P0409' THEN
    v_bad := v_bad || format('(e8b) la segunda cancelación debía dar P0409: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  EXECUTE 'RESET ROLE';

  -- ── Estado real de la fila, leído como postgres ──────────────────────────
  SELECT billing_exempt, billing_plan, billing_status, plan_expires_at
    INTO v_exempt, v_plan, v_status, v_expires
  FROM   public.accounts WHERE id = v_account_a;

  IF v_exempt IS DISTINCT FROM false THEN
    v_bad := v_bad || format('(e-fila) accounts.billing_exempt quedó en %s: alguna variante de la matriz SÍ escribió; ', v_exempt);
  END IF;
  IF v_expires IS NULL OR v_expires > now() + interval '31 days' THEN
    v_bad := v_bad || format('(e-fila) accounts.plan_expires_at quedó en %s: la RPC debía dejar now()+30 días y ninguna variante debía poder estirarlo; ', v_expires);
  END IF;
  IF v_status <> 'cancelling' THEN
    v_bad := v_bad || format('(e-fila) accounts.billing_status quedó en %s, se esperaba cancelling por la RPC; ', v_status);
  END IF;

  SELECT ai_queries_used, billing_plan, name INTO v_counter, v_plan, v_name
  FROM   public.profiles WHERE id = v_user_a;
  IF v_counter <> 7 THEN
    v_bad := v_bad || format('(e-fila) profiles.ai_queries_used quedó en %s, se esperaba 7 intacto; ', v_counter);
  END IF;
  IF v_plan <> 'gratis' THEN
    v_bad := v_bad || format('(e-fila) profiles.billing_plan quedó en %s, se esperaba gratis intacto; ', v_plan);
  END IF;
  IF v_name IS DISTINCT FROM 'Gate PrivCols' THEN
    v_bad := v_bad || format('(e-fila, control positivo) profiles.name quedó en %s, se esperaba el valor escrito por el camino legítimo; ', v_name);
  END IF;

  -- ── (e9) Miembro NO titular: la cuenta ajena queda intacta, y el intento
  --        no responde "ok" en silencio (hallazgo A1-5 de la auditoría: la
  --        ruta anterior devolvía {ok:true} con 0 filas afectadas) ──────────
  BEGIN
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
            jsonb_build_object('name', 'Gate PrivCols Member'))
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.account_members (account_id, user_id, role)
    VALUES (v_account_a, v_user_b, 'member')
    ON CONFLICT (account_id, user_id) DO NOTHING
    RETURNING id INTO v_member_b;

    UPDATE public.accounts SET billing_status = 'active' WHERE id = v_account_a;

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
      PERFORM public.rpc_request_subscription_cancellation();
      v_b_outcome := 'NO_ERROR';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_b_outcome = RETURNED_SQLSTATE;
    END;

    EXECUTE 'RESET ROLE';

    SELECT billing_status INTO v_status FROM public.accounts WHERE id = v_account_a;
    IF v_status <> 'active' THEN
      v_bad := v_bad || format('(e9) un miembro NO titular dejó la cuenta ajena en billing_status=%s (outcome de la RPC: %s) — la RPC debe rechazar con P0403 o resolver la cuenta propia, nunca tocar la ajena; ', v_status, v_b_outcome);
    END IF;
    RAISE NOTICE 'PASS (e9): miembro no titular → outcome=% y la cuenta ajena quedó intacta (billing_status=%).', v_b_outcome, v_status;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'GATE (e9) degradado: no se pudo construir la fixture de miembro no titular (%). El resto de la matriz no depende de esto.', SQLERRM;
  END;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ACCOUNTS-PRIVILEGE-COLUMNS FAILED (e, matriz de evasión): %', v_bad;
  END IF;

  RAISE NOTICE 'PASS (e): matriz de evasión completa (UPDATE, UPDATE…RETURNING, upsert, vista actualizable, contadores de cuota, role) rechazada por la capa de PRIVILEGIO; camino legítimo (perfil, preferencias, 2 RPCs de configuración, cancelación) intacto; fila de accounts y contadores de profiles sin tocar.';
END $$;

ROLLBACK;
