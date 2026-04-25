-- =============================================================================
-- MIGRATION: 20260425000001_security_hardening.sql
-- DESCRIPTION: Comprehensive multi-tenant security hardening for production.
--
-- VULNERABILITIES FIXED:
--
--  [CRITICAL-1] SECURITY DEFINER RPCs accept p_user_id from callers
--               → Any authenticated user could pass a victim's user_id to
--                 impersonate them, exhaust their plan quota, or inject data.
--               Fix: Remove p_user_id parameter; use auth.uid() internally.
--
--  [CRITICAL-2] profiles UPDATE without WITH CHECK → privilege escalation
--               → Any user could run:
--                 UPDATE profiles SET role='admin', plan='pro' WHERE id=auth.uid()
--               Fix: REVOKE UPDATE on sensitive columns + enforcement trigger.
--
--  [HIGH-1]     FOR ALL USING without WITH CHECK → row hijacking via UPDATE
--               → A user could change user_id to another user's id on their
--                 own rows, effectively "gifting" poisoned data to other users.
--               Fix: Split FOR ALL into SELECT/INSERT/UPDATE/DELETE with
--                    WITH CHECK (auth.uid() = user_id) on UPDATE.
--
--  [HIGH-2]     profiles SELECT policy exposes role, plan, insights_used to all
--               Fix: Restrict direct SELECT to own row; expose only safe public
--                    fields via a security-barrier view for community joins.
--
--  [MEDIUM-1]   analytics_events INSERT allows user_id IS NULL
--               → Authenticated users could spam anonymous events, polluting admin analytics.
--               Fix: Remove the OR user_id IS NULL exception.
--
-- ADDITIONAL IMPROVEMENTS:
--  - DEFAULT auth.uid() on user_id columns (no more client-side user_id injection)
--  - Missing index on products(parent_id) for variant guard queries
--  - Composite indexes for common filtered queries
--  - Admin content policies standardized to use is_admin() SECURITY DEFINER function
-- =============================================================================

-- =============================================================================
-- SECTION 1 — CRITICAL-1: Fix SECURITY DEFINER RPCs
-- Replace p_user_id parameter with internal auth.uid() call.
-- Callers (edge functions) must be updated to stop sending p_user_id.
-- =============================================================================

-- ── 1a. rpc_atomic_log_ai_insight ───────────────────────────────────────────
-- Old signature: (p_user_id uuid, p_type text, p_content text, p_source_function text)
-- New signature: (p_type text, p_content text, p_source_function text)

CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(
  p_type            text,
  p_content         text,
  p_source_function text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           uuid;
  v_profile       RECORD;
  v_insight_id    uuid;
  v_insight_record jsonb;
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock profile to prevent race conditions on usage counters
  SELECT id, plan, insights_used INTO v_profile
  FROM profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Enforce plan limits
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Insert insight
  INSERT INTO insights (user_id, type, content, actionable)
  VALUES (v_uid, p_type, p_content, 'actionable_extracted_from_content')
  RETURNING id INTO v_insight_id;

  -- Increment usage counter
  UPDATE profiles SET insights_used = insights_used + 1 WHERE id = v_uid;

  -- Telemetry
  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'insight_generated',
    jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id));

  -- UMV detection (first insight + first operation = UMV reached)
  IF EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'operation_created')
  AND NOT EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'umv_reached')
  THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'umv_reached',
      jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id));
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$$;

-- ── 1b. rpc_atomic_create_sale ───────────────────────────────────────────────
-- Old signature had: p_user_id uuid
-- New: identity from auth.uid() only

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_currency   text DEFAULT 'ARS'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid               uuid;
  v_product           RECORD;
  v_sale_id           uuid;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
