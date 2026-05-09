-- =============================================================================
-- MIGRATION: 20260509214856_etapa3_unit_id_on_operations.sql
-- DESCRIPTION: Etapa 3 — Soporte de unidad de medida en ventas y compras
--
-- Permite registrar ventas/compras en cualquier unidad de medida y convierte
-- automáticamente la cantidad a la unidad base antes de modificar el stock.
--
-- Diseño de conversión:
--   · sales.quantity / purchases.quantity  = cantidad en la unidad elegida
--     (se usa para total = amount × quantity — precio por unidad-de-venta)
--   · products.stock                       = siempre en unidad base
--   · stock_movements.quantity_delta       = delta en unidad base
--   · Conversión: quantity_base = p_quantity × units_of_measure.factor
--
-- Cambios:
--   1. sales.unit_id     → uuid FK a units_of_measure (nullable, sin conversión = NULL)
--   2. purchases.unit_id → uuid FK a units_of_measure (nullable)
--   3. DROP rpc_atomic_create_sale(uuid, uuid, numeric, numeric, text, date)
--   4. DROP rpc_atomic_create_purchase(uuid, numeric, numeric, text, date)
--   5. CREATE rpc_atomic_create_sale    con p_unit_id + lógica de conversión
--   6. CREATE rpc_atomic_create_purchase con p_unit_id + lógica de conversión
--   7. Re-grant nuevas firmas
--
-- Comportamiento retrocompatible:
--   p_unit_id = NULL → factor = 1.0 → sin conversión (igual que Etapas 0-2)
--
-- Rollback:
--   ALTER TABLE public.sales     DROP COLUMN IF EXISTS unit_id;
--   ALTER TABLE public.purchases DROP COLUMN IF EXISTS unit_id;
--   -- Recrear RPCs con firma anterior (sin p_unit_id)
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509214856
-- =============================================================================

-- ── 1. unit_id en sales ───────────────────────────────────────────────────────
ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS unit_id uuid
    REFERENCES public.units_of_measure(id);

CREATE INDEX idx_sales_unit
  ON public.sales(unit_id)
  WHERE unit_id IS NOT NULL;

-- ── 2. unit_id en purchases ───────────────────────────────────────────────────
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS unit_id uuid
    REFERENCES public.units_of_measure(id);

CREATE INDEX idx_purchases_unit
  ON public.purchases(unit_id)
  WHERE unit_id IS NOT NULL;

-- ── 3 & 4. Drop firmas NUMERIC sin p_unit_id ─────────────────────────────────
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, text, date);
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, numeric, text, date);

-- ── 5. rpc_atomic_create_sale — con conversión de unidad ─────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   NUMERIC(15,4),
  p_unit_id    uuid    DEFAULT NULL,
  p_currency   text    DEFAULT 'ARS',
  p_date       date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_product             RECORD;
  v_sale_id             uuid;
  v_existing_first_op   uuid;
  v_sale_record         jsonb;
  v_unit_factor         NUMERIC(20,10) := 1.0;
  v_quantity_normalized NUMERIC(15,4);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- ── Resolver factor de conversión ─────────────────────────────────────────
  IF p_unit_id IS NOT NULL THEN
    SELECT factor INTO v_unit_factor
    FROM public.units_of_measure
    WHERE id = p_unit_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unit of measure not found' USING ERRCODE = 'P404';
    END IF;
  END IF;

  -- Cantidad en unidad base (la que se descuenta del stock)
  v_quantity_normalized := (p_quantity * v_unit_factor)::NUMERIC(15,4);

  -- ── Lock del producto y validaciones ──────────────────────────────────────
  SELECT id, stock, price, user_id, is_variant INTO v_product
  FROM public.products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- El stock se compara contra la cantidad normalizada (en unidad base)
  IF v_product.stock < v_quantity_normalized THEN
    RAISE EXCEPTION 'Insufficient stock' USING ERRCODE = 'P409';
  END IF;

  -- ── Insertar venta ────────────────────────────────────────────────────────
  -- quantity = cantidad en la unidad elegida (para total = amount × quantity)
  -- unit_id  = referencia a la unidad usada (nullable para retrocompatibilidad)
  INSERT INTO public.sales
    (user_id, client_id, product_id, amount, quantity, unit_id, total, currency, date)
  VALUES
    (v_uid, p_client_id, p_product_id,
     p_amount, p_quantity, p_unit_id,
     p_amount * p_quantity, p_currency, p_date)
  RETURNING id INTO v_sale_id;

  -- ── Descontar stock en unidad base ────────────────────────────────────────
  UPDATE public.products
    SET stock = stock - v_quantity_normalized
  WHERE id = p_product_id;

  -- ── Ledger: delta negativo en unidad base ─────────────────────────────────
  INSERT INTO public.stock_movements
    (user_id, product_id, type, quantity_delta, reference_id, reference_type)
  VALUES
    (v_uid, p_product_id, 'sale', -v_quantity_normalized, v_sale_id, 'sale');

  -- ── Analytics ─────────────────────────────────────────────────────────────
  INSERT INTO public.analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created',
          jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));

  SELECT id INTO v_existing_first_op
  FROM public.analytics_events
  WHERE user_id = v_uid AND event_name = 'first_operation'
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'first_operation',
            jsonb_build_object('type', 'sale', 'sale_id', v_sale_id));
  END IF;

  SELECT to_jsonb(s) INTO v_sale_record FROM public.sales s WHERE id = v_sale_id;
  RETURN v_sale_record;
