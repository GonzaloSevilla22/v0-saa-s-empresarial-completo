-- =============================================================================
-- MIGRATION: 20260509211504_etapa2_units_of_measure_table.sql
-- DESCRIPTION: Etapa 2 — Create units_of_measure table with system units seed.
--              Supports unit types: unit, weight, volume, length, custom.
--              System units (is_system = true) visible to all users via RLS.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509211504
-- This file is a documentation stub — the migration was already applied.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.units_of_measure (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  symbol       text NOT NULL,
  type         text NOT NULL
    CONSTRAINT units_type_check
    CHECK (type IN ('unit', 'weight', 'volume', 'length', 'custom')),
  factor       NUMERIC(15,6) NOT NULL DEFAULT 1,
  base_unit_id uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL,
  user_id      uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  is_system    boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- RLS
ALTER TABLE public.units_of_measure ENABLE ROW LEVEL SECURITY;

CREATE POLICY "units_select_system_or_own" ON public.units_of_measure
  FOR SELECT USING (is_system = true OR auth.uid() = user_id);

CREATE POLICY "units_insert_own" ON public.units_of_measure
  FOR INSERT WITH CHECK (auth.uid() = user_id AND is_system = false);

CREATE POLICY "units_update_own" ON public.units_of_measure
  FOR UPDATE USING (auth.uid() = user_id AND is_system = false);

CREATE POLICY "units_delete_own" ON public.units_of_measure
  FOR DELETE USING (auth.uid() = user_id AND is_system = false);

-- System units seed
INSERT INTO public.units_of_measure (name, symbol, type, factor, is_system) VALUES
  ('Unidad',      'u',    'unit',   1,       true),
  ('Docena',      'doc',  'unit',   12,      true),
  ('Ciento',      'cto',  'unit',   100,     true),
  ('Gramo',       'g',    'weight', 1,       true),
  ('Kilogramo',   'kg',   'weight', 1000,    true),
  ('Tonelada',    'tn',   'weight', 1000000, true),
  ('Mililitro',   'mL',   'volume', 1,       true),
  ('Litro',       'L',    'volume', 1000,    true),
  ('Milímetro',   'mm',   'length', 1,       true),
  ('Centímetro',  'cm',   'length', 10,      true),
  ('Metro',       'm',    'length', 1000,    true)
ON CONFLICT DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_units_type     ON public.units_of_measure(type);
CREATE INDEX IF NOT EXISTS idx_units_user_id  ON public.units_of_measure(user_id);
