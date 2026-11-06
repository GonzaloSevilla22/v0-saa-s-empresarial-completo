-- =============================================================================
-- GATE: test_ia_copilot_v2.sql
-- CHANGE: ia-copilot-v2 (tanda A) — migración 20261095000001_ia_copilot_v2.sql
--
-- Verifica, EJECUTANDO las RPCs (no sólo que existan):
--   (a) ai_conversations con las columnas nuevas (model, tools_used, latency_ms,
--       prompt_tokens, completion_tokens, outcome con CHECK, thread_id) y el índice;
--       profiles con la ventana de ráfaga de consultas sin escritura de cliente;
--   (b) ai_feedback: RLS activa, SELECT propio, SIN privilegio de escritura para
--       anon/authenticated (INSERT directo como authenticated -> 42501);
--   (c) rpc_set_ai_feedback: P0401, 22023 (tipo, valoración, 'insight'), P0404
--       (inexistente, de otro usuario de la misma cuenta, de otra cuenta), alta,
--       cambio (una sola fila), borrado con NULL, y la RLS de lectura entre usuarios;
--   (d) el guardado del Copiloto: INSERT como authenticated CON account_id pasa y
--       SIN account_id lo rechaza la RLS (la causa del registro roto desde junio);
--   (e) rpc_reserve_ai_usage('queries'): concede e incrementa, 6ª dentro de 60 s
--       -> rate_limited sin incremento, ventana vencida, quota_exceeded con
--       precedencia sobre la ráfaga, 'ocr' con la misma respuesta y sin tocar
--       ai_queries_*, 'advice' -> 22023, sin sesión -> P0401;
--   (f) concurrencia real (dblink): con un cupo y dos reservas concurrentes
--       se concede exactamente una;
--   (g) ACLs de las dos RPCs y el comando VIVO del cron reset-ai-counters.
--
-- REGLA: se asserta el EFECTO (filas, contadores, claves exactas). Cleanup al
-- final en un DO separado, resuelve por email.
-- =============================================================================

-- ── (a) (b) (g) Introspección ───────────────────────────────────────────────
DO $$
DECLARE
  v_col  text;
  v_oid  oid;
  v_cmd  text;
  v_acl  aclitem[];
  v_priv text;
  v_role text;
