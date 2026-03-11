-- 1. Dynamically drop ALL existing policies on the affected tables to ensure NO recursive policy remains.
DO $$
DECLARE
    pol record;
BEGIN
    FOR pol IN (SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('company_users', 'companies', 'warehouses'))
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
    END LOOP;
END
$$;

-- 2. Create the non-recursive policies for company_users
CREATE POLICY "cu_select" ON public.company_users
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "cu_insert" ON public.company_users
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "cu_update" ON public.company_users
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "cu_delete" ON public.company_users
  FOR DELETE USING (user_id = auth.uid());

-- 3. Create the direct non-recursive policies for companies
CREATE POLICY "companies_select" ON public.companies
  FOR SELECT USING (
    id IN (SELECT company_id FROM public.company_users WHERE user_id = auth.uid())
  );

CREATE POLICY "companies_insert" ON public.companies
  FOR INSERT WITH CHECK (true);

CREATE POLICY "companies_update" ON public.companies
  FOR UPDATE USING (
    id IN (SELECT company_id FROM public.company_users WHERE user_id = auth.uid())
  );

-- 4. Create the direct non-recursive policies for warehouses
CREATE POLICY "warehouses_select" ON public.warehouses
  FOR SELECT USING (
    company_id IN (SELECT company_id FROM public.company_users WHERE user_id = auth.uid())
  );

CREATE POLICY "warehouses_insert" ON public.warehouses
  FOR INSERT WITH CHECK (
    company_id IN (SELECT company_id FROM public.company_users WHERE user_id = auth.uid())
  );

CREATE POLICY "warehouses_update" ON public.warehouses
  FOR UPDATE USING (
    company_id IN (SELECT company_id FROM public.company_users WHERE user_id = auth.uid())
  );
