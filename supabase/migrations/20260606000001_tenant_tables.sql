-- =============================================================================
-- MIGRATION: 20260606000001_tenant_tables.sql
-- CHANGE:    C-05 multi-user-tenant-architecture
-- BLOCK:     A — Tablas de tenant (aditivo, no toca RLS existente)
--
-- DESCRIPTION:
--   Creates the three new tenant tables (accounts, account_members,
--   account_invitations), the helper function current_account_ids(), indexes,
--   and RLS for the new tables only.
--
--   This block is 100% ADDITIVE — it does NOT touch any existing table,
--   column, index, or policy. Existing RLS continues to work unchanged.
--
-- GOVERNANCE: CRÍTICO — awaiting human gate before applying (Gate 1.7).
--
-- PRE-APPLY CHECKLIST (human):
--   1. Review this file completely.
--   2. Confirm no existing table named accounts/account_members/account_invitations.
--   3. Apply on branch first if possible; then prod.
--
-- ROLLBACK PLAN (if needed):
--   DROP TABLE IF EXISTS public.account_invitations;
--   DROP TABLE IF EXISTS public.account_members;
--   DROP TABLE IF EXISTS public.accounts;
--   DROP FUNCTION IF EXISTS public.current_account_ids();
-- =============================================================================


-- ============================================================
-- TASK 1.1 — Table: accounts
-- ============================================================

