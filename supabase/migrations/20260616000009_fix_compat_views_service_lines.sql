-- =============================================================================
-- MIGRATION: 20260616000009_fix_compat_views_service_lines.sql
-- HOTFIX C-20 (3/3) — incidente post-merge PR #153 (2026-06-10)
--
-- ROOT CAUSE:
--   v_sales_flat / v_purchases_flat (20260616000004) reconstruyen las columnas
--   planas SOLO desde sale_items/purchase_items. Las líneas de servicio
--   (product_id IS NULL en el header) no tienen fila de ítem — ni el backfill
--   (filtró product_id NOT NULL) ni los RPC v2 (la rama ELSE no inserta ítem)
--   las cubren. Resultado: esas filas salen con amount/quantity/total NULL y
--   los consumidores (EFs de IA con SUM, repos del backend con Pydantic
--   Decimal no-opcional) fallan o pierden datos en silencio.
--   Cuenta principal afectada: 3 ventas + 3 compras de servicio.
--
-- FIX:
--   COALESCE al header flat, que sigue poblado: la doble escritura (OQ2) lo
--   mantiene para filas nuevas y las filas legacy lo tienen por definición.
--
-- NOTA PARA EL CHECKPOINT GRUPO 10 (DROP del header):
--   Antes del DROP hay que decidir cómo representar líneas de servicio en
--   sale_items/purchase_items (hoy product_id NULL está reservado para filas
--   de variantes del importador). Hasta entonces, este COALESCE es la fuente
--   de verdad para servicios — el DROP NO puede ejecutarse sin resolver esto.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- v_sales_flat — con fallback al header para filas sin ítem
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
  -- Ítem si existe; header flat como fallback (líneas de servicio / transición)
  COALESCE(si.product_id, s.product_id) AS product_id,
  COALESCE(si.price,      s.amount)     AS amount,
  COALESCE(si.quantity,   s.quantity)   AS quantity,
  COALESCE(si.subtotal,   s.total)      AS total,
  COALESCE(si.unit_id,    s.unit_id)    AS unit_id
FROM public.sales s
LEFT JOIN public.sale_items si ON si.sale_id = s.id AND si.product_id IS NOT NULL;

COMMENT ON VIEW public.v_sales_flat IS
  'Vista de compatibilidad. Columnas planas desde sale_items con COALESCE al header '
  '(líneas de servicio sin fila de ítem — ver 20260616000009). OQ3: CONSERVAR post-DROP (DEC-15). '
  'security_invoker=true garantiza que RLS de la sesión se aplica — no bypasear.';

-- ─────────────────────────────────────────────────────────────────────────────
-- v_purchases_flat — simétrico
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
  COALESCE(pi2.product_id, p.product_id) AS product_id,
  COALESCE(pi2.price,      p.amount)     AS amount,
  COALESCE(pi2.quantity,   p.quantity)   AS quantity,
  COALESCE(pi2.subtotal,   p.total)      AS total,
  COALESCE(pi2.unit_id,    p.unit_id)    AS unit_id
FROM public.purchases p
LEFT JOIN public.purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL;

COMMENT ON VIEW public.v_purchases_flat IS
  'Vista de compatibilidad. Columnas planas desde purchase_items con COALESCE al header '
  '(ver 20260616000009). OQ3: CONSERVAR post-DROP. security_invoker=true.';
