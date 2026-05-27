-- =============================================================================
-- MIGRATION: 20260509210816_create_stock_movements.sql
-- DESCRIPTION: Create stock_movements audit table and change products.stock
--              column type from INTEGER to NUMERIC(15,4) to support fractional
--              quantities (weight, volume, length units).
--
-- Originally applied via Supabase MCP on 2026-05-09.
-- This file was a documentation stub — DDL has been reconstructed from the
-- live DB schema to allow CI to replay migrations on a fresh database.
-- =============================================================================

-- ── 0. Drop blocking trigger before column type change ───────────────────────
-- Migration 20250101000011_ai_alerts created on_product_stock_update with
-- "AFTER INSERT OR UPDATE OF stock", which registers a column-level dependency.
-- PostgreSQL refuses to ALTER COLUMN TYPE while that dependency exists.
-- We drop the trigger here and recreate it (improved) at the end of this file.
DROP TRIGGER IF EXISTS on_product_stock_update ON public.products;

-- ── 1. Change products.stock from INTEGER → NUMERIC(15,4) ────────────────────
-- Supports fractional quantities: weight (kg), volume (L), length (m), etc.
ALTER TABLE public.products
  ALTER COLUMN stock TYPE NUMERIC(15,4) USING stock::NUMERIC(15,4);

-- ── 2. stock_movements audit table ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id             uuid        DEFAULT gen_random_uuid() NOT NULL,
  user_id        uuid        REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id     uuid        REFERENCES public.products(id) ON DELETE SET NULL,
  type           text        CHECK (type = ANY (ARRAY['purchase','sale','adjustment','return','initial'])),
  quantity_delta numeric,
  reference_id   uuid,
  reference_type text        CHECK (reference_type = ANY (ARRAY['sale','purchase','adjustment','initial'])),
  notes          text,
  created_at     timestamptz DEFAULT now(),
  CONSTRAINT stock_movements_pkey PRIMARY KEY (id)
);

-- ── 3. Row-Level Security ─────────────────────────────────────────────────────
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_movements_select" ON public.stock_movements
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "stock_movements_insert" ON public.stock_movements
  FOR INSERT WITH CHECK (user_id = auth.uid());

-- ── 4. Performance indexes ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_stock_movements_product
  ON public.stock_movements (product_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_stock_movements_user
  ON public.stock_movements (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_stock_movements_reference
  ON public.stock_movements (reference_id)
  WHERE reference_id IS NOT NULL;

-- ── 5. check_low_stock trigger function ──────────────────────────────────────
-- Fires after INSERT/UPDATE on products. If stock drops ≤ 5, queues a
-- low_stock_alert in email_logs (debounced: only once per 24 h per product).
-- SECURITY DEFINER required — authenticated role cannot SELECT auth.users.
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  recent_alert boolean;
BEGIN
  IF NEW.stock <= 5 AND (TG_OP = 'INSERT' OR OLD.stock > 5) THEN
    SELECT EXISTS (
      SELECT 1 FROM public.email_logs
      WHERE event_type = 'low_stock_alert'
        AND metadata->>'product_id' = NEW.id::text
        AND created_at > now() - INTERVAL '24 hours'
    ) INTO recent_alert;

    IF NOT recent_alert THEN
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      SELECT
        NEW.user_id,
        'low_stock_alert',
        u.email,
        'Alerta de Stock Bajo: ' || NEW.name,
        jsonb_build_object(
          'product_id',    NEW.id,
          'product_name',  NEW.name,
          'current_stock', NEW.stock
        )
      FROM auth.users u
      WHERE u.id = NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ── 6. Attach trigger to products ────────────────────────────────────────────
DROP TRIGGER IF EXISTS on_product_stock_update ON public.products;
CREATE TRIGGER on_product_stock_update
  AFTER INSERT OR UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.check_low_stock();
