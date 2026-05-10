-- =============================================================================
-- MIGRATION: 20260509214856_etapa3_backfill_base_unit_id.sql
-- DESCRIPTION: Etapa 3 — Backfill base_unit_id on existing products.
--              Assigns the default "Unidad" system unit (type='unit', factor=1)
--              to products that have stock_control_type = 'tracked' and no
--              base_unit_id yet. Untracked and variant_only products are skipped.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509214856
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

DO $$
DECLARE
  v_unit_id uuid;
BEGIN
  -- Find the canonical base unit for discrete items
  SELECT id INTO v_unit_id
  FROM public.units_of_measure
  WHERE type = 'unit' AND symbol = 'u' AND is_system = true
  LIMIT 1;

  IF v_unit_id IS NOT NULL THEN
    UPDATE public.products
    SET base_unit_id = v_unit_id
    WHERE stock_control_type = 'tracked'
      AND base_unit_id IS NULL;
  END IF;
END;
$$;
