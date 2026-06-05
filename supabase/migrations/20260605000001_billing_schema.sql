-- =============================================================================
-- MIGRATION: 20260605000001_billing_schema.sql
-- CHANGE:    C-01 billing-schema-migration
-- DESCRIPTION:
--   Additive schema for 4-tier commercial billing.
--   ALL changes are 100% additive (ADD COLUMN IF NOT EXISTS, CREATE TABLE IF
--   NOT EXISTS). No DROP, no ALTER TYPE, no destructive operations.
--   The legacy column `profiles.plan` (ENUM type `user_plan`) is NOT touched.
--
-- PRE-FLIGHT CHECKLIST (human):
--   0.2 — Create a Supabase branch before applying:
--         $ supabase branches create billing-schema-migration
--         Apply and validate there before merging to production.
--
--   0.3 — Capture baseline BEFORE running on the branch:
--         SELECT count(*) FROM profiles;
--         SELECT plan, count(*) FROM profiles GROUP BY plan;
--         (Save the numbers — used by assertions in Block 4 below.)
--
-- ROLLBACK PLAN (if needed):
--   DROP TABLE IF EXISTS public.billing_events;
--   DROP TABLE IF EXISTS public.plan_limits;
--   ALTER TABLE public.profiles
--     DROP COLUMN IF EXISTS billing_plan,
--     DROP COLUMN IF EXISTS billing_status,
--     DROP COLUMN IF EXISTS trial_plan,
--     DROP COLUMN IF EXISTS trial_started_at,
--     DROP COLUMN IF EXISTS trial_expires_at,
--     DROP COLUMN IF EXISTS billing_provider_customer_id,
--     DROP COLUMN IF EXISTS ai_queries_used,
--     DROP COLUMN IF EXISTS ai_advice_used,
--     DROP COLUMN IF EXISTS usage_reset_at;
--   DROP FUNCTION IF EXISTS public.set_new_user_trial();
-- =============================================================================


-- ============================================================
-- BLOCK 1 — Schema additions to profiles
-- ============================================================

-- 1.2 Add billing columns to profiles (all additive, IF NOT EXISTS)
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS billing_plan text NOT NULL DEFAULT 'gratis'
    CONSTRAINT profiles_billing_plan_values
    CHECK (billing_plan IN ('gratis', 'inicial', 'avanzado', 'pro')),

  ADD COLUMN IF NOT EXISTS billing_status text NOT NULL DEFAULT 'trialing'
    CONSTRAINT profiles_billing_status_values
    CHECK (billing_status IN ('active', 'trialing', 'expired', 'cancelled')),

  -- trial_plan: nullable — NULL means no active trial; populated for new users
  ADD COLUMN IF NOT EXISTS trial_plan text
    CONSTRAINT profiles_trial_plan_values
    CHECK (trial_plan IN ('gratis', 'inicial', 'avanzado', 'pro')),

  ADD COLUMN IF NOT EXISTS trial_started_at timestamptz DEFAULT now(),

  -- trial_expires_at: NULL for beta users (C-03 will set when billing activates)
  ADD COLUMN IF NOT EXISTS trial_expires_at timestamptz,

  -- External billing provider (Stripe / MercadoPago customer ID — C-10)
  ADD COLUMN IF NOT EXISTS billing_provider_customer_id text,

  -- AI usage counters (D4: split from single insights_used into two counters)
  ADD COLUMN IF NOT EXISTS ai_queries_used integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_advice_used  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS usage_reset_at  timestamptz NOT NULL DEFAULT now();

-- 1.3 Indexes for billing columns used by C-02 and C-03
CREATE INDEX IF NOT EXISTS idx_profiles_billing_plan
  ON public.profiles (billing_plan);

-- Partial index — only rows with an active trial (C-03 expiry sweep)
CREATE INDEX IF NOT EXISTS idx_profiles_trial_expires_at
  ON public.profiles (trial_expires_at)
  WHERE trial_expires_at IS NOT NULL;

