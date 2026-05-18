-- =============================================================================
-- MIGRATION: 20260517000003_fix_rls_initplan_and_indexes.sql
-- DESCRIPTION:
--   SECTION 1 — auth_rls_initplan (80 policies across 35 tables)
--     Replace direct auth.uid() / auth.role() calls with (SELECT auth.uid())
--     subquery form. PostgreSQL evaluates the subquery once per statement
--     instead of once per row — fixes O(n) → O(1) auth function calls.
--
--   SECTION 2 — rls_policy_always_true
--     companies_insert had WITH CHECK (true) — any role (incl. anon) could
--     insert. Restricted to authenticated + meaningful expression.
--
--   SECTION 3 — duplicate_index
--     Drop idx_products_parent (duplicate of idx_products_parent_id).
--
--   SECTION 4 — unindexed_foreign_keys (22 FKs)
--     Add covering indexes for all unindexed FK columns to prevent seq scans
--     on JOIN and ON DELETE CASCADE operations.
--
-- Applied: 2026-05-17
-- =============================================================================


-- ── SECTION 1: auth_rls_initplan — fix all 35 tables ─────────────────────────

-- ai_conversations
DROP POLICY IF EXISTS "ai_conversations_select" ON public.ai_conversations;
CREATE POLICY "ai_conversations_select" ON public.ai_conversations
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "ai_conversations_insert" ON public.ai_conversations;
CREATE POLICY "ai_conversations_insert" ON public.ai_conversations
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "ai_conversations_delete" ON public.ai_conversations;
CREATE POLICY "ai_conversations_delete" ON public.ai_conversations
  FOR DELETE USING ((select auth.uid()) = user_id);

-- ai_insights
DROP POLICY IF EXISTS "ai_insights_select" ON public.ai_insights;
CREATE POLICY "ai_insights_select" ON public.ai_insights
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "ai_insights_insert" ON public.ai_insights;
CREATE POLICY "ai_insights_insert" ON public.ai_insights
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "ai_insights_delete" ON public.ai_insights;
CREATE POLICY "ai_insights_delete" ON public.ai_insights
  FOR DELETE USING ((select auth.uid()) = user_id);

-- analytics_events
DROP POLICY IF EXISTS "analytics_insert_own" ON public.analytics_events;
CREATE POLICY "analytics_insert_own" ON public.analytics_events
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "analytics_select_admin" ON public.analytics_events;
CREATE POLICY "analytics_select_admin" ON public.analytics_events
  FOR SELECT USING (is_admin((select auth.uid())));

-- audit_logs
DROP POLICY IF EXISTS "Users can access their audit logs" ON public.audit_logs;
CREATE POLICY "Users can access their audit logs" ON public.audit_logs
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- clients (individual user policies)
DROP POLICY IF EXISTS "clients_select" ON public.clients;
CREATE POLICY "clients_select" ON public.clients
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "clients_insert" ON public.clients;
CREATE POLICY "clients_insert" ON public.clients
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "clients_update" ON public.clients;
CREATE POLICY "clients_update" ON public.clients
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "clients_delete" ON public.clients;
CREATE POLICY "clients_delete" ON public.clients
  FOR DELETE USING ((select auth.uid()) = user_id);

