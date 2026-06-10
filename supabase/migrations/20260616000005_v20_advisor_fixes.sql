-- =============================================================================
-- MIGRATION: 20260616000005_v20_advisor_fixes.sql
-- C-20 v20-sale-items-migration — Grupo 1.6 / 5.4: Advisor fixes (performance)
--
-- Hallazgos del get_advisors tras Migración A:
--
-- 1. duplicate_index (WARN):
--    {idx_sale_items_sale, idx_sale_items_sale_id}       → drop idx_sale_items_sale_id  (duplica uno preexistente)
--    {idx_purchase_items_purchase, idx_purchase_items_purchase_id} → drop idx_purchase_items_purchase_id (ídem)
--
-- 2. unindexed_foreign_keys (INFO):
--    sale_items.product_id_fkey       → agregar índice en (product_id)
--    sale_items.unit_id_fkey          → agregar índice en (unit_id)
--    purchase_items.product_id_fkey   → agregar índice en (product_id)
--    purchase_items.unit_id_fkey      → agregar índice en (unit_id)
--
-- Nota: los hallazgos de security (authenticated_security_definer_function_executable)
-- en rpc_create_sale_operation / rpc_create_purchase_operation son INTENCIONALES
-- (SECURITY DEFINER requerido para gestión de stock + RLS). Sin acción.
--
-- Rollback: DROP los índices de FK + re-crear los duplicados si fuera necesario.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Eliminar índices duplicados (el preexistente sin sufijo _id se conserva)
-- ─────────────────────────────────────────────────────────────────────────────

DROP INDEX IF EXISTS public.idx_sale_items_sale_id;
DROP INDEX IF EXISTS public.idx_purchase_items_purchase_id;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Índices cubrientes para FKs sin índice (mejora JOINs por product_id y unit_id)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_sale_items_product_id
    ON public.sale_items (product_id)
    WHERE product_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sale_items_unit_id
    ON public.sale_items (unit_id)
    WHERE unit_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_purchase_items_product_id
    ON public.purchase_items (product_id)
    WHERE product_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_purchase_items_unit_id
    ON public.purchase_items (unit_id)
    WHERE unit_id IS NOT NULL;
