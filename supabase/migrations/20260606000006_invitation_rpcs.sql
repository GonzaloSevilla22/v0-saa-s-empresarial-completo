-- =============================================================================
-- MIGRATION: 20260606000006_invitation_rpcs.sql
-- CHANGE:    C-05 multi-user-tenant-architecture
-- BLOCK:     G — Invitaciones (Tasks 7.1 + 7.2)
--
-- DESCRIPTION:
--   Two SECURITY DEFINER RPCs for member invitation flow:
--     • rpc_invite_member(p_email, p_account_id)   — owner only, creates token
--     • rpc_accept_invitation(p_token)              — invitee accepts, joins account
--
--   Both enforce max_users from plan_limits. Neither can be called from the
--   client with elevated trust — SECURITY DEFINER runs as the function owner.
--
-- GOVERNANCE: CRÍTICO — human-approved (Bloque G).
-- NEVER use MCP apply_migration — always `npx supabase db push`.
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.rpc_invite_member(text, uuid);
--   DROP FUNCTION IF EXISTS public.rpc_accept_invitation(text);
-- =============================================================================


-- =============================================================================
-- TASK 7.2 — RPC: rpc_invite_member(p_email text, p_account_id uuid)
--
-- Only the account owner can invite. Validates:
--   1. Caller is the owner of the given account.
--   2. Current member count < plan_limits.max_users.
--   3. No existing pending invitation for this email on this account.
--
-- On success: inserts account_invitations row with a random token (expires in 7d)
--             and returns the invitation id + token.
--
-- Errors (SQLSTATE P0001 = raise_exception):
--   P401 — not the account owner
--   P403 — member quota reached for this plan
--   P409 — pending invitation already exists for this email
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_invite_member(
  p_email      text,
  p_account_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  uuid;
  v_plan       text;
  v_max_users  int;
  v_cur_users  int;
  v_inv_id     uuid;
  v_token      text;
BEGIN
  -- 1. Identify the caller
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Confirm caller is owner of this account
  IF NOT EXISTS (
    SELECT 1
    FROM   public.account_members
    WHERE  account_id = p_account_id
      AND  user_id    = v_caller_id
      AND  role       = 'owner'
  ) THEN
    RAISE EXCEPTION 'P401: caller is not the owner of account %', p_account_id
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. Get plan + max_users for this account
  SELECT a.billing_plan
  INTO   v_plan
  FROM   public.accounts a
  WHERE  a.id = p_account_id;

  SELECT pl.max_users
  INTO   v_max_users
  FROM   public.plan_limits pl
  WHERE  pl.plan = v_plan;

  IF v_max_users IS NULL THEN
    v_max_users := 1; -- safe fallback for gratis
  END IF;

  -- 4. Count current active members
  SELECT COUNT(*)
  INTO   v_cur_users
  FROM   public.account_members
  WHERE  account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0001';
  END IF;

  -- 5. Check for an existing pending invitation for this email
  IF EXISTS (
    SELECT 1
    FROM   public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
      USING ERRCODE = 'P0001';
  END IF;

  -- 6. Generate a secure random token (64 hex chars = 32 bytes entropy)
  v_token  := encode(gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  -- 7. Insert the invitation
  INSERT INTO public.account_invitations
    (id, account_id, email, token, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_invite_member(text, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_invite_member(text, uuid) TO authenticated;


-- =============================================================================
-- TASK 7.1 — RPC: rpc_accept_invitation(p_token text)
--
-- Called by the invitee after clicking the invitation link. Validates:
--   1. Token exists and is pending and not expired.
--   2. Caller's auth.uid() is a valid user.
--   3. Current member count < plan_limits.max_users (re-check at accept time).
--
-- On success: inserts account_members row (role='member'), marks invitation
--             'accepted', returns the new account_member id.
--
-- Errors (SQLSTATE P0001 = raise_exception):
--   P404 — invalid or expired token
--   P403 — member quota reached (account filled up since invite was sent)
--   P409 — caller already a member of this account
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_accept_invitation(
  p_token text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  uuid;
  v_inv        record;
  v_plan       text;
  v_max_users  int;
  v_cur_users  int;
  v_member_id  uuid;
BEGIN
  -- 1. Identify the caller
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Fetch the invitation by token (pending + not expired)
  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. Check caller is not already a member of this account
  IF EXISTS (
    SELECT 1
    FROM   public.account_members
    WHERE  account_id = v_inv.account_id
      AND  user_id    = v_caller_id
  ) THEN
    RAISE EXCEPTION 'P409: caller is already a member of account %', v_inv.account_id
      USING ERRCODE = 'P0001';
  END IF;

  -- 4. Re-validate max_users quota at accept time
  SELECT a.billing_plan
  INTO   v_plan
  FROM   public.accounts a
  WHERE  a.id = v_inv.account_id;

  SELECT pl.max_users
  INTO   v_max_users
  FROM   public.plan_limits pl
  WHERE  pl.plan = v_plan;

  IF v_max_users IS NULL THEN
    v_max_users := 1;
  END IF;

  SELECT COUNT(*)
  INTO   v_cur_users
  FROM   public.account_members
  WHERE  account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0001';
  END IF;

  -- 5. Add the caller as a member
  v_member_id := gen_random_uuid();

  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, 'member', now());

  -- 6. Mark the invitation accepted
  UPDATE public.account_invitations
  SET    status = 'accepted'
  WHERE  id = v_inv.id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'role',              'member'
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_accept_invitation(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_accept_invitation(text) TO authenticated;


-- =============================================================================
-- TEST ASSERTIONS (run AFTER applying)
--
-- TEST 7.4a: Both RPCs exist and are SECURITY DEFINER
-- SELECT proname, prosecdef FROM pg_proc
--   WHERE proname IN ('rpc_accept_invitation', 'rpc_invite_member')
--   ORDER BY proname;
-- Expected:
--   rpc_accept_invitation | t
--   rpc_invite_member     | t
-- =============================================================================
-- END OF MIGRATION 20260606000006_invitation_rpcs.sql
-- =============================================================================
