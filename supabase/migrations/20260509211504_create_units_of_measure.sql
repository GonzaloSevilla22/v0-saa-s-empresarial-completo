-- =============================================================================
-- MIGRATION: 20260509211504_create_units_of_measure.sql
-- DESCRIPTION: Etapa 1 — Tabla de unidades de medida + columnas en products
--
-- 100% aditiva: no modifica datos existentes, no rompe queries actuales.
-- Todos los productos existentes quedan con base_unit_id = NULL y
-- stock_control_type = 'tracked' (valor DEFAULT).
--
-- Cambios:
--   1. CREATE TABLE units_of_measure + unique indexes + RLS
--   2. Seed de 10 unidades del sistema (UUIDs fijos para referenciar en código)
--   3. ALTER TABLE products:
--        ADD COLUMN base_unit_id       uuid → FK a units_of_measure (nullable)
--        ADD COLUMN stock_control_type text → DEFAULT 'tracked' (NOT NULL)
--
-- Rollback:
--   ALTER TABLE public.products
--     DROP COLUMN IF EXISTS base_unit_id,
--     DROP COLUMN IF EXISTS stock_control_type;
--   DROP TABLE IF EXISTS public.units_of_measure;
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509211504
-- =============================================================================

-- ── 1. Tabla units_of_measure ────────────────────────────────────────────────
CREATE TABLE public.units_of_measure (
  id           uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid           REFERENCES auth.users(id) ON DELETE CASCADE,
  -- NULL = unidad del sistema, disponible para todos los usuarios
  name         text           NOT NULL,
  symbol       text           NOT NULL,
  type         text           NOT NULL
    CHECK (type IN ('unit', 'weight', 'volume', 'length', 'custom')),
  factor       NUMERIC(20,10) NOT NULL DEFAULT 1.0,
  -- factor de conversión hacia la unidad base del mismo tipo
  -- ej: 1g = 0.001 kg → factor = 0.001 | unidad base → factor = 1.0
  base_unit_id uuid           REFERENCES public.units_of_measure(id),
  -- NULL = esta ES la unidad base del tipo
  is_system    boolean        NOT NULL DEFAULT false,
  created_at   timestamptz    NOT NULL DEFAULT now()
);

-- Unique indexes: símbolos únicos por sistema y por usuario (por separado)
-- Sistema: no puede haber dos unidades sistema con el mismo símbolo
CREATE UNIQUE INDEX idx_uom_system_symbol
  ON public.units_of_measure(symbol)
  WHERE user_id IS NULL;

-- Usuario: dentro del mismo usuario no puede haber dos unidades con el mismo símbolo
CREATE UNIQUE INDEX idx_uom_user_symbol
  ON public.units_of_measure(user_id, symbol)
  WHERE user_id IS NOT NULL;

-- Índice de soporte para el FK self-referencial
CREATE INDEX idx_uom_base_unit
  ON public.units_of_measure(base_unit_id)
  WHERE base_unit_id IS NOT NULL;

-- ── 2. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.units_of_measure ENABLE ROW LEVEL SECURITY;

-- Lectura: unidades del sistema (is_system = true) + propias
CREATE POLICY "uom_select"
  ON public.units_of_measure FOR SELECT
  USING (is_system = true OR user_id = auth.uid());

-- Insertar: solo unidades propias (nunca sistema desde el cliente)
CREATE POLICY "uom_insert"
  ON public.units_of_measure FOR INSERT
  WITH CHECK (user_id = auth.uid() AND is_system = false);

-- Actualizar: solo unidades propias
CREATE POLICY "uom_update"
  ON public.units_of_measure FOR UPDATE
  USING (user_id = auth.uid() AND is_system = false)
  WITH CHECK (user_id = auth.uid() AND is_system = false);

-- Eliminar: solo unidades propias
CREATE POLICY "uom_delete"
  ON public.units_of_measure FOR DELETE
  USING (user_id = auth.uid() AND is_system = false);

-- ── 3. Seed — unidades del sistema ───────────────────────────────────────────
-- UUIDs fijos para poder referenciarlos desde código sin necesidad de query.
-- Convención de namespace: 00000000-0000-0000-0001-<número>

INSERT INTO public.units_of_measure
  (id, user_id, name, symbol, type, factor, base_unit_id, is_system)
VALUES
  -- ── Unidades base (factor = 1.0, base_unit_id = NULL) ──────────────────────
  (
    '00000000-0000-0000-0001-000000000001', NULL,
    'Unidad', 'u', 'unit', 1.0, NULL, true
  ),
  (
    '00000000-0000-0000-0001-000000000002', NULL,
    'Kilogramo', 'kg', 'weight', 1.0, NULL, true
  ),
  (
    '00000000-0000-0000-0001-000000000003', NULL,
    'Litro', 'L', 'volume', 1.0, NULL, true
  ),
  (
    '00000000-0000-0000-0001-000000000004', NULL,
    'Metro', 'm', 'length', 1.0, NULL, true
  ),
  -- ── Derivadas de peso ───────────────────────────────────────────────────────
  (
    '00000000-0000-0000-0001-000000000010', NULL,
    'Gramo', 'g', 'weight', 0.001,
    '00000000-0000-0000-0001-000000000002', true
  ),
  (
    '00000000-0000-0000-0001-000000000011', NULL,
    'Tonelada', 'tn', 'weight', 1000.0,
    '00000000-0000-0000-0001-000000000002', true
  ),
  -- ── Derivadas de volumen ────────────────────────────────────────────────────
  (
    '00000000-0000-0000-0001-000000000012', NULL,
    'Mililitro', 'mL', 'volume', 0.001,
    '00000000-0000-0000-0001-000000000003', true
  ),
  -- ── Derivadas de unidad ─────────────────────────────────────────────────────
  (
    '00000000-0000-0000-0001-000000000013', NULL,
    'Docena', 'doc', 'unit', 12.0,
    '00000000-0000-0000-0001-000000000001', true
  ),
  (
    '00000000-0000-0000-0001-000000000014', NULL,
    'Caja x 6', 'cj6', 'unit', 6.0,
    '00000000-0000-0000-0001-000000000001', true
  ),
  -- ── Derivadas de longitud ───────────────────────────────────────────────────
  (
    '00000000-0000-0000-0001-000000000015', NULL,
    'Centímetro', 'cm', 'length', 0.01,
    '00000000-0000-0000-0001-000000000004', true
  );

-- ── 4. Nuevas columnas en products (ambas opcionales / nullables) ─────────────
-- base_unit_id: FK a la unidad de medida base del producto.
--   NULL = producto sin unidad asignada (estado actual de todos los productos).
--   Se asignará masivamente en Etapa 5 (backfill + UI de onboarding).

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS base_unit_id uuid
    REFERENCES public.units_of_measure(id);

-- stock_control_type: determina cómo se gestiona el stock del producto.
--   'tracked'      → físico, el stock se cuenta y descuenta (default para todos)
--   'untracked'    → servicio o digital, el stock nunca cambia
--   'variant_only' → producto padre con variantes, sin stock propio

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS stock_control_type text
    NOT NULL DEFAULT 'tracked'
    CHECK (stock_control_type IN ('tracked', 'untracked', 'variant_only'));

-- Índice para filtrar por unidad (queries de catálogo multi-unidad — Etapa 3+)
CREATE INDEX idx_products_base_unit
  ON public.products(base_unit_id)
  WHERE base_unit_id IS NOT NULL;
