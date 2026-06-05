-- ============================================================
-- Bloque D — Task 4.1: Migrar RLS de user_id a account_id
-- Change: multi-user-tenant-architecture (C-05)
--
-- Para cada tabla de negocio, se eliminan las policies antiguas
-- (basadas en user_id = auth.uid()) y se crean nuevas policies
-- basadas en account_id IN (SELECT current_account_ids()).
--
-- Excepción: units_of_measure — SELECT incluye filas de sistema
--            (is_system = true), y DML solo permite is_system = false.
-- Excepción: stock_movements — ledger inmutable: DELETE y UPDATE
--            se mantienen bloqueados (qual = false) por diseño.
-- ============================================================

-- ============================================================
-- TABLA: products
-- Policies viejas: products_select, products_insert, products_update,
--                  products_delete, company_users_products_access
-- ============================================================
DROP POLICY IF EXISTS "products_select" ON public.products;
DROP POLICY IF EXISTS "products_insert" ON public.products;
DROP POLICY IF EXISTS "products_update" ON public.products;
DROP POLICY IF EXISTS "products_delete" ON public.products;
DROP POLICY IF EXISTS "company_users_products_access" ON public.products;

CREATE POLICY "products_account_select" ON public.products
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "products_account_insert" ON public.products
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "products_account_update" ON public.products
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "products_account_delete" ON public.products
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: sales
-- Policies viejas: sales_select, sales_insert, sales_update,
--                  sales_delete, company_users_sales_access
-- ============================================================
DROP POLICY IF EXISTS "sales_select" ON public.sales;
DROP POLICY IF EXISTS "sales_insert" ON public.sales;
DROP POLICY IF EXISTS "sales_update" ON public.sales;
DROP POLICY IF EXISTS "sales_delete" ON public.sales;
DROP POLICY IF EXISTS "company_users_sales_access" ON public.sales;

CREATE POLICY "sales_account_select" ON public.sales
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "sales_account_insert" ON public.sales
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "sales_account_update" ON public.sales
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "sales_account_delete" ON public.sales
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: purchases
-- Policies viejas: purchases_select, purchases_insert, purchases_update,
--                  purchases_delete, company_users_purchases_access
-- ============================================================
DROP POLICY IF EXISTS "purchases_select" ON public.purchases;
DROP POLICY IF EXISTS "purchases_insert" ON public.purchases;
DROP POLICY IF EXISTS "purchases_update" ON public.purchases;
DROP POLICY IF EXISTS "purchases_delete" ON public.purchases;
DROP POLICY IF EXISTS "company_users_purchases_access" ON public.purchases;

CREATE POLICY "purchases_account_select" ON public.purchases
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "purchases_account_insert" ON public.purchases
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "purchases_account_update" ON public.purchases
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "purchases_account_delete" ON public.purchases
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: expenses
-- Policies viejas: expenses_select, expenses_insert, expenses_update,
--                  expenses_delete, company_users_expenses_access
-- ============================================================
DROP POLICY IF EXISTS "expenses_select" ON public.expenses;
DROP POLICY IF EXISTS "expenses_insert" ON public.expenses;
DROP POLICY IF EXISTS "expenses_update" ON public.expenses;
DROP POLICY IF EXISTS "expenses_delete" ON public.expenses;
DROP POLICY IF EXISTS "company_users_expenses_access" ON public.expenses;

CREATE POLICY "expenses_account_select" ON public.expenses
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "expenses_account_insert" ON public.expenses
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "expenses_account_update" ON public.expenses
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "expenses_account_delete" ON public.expenses
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: clients
-- Policies viejas: clients_select, clients_insert, clients_update,
--                  clients_delete, company_users_clients_access
-- ============================================================
DROP POLICY IF EXISTS "clients_select" ON public.clients;
DROP POLICY IF EXISTS "clients_insert" ON public.clients;
DROP POLICY IF EXISTS "clients_update" ON public.clients;
DROP POLICY IF EXISTS "clients_delete" ON public.clients;
DROP POLICY IF EXISTS "company_users_clients_access" ON public.clients;

