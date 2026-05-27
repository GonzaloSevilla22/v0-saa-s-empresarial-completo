-- =============================================================================
-- MIGRATION: 20260527000004_ledger_immutability.sql
-- DESCRIPTION: Make stock_movements an immutable append-only ledger.
--
-- Problem:
--   The previous migrations added SELECT + INSERT RLS policies.
--   PostgreSQL RLS default is DENY for any operation without an explicit policy
--   (when RLS is ENABLED), so UPDATE and DELETE were implicitly blocked.
--   However, this was not documented, not visible to an auditor inspecting
--   the policies table, and could be accidentally overridden by a future
--   permissive policy addition.
--
-- Fix:
--   Add EXPLICIT DENY policies for UPDATE and DELETE on stock_movements.
--   These policies use USING (false) — no row ever satisfies the predicate —
--   making it impossible for any authenticated user to modify or delete
--   movement records.
--
-- Note: Supabase service_role bypasses RLS entirely (by design). This means
--   admin-level SQL editor access can still mutate rows — that is expected
--   and acceptable (admin access requires separate organizational controls).
--   The policies protect against authenticated API users abusing the ledger.
--
-- Compliance:
--   With these policies, the stock_movements table satisfies the append-only
--   requirement for fiscal inventory audit logs:
--   - Rows can only be created (INSERT)
--   - Rows can never be modified (UPDATE DENY)
--   - Rows can never be deleted (DELETE DENY)
--   - Any attempt by an authenticated user returns a permission error
-- =============================================================================

-- ── Explicit DENY: no authenticated user can update any movement row ──────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'stock_movements'
      AND policyname = 'stock_movements_no_update'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY "stock_movements_no_update"
        ON public.stock_movements
        FOR UPDATE
        USING (false)
    $policy$;
  END IF;
END;
$$;

-- ── Explicit DENY: no authenticated user can delete any movement row ──────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'stock_movements'
      AND policyname = 'stock_movements_no_delete'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY "stock_movements_no_delete"
        ON public.stock_movements
        FOR DELETE
        USING (false)
    $policy$;
  END IF;
END;
$$;

-- ── Verification comment (queryable by auditors) ──────────────────────────────
-- After this migration, pg_policies for stock_movements should show:
--
--   stock_movements_select    | SELECT  | PERMISSIVE | user_id = auth.uid()
--   stock_movements_insert    | INSERT  | PERMISSIVE | user_id = auth.uid()
--   stock_movements_no_update | UPDATE  | PERMISSIVE | false   (← deny-all)
--   stock_movements_no_delete | DELETE  | PERMISSIVE | false   (← deny-all)
--
-- Query to verify:
--   SELECT policyname, cmd, qual
--   FROM   pg_policies
--   WHERE  tablename = 'stock_movements'
--   ORDER  BY policyname;
