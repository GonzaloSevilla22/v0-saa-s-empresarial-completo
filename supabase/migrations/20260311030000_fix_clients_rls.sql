-- Fix: Clients RLS for multi-tenant SaaS architecture
-- Drops existing policies and creates new ones based on company_users

ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "clients_select" ON public.clients;
DROP POLICY IF EXISTS "clients_insert" ON public.clients;
DROP POLICY IF EXISTS "clients_update" ON public.clients;
DROP POLICY IF EXISTS "clients_delete" ON public.clients;

-- Drop potential old policies
DROP POLICY IF EXISTS "Users can view their own clients" ON public.clients;
DROP POLICY IF EXISTS "Users can create their own clients" ON public.clients;
DROP POLICY IF EXISTS "Users can update their own clients" ON public.clients;
DROP POLICY IF EXISTS "Users can delete their own clients" ON public.clients;

CREATE POLICY "clients_select" ON public.clients
  FOR SELECT USING (
    company_id IN (
      SELECT company_id FROM public.company_users WHERE user_id = auth.uid()
    )
    OR user_id = auth.uid()
  );

CREATE POLICY "clients_insert" ON public.clients
  FOR INSERT WITH CHECK (
    company_id IN (
      SELECT company_id FROM public.company_users WHERE user_id = auth.uid()
    )
    OR user_id = auth.uid()
  );

CREATE POLICY "clients_update" ON public.clients
  FOR UPDATE USING (
    company_id IN (
      SELECT company_id FROM public.company_users WHERE user_id = auth.uid()
    )
    OR user_id = auth.uid()
  );

CREATE POLICY "clients_delete" ON public.clients
  FOR DELETE USING (
    company_id IN (
      SELECT company_id FROM public.company_users WHERE user_id = auth.uid()
    )
    OR user_id = auth.uid()
  );