-- ── TEST 1.4 (run on branch to verify — paste into SQL editor) ────────────────
-- Assertion: all 8 new columns exist with correct types
-- SELECT column_name, data_type, column_default, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name = 'profiles'
--   AND column_name IN (
--     'billing_plan','billing_status','trial_plan','trial_started_at',
--     'trial_expires_at','billing_provider_customer_id',
--     'ai_queries_used','ai_advice_used','usage_reset_at'
--   )
-- ORDER BY column_name;
-- Expected: 9 rows (billing_provider_customer_id is nullable, rest per spec)
--
-- Edge test: CHECK constraint rejects invalid value
-- UPDATE public.profiles SET billing_plan = 'enterprise' WHERE false;
-- → Expected: ERROR 23514 violates check constraint "profiles_billing_plan_values"


-- ============================================================
-- BLOCK 2 — plan_limits table (source of truth for plan limits)
-- ============================================================

-- 2.1 Create plan_limits table
CREATE TABLE IF NOT EXISTS public.plan_limits (
  plan                      text        PRIMARY KEY
    CONSTRAINT plan_limits_plan_values
    CHECK (plan IN ('gratis', 'inicial', 'avanzado', 'pro')),

  -- Pricing
  price_monthly             numeric(12,2) NOT NULL DEFAULT 0,

  -- User and data limits
  max_users                 integer     NOT NULL DEFAULT 1,
  max_products              integer     NOT NULL DEFAULT 100,
  max_clients               integer     NOT NULL DEFAULT 50,
  max_suppliers             integer     NOT NULL DEFAULT 20,
  max_operations_per_month  integer     NOT NULL DEFAULT 100,
  history_days              integer     NOT NULL DEFAULT 30,
  max_exports_per_month     integer     NOT NULL DEFAULT 0,

  -- AI limits (separate counters per D4)
  max_ai_queries_per_month  integer     NOT NULL DEFAULT 5,
  max_ai_advice_per_month   integer     NOT NULL DEFAULT 3,

  -- Multi-branch
  max_branches              integer     NOT NULL DEFAULT 1,

  -- Feature flags
  has_product_profitability boolean     NOT NULL DEFAULT false,
  has_comparative_reports   boolean     NOT NULL DEFAULT false,
  has_price_suggestion      boolean     NOT NULL DEFAULT false,
  has_branches_module       boolean     NOT NULL DEFAULT false,
  has_monthly_analysis      boolean     NOT NULL DEFAULT false,

  -- Role management level ('none' | 'basic' | 'advanced')
  internal_roles            text        NOT NULL DEFAULT 'none'
    CONSTRAINT plan_limits_internal_roles_values
    CHECK (internal_roles IN ('none', 'basic', 'advanced')),

  created_at                timestamptz NOT NULL DEFAULT now()
);

-- 2.2 Idempotent seed — 4 plans with values from design.md D2 / RN-03
-- Re-running this migration (e.g. on CI) will not duplicate rows.
INSERT INTO public.plan_limits (
  plan, price_monthly,
  max_users, max_products, max_clients, max_suppliers,
  max_operations_per_month, history_days, max_exports_per_month,
  max_ai_queries_per_month, max_ai_advice_per_month, max_branches,
  has_product_profitability, has_comparative_reports, has_price_suggestion,
  has_branches_module, has_monthly_analysis, internal_roles
) VALUES
  -- gratis: free tier
  ('gratis',   0,        1,  100,   50,   20,  100,   30,  0,   5,   3,  1, false, false, false, false, false, 'none'),
  -- inicial: entry paid tier (~$24,900 ARS/mo)
  ('inicial',  24900,    2,  500,  250,  100,  500,  365,  3,  30,  15,  1, false, false, false, false, false, 'none'),
  -- avanzado: mid tier (~$34,900 ARS/mo)
  ('avanzado', 34900,    5, 1500, 1000,  300, 2000,  730, 15, 120,  60,  1, true,  true,  true,  false, false, 'basic'),
  -- pro: top tier (~$69,900 ARS/mo)
  ('pro',      69900,   10, 5000, 3000, 1000, 6000, 1825, 50, 300, 150,  3, true,  true,  true,  true,  true,  'advanced')
