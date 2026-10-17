-- =============================================================================
-- GATE: test_email_logs_insert_cerrado.sql
-- HOTFIX: email-logs-cierre-insert (OQ-7 de multiusuario-operativo), vía
--         20261084000001_email_logs_cierre_insert.sql
--         (governance CRÍTICO: vector de phishing desde el dominio de ALIADATA;
--          toca RLS, ACL y el envío de correos)
-- =============================================================================
--
-- QUÉ PRUEBA. Que `public.email_logs` ya NO acepta escrituras de `authenticated`
-- ni de `anon` (ni INSERT, ni UPDATE, ni DELETE, ni TRUNCATE), que NINGUNO de los
-- escritores legítimos se rompe (las funciones SECURITY DEFINER que encolan
-- correos, el camino de servicio y la cancelación de plan, que pasa a encolar su
-- correo adentro de la RPC), y que el destinatario del único correo que dispara
-- un usuario sale SIEMPRE de la sesión, nunca de un parámetro.
--
-- EL HALLAZGO. `email_logs_backend_insert WITH CHECK (true)` + `INSERT` de tabla
-- para `authenticated` dejaban a cualquier usuario autenticado escribir una fila
-- `status='pending'` con destinatario y asunto arbitrarios; el trigger
-- `on_email_log_insert` invocaba a `send-email` y ALIADATA mandaba el correo
-- desde su dominio. Verificado por construcción en la medición de OQ-7; este gate
-- es la prueba EJECUTADA del cierre (con impersonación real: SET LOCAL ROLE +
-- request.jwt.claims, el mismo mecanismo que usan PostgREST y get_db_conn).
--
-- POR QUÉ NO ALCANZA CON EL SQLSTATE. Postgres devuelve 42501 tanto cuando falta
-- el PRIVILEGIO ("permission denied for table …") como cuando la RLS rechaza la
-- fila ("new row violates row-level security policy …"). Con la policy abierta
-- eliminada pero el grant puesto, el segundo sería el único freno: una policy
-- nueva «de conveniencia» lo reabriría. Cada chequeo negativo exige entonces
-- que el rechazo venga de la capa de PRIVILEGIO (texto "permission denied") y que
-- NO sea el de la RLS — mismo razonamiento que test_accounts_privilege_columns.sql.
--
-- Aislamiento: todo el archivo corre dentro de BEGIN … ROLLBACK. Crea usuarios
-- sintéticos `@test.local` y no toca ninguna fila de negocio preexistente. Los
-- datos de la fixture viajan entre bloques por GUC (set_config(..., true)), porque
-- una tabla temporal del propietario no es legible bajo SET LOCAL ROLE.
-- =============================================================================

BEGIN;


-- ── (a) Metadata: ni policy de escritura ni privilegio de escritura para los
--       roles de la API; service_role y postgres conservan lo que necesitan ───
DO $$
DECLARE
  v_role text;
  v_priv text;
  v_bad  text := '';
  v_pol  RECORD;
BEGIN
  -- Policies: ninguna que permita escribir. La de lectura de administradores
  -- ("Admins can view email logs", SELECT) es la única que debe quedar.
  FOR v_pol IN
    SELECT policyname, cmd FROM pg_policies
    WHERE  schemaname = 'public' AND tablename = 'email_logs'
      AND  cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    v_bad := v_bad || format('policy de escritura vigente: %s (%s); ', v_pol.policyname, v_pol.cmd);
  END LOOP;

  -- Privilegios de tabla de los dos roles que expone PostgREST.
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
      IF has_table_privilege(v_role, 'public.email_logs', v_priv) THEN
        v_bad := v_bad || format('%s conserva %s a nivel tabla; ', v_role, v_priv);
      END IF;
    END LOOP;
    -- has_any_column_privilege ve los grants por COLUMNA (has_table_privilege no).
    IF has_any_column_privilege(v_role, 'public.email_logs', 'INSERT')
       OR has_any_column_privilege(v_role, 'public.email_logs', 'UPDATE') THEN
      v_bad := v_bad || format('%s conserva INSERT/UPDATE por columna; ', v_role);
    END IF;
  END LOOP;

  -- anon no necesita leer ni la existencia de la tabla.
  IF has_table_privilege('anon', 'public.email_logs', 'SELECT') THEN
    v_bad := v_bad || 'anon conserva SELECT; ';
  END IF;

  -- Controles positivos: lo legítimo sigue en pie.
  IF NOT has_table_privilege('authenticated', 'public.email_logs', 'SELECT') THEN
    v_bad := v_bad || 'authenticated PERDIÓ el SELECT (la policy de lectura de administradores quedaría muerta); ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'email_logs' AND cmd = 'SELECT') THEN
    v_bad := v_bad || 'falta la policy de lectura de administradores; ';
  END IF;
  FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'SELECT'] LOOP
    IF NOT has_table_privilege('service_role', 'public.email_logs', v_priv) THEN
      v_bad := v_bad || format('service_role PERDIÓ %s (send-email actualiza el estado con la service role key); ', v_priv);
    END IF;
  END LOOP;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.email_logs'::regclass) THEN
    v_bad := v_bad || 'la RLS de email_logs está APAGADA; ';
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (a): %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (a): email_logs sin policy ni privilegio de escritura para authenticated/anon; SELECT de administradores y service_role intactos.';
END $$;


