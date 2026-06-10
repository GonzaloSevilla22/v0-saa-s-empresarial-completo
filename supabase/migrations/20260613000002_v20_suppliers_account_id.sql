-- ============================================================
-- v20-tenancy-cleanup — Task 2.3 + 2.4
-- Agregar account_id a suppliers
--
-- Estado antes de esta migration (relevado 2026-06-09):
--   suppliers: 0 filas (tabla vacía)
--   suppliers.company_id: NOT NULL FK → companies.id
--
-- La columna se agrega nullable para zero-downtime.
-- El backfill via company_id → accounts es un no-op (tabla vacía).
-- NOT NULL constraint se agrega en el paso 8 (post-validación).
-- ============================================================

-- 2.3 Agregar columna account_id a suppliers (nullable)
ALTER TABLE public.suppliers
    ADD COLUMN IF NOT EXISTS account_id UUID REFERENCES public.accounts(id);

-- 2.4 Backfill: mapear company_id → account_id via company_users → account_members
-- (No-op para la tabla actual vacía, pero idempotente si se agregan filas antes del deploy)
UPDATE public.suppliers s
SET account_id = (
    SELECT am.account_id
    FROM public.company_users cu
    JOIN public.account_members am ON am.user_id = cu.user_id
    WHERE cu.company_id = s.company_id
    LIMIT 1
)
WHERE s.account_id IS NULL
  AND s.company_id IS NOT NULL;

-- Índice para RLS (mismo patrón que las otras tablas ERP)
CREATE INDEX IF NOT EXISTS idx_suppliers_account_id
    ON public.suppliers (account_id);
