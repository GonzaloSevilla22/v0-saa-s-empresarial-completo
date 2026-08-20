-- =============================================================================
-- GATE: test_pos_confirm_payment_method.sql
-- CHANGE: pos-catalogo-pagos (tasks 2.2, 2.4, 2.7, 3.4 RED+GREEN, 3.5 TRIANGULATE)
-- EXTENDIDO por: limpiezas-pagos-admin (G1a/G1b, task 4.5 — casos 4/8/11/12)
--
-- Ejercita rpc_quick_sale / _c29_confirm_order_core de verdad (sesión
-- sintética vía request.jwt.claims, mismo patrón que
-- supabase/tests/test_payment_method_operations.sql). Cubre:
--   (1) payment_method_id de OTRA cuenta → P0404, cero filas persistidas;
--   (2) id + texto en desacuerdo → P0400 payment_method_mismatch;
--   (3) id de forma de pago INACTIVA → P0400 payment_method_inactive;
--   (4) camino legacy sin id, texto 'other' (sembrado) → limpiezas-pagos-admin
--       (D2): resuelve payment_method_id a la forma sembrada, YA NO queda NULL;
--   (5) venta a crédito: postea customer_account_movement + evento
--       CustomerAccountCharged + CustomerAccount.balance, CERO cash_movements;
--   (6) crédito sin cliente → P0400 credit_requires_client ANTES de tocar stock;
--   (7) crédito para un cliente sin CustomerAccount previa → lazy auto-create;
--   (8) kind sin cableado ('transfer') → se persiste como etiqueta, cero
--       cash_movements, cero customer_account_movements, cero bank_movements,
--       evento SaleConfirmed con el kind en el payload;
--   (9) idempotencia: replay con OTRA forma de pago no crea un segundo
--       customer_account_movement ni cambia la imputación persistida;
--   (10) REGRESIÓN: branch_stock, stock_movements.unit_cost_snapshot,
--        sale_items snapshots, día ART y las 2 transiciones de
--        document_status_history siguen intactos sobre la RPC nueva;
--   (11) limpiezas-pagos-admin (D2): camino legacy con texto 'cash' sin id
--        resuelve payment_method_id a la forma sembrada, cash_movement intacto;
--   (12) limpiezas-pagos-admin (D2): camino legacy con texto 'check' SIN
--        método vivo/activo de ese kind → payment_method_id NULL, sin
--        abortar, evento con payment_method=check.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email     text := 'pos-confirm-payment-method-gate@test.local';
  v_other_email      text := 'pos-confirm-payment-method-gate-other@test.local';
  v_user_id          uuid := gen_random_uuid();
  v_other_user_id    uuid := gen_random_uuid();
  v_account_id       uuid;
  v_other_account_id uuid;
  v_branch_id        uuid;
  v_cashbox_id       uuid;
  v_session_id       uuid;
  v_product_id       uuid;
  v_client_id        uuid;
  v_client2_id       uuid;
  v_pm_cash          uuid;
  v_pm_credit        uuid;
  v_pm_transfer      uuid;
  v_pm_card          uuid;   -- se desactiva para el caso (3)
  v_pm_other         uuid;   -- limpiezas-pagos-admin: usado por el caso (4)
  v_pm_check         uuid;   -- limpiezas-pagos-admin (OQ-1): se desactiva para el caso (12)
  v_pm_other_cash    uuid;   -- Efectivo de LA OTRA cuenta
  v_resolved         boolean := false;

  v_result           jsonb;
  v_result2          jsonb;
  v_so_id            uuid;
  v_op_id            uuid;
  v_rejected         boolean;
  v_count            integer;
  v_ca_id            uuid;
  v_balance          numeric;
  v_stock_before     numeric;
  v_stock_after      numeric;
