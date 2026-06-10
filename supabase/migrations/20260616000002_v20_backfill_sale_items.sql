-- =============================================================================
-- MIGRATION: 20260616000002_v20_backfill_sale_items.sql
-- C-20 v20-sale-items-migration — Grupo 2: Backfill idempotente
--
-- Backfill 1:1 de sales → sale_items y purchases → purchase_items.
-- Idempotente: INSERT ... WHERE NOT EXISTS + índice único parcial garantizan
-- que re-ejecutar no duplica filas.
-- Las 23+18 filas de variantes preexistentes (product_id IS NULL) no se tocan.
--
-- GOVERNANCE ALTO. Aprobación PO: 2026-06-10.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.4 Backfill sale_items desde sales
-- ─────────────────────────────────────────────────────────────────────────────
-- Mapeo: price = amount, subtotal = COALESCE(total, amount*quantity), variant_id = NULL
-- Solo inserta donde product_id IS NOT NULL y no existe ya una fila con ese (sale_id, product_id)
-- (el índice único parcial idx_sale_items_sale_product_unique ya lo garantiza a nivel DB)

INSERT INTO public.sale_items (
  sale_id,
  product_id,
  account_id,
  variant_id,
  quantity,
  unit_id,
  price,
  subtotal
)
SELECT
  s.id                                         AS sale_id,
  s.product_id,
  s.account_id,
  NULL                                         AS variant_id,
  s.quantity                                   AS quantity,
  s.unit_id,
  s.amount                                     AS price,
  COALESCE(s.total, s.amount * s.quantity)     AS subtotal
FROM public.sales s
WHERE s.product_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.sale_items si
    WHERE si.sale_id = s.id
      AND si.product_id = s.product_id
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.5 Backfill purchase_items desde purchases (simétrico)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public.purchase_items (
  purchase_id,
  product_id,
  account_id,
  variant_id,
  quantity,
  unit_id,
  price,
  subtotal
)
SELECT
  p.id                                         AS purchase_id,
  p.product_id,
  p.account_id,
  NULL                                         AS variant_id,
  p.quantity                                   AS quantity,
  p.unit_id,
  p.amount                                     AS price,
  COALESCE(p.total, p.amount * p.quantity)     AS subtotal
FROM public.purchases p
WHERE p.product_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.purchase_items pi
    WHERE pi.purchase_id = p.id
      AND pi.product_id = p.product_id
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.6 Query de validación post-backfill (documentada)
-- Ejecutar manualmente o via SQL read-only para verificar:
--
--   SELECT
--     (SELECT count(*) FROM public.sales WHERE product_id IS NOT NULL)           AS sales_with_product,
--     (SELECT count(*) FROM public.sale_items WHERE product_id IS NOT NULL)       AS sale_items_with_product,
--     (SELECT count(*) FROM public.purchases WHERE product_id IS NOT NULL)        AS purchases_with_product,
--     (SELECT count(*) FROM public.purchase_items WHERE product_id IS NOT NULL)   AS purchase_items_with_product;
--
-- Resultado esperado:
--   sales_with_product = sale_items_with_product (133 = 133)
--   purchases_with_product = purchase_items_with_product (181 = 181)
--
-- También verificar que las filas de variantes no se tocaron:
--   SELECT count(*) FROM public.sale_items WHERE variant_id IS NOT NULL;   -- debe ser 23
--   SELECT count(*) FROM public.purchase_items WHERE variant_id IS NOT NULL; -- debe ser 18
--
-- Y las 2 ventas fraccionales:
--   SELECT quantity FROM public.sale_items WHERE sale_id IN (
--     '83a41d9c-1f99-4141-947a-925f4cad2891',
--     '85299ad9-d7dd-4c7c-849e-d514b3aa4a5f'
--   );  -- debe devolver 0.5000 y 0.3500
-- =============================================================================
