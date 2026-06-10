-- ============================================================
-- v20-tenancy-cleanup — Task 3.1
-- Agregar RLS a suppliers usando account_id
--
-- suppliers tenía solo company_id para tenancy, sin RLS por account_id.
-- Esta migration cierra el agujero de seguridad:
-- usuario A no debe ver suppliers del tenant B.
--
-- Patrón idéntico al de las otras tablas ERP (migration 20260606000004).
-- ============================================================

-- Eliminar políticas legacy de suppliers (basadas en company_id si existen)
DROP POLICY IF EXISTS "suppliers_select"            ON public.suppliers;
DROP POLICY IF EXISTS "suppliers_insert"            ON public.suppliers;
DROP POLICY IF EXISTS "suppliers_update"            ON public.suppliers;
DROP POLICY IF EXISTS "suppliers_delete"            ON public.suppliers;
DROP POLICY IF EXISTS "company_users_suppliers_access" ON public.suppliers;

-- Habilitar RLS si no estaba activo (por precaución)
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

-- Políticas basadas en account_id
CREATE POLICY "suppliers_account_select" ON public.suppliers
    FOR SELECT TO authenticated
    USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY "suppliers_account_insert" ON public.suppliers
    FOR INSERT TO authenticated
    WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "suppliers_account_update" ON public.suppliers
    FOR UPDATE TO authenticated
    USING  (account_id IN (SELECT current_account_ids()))
    WITH CHECK (account_id IN (SELECT current_account_ids()));

CREATE POLICY "suppliers_account_delete" ON public.suppliers
    FOR DELETE TO authenticated
    USING (account_id IN (SELECT current_account_ids()));
