-- =============================================================================
-- GATE: test_ia_ocr_cuota_reserva.sql
-- CHANGE: v31-ia-ratelimit-budget (H-11) — tanda única, grupo 1 (tasks 1.1/1.3)
--
-- Verifica la migración 20261090000001_ia_ocr_cuota_reserva.sql:
--   (a) columnas profiles.ai_ocr_used / ai_ocr_window_count /
--       ai_ocr_window_started_at y plan_limits.max_ai_ocr_per_month, con el
--       seed 5/30/120/300 (OQ-1) y NOT NULL;
--   (b) `authenticated` y `anon` SIN privilegio de UPDATE/INSERT sobre las 3
--       columnas de profiles (allow-list de columnas: nacen protegidas); en
--       plan_limits la postura vigente es RLS (escritura sólo admin), que se asserta;
--   (c) ACL de rpc_reserve_ai_usage(text): anon/PUBLIC sin EXECUTE,
--       authenticated con EXECUTE; SECURITY DEFINER con search_path fijado;
--   (d..i,k) la RPC se EJECUTA de verdad: concede e incrementa; used = limit ->
--       quota_exceeded sin incremento; 4ª reserva en 60 s -> rate_limited con
--       retry_after_seconds >= 1 sin incremento; ventana vencida -> concede con
--       count = 1; contador inválido -> 22023; sin sesión -> P0401; el plan lo
--       da rpc_my_effective_plan() (cuenta pro + perfil gratis -> límite 300);
--   (j) el comando VIVO de cron.job `reset-ai-counters` resetea también las
--       tres columnas nuevas;
--   (l) concurrencia real (dblink): una reserva que espera el lock de fila de
--       otra transacción re-evalúa el WHERE sobre la versión ya incrementada y
--       NO concede el cupo único (READ COMMITTED). Si dblink no está
--       disponible se declara y se cubre el borde con intentos secuenciales.
--
-- REGLA: se asserta el EFECTO (filas, contadores, claves exactas), nunca
-- "no hubo error". Cleanup: DO block separado al final, resuelve por email.
-- =============================================================================

-- ── (a) (b) (c) (j) Introspección ───────────────────────────────────────────
DO $$
DECLARE
  v_sig    text := 'public.rpc_reserve_ai_usage(text)';
  v_oid    oid;
  v_secdef boolean;
  v_config text[];
  v_acl    aclitem[];
  v_col    text;
  v_cmd    text;
  v_priv   text;
  v_seed   record;