ON CONFLICT (plan) DO UPDATE SET
  price_monthly             = EXCLUDED.price_monthly,
  max_users                 = EXCLUDED.max_users,
  max_products              = EXCLUDED.max_products,
  max_clients               = EXCLUDED.max_clients,
  max_suppliers             = EXCLUDED.max_suppliers,
  max_operations_per_month  = EXCLUDED.max_operations_per_month,
  history_days              = EXCLUDED.history_days,
  max_exports_per_month     = EXCLUDED.max_exports_per_month,
  max_ai_queries_per_month  = EXCLUDED.max_ai_queries_per_month,
  max_ai_advice_per_month   = EXCLUDED.max_ai_advice_per_month,
  max_branches              = EXCLUDED.max_branches,
  has_product_profitability = EXCLUDED.has_product_profitability,
  has_comparative_reports   = EXCLUDED.has_comparative_reports,
  has_price_suggestion      = EXCLUDED.has_price_suggestion,
  has_branches_module       = EXCLUDED.has_branches_module,
  has_monthly_analysis      = EXCLUDED.has_monthly_analysis,
  internal_roles            = EXCLUDED.internal_roles;

-- 2.3 RLS for plan_limits
ALTER TABLE public.plan_limits ENABLE ROW LEVEL SECURITY;

-- Public read: plan limits are public information (landing page, gating client)
DROP POLICY IF EXISTS "plan_limits_public_read" ON public.plan_limits;
CREATE POLICY "plan_limits_public_read" ON public.plan_limits
  FOR SELECT
  TO anon, authenticated
  USING (true);

-- Admin-only write (INSERT/UPDATE/DELETE)
DROP POLICY IF EXISTS "plan_limits_admin_write" ON public.plan_limits;
CREATE POLICY "plan_limits_admin_write" ON public.plan_limits
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND role = 'admin'
    )
  );

-- ── TEST 2.4 (run on branch) ──────────────────────────────────────────────────
-- Assertion: 4 rows seeded correctly
-- SELECT count(*) FROM public.plan_limits;  -- Expected: 4
-- SELECT plan, max_products FROM public.plan_limits ORDER BY price_monthly;
-- Expected:
--   gratis   | 100
--   inicial  | 500
--   avanzado | 1500
--   pro      | 5000
--
-- Idempotency: re-run the INSERT above → still 4 rows (ON CONFLICT DO UPDATE)
--
-- RLS edge: anon can SELECT (no error); authenticated non-admin cannot UPDATE:
-- UPDATE public.plan_limits SET price_monthly = 0 WHERE plan = 'pro';
-- → Expected: 0 rows affected (RLS blocks non-admin)


-- ============================================================
-- BLOCK 3 — billing_events table (immutable audit trail)
-- ============================================================

-- 3.1 Create billing_events table
CREATE TABLE IF NOT EXISTS public.billing_events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type  text        NOT NULL,   -- e.g. 'migration_backfill', 'plan_upgrade', 'trial_start'
  from_plan   text,                   -- plan before change (NULL for first event)
  to_plan     text,                   -- plan after change
  reason      text,                   -- human-readable reason / change name
  metadata    jsonb,                  -- arbitrary structured context
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 3.2 Indexes on billing_events
CREATE INDEX IF NOT EXISTS idx_billing_events_user_id
  ON public.billing_events (user_id);

CREATE INDEX IF NOT EXISTS idx_billing_events_created_at
  ON public.billing_events (created_at);

-- 3.3 RLS for billing_events
ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;

-- User can read their own events (for UI display)
DROP POLICY IF EXISTS "billing_events_user_read" ON public.billing_events;
CREATE POLICY "billing_events_user_read" ON public.billing_events
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- No INSERT/UPDATE/DELETE for regular users — only service_role (system) or admin
-- (service_role bypasses RLS entirely; admin policy below for admin UI)
DROP POLICY IF EXISTS "billing_events_admin_write" ON public.billing_events;
CREATE POLICY "billing_events_admin_write" ON public.billing_events
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND role = 'admin'
    )
  );