BEGIN
  -- Identity always comes from the JWT
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- Lock product row; includes is_variant for Phase 3 guard
  SELECT id, stock, price, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  -- Ownership: product must belong to the authenticated user
  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  -- Phase 3: reject parent catalogue entries (those with variant children)
  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  IF v_product.stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  -- Insert sale — user_id set from v_uid (never from caller)
  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, DEFAULT)
  RETURNING id INTO v_sale_id;

  UPDATE products SET stock = stock - p_quantity WHERE id = p_product_id;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));

  SELECT id INTO v_existing_first_op
  FROM analytics_events WHERE user_id = v_uid AND event_name = 'first_operation' LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'first_operation', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;

-- ── 1c. rpc_atomic_create_purchase ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    integer,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_product         RECORD;
  v_purchase_id     uuid;
  v_purchase_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  INSERT INTO purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_amount * p_quantity, DEFAULT)
  RETURNING id INTO v_purchase_id;

  UPDATE products SET stock = stock + p_quantity WHERE id = p_product_id;

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- ── 1d. rpc_safe_delete_product ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_safe_delete_product(p_product_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id AND user_id = v_uid) THEN
    RAISE EXCEPTION 'Producto no encontrado o sin permiso' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.sales    SET product_id = NULL WHERE product_id = p_product_id;
  UPDATE public.purchases SET product_id = NULL WHERE product_id = p_product_id;
  UPDATE public.products  SET parent_id  = NULL WHERE parent_id  = p_product_id;
  DELETE FROM public.products WHERE id = p_product_id AND user_id = v_uid;
END;
$$;

-- Explicit EXECUTE grants (idempotent)
GRANT EXECUTE ON FUNCTION public.rpc_atomic_log_ai_insight(text, text, text)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, integer, text)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_safe_delete_product(uuid)                          TO authenticated;

-- =============================================================================
-- SECTION 2 — CRITICAL-2: Prevent privilege escalation on profiles
-- Strategy: Column-level REVOKE + enforcement trigger as defense-in-depth.
-- =============================================================================

-- 2a. Revoke the ability for the `authenticated` role to directly change
--     role or plan. Only service_role (used by server-side admin operations)
--     can modify these fields.
REVOKE UPDATE (role, plan) ON public.profiles FROM authenticated;

-- 2b. Enforcement trigger — second layer of defense in case a future migration
--     accidentally re-grants column privileges.
CREATE OR REPLACE FUNCTION public.prevent_profile_privilege_escalation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Admins (service_role context) can change anything
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- Prevent any direct change to role or plan by non-admins
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'Cannot change profile role directly. Use admin panel.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.plan IS DISTINCT FROM OLD.plan THEN
    RAISE EXCEPTION 'Cannot change profile plan directly. Use billing system.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Prevent changing profile id (should never happen but guard anyway)
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Cannot change profile id.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_profile_escalation ON public.profiles;
CREATE TRIGGER trg_prevent_profile_escalation
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_profile_privilege_escalation();

-- =============================================================================
-- SECTION 3 — HIGH-1: Fix FOR ALL USING → split into explicit policies
-- Adding WITH CHECK on UPDATE prevents row hijacking (changing user_id).
-- =============================================================================

-- Helper macro: drop old blanket policy, create 4 explicit policies
-- Applies to: products, clients, sales, purchases, expenses, insights

-- ── products ──────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own products" ON public.products;

DROP POLICY IF EXISTS "products_select"  ON public.products;
DROP POLICY IF EXISTS "products_insert"  ON public.products;
DROP POLICY IF EXISTS "products_update"  ON public.products;
DROP POLICY IF EXISTS "products_delete"  ON public.products;

CREATE POLICY "products_select"  ON public.products
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "products_insert"  ON public.products
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- WITH CHECK ensures user_id cannot be changed to another user's id
CREATE POLICY "products_update"  ON public.products
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "products_delete"  ON public.products
  FOR DELETE USING (auth.uid() = user_id);

-- ── clients ───────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own clients" ON public.clients;