BEGIN
  -- (a) columnas
  FOREACH v_col IN ARRAY ARRAY['ai_ocr_used', 'ai_ocr_window_count', 'ai_ocr_window_started_at'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = v_col) THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (a): falta la columna profiles.%.', v_col;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'plan_limits'
                   AND column_name = 'max_ai_ocr_per_month' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (a): falta plan_limits.max_ai_ocr_per_month NOT NULL.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'profiles'
                   AND column_name = 'ai_ocr_used' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (a): profiles.ai_ocr_used debe ser NOT NULL.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'profiles'
                   AND column_name = 'ai_ocr_window_count' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (a): profiles.ai_ocr_window_count debe ser NOT NULL.';
  END IF;

  -- (a) seed OQ-1: 5 / 30 / 120 / 300 exactos
  FOR v_seed IN
    SELECT * FROM (VALUES ('gratis', 5), ('inicial', 30), ('avanzado', 120), ('pro', 300)) AS t(plan, expected)
  LOOP
    IF (SELECT max_ai_ocr_per_month FROM public.plan_limits WHERE plan = v_seed.plan)
         IS DISTINCT FROM v_seed.expected THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (a): plan_limits[%].max_ai_ocr_per_month debía ser % y es %.',
        v_seed.plan, v_seed.expected,
        (SELECT max_ai_ocr_per_month FROM public.plan_limits WHERE plan = v_seed.plan);
    END IF;
  END LOOP;

  -- (b) ningún rol de cliente escribe las columnas
  FOREACH v_col IN ARRAY ARRAY['ai_ocr_used', 'ai_ocr_window_count', 'ai_ocr_window_started_at'] LOOP
    FOREACH v_priv IN ARRAY ARRAY['UPDATE', 'INSERT'] LOOP
      IF has_column_privilege('authenticated', 'public.profiles', v_col, v_priv)
         OR has_column_privilege('anon', 'public.profiles', v_col, v_priv) THEN
        RAISE EXCEPTION 'GATE IA-OCR FAILED (b): authenticated/anon tienen % sobre profiles.%.', v_priv, v_col;
      END IF;
    END LOOP;
  END LOOP;
  -- plan_limits ya otorga privilegios de tabla a authenticated (default de Supabase); la
  -- protección vigente —no cambia con esta columna— es RLS: lectura pública, escritura sólo
  -- con profiles.role = 'admin'. Se asserta esa postura (no una ACL de columna que no existe).
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.plan_limits'::regclass) THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (b): plan_limits perdió su RLS: max_ai_ocr_per_month quedaría escribible por cualquier authenticated.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.plan_limits'::regclass
      AND polcmd IN ('a', 'w', 'd', '*')
      AND pg_get_expr(polqual, polrelid) IS DISTINCT FROM
          (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
            WHERE polrelid = 'public.plan_limits'::regclass AND polname = 'plan_limits_admin_write')
  ) THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (b): plan_limits tiene una policy de escritura distinta de la de admin.';
  END IF;
  IF (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
       WHERE polrelid = 'public.plan_limits'::regclass AND polname = 'plan_limits_admin_write') NOT LIKE '%admin%' THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (b): plan_limits_admin_write ya no exige rol admin.';
  END IF;

  -- (c) ACL
  v_oid := to_regprocedure(v_sig);
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): % no existe.', v_sig;
  END IF;
  SELECT p.prosecdef, p.proconfig, p.proacl INTO v_secdef, v_config, v_acl FROM pg_proc p WHERE p.oid = v_oid;
  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): % debe ser SECURITY DEFINER.', v_sig;
  END IF;
  IF v_config IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search_path=%') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): % no fija search_path.', v_sig;
  END IF;
  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): % tiene proacl NULL — falta el REVOKE ALL FROM PUBLIC.', v_sig;
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): anon NO debe poder ejecutar %.', v_sig;
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): authenticated debe poder ejecutar %.', v_sig;
  END IF;
  IF obj_description(v_oid, 'pg_proc') IS NULL THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (c): % no tiene COMMENT.', v_sig;
  END IF;

  -- (j) comando vivo del cron
  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'reset-ai-counters';
  IF v_cmd IS NULL THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (j): no existe el job reset-ai-counters.';
  END IF;
  IF (SELECT schedule FROM cron.job WHERE jobname = 'reset-ai-counters') <> '0 0 1 * *' THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (j): reset-ai-counters cambió de schedule (debe seguir en 0 0 1 * *).';
  END IF;
  FOREACH v_col IN ARRAY ARRAY['ai_queries_used = 0', 'ai_advice_used = 0', 'ai_ocr_used = 0',
                               'ai_ocr_window_count = 0', 'ai_ocr_window_started_at = NULL', 'usage_reset_at = now()'] LOOP
    IF position(v_col IN v_cmd) = 0 THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (j): el comando vivo de reset-ai-counters no incluye "%": %', v_col, v_cmd;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS (a)(b)(c)(j): columnas + seed 5/30/120/300, columnas sin escritura de cliente, ACL exacta, cron reseteando las 3 columnas.';
END $$;

