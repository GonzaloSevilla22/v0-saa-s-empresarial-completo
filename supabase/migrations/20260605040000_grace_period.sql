-- =============================================================================
-- MIGRATION: 20260605040000_grace_period.sql
-- CHANGE:    C-03 grace-period-logic
-- DESCRIPTION:
--   Enables pg_cron, creates expire_trials() and queue_trial_notifications()
--   functions, and schedules two daily cron jobs.
--
--   SAFE FOR PRODUCTION:
--   - expire_trials() only touches profiles with billing_status='trialing'
--     AND trial_expires_at IS NOT NULL AND trial_expires_at < now().
--   - The 26 beta users have trial_expires_at = NULL → NEVER touched.
--   - All operations are idempotent (CREATE OR REPLACE, cron.schedule).
--
-- ROLLBACK PLAN (if needed):
--   SELECT cron.unschedule('expire-trials');
--   SELECT cron.unschedule('trial-notifications');
--   DROP FUNCTION IF EXISTS public.expire_trials();
--   DROP FUNCTION IF EXISTS public.queue_trial_notifications();
--   DROP EXTENSION IF EXISTS pg_cron;  -- (only if no other jobs exist)
-- =============================================================================


-- ============================================================
-- BLOCK 1 — Enable pg_cron extension
-- ============================================================

-- NOTE: If this fails with "permission denied" or "not available on this plan",
-- follow the R1 fallback: use a GitHub Actions cron calling a Supabase RPC,
-- or an Edge Function scheduled via Deno.cron (Deno Deploy).
-- In that case, comment out this CREATE EXTENSION and the cron.schedule calls,
-- and document the fallback in this migration's comments.

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ============================================================
-- BLOCK 2 — expire_trials() function
-- ============================================================
-- Transitions trialing → expired for profiles whose trial_expires_at < now().
-- Inserts one billing_events row per expired trial (audit trail).
-- Returns the number of profiles transitioned (0 = nothing to do / idempotent).

CREATE OR REPLACE FUNCTION public.expire_trials()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n integer;
BEGIN
  WITH expired AS (
    UPDATE public.profiles
    SET billing_status = 'expired'
    WHERE billing_status = 'trialing'
      AND trial_expires_at IS NOT NULL
      AND trial_expires_at < now()
    RETURNING id, trial_plan, billing_plan
  )
  INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
  SELECT
    id,
    'trial_expired',
    trial_plan,
    billing_plan,
    'C-03 grace-period auto-downgrade',
    jsonb_build_object('expired_at', now())
  FROM expired;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

COMMENT ON FUNCTION public.expire_trials() IS
  'C-03: Daily sweep that transitions trialing profiles with expired trial_expires_at to billing_status=''expired'' and audits each downgrade in billing_events. Safe for beta users (trial_expires_at IS NULL). Idempotent.';


-- ============================================================
-- BLOCK 3 — queue_trial_notifications() function
-- ============================================================
-- Enqueues email_logs entries for trialing users whose trial expires soon.
-- Windows:
--   7d: trial_expires_at between now()+6d and now()+7d (exclusive upper bound)
--   1d: trial_expires_at between now()    and now()+1d (exclusive upper bound)
-- Deduplication: ON CONFLICT DO NOTHING relies on UNIQUE(user_id, event_type, metadata).
-- Returns the total number of rows inserted (may be 0 if all were already enqueued).
--
-- NOTE: trial_expired email is enqueued by expire_trials() itself (not here).

CREATE OR REPLACE FUNCTION public.queue_trial_notifications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n integer := 0;
  inserted integer;
BEGIN
  -- ── Window 7d: trial expires within 6–7 days (inclusive on lower, exclusive upper) ──
  WITH candidates_7d AS (
    SELECT p.id AS user_id,
           au.email AS recipient
    FROM public.profiles p
    JOIN auth.users au ON au.id = p.id
    WHERE p.billing_status = 'trialing'
      AND p.trial_expires_at IS NOT NULL
      AND p.trial_expires_at >= (now() + INTERVAL '6 days')
      AND p.trial_expires_at <  (now() + INTERVAL '7 days')
  ),
  ins_7d AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT
      user_id,
      'trial_expiring_soon',
      recipient,
      'Te quedan 7 dias de prueba — EmprendeSmart',
      jsonb_build_object('umbral', '7d')
    FROM candidates_7d
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted FROM ins_7d;
  n := n + inserted;

  -- ── Window 1d: trial expires within 0–1 days ──
  WITH candidates_1d AS (
    SELECT p.id AS user_id,
           au.email AS recipient
    FROM public.profiles p
    JOIN auth.users au ON au.id = p.id
    WHERE p.billing_status = 'trialing'
      AND p.trial_expires_at IS NOT NULL
      AND p.trial_expires_at >= now()
      AND p.trial_expires_at <  (now() + INTERVAL '1 day')
  ),
  ins_1d AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT
      user_id,
      'trial_expiring_soon',
      recipient,
      'Tu prueba vence manana — EmprendeSmart',
      jsonb_build_object('umbral', '1d')
    FROM candidates_1d
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted FROM ins_1d;
  n := n + inserted;

  RETURN n;
END;
$$;

COMMENT ON FUNCTION public.queue_trial_notifications() IS
  'C-03: Daily sweep that enqueues email_logs for trialing users whose trial_expires_at falls within the 7d or 1d warning windows. Deduplication via ON CONFLICT DO NOTHING (relies on email_logs UNIQUE constraint). Safe for beta users (trial_expires_at IS NULL).';


-- ============================================================
-- BLOCK 4 — Schedule cron jobs
-- ============================================================
-- cron.schedule is idempotent: if a job with the same name already exists,
-- it is replaced (same as CREATE OR REPLACE semantics in pg_cron).

-- Job 1: expire-trials — runs at 03:00 UTC daily
SELECT cron.schedule(
  'expire-trials',
  '0 3 * * *',
  'SELECT public.expire_trials()'
);

-- Job 2: trial-notifications — runs at 09:00 UTC daily
SELECT cron.schedule(
  'trial-notifications',
  '0 9 * * *',
  'SELECT public.queue_trial_notifications()'
);


-- ── Assertions (run on remote to verify — paste into SQL editor) ─────────────

-- Verify pg_cron extension is installed:
-- SELECT extname FROM pg_extension WHERE extname = 'pg_cron';
-- Expected: 1 row → pg_cron

-- Verify cron jobs are scheduled:
-- SELECT jobname, schedule, command FROM cron.job ORDER BY jobname;
-- Expected: 2 rows — expire-trials (0 3 * * *) and trial-notifications (0 9 * * *)

-- Verify functions exist:
-- SELECT routine_name FROM information_schema.routines
-- WHERE routine_schema = 'public' AND routine_name IN ('expire_trials', 'queue_trial_notifications');
-- Expected: 2 rows

-- =============================================================================
-- END OF MIGRATION 20260605040000_grace_period.sql
-- =============================================================================
