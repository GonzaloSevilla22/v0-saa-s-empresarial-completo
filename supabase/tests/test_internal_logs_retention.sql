-- =============================================================================
-- test_internal_logs_retention.sql — Gates de comportamiento: internal-logs-
-- retention
--
-- Contexto (diagnóstico medido en prod, gxdhpxvdjjkmxhdkkwyb, 2026-08-17):
--   - net._http_response: pg_net.ttl = 6 horas YA funciona (360 filas ≡ 6h ×
--     60 min de relay-process-outbox). Los 31 MB son bloat de heap, no filas
--     retenidas — VACUUM normal no lo devuelve al SO. Este gate NO verifica
--     ninguna purga por antigüedad sobre esta tabla (sería código muerto
--     compitiendo con el TTL nativo de pg_net) — verifica que exista el job
--     de VACUUM (FULL, ANALYZE) y que NINGÚN job tenga un DELETE sobre ella.
--   - cron.job_run_details: ya tenía purga plana de 7 días (20260630000001).
--     El 98% del volumen son los dos jobs `* * * * *`. Este gate verifica la
--     ventana ESCALONADA por frecuencia del schedule: 1 día para jobs de
--     alto volumen (minutos = `*` o `*/N`), 14 días para el resto y para
--     filas huérfanas (job ya desprogramado).
--   - public.email_logs: único caso de retención cero real → techo de 90 días.
--
-- Guard defensivo (D7): ninguna migración del repo crea la extensión pg_net
-- (la habilita la plataforma) — si el stack local de `supabase start` no la
-- trae precreada, las aserciones sobre net._http_response se omiten con
-- RAISE NOTICE en vez de fallar el CI por algo que no es una regresión.
--
-- Patrón del proyecto (test_kpis.sql / test_analytics_events.sql): acumular
-- fallos estructurales en text[], un solo RAISE EXCEPTION al final para que
-- `psql -v ON_ERROR_STOP=1` salga con código distinto de cero. Las secciones
-- de comportamiento (B/C) invocan directamente public.purge_internal_logs()
-- — si la función todavía no existe (fase RED), Postgres aborta el bloque
-- con "function ... does not exist" antes de llegar a esas secciones; por
-- eso las aserciones ESTRUCTURALES de la función/jobs se evalúan primero y
-- cortan temprano con el detalle acumulado si algo básico falta.
--
-- Corre en CI: KPI_Validation.yml -v ON_ERROR_STOP=1 (paso agregado en el
-- mismo PR que este archivo).
-- =============================================================================

DO $$
DECLARE
  v_failures            text[] := '{}';
  v_count               integer;
  v_bool                boolean;
  v_net_present         boolean;
  v_job_command         text;

  -- Jobs base preexistentes usados como anchors reales para las filas
  -- sintéticas de cron.job_run_details (no los crea este change).
  v_jobid_high_a        bigint;  -- relay-process-outbox        (* * * * *)
  v_jobid_high_b        bigint;  -- relay-process-pending-cae   (* * * * *)
  v_jobid_daily         bigint;  -- billing-plan-limit-exceeded-sweep (0 4 * * *)
  v_jobid_orphan        CONSTANT bigint := 987654321;  -- sentinel, no existe en cron.job

  -- runids de las filas sintéticas de cron.job_run_details. Sentinels
  -- NEGATIVOS explícitos (nunca DEFAULT/nextval): el rol `postgres` tiene
  -- INSERT sobre cron.job_run_details pero NO tiene USAGE sobre
  -- cron.runid_seq (owner supabase_admin, sin GRANT explícito) — invocar el
  -- DEFAULT del PK dispara "permission denied for sequence runid_seq". Los
  -- runids reales de pg_cron son siempre positivos (nextval arranca en 1),
  -- así que estos sentinels nunca colisionan.
  v_runid_old_high      CONSTANT bigint := -900001;
  v_runid_recent_high   CONSTANT bigint := -900002;
  v_runid_daily_10d     CONSTANT bigint := -900003;
  v_runid_daily_20d     CONSTANT bigint := -900004;
  v_runid_orphan_3d     CONSTANT bigint := -900005;

  -- ids de las filas sintéticas de email_logs
  v_email_old_id        uuid;
  v_email_recent_id     uuid;
