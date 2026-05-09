-- =============================================================================
-- MIGRATION: 20260509213302_integer_to_numeric_types.sql
-- DESCRIPTION: Etapa 2 — Migración INTEGER → NUMERIC(15,4)
--
-- Permite cantidades decimales en stock, ventas y compras.
-- Prerequisito cumplido: pre-check de reconciliación devuelve 0 deltas.
--
-- Cambios:
--   1. products.stock, products.min_stock  → NUMERIC(15,4)
--   2. sales.quantity                      → NUMERIC(15,4)
--   3. purchases.quantity                  → NUMERIC(15,4)
--   4. Drop triggers legacy que bloqueaban el ALTER TABLE y referenciaban
--      tablas inexistentes (product_variants, inventory_movements, warehouses)
--   5. Recrea check_low_stock + on_product_stock_update (alerta email stock bajo)
--   6. DROP rpc_atomic_create_sale(integer, date)    — overload con date y p_quantity integer
--   7. DROP rpc_atomic_create_purchase(integer, date) — ídem
--   8. CREATE rpc_atomic_create_sale(NUMERIC)         — nuevo, con ledger
--   9. CREATE rpc_atomic_create_purchase(NUMERIC)     — nuevo, con ledger
--
-- Rollback (solo si no hay datos decimales aún):
--   ALTER TABLE public.products
--     ALTER COLUMN stock     TYPE INTEGER USING stock::INTEGER,
--     ALTER COLUMN min_stock TYPE INTEGER USING min_stock::INTEGER;
--   ALTER TABLE public.sales     ALTER COLUMN quantity TYPE INTEGER USING quantity::INTEGER;
--   ALTER TABLE public.purchases ALTER COLUMN quantity TYPE INTEGER USING quantity::INTEGER;
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509213302
-- =============================================================================

-- ── 1. Drop triggers para desbloquear el ALTER TABLE ──────────────────────────
-- Triggers legacy eliminados permanentemente (referencian tablas inexistentes):
--   trg_products_before_insert → trg_set_product_company   (usa company_users)
--   trg_products_after_insert  → trg_create_default_variant (usa product_variants, warehouses)
--   trg_products_after_update  → trg_update_default_variant (usa product_variants)
-- Trigger válido recreado más abajo: on_product_stock_update → check_low_stock
DROP TRIGGER IF EXISTS on_product_stock_update    ON public.products;
DROP TRIGGER IF EXISTS trg_products_before_insert ON public.products;
DROP TRIGGER IF EXISTS trg_products_after_insert  ON public.products;
DROP TRIGGER IF EXISTS trg_products_after_update  ON public.products;

DROP FUNCTION IF EXISTS public.trg_set_product_company()    CASCADE;
DROP FUNCTION IF EXISTS public.trg_create_default_variant() CASCADE;
DROP FUNCTION IF EXISTS public.trg_update_default_variant() CASCADE;

-- ── 2. ALTER TABLE products ───────────────────────────────────────────────────
ALTER TABLE public.products
  ALTER COLUMN stock     TYPE NUMERIC(15,4) USING stock::NUMERIC(15,4),
  ALTER COLUMN min_stock TYPE NUMERIC(15,4) USING min_stock::NUMERIC(15,4);

-- ── 3. ALTER TABLE sales ──────────────────────────────────────────────────────
ALTER TABLE public.sales
  ALTER COLUMN quantity TYPE NUMERIC(15,4) USING quantity::NUMERIC(15,4);

-- ── 4. ALTER TABLE purchases ──────────────────────────────────────────────────
ALTER TABLE public.purchases
  ALTER COLUMN quantity TYPE NUMERIC(15,4) USING quantity::NUMERIC(15,4);

-- ── 5. Recrear check_low_stock + trigger on_product_stock_update ──────────────
-- La función no requiere cambios: NUMERIC(15,4) <= 5 funciona igual que INTEGER <= 5.
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
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

CREATE TRIGGER on_product_stock_update
  AFTER INSERT OR UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.check_low_stock();

-- ── 6 & 7. DROP overloads con integer+date (firma del ciclo anterior) ─────────
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, text, date);
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, text, date);

-- ── 8. rpc_atomic_create_sale — p_quantity NUMERIC(15,4) ─────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   NUMERIC(15,4),
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
  VALUES (v_uid, p_product_id, 'sale', -p_quantity, v_sale_id, 'sale');

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

-- ── 9. rpc_atomic_create_purchase — p_quantity NUMERIC(15,4) ─────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    NUMERIC(15,4),
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
  VALUES (v_uid, p_product_id, 'purchase', p_quantity, v_purchase_id, 'purchase');

  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'operation_created', jsonb_build_object('type', 'purchase', 'purchase_id', v_purchase_id));

  SELECT to_jsonb(p) INTO v_purchase_record FROM purchases p WHERE id = v_purchase_id;
  RETURN v_purchase_record;
END;
$$;

-- ── 10. Re-grant con nuevas firmas NUMERIC ────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, text, date)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, numeric, text, date)    TO authenticated;
