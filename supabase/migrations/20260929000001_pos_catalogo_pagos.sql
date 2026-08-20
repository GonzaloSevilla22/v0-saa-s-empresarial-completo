-- ═══════════════════════════════════════════════════════════════════════════
-- pos-catalogo-pagos — catálogo de formas de pago en el POS + restauración
-- del bloque `credit` de C-30 en _c29_confirm_order_core (regresión de julio)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- CONTEXTO (ver openspec/changes/pos-catalogo-pagos/design.md):
--
-- La migración 20260720000001_c30_customer_supplier_accounts.sql agregó a
-- _c29_confirm_order_core el bloque `credit` (guard credit_requires_client,
-- c30_get_or_create_customer_account + c30_register_customer_account_movement
-- + evento CustomerAccountCharged). Al día siguiente,
-- 20260721000001_c29_write_sale_items.sql reescribió la función ENTERA desde
-- una base anterior al C-30 y borró ese bloque en silencio. Las cuatro
-- reescrituras posteriores (20260806000001 snapshot, 20260807000001
-- status-history, 20260907000001 timezone, 20260928000001 payment-methods)
-- propagaron la versión sin el bloque. Verificado en prod 2026-08-19:
-- customer_account_movements tiene 0 filas y confirmar con payment_method=
-- 'credit' falla con invalid_payment_method, pese a que el spec sales-order
-- ya lo exige desde C-30 (drift spec↔implementación).
--
-- Esta migración parte de la definición VIVA de las 3 funciones (capturada
-- con pg_get_functiondef contra prod gxdhpxvdjjkmxhdkkwyb el 2026-08-19,
-- MAX(version) = 20260928000001 — verificado inmediatamente antes de fijar
-- este timestamp) — NO del archivo del repo — exactamente para no repetir
-- la regresión. La captura completa queda en el PR (rollback).
--
-- CAMBIOS:
--   1. sales_orders.payment_method_id (nueva, nullable, FK payment_methods).
--   2. CHECK de sales_orders.payment_method ampliado a los 7 kind del catálogo
--      (antes 5: cash,transfer,card,other,credit — ahora + check,wallet).
--   3. _c29_confirm_order_core: resuelve el kind desde payment_method_id
--      (D2), restaura el bloque credit (D3, canónico de 20260720000001),
--      valida vocabulario contra los 7 kind (D4), persiste payment_method_id
--      en sales_orders y en cada fila legacy de sales.
--      El bloque fiscal (C-27) y el de caja (C-28) viajan SIN TOCAR NI UNA
--      LÍNEA — gate OQ-G.
--   4. rpc_quick_sale / rpc_confirm_sales_order: DROP+CREATE con el arg
--      trailing p_payment_method_id uuid DEFAULT NULL (evita 42725) +
--      re-GRANT/REVOKE.
--   5. Backfill idempotente de las 120 sales_orders históricas (63 cash +
--      57 other) por kind = payment_method dentro de la misma cuenta.
--
-- Idempotente: supabase GitHub auto-aplica. IF NOT EXISTS / DROP+CREATE /
-- backfill acotado por payment_method_id IS NULL.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Columna + índice + CHECK ampliado + COMMENT (D1, D4)
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE public.sales_orders
  ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL
    REFERENCES public.payment_methods(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_sales_orders_payment_method_id
  ON public.sales_orders (payment_method_id)
  WHERE payment_method_id IS NOT NULL;

ALTER TABLE public.sales_orders
  DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;

ALTER TABLE public.sales_orders
  ADD CONSTRAINT sales_orders_payment_method_check
  CHECK (payment_method = ANY (ARRAY['cash'::text, 'transfer'::text, 'card'::text, 'check'::text, 'wallet'::text, 'credit'::text, 'other'::text]));

COMMENT ON COLUMN public.sales_orders.payment_method IS
  'Derivada de payment_method_id (pos-catalogo-pagos D1): la RPC la escribe '
  'igual al kind de payment_method_id cuando este no es NULL. Para órdenes '
  'sin imputación explícita (histórico pre-change) conserva el texto legacy '
  'y se lee por derivación de fallback (payment-method D10). No es un campo '
  'libre del cliente.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. _c29_confirm_order_core — DROP (firma vieja, 7 args) + CREATE (8 args)
-- ─────────────────────────────────────────────────────────────────────────
-- Evita el mismo riesgo 42725 que las dos RPCs públicas: todos los params
-- desde p_cash_session_id tienen DEFAULT, así que agregar uno trailing sin
-- dropear la firma vieja crearía un overload ambiguo para cualquier llamada
-- con 7 argumentos posicionales.

DROP FUNCTION IF EXISTS public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text);

CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_comprobante_type  text DEFAULT NULL::text,
  p_point_of_sale_id  uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  -- pos-catalogo-pagos (D2/D3): resolución de kind y cuenta corriente.
  v_kind                 text;
  v_pm_is_active         boolean;
  v_customer_account_id  uuid;
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

  -- ─── pos-catalogo-pagos (D2): resolver el kind — el cliente no elige la
  -- taxonomía, la RPC la deriva del catálogo y no le cree al texto que
  -- venga junto. Va con los demás guards de entrada, antes de tocar stock.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind, is_active INTO v_kind, v_pm_is_active
    FROM public.payment_methods
    WHERE id = p_payment_method_id
      AND account_id = v_account_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: % no pertenece a la cuenta o no existe', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;

    IF NOT v_pm_is_active THEN
      RAISE EXCEPTION 'payment_method_inactive: % está desactivada', p_payment_method_id
        USING ERRCODE = 'P0400';
    END IF;

    IF p_payment_method IS NOT NULL AND p_payment_method <> v_kind THEN
      RAISE EXCEPTION 'payment_method_mismatch: el texto % no coincide con el kind % de la forma de pago', p_payment_method, v_kind
        USING ERRCODE = 'P0400';
    END IF;
  ELSE
    -- Camino legacy (D2 regla 3): sin payment_method_id, el kind es el texto
    -- recibido (o 'other' si viene NULL) y la orden queda sin imputación.
    v_kind := COALESCE(p_payment_method, 'other');
  END IF;

  -- D6: validación cash sin session → P0400 (ramifica sobre v_kind, no sobre
  -- el texto crudo — D4).
  IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- pos-catalogo-pagos (D3): restaurar el guard credit_requires_client del
  -- bloque C-30 (20260720000001), ANTES de tocar stock — junto con los
  -- demás guards de entrada.
  IF v_kind = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (D4: vocabulario completo del catálogo, los 7 kind)
  IF v_kind NOT IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', v_kind
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
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado). La forma de pago del replay se ignora
    -- (pos-catalogo-pagos: mismo criterio, ahora también para payment_method_id).
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
      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
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

      -- Insertar fila legacy sales (retrocompat D4). app-timezone-argentina
      -- (task 5): día argentino, no CURRENT_DATE (UTC del servidor).
      -- pos-catalogo-pagos: cada fila legacy nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
      -- pos-catalogo-pagos: también nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  -- pos-catalogo-pagos (D4): ramifica sobre v_kind, no sobre el texto crudo.
  IF v_kind = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── pos-catalogo-pagos (D3): cuenta corriente del cliente — RESTAURADO
  -- desde el bloque canónico de 20260720000001_c30_customer_supplier_
  -- accounts.sql (líneas 1256-1290), perdido por 20260721000001 al
  -- reescribir la función desde una base anterior. Si el kind efectivo es
  -- credit, postea el cargo en el mismo commit (sin caja). client_id ya
  -- validado arriba (credit_requires_client antes del descuento de stock).
  IF v_kind = 'credit' THEN
    v_customer_account_id := public.c30_get_or_create_customer_account(
      v_account_id,
      v_order.client_id
    );
    PERFORM public.c30_register_customer_account_movement(
      v_customer_account_id,
      v_total,                -- positivo: cargo que aumenta la deuda del cliente
      'sale',
      p_sales_order_id
    );

    -- Evento CustomerAccountCharged al outbox (canónico de C-30).
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id,
      'CustomerAccountCharged',
      'CustomerAccount',
      v_customer_account_id,
      jsonb_build_object(
        'account_id',           v_account_id,
        'customer_account_id',  v_customer_account_id,
        'client_id',            v_order.client_id,
        'sales_order_id',       p_sales_order_id,
        'operation_id',         v_new_op_id,
        'amount',               v_total,
        'occurred_at',          now()
      ),
      now()
    );
  END IF;

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  -- GATE OQ-G: bloque fiscal copiado SIN TOCAR NI UNA LÍNEA desde la
  -- definición viva capturada 2026-08-19. No modificar sin sign-off del PO.
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
  -- pos-catalogo-pagos: el payload lleva el kind EFECTIVO (v_kind), no el
  -- texto crudo del cliente — coherente con lo que persiste sales_orders.
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
      'payment_method',  v_kind,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  -- pos-catalogo-pagos: payment_method pasa a ser el kind EFECTIVO (v_kind,
  -- derivado por la RPC — D1) y se persiste payment_method_id.
  UPDATE public.sales_orders
  SET
    status              = 'confirmed',
    payment_method      = v_kind,
    payment_method_id   = p_payment_method_id,
    total               = v_total,
    sale_operation_id   = v_new_op_id,
    fiscal_document_id  = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$function$;