-- clients (company-based policy)
DROP POLICY IF EXISTS "company_users_clients_access" ON public.clients;
CREATE POLICY "company_users_clients_access" ON public.clients
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- companies (SELECT + UPDATE — INSERT handled in SECTION 2)
DROP POLICY IF EXISTS "companies_select" ON public.companies;
CREATE POLICY "companies_select" ON public.companies
  FOR SELECT USING (
    id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS "companies_update" ON public.companies;
CREATE POLICY "companies_update" ON public.companies
  FOR UPDATE USING (
    id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- company_users
DROP POLICY IF EXISTS "cu_select" ON public.company_users;
CREATE POLICY "cu_select" ON public.company_users
  FOR SELECT USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "cu_insert" ON public.company_users;
CREATE POLICY "cu_insert" ON public.company_users
  FOR INSERT WITH CHECK (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "cu_update" ON public.company_users;
CREATE POLICY "cu_update" ON public.company_users
  FOR UPDATE USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "cu_delete" ON public.company_users;
CREATE POLICY "cu_delete" ON public.company_users
  FOR DELETE USING (user_id = (select auth.uid()));

-- course_enrollments
DROP POLICY IF EXISTS "Users can view their own enrollments" ON public.course_enrollments;
CREATE POLICY "Users can view their own enrollments" ON public.course_enrollments
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can enroll themselves" ON public.course_enrollments;
CREATE POLICY "Users can enroll themselves" ON public.course_enrollments
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

-- course_progress
DROP POLICY IF EXISTS "Users can do all to own course progress" ON public.course_progress;
CREATE POLICY "Users can do all to own course progress" ON public.course_progress
  FOR ALL USING ((select auth.uid()) = user_id);

-- email_logs (TO authenticated preserved)
DROP POLICY IF EXISTS "Admins can view email logs" ON public.email_logs;
CREATE POLICY "Admins can view email logs" ON public.email_logs
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = (select auth.uid())
        AND profiles.role = 'admin'
    )
  );

-- events
DROP POLICY IF EXISTS "Users can access their events" ON public.events;
CREATE POLICY "Users can access their events" ON public.events
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- expenses (individual user policies)
DROP POLICY IF EXISTS "expenses_select" ON public.expenses;
CREATE POLICY "expenses_select" ON public.expenses
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "expenses_insert" ON public.expenses;
CREATE POLICY "expenses_insert" ON public.expenses
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "expenses_update" ON public.expenses;
CREATE POLICY "expenses_update" ON public.expenses
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "expenses_delete" ON public.expenses;
CREATE POLICY "expenses_delete" ON public.expenses
  FOR DELETE USING ((select auth.uid()) = user_id);

-- expenses (company-based)
DROP POLICY IF EXISTS "company_users_expenses_access" ON public.expenses;
CREATE POLICY "company_users_expenses_access" ON public.expenses
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- fair_recommendations
DROP POLICY IF EXISTS "fair_rec_select" ON public.fair_recommendations;
CREATE POLICY "fair_rec_select" ON public.fair_recommendations
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "fair_rec_insert" ON public.fair_recommendations;
CREATE POLICY "fair_rec_insert" ON public.fair_recommendations
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

-- insights
DROP POLICY IF EXISTS "insights_select" ON public.insights;
CREATE POLICY "insights_select" ON public.insights
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "insights_insert" ON public.insights;
CREATE POLICY "insights_insert" ON public.insights
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "insights_delete" ON public.insights;
CREATE POLICY "insights_delete" ON public.insights
  FOR DELETE USING ((select auth.uid()) = user_id);

-- inventory_movements
DROP POLICY IF EXISTS "Users can access their inventory movements" ON public.inventory_movements;
CREATE POLICY "Users can access their inventory movements" ON public.inventory_movements
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- inventory_stock
DROP POLICY IF EXISTS "Users can access their inventory stock" ON public.inventory_stock;
CREATE POLICY "Users can access their inventory stock" ON public.inventory_stock
  FOR ALL USING (
    warehouse_id IN (
      SELECT warehouses.id FROM public.warehouses
      WHERE warehouses.company_id IN (
        SELECT company_users.company_id FROM company_users
        WHERE company_users.user_id = (select auth.uid())
      )
    )
  );

-- invoice_documents
DROP POLICY IF EXISTS "invoice_documents_select" ON public.invoice_documents;
CREATE POLICY "invoice_documents_select" ON public.invoice_documents
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "invoice_documents_insert" ON public.invoice_documents;
CREATE POLICY "invoice_documents_insert" ON public.invoice_documents
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "invoice_documents_update" ON public.invoice_documents;
CREATE POLICY "invoice_documents_update" ON public.invoice_documents
  FOR UPDATE USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "invoice_documents_delete" ON public.invoice_documents;
CREATE POLICY "invoice_documents_delete" ON public.invoice_documents
  FOR DELETE USING ((select auth.uid()) = user_id);

-- invoice_suppliers
DROP POLICY IF EXISTS "invoice_suppliers_all" ON public.invoice_suppliers;
CREATE POLICY "invoice_suppliers_all" ON public.invoice_suppliers
  FOR ALL USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

-- landing_sections (uses auth.role() — same initplan issue)
DROP POLICY IF EXISTS "Allow admin write access for landing sections" ON public.landing_sections;
CREATE POLICY "Allow admin write access for landing sections" ON public.landing_sections
  FOR ALL USING ((select auth.role()) = 'authenticated');

-- lesson_progress
DROP POLICY IF EXISTS "Users can view their own progress" ON public.lesson_progress;
CREATE POLICY "Users can view their own progress" ON public.lesson_progress
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can update their own progress" ON public.lesson_progress;
CREATE POLICY "Users can update their own progress" ON public.lesson_progress
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can edit their own progress" ON public.lesson_progress;
CREATE POLICY "Users can edit their own progress" ON public.lesson_progress
  FOR UPDATE USING ((select auth.uid()) = user_id);

-- meetings
DROP POLICY IF EXISTS "Admins can manage meetings" ON public.meetings;
CREATE POLICY "Admins can manage meetings" ON public.meetings
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = (select auth.uid())
        AND profiles.role = 'admin'
    )
  );