BEGIN
  -- ── Anchors sintéticos (dos cuentas) ──────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate POS Confirm PM'))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_other_user_id, 'authenticated', 'authenticated', v_other_email, now(), now(),
          jsonb_build_object('name', 'Gate POS Confirm PM Other'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id       FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_other_account_id FROM public.account_members WHERE user_id = v_other_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL OR v_other_account_id IS NULL THEN
    RAISE NOTICE 'GATE POS-CONFIRM-PAYMENT-METHOD: no se pudo resolver cuenta para los anchors sintéticos (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id     FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_id    FROM public.cashboxes WHERE branch_id = v_branch_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash       FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_credit     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;
  SELECT id INTO v_pm_transfer   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;
  SELECT id INTO v_pm_card       FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'card' LIMIT 1;
  SELECT id INTO v_pm_other      FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'other' LIMIT 1;
  SELECT id INTO v_pm_check      FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'check' LIMIT 1;
  SELECT id INTO v_pm_other_cash FROM public.payment_methods WHERE account_id = v_other_account_id AND kind = 'cash' LIMIT 1;

  IF v_branch_id IS NULL OR v_cashbox_id IS NULL OR v_pm_cash IS NULL OR v_pm_credit IS NULL
     OR v_pm_transfer IS NULL OR v_pm_card IS NULL OR v_pm_other IS NULL OR v_pm_check IS NULL
     OR v_pm_other_cash IS NULL THEN
    RAISE NOTICE 'GATE POS-CONFIRM-PAYMENT-METHOD: branch/cashbox/catálogo no sembrado para los anchors — degradando sin abortar.';
    RETURN;
  END IF;

  -- Desactivar "Tarjeta" de la cuenta ancla para el caso (3).
  UPDATE public.payment_methods SET is_active = false WHERE id = v_pm_card;

  -- limpiezas-pagos-admin (OQ-1, D2): desactivar "Cheque" para el caso (12)
  -- — simula "sin método sembrado/activo de ese kind" para ejercitar la
  -- rama del camino legacy que NO resuelve nada (aunque 'check' SÍ está
  -- sembrado desde OQ-1, este gate necesita el caso "sin match" igual).
  UPDATE public.payment_methods SET is_active = false WHERE id = v_pm_check;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_pos_cpm_product__', 1000, 400, 'GATE-POS-CPM-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pos_cpm_client__', 'active')
  RETURNING id INTO v_client_id;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pos_cpm_client2__', 'active')
  RETURNING id INTO v_client2_id;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE POS-CONFIRM-PAYMENT-METHOD: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
  ELSE
    v_resolved := true;

    SELECT public.rpc_open_cash_session(v_cashbox_id, 500) INTO v_result;
    v_session_id := (v_result->>'session_id')::uuid;
    IF v_session_id IS NULL THEN
      -- Algunas versiones de rpc_open_cash_session devuelven 'id' en vez de 'session_id'.
      v_session_id := (v_result->>'id')::uuid;
    END IF;
    IF v_session_id IS NULL THEN
      SELECT id INTO v_session_id FROM public.cash_sessions WHERE cashbox_id = v_cashbox_id AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
    END IF;

    -- ══════════════ (1) payment_method_id de OTRA cuenta → P0404 ═════════════
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_quick_sale(
        p_idempotency_key   => 'gate-pos-cpm-1',
        p_client_id         => NULL,
        p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
        -- p_payment_method se omite (default 'other' — sales_orders.payment_method
        -- es NOT NULL, la RPC necesita un placeholder no-nulo para el INSERT
        -- inicial del draft; el P0404 de payment_method_id se dispara antes de
        -- que ese texto importe).
        p_branch_id          => v_branch_id,
        p_payment_method_id  => v_pm_other_cash
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (1): payment_method_id de otra cuenta debería rechazarse con P0404.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.operation_idempotency WHERE user_id = v_user_id AND idempotency_key = 'gate-pos-cpm-1';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (1b): el rechazo debería abortar TODO (incluida la orden draft creada por quick_sale), cero filas de idempotencia esperadas.';
    END IF;
    RAISE NOTICE 'PASS (1): payment_method_id de otra cuenta rechazado con P0404, cero filas persistidas.';

    -- ══════════════ (2) id + texto en desacuerdo → payment_method_mismatch ═══
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_quick_sale(
        p_idempotency_key   => 'gate-pos-cpm-2',
        p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
        p_payment_method     => 'cash',
        p_branch_id          => v_branch_id,
        p_payment_method_id  => v_pm_credit  -- kind real = 'credit', texto dice 'cash'
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE '%payment_method_mismatch%' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (2): id de kind=credit + texto=cash debería rechazarse con payment_method_mismatch.';
    END IF;
    RAISE NOTICE 'PASS (2): payment_method_id y texto en desacuerdo rechazados (payment_method_mismatch).';

    -- ══════════════ (3) id de forma de pago INACTIVA → payment_method_inactive ═
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_quick_sale(
        p_idempotency_key   => 'gate-pos-cpm-3',
        p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
        -- p_payment_method se omite (default 'other') — mismo motivo que (1).
        p_branch_id          => v_branch_id,
        p_payment_method_id  => v_pm_card
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE '%payment_method_inactive%' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (3): una forma de pago inactiva debería rechazarse con payment_method_inactive.';
    END IF;
    RAISE NOTICE 'PASS (3): forma de pago inactiva rechazada (payment_method_inactive).';

    -- ══════════════ (4) camino legacy sin id → resuelve por kind (D2) ════════
    -- limpiezas-pagos-admin (G1b, D2): antes del retiro de la columna, el
    -- camino legacy dejaba payment_method_id NULL siempre. Ahora resuelve la
    -- forma de pago viva y activa de la cuenta con ese kind — 'other' está
    -- sembrado, así que SE IMPUTA (a diferencia del caso (12), que ejercita
    -- la rama sin match).
    SELECT public.rpc_quick_sale(
      p_idempotency_key => 'gate-pos-cpm-4',
      p_items            => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method   => 'other',
      p_branch_id        => v_branch_id
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;

    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND payment_method_id = v_pm_other) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (4): el camino legacy con texto ''other'' debería resolver payment_method_id=% (sembrado) — limpiezas-pagos-admin D2.', v_pm_other;
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales WHERE operation_id = (v_result->>'operation_id')::uuid AND payment_method_id IS DISTINCT FROM v_pm_other) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (4b): las filas legacy de sales deberían nacer con el payment_method_id resuelto (%).', v_pm_other;
    END IF;
    RAISE NOTICE 'PASS (4, limpiezas-pagos-admin D2): confirmación sin payment_method_id explícito resuelve el camino legacy por kind (''other'' sembrado).';

    -- ══════════════ (5) venta a crédito postea cargo en la cuenta corriente ══
    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-5',
      p_client_id         => v_client_id,
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method     => 'credit',
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_credit
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;

    SELECT id, balance INTO v_ca_id, v_balance FROM public.customer_accounts WHERE account_id = v_account_id AND client_id = v_client_id;
    IF v_ca_id IS NULL THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (5): esperaba una CustomerAccount materializada para el cliente.';
    END IF;
    IF v_balance <> 1000 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (5b): CustomerAccount.balance esperado 1000, es %.', v_balance;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
    WHERE customer_account_id = v_ca_id AND movement_type = 'sale' AND amount = 1000 AND balance_after = 1000 AND reference_id = v_so_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (5c): esperaba 1 customer_account_movement tipo sale con amount=balance_after=1000, hay %. ESTE ES EL GATE ESTRELLA — restaura la regresión de julio 2026.', v_count;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_so_id;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (5d): una venta a crédito NO debería generar cash_movements, hay %.', v_count;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'CustomerAccountCharged' AND aggregate_id = v_ca_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (5e): esperaba 1 evento CustomerAccountCharged en el outbox, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (5, GATE ESTRELLA): venta a crédito postea customer_account_movement + evento CustomerAccountCharged + balance, cero cash_movements — regresión de julio 2026 restaurada.';

    -- ══════════════ (6) crédito sin cliente → credit_requires_client ═════════
    SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_quick_sale(
        p_idempotency_key  => 'gate-pos-cpm-6',
        p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
        p_payment_method     => 'credit',
        p_branch_id          => v_branch_id,
        p_payment_method_id  => v_pm_credit
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE '%credit_requires_client%' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (6): crédito sin cliente debería rechazarse con credit_requires_client.';
    END IF;
    SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
    IF v_stock_after <> v_stock_before THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (6b): el guard debe correr ANTES de tocar stock — stock cambió de % a %.', v_stock_before, v_stock_after;
    END IF;
    RAISE NOTICE 'PASS (6): crédito sin cliente rechazado ANTES de tocar stock.';

    -- ══════════════ (7) crédito para cliente SIN CustomerAccount previa ══════
    IF EXISTS (SELECT 1 FROM public.customer_accounts WHERE account_id = v_account_id AND client_id = v_client2_id) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (7 setup): el cliente 2 no debería tener CustomerAccount todavía.';
    END IF;

    PERFORM public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-7',
      p_client_id         => v_client2_id,
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 500, 'subtotal', 500)),
      p_payment_method     => 'credit',
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_credit
    );

    IF NOT EXISTS (SELECT 1 FROM public.customer_accounts WHERE account_id = v_account_id AND client_id = v_client2_id AND balance = 500) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (7): la CustomerAccount del cliente 2 debería materializarse lazy con balance=500.';
    END IF;
    RAISE NOTICE 'PASS (7): CustomerAccount se materializa lazy para un cliente sin cuenta previa.';

    -- ══════════════ (8) kind sin cableado ('transfer') ═══════════════════════
    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-8',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method     => 'transfer',
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_transfer
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;

    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND payment_method_id = v_pm_transfer) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (8): la orden debería quedar imputada a transfer.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_so_id;
    IF v_count <> 0 THEN RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (8b): transfer no debería generar cash_movements.'; END IF;
    SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE reference_id = v_so_id;
    IF v_count <> 0 THEN RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (8c): transfer no debería generar customer_account_movements.'; END IF;
    SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE account_id = v_account_id;
    IF v_count <> 0 THEN RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (8d): transfer no debería generar bank_movements (OQ-A, fuera de alcance).'; END IF;
    -- limpiezas-pagos-admin (task 4.5(i)): el evento SaleConfirmed sigue
    -- transportando el kind efectivo en el payload — la columna se retiró,
    -- el payload NO cambia (D1 de design.md).
    SELECT COUNT(*) INTO v_count FROM public.events
    WHERE event_type = 'SaleConfirmed' AND aggregate_id = v_so_id AND payload->>'payment_method' = 'transfer';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (8e): esperaba el evento SaleConfirmed con payment_method=transfer en el payload, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (8): kind sin cableado (transfer) se persiste como etiqueta pura, sin efectos, con el evento reflejando el kind.';

    -- ══════════════ (9) idempotencia: replay con OTRA forma de pago ═════════
    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-9',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_id,
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_cash
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-9',   -- misma clave
      p_client_id         => v_client_id,
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 5, 'price', 1000, 'subtotal', 5000)),
      p_payment_method     => 'credit',           -- otra forma de pago en el replay (debe ser válida para pasar los guards, aunque se ignore)
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_credit
    ) INTO v_result2;

    -- Nota (comportamiento preexistente, no tocado por este change): quick_sale
    -- crea SIEMPRE una sales_orders draft nueva antes de invocar el core, así
    -- que en un replay el 'sales_order_id' devuelto es el de ESA orden nueva
    -- (que queda huérfana en draft) — la identidad idempotente real es
    -- 'operation_id', que sí debe coincidir con la primera invocación.
    IF (v_result2->>'replayed')::boolean IS NOT TRUE OR (v_result2->>'operation_id')::uuid IS DISTINCT FROM v_op_id THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (9): el replay debería devolver operation_id=% (original) con replayed=true, devolvió %.', v_op_id, v_result2;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE reference_id = v_so_id;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (9b): el replay con kind=credit NO debería crear un customer_account_movement.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND payment_method_id = v_pm_cash) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (9c): la imputación persistida (cash) no debería cambiar por el replay.';
    END IF;
    RAISE NOTICE 'PASS (9): replay con otra forma de pago no crea efectos nuevos ni cambia la imputación persistida.';

    -- ══════════════ (11) camino legacy con texto 'cash' sin id → resuelve ═══
    -- limpiezas-pagos-admin (task 4.5(ii)): confirm legacy con texto 'cash'
    -- sin id → orden imputada a la forma sembrada 'cash' (D2).
    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-11',
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method     => 'cash',
      p_cash_session_id    => v_session_id,
      p_branch_id          => v_branch_id
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;

    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND payment_method_id = v_pm_cash) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (11): el camino legacy con texto ''cash'' debería resolver payment_method_id=% (sembrado).', v_pm_cash;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_so_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (11b): cash resuelto por el camino legacy debería seguir registrando cash_movement, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (11, limpiezas-pagos-admin D2): camino legacy con texto ''cash'' resuelve payment_method_id a la forma sembrada, con su efecto de caja intacto.';

    -- ══════════════ (12) camino legacy 'check' SIN método vivo/activo ═══════
    -- limpiezas-pagos-admin (task 4.5(iii), adaptado a OQ-1: 'check' SÍ está
    -- sembrado desde esta misma migración, pero se desactivó en el setup
    -- para poder ejercitar la rama sin match de D2): confirm legacy con
    -- texto 'check' sin ninguna forma de pago viva/activa de ese kind →
    -- orden con payment_method_id NULL, sin abortar, evento con el kind.
    SELECT public.rpc_quick_sale(
      p_idempotency_key  => 'gate-pos-cpm-12',
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method     => 'check',
      p_branch_id          => v_branch_id
    ) INTO v_result;
    v_so_id := (v_result->>'sales_order_id')::uuid;

    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND payment_method_id IS NULL) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (12): sin forma de pago ''check'' viva/activa, la orden debería quedar payment_method_id NULL.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.events
    WHERE event_type = 'SaleConfirmed' AND aggregate_id = v_so_id AND payload->>'payment_method' = 'check';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (12b): el evento SaleConfirmed debería llevar payment_method=check en el payload aunque no se haya podido imputar, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (12, limpiezas-pagos-admin D2): camino legacy ''check'' sin match confirma con payment_method_id NULL sin abortar, evento con payment_method=check.';

    -- ══════════════ (10) REGRESIÓN: stock, snapshots, día ART, historial ════
    SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
    -- Ventas confirmadas con producto en este gate: (4),(5)x1,(6 rechazada:0),
    -- (7)x1,(8)x1,(9)x1,(11)x1,(12)x1 = 7 unidades descontadas desde 100.
    IF v_stock_after <> 93 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (10a): branch_stock esperado 93 tras 7 ventas de 1 unidad, es %.', v_stock_after;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.stock_movements
      WHERE account_id = v_account_id AND product_id = v_product_id AND type = 'sale'
        AND unit_cost_snapshot = 400
    ) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (10b, regresión): stock_movements debería tener unit_cost_snapshot=400 (costo del producto) intacto sobre la RPC nueva.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
      WHERE s.account_id = v_account_id AND si.product_id = v_product_id
        AND si.name_snapshot = '__gate_pos_cpm_product__' AND si.unit_cost_snapshot = 400
    ) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (10c, regresión #415/#255): sale_items debería seguir congelando name_snapshot/unit_cost_snapshot.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.sales WHERE account_id = v_account_id AND product_id = v_product_id AND date <> public.reporting_local_today()) THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (10d, regresión app-timezone-argentina): sales.date debería ser el día ART (reporting_local_today), no CURRENT_DATE.';
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.document_status_history
    WHERE document_type = 'sales_order' AND document_id = v_so_id
      AND ((from_status IS NULL AND to_status = 'draft') OR (from_status = 'draft' AND to_status = 'confirmed'));
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE POS-CONFIRM-PAYMENT-METHOD FAILED (10e, regresión v3-document-status-history): esperaba 2 transiciones (NULL→draft, draft→confirmed), hay %.', v_count;
    END IF;

    RAISE NOTICE 'PASS (10): sin regresión — branch_stock, unit_cost_snapshot, snapshots de sale_items, día ART y las 2 transiciones de historial siguen intactos sobre la RPC nueva.';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre (dos cuentas) ──────────────────────────────────────
  DELETE FROM public.document_status_history WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.events                  WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.customer_account_movements WHERE customer_account_id IN (SELECT id FROM public.customer_accounts WHERE account_id IN (v_account_id, v_other_account_id));
  DELETE FROM public.customer_accounts       WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.cash_movements          WHERE session_id IN (SELECT id FROM public.cash_sessions WHERE cashbox_id = v_cashbox_id);
  DELETE FROM public.cash_sessions           WHERE cashbox_id = v_cashbox_id;
  DELETE FROM public.sale_items              WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_id, v_other_account_id));
  DELETE FROM public.stock_movements         WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.sales                   WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.sales_order_items       WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.sales_orders            WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.operation_idempotency   WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.branch_stock            WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.clients                 WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.products                WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.payment_methods         WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_other_account_id));
  DELETE FROM public.branches                WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.account_members         WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.accounts                WHERE owner_user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.profiles                WHERE id IN (v_user_id, v_other_user_id);
  DELETE FROM public.email_logs              WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM auth.users                     WHERE id IN (v_user_id, v_other_user_id);

  IF v_resolved THEN
    RAISE NOTICE 'GATE POS-CONFIRM-PAYMENT-METHOD PASSED: resolución de kind, guards P0404/P0400, restauración del bloque credit (gate estrella), lazy CustomerAccount, kind sin cableado, idempotencia y regresión (#255/#415/app-timezone/status-history) — todo verde.';
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL OR v_other_account_id IS NOT NULL THEN
        DELETE FROM public.document_status_history WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.events                  WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.customer_account_movements WHERE customer_account_id IN (SELECT id FROM public.customer_accounts WHERE account_id IN (v_account_id, v_other_account_id));
        DELETE FROM public.customer_accounts       WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.cash_movements          WHERE session_id IN (SELECT id FROM public.cash_sessions WHERE cashbox_id = v_cashbox_id);
        DELETE FROM public.cash_sessions           WHERE cashbox_id = v_cashbox_id;
        DELETE FROM public.sale_items              WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_id, v_other_account_id));
        DELETE FROM public.stock_movements         WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.sales                   WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.sales_order_items       WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.sales_orders            WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.operation_idempotency   WHERE user_id IN (v_user_id, v_other_user_id);
        DELETE FROM public.branch_stock            WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.clients                 WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.products                WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.payment_methods         WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_other_account_id));
        DELETE FROM public.branches                WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.account_members         WHERE user_id IN (v_user_id, v_other_user_id);
        DELETE FROM public.accounts                WHERE owner_user_id IN (v_user_id, v_other_user_id);
      END IF;
      DELETE FROM public.profiles   WHERE id IN (v_user_id, v_other_user_id);
      DELETE FROM public.email_logs WHERE user_id IN (v_user_id, v_other_user_id);
      DELETE FROM auth.users        WHERE id IN (v_user_id, v_other_user_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