-- ACLs de _c29_confirm_order_core: solo postgres/service_role (no expuesta a
-- PostgREST). El DROP+CREATE resetea a default (EXECUTE a PUBLIC) — re-emitir.
-- REVOKE debe listar "PUBLIC, anon, authenticated" explícitamente: "FROM
-- PUBLIC" solo no alcanza porque Supabase setea ALTER DEFAULT PRIVILEGES
-- que otorga EXECUTE directo a anon/authenticated en cada función nueva
-- (no vía el pseudo-rol PUBLIC) — gotcha de los advisors 0028/0029, mismo
-- patrón que 20260828000001_v31_rls_collision_rpcs.sql. Confirmado en CI
-- (gate test_function_acl_gate.sql) sobre este mismo change: el REVOKE
-- "FROM PUBLIC" a secas dejaba anon con EXECUTE en las 3 funciones.
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. rpc_confirm_sales_order — DROP (firma vieja, 8 args) + CREATE (9 args)
-- ─────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.rpc_confirm_sales_order(text, uuid, text, uuid, text, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_confirm_sales_order(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_comprobante_type  text DEFAULT NULL::text,
  p_point_of_sale_id  uuid DEFAULT NULL::uuid,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    p_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal,
    p_payment_method_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_confirm_sales_order(text, uuid, text, uuid, text, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_sales_order(text, uuid, text, uuid, text, uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_sales_order(text, uuid, text, uuid, text, uuid, uuid, text, uuid) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. rpc_quick_sale — DROP (firma vieja, 9 args) + CREATE (10 args)
-- ─────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.rpc_quick_sale(text, uuid, jsonb, text, uuid, text, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.rpc_quick_sale(
  p_idempotency_key   text,
  p_client_id         uuid DEFAULT NULL::uuid,
  p_items             jsonb DEFAULT '[]'::jsonb,
  p_payment_method    text DEFAULT 'other'::text,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_comprobante_type  text DEFAULT NULL::text,
  p_point_of_sale_id  uuid DEFAULT NULL::uuid,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_sales_order_id uuid;
  v_item           RECORD;
  v_total          numeric(15,2) := 0;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar items
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular total inicial
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'quantity debe ser > 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.price IS NULL OR v_item.price < 0 THEN
      RAISE EXCEPTION 'price debe ser >= 0' USING ERRCODE = 'P0400';
    END IF;
    v_total := v_total + COALESCE(v_item.subtotal, v_item.price * v_item.quantity);
  END LOOP;

  -- Crear SalesOrder en draft
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, status, payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, p_client_id, 'draft', p_payment_method, v_total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- Crear sales_order_items
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price,
       COALESCE(v_item.subtotal, v_item.price * v_item.quantity));
  END LOOP;

  -- Confirmar inline (hot path transaccional). pos-catalogo-pagos: pasa
  -- p_payment_method_id — la RPC interna resuelve y valida el kind (D2).
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal,
    p_payment_method_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_quick_sale(text, uuid, jsonb, text, uuid, text, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quick_sale(text, uuid, jsonb, text, uuid, text, uuid, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_quick_sale(text, uuid, jsonb, text, uuid, text, uuid, uuid, text, uuid) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Backfill idempotente (D9) — 120 sales_orders históricas (63 cash + 57
--    other), por kind = payment_method dentro de la misma cuenta. Mismo
--    mapping firmado del backfill de #419 (metodos-pago-operaciones).
-- ─────────────────────────────────────────────────────────────────────────

UPDATE public.sales_orders so
SET payment_method_id = pm.id
FROM public.payment_methods pm
WHERE pm.account_id = so.account_id
  AND pm.kind = so.payment_method
  AND pm.deleted_at IS NULL
  AND so.payment_method_id IS NULL;