DROP POLICY IF EXISTS "clients_select"  ON public.clients;
DROP POLICY IF EXISTS "clients_insert"  ON public.clients;
DROP POLICY IF EXISTS "clients_update"  ON public.clients;
DROP POLICY IF EXISTS "clients_delete"  ON public.clients;

CREATE POLICY "clients_select"  ON public.clients
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "clients_insert"  ON public.clients
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "clients_update"  ON public.clients
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "clients_delete"  ON public.clients
  FOR DELETE USING (auth.uid() = user_id);

-- ── sales ─────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own sales" ON public.sales;

DROP POLICY IF EXISTS "sales_select"  ON public.sales;
DROP POLICY IF EXISTS "sales_insert"  ON public.sales;
DROP POLICY IF EXISTS "sales_update"  ON public.sales;
DROP POLICY IF EXISTS "sales_delete"  ON public.sales;

CREATE POLICY "sales_select"  ON public.sales
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "sales_insert"  ON public.sales
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "sales_update"  ON public.sales
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "sales_delete"  ON public.sales
  FOR DELETE USING (auth.uid() = user_id);

-- ── purchases ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own purchases" ON public.purchases;

DROP POLICY IF EXISTS "purchases_select"  ON public.purchases;
DROP POLICY IF EXISTS "purchases_insert"  ON public.purchases;
DROP POLICY IF EXISTS "purchases_update"  ON public.purchases;
DROP POLICY IF EXISTS "purchases_delete"  ON public.purchases;

CREATE POLICY "purchases_select"  ON public.purchases
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "purchases_insert"  ON public.purchases
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "purchases_update"  ON public.purchases
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "purchases_delete"  ON public.purchases
  FOR DELETE USING (auth.uid() = user_id);

-- ── expenses ──────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own expenses" ON public.expenses;

DROP POLICY IF EXISTS "expenses_select"  ON public.expenses;
DROP POLICY IF EXISTS "expenses_insert"  ON public.expenses;
DROP POLICY IF EXISTS "expenses_update"  ON public.expenses;
DROP POLICY IF EXISTS "expenses_delete"  ON public.expenses;

CREATE POLICY "expenses_select"  ON public.expenses
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "expenses_insert"  ON public.expenses
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "expenses_update"  ON public.expenses
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "expenses_delete"  ON public.expenses
  FOR DELETE USING (auth.uid() = user_id);

-- ── insights (ERP insights table) ────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can do all to own insights" ON public.insights;

DROP POLICY IF EXISTS "insights_select"  ON public.insights;
DROP POLICY IF EXISTS "insights_insert"  ON public.insights;
DROP POLICY IF EXISTS "insights_update"  ON public.insights;
DROP POLICY IF EXISTS "insights_delete"  ON public.insights;

CREATE POLICY "insights_select"  ON public.insights
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "insights_insert"  ON public.insights
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Insights are immutable after creation; UPDATE is intentionally not granted.
-- DELETE allowed so users can clean up old insights.
CREATE POLICY "insights_delete"  ON public.insights
  FOR DELETE USING (auth.uid() = user_id);

-- ── ai_insights ───────────────────────────────────────────────────────────────
-- Already had SELECT+INSERT. Add explicit DELETE, keep UPDATE absent (immutable).
DROP POLICY IF EXISTS "Users can view their own insights"     ON public.ai_insights;
DROP POLICY IF EXISTS "System/Functions can insert insights"  ON public.ai_insights;

DROP POLICY IF EXISTS "ai_insights_select"  ON public.ai_insights;
DROP POLICY IF EXISTS "ai_insights_insert"  ON public.ai_insights;
DROP POLICY IF EXISTS "ai_insights_delete"  ON public.ai_insights;

CREATE POLICY "ai_insights_select"  ON public.ai_insights
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "ai_insights_insert"  ON public.ai_insights
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "ai_insights_delete"  ON public.ai_insights
  FOR DELETE USING (auth.uid() = user_id);

-- ── ai_conversations ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can view their own conversations"   ON public.ai_conversations;
DROP POLICY IF EXISTS "Users can insert their own conversations" ON public.ai_conversations;

