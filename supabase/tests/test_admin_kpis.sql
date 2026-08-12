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
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz)',
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

  -- Gate 2.5: cohorte madura (activación hace 45 días, retenida al día 32) e
  -- inmadura (activación hoy).
  v_mature_cohort := date_trunc('week', now() - interval '45 days');
  INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
  VALUES (v_mature_id, v_admin_account, 'first_operation', jsonb_build_object('entity_type', 'expense'), now() - interval '45 days');

  INSERT INTO public.analytics_events (id, user_id, account_id, event_name, event_data, created_at)
  VALUES (v_mature_op_id, v_mature_id, v_admin_account, 'operation_created',
          jsonb_build_object('entity_id', v_mature_op_id::text, 'entity_type', 'expense', 'source', 'gate'),
          now() - interval '45 days' + interval '32 days');

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
        format('FAIL 2.5a: cohorte activada hace 45 días esperaba is_mature=true, obtuvo %s', v_mature_row->>'is_mature'));
    ELSE
      RAISE NOTICE 'PASS 2.5a: cohorte madura (45 días) marca is_mature=true con observation_window_days=%', v_mature_row->>'observation_window_days';
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
  DELETE FROM public.branches  WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts);
  DELETE FROM public.account_members WHERE user_id IN (
    v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
  );
  DELETE FROM public.accounts WHERE id = v_admin_account OR id = ANY(v_secondary_accounts);
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
      DELETE FROM public.branches  WHERE account_id = v_admin_account OR account_id = ANY(v_secondary_accounts);
      DELETE FROM public.account_members WHERE user_id IN (
        v_admin_id, v_user_a_id, v_user_b_id, v_user_c_id, v_act1_id, v_act2_id, v_mature_id, v_immature_id
      );
      DELETE FROM public.accounts WHERE id = v_admin_account OR id = ANY(v_secondary_accounts);
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