-- ── (d..i,k) Comportamiento: la RPC se EJECUTA ──────────────────────────────
DO $$
DECLARE
  v_email   CONSTANT text := 'ia-ocr-cuota-gate@test.local';
  v_user    uuid;
  v_account uuid;
  r         jsonb;
  v_used    integer;
  v_count   integer;
  v_start   timestamptz;
  v_expected_reset timestamptz;
  i         integer;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = v_email;
  IF v_user IS NULL THEN
    v_user := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
            jsonb_build_object('name', 'Gate IA OCR'));
  END IF;
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (setup): el alta del usuario no aprovisionó cuenta.';
  END IF;

  -- Plan efectivo explícito: gratis (límite 5).
  UPDATE public.accounts
     SET billing_plan = 'gratis', billing_status = 'active', trial_plan = NULL, trial_expires_at = NULL,
         plan_expires_at = NULL, billing_exempt = false
   WHERE id = v_account;
  UPDATE public.profiles
     SET ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL
   WHERE id = v_user;

  v_expected_reset := (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC';

  -- (h) sin sesión -> P0401
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM public.rpc_reserve_ai_usage('ocr');
    RAISE EXCEPTION 'GATE IA-OCR FAILED (h): la RPC aceptó una llamada sin auth.uid().';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (setup): auth.uid() no resuelve con request.jwt.claims local.';
  END IF;

  -- (h) contador inválido -> 22023 y sin efecto
  BEGIN
    PERFORM public.rpc_reserve_ai_usage('queries');
    RAISE EXCEPTION 'GATE IA-OCR FAILED (h): p_counter=queries aceptado.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  SELECT ai_ocr_used INTO v_used FROM public.profiles WHERE id = v_user;
  IF v_used <> 0 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (h): un contador inválido movió ai_ocr_used a %.', v_used;
  END IF;

  -- (d) (k) la reserva con cupo concede e incrementa
  r := public.rpc_reserve_ai_usage('ocr');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 1 OR (r->>'limit')::int <> 5 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (d): 1ª reserva debía conceder used=1 limit=5 y devolvió %.', r;
  END IF;
  IF (r->>'reset_at')::timestamptz <> v_expected_reset THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (d): reset_at debía ser la PRÓXIMA renovación % y es %.', v_expected_reset, r->>'reset_at';
  END IF;
  SELECT ai_ocr_used, ai_ocr_window_count INTO v_used, v_count FROM public.profiles WHERE id = v_user;
  IF v_used <> 1 OR v_count <> 1 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (d): el perfil debía quedar used=1 count=1 y quedó %/%.', v_used, v_count;
  END IF;
  r := public.rpc_reserve_ai_usage('ocr');
  r := public.rpc_reserve_ai_usage('ocr');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 3 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (d): 3ª reserva debía conceder used=3 y devolvió %.', r;
  END IF;

  -- (f) la 4ª reserva dentro de 60 s -> rate_limited, sin incremento
  r := public.rpc_reserve_ai_usage('ocr');
  IF (r->>'allowed')::boolean OR r->>'reason' <> 'rate_limited' THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (f): la 4ª reserva debía ser rate_limited y devolvió %.', r;
  END IF;
  IF (r->>'retry_after_seconds')::int < 1 OR (r->>'retry_after_seconds')::int > 60 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (f): retry_after_seconds fuera de [1,60]: %.', r;
  END IF;
  SELECT ai_ocr_used, ai_ocr_window_count INTO v_used, v_count FROM public.profiles WHERE id = v_user;
  IF v_used <> 3 OR v_count <> 3 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (f): una reserva denegada incrementó (used=%, count=%).', v_used, v_count;
  END IF;

  -- (g) ventana vencida -> concede y reabre con count = 1
  UPDATE public.profiles SET ai_ocr_window_started_at = now() - interval '61 seconds' WHERE id = v_user;
  r := public.rpc_reserve_ai_usage('ocr');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 4 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (g): con la ventana vencida debía conceder used=4 y devolvió %.', r;
  END IF;
  SELECT ai_ocr_window_count, ai_ocr_window_started_at INTO v_count, v_start FROM public.profiles WHERE id = v_user;
  IF v_count <> 1 OR v_start <= now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (g): la ventana debía reabrirse con count=1 y started_at reciente (count=%, started_at=%).', v_count, v_start;
  END IF;

  -- (e) used = limit -> quota_exceeded, sin incremento (con la ventana libre)
  UPDATE public.profiles SET ai_ocr_used = 5, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL WHERE id = v_user;
  r := public.rpc_reserve_ai_usage('ocr');
  IF (r->>'allowed')::boolean OR r->>'reason' <> 'quota_exceeded'
     OR (r->>'used')::int <> 5 OR (r->>'limit')::int <> 5
     OR (r->>'reset_at')::timestamptz <> v_expected_reset THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (e): used=limit debía ser quota_exceeded(5/5, próximo reset) y devolvió %.', r;
  END IF;
  SELECT ai_ocr_used, ai_ocr_window_count INTO v_used, v_count FROM public.profiles WHERE id = v_user;
  IF v_used <> 5 OR v_count <> 0 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (e): una reserva sin cupo incrementó (used=%, count=%).', v_used, v_count;
  END IF;
  -- precedencia: sin cupo Y en ráfaga -> gana quota_exceeded
  UPDATE public.profiles SET ai_ocr_window_count = 3, ai_ocr_window_started_at = now() WHERE id = v_user;
  r := public.rpc_reserve_ai_usage('ocr');
  IF r->>'reason' <> 'quota_exceeded' THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (e): sin cupo y en ráfaga debía ganar quota_exceeded y devolvió %.', r;
  END IF;

  -- (i) el plan lo da rpc_my_effective_plan(): cuenta pro + perfil gratis -> límite 300
  UPDATE public.accounts SET billing_plan = 'pro' WHERE id = v_account;
  UPDATE public.profiles
     SET billing_plan = 'gratis', ai_ocr_used = 100, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL
   WHERE id = v_user;
  r := public.rpc_reserve_ai_usage('ocr');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'limit')::int <> 300 OR (r->>'used')::int <> 101 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (i): cuenta pro + perfil gratis debía conceder con límite 300 y devolvió %.', r;
  END IF;
  UPDATE public.profiles SET ai_ocr_used = 300, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL WHERE id = v_user;
  r := public.rpc_reserve_ai_usage('ocr');
  IF r->>'reason' <> 'quota_exceeded' OR (r->>'limit')::int <> 300 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (i): con 300/300 debía ser quota_exceeded(300) y devolvió %.', r;
  END IF;
  -- triangulación: un cambio de límite en plan_limits se refleja sin deploy
  UPDATE public.plan_limits SET max_ai_ocr_per_month = 301 WHERE plan = 'pro';
  r := public.rpc_reserve_ai_usage('ocr');
  UPDATE public.plan_limits SET max_ai_ocr_per_month = 300 WHERE plan = 'pro';
  IF NOT ((r->>'allowed')::boolean) OR (r->>'limit')::int <> 301 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (i): subir el límite a 301 debía conceder la lectura 301 y devolvió %.', r;
  END IF;

  -- (borde) cota dura: con límite 5, 8 intentos separados por ventanas vencidas conceden EXACTAMENTE 5
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;
  UPDATE public.profiles SET ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL WHERE id = v_user;
  v_count := 0;
  FOR i IN 1..8 LOOP
    UPDATE public.profiles SET ai_ocr_window_started_at = now() - interval '61 seconds' WHERE id = v_user;
    r := public.rpc_reserve_ai_usage('ocr');
    IF (r->>'allowed')::boolean THEN v_count := v_count + 1; END IF;
  END LOOP;
  SELECT ai_ocr_used INTO v_used FROM public.profiles WHERE id = v_user;
  IF v_count <> 5 OR v_used <> 5 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (borde): 8 intentos con límite 5 debían conceder exactamente 5 y concedieron % (used=%).', v_count, v_used;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'PASS (d..i,k): concede/incrementa, quota_exceeded y rate_limited sin incremento, ventana vencida, 22023/P0401, plan efectivo, cota dura de 5.';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE;
