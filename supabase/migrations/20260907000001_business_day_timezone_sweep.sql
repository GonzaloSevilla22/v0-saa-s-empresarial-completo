-- =============================================================================
-- MIGRATION: 20260907000001_business_day_timezone_sweep.sql
-- app-timezone-argentina, task 5 (D5): sweep de definiciones VIGENTES en
-- supabase/migrations/ que aún computan el "día de negocio" con CURRENT_DATE
-- (día UTC del servidor) en vez de public.reporting_local_today() (día
-- calendario en America/Argentina/Mendoza — ya existe desde 20260814000001,
-- v3-reporting-invariants). Entre las 21:00 y las 23:59:59 ART el día UTC ya
-- rolleó al día siguiente; estas RPCs quedaban corridas un día en esa franja.
--
-- CREATE OR REPLACE con la MISMA firma en las 4 → conserva las ACLs
-- existentes (REVOKE/GRANT ya aplicados por sus migraciones originales; sin
-- DROP no se resetean). Ningún cuerpo cambia salvo CURRENT_DATE →
-- public.reporting_local_today() en los sitios listados abajo.
--
-- RESULTADO DEL SWEEP (12 archivos con CURRENT_DATE/now()::date, clasificados):
--
--   MIGRAR (4 funciones, 5 sitios — este archivo):
--     1. rpc_accept_quote            — vigente: 20260808000002 (línea ~308).
--        Chequeo de expiración de Quote (`valid_until < CURRENT_DATE`): un
--        quote con valid_until = hoy(ART) se veía "vencido" un día antes de
--        tiempo entre las 21:00-23:59 ART.
--     2. _c29_confirm_order_core     — vigente: 20260807000001 (líneas ~849, ~886).
--        Fecha de la fila `sales` legacy al confirmar una SalesOrder
--        (`date = CURRENT_DATE`) — la venta quedaba fechada mañana si se
--        confirmaba de noche (mismo bug que sale-form.tsx, ahora en SQL).
--     3. rpc_register_payment_received — vigente: 20260804000007 (línea ~250).
--        `p_value_date` del bank_movement al cobrar (transfer/card/check).
--     4. rpc_register_payment_made     — vigente: 20260804000007 (línea ~443).
--        Ídem, al pagar a un proveedor.
--
--   MUERTO (superseded, sin acción):
--     - rpc_product_profitability CURRENT_DATE en 20260606110000 — la
--       definición VIGENTE (20260814000001, v3-reporting-invariants) YA
--       usa public.reporting_local_today() desde su creación (RN-D5).
--     - Las definiciones previas de rpc_accept_quote/_c29_confirm_order_core
--       en 20260702000001/20260720000001/20260721000001/20260806000001 —
--       superseded por las vigentes migradas arriba (CREATE OR REPLACE
--       posterior ya las reemplazó en prod).
--
--   DELIBERADO — fuera de alcance (documentado, sin acción):
--     - 20260828000001_v31_rls_collision_rpcs.sql (líneas 749/762):
--       `CURRENT_DATE + 10/20` como vencimiento de CAE sintético dentro de un
--       gate de test (`DO $$ ... RAISE EXCEPTION 'GATE (fiscal-a)...`). Zona
--       fiscal AFIP/WSFE intocable (reglas ARCA) + es fixture de test, no
--       lógica de negocio real.
--     - 20260901000001_cost_center_report.sql (líneas 223/224):
--       `v_start := CURRENT_DATE - 10; v_end := CURRENT_DATE` — ventana
--       arbitraria de 10 días dentro de un gate de test (`DO $$` con
--       `v_unauthorized`/asserts), no una RPC de negocio.
--     - 20260509153624_add_date_param_to_rpcs.sql — "CURRENT_DATE" aparece
--       solo en un comentario de descripción de la migración, no en código.
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- =============================================================================