-- ── TEST 3.4 (run on branch) ──────────────────────────────────────────────────
-- Assertion: table and policies exist
-- SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='billing_events';
-- SELECT policyname FROM pg_policies WHERE tablename='billing_events';
--
-- Edge test: authenticated non-admin cannot INSERT:
-- INSERT INTO public.billing_events (user_id, event_type) VALUES (auth.uid(), 'test');
-- → Expected: RLS violation / 0 rows (only service_role / admin can write)


-- ============================================================
-- BLOCK 4 — Backfill existing users + new user trigger
-- ============================================================

-- 4.1 Backfill existing beta users (those with plan = 'pro')
-- All beta users → billing_plan = 'avanzado' (confirmed decision D5)
-- trial_plan = NULL (beta users are NOT in a trial — they get Avanzado directly)
-- trial_expires_at = NULL (C-03 will set expiry when billing activates)
-- ai_queries_used backfilled from insights_used (D4)
UPDATE public.profiles
SET
  billing_plan   = 'avanzado',
  billing_status = 'trialing',
  trial_plan     = NULL,
  trial_started_at  = COALESCE(created_at, now()),
  trial_expires_at  = NULL,
  ai_queries_used   = COALESCE(insights_used, 0),
  usage_reset_at    = COALESCE(insights_reset_at, now())
WHERE plan = 'pro';

-- 4.2 Insert billing_events audit record for each backfilled user
INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
SELECT
  id,
  'migration_backfill',
  'pro',       -- from_plan: the legacy plan value
  'avanzado',  -- to_plan:   the new billing_plan assigned
  'C-01 billing-schema-migration backfill',
  jsonb_build_object(
    'migration',        '20260605000001_billing_schema',
    'legacy_plan',      plan::text,
    'ai_queries_backfilled', COALESCE(insights_used, 0)
  )
FROM public.profiles
WHERE plan = 'pro';

-- ── TEST 4.3 (run on branch — compare against baseline captured in 0.3) ───────
-- No-regression: total row count matches baseline
-- SELECT count(*) FROM public.profiles;  -- Must equal baseline count
--
-- Zero billing_plan NULLs (DEFAULT handles new rows; backfill covers existing)
-- SELECT count(*) FROM public.profiles WHERE billing_plan IS NULL;  -- Expected: 0
--
-- Beta users correctly set to avanzado
-- SELECT billing_plan, count(*) FROM public.profiles WHERE plan = 'pro' GROUP BY billing_plan;
-- Expected: avanzado | <baseline pro count>
--
-- AI usage backfill correct
-- SELECT count(*) FROM public.profiles WHERE ai_queries_used != COALESCE(insights_used, 0);
-- Expected: 0
--
-- Edge: user without created_at → trial_started_at = now() (no error due to COALESCE)

-- ── Trigger for new users (post-migration) ────────────────────────────────────
-- New users get: billing_plan='gratis' (from column DEFAULT),
--               trial_plan='avanzado', trial_expires_at=NOW()+30d
-- This trigger fires AFTER INSERT, so it sees the new row and updates it.

CREATE OR REPLACE FUNCTION public.set_new_user_trial()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles
  SET
    trial_plan       = 'avanzado',
    trial_started_at = now(),
    trial_expires_at = now() + INTERVAL '30 days',
    billing_status   = 'trialing'
  WHERE id = NEW.id;
  RETURN NULL;  -- AFTER trigger: return value ignored
END;
$$;

DROP TRIGGER IF EXISTS trg_new_user_trial ON public.profiles;
CREATE TRIGGER trg_new_user_trial
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_new_user_trial();


-- ============================================================
-- BLOCK 5 — Post-apply checklist (human actions required)
-- ============================================================

-- 5.1 Run advisors on the branch after applying:
--     $ supabase db advisors
--     Resolve any new security or performance warnings introduced by this migration.
--
-- 5.2 Regenerate TypeScript types after applying:
--     $ supabase gen types typescript --project-id <ref> > lib/database.types.ts
--     OR with local dev:
--     $ supabase db pull && supabase gen types typescript --local > lib/database.types.ts
--     Confirm that billing_plan, trial_plan, billing_events, and plan_limits
--     appear in the generated types file.

-- =============================================================================
-- END OF MIGRATION 20260605000001_billing_schema.sql
-- =============================================================================