DROP POLICY IF EXISTS "ai_conversations_select"  ON public.ai_conversations;
DROP POLICY IF EXISTS "ai_conversations_insert"  ON public.ai_conversations;
DROP POLICY IF EXISTS "ai_conversations_delete"  ON public.ai_conversations;

CREATE POLICY "ai_conversations_select"  ON public.ai_conversations
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "ai_conversations_insert"  ON public.ai_conversations
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "ai_conversations_delete"  ON public.ai_conversations
  FOR DELETE USING (auth.uid() = user_id);

-- ── fair_recommendations ─────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can view their own fair recommendations"   ON public.fair_recommendations;
DROP POLICY IF EXISTS "Users can insert their own fair recommendations" ON public.fair_recommendations;

DROP POLICY IF EXISTS "fair_rec_select"  ON public.fair_recommendations;
DROP POLICY IF EXISTS "fair_rec_insert"  ON public.fair_recommendations;

CREATE POLICY "fair_rec_select"  ON public.fair_recommendations
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "fair_rec_insert"  ON public.fair_recommendations
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- =============================================================================
-- SECTION 4 — HIGH-2: Restrict profiles SELECT + safe public view
-- "Profiles viewable by everyone" exposes role, plan, insights_used.
-- Solution: keep own-row SELECT + a security-barrier view for community.
-- =============================================================================

-- Drop the old "viewable by everyone" policy
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;

-- Users can always read their own complete profile
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT USING (auth.uid() = id);

-- Admins can read all profiles (via is_admin() SECURITY DEFINER — no recursion)
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles" ON public.profiles
  FOR SELECT USING (public.is_admin());

-- Safe public view: exposes ONLY display-safe fields for community joins.
-- PostgREST will use this view when the community module joins profiles.
-- SECURITY BARRIER prevents the view from leaking data through WHERE pushdown.
DROP VIEW IF EXISTS public.profiles_public;
CREATE VIEW public.profiles_public
  WITH (security_barrier = true)
AS
  SELECT id, name
  FROM public.profiles;

-- Grant read access to authenticated users and anon (for public community pages)
GRANT SELECT ON public.profiles_public TO authenticated, anon;

COMMENT ON VIEW public.profiles_public IS
  'Safe public projection of profiles exposing only id and name. '
  'Use this for community author display. Never query profiles directly for cross-user data.';

-- =============================================================================
-- SECTION 5 — MEDIUM-1: Fix analytics_events INSERT policy
-- Remove "OR user_id IS NULL" to prevent analytics spam from authenticated users.
-- =============================================================================

DROP POLICY IF EXISTS "Users can insert own analytics events"  ON public.analytics_events;
DROP POLICY IF EXISTS "Users can insert own events"            ON public.analytics_events;

CREATE POLICY "analytics_insert_own" ON public.analytics_events
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Admins read all events (unchanged)
DROP POLICY IF EXISTS "Admins can read all analytics events"  ON public.analytics_events;
DROP POLICY IF EXISTS "Admins can read all events"            ON public.analytics_events;

CREATE POLICY "analytics_select_admin" ON public.analytics_events
  FOR SELECT USING (public.is_admin(auth.uid()));

-- =============================================================================
-- SECTION 6 — DEFAULT auth.uid() on user_id columns
-- Tables no longer require the client to pass user_id; the DB enforces it.
-- =============================================================================

ALTER TABLE public.products        ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.clients         ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.sales           ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.purchases       ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.expenses        ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.insights        ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.ai_insights     ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.ai_conversations ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.fair_recommendations ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.analytics_events ALTER COLUMN user_id SET DEFAULT auth.uid();

-- =============================================================================
-- SECTION 7 — Admin content policies: standardize to is_admin() function
-- Avoids inline EXISTS (SELECT FROM profiles) which can cause RLS recursion
-- if profiles policy is later tightened.
-- =============================================================================