-- =============================================================================
-- 1. rpc_accept_quote — expiración de Quote anclada al día argentino
--    Cuerpo vigente: 20260808000002_v3_notifications_producers.sql:266-393,
--    preservado byte-a-byte salvo la línea del chequeo de expiración.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_accept_quote(
  p_quote_id  uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_quote          public.quotes%ROWTYPE;
  v_item           RECORD;
  v_sales_order_id uuid;
  v_branch_id      uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cargar el quote y validar tenencia
  SELECT * INTO v_quote
  FROM public.quotes
  WHERE id = p_quote_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_quote.account_id;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado: solo draft o sent son aceptables
  IF v_quote.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'quote_invalid_state: estado % no es aceptable', v_quote.status
      USING ERRCODE = 'P0409';
  END IF;

  -- OQ-4: validación defensiva on-read de expiración.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE (UTC del
  -- servidor) — evita marcar "vencido" un quote válido hasta hoy(ART) cuando
  -- se lo lee entre las 21:00 y las 23:59:59 ART.
  IF v_quote.valid_until IS NOT NULL AND v_quote.valid_until < public.reporting_local_today() THEN
    RAISE EXCEPTION 'quote_expired: valid_until % ya pasó', v_quote.valid_until
      USING ERRCODE = 'P0409';
  END IF;

  -- Resolver branch: preferir branch del quote, sino default
  v_branch_id := COALESCE(
    v_quote.branch_id,
    public.c26_default_branch(v_account_id)
  );

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Crear la SalesOrder en estado draft (sin tocar stock aún)
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_quote_id, status,
     payment_method, total, created_by)
  VALUES
    (v_account_id, v_branch_id, v_quote.client_id, p_quote_id, 'draft',
     'other', v_quote.total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- v3-snapshot-pattern (D1): copiar quote_items → sales_order_items
  -- propagando los snapshots ya congelados, SIN re-leer products.
  FOR v_item IN
    SELECT * FROM public.quote_items WHERE quote_id = p_quote_id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
       name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal,
       v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot,
       v_item.iva_rate_snapshot, v_item.snapshot_backfilled);
  END LOOP;

  -- v3-document-status-history (RN-A1): transición del quote en la misma transacción
  PERFORM public.record_status_transition(
    v_account_id, 'quote', p_quote_id, v_quote.status, 'accepted', v_uid, NULL);

  -- Transicionar el quote a accepted
  UPDATE public.quotes
  SET status = 'accepted'
  WHERE id = p_quote_id;

  -- v3-notifications-realtime (5.3): productor de QuoteAccepted al outbox.
  -- seller_id = quote.created_by (proxy — no hay columna seller_id dedicada
  -- hoy; deuda conocida documentada, igual criterio que D3).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'QuoteAccepted', 'Quote', p_quote_id,
    jsonb_build_object(
      'quote_id',  p_quote_id,
      'seller_id', v_quote.created_by,
      'branch_id', v_branch_id,
      'total',     v_quote.total
    ),
    now()
  );

  RETURN jsonb_build_object(
    'sales_order_id', v_sales_order_id,
    'quote_id',       p_quote_id,
    'status',         'accepted'
  );
END;
$$;


-- =============================================================================
-- 2. _c29_confirm_order_core — fecha de la venta legacy anclada al día argentino
--    Cuerpo vigente: 20260807000001_v3_document_status_history.sql:674-958,
--    preservado byte-a-byte salvo las 2 líneas de INSERT INTO sales (date=).
--    Helper interno — sigue sin GRANT a authenticated (ACL preservada, ver
--    encabezado del archivo).
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
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado)
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
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal)
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
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
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

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

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


-- =============================================================================
-- 3. rpc_register_payment_received — value_date del bank_movement anclado
--    Cuerpo vigente: 20260804000007_bank_payment_routing.sql:107-289,
--    preservado byte-a-byte salvo la línea del p_value_date.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_received(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_amount            numeric,
  p_reference_sale_id uuid DEFAULT NULL,
  p_payment_method    text DEFAULT 'cash',
  p_bank_account_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar amount > 0
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 C-30 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1 C-30)
  -- El helper c30_register_customer_account_movement lanza P0409 si balance resultante < 0
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,                 -- negativo: el cobro reduce la deuda
    'payment_received',
    v_payment_id
  );

  -- Obtener el balance_after del movimiento recién insertado
  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- INSERT en payments_received
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := CASE WHEN p_payment_method = 'card' THEN 'card_settlement' ELSE 'transfer_in' END;

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      p_amount,                 -- positivo: ingreso
      v_bank_movement_type,
      'payment_received',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30 (evento al outbox) + payment_method/bank_account_id enriquecidos (C2 D3)
  -- El consumer AuditLog de C-25 es genérico; el Consumer 3 (JournalEntry) lee
  -- payment_method del payload para rutear 1110 vs 1100.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      'payment_method',       p_payment_method,
      'bank_account_id',      p_bank_account_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$$;


-- =============================================================================
-- 4. rpc_register_payment_made — value_date del bank_movement anclado
--    Cuerpo vigente: 20260804000007_bank_payment_routing.sql:309-479,
--    preservado byte-a-byte salvo la línea del p_value_date.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_made(
  p_idempotency_key       text,
  p_supplier_id           uuid,
  p_amount                numeric,
  p_reference_purchase_id uuid DEFAULT NULL,
  p_payment_method        text DEFAULT 'cash',
  p_bank_account_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- D4: validar taxonomía de payment_method
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- D2: método bancario exige bank_account_id válido, activo y de la cuenta
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,               -- negativo: el pago reduce lo que se debe
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid);

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios.
  -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := 'transfer_out';  -- egreso: pago por transfer/check/card → egreso bancario

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      -p_amount,                -- negativo: egreso
      v_bank_movement_type,
      'payment_made',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  -- OQ-6 C-30: evento PaymentMade al outbox + payment_method/bank_account_id (C2 D3)
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'payment_method',      p_payment_method,
      'bank_account_id',     p_bank_account_id,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$$;
