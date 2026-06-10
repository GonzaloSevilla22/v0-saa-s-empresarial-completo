-- =============================================================================
-- MIGRATION: 20260616000004_v20_compat_views.sql
-- C-20 v20-sale-items-migration — Grupo 5: Vistas de compatibilidad
--
-- v_sales_flat y v_purchases_flat reconstruyen las columnas planas desde el
-- JOIN con sale_items/purchase_items.
--
-- OQ3 (resuelto por PO): CONSERVAR — estas vistas se mantienen permanentemente
-- post-DROP para las Edge Functions de IA (DEC-15).
--
-- CRÍTICO: security_invoker = true — sin esto la vista bypasaría RLS y filtraría
-- datos cross-tenant. Postgres 15+ required.
--
-- Rollback: DROP VIEW IF EXISTS public.v_sales_flat; DROP VIEW IF EXISTS public.v_purchases_flat;
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.3 v_sales_flat — columnas planas desde JOIN sale_items
-- ─────────────────────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS public.v_sales_flat;

CREATE OR REPLACE VIEW public.v_sales_flat
WITH (security_invoker = true)
AS
SELECT
  s.id,
  s.user_id,
  s.account_id,
  s.client_id,
  s.operation_id,
  s.date,
  s.currency,
  s.canal,
  s.branch_id,
  -- Columnas planas reconstruidas desde sale_items
  si.product_id,
  si.price       AS amount,
  si.quantity,
  si.subtotal    AS total,
  si.unit_id
FROM public.sales s
LEFT JOIN public.sale_items si ON si.sale_id = s.id AND si.product_id IS NOT NULL;

COMMENT ON VIEW public.v_sales_flat IS
  'Vista de compatibilidad. Reconstruye las columnas planas (product_id, amount, quantity, total, unit_id) '
  'desde sale_items para consumidores legacy (EFs de IA). OQ3: CONSERVAR permanentemente post-DROP (DEC-15). '
  'security_invoker=true garantiza que RLS de la sesión se aplica — no bypasear.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.3 v_purchases_flat — simétrico para compras
-- ─────────────────────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS public.v_purchases_flat;

CREATE OR REPLACE VIEW public.v_purchases_flat
WITH (security_invoker = true)
AS
SELECT
  p.id,
  p.user_id,
  p.account_id,
  p.operation_id,
  p.date,
  p.description,
  -- Columnas planas reconstruidas desde purchase_items
  pi2.product_id,
  pi2.price      AS amount,
  pi2.quantity,
  pi2.subtotal   AS total,
  pi2.unit_id
FROM public.purchases p
LEFT JOIN public.purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL;

COMMENT ON VIEW public.v_purchases_flat IS
  'Vista de compatibilidad. Reconstruye las columnas planas desde purchase_items. '
  'OQ3: CONSERVAR permanentemente post-DROP. security_invoker=true.';