CREATE POLICY "clients_account_select" ON public.clients
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "clients_account_insert" ON public.clients
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "clients_account_update" ON public.clients
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "clients_account_delete" ON public.clients
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: stock_movements
-- Policies viejas: stock_movements_select, stock_movements_insert,
--                  stock_movements_no_update, stock_movements_no_delete
-- NOTA: Ledger inmutable — UPDATE y DELETE siguen bloqueados (false).
--       Solo se migra el scope de SELECT e INSERT a account_id.
-- ============================================================
DROP POLICY IF EXISTS "stock_movements_select" ON public.stock_movements;
DROP POLICY IF EXISTS "stock_movements_insert" ON public.stock_movements;
DROP POLICY IF EXISTS "stock_movements_no_update" ON public.stock_movements;
DROP POLICY IF EXISTS "stock_movements_no_delete" ON public.stock_movements;

CREATE POLICY "stock_movements_account_select" ON public.stock_movements
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "stock_movements_account_insert" ON public.stock_movements
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

-- Mantener ledger inmutable: UPDATE y DELETE bloqueados por diseño
CREATE POLICY "stock_movements_no_update" ON public.stock_movements
  FOR UPDATE TO authenticated
  USING (false);

CREATE POLICY "stock_movements_no_delete" ON public.stock_movements
  FOR DELETE TO authenticated
  USING (false);

-- ============================================================
-- TABLA: units_of_measure (EXCEPCIÓN)
-- Policies viejas: uom_select, uom_insert, uom_update, uom_delete
-- EXCEPCIÓN: SELECT permite filas de sistema (is_system = true).
--            INSERT/UPDATE/DELETE solo permiten filas de la cuenta
--            y bloquean modificar filas de sistema (is_system = false).
-- ============================================================
DROP POLICY IF EXISTS "uom_select" ON public.units_of_measure;
DROP POLICY IF EXISTS "uom_insert" ON public.units_of_measure;
DROP POLICY IF EXISTS "uom_update" ON public.units_of_measure;
DROP POLICY IF EXISTS "uom_delete" ON public.units_of_measure;

CREATE POLICY "uom_account_select" ON public.units_of_measure
  FOR SELECT TO authenticated
  USING (is_system = true OR account_id IN (SELECT current_account_ids()));

CREATE POLICY "uom_account_insert" ON public.units_of_measure
  FOR INSERT TO authenticated
  WITH CHECK (
    is_system = false
    AND account_id IN (SELECT current_account_ids())
  );

CREATE POLICY "uom_account_update" ON public.units_of_measure
  FOR UPDATE TO authenticated
  USING (
    is_system = false
    AND account_id IN (SELECT current_account_ids())
  )
  WITH CHECK (
    is_system = false
    AND account_id IN (SELECT current_account_ids())
  );

CREATE POLICY "uom_account_delete" ON public.units_of_measure
  FOR DELETE TO authenticated
  USING (
    is_system = false
    AND account_id IN (SELECT current_account_ids())
  );

-- ============================================================
-- TABLA: operation_idempotency
-- Policies viejas: operation_idempotency_select
-- NOTA: Solo existía SELECT. Se agrega cobertura completa.
-- ============================================================
DROP POLICY IF EXISTS "operation_idempotency_select" ON public.operation_idempotency;

CREATE POLICY "operation_idempotency_account_select" ON public.operation_idempotency
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "operation_idempotency_account_insert" ON public.operation_idempotency
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "operation_idempotency_account_update" ON public.operation_idempotency
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "operation_idempotency_account_delete" ON public.operation_idempotency
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: ai_insights
-- Policies viejas: ai_insights_select, ai_insights_insert, ai_insights_delete
-- NOTA: No existía UPDATE — se agrega por completitud.
-- ============================================================
DROP POLICY IF EXISTS "ai_insights_select" ON public.ai_insights;
DROP POLICY IF EXISTS "ai_insights_insert" ON public.ai_insights;
DROP POLICY IF EXISTS "ai_insights_delete" ON public.ai_insights;

CREATE POLICY "ai_insights_account_select" ON public.ai_insights
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_insights_account_insert" ON public.ai_insights
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_insights_account_update" ON public.ai_insights
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_insights_account_delete" ON public.ai_insights
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: ai_conversations
-- Policies viejas: ai_conversations_select, ai_conversations_insert,
--                  ai_conversations_delete
-- NOTA: No existía UPDATE — se agrega por completitud.
-- ============================================================
DROP POLICY IF EXISTS "ai_conversations_select" ON public.ai_conversations;
DROP POLICY IF EXISTS "ai_conversations_insert" ON public.ai_conversations;
DROP POLICY IF EXISTS "ai_conversations_delete" ON public.ai_conversations;

