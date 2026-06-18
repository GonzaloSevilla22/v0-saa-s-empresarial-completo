-- ============================================================
-- C-27 v21-fiscal-profile — CAE relay trigger: pg_cron → backend HTTP
-- ============================================================
-- Rewrites the relay-process-pending-cae pg_cron job so its body
-- calls the backend machine endpoint POST /fiscal/documents/process-pending-cron
-- via net.http_post (pg_net), replacing the placeholder UPDATE no-op.
--
-- Architecture (OQ-1=A, D6):
--   1. Emit: POST /fiscal/documents/emit → persists pending_cae doc →
--            BackgroundTask → process_doc_by_id_background (fire-and-forget)
--   2. Backstop: pg_cron every minute → this job → POST /process-pending-cron
--      Anti-double-CAE: claim_pending lease (next_attempt_at +5min) ensures
--      fire-and-forget and pg_cron never both call request_cae for the same doc.
--
-- Dependencies:
--   - pg_net  v0.19.5  (already installed in prod)
--   - pg_cron 1.6.4    (already installed in prod)
--   - vault extension  (Supabase built-in)
--
-- Applied via: npx supabase db push (CLI, NEVER via MCP apply_migration).
--
-- ============================================================
-- ONE-TIME PROD SETUP — run out-of-band by the PO BEFORE merging this migration
-- ============================================================
-- Step 1: Store the relay shared secret in Supabase Vault
--   (generate a strong random value, e.g.: openssl rand -hex 32)
--
-- SELECT vault.create_secret(
--   '<YOUR_RELAY_SECRET_VALUE>',   -- the actual secret value (never hardcode here)
--   'cae_relay_secret',            -- name used in vault.decrypted_secrets
--   'CAE relay shared secret — used by pg_cron to authenticate against the backend machine endpoint'
-- );
--
-- Step 2: Store the backend base URL (or reuse existing if already present)
--
-- SELECT vault.create_secret(
--   'https://emprende-smart-backend.onrender.com',
--   'backend_base_url',
--   'Render backend base URL for pg_cron HTTP calls'
-- );
--
-- Step 3: Set the same secret in Render environment variables
--   Dashboard → emprende-smart-backend → Environment → Add variable:
--     RELAY_SECRET = <same value as stored in vault step 1>
--
-- Step 4: Verify vault entries exist before pushing migration:
--   SELECT name FROM vault.secrets WHERE name IN ('cae_relay_secret', 'backend_base_url');
--
-- ============================================================


-- ============================================================
-- 1. SECURITY DEFINER helper: rpc_trigger_cae_relay()
-- ============================================================
-- Reads the relay secret and backend URL from vault.decrypted_secrets and
-- fires the net.http_post call. This avoids embedding the vault SELECT inside
-- the cron $$ body (which would require the cron user to have vault SELECT).
-- SECURITY DEFINER runs as the function owner (who has vault access).
--
-- The cron job calls: SELECT rpc_trigger_cae_relay();
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_trigger_cae_relay()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE
  v_backend_url text;
  v_relay_secret text;
BEGIN
  -- Read secrets from Supabase Vault (names set in ONE-TIME PROD SETUP above)
  SELECT decrypted_secret INTO v_backend_url
  FROM vault.decrypted_secrets
  WHERE name = 'backend_base_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_relay_secret
  FROM vault.decrypted_secrets
  WHERE name = 'cae_relay_secret'
  LIMIT 1;

  -- Fail-safe: if secrets are not configured, log and exit (do not attempt HTTP call)
  IF v_backend_url IS NULL OR v_relay_secret IS NULL THEN
    RAISE WARNING 'rpc_trigger_cae_relay: vault secrets not configured (backend_base_url or cae_relay_secret missing) — skipping HTTP call';
    RETURN;
  END IF;

  -- Fire HTTP POST to the machine endpoint (fire-and-forget via pg_net)
  PERFORM net.http_post(
    url     := v_backend_url || '/fiscal/documents/process-pending-cron',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_relay_secret
    ),
    body    := '{}'::jsonb
  );
END;
$function$;

-- Restrict execution: only pg_cron (postgres superuser) may call this function.
-- anon and authenticated roles must NOT be able to trigger this.
REVOKE ALL ON FUNCTION public.rpc_trigger_cae_relay() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_trigger_cae_relay() FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_trigger_cae_relay() FROM authenticated;
-- postgres (superuser) retains implicit EXECUTE — needed by pg_cron.

COMMENT ON FUNCTION public.rpc_trigger_cae_relay IS
  'C-27 (D6, OQ-1=A): SECURITY DEFINER helper that reads cae_relay_secret + backend_base_url '
  'from vault.decrypted_secrets and calls the machine endpoint /fiscal/documents/process-pending-cron '
  'via net.http_post (pg_net). Called by the relay-process-pending-cae pg_cron job every minute. '
  'Fail-safe: logs a WARNING and returns if vault secrets are not configured.';


-- ============================================================
-- 2. Rewrite the pg_cron relay job
-- ============================================================
-- Unschedule-before-schedule guard (idempotent re-run safety).
-- The FROM cron.job WHERE clause makes unschedule a no-op if job doesn't exist.
-- ============================================================

SELECT cron.unschedule('relay-process-pending-cae') FROM cron.job WHERE jobname = 'relay-process-pending-cae';

SELECT cron.schedule(
  'relay-process-pending-cae',
  '* * * * *',  -- cada minuto (backstop para docs que fire-and-forget no alcanzó)
  $$
    -- C-27 (OQ-1=A, D6): pg_cron backstop — dispara el relay del CAE vía HTTP.
    -- La autenticación usa cae_relay_secret leído desde vault.decrypted_secrets
    -- (dentro de rpc_trigger_cae_relay SECURITY DEFINER, sin exponer el secreto aquí).
    -- Anti-double-CAE: el backend usa claim_pending (next_attempt_at +5min lease)
    -- para que fire-and-forget y este cron nunca llamen request_cae para el mismo doc.
    SELECT public.rpc_trigger_cae_relay();
  $$
);

COMMENT ON FUNCTION public.rpc_trigger_cae_relay IS
  'C-27 (D6, OQ-1=A): SECURITY DEFINER helper — lee cae_relay_secret + backend_base_url '
  'de vault.decrypted_secrets y llama al machine endpoint /fiscal/documents/process-pending-cron '
  'via net.http_post. Invocada por el pg_cron relay-process-pending-cae cada minuto.';
