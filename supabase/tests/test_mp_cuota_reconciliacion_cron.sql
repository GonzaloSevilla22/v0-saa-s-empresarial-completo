-- =============================================================================
-- GATE: test_mp_cuota_reconciliacion_cron.sql
-- CHANGE: mp-cuota-acreditacion-resiliente (governance CRÍTICO, dinero real)
-- MIGRACIÓN: 20261092000001_mp_cuota_reconciliacion_cron.sql
--
-- El barrido horario es la red principal que acredita el cobro mensual de
-- una suscripción cuando MercadoPago no notifica la cuota `processed` (caso
-- real: noviembre 2026). Este gate EJECUTA la función disparadora — no sólo
-- verifica que exista — y fija:
--   (1) introspección: SECURITY DEFINER, search_path fijo (public, vault),
--       lee los MISMOS secretos de Vault que el relay del CAE.
--   (2) ACLs: ni PUBLIC, ni anon, ni authenticated, ni service_role pueden
--       ejecutarla (dispara llamadas HTTP firmadas con el secreto del relay).
--   (3) job pg_cron: UNO solo, activo, cada hora al minuto 7, que llama a la
--       función.
--   (4) fail-closed: sin secretos en Vault la función NO falla y NO encola
--       ninguna llamada HTTP.
--   (5) con secretos: encola UN POST a /payments/subscriptions/reconcile-cron
--       con `Authorization: Bearer <secreto>`, sin doble barra aunque la URL
--       base termine en `/`, y con timeout de 30 s.
-- (4) y (5) corren en subtransacciones que se deshacen: el gate no deja
-- secretos ni requests encolados, ni toca los que el entorno ya tuviera.
-- =============================================================================

