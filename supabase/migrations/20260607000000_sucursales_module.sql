-- =============================================================================
-- MIGRATION: 20260607000000_sucursales_module.sql
-- CHANGE:    C-07 sucursales-module-pro
--
-- DESCRIPTION:
--   Implements the Branches (Sucursales) module, exclusively for the 'pro' plan.
--   - Creates the `branches` table scoped by account_id.
--   - Adds nullable `branch_id` FK to sales, purchases, expenses, stock_movements.
--   - Creates supporting indexes for branch-filtered queries.
--   - Enables RLS on branches: SELECT for account members, writes only for owner/admin.
--   - Creates RPCs: rpc_create_branch, rpc_deactivate_branch, rpc_branch_report.
--
-- GOVERNANCE: MEDIO — new table + ADD COLUMN NULLABLE (retrocompatible). No data loss.
--   All existing rows keep branch_id = NULL (represents "main / no specific branch").
--
-- APPLY: npx supabase db push  (NEVER use MCP apply_migration)
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.rpc_branch_report(uuid, date, date);
--   DROP FUNCTION IF EXISTS public.rpc_deactivate_branch(uuid);
--   DROP FUNCTION IF EXISTS public.rpc_create_branch(uuid, text, text);
--   ALTER TABLE public.stock_movements DROP COLUMN IF EXISTS branch_id;
--   ALTER TABLE public.expenses        DROP COLUMN IF EXISTS branch_id;
--   ALTER TABLE public.purchases       DROP COLUMN IF EXISTS branch_id;
--   ALTER TABLE public.sales           DROP COLUMN IF EXISTS branch_id;
--   DROP TABLE IF EXISTS public.branches;
-- =============================================================================


-- ============================================================
-- TASK 1.1 — Create branches table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.branches (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID        NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  address     TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT branches_account_name_unique UNIQUE (account_id, name)
);

COMMENT ON TABLE public.branches IS
  'Physical locations / points of sale for an account. Exclusive to plan pro.';
COMMENT ON COLUMN public.branches.is_active IS
  'Soft-delete: FALSE hides branch from selectors but preserves historical records.';


-- ============================================================
-- TASK 1.2-1.5 — Add branch_id FK to transaction tables
-- NULL = "no specific branch / main location" (retrocompatible)
-- ============================================================
ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL;

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL;

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL;


-- ============================================================
-- TASK 1.6 — Indexes for branch-filtered queries
-- ============================================================
CREATE INDEX IF NOT EXISTS branches_account_id_idx
  ON public.branches (account_id);

CREATE INDEX IF NOT EXISTS sales_account_branch_idx
  ON public.sales (account_id, branch_id);

CREATE INDEX IF NOT EXISTS purchases_account_branch_idx
  ON public.purchases (account_id, branch_id);

CREATE INDEX IF NOT EXISTS expenses_account_branch_idx
  ON public.expenses (account_id, branch_id);

CREATE INDEX IF NOT EXISTS stock_movements_account_branch_idx
  ON public.stock_movements (account_id, branch_id);


-- ============================================================
-- TASK 1.8 — RLS on branches
-- ============================================================
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

-- SELECT: any member of the account can read its branches
DROP POLICY IF EXISTS "branches_member_select" ON public.branches;
CREATE POLICY "branches_member_select" ON public.branches
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- INSERT/UPDATE/DELETE: only owner or admin (writer role)
DROP POLICY IF EXISTS "branches_writer_insert" ON public.branches;
CREATE POLICY "branches_writer_insert" ON public.branches
  FOR INSERT
  TO authenticated
  WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "branches_writer_update" ON public.branches;
CREATE POLICY "branches_writer_update" ON public.branches
  FOR UPDATE
  TO authenticated
  USING     (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));

DROP POLICY IF EXISTS "branches_writer_delete" ON public.branches;
CREATE POLICY "branches_writer_delete" ON public.branches
  FOR DELETE
  TO authenticated
  USING (is_account_writer(account_id));