CREATE TABLE IF NOT EXISTS public.accounts (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Billing fields — mirror of profiles billing columns (D4/D5)
  billing_plan   text        NOT NULL DEFAULT 'gratis'
    CONSTRAINT accounts_billing_plan_values
    CHECK (billing_plan IN ('gratis', 'inicial', 'avanzado', 'pro')),

  billing_status text        NOT NULL DEFAULT 'trialing'
    CONSTRAINT accounts_billing_status_values
    CHECK (billing_status IN ('active', 'trialing', 'expired', 'cancelled')),

  trial_plan     text
    CONSTRAINT accounts_trial_plan_values
    CHECK (trial_plan IN ('gratis', 'inicial', 'avanzado', 'pro')),

  trial_started_at  timestamptz DEFAULT now(),
  trial_expires_at  timestamptz,

  -- The auth.users id of the user who owns/created this account
  owner_user_id  uuid        NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,

  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Index to find accounts owned by a user quickly
CREATE INDEX IF NOT EXISTS idx_accounts_owner_user_id
  ON public.accounts (owner_user_id);


-- ============================================================
-- TASK 1.2 — Table: account_members
-- ============================================================

CREATE TABLE IF NOT EXISTS public.account_members (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role       text        NOT NULL DEFAULT 'member'
    CONSTRAINT account_members_role_values
    CHECK (role IN ('owner', 'member')),
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (account_id, user_id)
);


-- ============================================================
-- TASK 1.3 — Table: account_invitations
-- ============================================================

CREATE TABLE IF NOT EXISTS public.account_invitations (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  email       text        NOT NULL,
  token       text        NOT NULL UNIQUE,
  status      text        NOT NULL DEFAULT 'pending'
    CONSTRAINT account_invitations_status_values
    CHECK (status IN ('pending', 'accepted', 'expired')),
  invited_by  uuid        NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT (now() + INTERVAL '7 days')
);


-- ============================================================
-- TASK 1.4 — Helper function: current_account_ids()
--
-- D3: STABLE so the planner can cache it per query (avoids initplan churn).
--     SECURITY DEFINER with fixed search_path so it can read account_members
--     even when the caller cannot (avoids RLS recursion on account_members).
--     The account_members policy MUST use user_id = (SELECT auth.uid()) DIRECTLY —
--     never call current_account_ids() from account_members policies.
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_account_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT account_id
  FROM   public.account_members
  WHERE  user_id = (SELECT auth.uid())
$$;

REVOKE ALL     ON FUNCTION public.current_account_ids() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.current_account_ids() TO authenticated;


-- ============================================================
-- TASK 1.5 — Indexes for account_members and account_invitations
-- ============================================================

-- account_members: fast lookup of all accounts a user belongs to
CREATE INDEX IF NOT EXISTS idx_account_members_user_id
  ON public.account_members (user_id);

-- account_members: fast lookup of all members of an account
CREATE INDEX IF NOT EXISTS idx_account_members_account_id
  ON public.account_members (account_id);

-- account_invitations: token lookup (unique, but explicit index for clarity)
CREATE INDEX IF NOT EXISTS idx_account_invitations_token
  ON public.account_invitations (token);

-- account_invitations: list invitations by account
CREATE INDEX IF NOT EXISTS idx_account_invitations_account_id
  ON public.account_invitations (account_id);


-- ============================================================
-- TASK 1.6 — RLS for the three new tables
-- ============================================================

-- ── Enable RLS ────────────────────────────────────────────────────────────────
ALTER TABLE public.accounts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_members    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_invitations ENABLE ROW LEVEL SECURITY;


-- ── accounts policies ─────────────────────────────────────────────────────────
-- Members of the account can read it.
-- The check uses current_account_ids() which reads account_members directly
-- (no recursion risk — accounts -> account_members is one level, not circular).

DROP POLICY IF EXISTS "accounts_member_select" ON public.accounts;
CREATE POLICY "accounts_member_select" ON public.accounts
  FOR SELECT
  TO authenticated
  USING (id IN (SELECT current_account_ids()));

-- Only the owner can update their account's billing fields.
DROP POLICY IF EXISTS "accounts_owner_update" ON public.accounts;
CREATE POLICY "accounts_owner_update" ON public.accounts
  FOR UPDATE
  TO authenticated
  USING  (owner_user_id = (SELECT auth.uid()))
  WITH CHECK (owner_user_id = (SELECT auth.uid()));

-- Accounts are created programmatically (backfill + invitation acceptance RPCs).
-- Direct INSERT from client is blocked; service_role bypasses RLS.
-- (No INSERT policy for authenticated — insertions go via SECURITY DEFINER RPCs.)


-- ── account_members policies ──────────────────────────────────────────────────
-- CRITICAL: MUST use user_id = (SELECT auth.uid()) DIRECTLY.
-- DO NOT use current_account_ids() here — that would cause infinite recursion
-- because current_account_ids() reads account_members.

-- A user can see their OWN membership rows.
DROP POLICY IF EXISTS "account_members_self_select" ON public.account_members;
CREATE POLICY "account_members_self_select" ON public.account_members
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- Members of the same account can see other members
-- (needed for team management UI — uses the accounts join, not current_account_ids).
DROP POLICY IF EXISTS "account_members_same_account_select" ON public.account_members;
CREATE POLICY "account_members_same_account_select" ON public.account_members
  FOR SELECT
  TO authenticated
  USING (
    account_id IN (
      SELECT am2.account_id
      FROM   public.account_members am2
      WHERE  am2.user_id = (SELECT auth.uid())
    )
  );

-- No direct INSERT/UPDATE/DELETE for account_members from clients.
-- Membership changes go via SECURITY DEFINER RPCs (rpc_accept_invitation,
-- rpc_invite_member) to enforce max_users limits.


-- ── account_invitations policies ─────────────────────────────────────────────
-- Owner of the account can manage invitations (create, view, expire).
DROP POLICY IF EXISTS "account_invitations_owner_all" ON public.account_invitations;
CREATE POLICY "account_invitations_owner_all" ON public.account_invitations
  FOR ALL
  TO authenticated
  USING (
    account_id IN (
      SELECT id FROM public.accounts
      WHERE  owner_user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    account_id IN (
      SELECT id FROM public.accounts
      WHERE  owner_user_id = (SELECT auth.uid())
    )
  );

-- Invitee reads their invitation via rpc_accept_invitation(token) SECURITY DEFINER (task 7.1).
-- No direct SELECT for anon/authenticated — avoids token enumeration across all rows.
-- (Owner reads through account_invitations_owner_all policy above.)


-- =============================================================================
-- TEST ASSERTIONS (run AFTER applying — paste in SQL editor)
-- =============================================================================

-- TEST 1.7a: All three tables exist
-- SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--     AND table_name IN ('accounts','account_members','account_invitations')
--   ORDER BY table_name;
-- Expected: 3 rows

-- TEST 1.7b: current_account_ids() exists and is STABLE SECURITY DEFINER
-- SELECT proname, prosecdef, provolatile
--   FROM pg_proc WHERE proname = 'current_account_ids';
-- Expected: current_account_ids | t (security definer) | s (stable)

-- TEST 1.7c: account_members policy is NOT recursive (direct user_id check)
-- SELECT policyname, qual FROM pg_policies
--   WHERE tablename = 'account_members'
--   ORDER BY policyname;
-- Expected: policies reference user_id directly, NOT current_account_ids()

-- TEST 1.7d: Indexes exist
-- SELECT indexname FROM pg_indexes
--   WHERE schemaname='public'
--     AND tablename IN ('account_members','account_invitations','accounts')
--   ORDER BY indexname;
-- Expected: idx_account_members_user_id, idx_account_members_account_id,
--           idx_account_invitations_token, idx_account_invitations_account_id,
--           idx_accounts_owner_user_id

-- =============================================================================
-- END OF MIGRATION 20260606000001_tenant_tables.sql
-- =============================================================================