BEGIN
  FOREACH v_col IN ARRAY ARRAY['model', 'tools_used', 'latency_ms', 'prompt_tokens', 'completion_tokens', 'outcome', 'thread_id'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'ai_conversations' AND column_name = v_col) THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): falta ai_conversations.%.', v_col;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'ai_conversations'
                   AND column_name = 'tools_used' AND is_nullable = 'NO' AND data_type = 'jsonb') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): ai_conversations.tools_used debe ser jsonb NOT NULL.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.ai_conversations'::regclass AND contype = 'c'
                   AND pg_get_constraintdef(oid) LIKE '%outcome%' AND pg_get_constraintdef(oid) LIKE '%fallback%') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): falta el CHECK de ai_conversations.outcome.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'ai_conversations'
                   AND indexdef LIKE '%(user_id, created_at DESC)%') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): falta el índice (user_id, created_at DESC) de ai_conversations.';
  END IF;

  FOREACH v_col IN ARRAY ARRAY['ai_queries_window_count', 'ai_queries_window_started_at'] LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = v_col) THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): falta profiles.%.', v_col;
    END IF;
    FOREACH v_priv IN ARRAY ARRAY['UPDATE', 'INSERT'] LOOP
      IF has_column_privilege('authenticated', 'public.profiles', v_col, v_priv)
         OR has_column_privilege('anon', 'public.profiles', v_col, v_priv) THEN
        RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): authenticated/anon tienen % sobre profiles.%.', v_priv, v_col;
      END IF;
    END LOOP;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'profiles'
                   AND column_name = 'ai_queries_window_count' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (a): profiles.ai_queries_window_count debe ser NOT NULL.';
  END IF;

  -- (b) ai_feedback
  IF to_regclass('public.ai_feedback') IS NULL THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): no existe public.ai_feedback.';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.ai_feedback'::regclass) THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): ai_feedback sin RLS.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.ai_feedback'::regclass AND polcmd <> 'r') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): ai_feedback tiene una policy que no es de SELECT.';
  END IF;
  IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.ai_feedback'::regclass AND polcmd = 'r') <> 1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): ai_feedback debe tener exactamente una policy de SELECT.';
  END IF;
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
      IF has_table_privilege(v_role, 'public.ai_feedback', v_priv) THEN
        RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): % tiene % sobre ai_feedback.', v_role, v_priv;
      END IF;
    END LOOP;
  END LOOP;
  IF has_table_privilege('anon', 'public.ai_feedback', 'SELECT') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): anon no debe leer ai_feedback.';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.ai_feedback', 'SELECT') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): authenticated debe poder leer ai_feedback (acotado por la RLS).';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'ai_feedback'
                   AND indexdef LIKE '%(account_id, subject_type, created_at)%') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): falta el índice (account_id, subject_type, created_at).';
  END IF;

  -- (g) ACLs de las dos RPCs
  FOREACH v_cmd IN ARRAY ARRAY['public.rpc_set_ai_feedback(text,uuid,text)', 'public.rpc_reserve_ai_usage(text)'] LOOP
    v_oid := to_regprocedure(v_cmd);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): % no existe.', v_cmd;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): % debe ser SECURITY DEFINER.', v_cmd;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proconfig) c WHERE p.oid = v_oid AND c LIKE 'search_path=%') THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): % no fija search_path.', v_cmd;
    END IF;
    SELECT proacl INTO v_acl FROM pg_proc WHERE oid = v_oid;
    IF v_acl IS NULL THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): % tiene proacl NULL (falta REVOKE FROM PUBLIC).', v_cmd;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): anon NO debe ejecutar %.', v_cmd;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): authenticated debe ejecutar %.', v_cmd;
    END IF;
    IF obj_description(v_oid, 'pg_proc') IS NULL THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): % no tiene COMMENT.', v_cmd;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_reserve_ai_usage' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): rpc_reserve_ai_usage tiene más de una definición viva (overload).';
  END IF;
  IF position('queries' IN pg_get_functiondef('public.rpc_reserve_ai_usage(text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): rpc_reserve_ai_usage no tiene la rama queries.';
  END IF;

  -- (g) cron
  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'reset-ai-counters';
  IF v_cmd IS NULL THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): no existe el job reset-ai-counters.';
  END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'reset-ai-counters') <> 1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): hay más de un job reset-ai-counters.';
  END IF;
  IF (SELECT schedule FROM cron.job WHERE jobname = 'reset-ai-counters') <> '0 0 1 * *' THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): reset-ai-counters cambió de schedule.';
  END IF;
  FOREACH v_col IN ARRAY ARRAY['ai_queries_used = 0', 'ai_advice_used = 0', 'ai_ocr_used = 0', 'ai_ocr_window_count = 0',
                               'ai_ocr_window_started_at = NULL', 'ai_queries_window_count = 0',
                               'ai_queries_window_started_at = NULL', 'usage_reset_at = now()'] LOOP
    IF position(v_col IN v_cmd) = 0 THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (g): el comando vivo de reset-ai-counters no incluye "%": %', v_col, v_cmd;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS (a)(b)(g): columnas, ai_feedback sin escritura de cliente, ACLs exactas, una sola rpc_reserve_ai_usage, cron con las columnas nuevas.';
END $$;

-- ── Fixtures: dos usuarios, cada uno con su cuenta ──────────────────────────
DO $$
DECLARE
  v_email text;
  v_user  uuid;
BEGIN
  FOREACH v_email IN ARRAY ARRAY['ia-copilot-gate-1@test.local', 'ia-copilot-gate-2@test.local'] LOOP
    SELECT id INTO v_user FROM auth.users WHERE email = v_email;
    IF v_user IS NULL THEN
      v_user := gen_random_uuid();
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
              jsonb_build_object('name', 'Gate IA Copilot'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE user_id = v_user) THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (setup): % no tiene cuenta aprovisionada.', v_email;
    END IF;
  END LOOP;
END $$;