-- ═══════════ (1) + (2) INTROSPECCIÓN Y ACLs ══════════════════════════════════
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_role text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'rpc_trigger_subscription_reconcile'
    AND pg_get_function_identity_arguments(p.oid) = '';
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (1): public.rpc_trigger_subscription_reconcile() no existe.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('SECURITY DEFINER' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (1): la función debe ser SECURITY DEFINER.';
  END IF;
  IF position('SET search_path TO ''public'', ''vault''' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (1): search_path fijo (public, vault) ausente.';
  END IF;
  IF position('cae_relay_secret' in v_def) = 0 OR position('backend_base_url' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (1): debe leer cae_relay_secret y backend_base_url de Vault (OQ-2 a).';
  END IF;

  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF has_function_privilege(v_role, v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (2): % puede ejecutar rpc_trigger_subscription_reconcile().', v_role;
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (2): PUBLIC conserva EXECUTE.';
  END IF;

  RAISE NOTICE 'GATE MP-CUOTA-CRON (1)(2) PASSED: SECURITY DEFINER, search_path fijo, secretos del relay, sin EXECUTE para PUBLIC/anon/authenticated/service_role.';
END $$;

-- ═══════════ (3) JOB pg_cron ══════════════════════════════════════════════════
DO $$
DECLARE
  v_count int;
  v_schedule text;
  v_command text;
  v_active boolean;
BEGIN
  SELECT count(*) INTO v_count FROM cron.job WHERE jobname = 'subscription-reconcile-charges';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (3): se esperaba UN job subscription-reconcile-charges, hay %.', v_count;
  END IF;
  SELECT schedule, command, active INTO v_schedule, v_command, v_active
  FROM cron.job WHERE jobname = 'subscription-reconcile-charges';
  IF v_schedule <> '7 * * * *' THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (3): schedule % (esperado 7 * * * *, OQ-3 a).', v_schedule;
  END IF;
  IF NOT v_active THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (3): el job está inactivo.';
  END IF;
  IF position('public.rpc_trigger_subscription_reconcile()' in v_command) = 0 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (3): el job no llama a public.rpc_trigger_subscription_reconcile().';
  END IF;
  IF v_command ILIKE '%Bearer%' OR v_command ILIKE '%decrypted_secret%' THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (3): el cuerpo del job expone el secreto (debe leerlo la función).';
  END IF;
  RAISE NOTICE 'GATE MP-CUOTA-CRON (3) PASSED: un job activo, 7 * * * *, delega en la función.';
END $$;

-- ═══════════ (4) FAIL-CLOSED SIN SECRETOS — EJECUTA la función ═══════════════
DO $$
DECLARE
  v_before bigint;
  v_after bigint;
BEGIN
  BEGIN
    DELETE FROM vault.secrets WHERE name IN ('backend_base_url', 'cae_relay_secret');
    SELECT count(*) INTO v_before FROM net.http_request_queue;
    PERFORM public.rpc_trigger_subscription_reconcile();
    SELECT count(*) INTO v_after FROM net.http_request_queue;
    RAISE EXCEPTION USING ERRCODE = 'P0999', MESSAGE = 'rollback (4)';
  EXCEPTION WHEN SQLSTATE 'P0999' THEN
    NULL;  -- deshace el DELETE de los secretos (si el entorno los tenía, vuelven)
  END;
  IF v_after IS NULL THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (4): la función falló sin secretos (debe salir con WARNING).';
  END IF;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (4): sin secretos encoló % request(s) HTTP (fail-closed roto).', v_after - v_before;
  END IF;
  RAISE NOTICE 'GATE MP-CUOTA-CRON (4) PASSED: sin secretos, la función sale limpia y no encola ninguna llamada.';
END $$;

-- ═══════════ (5) CON SECRETOS — encola UN POST firmado ═══════════════════════
DO $$
DECLARE
  v_before bigint;
  v_after bigint;
  v_url text;
  v_method text;
  v_auth text;
  v_timeout int;
BEGIN
  BEGIN
    DELETE FROM vault.secrets WHERE name IN ('backend_base_url', 'cae_relay_secret');
    PERFORM vault.create_secret('http://127.0.0.1:9/', 'backend_base_url', 'gate mp-cuota-acreditacion-resiliente');
    PERFORM vault.create_secret('gate-relay-secret', 'cae_relay_secret', 'gate mp-cuota-acreditacion-resiliente');
    SELECT count(*) INTO v_before FROM net.http_request_queue;
    PERFORM public.rpc_trigger_subscription_reconcile();
    SELECT count(*) INTO v_after FROM net.http_request_queue;
    SELECT q.url, q.method, q.headers ->> 'Authorization', q.timeout_milliseconds
      INTO v_url, v_method, v_auth, v_timeout
    FROM net.http_request_queue q
    ORDER BY q.id DESC LIMIT 1;
    RAISE EXCEPTION USING ERRCODE = 'P0999', MESSAGE = 'rollback (5)';
  EXCEPTION WHEN SQLSTATE 'P0999' THEN
    NULL;  -- deshace secretos de prueba y el request encolado
  END;
  IF v_after IS DISTINCT FROM v_before + 1 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (5): con secretos debía encolar 1 request, encoló %.', coalesce(v_after - v_before, -1);
  END IF;
  IF v_url <> 'http://127.0.0.1:9/payments/subscriptions/reconcile-cron' THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (5): URL inesperada %.', v_url;
  END IF;
  IF v_method <> 'POST' THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (5): método % (esperado POST).', v_method;
  END IF;
  IF v_auth IS DISTINCT FROM 'Bearer gate-relay-secret' THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (5): cabecera Authorization inesperada.';
  END IF;
  IF v_timeout IS DISTINCT FROM 30000 THEN
    RAISE EXCEPTION 'GATE MP-CUOTA-CRON FAILED (5): timeout % ms (esperado 30000).', v_timeout;
  END IF;
  RAISE NOTICE 'GATE MP-CUOTA-CRON (5) PASSED: un POST a /payments/subscriptions/reconcile-cron con el Bearer del relay y 30 s de timeout.';
END $$;

DO $$ BEGIN RAISE NOTICE 'GATE MP-CUOTA-CRON: todos los bloques PASSED.'; END $$;