-- ── (b) Estructural: TODA función que escribe en email_logs es SECURITY DEFINER
--       (un trigger/RPC SECURITY INVOKER dejaría de poder encolar su correo bajo
--       `authenticated` — o forzaría a reabrir el privilegio). Barrido por
--       catálogo: una función nueva que lo viole hace FALLAR el gate ───────────
DO $$
DECLARE
  v_bad text := '';
  v_n   integer := 0;
  r     RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS fn, p.prosecdef
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname IN ('public', 'community')
      AND  p.prokind IN ('f', 'p')
      AND  p.prosrc ILIKE '%email_logs%'
      -- Sólo las que ESCRIBEN: INSERT/UPDATE/DELETE/TRUNCATE sobre la tabla.
      AND  p.prosrc ~* '(insert\s+into|update|delete\s+from|truncate)\s+(table\s+)?(public\.)?email_logs'
  LOOP
    v_n := v_n + 1;
    IF NOT r.prosecdef THEN
      v_bad := v_bad || format('%s escribe en email_logs y es SECURITY INVOKER; ', r.fn);
    END IF;
  END LOOP;

  IF v_n < 8 THEN
    -- Sanidad del barrido: hoy hay 11 funciones que escriben (handle_new_user,
    -- check_low_margin, check_branch_low_stock, notify_meeting_created,
    -- notify_pool_created, queue_trial_notifications, _produce_plan_expiring_soon,
    -- _produce_receivables_overdue_digest, rpc_process_outbox_dispatch,
    -- purge_internal_logs y rpc_request_subscription_cancellation). Si el
    -- barrido ve muy pocas, la regex dejó de funcionar y el gate no prueba nada.
    v_bad := v_bad || format('el barrido sólo encontró %s funciones que escriben en email_logs (se esperaban ≥ 8): la regex del gate dejó de funcionar; ', v_n);
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (b): %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (b): las % funciones que escriben en email_logs son todas SECURITY DEFINER.', v_n;
END $$;