-- post_likes
DROP POLICY IF EXISTS "Users can insert own likes" ON public.post_likes;
CREATE POLICY "Users can insert own likes" ON public.post_likes
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can delete own likes" ON public.post_likes;
CREATE POLICY "Users can delete own likes" ON public.post_likes
  FOR DELETE USING ((select auth.uid()) = user_id);

-- product_aliases
DROP POLICY IF EXISTS "product_aliases_all" ON public.product_aliases;
CREATE POLICY "product_aliases_all" ON public.product_aliases
  FOR ALL USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

-- product_variants
DROP POLICY IF EXISTS "Users can access variants of their products" ON public.product_variants;
CREATE POLICY "Users can access variants of their products" ON public.product_variants
  FOR ALL USING (
    product_id IN (
      SELECT products.id FROM public.products
      WHERE products.company_id IN (
          SELECT company_users.company_id FROM company_users
          WHERE company_users.user_id = (select auth.uid())
        )
        OR products.user_id = (select auth.uid())
    )
  );

-- products (individual user policies)
DROP POLICY IF EXISTS "products_select" ON public.products;
CREATE POLICY "products_select" ON public.products
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "products_insert" ON public.products;
CREATE POLICY "products_insert" ON public.products
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "products_update" ON public.products;
CREATE POLICY "products_update" ON public.products
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "products_delete" ON public.products;
CREATE POLICY "products_delete" ON public.products
  FOR DELETE USING ((select auth.uid()) = user_id);

-- products (company-based)
DROP POLICY IF EXISTS "company_users_products_access" ON public.products;
CREATE POLICY "company_users_products_access" ON public.products
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- profiles
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT USING ((select auth.uid()) = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING ((select auth.uid()) = id);

-- purchase_items
DROP POLICY IF EXISTS "Users can access their purchase items" ON public.purchase_items;
CREATE POLICY "Users can access their purchase items" ON public.purchase_items
  FOR ALL USING (
    purchase_id IN (
      SELECT purchases.id FROM public.purchases
      WHERE purchases.company_id IN (
          SELECT company_users.company_id FROM company_users
          WHERE company_users.user_id = (select auth.uid())
        )
        OR purchases.user_id = (select auth.uid())
    )
  );

-- purchase_pools
DROP POLICY IF EXISTS "Admins can manage purchase pools" ON public.purchase_pools;
CREATE POLICY "Admins can manage purchase pools" ON public.purchase_pools
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = (select auth.uid())
        AND profiles.role = 'admin'
    )
  );

-- purchases (individual user policies)
DROP POLICY IF EXISTS "purchases_select" ON public.purchases;
CREATE POLICY "purchases_select" ON public.purchases
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "purchases_insert" ON public.purchases;
CREATE POLICY "purchases_insert" ON public.purchases
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "purchases_update" ON public.purchases;
CREATE POLICY "purchases_update" ON public.purchases
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "purchases_delete" ON public.purchases;
CREATE POLICY "purchases_delete" ON public.purchases
  FOR DELETE USING ((select auth.uid()) = user_id);

-- purchases (company-based)
DROP POLICY IF EXISTS "company_users_purchases_access" ON public.purchases;
CREATE POLICY "company_users_purchases_access" ON public.purchases
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- sale_items
DROP POLICY IF EXISTS "Users can access their sale items" ON public.sale_items;
CREATE POLICY "Users can access their sale items" ON public.sale_items
  FOR ALL USING (
    sale_id IN (
      SELECT sales.id FROM public.sales
      WHERE sales.company_id IN (
          SELECT company_users.company_id FROM company_users
          WHERE company_users.user_id = (select auth.uid())
        )
        OR sales.user_id = (select auth.uid())
    )
  );

-- sale_notifications
DROP POLICY IF EXISTS "sale_notifications_all" ON public.sale_notifications;
CREATE POLICY "sale_notifications_all" ON public.sale_notifications
  FOR ALL USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

-- sales (individual user policies)
DROP POLICY IF EXISTS "sales_select" ON public.sales;
CREATE POLICY "sales_select" ON public.sales
  FOR SELECT USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "sales_insert" ON public.sales;
CREATE POLICY "sales_insert" ON public.sales
  FOR INSERT WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "sales_update" ON public.sales;
CREATE POLICY "sales_update" ON public.sales
  FOR UPDATE USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "sales_delete" ON public.sales;
CREATE POLICY "sales_delete" ON public.sales
  FOR DELETE USING ((select auth.uid()) = user_id);

-- sales (company-based)
DROP POLICY IF EXISTS "company_users_sales_access" ON public.sales;
CREATE POLICY "company_users_sales_access" ON public.sales
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- suppliers
DROP POLICY IF EXISTS "Users can access their suppliers" ON public.suppliers;
CREATE POLICY "Users can access their suppliers" ON public.suppliers
  FOR ALL USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

