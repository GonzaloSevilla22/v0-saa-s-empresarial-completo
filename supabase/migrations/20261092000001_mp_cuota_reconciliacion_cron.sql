-- ============================================================
-- mp-cuota-acreditacion-resiliente (governance CRÍTICO — dinero real)
-- Barrido horario de reconciliación de cuotas de suscripción:
-- pg_cron → rpc_trigger_subscription_reconcile() → pg_net →
-- POST /payments/subscriptions/reconcile-cron (backend).
-- ============================================================
-- Por qué: el 2026-11-04 MercadoPago cobró la cuota de noviembre ($24.900,
-- pago 187789722328) de la suscripción fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1
-- y NUNCA notificó la cuota `processed`; el backend sólo acreditaba con esa
-- notificación. El barrido reconcilia contra la API de MercadoPago las
-- suscripciones cuyo período pagado ya alcanzó su fecha de cobro, sin
-- depender de ninguna notificación (design.md D1/D4/D5).
--
-- Molde exacto de rpc_trigger_cae_relay() (20260719000001_c27_cae_relay_trigger.sql):
--   * SECURITY DEFINER con search_path fijo (public, vault): lee los secretos
--     de vault.decrypted_secrets sin que el cuerpo del cron los exponga.
--   * Reutiliza los MISMOS secretos de Vault (OQ-2 (a), firmada por el PO el
--     2026-11-05): `backend_base_url` y `cae_relay_secret` — cero pasos
--     manuales nuevos en prod. El backend verifica ese mismo valor como
--     RELAY_SECRET con la dependencia compartida `require_relay_secret`.
--   * Falla CERRADO sin romper el job: si falta cualquiera de los dos
--     secretos, RAISE WARNING y RETURN — no se hace ninguna llamada HTTP.
--   * Fire-and-forget (pg_net encola el request y responde después).
--     timeout_milliseconds = 30000 (el default de pg_net es 5 s): Render en
--     frío tarda ~50 s en despertar; aunque pg_net corte antes, el backend
--     termina el barrido, y si no, la corrida siguiente lo reintenta.
--
-- Cadencia (OQ-3 (a)): cada hora, al minuto 7 — lejos del minuto 0 donde ya
-- corren reset-ai-counters y otros jobs, y del `* * * * *` del relay del CAE.
--
-- Idempotente: CREATE OR REPLACE de la función (misma firma), ACLs
-- re-aplicadas explícitamente en este mismo archivo, y cron.unschedule
-- condicional antes de cron.schedule (reaplicarla deja UN solo job).
--
-- Rollback sin deploy: SELECT cron.unschedule('subscription-reconcile-charges');
--
-- Aplicada vía: npx supabase db push (CI deploy.yml) — NUNCA el MCP apply_migration.
-- ============================================================


-- ============================================================
-- 1. rpc_trigger_subscription_reconcile()
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_trigger_subscription_reconcile()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE
  v_backend_url  text;
  v_relay_secret text;
BEGIN
  SELECT decrypted_secret INTO v_backend_url
  FROM vault.decrypted_secrets
  WHERE name = 'backend_base_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_relay_secret
  FROM vault.decrypted_secrets
  WHERE name = 'cae_relay_secret'
  LIMIT 1;

  -- Fail-closed: sin los dos secretos no se dispara nada (y el job no falla).
  IF v_backend_url IS NULL OR v_backend_url = '' OR v_relay_secret IS NULL OR v_relay_secret = '' THEN
    RAISE WARNING 'rpc_trigger_subscription_reconcile: vault secrets not configured (backend_base_url or cae_relay_secret missing) — skipping HTTP call';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url                  := rtrim(v_backend_url, '/') || '/payments/subscriptions/reconcile-cron',
    body                 := '{}'::jsonb,
    params               := '{}'::jsonb,
    headers              := jsonb_build_object(
                              'Content-Type',  'application/json',
                              'Authorization', 'Bearer ' || v_relay_secret
                            ),
    timeout_milliseconds := 30000
  );
END;
$function$;

-- Sólo pg_cron (postgres) la ejecuta. anon/authenticated NUNCA: dispararía
-- llamadas HTTP autenticadas con el secreto del relay.
REVOKE ALL ON FUNCTION public.rpc_trigger_subscription_reconcile() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_trigger_subscription_reconcile() FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_trigger_subscription_reconcile() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_trigger_subscription_reconcile() FROM service_role;

COMMENT ON FUNCTION public.rpc_trigger_subscription_reconcile() IS
  'mp-cuota-acreditacion-resiliente (D5): SECURITY DEFINER — lee backend_base_url + cae_relay_secret '
  'de vault.decrypted_secrets y llama a POST /payments/subscriptions/reconcile-cron vía net.http_post. '
  'Invocada por el pg_cron subscription-reconcile-charges cada hora (minuto 7). Fail-closed: '
  'WARNING y salida sin llamada HTTP si falta algún secreto.';


-- ============================================================
-- 2. Job pg_cron (idempotente: unschedule condicional + schedule)
-- ============================================================

SELECT cron.unschedule('subscription-reconcile-charges')
FROM cron.job WHERE jobname = 'subscription-reconcile-charges';

SELECT cron.schedule(
  'subscription-reconcile-charges',
  '7 * * * *',
  $$
    -- mp-cuota-acreditacion-resiliente: barrido horario de cuotas de suscripción.
    -- El secreto vive en Vault y lo lee la función SECURITY DEFINER (nunca acá).
    SELECT public.rpc_trigger_subscription_reconcile();
  $$
);