-- ── (c) (d) rpc_set_ai_feedback, RLS y el guardado con account_id ───────────
DO $$
DECLARE
  v_u1 uuid; v_u2 uuid; v_a1 uuid; v_a2 uuid;
  v_conv1 uuid; v_conv_other_user uuid; v_conv_other_acct uuid;
  r jsonb; n integer;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'ia-copilot-gate-1@test.local';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'ia-copilot-gate-2@test.local';
  SELECT account_id INTO v_a1 FROM public.account_members WHERE user_id = v_u1 ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_a2 FROM public.account_members WHERE user_id = v_u2 ORDER BY created_at LIMIT 1;
  IF v_a1 = v_a2 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (setup): los dos usuarios comparten cuenta.'; END IF;
  DELETE FROM public.ai_feedback WHERE user_id IN (v_u1, v_u2);
  DELETE FROM public.ai_conversations WHERE user_id IN (v_u1, v_u2);

  -- Filas del Copiloto armadas como superusuario (la RLS no aplica).
  INSERT INTO public.ai_conversations (user_id, account_id, question, answer, outcome)
    VALUES (v_u1, v_a1, 'p1', 'r1', 'answer') RETURNING id INTO v_conv1;
  INSERT INTO public.ai_conversations (user_id, account_id, question, answer, outcome)
    VALUES (v_u2, v_a1, 'p2', 'r2', 'answer') RETURNING id INTO v_conv_other_user;   -- misma cuenta, otro usuario
  INSERT INTO public.ai_conversations (user_id, account_id, question, answer, outcome)
    VALUES (v_u2, v_a2, 'p3', 'r3', 'answer') RETURNING id INTO v_conv_other_acct;   -- otra cuenta y otro usuario

  -- sin sesión -> P0401
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM public.rpc_set_ai_feedback('copilot_answer', v_conv1, 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): la RPC aceptó una llamada sin auth.uid().';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u1::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_u1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (setup): auth.uid() no resuelve con request.jwt.claims local.';
  END IF;

  -- dominios -> 22023
  BEGIN
    PERFORM public.rpc_set_ai_feedback('otro', v_conv1, 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): tipo fuera de dominio aceptado.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN
    PERFORM public.rpc_set_ai_feedback('copilot_answer', v_conv1, 'genial');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): valoración fuera de dominio aceptada.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN
    PERFORM public.rpc_set_ai_feedback('insight', gen_random_uuid(), 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): la rama insight aún no está habilitada y fue aceptada.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;

  -- sujeto inexistente / de otro usuario (misma cuenta) / de otra cuenta -> P0404, sin escritura
  BEGIN
    PERFORM public.rpc_set_ai_feedback('copilot_answer', gen_random_uuid(), 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): respuesta inexistente aceptada.';
  EXCEPTION WHEN SQLSTATE 'P0404' THEN NULL; END;
  BEGIN
    PERFORM public.rpc_set_ai_feedback('copilot_answer', v_conv_other_user, 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): respuesta de otro usuario de la misma cuenta aceptada.';
  EXCEPTION WHEN SQLSTATE 'P0404' THEN NULL; END;
  BEGIN
    PERFORM public.rpc_set_ai_feedback('copilot_answer', v_conv_other_acct, 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): respuesta de otra cuenta aceptada.';
  EXCEPTION WHEN SQLSTATE 'P0404' THEN NULL; END;
  SELECT count(*) INTO n FROM public.ai_feedback WHERE user_id = v_u1;
  IF n <> 0 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): un rechazo dejó % filas.', n; END IF;

  -- me sirvió
  r := public.rpc_set_ai_feedback('copilot_answer', v_conv1, 'useful');
  IF r->>'rating' <> 'useful' OR r->>'subject_type' <> 'copilot_answer' OR (r->>'subject_id')::uuid <> v_conv1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): la respuesta de la RPC no es la esperada: %.', r;
  END IF;
  SELECT count(*) INTO n FROM public.ai_feedback
   WHERE user_id = v_u1 AND subject_type = 'copilot_answer' AND subject_id = v_conv1 AND rating = 'useful' AND account_id = v_a1;
  IF n <> 1 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): faltó la fila useful (n=%).', n; END IF;

  -- cambiar de opinión: la misma fila, no una segunda
  r := public.rpc_set_ai_feedback('copilot_answer', v_conv1, 'not_useful');
  SELECT count(*) INTO n FROM public.ai_feedback WHERE user_id = v_u1 AND subject_id = v_conv1;
  IF n <> 1 OR NOT EXISTS (SELECT 1 FROM public.ai_feedback WHERE user_id = v_u1 AND subject_id = v_conv1 AND rating = 'not_useful') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): cambiar la valoración debía dejar UNA fila not_useful (n=%).', n;
  END IF;

  -- RLS de lectura: U1 la ve (rol authenticated), U2 no
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.ai_feedback WHERE subject_id = v_conv1;
  IF n <> 1 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): U1 debía ver su valoración (n=%).', n; END IF;
  -- escritura directa -> rechazada por privilegio
  BEGIN
    INSERT INTO public.ai_feedback (account_id, user_id, subject_type, subject_id, rating)
    VALUES (v_a1, v_u1, 'copilot_answer', gen_random_uuid(), 'useful');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): INSERT directo en ai_feedback aceptado.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN
    UPDATE public.ai_feedback SET rating = 'useful' WHERE user_id = v_u1;
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): UPDATE directo en ai_feedback aceptado.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN
    DELETE FROM public.ai_feedback WHERE user_id = v_u1;
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (b): DELETE directo en ai_feedback aceptado.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;

  -- (d) el guardado del Copiloto CON account_id pasa; SIN account_id lo rechaza la RLS
  INSERT INTO public.ai_conversations (user_id, account_id, question, answer, model, tools_used, latency_ms,
                                       prompt_tokens, completion_tokens, outcome, thread_id)
  VALUES (v_u1, v_a1, 'guardado', 'ok', 'gpt-test', '[{"name":"resumen_periodo","ok":true,"rows":1,"ms":12}]'::jsonb,
          1234, 100, 50, 'answer', gen_random_uuid());
  BEGIN
    INSERT INTO public.ai_conversations (user_id, question, answer) VALUES (v_u1, 'sin cuenta', 'x');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (d): el INSERT sin account_id debía rechazarlo la RLS.';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  BEGIN
    INSERT INTO public.ai_conversations (user_id, account_id, question, answer, outcome) VALUES (v_u1, v_a1, 'q', 'a', 'bogus');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (d): outcome fuera del CHECK aceptado.';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL; END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM public.ai_conversations WHERE user_id = v_u1 AND question = 'guardado' AND account_id = v_a1
     AND model = 'gpt-test' AND outcome = 'answer' AND jsonb_array_length(tools_used) = 1;
  IF n <> 1 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (d): el turno guardado no quedó con sus columnas (n=%).', n; END IF;

  -- U2 (otra cuenta) NO ve la valoración de U1
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u2::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.ai_feedback WHERE subject_id = v_conv1;
  EXECUTE 'RESET ROLE';
  IF n <> 0 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): U2 vio la valoración de U1 (n=%).', n; END IF;

  -- quitar la valoración (U1)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u1::text, 'role', 'authenticated')::text, true);
  r := public.rpc_set_ai_feedback('copilot_answer', v_conv1, NULL);
  IF r->>'rating' IS NOT NULL THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): borrar debía devolver rating nulo: %.', r;
  END IF;
  SELECT count(*) INTO n FROM public.ai_feedback WHERE user_id = v_u1;
  IF n <> 0 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (c): p_rating NULL debía borrar (n=%).', n; END IF;
  -- borrar lo que no existe es idempotente
  PERFORM public.rpc_set_ai_feedback('copilot_answer', v_conv1, NULL);

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'PASS (b)(c)(d): P0401/22023/P0404, alta, cambio en una sola fila, borrado, RLS de lectura, escritura directa rechazada y guardado con account_id.';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE;
END $$;