-- ── (c) Fixture: dueño A (plan pago), miembro B (no titular), administrador X ─
DO $$
DECLARE
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_user_x    uuid := gen_random_uuid();
  v_account_a uuid;
  v_welcome   integer;
  v_status    text;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'gate-emaillogs-owner@test.local', now(), now(),
          jsonb_build_object('name', 'Gate EmailLogs Owner')),
         (v_user_b, 'authenticated', 'authenticated', 'gate-emaillogs-member@test.local', now(), now(),
          jsonb_build_object('name', 'Gate EmailLogs Member')),
         (v_user_x, 'authenticated', 'authenticated', 'gate-emaillogs-admin@test.local', now(), now(),
          jsonb_build_object('name', 'Gate EmailLogs Admin'));

  SELECT account_id INTO v_account_a
  FROM   public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (c, fixture): el INSERT en auth.users no derivó en una cuenta con membresía.';
  END IF;

  -- B: miembro (no titular) de la cuenta de A.
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_b, 'member')
  ON CONFLICT (account_id, user_id) DO NOTHING;

  -- X: administrador de plataforma (lee email_logs; da de alta reuniones).
  -- prevent_profile_privilege_escalation bloquea UPDATE de role fuera de un caller ya-admin:
  -- escape sancionado para setup de test (patrón de test_admin_kpis.sql), en la misma transacción.
  ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation;
  UPDATE public.profiles SET role = 'admin' WHERE id = v_user_x;
  ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation;

  -- A: plan pago activo, para poder ejercitar la cancelación legítima.
  UPDATE public.accounts
  SET    billing_plan = 'pro', billing_status = 'active', plan_expires_at = NULL,
         billing_exempt = false
  WHERE  id = v_account_a;

  PERFORM set_config('gate.user_a', v_user_a::text, true);
  PERFORM set_config('gate.user_b', v_user_b::text, true);
  PERFORM set_config('gate.user_x', v_user_x::text, true);
  PERFORM set_config('gate.account_a', v_account_a::text, true);

  -- Control positivo del producto SECURITY DEFINER más antiguo: el alta de usuario
  -- (trigger de auth.users, corre como supabase_auth_admin) encoló su `welcome`.
  -- Entra con el estado POR DEFECTO ('pending'): es lo que el trigger
  -- on_email_log_insert necesita para invocar a send-email.
  SELECT count(*), min(status) INTO v_welcome, v_status
  FROM   public.email_logs
  WHERE  user_id = v_user_a AND event_type = 'welcome';
  IF v_welcome <> 1 OR v_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (c, fixture): el alta de usuario debía encolar 1 correo welcome en estado pending; encoló % con estado %.', v_welcome, v_status;
  END IF;

  RAISE NOTICE 'PASS (c0): fixture creada (cuenta=%); el alta de usuario encoló su correo welcome pending vía handle_new_user (SECURITY DEFINER).', v_account_a;
END $$;


-- ── (d) MATRIZ DE EVASIÓN ejecutada con impersonación real ───────────────────
DO $$
DECLARE
  v_user_a    uuid := current_setting('gate.user_a')::uuid;
  v_user_b    uuid := current_setting('gate.user_b')::uuid;
  v_who       text;
  v_claims    text;
  v_sqlstate  text;
  v_msg       text;
  v_bad       text := '';
  v_victima   CONSTANT text := 'victima-phishing@example.com';
  v_leaked    integer;
  v_rows      bigint;
  v_before    integer := (SELECT count(*) FROM public.email_logs WHERE recipient IN ('victima-phishing@example.com', 'all_users'));
  v_note      CONSTANT text := '42501 + "permission denied", nunca el mensaje de la RLS';