-- ============================================================
-- TASK 1.9 — rpc_create_branch
--
-- Creates a branch for the caller's account.
-- Guards:
--   - Caller must be a member of p_account_id (unauthorized)
--   - Account plan must have has_branches_module = true (branch_limit_exceeded)
--   - Active branches must be < max_branches (branch_limit_exceeded)
--   - Name must be unique in the account (branch_name_duplicate)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_branch(
  p_account_id  UUID,
  p_name        TEXT,
  p_address     TEXT DEFAULT NULL
)
RETURNS public.branches
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan            TEXT;
  v_max_branches    INTEGER;
  v_has_module      BOOLEAN;
  v_active_count    INTEGER;
  v_new_branch      public.branches;
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Verify caller is writer (owner or admin)
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can create branches'
      USING ERRCODE = 'P0401';
  END IF;

  -- Get plan limits
  SELECT
    pl.max_branches,
    pl.has_branches_module
  INTO v_max_branches, v_has_module
  FROM public.accounts a
  JOIN public.plan_limits pl ON pl.plan = a.billing_plan
  WHERE a.id = p_account_id;

  IF NOT FOUND OR NOT v_has_module THEN
    RAISE EXCEPTION 'branch_limit_exceeded: branches module requires pro plan'
      USING ERRCODE = 'P0403';
  END IF;

  -- Count active branches
  SELECT COUNT(*) INTO v_active_count
  FROM public.branches
  WHERE account_id = p_account_id
    AND is_active  = TRUE;

  IF v_active_count >= v_max_branches THEN
    RAISE EXCEPTION 'branch_limit_exceeded: plan allows % branches, account has %',
      v_max_branches, v_active_count
      USING ERRCODE = 'P0403';
  END IF;

  -- Insert (UNIQUE constraint handles duplicate names)
  BEGIN
    INSERT INTO public.branches (account_id, name, address)
    VALUES (p_account_id, p_name, p_address)
    RETURNING * INTO v_new_branch;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'branch_name_duplicate: a branch named % already exists in this account', p_name
        USING ERRCODE = 'P0409';
  END;

  RETURN v_new_branch;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_branch(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_create_branch(uuid, text, text) TO authenticated;


-- ============================================================
-- TASK 1.10 — rpc_deactivate_branch
--
-- Soft-deletes a branch (is_active = FALSE).
-- Guards:
--   - Caller must be owner or admin of the branch's account
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_deactivate_branch(
  p_branch_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  SELECT account_id INTO v_account_id
  FROM public.branches
  WHERE id = p_branch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found'
      USING ERRCODE = 'P0404';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can deactivate branches'
      USING ERRCODE = 'P0401';
  END IF;

  UPDATE public.branches
  SET is_active = FALSE
  WHERE id = p_branch_id;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_deactivate_branch(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_deactivate_branch(uuid) TO authenticated;


-- ============================================================
-- TASK 6.1 — rpc_branch_report
--
-- Aggregates sales, expenses and operation count per branch
-- for the caller's account in the given date range.
-- Includes a "Sin sucursal" row for branch_id = NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_branch_report(
  p_account_id  UUID,
  p_start       DATE,
  p_end         DATE
)
RETURNS TABLE (
  branch_id     UUID,
  branch_name   TEXT,
  total_sales   NUMERIC,
  total_expenses NUMERIC,
  operation_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    branch_sales AS (
      SELECT
        s.branch_id,
        COALESCE(SUM(s.amount), 0)   AS total_sales,
        COUNT(DISTINCT s.operation_id)::BIGINT AS op_count
      FROM public.sales s
      WHERE s.account_id = p_account_id
        AND s.date BETWEEN p_start AND p_end
      GROUP BY s.branch_id
    ),
    branch_expenses AS (
      SELECT
        e.branch_id,
        COALESCE(SUM(e.amount), 0) AS total_expenses
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        AND e.date BETWEEN p_start AND p_end
      GROUP BY e.branch_id
    ),
    all_branch_ids AS (
      SELECT DISTINCT branch_id FROM branch_sales
      UNION
      SELECT DISTINCT branch_id FROM branch_expenses
    )
  SELECT
    abi.branch_id,
    COALESCE(b.name, 'Sin sucursal')       AS branch_name,
    COALESCE(bs.total_sales, 0)            AS total_sales,
    COALESCE(be.total_expenses, 0)         AS total_expenses,
    COALESCE(bs.op_count, 0)              AS operation_count
  FROM all_branch_ids abi
  LEFT JOIN public.branches b  ON b.id = abi.branch_id
  LEFT JOIN branch_sales   bs  ON bs.branch_id IS NOT DISTINCT FROM abi.branch_id
  LEFT JOIN branch_expenses be ON be.branch_id IS NOT DISTINCT FROM abi.branch_id
  ORDER BY total_sales DESC NULLS LAST;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_branch_report(uuid, date, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) TO authenticated;


-- =============================================================================
-- VERIFICATION QUERIES (paste in SQL editor to verify migration)
-- =============================================================================
-- SELECT id, name, address, is_active FROM branches WHERE false; -- confirm columns
-- SELECT branch_id FROM sales WHERE false; -- confirm column
-- SELECT proname FROM pg_proc WHERE proname IN ('rpc_create_branch','rpc_deactivate_branch','rpc_branch_report');
-- SELECT max_branches, has_branches_module FROM plan_limits ORDER BY price_monthly;