-- ── seguros ───────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admins have full access" ON public.seguros;
CREATE POLICY "seguros_admin_all" ON public.seguros
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ── fair_ai_tools ─────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admin full access fair_ai_tools" ON public.fair_ai_tools;
CREATE POLICY "fair_ai_tools_admin_all" ON public.fair_ai_tools
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ── copilot_prompts ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Admin full access copilot_prompts" ON public.copilot_prompts;
CREATE POLICY "copilot_prompts_admin_all" ON public.copilot_prompts
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

-- courses (also inline EXISTS pattern)
DROP POLICY IF EXISTS "Admins can insert courses" ON public.courses;
DROP POLICY IF EXISTS "Admins can update courses" ON public.courses;
DROP POLICY IF EXISTS "Admins can delete courses" ON public.courses;

CREATE POLICY "courses_admin_insert" ON public.courses
  FOR INSERT WITH CHECK (public.is_admin());

CREATE POLICY "courses_admin_update" ON public.courses
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

CREATE POLICY "courses_admin_delete" ON public.courses
  FOR DELETE USING (public.is_admin());

-- posts admin delete
DROP POLICY IF EXISTS "Admins can delete any post"  ON public.posts;
DROP POLICY IF EXISTS "Admins can delete any reply" ON public.replies;

CREATE POLICY "posts_admin_delete"   ON public.posts   FOR DELETE USING (public.is_admin());
CREATE POLICY "replies_admin_delete" ON public.replies FOR DELETE USING (public.is_admin());

-- =============================================================================
-- SECTION 8 — Missing indexes for performance and security-sensitive queries
-- =============================================================================

-- Variant guard queries scan products(parent_id) — needs an index
CREATE INDEX IF NOT EXISTS idx_products_parent_id    ON public.products(parent_id);
CREATE INDEX IF NOT EXISTS idx_products_is_variant   ON public.products(is_variant);

-- Composite indexes for common filtered + sorted queries
CREATE INDEX IF NOT EXISTS idx_sales_user_date       ON public.sales(user_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_purchases_user_date   ON public.purchases(user_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_expenses_user_date    ON public.expenses(user_id, date DESC);

-- Analytics compound index used by admin cohort queries
CREATE INDEX IF NOT EXISTS idx_analytics_user_event  ON public.analytics_events(user_id, event_name);

-- ai_insights by user + recency (common query pattern)
CREATE INDEX IF NOT EXISTS idx_ai_insights_user_created ON public.ai_insights(user_id, created_at DESC);

-- =============================================================================
-- VERIFICATION QUERIES (run manually after applying to confirm correctness)
-- =============================================================================
--
-- 1. Confirm all business tables have RLS enabled:
--    SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname = 'public'
--    AND tablename IN ('products','clients','sales','purchases','expenses',
--                      'insights','ai_insights','ai_conversations');
--
-- 2. Confirm policies per table:
--    SELECT tablename, policyname, cmd, qual, with_check
--    FROM pg_policies WHERE schemaname = 'public'
--    ORDER BY tablename, cmd;
--
-- 3. Test privilege escalation attempt (should fail with error):
--    UPDATE profiles SET role = 'admin' WHERE id = auth.uid();
--    → Expected: ERROR: Cannot change profile role directly
--
-- 4. Test row hijacking attempt (should fail):
--    UPDATE products SET user_id = 'other-user-uuid' WHERE id = 'my-product-id';
--    → Expected: new row violates row-level security policy
--
-- 5. Test cross-tenant data access (should return 0 rows):
--    SELECT * FROM sales; -- As a regular user
--    → Expected: only own rows
--
-- 6. Confirm profiles no longer leaks to all users:
--    SELECT role, plan, insights_used FROM profiles WHERE id != auth.uid();
--    → Expected: 0 rows (only own profile visible)
--    SELECT id, name FROM profiles_public WHERE id != auth.uid();
--    → Expected: all users' id+name (safe for community display)
-- =============================================================================