BEGIN
  -- ═══ SECCIÓN A — ESTRUCTURAL: función canónica + registro de jobs ═════════

  IF to_regprocedure('public.purge_internal_logs()') IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL A1: public.purge_internal_logs() no existe');
  ELSE
    RAISE NOTICE 'PASS A1: public.purge_internal_logs() existe';
  END IF;

  SELECT count(*) INTO v_count
  FROM cron.job WHERE jobname = 'purge-internal-logs' AND schedule = '0 4 * * *' AND active;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL A2: se esperaba exactamente 1 job activo "purge-internal-logs" con schedule "0 4 * * *", hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS A2: job purge-internal-logs registrado con el schedule esperado';
  END IF;

  SELECT count(*) INTO v_count
  FROM cron.job WHERE jobname = 'vacuum-full-net-http-response' AND schedule = '20 4 * * *' AND active;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL A3: se esperaba exactamente 1 job activo "vacuum-full-net-http-response" con schedule "20 4 * * *", hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS A3: job vacuum-full-net-http-response registrado con el schedule esperado';
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-cron-job-run-details') THEN
    v_failures := array_append(v_failures,
      'FAIL A4: el job "purge-cron-job-run-details" (superado por purge-internal-logs) sigue registrado');
  ELSE
    RAISE NOTICE 'PASS A4: purge-cron-job-run-details fue retirado';
  END IF;

  SELECT count(*) INTO v_count FROM cron.job WHERE command ILIKE '%DELETE%net._http_response%';
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      'FAIL A5: hay un job con DELETE sobre net._http_response — D1 prohíbe purga por antigüedad ahí (pg_net.ttl ya la hace)');
  ELSE
    RAISE NOTICE 'PASS A5: ningún job borra por antigüedad sobre net._http_response';
  END IF;

  SELECT count(*) INTO v_count
  FROM cron.job
  WHERE jobname <> 'purge-internal-logs'
    AND (command ILIKE '%DELETE%cron.job_run_details%' OR command ILIKE '%DELETE%email_logs%');
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      'FAIL A6: hay lógica de retención duplicada embebida en el comando de otro job — debe vivir sólo en purge_internal_logs()');
  ELSE
    RAISE NOTICE 'PASS A6: no hay retención duplicada embebida en otros comandos de cron';
  END IF;

  SELECT command INTO v_job_command FROM cron.job WHERE jobname = 'purge-internal-logs';
  IF v_job_command IS NULL OR v_job_command !~* 'purge_internal_logs' THEN
    v_failures := array_append(v_failures,
      'FAIL A7: el comando del job purge-internal-logs no invoca public.purge_internal_logs()');
  ELSE
    RAISE NOTICE 'PASS A7: el comando de purge-internal-logs se limita a invocar la función canónica';
  END IF;

  -- Corte temprano y limpio: sin la función ni los jobs no tiene sentido
  -- seguir a las secciones de comportamiento (Postgres abortaría el bloque
  -- entero con "function ... does not exist" en vez de reportar el detalle
  -- acumulado arriba).
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE INTERNAL-LOGS-RETENTION FAILED (estructural):\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  -- ═══ SECCIÓN B — COMPORTAMIENTO: cron.job_run_details escalonado ══════════

  SELECT jobid INTO v_jobid_high_a FROM cron.job WHERE jobname = 'relay-process-outbox';
  SELECT jobid INTO v_jobid_high_b FROM cron.job WHERE jobname = 'relay-process-pending-cae';
  SELECT jobid INTO v_jobid_daily  FROM cron.job WHERE jobname = 'billing-plan-limit-exceeded-sweep';

  IF v_jobid_high_a IS NULL OR v_jobid_daily IS NULL THEN
    RAISE NOTICE 'GATE INTERNAL-LOGS-RETENTION: jobs base (relay-process-outbox / billing-plan-limit-exceeded-sweep) no encontrados en este entorno — sección de comportamiento de cron.job_run_details omitida (no son objetos de este change).';
  ELSE
    -- Vieja ejecución de un job por minuto (> 1 día) → debe purgarse.
    INSERT INTO cron.job_run_details
      (runid, jobid, job_pid, database, username, command, status, return_message, start_time, end_time)
    VALUES (v_runid_old_high, v_jobid_high_a, NULL, current_database(), 'postgres', '__gate_ilr_old_high_freq__', 'succeeded', NULL,
            now() - interval '2 days', now() - interval '2 days');

    -- Ejecución reciente del mismo tipo de job (< 1 día) → debe sobrevivir.
    INSERT INTO cron.job_run_details
      (runid, jobid, job_pid, database, username, command, status, return_message, start_time, end_time)
    VALUES (v_runid_recent_high, v_jobid_high_b, NULL, current_database(), 'postgres', '__gate_ilr_recent_high_freq__', 'succeeded', NULL,
            now() - interval '1 hour', now() - interval '1 hour');

    -- Job diario: 10 días → sobrevive (ventana de 14 días); 20 días → purga.
    INSERT INTO cron.job_run_details
      (runid, jobid, job_pid, database, username, command, status, return_message, start_time, end_time)
    VALUES (v_runid_daily_10d, v_jobid_daily, NULL, current_database(), 'postgres', '__gate_ilr_daily_10d__', 'succeeded', NULL,
            now() - interval '10 days', now() - interval '10 days');

    INSERT INTO cron.job_run_details
      (runid, jobid, job_pid, database, username, command, status, return_message, start_time, end_time)
    VALUES (v_runid_daily_20d, v_jobid_daily, NULL, current_database(), 'postgres', '__gate_ilr_daily_20d__', 'succeeded', NULL,
            now() - interval '20 days', now() - interval '20 days');

    -- Fila huérfana (jobid inexistente en cron.job), 3 días → sobrevive
    -- (ventana larga: es evidencia de un job desprogramado).
    INSERT INTO cron.job_run_details
      (runid, jobid, job_pid, database, username, command, status, return_message, start_time, end_time)
    VALUES (v_runid_orphan_3d, v_jobid_orphan, NULL, current_database(), 'postgres', '__gate_ilr_orphan_3d__', 'succeeded', NULL,
            now() - interval '3 days', now() - interval '3 days');

    PERFORM public.purge_internal_logs();

    IF EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_old_high) THEN
      v_failures := array_append(v_failures, 'FAIL B1: ejecución vieja (2 días) de un job por minuto no fue purgada (ventana de 1 día)');
    ELSE
      RAISE NOTICE 'PASS B1: ejecución vieja de un job de alta frecuencia se purga a 1 día';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_recent_high) THEN
      v_failures := array_append(v_failures, 'FAIL B2: ejecución reciente (1 hora) de un job por minuto fue purgada indebidamente');
    ELSE
      RAISE NOTICE 'PASS B2: ejecución reciente de un job de alta frecuencia sobrevive';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_daily_10d) THEN
      v_failures := array_append(v_failures, 'FAIL B3: ejecución de 10 días de un job diario fue purgada indebidamente (ventana de 14 días)');
    ELSE
      RAISE NOTICE 'PASS B3: un job diario conserva su historia dentro de los 14 días';
    END IF;

    IF EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_daily_20d) THEN
      v_failures := array_append(v_failures, 'FAIL B4: ejecución de 20 días de un job diario no fue purgada (excede la ventana de 14 días)');
    ELSE
      RAISE NOTICE 'PASS B4: un job diario pierde historia más allá de los 14 días';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_orphan_3d) THEN
      v_failures := array_append(v_failures, 'FAIL B5: una fila huérfana de 3 días fue purgada indebidamente (las huérfanas usan la ventana larga de 14 días)');
    ELSE
      RAISE NOTICE 'PASS B5: las filas huérfanas usan la ventana larga (14 días)';
    END IF;

    -- Idempotencia real: correr la purga una segunda vez no debe alterar los
    -- sobrevivientes ni fallar.
    PERFORM public.purge_internal_logs();

    IF NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_recent_high)
       OR NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_daily_10d)
       OR NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE runid = v_runid_orphan_3d) THEN
      v_failures := array_append(v_failures, 'FAIL B6: una segunda ejecución de purge_internal_logs() alteró filas que ya habían sobrevivido a la primera (no idempotente)');
    ELSE
      RAISE NOTICE 'PASS B6: una segunda ejecución de purge_internal_logs() es idempotente sobre los sobrevivientes';
    END IF;

    -- Limpieza de las filas sintéticas restantes (best-effort).
    DELETE FROM cron.job_run_details
    WHERE runid IN (v_runid_recent_high, v_runid_daily_10d, v_runid_orphan_3d);
  END IF;

  -- ═══ SECCIÓN C — COMPORTAMIENTO: public.email_logs a 90 días ═════════════

  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, status, created_at)
  VALUES (NULL, '__gate_ilr_email_old__', 'gate-ilr-old@test.local', 'gate', 'sent', now() - interval '100 days')
  RETURNING id INTO v_email_old_id;

  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, status, created_at)
  VALUES (NULL, '__gate_ilr_email_recent__', 'gate-ilr-recent@test.local', 'gate', 'sent', now() - interval '30 days')
  RETURNING id INTO v_email_recent_id;

  PERFORM public.purge_internal_logs();

  IF EXISTS (SELECT 1 FROM public.email_logs WHERE id = v_email_old_id) THEN
    v_failures := array_append(v_failures, 'FAIL C1: un log de email de 100 días no fue purgado (ventana de 90 días)');
  ELSE
    RAISE NOTICE 'PASS C1: un log de email de 100 días se purga';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.email_logs WHERE id = v_email_recent_id) THEN
    v_failures := array_append(v_failures, 'FAIL C2: un log de email de 30 días fue purgado indebidamente (dentro de la ventana de 90 días)');
  ELSE
    RAISE NOTICE 'PASS C2: un log de email de 30 días sobrevive';
  END IF;

  DELETE FROM public.email_logs WHERE id = v_email_recent_id;

  -- ═══ SECCIÓN D — SUPERFICIE DE AUTORIZACIÓN ═══════════════════════════════

  IF has_function_privilege('anon', 'public.purge_internal_logs()', 'EXECUTE') THEN
    v_failures := array_append(v_failures, 'FAIL D1: anon puede ejecutar public.purge_internal_logs() — debe estar revocado');
  ELSE
    RAISE NOTICE 'PASS D1: anon no puede ejecutar purge_internal_logs()';
  END IF;

  IF has_function_privilege('authenticated', 'public.purge_internal_logs()', 'EXECUTE') THEN
    v_failures := array_append(v_failures, 'FAIL D2: authenticated puede ejecutar public.purge_internal_logs() — debe estar revocado');
  ELSE
    RAISE NOTICE 'PASS D2: authenticated no puede ejecutar purge_internal_logs()';
  END IF;

  IF NOT has_function_privilege('postgres', 'public.purge_internal_logs()', 'EXECUTE') THEN
    v_failures := array_append(v_failures, 'FAIL D3: postgres (el rol bajo el que corren los cron jobs) NO puede ejecutar purge_internal_logs()');
  ELSE
    RAISE NOTICE 'PASS D3: postgres puede ejecutar purge_internal_logs()';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    WHERE p.oid = to_regprocedure('public.purge_internal_logs()')
      AND p.proconfig IS NOT NULL
      AND EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg ILIKE 'search_path=%')
  ) INTO v_bool;
  IF NOT v_bool THEN
    v_failures := array_append(v_failures, 'FAIL D4: purge_internal_logs() no tiene un search_path explícito en pg_proc.proconfig');
  ELSE
    RAISE NOTICE 'PASS D4: purge_internal_logs() fija search_path explícito';
  END IF;

  -- ═══ SECCIÓN E — RECLAMO DE ESPACIO net._http_response (guard D7/OQ-3) ═══

  v_net_present := to_regclass('net._http_response') IS NOT NULL;
  IF NOT v_net_present THEN
    RAISE NOTICE 'GATE INTERNAL-LOGS-RETENTION: schema net / net._http_response no existe en este stack (pg_net no precreado) — aserciones de reclamo de espacio omitidas (D7/OQ-3). La verificación del VACUUM FULL queda como post-deploy en prod.';
  ELSE
    SELECT count(*) INTO v_count
    FROM cron.job
    WHERE jobname = 'vacuum-full-net-http-response'
      AND command ILIKE '%VACUUM%FULL%net._http_response%';
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, 'FAIL E1: el job vacuum-full-net-http-response no ejecuta VACUUM (FULL, ...) sobre net._http_response');
    ELSE
      RAISE NOTICE 'PASS E1: el job de reclamo de espacio ejecuta VACUUM (FULL) sobre net._http_response';
    END IF;
  END IF;

  -- ═══ SECCIÓN F — RE-REGISTRO IDEMPOTENTE DE LOS JOBS ═════════════════════
  -- Simula re-aplicar el bloque unschedule-si-existe + schedule de la
  -- migración dos veces seguidas: no debe duplicar jobs ni fallar.

  PERFORM cron.unschedule(jobname) FROM cron.job
  WHERE jobname IN ('purge-internal-logs', 'vacuum-full-net-http-response');

  PERFORM cron.schedule('purge-internal-logs', '0 4 * * *',
    $sched$SELECT public.purge_internal_logs();$sched$);
  PERFORM cron.schedule('vacuum-full-net-http-response', '20 4 * * *',
    $sched$VACUUM (FULL, ANALYZE) net._http_response;$sched$);

  PERFORM cron.unschedule(jobname) FROM cron.job
  WHERE jobname IN ('purge-internal-logs', 'vacuum-full-net-http-response');

  PERFORM cron.schedule('purge-internal-logs', '0 4 * * *',
    $sched$SELECT public.purge_internal_logs();$sched$);
  PERFORM cron.schedule('vacuum-full-net-http-response', '20 4 * * *',
    $sched$VACUUM (FULL, ANALYZE) net._http_response;$sched$);

  SELECT count(*) INTO v_count FROM cron.job WHERE jobname = 'purge-internal-logs';
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL F1: re-aplicar el registro del job purge-internal-logs dos veces dejó %s filas en cron.job (se esperaba 1)', v_count));
  ELSE
    RAISE NOTICE 'PASS F1: re-registrar purge-internal-logs es idempotente';
  END IF;

  SELECT count(*) INTO v_count FROM cron.job WHERE jobname = 'vacuum-full-net-http-response';
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL F2: re-aplicar el registro del job vacuum-full-net-http-response dos veces dejó %s filas en cron.job (se esperaba 1)', v_count));
  ELSE
    RAISE NOTICE 'PASS F2: re-registrar vacuum-full-net-http-response es idempotente';
  END IF;

  -- ═══ RESULTADO ═════════════════════════════════════════════════════════

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE INTERNAL-LOGS-RETENTION FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE INTERNAL-LOGS-RETENTION PASSED: función canónica, retención escalonada de cron.job_run_details (alta frecuencia/diaria/huérfana), techo de email_logs a 90 días, superficie de autorización, reclamo de espacio de net._http_response y re-registro idempotente de los jobs — verificados.';

  -- Limpieza best-effort de residuos sintéticos (por si alguna rama arriba
  -- no llegó a limpiar los suyos).
  DELETE FROM cron.job_run_details WHERE command LIKE '\_\_gate\_ilr\_%' ESCAPE '\';
  DELETE FROM public.email_logs    WHERE event_type LIKE '\_\_gate\_ilr\_%' ESCAPE '\';

EXCEPTION
  WHEN OTHERS THEN
    -- Limpieza best-effort incluso si algo falló a mitad de camino.
    BEGIN
      DELETE FROM cron.job_run_details WHERE command LIKE '\_\_gate\_ilr\_%' ESCAPE '\';
      DELETE FROM public.email_logs    WHERE event_type LIKE '\_\_gate\_ilr\_%' ESCAPE '\';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
