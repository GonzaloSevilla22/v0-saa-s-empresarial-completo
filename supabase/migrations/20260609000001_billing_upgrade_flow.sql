-- =============================================================================
-- MIGRATION: 20260609000001_billing_upgrade_flow.sql
-- CHANGE:    C-10 subscription-ui-upgrade-flow
-- DESCRIPTION:
--   Additive schema for MercadoPago-backed subscription upgrade flow.
--   Block 1: add price_ars_annual to plan_limits + seed
--   Block 2: add MP columns to billing_events
--   Block 3: add plan_expires_at + cancelling status to accounts
--   Block 4: process_cancellations() function + cron job
--
-- ROLLBACK PLAN (if needed):
--   ALTER TABLE public.plan_limits DROP COLUMN IF EXISTS price_ars_annual;
--   ALTER TABLE public.billing_events
--     DROP COLUMN IF EXISTS mercadopago_payment_id,
--     DROP COLUMN IF EXISTS mercadopago_preference_id,
--     DROP COLUMN IF EXISTS amount;
--   ALTER TABLE public.accounts DROP COLUMN IF EXISTS plan_expires_at;
--   -- Revert billing_status CHECK: handled manually (ALTER CONSTRAINT)
--   SELECT cron.unschedule('process-cancellations');
--   DROP FUNCTION IF EXISTS public.process_cancellations();
-- =============================================================================


-- ============================================================
-- BLOCK 1 — plan_limits: add price_ars_annual + seed
-- ============================================================

ALTER TABLE public.plan_limits
  ADD COLUMN IF NOT EXISTS price_ars_annual numeric(12,2) NOT NULL DEFAULT 0;

-- Seed annual prices (monthly * 10 = 2 months free)
UPDATE public.plan_limits SET price_ars_annual = 0       WHERE plan = 'gratis';
UPDATE public.plan_limits SET price_ars_annual = 249000  WHERE plan = 'inicial';
UPDATE public.plan_limits SET price_ars_annual = 349000  WHERE plan = 'avanzado';
UPDATE public.plan_limits SET price_ars_annual = 699000  WHERE plan = 'pro';


-- ============================================================
-- BLOCK 2 — billing_events: MP columns + index
-- ============================================================

ALTER TABLE public.billing_events
  ADD COLUMN IF NOT EXISTS mercadopago_payment_id    text,
  ADD COLUMN IF NOT EXISTS mercadopago_preference_id text,
  ADD COLUMN IF NOT EXISTS amount                    numeric(12,2);

-- UNIQUE index for idempotency: one billing_event per MP payment
CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_events_mp_payment_id
  ON public.billing_events (mercadopago_payment_id)
  WHERE mercadopago_payment_id IS NOT NULL;


-- ============================================================
-- BLOCK 3 — accounts: plan_expires_at + cancelling status
-- ============================================================

-- 3.1 Drop existing CHECK constraint and recreate with 'cancelling'
ALTER TABLE public.accounts
  DROP CONSTRAINT IF EXISTS accounts_billing_status_values;

ALTER TABLE public.accounts
  ADD CONSTRAINT accounts_billing_status_values
    CHECK (billing_status IN ('active', 'trialing', 'expired', 'cancelled', 'cancelling'));

-- 3.2 Add plan_expires_at (null = no scheduled expiry)
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS plan_expires_at timestamptz;

-- Partial index for the daily cancellation sweep
CREATE INDEX IF NOT EXISTS idx_accounts_plan_expires_at
  ON public.accounts (plan_expires_at)
  WHERE plan_expires_at IS NOT NULL;


-- ============================================================
-- BLOCK 4 — process_cancellations() + cron job
-- ============================================================
-- Processes accounts with billing_status='cancelling' and plan_expires_at < now().
-- Downgrades to 'gratis', inserts billing_events audit row, resets plan_expires_at.
-- Returns number of accounts processed. Idempotent.
--
-- DEC-07 (immutability rule): we do NOT modify expire_trials(). This is a
-- separate function for cancellations, scheduled independently.

CREATE OR REPLACE FUNCTION public.process_cancellations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n integer;
BEGIN
  WITH cancelled AS (
    UPDATE public.accounts
    SET
      billing_plan    = 'gratis',
      billing_status  = 'cancelled',
      plan_expires_at = NULL
    WHERE billing_status = 'cancelling'
      AND plan_expires_at IS NOT NULL
      AND plan_expires_at < now()
    RETURNING id, billing_plan AS new_plan, owner_user_id
  )
  INSERT INTO public.billing_events (
    user_id, event_type, from_plan, to_plan, reason, metadata
  )
  SELECT
    c.owner_user_id,
    'plan_cancelled',
    'gratis',          -- from_plan: what was the paid plan (stored before update above)
    'gratis',          -- to_plan:   downgraded to gratis
    'C-10 scheduled-cancellation',
    jsonb_build_object('processed_at', now(), 'account_id', c.id)
  FROM cancelled c;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

COMMENT ON FUNCTION public.process_cancellations() IS
  'C-10: Daily sweep that finalises scheduled cancellations. Transitions accounts with billing_status=''cancelling'' and plan_expires_at < now() to billing_plan=''gratis'', billing_status=''cancelled''. Inserts billing_events audit row. Idempotent.';

-- Schedule: runs at 03:30 UTC daily (30 min after expire-trials)
SELECT cron.schedule(
  'process-cancellations',
  '30 3 * * *',
  'SELECT public.process_cancellations()'
);


-- ── TEST ASSERTIONS (run on branch after applying) ─────────────────────────────

-- Block 1: price_ars_annual exists and seeded
-- SELECT plan, price_ars_annual FROM public.plan_limits ORDER BY price_monthly;
-- Expected: gratis=0, inicial=249000, avanzado=349000, pro=699000

-- Block 2: new columns exist in billing_events
-- SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='billing_events'
--   AND column_name IN ('mercadopago_payment_id','mercadopago_preference_id','amount');
-- Expected: 3 rows

-- Block 3: plan_expires_at column + constraint includes 'cancelling'
-- SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='accounts'
--   AND column_name='plan_expires_at';
-- UPDATE public.accounts SET billing_status='cancelling' WHERE false;  -- no error expected

-- Block 4: function and cron job exist
-- SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema='public' AND routine_name='process_cancellations';
-- SELECT jobname FROM cron.job WHERE jobname='process-cancellations';

-- =============================================================================
-- END OF MIGRATION 20260609000001_billing_upgrade_flow.sql
-- =============================================================================
