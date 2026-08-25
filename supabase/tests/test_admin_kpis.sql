-- =============================================================================
-- test_admin_kpis.sql — Gates de comportamiento: admin-kpi-refresh (grupos 1-7)
--
-- Verifica que los KPI de los paneles de administración se calculen en SQL
-- (no en el cliente) y con las unidades correctas:
--   1. Personas contra eventos: usuarios de comunidad = COUNT(DISTINCT user_id)
--      sobre las tablas transaccionales (community.posts/replies), no suma de
--      activos por período/evento (bug real: hoy la clave ni siquiera existe).
--   2. Activaciones y UMV como conteos distintos sobre el rango completo
--      (definición-candado: bajo la unicidad estructural de first_operation
--      no hay hoy un caso real de doble conteo, pero fija el contrato).
--   3. Cobertura de datos: summary.data_coverage no existe hoy → RED real.
--   4. Madurez de cohorte: rpc_admin_retention_30d no devuelve
--      observation_window_days/is_mature hoy (RETURNS TABLE distinto) → RED
--      real (la query contra la firma nueva falla).
--   5. Comunidad transaccional: get_admin_community_interactions y la rama
--      'comunidad' de rpc_admin_module_stats leen public.posts/replies, que
--      ya no existen (movidas a community.* por C-23) → 42P01 (RED real).
--   6. Pools activos: rpc_admin_business_kpis devuelve el literal 3 sin
--      importar el estado real de community.purchase_pools (RED real).
--   7. Superficie de autorización: una sola definición por proname, EXECUTE
--      para authenticated, sin EXECUTE para anon, rechazo de no-admin.
--
-- Patrón del proyecto (test_kpis.sql, test_analytics_events.sql): acumular
-- fallos en text[], un solo RAISE EXCEPTION al final para que
-- psql -v ON_ERROR_STOP=1 salga con código distinto de cero. Anchors
-- sintéticos vía handle_new_user (siembra account + branch + cashbox,
-- 20260812000001). Admin real vía UPDATE profiles.role tras el insert,
-- con el trigger anti-escalada deshabilitado sólo para el setup (patrón
-- sancionado por 20260816000001 D4).
--
-- Todo el SEED de datos (community.*, analytics_events) corre como postgres:
-- el entorno local de CI no siempre otorga a `authenticated` el GRANT base
-- sobre estas tablas (documentado en test_analytics_events.sql Gate 5); las
-- RPCs bajo prueba son SECURITY DEFINER, así que ejecutan sus queries
-- internas como el owner sin importar el rol del caller — sólo la
-- impersonación (SET LOCAL ROLE authenticated + request.jwt.claims) importa
-- para ejercitar el chequeo is_admin(auth.uid()) de cada RPC. PROHIBIDO
-- hacer esto mismo contra prod (ver instrucciones del change).
--
-- Cleanup hijo→padre al final; degrada con RAISE NOTICE si el contexto no lo
-- permite (prod real, sin cuenta resoluble para el anchor).
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures            text[] := '{}';

  -- Admin anchor: dispara handle_new_user, luego se promueve a role='admin'.
  v_admin_email         text := 'admin-kpi-refresh-gate-admin@test.local';
  v_admin_id            uuid := gen_random_uuid();
  v_admin_account       uuid;
  v_admin_branch        uuid;

  -- Usuarios de comunidad (D5: se miden sobre community.posts/replies).
  v_user_a_email        text := 'admin-kpi-refresh-gate-user-a@test.local';
  v_user_a_id           uuid := gen_random_uuid();
  v_user_b_email        text := 'admin-kpi-refresh-gate-user-b@test.local';
  v_user_b_id           uuid := gen_random_uuid();
  v_user_c_email        text := 'admin-kpi-refresh-gate-user-c@test.local';
  v_user_c_id           uuid := gen_random_uuid();

  v_post_a1             uuid := gen_random_uuid();
  v_post_b1             uuid := gen_random_uuid();

  -- Usuarios de activación/UMV (gate 2.3).
  v_act1_email          text := 'admin-kpi-refresh-gate-act1@test.local';
  v_act1_id             uuid := gen_random_uuid();
  v_act2_email          text := 'admin-kpi-refresh-gate-act2@test.local';
  v_act2_id             uuid := gen_random_uuid();

  -- Cohortes de retención (gate 2.5): madura (>37d) e inmadura (hoy).
  v_mature_email        text := 'admin-kpi-refresh-gate-mature@test.local';
  v_mature_id           uuid := gen_random_uuid();
  v_immature_email      text := 'admin-kpi-refresh-gate-immature@test.local';
  v_immature_id         uuid := gen_random_uuid();

  v_range_from          timestamptz := now() - interval '10 days';
  v_range_to             timestamptz := now() + interval '1 day';

  v_result              jsonb;
  v_summary             jsonb;
  v_community_users     int;
  v_interactions        bigint;
  v_module_stats        jsonb;
  v_pools_baseline      int;
  v_active_pools        int;
  v_pool_1              uuid := gen_random_uuid();
  v_pool_2              uuid := gen_random_uuid();
  v_stale_event_id      uuid := gen_random_uuid();
  v_fresh_event_id      uuid := gen_random_uuid();
  v_mature_op_id        uuid := gen_random_uuid();
  v_mature_cohort       timestamptz;
  v_immature_cohort     timestamptz;
  v_mature_row          jsonb;
  v_immature_row        jsonb;
  v_sig                 text;
  v_dup_count           int;
  v_role_result         jsonb;
  v_rejected            boolean;
  v_failures_before_28  int;
  v_secondary_accounts  uuid[];
  v_fns_5               CONSTANT text[] := ARRAY[
    'public.rpc_admin_kpi_overview(timestamptz, timestamptz, text)',
    -- grupo 9 (OQ-5, M2): firma nueva con p_horizon_days — la de 3 args ya
    -- no existe (DROP+CREATE por 42P13, ver migración M2).
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz, integer)',
    'public.rpc_admin_module_stats(text, timestamptz, timestamptz)',
    'public.rpc_admin_business_kpis(timestamptz, timestamptz)',
    'public.get_admin_community_interactions(timestamptz, timestamptz)'
  ];
  v_pronames             CONSTANT text[] := ARRAY[
    'rpc_admin_kpi_overview', 'rpc_admin_retention_30d', 'rpc_admin_module_stats',
    'rpc_admin_business_kpis', 'get_admin_community_interactions'
  ];
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- FASE 1 — SETUP (todo como postgres: anchors + seed de datos)
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_admin_id, 'authenticated', 'authenticated', v_admin_email, now(), now(),
          jsonb_build_object('name', 'Gate Admin KPI Refresh', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  -- prevent_profile_privilege_escalation (20260425000001) bloquea UPDATE de
  -- role fuera de un caller ya-admin: escape sancionado para setup de test
  -- (patrón 20260816000001 D4) — DISABLE/ENABLE en la misma transacción.
  ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation;
  UPDATE public.profiles SET role = 'admin' WHERE id = v_admin_id;
  ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation;

  SELECT account_id INTO v_admin_account
  FROM   public.account_members
  WHERE  user_id = v_admin_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_admin_account IS NULL THEN
    RAISE NOTICE 'GATE ADMIN-KPI-REFRESH: no se pudo resolver una account para el anchor admin (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_admin_branch FROM public.branches WHERE account_id = v_admin_account ORDER BY created_at LIMIT 1;

  -- Usuarios secundarios (community + activación + retención).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_user_a_id,    'authenticated', 'authenticated', v_user_a_email,    now(), now(), jsonb_build_object('name', 'Gate User A',    'phone', '', 'locality', '', 'province', '')),
    (v_user_b_id,    'authenticated', 'authenticated', v_user_b_email,    now(), now(), jsonb_build_object('name', 'Gate User B',    'phone', '', 'locality', '', 'province', '')),
    (v_user_c_id,    'authenticated', 'authenticated', v_user_c_email,    now(), now(), jsonb_build_object('name', 'Gate User C',    'phone', '', 'locality', '', 'province', '')),
    (v_act1_id,      'authenticated', 'authenticated', v_act1_email,      now(), now(), jsonb_build_object('name', 'Gate Act 1',     'phone', '', 'locality', '', 'province', '')),
    (v_act2_id,      'authenticated', 'authenticated', v_act2_email,      now(), now(), jsonb_build_object('name', 'Gate Act 2',     'phone', '', 'locality', '', 'province', '')),
    (v_mature_id,    'authenticated', 'authenticated', v_mature_email,    now(), now(), jsonb_build_object('name', 'Gate Mature',    'phone', '', 'locality', '', 'province', '')),
    (v_immature_id,  'authenticated', 'authenticated', v_immature_email,  now(), now(), jsonb_build_object('name', 'Gate Immature',  'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  -- Comunidad (gates 2.2 / 2.6): 2 posts + 3 replies = 5 filas, 3 usuarios
  -- distintos. Usuario A activo en 3 días distintos con post+reply.
  INSERT INTO community.posts (id, user_id, title, content, created_at) VALUES
    (v_post_a1, v_user_a_id, 'Post A1 gate', 'contenido', v_range_from + interval '1 day'),
    (v_post_b1, v_user_b_id, 'Post B1 gate', 'contenido', v_range_from + interval '4 days');

  -- Nota histórica: este seed convivía con on_post_reply_change deshabilitado
  -- porque update_post_replies_count() escribía en `public.posts` sin calificar
  -- (42P01 desde C-23). Ese bug quedó CERRADO por
  -- 20260918000001_community_counter_triggers_schema_fix.sql
  -- (change community-counter-triggers-schema-fix), así que el trigger corre
  -- normalmente. NO volver a deshabilitarlo: apagaría la detección de una
  -- recaída en la ruta que este gate ejercita.
  INSERT INTO community.replies (id, post_id, user_id, content, created_at) VALUES
    (gen_random_uuid(), v_post_a1, v_user_a_id, 'respuesta A gate', v_range_from + interval '2 days'),
    (gen_random_uuid(), v_post_a1, v_user_a_id, 'respuesta A gate 2', v_range_from + interval '3 days'),
    (gen_random_uuid(), v_post_b1, v_user_c_id, 'respuesta C gate', v_range_from + interval '5 days');

  -- Gate 2.3: activaciones=2 (act1,act2), UMV=1 (solo act2 tiene insight).
  INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at) VALUES
    (v_act1_id, v_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), v_range_from + interval '1 day'),
    (v_act2_id, v_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), v_range_from + interval '2 days'),
    (v_act2_id, v_admin_account, 'insight_generated', jsonb_build_object('type', 'general'), v_range_from + interval '2 days');

  -- Gate 2.4 parte A: telemetría vieja (>7 días).
  INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
  VALUES (v_stale_event_id, v_admin_id, v_admin_account, 'operation_created',
          jsonb_build_object('entity_id', v_stale_event_id::text, 'entity_type', 'expense', 'source', 'gate'),
          now() - interval '10 days');

  -- Gate 2.5: cohorte madura (activación hace 70 días, retenida al día 32) e
  -- inmadura (activación hoy). 70 días (no 45): desde el sign-off de OQ-5
  -- (M2, grupo 9) el horizonte DEFAULT de madurez pasó de 37 a 60 días — una
  -- cohorte de 45 días ya no califica como madura bajo la firma que este
  -- gate llama con 3 argumentos (default p_horizon_days=60).
  v_mature_cohort := date_trunc('week', now() - interval '70 days');
  INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
  VALUES (v_mature_id, v_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now() - interval '70 days');

  INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
  VALUES (v_mature_op_id, v_mature_id, v_admin_account, 'operation_created',
          jsonb_build_object('entity_id', v_mature_op_id::text, 'entity_type', 'expense', 'source', 'gate'),
          now() - interval '70 days' + interval '32 days');

  v_immature_cohort := date_trunc('week', now());
  INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
  VALUES (v_immature_id, v_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now());

  -- Baseline de pools (medido como postgres: bajo rol authenticated,
  -- community.purchase_pools no siempre tiene GRANT directo de SELECT en el
  -- entorno local — se lee vía la RPC SECURITY DEFINER en las aserciones).
  SELECT COUNT(*) INTO v_pools_baseline FROM community.purchase_pools;

  -- ═══════════════════════════════════════════════════════════════════════
  -- FASE 2 — llamadas RPC impersonando al admin (ejercitan is_admin())
  -- ═══════════════════════════════════════════════════════════════════════
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    SELECT public.rpc_admin_kpi_overview(v_range_from, v_range_to, 'day') INTO v_result;
    v_summary := v_result->'summary';

    -- Gate 2.2: usuarios de comunidad = personas distintas (A, B, C) = 3.
    v_community_users := (v_summary->>'community_active_users')::int;
    IF v_community_users IS DISTINCT FROM 3 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.2: community_active_users esperaba 3 (A,B,C distintos), obtuvo %s', v_community_users));
    ELSE
      RAISE NOTICE 'PASS 2.2: community_active_users cuenta personas distintas (3), no filas de actividad (5)';
    END IF;

    -- Gate 2.3: activaciones=3 (act1, act2, y el usuario "inmaduro" del
    -- fixture de retención — su first_operation es de hoy, cae dentro del
    -- mismo rango de consulta). UMV=1 (solo act2 tiene insight_generated).
    IF (v_summary->>'total_activations_in_range')::int IS DISTINCT FROM 3 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.3a: total_activations_in_range esperaba 3, obtuvo %s', v_summary->>'total_activations_in_range'));
    ELSE
      RAISE NOTICE 'PASS 2.3a: total_activations_in_range es un conteo distinto sobre el rango (3)';
    END IF;

    IF (v_summary->>'total_umv_in_range')::int IS DISTINCT FROM 1 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.3b: total_umv_in_range esperaba 1, obtuvo %s', v_summary->>'total_umv_in_range'));
    ELSE
      RAISE NOTICE 'PASS 2.3b: total_umv_in_range es un conteo distinto sobre el rango (1)';
    END IF;

    -- Gate 2.4a: cobertura declara telemetría vieja (>7 días de antigüedad).
    IF v_summary->'data_coverage' IS NULL THEN
      v_failures := array_append(v_failures, 'FAIL 2.4a: summary.data_coverage no existe');
    ELSIF (v_summary->'data_coverage'->>'operation_events_stale_days')::numeric <= 7 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.4a: operation_events_stale_days esperaba > 7, obtuvo %s',
               v_summary->'data_coverage'->>'operation_events_stale_days'));
    ELSE
      RAISE NOTICE 'PASS 2.4a: data_coverage declara telemetría estancada (% días)', v_summary->'data_coverage'->>'operation_events_stale_days';
    END IF;

    -- Gate 2.7a (baseline): active_pools = conteo real, no el literal 3.
    SELECT public.rpc_admin_business_kpis(v_range_from, v_range_to) INTO v_result;
    v_active_pools := (v_result->'community'->>'active_pools')::int;
    IF v_active_pools IS DISTINCT FROM v_pools_baseline THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.7a: active_pools esperaba el conteo real (%s), obtuvo %s', v_pools_baseline, v_active_pools));
    ELSE
      RAISE NOTICE 'PASS 2.7a: active_pools refleja el conteo real de community.purchase_pools (%), no el literal 3', v_pools_baseline;
    END IF;

    -- Gate 2.6a: rpc_admin_business_kpis.community.total_activity reutiliza
    -- get_admin_community_interactions (2 posts + 3 replies = 5).
    v_interactions := (v_result->'community'->>'total_activity')::bigint;
    IF v_interactions IS DISTINCT FROM 5 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.6a: rpc_admin_business_kpis.community.total_activity esperaba 5, obtuvo %s', v_interactions));
    ELSE
      RAISE NOTICE 'PASS 2.6a: rpc_admin_business_kpis cuenta comunidad desde las tablas transaccionales (5)';
    END IF;

    -- Gate 2.6b: get_admin_community_interactions directo, mismo total.
    SELECT public.get_admin_community_interactions(v_range_from, v_range_to) INTO v_interactions;
    IF v_interactions IS DISTINCT FROM 5 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.6b: get_admin_community_interactions esperaba 5, obtuvo %s', v_interactions));
    ELSE
      RAISE NOTICE 'PASS 2.6b: get_admin_community_interactions lee community.posts/replies (5)';
    END IF;

    -- Gate 2.6c: rpc_admin_module_stats('comunidad', ...) sin 42P01.
    SELECT public.rpc_admin_module_stats('comunidad', v_range_from, v_range_to) INTO v_module_stats;
    IF (v_module_stats->'summary'->>'users_count')::int IS DISTINCT FROM 3 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.6c: rpc_admin_module_stats(comunidad).users_count esperaba 3, obtuvo %s', v_module_stats->'summary'->>'users_count'));
    ELSE
      RAISE NOTICE 'PASS 2.6c: rpc_admin_module_stats(comunidad) responde sin error de relación inexistente (users_count=3)';
    END IF;

    -- Gate 2.5: madurez de cohorte.
    SELECT to_jsonb(t) INTO v_mature_row
    FROM public.rpc_admin_retention_30d('week', now() - interval '90 days', now() + interval '1 day') t
    WHERE t.cohort_start = v_mature_cohort;

    SELECT to_jsonb(t) INTO v_immature_row
    FROM public.rpc_admin_retention_30d('week', now() - interval '90 days', now() + interval '1 day') t
    WHERE t.cohort_start = v_immature_cohort;

    IF v_mature_row IS NULL OR (v_mature_row->>'observation_window_days') IS NULL THEN
      v_failures := array_append(v_failures, 'FAIL 2.5a: cohorte madura sin observation_window_days');
    ELSIF (v_mature_row->>'is_mature')::boolean IS DISTINCT FROM true THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.5a: cohorte activada hace 70 días esperaba is_mature=true, obtuvo %s', v_mature_row->>'is_mature'));
    ELSE
      RAISE NOTICE 'PASS 2.5a: cohorte madura (70 días) marca is_mature=true con observation_window_days=%', v_mature_row->>'observation_window_days';
    END IF;

    IF v_immature_row IS NULL OR (v_immature_row->>'observation_window_days') IS NULL THEN
      v_failures := array_append(v_failures, 'FAIL 2.5b: cohorte inmadura sin observation_window_days');
    ELSIF (v_immature_row->>'is_mature')::boolean IS DISTINCT FROM false THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.5b: cohorte activada hoy esperaba is_mature=false, obtuvo %s', v_immature_row->>'is_mature'));
    ELSE
      RAISE NOTICE 'PASS 2.5b: cohorte inmadura (hoy) marca is_mature=false con observation_window_days=%', v_immature_row->>'observation_window_days';
    END IF;

    -- ── Gate 2.7b: sembrar 2 pools (como postgres) y verificar +2 exacto ────
    EXECUTE 'RESET ROLE';
    INSERT INTO community.purchase_pools (id, title, target_amount, closes_at) VALUES
      (v_pool_1, 'Pool gate 1', 1000, now() + interval '10 days'),
      (v_pool_2, 'Pool gate 2', 2000, now() + interval '10 days');
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    SELECT public.rpc_admin_business_kpis(v_range_from, v_range_to) INTO v_result;
    v_active_pools := (v_result->'community'->>'active_pools')::int;
    IF v_active_pools IS DISTINCT FROM (v_pools_baseline + 2) THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.7b: active_pools esperaba %s tras sembrar 2 pools, obtuvo %s', v_pools_baseline + 2, v_active_pools));
    ELSE
      RAISE NOTICE 'PASS 2.7b: active_pools sube exactamente 2 al sembrar 2 pools reales';
    END IF;

    -- ── Gate 2.4b: telemetría fresca (evento de hoy → antigüedad ~0) ────────
    EXECUTE 'RESET ROLE';
    INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
    VALUES (v_fresh_event_id, v_admin_id, v_admin_account, 'operation_created',
            jsonb_build_object('entity_id', v_fresh_event_id::text, 'entity_type', 'expense', 'source', 'gate'),
            now());
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    SELECT public.rpc_admin_kpi_overview(v_range_from, v_range_to, 'day') INTO v_result;
    v_summary := v_result->'summary';

    IF (v_summary->'data_coverage'->>'operation_events_stale_days')::numeric > 1 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.4b: operation_events_stale_days esperaba ~0 tras evento de hoy, obtuvo %s',
               v_summary->'data_coverage'->>'operation_events_stale_days'));
    ELSE
      RAISE NOTICE 'PASS 2.4b: data_coverage refleja telemetría al día (% días)', v_summary->'data_coverage'->>'operation_events_stale_days';
    END IF;

    -- ── Gate 2.8: rechazo de usuario no-admin ────────────────────────────────
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    v_rejected := false;
    BEGIN
      SELECT public.rpc_admin_kpi_overview(v_range_from, v_range_to, 'day') INTO v_role_result;
    EXCEPTION
      WHEN OTHERS THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
      v_failures := array_append(v_failures, 'FAIL 2.8: un usuario no-admin obtuvo datos de rpc_admin_kpi_overview');
    ELSE
      RAISE NOTICE 'PASS 2.8: un usuario no-admin es rechazado por rpc_admin_kpi_overview';
    END IF;

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      RAISE;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- FASE 3 — superficie de autorización: 1 definición + ACLs (como postgres)
  -- ═══════════════════════════════════════════════════════════════════════
  v_failures_before_28 := COALESCE(array_length(v_failures, 1), 0);

  FOREACH v_sig IN ARRAY v_fns_5 LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      v_failures := array_append(v_failures, format('FAIL 2.8: %s no existe', v_sig));
      CONTINUE;
    END IF;

    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      v_failures := array_append(v_failures, format('FAIL 2.8: %s sin EXECUTE para authenticated', v_sig));
    END IF;

    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      v_failures := array_append(v_failures, format('FAIL 2.8: %s con EXECUTE para anon (debe estar revocado)', v_sig));
    END IF;
  END LOOP;

  FOREACH v_sig IN ARRAY v_pronames LOOP
    SELECT COUNT(*) INTO v_dup_count
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = v_sig;

    IF v_dup_count <> 1 THEN
      v_failures := array_append(v_failures,
        format('FAIL 2.8: %s tiene %s definiciones (se espera exactamente 1, anti-42725)', v_sig, v_dup_count));
    END IF;
  END LOOP;

  IF COALESCE(array_length(v_failures, 1), 0) = v_failures_before_28 THEN
    RAISE NOTICE 'PASS 2.8: superficie de autorización intacta en las 5 RPCs (1 definición, EXECUTE authenticated, sin EXECUTE anon)';
  END IF;

  -- ── Resultado ──────────────────────────────────────────────────────────────
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ADMIN-KPI-REFRESH FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE ADMIN-KPI-REFRESH PASSED: personas vs eventos, activaciones/UMV distintos, cobertura de datos, madurez de cohorte, comunidad transaccional, pools reales y superficie de autorización — verificados.';

  -- ── Limpieza hijo→padre (accounts=0 al final) ────────────────────────────
  -- Capturar las accounts de los usuarios secundarios ANTES de borrar
  -- account_members: si se consulta después de borrarlo, la subquery ya no
  -- encuentra nada y accounts.owner_user_id queda huérfano, rompiendo el
  -- DELETE FROM auth.users final por FK (accounts_owner_user_id_fkey).
  SELECT array_agg(DISTINCT account_id) INTO v_secondary_accounts
  FROM public.account_members
  WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id);

  DELETE FROM community.replies       WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id);
  DELETE FROM community.posts         WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id);
  DELETE FROM community.purchase_pools WHERE id IN (v_pool_1, v_pool_2);
  DELETE FROM public.analytics_events WHERE user_id IN (
    v_admin_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  DELETE FROM public.analytics_events WHERE id IN (v_stale_event_id, v_fresh_event_id, v_mature_op_id);
  DELETE FROM public.cashboxes WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts)
  );
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches  WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id = v_admin_account OR id = ANY(v_secondary_accounts);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  DELETE FROM public.email_logs WHERE user_id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  DELETE FROM public.operation_idempotency WHERE user_id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  DELETE FROM auth.users WHERE id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    -- Best-effort cleanup incluso si algo falló a mitad de camino.
    BEGIN
      IF v_secondary_accounts IS NULL THEN
        SELECT array_agg(DISTINCT account_id) INTO v_secondary_accounts
        FROM public.account_members
        WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id);
      END IF;

      DELETE FROM community.replies       WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id);
      DELETE FROM community.posts         WHERE user_id IN (v_user_a_id, v_user_b_id, v_user_c_id);
      DELETE FROM community.purchase_pools WHERE id IN (v_pool_1, v_pool_2);
      DELETE FROM public.analytics_events WHERE user_id IN (
        v_admin_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      DELETE FROM public.analytics_events WHERE id IN (v_stale_event_id, v_fresh_event_id, v_mature_op_id);
      DELETE FROM public.cashboxes WHERE branch_id IN (
        SELECT id FROM public.branches WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts)
      );
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches  WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members WHERE user_id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.accounts WHERE id = v_admin_account OR id = ANY(v_secondary_accounts);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles WHERE id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      DELETE FROM public.email_logs WHERE user_id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      DELETE FROM public.operation_idempotency WHERE user_id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      DELETE FROM auth.users WHERE id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- =============================================================================
-- GATE ADMIN-KPI-REFRESH — M2 (grupos 8 y 9): MRR real (OQ-4) y retención
-- censurada [30,60) (OQ-5) — sign-off PO 2026-08-12.
--
-- Verifica (design.md D6/D7, tasks.md 8.2/9.2):
--   8. MRR: cuenta paga (billing_plan, tarifa de lista) aporta price_monthly
--      de su plan; cuenta con suscripción MP autorizada aporta el importe de
--      la suscripción (no la tarifa de lista — D6 término B preferente sobre
--      A); cuenta en trial vigente aporta 0 al MRR y el precio de su plan de
--      trial a trial_pipeline_mrr_ars; cuenta exenta aporta 0 a ambos aunque
--      tenga un trial vigente (precedencia de get_effective_plan: exención
--      antes que trial); las claves legacy pro_users/mrr/conversion_rate
--      (profiles.plan) mueren. Reutiliza get_effective_plan(id) — no se
--      re-deriva la lógica de plan efectivo.
--   9. Retención [30,H): usuario que opera dentro de [30,60) desde su
--      activación cuenta como retenido; usuario que sólo opera antes del día
--      30 no cuenta; cohorte más joven que el horizonte (50d) se marca
--      is_mature=false — con la ventana FIJA anterior [30,37) esa misma
--      cohorte de 50 días ya era madura, así que ese assert es la prueba de
--      que la definición realmente cambió, no sólo se parametrizó; el
--      llamador con 3 argumentos (sin p_horizon_days) sigue funcionando con
--      el default 60.
--
-- Patrón baseline+delta (igual que active_pools en el gate anterior): ni la
-- población de cuentas ni la tabla de cohortes de rpc_admin_retention_30d
-- filtran por lo sembrado en este bloque — así que en vez de asserts
-- absolutos se mide el delta contra una captura previa a la siembra, inmune
-- a contaminación de otros gates que compartan rango de fechas o corran
-- antes en el mismo pipeline de CI.
-- =============================================================================