END;
$$;

-- ── 6. rpc_atomic_create_purchase — con conversión de unidad ─────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    NUMERIC(15,4),
  p_unit_id     uuid    DEFAULT NULL,
  p_description text    DEFAULT NULL,
  p_date        date    DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_product             RECORD;
  v_purchase_id         uuid;
  v_purchase_record     jsonb;
  v_unit_factor         NUMERIC(20,10) := 1.0;
  v_quantity_normalized NUMERIC(15,4);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
  END IF;

  -- ── Resolver factor de conversión ─────────────────────────────────────────
  IF p_unit_id IS NOT NULL THEN
    SELECT factor INTO v_unit_factor
    FROM public.units_of_measure
    WHERE id = p_unit_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unit of measure not found' USING ERRCODE = 'P404';
    END IF;
  END IF;

  -- Cantidad en unidad base (la que se suma al stock)
  v_quantity_normalized := (p_quantity * v_unit_factor)::NUMERIC(15,4);

  -- ── Lock del producto y validaciones ──────────────────────────────────────
  SELECT id, stock, user_id, is_variant INTO v_product
  FROM public.products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P404';
  END IF;

  IF v_product.user_id != v_uid THEN
    RAISE EXCEPTION 'Permission denied to this product' USING ERRCODE = 'P403';
  END IF;

  IF NOT v_product.is_variant THEN
    IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = p_product_id LIMIT 1) THEN
      RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
        USING ERRCODE = 'P422';
    END IF;
  END IF;

  -- ── Insertar compra ───────────────────────────────────────────────────────
  -- quantity    = cantidad en la unidad elegida (para total = amount × quantity)
  -- unit_id     = referencia a la unidad usada (nullable para retrocompatibilidad)
  -- description = observación libre del proveedor / lote (fix: ahora se guarda)
  INSERT INTO public.purchases
    (user_id, product_id, amount, quantity, unit_id, total, description, date)
  VALUES
    (v_uid, p_product_id, p_amount, p_quantity, p_unit_id,
     p_amount * p_quantity, p_description, p_date)
  RETURNING id INTO v_purchase_id;

  -- ── Sumar stock en unidad base ────────────────────────────────────────────
  UPDATE public.products
    SET stock = stock + v_quantity_normalized
  WHERE id = p_product_id;

  -- ── Ledger: delta positivo en unidad base ─────────────────────────────────
  INSERT INTO public.stock_movements
    (user_id, product_id, type, quantity_delta, reference_id, reference_type)
  VALUES
    (v_uid, p_product_id, 'purchase', v_quantity_normalized, v_purchase_id, 'purchase');

  -- ── Analytics ─────────────────────────────────────────────────────────────
  INSERT INTO public.analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created',
          jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM public.purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- ── 7. Re-grant nuevas firmas ─────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, uuid, text, date)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, numeric, uuid, text, date)    TO authenticated;