-- units_of_measure
DROP POLICY IF EXISTS "uom_select" ON public.units_of_measure;
CREATE POLICY "uom_select" ON public.units_of_measure
  FOR SELECT USING ((is_system = true) OR (user_id = (select auth.uid())));

DROP POLICY IF EXISTS "uom_insert" ON public.units_of_measure;
CREATE POLICY "uom_insert" ON public.units_of_measure
  FOR INSERT WITH CHECK ((user_id = (select auth.uid())) AND (is_system = false));

DROP POLICY IF EXISTS "uom_update" ON public.units_of_measure;
CREATE POLICY "uom_update" ON public.units_of_measure
  FOR UPDATE USING ((user_id = (select auth.uid())) AND (is_system = false))
  WITH CHECK ((user_id = (select auth.uid())) AND (is_system = false));

DROP POLICY IF EXISTS "uom_delete" ON public.units_of_measure;
CREATE POLICY "uom_delete" ON public.units_of_measure
  FOR DELETE USING ((user_id = (select auth.uid())) AND (is_system = false));

-- warehouses
DROP POLICY IF EXISTS "warehouses_select" ON public.warehouses;
CREATE POLICY "warehouses_select" ON public.warehouses
  FOR SELECT USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS "warehouses_insert" ON public.warehouses;
CREATE POLICY "warehouses_insert" ON public.warehouses
  FOR INSERT WITH CHECK (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS "warehouses_update" ON public.warehouses;
CREATE POLICY "warehouses_update" ON public.warehouses
  FOR UPDATE USING (
    company_id IN (
      SELECT company_users.company_id FROM company_users
      WHERE company_users.user_id = (select auth.uid())
    )
  );


-- ── SECTION 2: rls_policy_always_true — companies_insert ─────────────────────
-- Before: WITH CHECK (true) — any role (including anon) could create companies.
-- After:  TO authenticated + auth.uid() IS NOT NULL — requires a valid session.

DROP POLICY IF EXISTS "companies_insert" ON public.companies;
CREATE POLICY "companies_insert" ON public.companies
  FOR INSERT TO authenticated
  WITH CHECK ((select auth.uid()) IS NOT NULL);


-- ── SECTION 3: duplicate_index — products ─────────────────────────────────────
-- idx_products_parent and idx_products_parent_id are identical. Drop the one
-- without the descriptive _id suffix.

DROP INDEX IF EXISTS public.idx_products_parent;


-- ── SECTION 4: unindexed_foreign_keys — 22 FK indexes ───────────────────────
-- Each index covers the FK column used in JOINs and CASCADE operations.

CREATE INDEX IF NOT EXISTS idx_audit_logs_company_id          ON public.audit_logs          (company_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id             ON public.audit_logs          (user_id);
CREATE INDEX IF NOT EXISTS idx_company_users_user_id          ON public.company_users        (user_id);
CREATE INDEX IF NOT EXISTS idx_course_enrollments_course_id   ON public.course_enrollments   (course_id);
CREATE INDEX IF NOT EXISTS idx_course_lessons_module_id       ON public.course_lessons        (module_id);
CREATE INDEX IF NOT EXISTS idx_course_modules_course_id       ON public.course_modules        (course_id);
CREATE INDEX IF NOT EXISTS idx_events_company_id              ON public.events               (company_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_created_by ON public.inventory_movements  (created_by);
CREATE INDEX IF NOT EXISTS idx_inventory_stock_warehouse_id   ON public.inventory_stock      (warehouse_id);
CREATE INDEX IF NOT EXISTS idx_lesson_progress_lesson_id      ON public.lesson_progress      (lesson_id);
CREATE INDEX IF NOT EXISTS idx_post_likes_user_id             ON public.post_likes           (user_id);
CREATE INDEX IF NOT EXISTS idx_product_aliases_product_id     ON public.product_aliases      (product_id);
CREATE INDEX IF NOT EXISTS idx_purchase_items_variant_id      ON public.purchase_items       (variant_id);
CREATE INDEX IF NOT EXISTS idx_purchases_product_id           ON public.purchases            (product_id);
CREATE INDEX IF NOT EXISTS idx_purchases_supplier_id          ON public.purchases            (supplier_id);
CREATE INDEX IF NOT EXISTS idx_replies_post_id                ON public.replies              (post_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_variant_id          ON public.sale_items           (variant_id);
CREATE INDEX IF NOT EXISTS idx_sale_notifications_client_id   ON public.sale_notifications   (client_id);
CREATE INDEX IF NOT EXISTS idx_sales_client_id                ON public.sales                (client_id);
CREATE INDEX IF NOT EXISTS idx_sales_product_id               ON public.sales                (product_id);
CREATE INDEX IF NOT EXISTS idx_suppliers_company_id           ON public.suppliers            (company_id);
CREATE INDEX IF NOT EXISTS idx_warehouses_company_id          ON public.warehouses           (company_id);