CREATE POLICY "ai_conversations_account_select" ON public.ai_conversations
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_conversations_account_insert" ON public.ai_conversations
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_conversations_account_update" ON public.ai_conversations
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "ai_conversations_account_delete" ON public.ai_conversations
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: fair_recommendations
-- Policies viejas: fair_rec_select, fair_rec_insert
-- NOTA: No existía UPDATE/DELETE — se agrega por completitud.
-- ============================================================
DROP POLICY IF EXISTS "fair_rec_select" ON public.fair_recommendations;
DROP POLICY IF EXISTS "fair_rec_insert" ON public.fair_recommendations;

CREATE POLICY "fair_recommendations_account_select" ON public.fair_recommendations
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "fair_recommendations_account_insert" ON public.fair_recommendations
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "fair_recommendations_account_update" ON public.fair_recommendations
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "fair_recommendations_account_delete" ON public.fair_recommendations
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: invoice_documents
-- Policies viejas: invoice_documents_select, invoice_documents_insert,
--                  invoice_documents_update, invoice_documents_delete
-- ============================================================
DROP POLICY IF EXISTS "invoice_documents_select" ON public.invoice_documents;
DROP POLICY IF EXISTS "invoice_documents_insert" ON public.invoice_documents;
DROP POLICY IF EXISTS "invoice_documents_update" ON public.invoice_documents;
DROP POLICY IF EXISTS "invoice_documents_delete" ON public.invoice_documents;

CREATE POLICY "invoice_documents_account_select" ON public.invoice_documents
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_documents_account_insert" ON public.invoice_documents
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_documents_account_update" ON public.invoice_documents
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_documents_account_delete" ON public.invoice_documents
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: invoice_suppliers
-- Policies viejas: invoice_suppliers_all (ALL cmd)
-- ============================================================
DROP POLICY IF EXISTS "invoice_suppliers_all" ON public.invoice_suppliers;

CREATE POLICY "invoice_suppliers_account_select" ON public.invoice_suppliers
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_suppliers_account_insert" ON public.invoice_suppliers
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_suppliers_account_update" ON public.invoice_suppliers
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "invoice_suppliers_account_delete" ON public.invoice_suppliers
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: product_aliases
-- Policies viejas: product_aliases_all (ALL cmd)
-- ============================================================
DROP POLICY IF EXISTS "product_aliases_all" ON public.product_aliases;

CREATE POLICY "product_aliases_account_select" ON public.product_aliases
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "product_aliases_account_insert" ON public.product_aliases
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "product_aliases_account_update" ON public.product_aliases
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "product_aliases_account_delete" ON public.product_aliases
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- TABLA: course_progress
-- Policies viejas: "Users can do all to own course progress" (ALL cmd)
-- ============================================================
DROP POLICY IF EXISTS "Users can do all to own course progress" ON public.course_progress;

CREATE POLICY "course_progress_account_select" ON public.course_progress
  FOR SELECT TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "course_progress_account_insert" ON public.course_progress
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "course_progress_account_update" ON public.course_progress
  FOR UPDATE TO authenticated
  USING (account_id IN (SELECT current_account_ids()))
  WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "course_progress_account_delete" ON public.course_progress
  FOR DELETE TO authenticated
  USING (account_id IN (SELECT current_account_ids()));

-- ============================================================
-- Task 4.2 — posts / replies: NO se migran (comunidad global per-usuario)
-- ============================================================

-- ============================================================
-- Task 4.4 — SQL de verificación de aislamiento post-push
-- (Ejecutar después de aplicar la migration con npx supabase db push)
-- ============================================================
-- SELECT 'products' as tabla, count(*) as huerfanas
-- FROM products p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'sales', count(*) FROM sales p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'purchases', count(*) FROM purchases p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'expenses', count(*) FROM expenses p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'clients', count(*) FROM clients p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'stock_movements', count(*) FROM stock_movements p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'ai_insights', count(*) FROM ai_insights p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'ai_conversations', count(*) FROM ai_conversations p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'fair_recommendations', count(*) FROM fair_recommendations p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'invoice_documents', count(*) FROM invoice_documents p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'invoice_suppliers', count(*) FROM invoice_suppliers p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'product_aliases', count(*) FROM product_aliases p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'course_progress', count(*) FROM course_progress p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL
-- UNION ALL
-- SELECT 'operation_idempotency', count(*) FROM operation_idempotency p
-- WHERE NOT EXISTS (SELECT 1 FROM account_members am WHERE am.account_id = p.account_id)
--   AND p.account_id IS NOT NULL;
