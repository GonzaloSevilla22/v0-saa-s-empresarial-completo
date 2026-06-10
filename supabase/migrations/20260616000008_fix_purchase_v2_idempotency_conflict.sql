-- =============================================================================
-- MIGRATION: 20260616000008_fix_purchase_v2_idempotency_conflict.sql
-- HOTFIX C-20 (2/2) — incidente post-merge PR #153 (2026-06-10)
--
-- ROOT CAUSE:
--   rpc_create_purchase_operation_v2 y el camino legacy inline del wrapper
--   rpc_create_purchase_operation (ambos de 20260616000003) usan
--   ON CONFLICT (user_id, idempotency_key), pero la constraint real de
--   operation_idempotency es de 3 columnas (user_id, operation_kind,
--   idempotency_key) desde 20260607000003. Resultado:
--   "42P10: there is no unique or exclusion constraint matching the
--   ON CONFLICT specification" → 500 en toda creación de compras.
--   (Las funciones de VENTAS de la misma migración usan el target correcto.)
--
-- FIX:
--   - ON CONFLICT (user_id, operation_kind, idempotency_key) en ambas.
--   - Lookup de replay con operation_kind = 'purchase' (evita colisión si la
--     misma key se usó para una venta).
--   - v2 recupera la validación de amount (NULL o <= 0) que la legacy tenía.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- rpc_create_purchase_operation_v2 — escribe header flat + purchase_items
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation_v2(
  p_idempotency_key text,
  p_date            date,
  p_description     text,
  p_items           jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_inserted        integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'purchase'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.purchases p
    WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id <> v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      -- OQ2: doble escritura — header flat + purchase_items
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      -- Insertar en purchase_items (v2 path)
      INSERT INTO public.purchase_items (
        purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_purchase_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      UPDATE public.products
      SET    stock = stock + v_qty_norm
      WHERE  id = v_item.product_id
      RETURNING stock - v_qty_norm, stock
      INTO   v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
        v_qty_norm, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase', v_uid,
        v_new_op_id
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation_v2(text, date, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation_v2(text, date, text, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation_v2(text, date, text, jsonb) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper rpc_create_purchase_operation — despacha según flag por cuenta
-- (mismo cuerpo que 20260616000003, con el ON CONFLICT corregido en el
--  camino legacy inline)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key text,
  p_date            date,
  p_description     text,
  p_items           jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_flag_on    boolean := false;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  -- Leer el flag por cuenta (mismo flag que ventas)
  SELECT COALESCE(enabled, false) INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;

  IF v_flag_on THEN
    RETURN public.rpc_create_purchase_operation_v2(
      p_idempotency_key, p_date, p_description, p_items
    );
  ELSE
    -- Cuerpo legacy (20260528162050)
    DECLARE
      v_new_op_id       uuid;
      v_existing_op     uuid;
      v_item            RECORD;
      v_product         RECORD;
      v_new_purchase_id uuid;
      v_result_items    jsonb := '[]'::jsonb;
      v_qty_before      numeric;
      v_qty_after       numeric;
      v_unit_factor     numeric(20,10);
      v_qty_norm        numeric(15,4);
      v_inserted        integer;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
      END IF;

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
      END IF;

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        RETURN jsonb_build_object(
          'operation_id', v_existing_op,
          'items',        v_result_items,
          'replayed',     true
        );
      END IF;

      FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                 AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
      LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
          RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
          SELECT factor INTO v_unit_factor
          FROM   public.units_of_measure
          WHERE  id = v_item.unit_id;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
          END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        IF v_item.product_id IS NOT NULL THEN
          SELECT id, stock, user_id, is_variant, name INTO v_product
          FROM   public.products
          WHERE  id = v_item.product_id
          FOR UPDATE;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
          END IF;

          IF v_product.user_id <> v_uid THEN
            RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
          END IF;

          IF NOT v_product.is_variant THEN
            IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
              RAISE EXCEPTION
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                USING ERRCODE = 'P422';
            END IF;
          END IF;

          INSERT INTO public.purchases
            (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
          VALUES
            (v_uid, v_account_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
          RETURNING id INTO v_new_purchase_id;

          UPDATE public.products
          SET    stock = stock + v_qty_norm
          WHERE  id = v_item.product_id
          RETURNING stock - v_qty_norm, stock
          INTO   v_qty_before, v_qty_after;

          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
            v_qty_norm, v_qty_before, v_qty_after,
            v_new_purchase_id, 'purchase', v_uid,
            v_new_op_id
          );

        ELSE
          INSERT INTO public.purchases
            (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
          VALUES
            (v_uid, v_account_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
          RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
      END LOOP;

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb) TO authenticated;
