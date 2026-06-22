-- =============================================================================
-- MIGRATION: 20260721000001_c29_write_sale_items.sql
-- Change: c29-write-sale-items
--
-- PROBLEMA:
--   _c29_confirm_order_core (20260702000001) escribe sales + stock_movements
--   pero NUNCA sale_items, pese a que la spec sale-line-items ya exige que
--   SalesOrder.confirm()/quickSale() escriban la línea en sale_items. Drift
--   spec↔implementación: bloquea el DROP del header plano (C-20 Grupo 10) y
--   obligó al fix de reposición de stock a leer de stock_movements.
--
-- FIX:
--   (1) CREATE OR REPLACE del core reproduciendo el cuerpo vigente + un único
--       INSERT INTO sale_items por línea con producto (espejo de
--       rpc_create_sale_operation_v2; variant_id = NULL).
--   (2) Backfill idempotente (NOT EXISTS) de las ventas con product_id que hoy
--       no tienen fila en sale_items, desde las columnas planas de sales.
--
--   Sin DROP ni DDL destructivo. Líneas de servicio (product_id IS NULL) no
--   generan ítem. Idempotencia del confirm intacta (operation_idempotency).
-- =============================================================================

CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: validación cash sin session → P0400
  IF p_payment_method = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method
  IF p_payment_method NOT IN ('cash', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- Lock del producto para serializar
      SELECT id, user_id, name INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      v_qty_norm := v_item.quantity;

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4)
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;

      -- c29-write-sale-items: la línea vive en sale_items (espejo de
      -- rpc_create_sale_operation_v2). variant_id = NULL (sales_order_items
      -- no maneja variantes). Fuente de verdad post C-20.
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal
      );

      -- stock_movements (reference_type='sale')
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  IF p_payment_method = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  p_payment_method,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  UPDATE public.sales_orders
  SET
    status             = 'confirmed',
    payment_method     = p_payment_method,
    total              = v_total,
    sale_operation_id  = v_new_op_id,
    fiscal_document_id = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$$;

-- REVOKE: helper interno — NO callable desde rol authenticated (paridad con el original)
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._c29_confirm_order_core IS
  'C-29 (D1): helper interno compartido por rpc_confirm_sales_order y rpc_quick_sale. '
  'SECURITY DEFINER para poder invocar c28_register_cash_movement (revocado de PUBLIC). '
  'No callable externamente. Atómico: un fallo aborta todo el commit. '
  'c29-write-sale-items: escribe sale_items por línea con producto.';


-- =============================================================================
-- Backfill idempotente: reconstruir sale_items para ventas con producto que
-- hoy no tienen ítem (ventas C-29/legacy creadas antes de este fix). Desde las
-- columnas planas de sales. NOT EXISTS = re-ejecutable sin duplicar. No toca
-- filas de variantes del importador (product_id IS NULL).
-- =============================================================================
INSERT INTO public.sale_items
  (sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal)
SELECT
  s.id, s.product_id, s.account_id, NULL,
  s.quantity, s.unit_id, s.amount,
  COALESCE(s.total, s.amount * s.quantity)
FROM public.sales s
WHERE s.product_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.sale_items si WHERE si.sale_id = s.id
  );