DO $$
DECLARE
  v2_failures              text[] := '{}';

  v2_admin_email           text := 'admin-kpi-refresh-m2-admin@test.local';
  v2_admin_id              uuid := gen_random_uuid();
  v2_admin_account         uuid;

  -- MRR (grupo 8): 5 cuentas, una por población + una vía de suscripción viva.
  v2_owner_paying_email    text := 'admin-kpi-refresh-m2-paying@test.local';
  v2_owner_paying_id       uuid := gen_random_uuid();
  v2_owner_sub_email       text := 'admin-kpi-refresh-m2-sub@test.local';
  v2_owner_sub_id          uuid := gen_random_uuid();
  v2_owner_trial_email     text := 'admin-kpi-refresh-m2-trial@test.local';
  v2_owner_trial_id        uuid := gen_random_uuid();
  v2_owner_exempt_email    text := 'admin-kpi-refresh-m2-exempt@test.local';
  v2_owner_exempt_id       uuid := gen_random_uuid();
  v2_owner_free_email      text := 'admin-kpi-refresh-m2-free@test.local';
  v2_owner_free_id         uuid := gen_random_uuid();

  v2_account_paying        uuid;
  v2_account_sub           uuid;
  v2_account_trial         uuid;
  v2_account_exempt        uuid;
  v2_account_free          uuid;

  v2_before                jsonb;
  v2_after                 jsonb;
  v2_freemium_before       jsonb;
  v2_freemium_after        jsonb;

  -- Retención (grupo 9): usuarios en 3 cohortes distintas y bien separadas
  -- (>=40 días entre offsets) para no compartir bucket de semana.
  v2_ret_r_email           text := 'admin-kpi-refresh-m2-ret-r@test.local';
  v2_ret_r_id              uuid := gen_random_uuid();
  v2_ret_nr_email          text := 'admin-kpi-refresh-m2-ret-nr@test.local';
  v2_ret_nr_id             uuid := gen_random_uuid();
  v2_ret_imm_email         text := 'admin-kpi-refresh-m2-ret-imm@test.local';
  v2_ret_imm_id            uuid := gen_random_uuid();
  v2_ret_op_r              uuid := gen_random_uuid();
  v2_ret_op_nr             uuid := gen_random_uuid();

  v2_ret_cohort_r          timestamptz;
  v2_ret_cohort_nr         timestamptz;
  v2_ret_cohort_imm        timestamptz;
  v2_ret_from              timestamptz := now() - interval '150 days';
  v2_ret_to                timestamptz := now() + interval '1 day';

  v2_baseline_size_r       int;
  v2_baseline_retained_r   int;
  v2_baseline_size_nr      int;
  v2_baseline_retained_nr  int;
  v2_row_r                 jsonb;
  v2_row_nr                jsonb;
  v2_row_imm               jsonb;
  v2_delta_size_r          int;
  v2_delta_retained_r      int;
  v2_delta_size_nr         int;
  v2_delta_retained_nr     int;

  v2_dup_count             int;
  -- Cuentas auto-aprovisionadas por handle_new_user para los 3 usuarios de
  -- retención (nunca customizadas, pero SÍ existen y deben limpiarse — el
  -- mismo aprovisionamiento eager que contaminaba el freemium "after", ver
  -- nota más arriba).
  v2_ret_accounts          uuid[];
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- SETUP — admin propio del bloque M2
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v2_admin_id, 'authenticated', 'authenticated', v2_admin_email, now(), now(),
          jsonb_build_object('name', 'Gate Admin KPI Refresh M2', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation;
  UPDATE public.profiles SET role = 'admin' WHERE id = v2_admin_id;
  ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation;

  SELECT account_id INTO v2_admin_account
  FROM   public.account_members
  WHERE  user_id = v2_admin_id
  ORDER  BY created_at
  LIMIT  1;

  IF v2_admin_account IS NULL THEN
    RAISE NOTICE 'GATE ADMIN-KPI-REFRESH-M2: no se pudo resolver una account para el anchor admin — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Baseline (ANTES de sembrar nada) — inmune a contaminación ───────────
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v2_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    v2_ret_cohort_r   := date_trunc('week', now() - interval '70 days');
    v2_ret_cohort_nr  := date_trunc('week', now() - interval '110 days');
    v2_ret_cohort_imm := date_trunc('week', now() - interval '50 days');

    SELECT (t.cohort_size)::int, (t.retained_30d)::int INTO v2_baseline_size_r, v2_baseline_retained_r
    FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to, 60) t
    WHERE t.cohort_start = v2_ret_cohort_r;

    SELECT (t.cohort_size)::int, (t.retained_30d)::int INTO v2_baseline_size_nr, v2_baseline_retained_nr
    FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to, 60) t
    WHERE t.cohort_start = v2_ret_cohort_nr;

    v2_baseline_size_r      := COALESCE(v2_baseline_size_r, 0);
    v2_baseline_retained_r  := COALESCE(v2_baseline_retained_r, 0);
    v2_baseline_size_nr     := COALESCE(v2_baseline_size_nr, 0);
    v2_baseline_retained_nr := COALESCE(v2_baseline_retained_nr, 0);

    SELECT public.rpc_admin_business_kpis(now() - interval '30 days', now()) INTO v2_before;
    v2_freemium_before := v2_before->'freemium';

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      RAISE;
  END;

  -- ── Siembra de las 5 cuentas de MRR (como postgres) ─────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v2_owner_paying_id, 'authenticated', 'authenticated', v2_owner_paying_email, now(), now(), jsonb_build_object('name', 'Gate Paying',  'phone', '', 'locality', '', 'province', '')),
    (v2_owner_sub_id,    'authenticated', 'authenticated', v2_owner_sub_email,    now(), now(), jsonb_build_object('name', 'Gate Sub',     'phone', '', 'locality', '', 'province', '')),
    (v2_owner_trial_id,  'authenticated', 'authenticated', v2_owner_trial_email,  now(), now(), jsonb_build_object('name', 'Gate Trial',   'phone', '', 'locality', '', 'province', '')),
    (v2_owner_exempt_id, 'authenticated', 'authenticated', v2_owner_exempt_email, now(), now(), jsonb_build_object('name', 'Gate Exempt',  'phone', '', 'locality', '', 'province', '')),
    (v2_owner_free_id,   'authenticated', 'authenticated', v2_owner_free_email,   now(), now(), jsonb_build_object('name', 'Gate Free',    'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v2_account_paying FROM public.accounts WHERE owner_user_id = v2_owner_paying_id;
  SELECT id INTO v2_account_sub    FROM public.accounts WHERE owner_user_id = v2_owner_sub_id;
  SELECT id INTO v2_account_trial  FROM public.accounts WHERE owner_user_id = v2_owner_trial_id;
  SELECT id INTO v2_account_exempt FROM public.accounts WHERE owner_user_id = v2_owner_exempt_id;
  SELECT id INTO v2_account_free   FROM public.accounts WHERE owner_user_id = v2_owner_free_id;

  IF v2_account_paying IS NULL OR v2_account_sub IS NULL OR v2_account_trial IS NULL
     OR v2_account_exempt IS NULL OR v2_account_free IS NULL THEN
    RAISE NOTICE 'GATE ADMIN-KPI-REFRESH-M2: handle_new_user no aprovisionó alguna de las 5 cuentas de MRR — degradando sin abortar.';
    RETURN;
  END IF;

  -- Paying (lista de precios): billing_plan pago vigente, trial vencido para
  -- que no gane precedencia sobre billing_plan (get_effective_plan D1/D2).
  UPDATE public.accounts SET
    billing_plan     = 'avanzado',
    plan_expires_at  = now() + interval '30 days',
    trial_plan       = 'pro',
    trial_expires_at = now() - interval '1 day'
  WHERE id = v2_account_paying;

  -- Paying (suscripción MP viva): el importe real de la suscripción pisa la
  -- tarifa de lista del plan (D6, término B preferente sobre A).
  UPDATE public.accounts SET
    billing_plan     = 'pro',
    plan_expires_at  = now() + interval '30 days',
    trial_plan       = 'pro',
    trial_expires_at = now() - interval '1 day'
  WHERE id = v2_account_sub;

  INSERT INTO public.subscriptions (account_id, preapproval_id, preapproval_plan_id, plan, status, amount, currency)
  VALUES (v2_account_sub, 'gate-mrr-preapproval-test', 'gate-mrr-plan-test', 'pro', 'authorized', 55000.00, 'ARS');

  -- Trial: se deja el trial PRO de 30 días que asigna set_new_user_trial()
  -- por defecto en todo signup nuevo — es exactamente el caso "trial
  -- vigente" que el MRR debe excluir y el pipeline debe valorizar.

  -- Exento: precedencia máxima sobre trial/billing_plan en get_effective_plan.
  UPDATE public.accounts SET
    billing_exempt        = true,
    billing_exempt_reason = 'gate admin-kpi-refresh-m2'
  WHERE id = v2_account_exempt;

  -- Free: trial vencido y sin billing_plan pago → cae a 'gratis'.
  UPDATE public.accounts SET
    trial_plan       = 'pro',
    trial_expires_at = now() - interval '1 day'
  WHERE id = v2_account_free;

  -- NOTA (encontrada en RED de este mismo gate — no era el RED esperado):
  -- la siembra de retención NO puede pasar acá, antes de capturar el
  -- "after" del MRR. Cada auth.users nuevo dispara handle_new_user, que
  -- aprovisiona una cuenta con el trial PRO de 30 días por defecto
  -- (set_new_user_trial) — si las 3 cuentas de retención existieran ya, el
  -- freemium "after" las contaría como 'trial' además de v2_owner_trial
  -- (trial_accounts delta daba 4, no 1; trial_pipeline_mrr_ars daba
  -- 4×69900, no 69900). Se siembra DESPUÉS de leer v2_after (bloque
  -- siguiente), fuera del alcance de la foto de MRR.

  -- ═══════════════════════════════════════════════════════════════════════
  -- EJERCICIO — RPCs impersonando al admin del bloque M2
  -- ═══════════════════════════════════════════════════════════════════════
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v2_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- ── Gate 8.2: MRR / poblaciones ────────────────────────────────────────
    SELECT public.rpc_admin_business_kpis(now() - interval '30 days', now()) INTO v2_after;
    v2_freemium_after := v2_after->'freemium';

    IF (v2_freemium_after->>'paying_accounts')::int - (v2_freemium_before->>'paying_accounts')::int IS DISTINCT FROM 2 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2a: paying_accounts delta esperaba 2, obtuvo %s',
        (v2_freemium_after->>'paying_accounts')::int - (v2_freemium_before->>'paying_accounts')::int));
    ELSE
      RAISE NOTICE 'PASS 8.2a: paying_accounts sube exactamente 2 (billing_plan + suscripción MP)';
    END IF;

    IF (v2_freemium_after->>'trial_accounts')::int - (v2_freemium_before->>'trial_accounts')::int IS DISTINCT FROM 1 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2b: trial_accounts delta esperaba 1, obtuvo %s',
        (v2_freemium_after->>'trial_accounts')::int - (v2_freemium_before->>'trial_accounts')::int));
    ELSE
      RAISE NOTICE 'PASS 8.2b: trial_accounts sube exactamente 1';
    END IF;

    IF (v2_freemium_after->>'exempt_accounts')::int - (v2_freemium_before->>'exempt_accounts')::int IS DISTINCT FROM 1 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2c: exempt_accounts delta esperaba 1, obtuvo %s',
        (v2_freemium_after->>'exempt_accounts')::int - (v2_freemium_before->>'exempt_accounts')::int));
    ELSE
      RAISE NOTICE 'PASS 8.2c: exempt_accounts sube exactamente 1';
    END IF;

    IF (v2_freemium_after->>'free_accounts')::int - (v2_freemium_before->>'free_accounts')::int IS DISTINCT FROM 1 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2d: free_accounts delta esperaba 1, obtuvo %s',
        (v2_freemium_after->>'free_accounts')::int - (v2_freemium_before->>'free_accounts')::int));
    ELSE
      RAISE NOTICE 'PASS 8.2d: free_accounts sube exactamente 1';
    END IF;

    IF (v2_freemium_after->>'mrr_ars')::numeric - (v2_freemium_before->>'mrr_ars')::numeric IS DISTINCT FROM 89900.00 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2e: mrr_ars delta esperaba 89900.00 (34900 lista + 55000 suscripción), obtuvo %s',
        (v2_freemium_after->>'mrr_ars')::numeric - (v2_freemium_before->>'mrr_ars')::numeric));
    ELSE
      RAISE NOTICE 'PASS 8.2e: mrr_ars suma tarifa de lista + importe real de suscripción (89900.00), no cuenta trials ni exentas';
    END IF;

    IF (v2_freemium_after->>'trial_pipeline_mrr_ars')::numeric - (v2_freemium_before->>'trial_pipeline_mrr_ars')::numeric IS DISTINCT FROM 69900.00 THEN
      v2_failures := array_append(v2_failures, format('FAIL 8.2f: trial_pipeline_mrr_ars delta esperaba 69900.00 (precio pro), obtuvo %s',
        (v2_freemium_after->>'trial_pipeline_mrr_ars')::numeric - (v2_freemium_before->>'trial_pipeline_mrr_ars')::numeric));
    ELSE
      RAISE NOTICE 'PASS 8.2f: trial_pipeline_mrr_ars valoriza el trial vigente a precio de plan (69900.00)';
    END IF;

    IF v2_freemium_after ? 'pro_users' OR v2_freemium_after ? 'mrr' OR v2_freemium_after ? 'conversion_rate' THEN
      v2_failures := array_append(v2_failures, 'FAIL 8.2g: freemium todavía expone claves legacy (pro_users/mrr/conversion_rate) — profiles.plan debe estar muerto');
    ELSE
      RAISE NOTICE 'PASS 8.2g: freemium ya no expone pro_users/mrr/conversion_rate (columna legacy profiles.plan muerta)';
    END IF;

    -- ── Siembra de retención (3 cohortes) — DESPUÉS del "after" de MRR, ver
    --    nota más arriba. RESET ROLE porque el seed corre como postgres (los
    --    triggers de aprovisionamiento no dependen de RLS, pero el patrón
    --    del proyecto siembra siempre sin impersonar) y se re-impersona al
    --    admin apenas termina (mismo patrón que 2.7b/2.4b del gate anterior).
    EXECUTE 'RESET ROLE';
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES
      (v2_ret_r_id,   'authenticated', 'authenticated', v2_ret_r_email,   now(), now(), jsonb_build_object('name', 'Gate Ret R',   'phone', '', 'locality', '', 'province', '')),
      (v2_ret_nr_id,  'authenticated', 'authenticated', v2_ret_nr_email,  now(), now(), jsonb_build_object('name', 'Gate Ret NR',  'phone', '', 'locality', '', 'province', '')),
      (v2_ret_imm_id, 'authenticated', 'authenticated', v2_ret_imm_email, now(), now(), jsonb_build_object('name', 'Gate Ret IMM', 'phone', '', 'locality', '', 'province', ''))
    ON CONFLICT (id) DO NOTHING;

    -- R: activada hace 70 días (madura, 70>=60) — opera al día 45 (dentro de
    -- [30,60), FUERA de la vieja [30,37)) → retenida bajo la definición nueva.
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    VALUES (v2_ret_r_id, v2_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now() - interval '70 days');
    INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
    VALUES (v2_ret_op_r, v2_ret_r_id, v2_admin_account, 'operation_created',
            jsonb_build_object('entity_id', v2_ret_op_r::text, 'entity_type', 'expense', 'source', 'gate'),
            now() - interval '70 days' + interval '45 days');

    -- NR: activada hace 110 días (madura) — opera al día 10 (antes del día 30)
    -- → NO retenida bajo ninguna definición.
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    VALUES (v2_ret_nr_id, v2_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now() - interval '110 days');
    INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
    VALUES (v2_ret_op_nr, v2_ret_nr_id, v2_admin_account, 'operation_created',
            jsonb_build_object('entity_id', v2_ret_op_nr::text, 'entity_type', 'expense', 'source', 'gate'),
            now() - interval '110 days' + interval '10 days');

    -- IMM: activada hace 50 días — madura bajo la vieja ventana fija [30,37)
    -- (50>37) pero INMADURA bajo el horizonte censurado nuevo (50<60). Prueba
    -- que la definición cambió, no sólo se parametrizó.
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    VALUES (v2_ret_imm_id, v2_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now() - interval '50 days');

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v2_admin_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- ── Gate 9.2: retención censurada [30,60) ───────────────────────────────
    SELECT to_jsonb(t) INTO v2_row_r
    FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to, 60) t
    WHERE t.cohort_start = v2_ret_cohort_r;

    SELECT to_jsonb(t) INTO v2_row_nr
    FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to, 60) t
    WHERE t.cohort_start = v2_ret_cohort_nr;

    SELECT to_jsonb(t) INTO v2_row_imm
    FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to, 60) t
    WHERE t.cohort_start = v2_ret_cohort_imm;

    v2_delta_size_r      := COALESCE((v2_row_r->>'cohort_size')::int, 0) - v2_baseline_size_r;
    v2_delta_retained_r  := COALESCE((v2_row_r->>'retained_30d')::int, 0) - v2_baseline_retained_r;
    v2_delta_size_nr     := COALESCE((v2_row_nr->>'cohort_size')::int, 0) - v2_baseline_size_nr;
    v2_delta_retained_nr := COALESCE((v2_row_nr->>'retained_30d')::int, 0) - v2_baseline_retained_nr;

    IF v2_delta_size_r IS DISTINCT FROM 1 OR v2_delta_retained_r IS DISTINCT FROM 1 THEN
      v2_failures := array_append(v2_failures, format(
        'FAIL 9.2a: cohorte R (opera al día 45, dentro de [30,60)) esperaba delta cohort_size=1/retained=1, obtuvo size=%s/retained=%s',
        v2_delta_size_r, v2_delta_retained_r));
    ELSE
      RAISE NOTICE 'PASS 9.2a: usuario que opera al día 45 (dentro de [30,60), fuera de la vieja [30,37)) cuenta como retenido';
    END IF;

    IF v2_delta_size_nr IS DISTINCT FROM 1 OR v2_delta_retained_nr IS DISTINCT FROM 0 THEN
      v2_failures := array_append(v2_failures, format(
        'FAIL 9.2b: cohorte NR (opera al día 10, antes del día 30) esperaba delta cohort_size=1/retained=0, obtuvo size=%s/retained=%s',
        v2_delta_size_nr, v2_delta_retained_nr));
    ELSE
      RAISE NOTICE 'PASS 9.2b: usuario que sólo opera antes del día 30 NO cuenta como retenido';
    END IF;

    IF v2_row_r IS NULL OR (v2_row_r->>'observation_window_days')::int IS DISTINCT FROM 60 THEN
      v2_failures := array_append(v2_failures, format('FAIL 9.2c: cohorte R esperaba observation_window_days=60, obtuvo %s', v2_row_r->>'observation_window_days'));
    ELSIF (v2_row_r->>'is_mature')::boolean IS DISTINCT FROM true THEN
      v2_failures := array_append(v2_failures, 'FAIL 9.2c: cohorte R (70 días) esperaba is_mature=true');
    ELSE
      RAISE NOTICE 'PASS 9.2c: cohorte R (70 días) is_mature=true con observation_window_days=60';
    END IF;

    IF v2_row_imm IS NULL OR (v2_row_imm->>'observation_window_days')::int IS DISTINCT FROM 60 THEN
      v2_failures := array_append(v2_failures, format('FAIL 9.2d: cohorte IMM esperaba observation_window_days=60, obtuvo %s', v2_row_imm->>'observation_window_days'));
    ELSIF (v2_row_imm->>'is_mature')::boolean IS DISTINCT FROM false THEN
      v2_failures := array_append(v2_failures, format(
        'FAIL 9.2d: cohorte IMM (50 días — madura bajo la vieja [30,37), INMADURA bajo el horizonte nuevo de 60) esperaba is_mature=false, obtuvo %s',
        v2_row_imm->>'is_mature'));
    ELSE
      RAISE NOTICE 'PASS 9.2d: cohorte de 50 días — madura con la vieja ventana fija [30,37), INMADURA con el horizonte nuevo [30,60) — la definición cambió de verdad, no sólo se parametrizó';
    END IF;

    -- ── Gate 9.2e: el llamador sin p_horizon_days sigue funcionando (default
    --    60 — el frontend actual no manda el 4º argumento) ─────────────────
    PERFORM 1 FROM public.rpc_admin_retention_30d('week', v2_ret_from, v2_ret_to) LIMIT 1;
    RAISE NOTICE 'PASS 9.2e: rpc_admin_retention_30d sigue aceptando 3 argumentos (p_horizon_days default 60)';

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      RAISE;
  END;

  -- ── Gate de superficie: una sola definición de retención (4 args) ───────
  SELECT COUNT(*) INTO v2_dup_count
  FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public' AND p.proname = 'rpc_admin_retention_30d';

  IF v2_dup_count <> 1 THEN
    v2_failures := array_append(v2_failures, format('FAIL 9.2f: rpc_admin_retention_30d tiene %s definiciones (se espera 1, anti-42725)', v2_dup_count));
  ELSE
    RAISE NOTICE 'PASS 9.2f: rpc_admin_retention_30d tiene exactamente 1 definición tras el DROP+CREATE de 4 argumentos';
  END IF;

  -- ── Resultado ──────────────────────────────────────────────────────────
  IF array_length(v2_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ADMIN-KPI-REFRESH-M2 FAILED:\n  %', array_to_string(v2_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE ADMIN-KPI-REFRESH-M2 PASSED: MRR real por plan efectivo/suscripción y retención censurada [30,60) — verificados.';

  -- ── Limpieza hijo→padre ──────────────────────────────────────────────────
  SELECT array_agg(id) INTO v2_ret_accounts
  FROM public.accounts
  WHERE owner_user_id IN (v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id);
  v2_ret_accounts := COALESCE(v2_ret_accounts, ARRAY[]::uuid[]);

  DELETE FROM public.subscriptions WHERE account_id = v2_account_sub;
  DELETE FROM public.analytics_events WHERE user_id IN (v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id);
  DELETE FROM public.cashboxes WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id = v2_admin_account
       OR account_id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
       OR account_id = ANY(v2_ret_accounts)
  );
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches WHERE account_id = v2_admin_account
     OR account_id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
     OR account_id = ANY(v2_ret_accounts);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (
    v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
    v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
  );
  DELETE FROM public.accounts WHERE id = v2_admin_account
     OR id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
     OR id = ANY(v2_ret_accounts);
  DELETE FROM public.profiles WHERE id IN (
    v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
    v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
  );
  DELETE FROM public.email_logs WHERE user_id IN (
    v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
    v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
  );
  DELETE FROM public.operation_idempotency WHERE user_id IN (
    v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
    v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
  );
  DELETE FROM auth.users WHERE id IN (
    v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
    v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
  );

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
      IF v2_ret_accounts IS NULL THEN
        SELECT array_agg(id) INTO v2_ret_accounts
        FROM public.accounts
        WHERE owner_user_id IN (v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id);
      END IF;
      v2_ret_accounts := COALESCE(v2_ret_accounts, ARRAY[]::uuid[]);

      DELETE FROM public.subscriptions WHERE account_id = v2_account_sub;
      DELETE FROM public.analytics_events WHERE user_id IN (v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id);
      DELETE FROM public.cashboxes WHERE branch_id IN (
        SELECT id FROM public.branches WHERE account_id = v2_admin_account
           OR account_id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
           OR account_id = ANY(v2_ret_accounts)
      );
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches WHERE account_id = v2_admin_account
         OR account_id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
         OR account_id = ANY(v2_ret_accounts);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members WHERE user_id IN (
        v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
        v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
      );
      DELETE FROM public.accounts WHERE id = v2_admin_account
         OR id = ANY(ARRAY[v2_account_paying, v2_account_sub, v2_account_trial, v2_account_exempt, v2_account_free])
         OR id = ANY(v2_ret_accounts);
      DELETE FROM public.profiles WHERE id IN (
        v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
        v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
      );
      DELETE FROM public.email_logs WHERE user_id IN (
        v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
        v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
      );
      DELETE FROM public.operation_idempotency WHERE user_id IN (
        v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
        v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
      );
      DELETE FROM auth.users WHERE id IN (
        v2_admin_id, v2_owner_paying_id, v2_owner_sub_id, v2_owner_trial_id, v2_owner_exempt_id, v2_owner_free_id,
        v2_ret_r_id, v2_ret_nr_id, v2_ret_imm_id
      );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