BEGIN
  -- Se corre idéntica para el miembro B (el atacante típico) y para el titular A:
  -- ser titular de una cuenta no otorga escritura sobre la tabla técnica.
  FOREACH v_who IN ARRAY ARRAY['miembro-B', 'titular-A'] LOOP
    v_claims := json_build_object(
      'sub',  CASE v_who WHEN 'miembro-B' THEN v_user_b ELSE v_user_a END::text,
      'role', 'authenticated')::text;
    PERFORM set_config('request.jwt.claims', v_claims, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- (d1) EL exploit: correo arbitrario a un tercero, con asunto libre.
    BEGIN
      EXECUTE format(
        'INSERT INTO public.email_logs (event_type, recipient, subject, metadata) VALUES (%L, %L, %L, %L::jsonb)',
        'meeting_notice', v_victima, 'Verificá tu cuenta de ALIADATA', '{"title":"x","start_time":"2026-01-01T00:00:00Z","url":"https://evil.example/phish"}');
      v_sqlstate := 'NO_ERROR'; v_msg := 'el INSERT tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%' AND v_msg NOT ILIKE '%row-level security%') THEN
      v_bad := v_bad || format('(d1/%s) INSERT directo a un tercero: sqlstate=%s msg=%s [%s]; ', v_who, v_sqlstate, v_msg, v_note);
    END IF;

    -- (d2) La variante que PostgREST emite con `Prefer: resolution=ignore-duplicates`.
    BEGIN
      EXECUTE format(
        'INSERT INTO public.email_logs (event_type, recipient, subject, metadata) VALUES (%L, %L, %L, %L::jsonb) ON CONFLICT DO NOTHING',
        'plan_upgraded', v_victima, 'Tu pago fue acreditado', '{"plan":"pro"}');
      v_sqlstate := 'NO_ERROR'; v_msg := 'el INSERT … ON CONFLICT tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%' AND v_msg NOT ILIKE '%row-level security%') THEN
      v_bad := v_bad || format('(d2/%s) INSERT … ON CONFLICT DO NOTHING: sqlstate=%s msg=%s; ', v_who, v_sqlstate, v_msg);
    END IF;

    -- (d3) Fan-out masivo: el comodín `all_users` (sólo lo frena la allow-list de
    --      send-email, que es el SEGUNDO freno; el primero es no poder insertar).
    BEGIN
      EXECUTE format(
        'INSERT INTO public.email_logs (event_type, recipient, subject, metadata) VALUES (%L, %L, %L, %L::jsonb)',
        'meeting_notice', 'all_users', 'Aviso importante', '{"title":"x"}');
      v_sqlstate := 'NO_ERROR'; v_msg := 'el INSERT all_users tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%' AND v_msg NOT ILIKE '%row-level security%') THEN
      v_bad := v_bad || format('(d3/%s) INSERT con destinatario all_users: sqlstate=%s msg=%s; ', v_who, v_sqlstate, v_msg);
    END IF;

    -- (d4) INSERT … SELECT (no depende de VALUES).
    BEGIN
      EXECUTE format(
        'INSERT INTO public.email_logs (event_type, recipient, subject) SELECT %L, %L, %L',
        'welcome', v_victima, 'Hola');
      v_sqlstate := 'NO_ERROR'; v_msg := 'el INSERT … SELECT tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%' AND v_msg NOT ILIKE '%row-level security%') THEN
      v_bad := v_bad || format('(d4/%s) INSERT … SELECT: sqlstate=%s msg=%s; ', v_who, v_sqlstate, v_msg);
    END IF;

    -- (d5) UPDATE: reencolar/redirigir una fila existente (la fila `welcome` del
    --      propio usuario está a la vista para el titular; el UPDATE debe frenarlo
    --      el PRIVILEGIO, no el hecho de que la RLS oculte la fila).
    BEGIN
      EXECUTE format('UPDATE public.email_logs SET recipient = %L, status = %L', v_victima, 'pending');
      v_sqlstate := 'NO_ERROR'; v_msg := 'el UPDATE tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
      v_bad := v_bad || format('(d5/%s) UPDATE recipient/status: sqlstate=%s msg=%s [%s]; ', v_who, v_sqlstate, v_msg, v_note);
    END IF;

    -- (d6) DELETE: borrar el rastro de un envío.
    BEGIN
      EXECUTE 'DELETE FROM public.email_logs';
      v_sqlstate := 'NO_ERROR'; v_msg := 'el DELETE tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
      v_bad := v_bad || format('(d6/%s) DELETE: sqlstate=%s msg=%s; ', v_who, v_sqlstate, v_msg);
    END IF;

    -- (d7) TRUNCATE (no lo gobierna la RLS: sólo el privilegio).
    BEGIN
      EXECUTE 'TRUNCATE public.email_logs';
      v_sqlstate := 'NO_ERROR'; v_msg := 'el TRUNCATE tuvo éxito';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
      v_bad := v_bad || format('(d7/%s) TRUNCATE: sqlstate=%s msg=%s; ', v_who, v_sqlstate, v_msg);
    END IF;

    EXECUTE 'RESET ROLE';
  END LOOP;

  -- (d8) anon (sin sesión): mismo cierre.
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    EXECUTE format(
      'INSERT INTO public.email_logs (event_type, recipient, subject) VALUES (%L, %L, %L)',
      'welcome', v_victima, 'Hola');
    v_sqlstate := 'NO_ERROR'; v_msg := 'el INSERT anónimo tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%' AND v_msg NOT ILIKE '%row-level security%') THEN
    v_bad := v_bad || format('(d8) INSERT como anon: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.email_logs';
    v_sqlstate := 'NO_ERROR'; v_msg := 'el SELECT anónimo tuvo éxito';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF NOT (v_sqlstate = '42501' AND v_msg ILIKE 'permission denied%') THEN
    v_bad := v_bad || format('(d8b) SELECT como anon: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;
  EXECUTE 'RESET ROLE';

  -- (d9) Estado real, leído como propietario: ninguna fila al tercero, y las
  --      filas preexistentes (welcome de A, B y X) siguen ahí y siguen pending.
  SELECT count(*) INTO v_leaked FROM public.email_logs WHERE recipient IN (v_victima, 'all_users');
  v_leaked := v_leaked - v_before;  -- restar lo que ya había antes de la matriz (otros gates dejan filas all_users)
  IF v_leaked <> 0 THEN
    v_bad := v_bad || format('(d9) quedaron %s filas hacia el tercero/all_users: algún INSERT de la matriz SÍ escribió; ', v_leaked);
  END IF;
  SELECT count(*) INTO v_rows FROM public.email_logs
  WHERE  event_type = 'welcome'
    AND  recipient IN ('gate-emaillogs-owner@test.local', 'gate-emaillogs-member@test.local', 'gate-emaillogs-admin@test.local')
    AND  status = 'pending';
  IF v_rows <> 3 THEN
    v_bad := v_bad || format('(d9) las 3 filas welcome de la fixture debían seguir intactas y pending; quedan %s; ', v_rows);
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (d, matriz de evasión): %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (d): INSERT (plano, ON CONFLICT, all_users, INSERT…SELECT), UPDATE, DELETE y TRUNCATE rechazados por la capa de PRIVILEGIO para miembro, titular y anon; ninguna fila llegó al tercero.';
END $$;


-- ── (e) Los escritores legítimos siguen encolando, incluso bajo `authenticated` ─
DO $$
DECLARE
  v_user_x    uuid := current_setting('gate.user_x')::uuid;
  v_user_b    uuid := current_setting('gate.user_b')::uuid;
  v_bad       text := '';
  v_sqlstate  text;
  v_msg       text;
  v_n         integer;
  v_status    text;
  v_visible_x bigint;
  v_visible_b bigint;
  v_enabled   "char";
  v_fn        text;
  v_secdef    boolean;
BEGIN
  -- (e1) Un trigger SECURITY DEFINER disparado POR un usuario `authenticated`
  --      encola el correo con el privilegio del propietario: el administrador X da
  --      de alta una reunión comunitaria → notify_meeting_created() → meeting_notice.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_x::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO community.meetings (title, description, meeting_url, start_time)
    VALUES ('Gate EmailLogs Reunión', 'gate', 'https://meet.example/abc', now() + interval '1 day');
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;

  -- (e2) El administrador lee email_logs (policy "Admins can view email logs");
  --      un no administrador ve 0 filas (la RLS filtra; el privilegio de SELECT no).
  SELECT count(*) INTO v_visible_x FROM public.email_logs;
  EXECUTE 'RESET ROLE';

  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(e1) el alta de una reunión por un administrador (trigger SECURITY DEFINER) falló: sqlstate=%s msg=%s — el cierre rompió a un productor legítimo; ', v_sqlstate, v_msg);
  ELSE
    SELECT count(*), min(status) INTO v_n, v_status
    FROM   public.email_logs
    WHERE  event_type = 'meeting_notice' AND subject = 'Nueva Reunión: Gate EmailLogs Reunión';
    IF v_n <> 1 OR v_status IS DISTINCT FROM 'pending' THEN
      v_bad := v_bad || format('(e1) la reunión debía encolar 1 meeting_notice pending; encoló %s con estado %s; ', v_n, v_status);
    END IF;
  END IF;

  IF v_visible_x < 3 THEN
    v_bad := v_bad || format('(e2, control positivo) el administrador debía leer email_logs (≥ 3 filas de la fixture); ve %s; ', v_visible_x);
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_visible_b FROM public.email_logs;
  EXECUTE 'RESET ROLE';
  IF v_visible_b <> 0 THEN
    v_bad := v_bad || format('(e2) un no administrador ve %s filas de email_logs; debía ver 0; ', v_visible_b);
  END IF;

  -- (e3) Camino de servicio: la service role key (Edge Function send-email y
  --      cualquier job administrativo) sigue pudiendo escribir y actualizar.
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN
    INSERT INTO public.email_logs (event_type, recipient, subject)
    VALUES ('gate_service_role', 'gate-servicio@test.local', 'Gate servicio');
    UPDATE public.email_logs SET status = 'sent', sent_at = now()
    WHERE  event_type = 'gate_service_role';
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  EXECUTE 'RESET ROLE';
  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(e3) service_role no pudo INSERT/UPDATE en email_logs: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (e4) Camino del backend (get_service_conn = usuario postgres, propietario): una
  --      fila con el estado por defecto entra 'pending' y el trigger que invoca a
  --      send-email sigue instalado, habilitado y SECURITY DEFINER.
  INSERT INTO public.email_logs (event_type, recipient, subject)
  VALUES ('gate_owner_default', 'gate-owner@test.local', 'Gate propietario');
  SELECT status INTO v_status FROM public.email_logs WHERE event_type = 'gate_owner_default';
  IF v_status IS DISTINCT FROM 'pending' THEN
    v_bad := v_bad || format('(e4) una fila insertada por el propietario sin estado debía nacer pending; nació %L; ', v_status);
  END IF;
  SELECT t.tgenabled, p.proname, p.prosecdef INTO v_enabled, v_fn, v_secdef
  FROM   pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE  t.tgrelid = 'public.email_logs'::regclass AND t.tgname = 'on_email_log_insert';
  IF v_enabled IS DISTINCT FROM 'O' OR v_fn IS DISTINCT FROM 'send_email_log_webhook' OR v_secdef IS DISTINCT FROM true THEN
    v_bad := v_bad || format('(e4) on_email_log_insert debía estar habilitado ("O") sobre send_email_log_webhook SECURITY DEFINER: enabled=%s fn=%s secdef=%s; ', v_enabled, v_fn, v_secdef);
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (e, escritores legítimos): %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (e): trigger SECURITY DEFINER disparado por authenticated sigue encolando; administrador lee, no administrador no; service_role y propietario escriben; trigger de envío intacto.';
END $$;


-- ── (f) La cancelación de plan: el correo se encola ADENTRO de la RPC, con el
--       destinatario y el user_id de la sesión (nunca de un parámetro) ─────────
DO $$
DECLARE
  v_user_a   uuid := current_setting('gate.user_a')::uuid;
  v_user_b   uuid := current_setting('gate.user_b')::uuid;
  v_account  uuid := current_setting('gate.account_a')::uuid;
  v_bad      text := '';
  v_sqlstate text;
  v_msg      text;
  v_result   jsonb;
  v_n        integer;
  r          RECORD;
BEGIN
  -- (f1) Firma: sin parámetros. No hay manera de elegir destinatario, plan ni fecha.
  IF EXISTS (SELECT 1 FROM pg_proc
             WHERE  oid = 'public.rpc_request_subscription_cancellation()'::regprocedure
               AND  (pronargs <> 0 OR NOT prosecdef)) THEN
    v_bad := v_bad || '(f1) rpc_request_subscription_cancellation() debe ser SECURITY DEFINER y no aceptar parámetros; ';
  END IF;
  IF has_function_privilege('anon', 'public.rpc_request_subscription_cancellation()', 'EXECUTE') THEN
    v_bad := v_bad || '(f1) anon puede ejecutar la RPC de cancelación; ';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpc_request_subscription_cancellation()', 'EXECUTE') THEN
    v_bad := v_bad || '(f1) authenticated PERDIÓ el EXECUTE de la RPC de cancelación (la ruta /api/billing/cancel quedaría rota); ';
  END IF;

  -- (f2) El miembro B (no titular) NO puede encolar el correo: P0403 y ninguna fila
  --      plan_downgraded hacia él ni hacia nadie.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated', 'app_metadata', json_build_object('account_id', v_account::text))::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  EXECUTE 'RESET ROLE';
  IF v_sqlstate <> 'P0403' THEN
    v_bad := v_bad || format('(f2) un miembro NO titular debía recibir P0403 al cancelar: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;
  SELECT count(*) INTO v_n FROM public.email_logs WHERE event_type = 'plan_downgraded' AND user_id IN (v_user_a, v_user_b);
  IF v_n <> 0 THEN
    v_bad := v_bad || format('(f2) un miembro no titular dejó %s filas plan_downgraded; debían ser 0; ', v_n);
  END IF;

  -- (f3) Intento de elegir destinatario por parámetro: la función no existe con
  --      argumentos (42883), no hay camino para eso.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated', 'app_metadata', json_build_object('account_id', v_account::text))::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE 'SELECT public.rpc_request_subscription_cancellation(''victima-phishing@example.com'')';
    v_sqlstate := 'NO_ERROR'; v_msg := 'la RPC aceptó un argumento';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_sqlstate <> '42883' THEN
    v_bad := v_bad || format('(f3) la RPC con un argumento debía dar 42883 (no existe): sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;

  -- (f4) El titular A cancela: la RPC responde y encola EXACTAMENTE un correo
  --      plan_downgraded con user_id = A y recipient = el email de A en auth.users.
  BEGIN
    v_result := public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  EXECUTE 'RESET ROLE';
  IF v_sqlstate <> 'NO_ERROR' THEN
    v_bad := v_bad || format('(f4) la cancelación del titular con plan pago debía funcionar: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  ELSE
    IF (v_result->>'from_plan') IS DISTINCT FROM 'pro' THEN
      v_bad := v_bad || format('(f4) la RPC devolvió from_plan=%s, se esperaba pro; ', v_result->>'from_plan');
    END IF;
    SELECT count(*) INTO v_n FROM public.email_logs WHERE event_type = 'plan_downgraded' AND user_id IN (v_user_a, v_user_b);
    IF v_n <> 1 THEN
      v_bad := v_bad || format('(f4) la cancelación debía encolar exactamente 1 correo plan_downgraded; encoló %s; ', v_n);
    END IF;
    SELECT e.* INTO r FROM public.email_logs e WHERE e.event_type = 'plan_downgraded' AND e.user_id IN (v_user_a, v_user_b) LIMIT 1;
    IF r.user_id IS DISTINCT FROM v_user_a THEN
      v_bad := v_bad || format('(f4) el correo quedó con user_id=%s, se esperaba el titular %s; ', r.user_id, v_user_a);
    END IF;
    IF r.recipient IS DISTINCT FROM (SELECT email FROM auth.users WHERE id = v_user_a) THEN
      v_bad := v_bad || format('(f4) el destinatario es %s, debía ser el email de auth.users del titular; ', r.recipient);
    END IF;
    IF r.status IS DISTINCT FROM 'pending' THEN
      v_bad := v_bad || format('(f4) el correo debía nacer pending (lo necesita el trigger de envío); nació %s; ', r.status);
    END IF;
    IF (r.metadata->>'plan') IS DISTINCT FROM 'pro'
       OR (r.metadata->>'reason') IS DISTINCT FROM 'user_requested'
       OR (r.metadata->>'plan_expires_at') IS NULL THEN
      v_bad := v_bad || format('(f4) metadata inesperada (plan/reason/plan_expires_at): %s; ', r.metadata);
    END IF;
    IF r.subject IS NULL OR r.subject !~* 'cancelad' THEN
      v_bad := v_bad || format('(f4) asunto inesperado: %L; ', r.subject);
    END IF;
  END IF;

  -- (f5) Segunda cancelación: P0409 y NINGÚN correo nuevo (no se puede spamear
  --      al propio titular reintentando).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated', 'app_metadata', json_build_object('account_id', v_account::text))::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  EXECUTE 'RESET ROLE';
  IF v_sqlstate <> 'P0409' THEN
    v_bad := v_bad || format('(f5) la segunda cancelación debía dar P0409: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;
  SELECT count(*) INTO v_n FROM public.email_logs WHERE event_type = 'plan_downgraded' AND user_id IN (v_user_a, v_user_b);
  IF v_n <> 1 THEN
    v_bad := v_bad || format('(f5) tras el reintento hay %s correos plan_downgraded; debía seguir habiendo 1; ', v_n);
  END IF;

  -- (f6) Cuenta sin plan pago: P0400 y ningún correo (se baja el plan de la cuenta de A).
  UPDATE public.accounts SET billing_plan = 'gratis', billing_status = 'active', plan_expires_at = NULL
  WHERE  id = v_account;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated', 'app_metadata', json_build_object('account_id', v_account::text))::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM public.rpc_request_subscription_cancellation();
    v_sqlstate := 'NO_ERROR';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  EXECUTE 'RESET ROLE';
  IF v_sqlstate <> 'P0400' THEN
    v_bad := v_bad || format('(f6) sin plan pago debía dar P0400: sqlstate=%s msg=%s; ', v_sqlstate, v_msg);
  END IF;
  SELECT count(*) INTO v_n FROM public.email_logs WHERE event_type = 'plan_downgraded' AND user_id IN (v_user_a, v_user_b);
  IF v_n <> 1 THEN
    v_bad := v_bad || format('(f6) sin plan pago no debía encolarse nada; hay %s plan_downgraded; ', v_n);
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE EMAIL-LOGS-INSERT-CERRADO FAILED (f, cancelación de plan): %', v_bad;
  END IF;
  RAISE NOTICE 'PASS (f): la cancelación encola 1 correo con destinatario y user_id de la sesión; no titular → P0403 sin correo; sin parámetros; reintento → P0409 sin correo; sin plan pago → P0400 sin correo.';
END $$;

ROLLBACK;