-- ── (e) rpc_reserve_ai_usage('queries') y el OCR intacto ────────────────────
DO $$
DECLARE
  v_u  uuid; v_a uuid;
  r jsonb;
  v_used integer; v_count integer; v_start timestamptz;
  v_ocr_used integer; v_ocr_count integer;
  v_expected_reset timestamptz;
  i integer;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'ia-copilot-gate-1@test.local';
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_u ORDER BY created_at LIMIT 1;
  -- Plan inicial (30 consultas/mes): con el cupo por encima de la ráfaga (5) se prueba la ráfaga limpia.
  UPDATE public.accounts
     SET billing_plan = 'inicial', billing_status = 'active', trial_plan = NULL, trial_expires_at = NULL,
         plan_expires_at = NULL, billing_exempt = false
   WHERE id = v_a;
  UPDATE public.profiles
     SET ai_queries_used = 0, ai_queries_window_count = 0, ai_queries_window_started_at = NULL,
         ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL
   WHERE id = v_u;
  v_expected_reset := (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC';

  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM public.rpc_reserve_ai_usage('queries');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): queries aceptó una llamada sin auth.uid().';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL; END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u::text, 'role', 'authenticated')::text, true);

  -- contador desconocido sigue en 22023, sin efecto
  BEGIN
    PERFORM public.rpc_reserve_ai_usage('advice');
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): p_counter=advice aceptado.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;

  -- 1ª reserva concede
  r := public.rpc_reserve_ai_usage('queries');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 1 OR (r->>'limit')::int <> 30
     OR (r->>'reset_at')::timestamptz <> v_expected_reset THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): 1ª reserva debía conceder used=1 limit=30 y devolvió %.', r;
  END IF;
  SELECT ai_queries_used, ai_queries_window_count, ai_ocr_used, ai_ocr_window_count
    INTO v_used, v_count, v_ocr_used, v_ocr_count FROM public.profiles WHERE id = v_u;
  IF v_used <> 1 OR v_count <> 1 OR v_ocr_used <> 0 OR v_ocr_count <> 0 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): perfil tras la 1ª: queries %/% ocr %/% (esperaba 1/1 y 0/0).', v_used, v_count, v_ocr_used, v_ocr_count;
  END IF;
  FOR i IN 2..5 LOOP
    r := public.rpc_reserve_ai_usage('queries');
    IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> i THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): reserva % debía conceder used=% y devolvió %.', i, i, r;
    END IF;
  END LOOP;

  -- 6ª dentro de 60 s -> rate_limited, sin incremento
  r := public.rpc_reserve_ai_usage('queries');
  IF (r->>'allowed')::boolean OR r->>'reason' <> 'rate_limited'
     OR (r->>'retry_after_seconds')::int < 1 OR (r->>'retry_after_seconds')::int > 60 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): la 6ª reserva debía ser rate_limited (1..60 s) y devolvió %.', r;
  END IF;
  SELECT ai_queries_used, ai_queries_window_count INTO v_used, v_count FROM public.profiles WHERE id = v_u;
  IF v_used <> 5 OR v_count <> 5 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): una reserva denegada incrementó (used=%, count=%).', v_used, v_count;
  END IF;

  -- ventana vencida -> concede y reabre con count = 1
  UPDATE public.profiles SET ai_queries_window_started_at = now() - interval '61 seconds' WHERE id = v_u;
  r := public.rpc_reserve_ai_usage('queries');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 6 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): con la ventana vencida debía conceder used=6 y devolvió %.', r;
  END IF;
  SELECT ai_queries_window_count, ai_queries_window_started_at INTO v_count, v_start FROM public.profiles WHERE id = v_u;
  IF v_count <> 1 OR v_start <= now() - interval '5 seconds' THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): la ventana debía reabrirse con count=1 y started_at reciente (%/%).', v_count, v_start;
  END IF;

  -- cuota agotada -> quota_exceeded sin incremento; y gana sobre la ráfaga
  UPDATE public.profiles SET ai_queries_used = 30, ai_queries_window_count = 5, ai_queries_window_started_at = now() WHERE id = v_u;
  r := public.rpc_reserve_ai_usage('queries');
  IF (r->>'allowed')::boolean OR r->>'reason' <> 'quota_exceeded'
     OR (r->>'used')::int <> 30 OR (r->>'limit')::int <> 30 OR (r->>'reset_at')::timestamptz <> v_expected_reset THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): sin cupo y en ráfaga debía ganar quota_exceeded(30/30) y devolvió %.', r;
  END IF;
  SELECT ai_queries_used INTO v_used FROM public.profiles WHERE id = v_u;
  IF v_used <> 30 THEN RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): una reserva sin cupo incrementó (%).', v_used; END IF;

  -- plan gratis: límite 5, tercera triangulación del límite por plan
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_a;
  UPDATE public.profiles SET ai_queries_used = 5, ai_queries_window_count = 0, ai_queries_window_started_at = NULL WHERE id = v_u;
  r := public.rpc_reserve_ai_usage('queries');
  IF r->>'reason' <> 'quota_exceeded' OR (r->>'limit')::int <> 5 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): gratis con 5/5 debía ser quota_exceeded(5) y devolvió %.', r;
  END IF;
  UPDATE public.profiles SET ai_queries_used = 4 WHERE id = v_u;
  r := public.rpc_reserve_ai_usage('queries');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 5 OR (r->>'limit')::int <> 5 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): gratis con 4/5 debía conceder la 5ª y devolvió %.', r;
  END IF;

  -- el OCR conserva su comportamiento y no toca ai_queries_*
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_a;
  UPDATE public.profiles
     SET ai_queries_used = 7, ai_queries_window_count = 2, ai_queries_window_started_at = NULL,
         ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL
   WHERE id = v_u;
  r := public.rpc_reserve_ai_usage('ocr');
  IF NOT ((r->>'allowed')::boolean) OR (r->>'used')::int <> 1 OR (r->>'limit')::int <> 5
     OR (r->>'reset_at')::timestamptz <> v_expected_reset THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): el OCR debía conceder used=1 limit=5 como antes y devolvió %.', r;
  END IF;
  SELECT ai_queries_used, ai_queries_window_count, ai_queries_window_started_at, ai_ocr_used, ai_ocr_window_count
    INTO v_used, v_count, v_start, v_ocr_used, v_ocr_count FROM public.profiles WHERE id = v_u;
  IF v_used <> 7 OR v_count <> 2 OR v_start IS NOT NULL OR v_ocr_used <> 1 OR v_ocr_count <> 1 THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): el OCR tocó ai_queries_* o no incrementó el suyo (queries %/%/%, ocr %/%).', v_used, v_count, v_start, v_ocr_used, v_ocr_count;
  END IF;
  r := public.rpc_reserve_ai_usage('ocr'); r := public.rpc_reserve_ai_usage('ocr');
  r := public.rpc_reserve_ai_usage('ocr');
  IF (r->>'allowed')::boolean OR r->>'reason' <> 'rate_limited' THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (e): la ráfaga del OCR sigue siendo de 3 y la 4ª debía ser rate_limited; devolvió %.', r;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'PASS (e): queries concede/incrementa, ráfaga de 5, ventana vencida, quota_exceeded con precedencia, límite por plan, OCR intacto, advice 22023, sin sesión P0401.';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE;
