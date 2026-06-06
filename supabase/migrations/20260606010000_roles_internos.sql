-- =============================================================================
-- MIGRATION: 20260606010000_roles_internos.sql
-- CHANGE:    C-06 roles-internos-basicos
--
-- DESCRIPTION:
--   Introduces the 'admin' role into account_members, adds write-permission
--   gating to business tables (sales/purchases/expenses/products/clients),
--   and creates RPCs for role management (change role, remove member, get
--   caller's role). Also extends rpc_invite_member/rpc_accept_invitation to
--   support role-specific invitations.
--
-- GOVERNANCE: ALTO — touches RLS on all business tables.
--   All 26 beta users are 'owner', so zero visible impact during beta.
--
-- APPLY: npx supabase db push  (NEVER use MCP apply_migration)
--
-- ROLLBACK:
--   DROP POLICY IF EXISTS "sales_writer_insert" ON public.sales;
--   -- (repeat for all writer policies below)
--   DROP FUNCTION IF EXISTS public.is_account_writer(uuid);
--   DROP FUNCTION IF EXISTS public.rpc_change_member_role(uuid, uuid, text);
--   DROP FUNCTION IF EXISTS public.rpc_remove_member(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.rpc_my_account_role(uuid);
--   ALTER TABLE public.account_members
--     DROP CONSTRAINT account_members_role_values;
--   ALTER TABLE public.account_members
--     ADD CONSTRAINT account_members_role_values CHECK (role IN ('owner', 'member'));
--   ALTER TABLE public.account_invitations DROP COLUMN IF EXISTS role;
-- =============================================================================


-- ============================================================
-- TASK 1.1 — Ampliar constraint de roles en account_members
-- ============================================================
ALTER TABLE public.account_members
  DROP CONSTRAINT IF EXISTS account_members_role_values;

ALTER TABLE public.account_members
  ADD CONSTRAINT account_members_role_values
  CHECK (role IN ('owner', 'admin', 'member'));


-- ============================================================
-- TASK 1.2 — Helper: is_account_writer(p_account_id uuid)
--
-- Returns TRUE if the current user has role 'owner' or 'admin'
-- in account_members for the given account. Used by all writer
-- RLS policies below.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_account_writer(p_account_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   public.account_members
    WHERE  account_id = p_account_id
      AND  user_id    = (SELECT auth.uid())
      AND  role       IN ('owner', 'admin')
  );
$$;

REVOKE ALL     ON FUNCTION public.is_account_writer(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.is_account_writer(uuid) TO authenticated;


-- ============================================================
-- TASK 2.1 — RPC: rpc_change_member_role
--
-- Changes the role of a member in an account.
-- Validation order (returns jsonb {ok:true} or {error:string}):
--   1. Caller must be owner or admin in the account.
--   2. Admin can only change role of 'member' → 'member' (no-op for others).
--   3. new_role='admin' requires account.billing_plan='pro'.
--   4. Target is the sole owner → cannot be degraded.
--   5. Apply UPDATE.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_change_member_role(
  p_account_id     uuid,
  p_target_user_id uuid,
  p_new_role       text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_target_role text;
  v_plan        text;
  v_owner_count int;
BEGIN
  v_caller_id := (SELECT auth.uid());

  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  -- 1. Caller must be owner or admin
  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos');
  END IF;

  SELECT role INTO v_target_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  -- 2. Admin can only operate on 'member' targets and only set 'member'
  IF v_caller_role = 'admin' AND (v_target_role != 'member' OR p_new_role != 'member') THEN
    RETURN jsonb_build_object('error', 'Sin permisos para cambiar este rol');
  END IF;

  -- 3. new_role='admin' requires plan 'pro'
  IF p_new_role = 'admin' THEN
    SELECT billing_plan INTO v_plan FROM public.accounts WHERE id = p_account_id;
    IF v_plan != 'pro' THEN
      RETURN jsonb_build_object('error', 'El rol admin requiere plan pro');
    END IF;
  END IF;

  -- 4. Cannot degrade the sole owner
  IF v_target_role = 'owner' AND p_new_role != 'owner' THEN
    SELECT COUNT(*) INTO v_owner_count
    FROM   public.account_members
    WHERE  account_id = p_account_id AND role = 'owner';

    IF v_owner_count <= 1 THEN
      RETURN jsonb_build_object('error', 'No se puede degradar al único owner');
    END IF;
  END IF;

  -- 5. Apply
  UPDATE public.account_members
  SET    role = p_new_role
  WHERE  account_id = p_account_id
    AND  user_id    = p_target_user_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_change_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_change_member_role(uuid, uuid, text) TO authenticated;


-- ============================================================
-- TASK 2.2 — RPC: rpc_remove_member
--
-- Removes a member from an account.
-- Validation order:
--   1. Caller must be owner or admin.
--   2. Owner cannot be expelled.
--   3. Admin cannot expel another owner or admin.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_remove_member(
  p_account_id     uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_target_role text;
BEGIN
  v_caller_id := (SELECT auth.uid());

  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  -- 1. Caller must be owner or admin
  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos');
  END IF;

  SELECT role INTO v_target_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = p_target_user_id;

  -- 2. Cannot expel the owner
  IF v_target_role = 'owner' THEN
    RETURN jsonb_build_object('error', 'No se puede expulsar al owner');
  END IF;

  -- 3. Admin cannot expel another admin (or owner, already covered above)
  IF v_caller_role = 'admin' AND v_target_role IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('error', 'Sin permisos para expulsar este miembro');
  END IF;

  DELETE FROM public.account_members
  WHERE  account_id = p_account_id
    AND  user_id    = p_target_user_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_remove_member(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_remove_member(uuid, uuid) TO authenticated;


-- ============================================================
-- TASK 2.3 — RPC: rpc_my_account_role
--
-- Returns the role of the current user in the given account,
-- or NULL if not a member.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_my_account_role(p_account_id uuid)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT role
  FROM   public.account_members
  WHERE  account_id = p_account_id
    AND  user_id    = (SELECT auth.uid());
$$;

REVOKE ALL     ON FUNCTION public.rpc_my_account_role(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_my_account_role(uuid) TO authenticated;


-- ============================================================
-- TASK 2.4 — Ampliar invitaciones con soporte de rol
--
-- a) Add 'role' column to account_invitations (default 'member').
-- b) Replace rpc_invite_member: add p_role param; allow admin to
--    invite but only with role='member'; guard admin role behind
--    plan='pro'.
-- c) Replace rpc_accept_invitation: use stored role from invitation.
-- ============================================================

-- a) Add role column
ALTER TABLE public.account_invitations
  ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'member'
    CONSTRAINT account_invitations_role_values
    CHECK (role IN ('owner', 'admin', 'member'));

-- b) Updated rpc_invite_member (adds p_role param, allows admin callers)
CREATE OR REPLACE FUNCTION public.rpc_invite_member(
  p_email      text,
  p_account_id uuid,
  p_role       text DEFAULT 'member'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_plan        text;
  v_max_users   int;
  v_cur_users   int;
  v_inv_id      uuid;
  v_token       text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- Caller must be owner or admin
  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'P401: caller is not owner or admin of account %', p_account_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Admin can only invite with role='member'
  IF v_caller_role = 'admin' AND p_role != 'member' THEN
    RAISE EXCEPTION 'Solo el owner puede invitar admins'
      USING ERRCODE = 'P0001';
  END IF;

  -- role='admin' requires plan='pro'
  IF p_role = 'admin' THEN
    SELECT billing_plan INTO v_plan FROM public.accounts WHERE id = p_account_id;
    IF v_plan != 'pro' THEN
      RAISE EXCEPTION 'El rol admin requiere plan pro' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- Quota check
  IF v_plan IS NULL THEN
    SELECT billing_plan INTO v_plan FROM public.accounts WHERE id = p_account_id;
  END IF;

  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0001';
  END IF;

  -- Duplicate pending invitation check
  IF EXISTS (
    SELECT 1 FROM public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
      USING ERRCODE = 'P0001';
  END IF;

  v_token  := encode(gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  INSERT INTO public.account_invitations
    (id, account_id, email, token, role, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     p_role, 'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'role',       p_role,
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_invite_member(text, uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_invite_member(text, uuid, text) TO authenticated;

-- c) Updated rpc_accept_invitation: uses role from invitation row
CREATE OR REPLACE FUNCTION public.rpc_accept_invitation(p_token text)
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
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

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

  IF EXISTS (
    SELECT 1 FROM public.account_members
    WHERE  account_id = v_inv.account_id AND user_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'P409: caller is already a member of account %', v_inv.account_id
      USING ERRCODE = 'P0001';
  END IF;

  SELECT a.billing_plan INTO v_plan FROM public.accounts a WHERE a.id = v_inv.account_id;
  SELECT pl.max_users   INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0001';
  END IF;

  v_member_id := gen_random_uuid();

  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, COALESCE(v_inv.role, 'member'), now());

  UPDATE public.account_invitations SET status = 'accepted' WHERE id = v_inv.id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'role',              COALESCE(v_inv.role, 'member')
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_accept_invitation(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_accept_invitation(text) TO authenticated;


-- ============================================================
-- TASKS 3.1 + 3.2 — RLS escritura en sales, purchases, expenses
--
-- Drop the open C-05 INSERT/UPDATE/DELETE policies and replace
-- them with writer-gated ones (is_account_writer). SELECT
-- policies are intentionally left unchanged — members can read.
-- ============================================================

-- TABLA: sales
DROP POLICY IF EXISTS "sales_account_insert" ON public.sales;
DROP POLICY IF EXISTS "sales_account_update" ON public.sales;
DROP POLICY IF EXISTS "sales_account_delete" ON public.sales;

CREATE POLICY "sales_writer_insert" ON public.sales
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "sales_writer_update" ON public.sales
  FOR UPDATE TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "sales_writer_delete" ON public.sales
  FOR DELETE TO authenticated
  USING (is_account_writer(account_id));

-- TABLA: purchases
DROP POLICY IF EXISTS "purchases_account_insert" ON public.purchases;
DROP POLICY IF EXISTS "purchases_account_update" ON public.purchases;
DROP POLICY IF EXISTS "purchases_account_delete" ON public.purchases;

CREATE POLICY "purchases_writer_insert" ON public.purchases
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "purchases_writer_update" ON public.purchases
  FOR UPDATE TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "purchases_writer_delete" ON public.purchases
  FOR DELETE TO authenticated
  USING (is_account_writer(account_id));

-- TABLA: expenses
DROP POLICY IF EXISTS "expenses_account_insert" ON public.expenses;
DROP POLICY IF EXISTS "expenses_account_update" ON public.expenses;
DROP POLICY IF EXISTS "expenses_account_delete" ON public.expenses;

CREATE POLICY "expenses_writer_insert" ON public.expenses
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "expenses_writer_update" ON public.expenses
  FOR UPDATE TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "expenses_writer_delete" ON public.expenses
  FOR DELETE TO authenticated
  USING (is_account_writer(account_id));


-- ============================================================
-- TASK 3.3 — RLS escritura en products, clients
--
-- NOTE: 'suppliers' table uses company_id (not account_id) and
-- was not migrated to the account model in C-05. Writer-gated
-- RLS for suppliers is deferred until that migration occurs.
-- ============================================================

-- TABLA: products
DROP POLICY IF EXISTS "products_account_insert" ON public.products;
DROP POLICY IF EXISTS "products_account_update" ON public.products;
DROP POLICY IF EXISTS "products_account_delete" ON public.products;

CREATE POLICY "products_writer_insert" ON public.products
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "products_writer_update" ON public.products
  FOR UPDATE TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "products_writer_delete" ON public.products
  FOR DELETE TO authenticated
  USING (is_account_writer(account_id));

-- TABLA: clients
DROP POLICY IF EXISTS "clients_account_insert" ON public.clients;
DROP POLICY IF EXISTS "clients_account_update" ON public.clients;
DROP POLICY IF EXISTS "clients_account_delete" ON public.clients;

CREATE POLICY "clients_writer_insert" ON public.clients
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "clients_writer_update" ON public.clients
  FOR UPDATE TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY "clients_writer_delete" ON public.clients
  FOR DELETE TO authenticated
  USING (is_account_writer(account_id));


-- =============================================================================
-- TEST ASSERTIONS (run AFTER applying)
--
-- TEST 1.3: is_account_writer exists and is SECURITY DEFINER
--   SELECT proname, prosecdef FROM pg_proc WHERE proname = 'is_account_writer';
--   Expected: is_account_writer | t
--
-- TEST 3.4: all writer policies exist
--   SELECT policyname, cmd FROM pg_policies
--   WHERE policyname LIKE '%_writer_%' ORDER BY tablename, cmd;
--
-- TEST 0.1 (re-run): baseline unchanged
--   SELECT role, count(*) FROM account_members GROUP BY 1;
--   Expected: owner | 26
-- =============================================================================
-- END OF MIGRATION 20260606010000_roles_internos.sql
-- =============================================================================
