-- =============================================================================
-- MIGRATION: 20260517000001_fix_security_advisor.sql
-- DESCRIPTION: Fix Supabase Security Advisor warnings
--
--   [CRITICAL] profiles_public view runs as owner (postgres/service_role)
--              because security_invoker is not set — effectively bypasses RLS.
--              Fix: ALTER VIEW SET (security_invoker = on).
--
--   [WARN x6]  Auth RLS Initialization Plan on posts, replies, stock_movements.
--              Policies call auth.uid() directly inside USING/WITH CHECK clauses.
--              PostgreSQL re-evaluates this function per row, which can be
--              100× slower on large tables. Fix: wrap in a subquery
--              `(select auth.uid())` so PostgreSQL evaluates it once per query.
--
-- Applied: 2026-05-17
-- =============================================================================

-- ── 1. profiles_public — enable security_invoker (CRITICAL fix) ───────────────
--
-- Before: view ran as its owner (typically postgres/service_role in Supabase).
--         Any authenticated user could read ALL profiles, bypassing RLS entirely.
-- After:  view runs with the calling user's privileges → RLS is enforced normally.
ALTER VIEW public.profiles_public SET (security_invoker = on);


-- ── 2. posts — fix Auth RLS Initialization Plan (×3 policies) ────────────────

DROP POLICY IF EXISTS "Users can insert own posts" ON public.posts;
CREATE POLICY "Users can insert own posts" ON public.posts
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can update own posts" ON public.posts;
CREATE POLICY "Users can update own posts" ON public.posts
  FOR UPDATE USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can delete own posts" ON public.posts;
CREATE POLICY "Users can delete own posts" ON public.posts
  FOR DELETE USING ((select auth.uid()) = user_id);


-- ── 3. replies — fix Auth RLS Initialization Plan (×3 policies) ──────────────

DROP POLICY IF EXISTS "Users can insert own replies" ON public.replies;
CREATE POLICY "Users can insert own replies" ON public.replies
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can update own replies" ON public.replies;
CREATE POLICY "Users can update own replies" ON public.replies
  FOR UPDATE USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can delete own replies" ON public.replies;
CREATE POLICY "Users can delete own replies" ON public.replies
  FOR DELETE USING ((select auth.uid()) = user_id);


-- ── 4. stock_movements — fix Auth RLS Initialization Plan (×2 policies) ───────

DROP POLICY IF EXISTS "stock_movements_select" ON public.stock_movements;
CREATE POLICY "stock_movements_select" ON public.stock_movements
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "stock_movements_insert" ON public.stock_movements;
CREATE POLICY "stock_movements_insert" ON public.stock_movements
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));
