-- =============================================================================
-- MIGRATION: 20260509210816_create_stock_movements.sql
-- DESCRIPTION: Etapa 0.5 — Ledger inmutable de movimientos de stock
--
-- Crea `stock_movements` como registro auditable de cada delta de inventario.
-- Cada compra y venta inserta una fila aquí dentro de la misma transacción
-- atómica que modifica products.stock.
--
-- Esta tabla es prerequisito de:
--   - Etapa 2 (INTEGER → NUMERIC: reconciliar datos antes de cambiar tipos)
--   - Etapa 3 (multi-unidad: almacenar qty normalizada en unidad base)
--   - Futuro: UI de ajuste de stock, reportes de auditoría
--
-- Cambios:
--   1. CREATE TABLE stock_movements + índices + RLS
--   2. Backfill histórico desde purchases y sales existentes
--   3. CREATE OR REPLACE rpc_atomic_create_sale    (agrega INSERT en ledger)
--   4. CREATE OR REPLACE rpc_atomic_create_purchase (agrega INSERT en ledger)
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509210816
-- =============================================================================

-- ── 1. Tabla ──────────────────────────────────────────────────────────────────
CREATE TABLE public.stock_movements (
  id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id     uuid          REFERENCES public.products(id) ON DELETE SET NULL,
  type           text          NOT NULL
    CHECK (type IN ('purchase', 'sale', 'adjustment', 'return', 'initial')),
  quantity_delta NUMERIC(15,4) NOT NULL,
  -- positivo = entrada (purchase, return), negativo = salida (sale)
  reference_id   uuid,
  -- sale_id o purchase_id de origen; NULL para ajustes manuales
  reference_type text
    CHECK (reference_type IN ('sale', 'purchase', 'adjustment', 'initial')),
  notes          text,
  created_at     timestamptz   NOT NULL DEFAULT now()
);

-- ── 2. Índices ────────────────────────────────────────────────────────────────
CREATE INDEX idx_stock_movements_product
  ON public.stock_movements(product_id, created_at DESC);

CREATE INDEX idx_stock_movements_user
  ON public.stock_movements(user_id, created_at DESC);

CREATE INDEX idx_stock_movements_reference
  ON public.stock_movements(reference_id)
  WHERE reference_id IS NOT NULL;

-- ── 3. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_movements_select"
  ON public.stock_movements FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "stock_movements_insert"
  ON public.stock_movements FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- ── 4. Backfill histórico ─────────────────────────────────────────────────────
-- Compras → deltas positivos (entrada de stock)
INSERT INTO public.stock_movements
  (user_id, product_id, type, quantity_delta, reference_id, reference_type, created_at)
SELECT
  user_id,
  product_id,
  'purchase',
  quantity::NUMERIC(15,4),
  id,
  'purchase',
  created_at
FROM public.purchases
WHERE product_id IS NOT NULL;

-- Ventas → deltas negativos (salida de stock)
INSERT INTO public.stock_movements
  (user_id, product_id, type, quantity_delta, reference_id, reference_type, created_at)
SELECT
  user_id,
  product_id,
  'sale',
  -(quantity::NUMERIC(15,4)),
  id,
  'sale',
  created_at
FROM public.sales
WHERE product_id IS NOT NULL;

-- ── 5. rpc_atomic_create_sale — agrega INSERT en stock_movements ──────────────
-- Cuerpo base: 20260509153624_add_date_param_to_rpcs.sql
-- Cambio único: INSERT INTO stock_movements después del UPDATE products.

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_currency   text DEFAULT 'ARS',
  p_date       date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid               uuid;
  v_product           RECORD;
  v_sale_id           uuid;
  v_existing_first_op uuid;
  v_sale_record       jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, price, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  IF v_product.stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  INSERT INTO sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_currency, p_date)
  RETURNING id INTO v_sale_id;

  UPDATE products SET stock = stock - p_quantity WHERE id = p_product_id;

  -- Ledger: delta negativo = salida de stock
  INSERT INTO stock_movements (user_id, product_id, type, quantity_delta, reference_id, reference_type)
  VALUES (v_uid, p_product_id, 'sale', -(p_quantity::NUMERIC(15,4)), v_sale_id, 'sale');

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));

  SELECT id INTO v_existing_first_op
  FROM analytics_events WHERE user_id = v_uid AND event_name = 'first_operation' LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'first_operation', jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;

-- ── 6. rpc_atomic_create_purchase — agrega INSERT en stock_movements ──────────
-- Cuerpo base: 20260509153624_add_date_param_to_rpcs.sql
-- Cambio único: INSERT INTO stock_movements después del UPDATE products.

CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    integer,
  p_description text DEFAULT NULL,
  p_date        date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_product         RECORD;
  v_purchase_id     uuid;
  v_purchase_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  SELECT id, stock, user_id, is_variant INTO v_product
  FROM products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  INSERT INTO purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_amount * p_quantity, p_date)
  RETURNING id INTO v_purchase_id;

  UPDATE products SET stock = stock + p_quantity WHERE id = p_product_id;

  -- Ledger: delta positivo = entrada de stock
  INSERT INTO stock_movements (user_id, product_id, type, quantity_delta, reference_id, reference_type)
  VALUES (v_uid, p_product_id, 'purchase', p_quantity::NUMERIC(15,4), v_purchase_id, 'purchase');

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- Re-grant EXECUTE (firmas sin cambios — idempotente)
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, text, date)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, integer, text, date)    TO authenticated;
