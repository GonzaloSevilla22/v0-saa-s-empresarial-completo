-- =============================================================================
-- MIGRATION: 20260616000001_v20_sale_items_schema.sql
-- C-20 v20-sale-items-migration — Migración A (no destructiva)
-- Grupo 1: ALTER TABLE + índices + RLS en sale_items/purchase_items
--          + tabla account_feature_flags
--
-- GOVERNANCE ALTO. Aprobación PO: 2026-06-10.
-- NUNCA apply_migration — siempre npx supabase db push.
--
-- Rollback (si fuera necesario):
--   DROP TABLE IF EXISTS public.account_feature_flags;
--   ALTER TABLE public.sale_items ALTER COLUMN variant_id SET NOT NULL;
--   ALTER TABLE public.sale_items ALTER COLUMN quantity TYPE integer USING quantity::integer;
--   ALTER TABLE public.sale_items DROP COLUMN IF EXISTS product_id;
--   ALTER TABLE public.sale_items DROP COLUMN IF EXISTS account_id;
--   ALTER TABLE public.sale_items DROP COLUMN IF EXISTS unit_id;
--   (equivalente en purchase_items)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.1 ALTER TABLE sale_items
-- ─────────────────────────────────────────────────────────────────────────────

-- Hacer variant_id nullable (era NOT NULL — bloqueaba insertar filas con solo product_id)
ALTER TABLE public.sale_items ALTER COLUMN variant_id DROP NOT NULL;

-- Agregar columnas del modelo flat
ALTER TABLE public.sale_items
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS account_id uuid,
  ADD COLUMN IF NOT EXISTS unit_id    uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL;

-- Ampliar quantity de integer a numeric(15,4) para preservar fracciones
ALTER TABLE public.sale_items ALTER COLUMN quantity TYPE numeric(15,4) USING quantity::numeric(15,4);

-- Agregar subtotal (columna presente en prod desde el importer de variantes pero ausente
-- en el stub de la cadena de migraciones CI — 20260517000000_ci_compat_stubs.sql).
-- ADD COLUMN IF NOT EXISTS es no-op en prod (columna ya existe). DEFAULT 0 + NOT NULL
-- coincide exactamente con la definición real de prod.
ALTER TABLE public.sale_items
  ADD COLUMN IF NOT EXISTS subtotal numeric NOT NULL DEFAULT 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.2 ALTER TABLE purchase_items (simétrico)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.purchase_items ALTER COLUMN variant_id DROP NOT NULL;

ALTER TABLE public.purchase_items
  ADD COLUMN IF NOT EXISTS product_id  uuid REFERENCES public.products(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS account_id  uuid,
  ADD COLUMN IF NOT EXISTS unit_id     uuid REFERENCES public.units_of_measure(id) ON DELETE SET NULL;

ALTER TABLE public.purchase_items ALTER COLUMN quantity TYPE numeric(15,4) USING quantity::numeric(15,4);

-- Agregar subtotal (mismo drift que sale_items — columna en prod, ausente en el stub).
ALTER TABLE public.purchase_items
  ADD COLUMN IF NOT EXISTS subtotal numeric NOT NULL DEFAULT 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.3 Índices únicos parciales para idempotencia del backfill
-- solo se aplica cuando product_id IS NOT NULL (no choca con las 23/18 filas
-- de variantes que tienen product_id IS NULL)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS idx_sale_items_sale_product_unique
  ON public.sale_items (sale_id, product_id)
  WHERE product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_items_purchase_product_unique
  ON public.purchase_items (purchase_id, product_id)
  WHERE product_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.4 Índices de apoyo para JOINs y RLS
-- ─────────────────────────────────────────────────────────────────────────────

-- sale_items
CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id     ON public.sale_items (sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_account_id  ON public.sale_items (account_id);

-- purchase_items
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase_id  ON public.purchase_items (purchase_id);
CREATE INDEX IF NOT EXISTS idx_purchase_items_account_id   ON public.purchase_items (account_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.5 RLS en sale_items / purchase_items
-- Reemplazar las políticas antiguas (basadas en company_users JOIN) por el
-- patrón moderno de account_id usando current_account_ids() / is_account_writer()
-- espejo de las policies de sales/purchases.
-- ─────────────────────────────────────────────────────────────────────────────

-- sale_items
DROP POLICY IF EXISTS "Users can access their sale items" ON public.sale_items;

CREATE POLICY sale_items_account_select ON public.sale_items
  FOR SELECT USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY sale_items_writer_insert ON public.sale_items
  FOR INSERT WITH CHECK (is_account_writer(account_id));

CREATE POLICY sale_items_writer_update ON public.sale_items
  FOR UPDATE USING (is_account_writer(account_id))
             WITH CHECK (is_account_writer(account_id));

CREATE POLICY sale_items_writer_delete ON public.sale_items
  FOR DELETE USING (is_account_writer(account_id));

-- purchase_items
DROP POLICY IF EXISTS "Users can access their purchase items" ON public.purchase_items;

CREATE POLICY purchase_items_account_select ON public.purchase_items
  FOR SELECT USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY purchase_items_writer_insert ON public.purchase_items
  FOR INSERT WITH CHECK (is_account_writer(account_id));

CREATE POLICY purchase_items_writer_update ON public.purchase_items
  FOR UPDATE USING (is_account_writer(account_id))
             WITH CHECK (is_account_writer(account_id));

CREATE POLICY purchase_items_writer_delete ON public.purchase_items
  FOR DELETE USING (is_account_writer(account_id));

-- ─────────────────────────────────────────────────────────────────────────────
-- tabla account_feature_flags (OQ1 resuelto por PO: flag por cuenta)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.account_feature_flags (
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  flag_key   text NOT NULL,
  enabled    boolean NOT NULL DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  PRIMARY KEY (account_id, flag_key)
);

-- RLS en account_feature_flags: solo writers de la cuenta pueden leer/escribir
ALTER TABLE public.account_feature_flags ENABLE ROW LEVEL SECURITY;

CREATE POLICY account_feature_flags_select ON public.account_feature_flags
  FOR SELECT USING (account_id IN (SELECT current_account_ids()));

CREATE POLICY account_feature_flags_writer_insert ON public.account_feature_flags
  FOR INSERT WITH CHECK (is_account_writer(account_id));

CREATE POLICY account_feature_flags_writer_update ON public.account_feature_flags
  FOR UPDATE USING (is_account_writer(account_id))
             WITH CHECK (is_account_writer(account_id));

CREATE POLICY account_feature_flags_writer_delete ON public.account_feature_flags
  FOR DELETE USING (is_account_writer(account_id));

-- Índice para búsquedas por (account_id, flag_key) — ya cubierto por PK.
-- Índice adicional por flag_key para queries globales de ops.
CREATE INDEX IF NOT EXISTS idx_account_feature_flags_flag_key
  ON public.account_feature_flags (flag_key);

COMMENT ON TABLE public.account_feature_flags IS
  'Feature flags por cuenta. flag_key=''sale_items_rpc_v2'' activa el RPC v2 de ventas para esa cuenta.';
