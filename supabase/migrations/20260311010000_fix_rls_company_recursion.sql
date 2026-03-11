-- Fix: infinite recursion in RLS policy for company_users
-- The old policy likely did: company_id IN (SELECT company_id FROM company_users WHERE user_id = auth.uid())
-- which causes infinite recursion. Replace with direct user_id check.

-- ===== company_users =====
DROP POLICY IF EXISTS "company_users_select" ON company_users;
DROP POLICY IF EXISTS "company_users_insert" ON company_users;
DROP POLICY IF EXISTS "company_users_update" ON company_users;
DROP POLICY IF EXISTS "company_users_delete" ON company_users;
DROP POLICY IF EXISTS "Users can view their company_users" ON company_users;
DROP POLICY IF EXISTS "Users can manage their company_users" ON company_users;

-- Simple non-recursive policy: users can only see their own rows
CREATE POLICY "cu_select" ON company_users
  FOR SELECT USING (user_id = auth.uid());

-- Only allow insertions where the user_id matches the authenticated user
CREATE POLICY "cu_insert" ON company_users
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "cu_update" ON company_users
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "cu_delete" ON company_users
  FOR DELETE USING (user_id = auth.uid());

-- ===== companies =====
-- Allow users to read the company they belong to
-- Use a security definer function to avoid recursion when looking up company_id
DROP POLICY IF EXISTS "companies_select" ON companies;
DROP POLICY IF EXISTS "Users can view their company" ON companies;
DROP POLICY IF EXISTS "companies_read" ON companies;

-- Use auth.uid() based lookup via subquery but on company_users (non-recursive since company_users policies only check user_id)
CREATE POLICY "companies_select" ON companies
  FOR SELECT USING (
    id IN (
      SELECT company_id FROM company_users WHERE user_id = auth.uid()
    )
  );

-- Allow insert (needed when creating a new company)
DROP POLICY IF EXISTS "companies_insert" ON companies;
CREATE POLICY "companies_insert" ON companies
  FOR INSERT WITH CHECK (true);

-- Allow update only if user belongs to that company
DROP POLICY IF EXISTS "companies_update" ON companies;
CREATE POLICY "companies_update" ON companies
  FOR UPDATE USING (
    id IN (
      SELECT company_id FROM company_users WHERE user_id = auth.uid()
    )
  );

-- ===== warehouses =====
-- Ensure warehouses follows the same pattern
DROP POLICY IF EXISTS "warehouses_select" ON warehouses;
DROP POLICY IF EXISTS "Users can view their warehouses" ON warehouses;

CREATE POLICY "warehouses_select" ON warehouses
  FOR SELECT USING (
    company_id IN (
      SELECT company_id FROM company_users WHERE user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "warehouses_insert" ON warehouses;
CREATE POLICY "warehouses_insert" ON warehouses
  FOR INSERT WITH CHECK (
    company_id IN (
      SELECT company_id FROM company_users WHERE user_id = auth.uid()
    )
  );
