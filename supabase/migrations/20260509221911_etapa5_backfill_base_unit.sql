-- =============================================================================
-- MIGRATION: 20260509221911_etapa5_backfill_base_unit.sql
-- DESCRIPTION: Etapa 5 — Backfill base_unit_id + stock_control_type
--
-- Completa los nuevos campos que quedaron NULL tras Etapa 1 (additive).
-- Opera en 2 pasos para respetar la dependencia entre ellos:
--
--   PASO 1 — stock_control_type = 'variant_only'
--     Para todos los productos que funcionan como "catálogo padre" (tienen al
--     menos un hijo con parent_id apuntando a ellos).  Su stock siempre es 0
--     y no tiene sentido asignarles stock propio ni unidad de medida.
--
--   PASO 2 — base_unit_id = 'Unidad' (u)
--     Para todos los productos con stock_control_type = 'tracked' que todavía
--     no tienen unidad asignada. La unidad "Unidad" (UUID fijo 0001) es el
--     denominador común correcto para el catálogo actual (productos vendidos
--     por pieza). Los usuarios podrán cambiar esto por producto desde la UI.
--
-- Impacto:
--   · No modifica datos de ventas ni compras — solo metadatos de producto.
--   · Rollback: UPDATE products SET stock_control_type='tracked', base_unit_id=NULL;
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509221911
-- =============================================================================

-- ── PASO 1: Marcar padres como variant_only ───────────────────────────────────
UPDATE public.products
SET stock_control_type = 'variant_only'
WHERE stock_control_type = 'tracked'
  AND id IN (
    SELECT DISTINCT parent_id
    FROM   public.products
    WHERE  parent_id IS NOT NULL
  );

-- ── PASO 2: Asignar Unidad (u) como base a todos los productos tracked ─────────
-- UUIDs fijos del seed de Etapa 1:
--   '00000000-0000-0000-0001-000000000001' → Unidad (u, factor=1)
UPDATE public.products
SET base_unit_id = '00000000-0000-0000-0001-000000000001'
WHERE base_unit_id IS NULL
  AND stock_control_type = 'tracked';

-- ── Verificación inline ───────────────────────────────────────────────────────
-- Ejecutar manualmente para confirmar:
--   SELECT stock_control_type, COUNT(*) FROM public.products GROUP BY 1;
--   SELECT
--     COUNT(*) FILTER (WHERE base_unit_id IS NOT NULL) AS with_unit,
--     COUNT(*) FILTER (WHERE base_unit_id IS NULL)     AS without_unit
--   FROM public.products;