END $$;

-- ── (l) Concurrencia real con dblink ────────────────────────────────────────
DO $$
DECLARE
  v_email CONSTANT text := 'ia-ocr-cuota-gate@test.local';
  v_user  uuid;
  v_conn  text;
  v_claims text;
  v_res_a text;
  v_res_b text;
  v_busy  integer;
  v_used  integer;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = v_email;
  BEGIN
    CREATE EXTENSION IF NOT EXISTS dblink;
    -- dblink exige que la password se USE de verdad (aun para postgres): hay que entrar por TCP
    -- (scram), no por el socket unix (trust). Correr el gate con `psql -h <host>` (CI lo hace);
    -- por el socket local inet_server_addr() es NULL y el bloque se degrada declarándolo.
    IF inet_server_addr() IS NULL THEN
      RAISE EXCEPTION 'conexión por socket unix: sin TCP no hay credencial que dblink acepte';
    END IF;
    v_conn := format('host=%s port=%s dbname=%s user=%s password=postgres',
                     host(inet_server_addr()), inet_server_port(), current_database(), current_user);
    PERFORM dblink_connect('ocr_a', v_conn);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE IA-OCR (l): dblink no disponible (%) — se cubre el borde con intentos secuenciales, ya asertado arriba.', SQLERRM;
    RETURN;
  END;

  BEGIN
    PERFORM dblink_connect('ocr_b', v_conn);
    v_claims := json_build_object('sub', v_user::text, 'role', 'authenticated')::text;

    -- Cupo ÚNICO: gratis (5), usadas 4, ventana libre (cada dblink_exec autocommitea).
    PERFORM dblink_exec('ocr_a', format('UPDATE public.profiles SET ai_ocr_used = 4, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL WHERE id = %L', v_user));
    PERFORM * FROM dblink('ocr_a', format('SELECT set_config(''request.jwt.claims'', %L, false)', v_claims)) AS t(x text);
    PERFORM * FROM dblink('ocr_b', format('SELECT set_config(''request.jwt.claims'', %L, false)', v_claims)) AS t(x text);

    -- A abre transacción y reserva (retiene el lock de fila, sin commitear).
    PERFORM dblink_exec('ocr_a', 'BEGIN');
    SELECT r INTO v_res_a FROM dblink('ocr_a', 'SELECT public.rpc_reserve_ai_usage(''ocr'')::text') AS t(r text);

    -- B pide la misma reserva: debe QUEDAR BLOQUEADA esperando el lock de A.
    PERFORM dblink_send_query('ocr_b', 'SELECT public.rpc_reserve_ai_usage(''ocr'')::text');
    PERFORM pg_sleep(0.7);
    v_busy := dblink_is_busy('ocr_b');
    IF v_busy <> 1 THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (l): la reserva concurrente NO esperó el lock de fila (is_busy=%): no hay serialización.', v_busy;
    END IF;

    -- A commitea -> B re-evalúa el WHERE sobre la versión incrementada (5/5) y debe ser DENEGADA.
    PERFORM dblink_exec('ocr_a', 'COMMIT');
    SELECT r INTO v_res_b FROM dblink_get_result('ocr_b') AS t(r text);

    IF (v_res_a::jsonb->>'allowed')::boolean IS NOT TRUE OR (v_res_a::jsonb->>'used')::int <> 5 THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (l): A debía conceder el cupo único (used=5) y devolvió %.', v_res_a;
    END IF;
    IF (v_res_b::jsonb->>'allowed')::boolean IS NOT FALSE OR v_res_b::jsonb->>'reason' <> 'quota_exceeded' THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (l): B debía ser quota_exceeded tras el commit de A y devolvió %.', v_res_b;
    END IF;
    SELECT ai_ocr_used INTO v_used FROM public.profiles WHERE id = v_user;
    IF v_used <> 5 THEN
      RAISE EXCEPTION 'GATE IA-OCR FAILED (l): con cupo 1 y dos reservas concurrentes ai_ocr_used debía quedar en 5 y quedó %.', v_used;
    END IF;

    PERFORM dblink_disconnect('ocr_a');
    PERFORM dblink_disconnect('ocr_b');
    RAISE NOTICE 'PASS (l): con un solo cupo y dos reservas concurrentes se concede una sola; la segunda esperó el lock y re-evaluó.';
  EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_disconnect('ocr_a'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('ocr_b'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
  END;
END $$;

-- ═══ CLEANUP — resuelve por email, sobrevive corridas cortadas ══════════════
DO $$
DECLARE
  v_user uuid;
  v_account uuid;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = 'ia-ocr-cuota-gate@test.local';
  IF v_user IS NULL THEN RETURN; END IF;
  UPDATE public.profiles SET ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL, billing_plan = 'gratis' WHERE id = v_user;
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NOT NULL THEN
    UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;
  END IF;
  UPDATE public.plan_limits SET max_ai_ocr_per_month = 300 WHERE plan = 'pro' AND max_ai_ocr_per_month = 301;
  -- dblink lo instala el bloque (l) sólo para este gate; nada más en el repo lo usa.
  DROP EXTENSION IF EXISTS dblink;
  IF (SELECT ai_ocr_used FROM public.profiles WHERE id = v_user) <> 0 THEN
    RAISE EXCEPTION 'GATE IA-OCR FAILED (cleanup): el contador no quedó en 0.';
  END IF;
  RAISE NOTICE 'PASS (cleanup): fixtures revertidos.';
END $$;