END $$;

-- ── (f) Concurrencia real con dblink ────────────────────────────────────────
DO $$
DECLARE
  v_u uuid; v_a uuid;
  v_conn text; v_claims text; v_res_a text; v_res_b text; v_busy integer; v_used integer;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'ia-copilot-gate-1@test.local';
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_u ORDER BY created_at LIMIT 1;
  BEGIN
    CREATE EXTENSION IF NOT EXISTS dblink;
    IF inet_server_addr() IS NULL THEN
      RAISE EXCEPTION 'conexión por socket unix: sin TCP no hay credencial que dblink acepte';
    END IF;
    v_conn := format('host=%s port=%s dbname=%s user=%s password=postgres',
                     host(inet_server_addr()), inet_server_port(), current_database(), current_user);
    PERFORM dblink_connect('cop_a', v_conn);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE IA-COPILOT (f): dblink no disponible (%) — el borde de cupo único queda cubierto por la cota dura secuencial.', SQLERRM;
    RETURN;
  END;

  BEGIN
    PERFORM dblink_connect('cop_b', v_conn);
    v_claims := json_build_object('sub', v_u::text, 'role', 'authenticated')::text;
    -- gratis (5), 4 usadas, ventana libre: UN solo cupo.
    UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_a;
    PERFORM dblink_exec('cop_a', format('UPDATE public.profiles SET ai_queries_used = 4, ai_queries_window_count = 0, ai_queries_window_started_at = NULL WHERE id = %L', v_u));
    PERFORM * FROM dblink('cop_a', format('SELECT set_config(''request.jwt.claims'', %L, false)', v_claims)) AS t(x text);
    PERFORM * FROM dblink('cop_b', format('SELECT set_config(''request.jwt.claims'', %L, false)', v_claims)) AS t(x text);

    PERFORM dblink_exec('cop_a', 'BEGIN');
    SELECT r INTO v_res_a FROM dblink('cop_a', 'SELECT public.rpc_reserve_ai_usage(''queries'')::text') AS t(r text);
    PERFORM dblink_send_query('cop_b', 'SELECT public.rpc_reserve_ai_usage(''queries'')::text');
    PERFORM pg_sleep(0.7);
    v_busy := dblink_is_busy('cop_b');
    IF v_busy <> 1 THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (f): la reserva concurrente NO esperó el lock de fila (is_busy=%).', v_busy;
    END IF;
    PERFORM dblink_exec('cop_a', 'COMMIT');
    SELECT r INTO v_res_b FROM dblink_get_result('cop_b') AS t(r text);

    IF (v_res_a::jsonb->>'allowed')::boolean IS NOT TRUE OR (v_res_a::jsonb->>'used')::int <> 5 THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (f): A debía conceder el cupo único (used=5) y devolvió %.', v_res_a;
    END IF;
    IF (v_res_b::jsonb->>'allowed')::boolean IS NOT FALSE OR v_res_b::jsonb->>'reason' <> 'quota_exceeded' THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (f): B debía ser quota_exceeded tras el commit de A y devolvió %.', v_res_b;
    END IF;
    SELECT ai_queries_used INTO v_used FROM public.profiles WHERE id = v_u;
    IF v_used <> 5 THEN
      RAISE EXCEPTION 'GATE IA-COPILOT FAILED (f): con cupo 1 y dos reservas concurrentes ai_queries_used debía quedar en 5 y quedó %.', v_used;
    END IF;
    PERFORM dblink_disconnect('cop_a');
    PERFORM dblink_disconnect('cop_b');
    RAISE NOTICE 'PASS (f): con un solo cupo y dos reservas concurrentes se concede exactamente una.';
  EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_disconnect('cop_a'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('cop_b'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
  END;
END $$;

-- ═══ CLEANUP — resuelve por email, sobrevive corridas cortadas ══════════════
DO $$
DECLARE
  v_user uuid;
  v_account uuid;
  v_email text;
BEGIN
  FOREACH v_email IN ARRAY ARRAY['ia-copilot-gate-1@test.local', 'ia-copilot-gate-2@test.local'] LOOP
    SELECT id INTO v_user FROM auth.users WHERE email = v_email;
    CONTINUE WHEN v_user IS NULL;
    DELETE FROM public.ai_feedback WHERE user_id = v_user;
    DELETE FROM public.ai_conversations WHERE user_id = v_user;
    UPDATE public.profiles
       SET ai_queries_used = 0, ai_queries_window_count = 0, ai_queries_window_started_at = NULL,
           ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL, billing_plan = 'gratis'
     WHERE id = v_user;
    SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
    IF v_account IS NOT NULL THEN
      UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;
    END IF;
  END LOOP;
  DROP EXTENSION IF EXISTS dblink;
  IF EXISTS (SELECT 1 FROM public.ai_feedback f JOIN auth.users u ON u.id = f.user_id WHERE u.email LIKE 'ia-copilot-gate-%@test.local') THEN
    RAISE EXCEPTION 'GATE IA-COPILOT FAILED (cleanup): quedaron valoraciones de los fixtures.';
  END IF;
  RAISE NOTICE 'PASS (cleanup): fixtures revertidos.';
END $$;
