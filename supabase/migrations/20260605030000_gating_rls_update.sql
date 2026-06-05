-- =============================================================================
-- MIGRATION: 20260605030000_gating_rls_update.sql
-- CHANGE:    C-02 plan-gating-engine
-- DESCRIPTION:
--   Fixes the community INSERT gating and migrates it from the legacy
--   `plan = 'pro'` (ENUM) check to `billing_plan IN ('avanzado','pro')`.
--
--   SECURITY FIX: C-09 added "Pro users can insert posts/replies" policies but
--   left the pre-existing "Users can insert own posts/replies" policies in place.
--   PERMISSIVE policies are OR'd, so the ownership-only policy let ANY
--   authenticated user insert regardless of plan — the plan gate was bypassed.
--
--   Fix: drop BOTH INSERT policies per table and create a SINGLE policy that
--   requires ownership AND an eligible plan (avanzado or pro). Combining the
--   conditions in one policy with AND closes the OR bypass.
-- =============================================================================

-- ── posts: replace the two INSERT policies with one combined gate ────────────
DROP POLICY IF EXISTS "Pro users can insert posts" ON public.posts;
DROP POLICY IF EXISTS "Users can insert own posts"  ON public.posts;

CREATE POLICY "posts_insert_owner_and_plan" ON public.posts
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND billing_plan IN ('avanzado', 'pro')
    )
  );

-- ── replies: same combined gate ──────────────────────────────────────────────
DROP POLICY IF EXISTS "Pro users can insert replies" ON public.replies;
DROP POLICY IF EXISTS "Users can insert own replies"  ON public.replies;

CREATE POLICY "replies_insert_owner_and_plan" ON public.replies
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = (SELECT auth.uid())
        AND billing_plan IN ('avanzado', 'pro')
    )
  );

-- ── Assertions (run on remote to verify) ─────────────────────────────────────
-- SELECT policyname, with_check FROM pg_policies
--   WHERE tablename='posts' AND cmd='INSERT';
-- Expected: exactly 1 row → posts_insert_owner_and_plan
--
-- SELECT policyname FROM pg_policies WHERE tablename='replies' AND cmd='INSERT';
-- Expected: exactly 1 row → replies_insert_owner_and_plan

-- =============================================================================
-- END OF MIGRATION 20260605030000_gating_rls_update.sql
-- =============================================================================
