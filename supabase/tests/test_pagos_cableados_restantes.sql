-- =============================================================================
-- GATE: test_pagos_cableados_restantes.sql
-- CHANGE: pagos-cableados-restantes (tasks 3.1-3.3, 5.1/5.4, 6.1/6.4, 7.1/7.3,
-- 8.1/8.4, 9.1/9.5 RED+GREEN+TRIANGULATE)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_pos_confirm_payment_method.sql) las piezas nuevas de este change:
--   (3) el helper _pay_register_party_charge — cliente, proveedor,
--       invalid_party_kind, creación lazy de cuenta, balance_after acumulado;
--   (5) rpc_create_sale_operation_v2 — crédito postea cargo, crédito sin
--       cliente falla ANTES de tocar stock, no-crédito no toca la cuenta;
--   (5.3/6.2) la rama LEGACY de rpc_create_sale_operation (flag off) queda
--       consistente con la v2 — mismo trío crédito/caja;
--   (6) opt-in de caja — las tres condiciones de servidor (kind, sesión
--       abierta en la sucursal EFECTIVA, fecha=hoy) + expected_balance;
--   (7) rpc_create_purchase_operation — el evento PurchaseCreated ya no
--       hardcodea 'credit', lleva el kind real;
--   (8) _journal_post_from_event — wallet rutea a 1110 en las 3 ramas con
--       predicado bancario (tabla de 7 kind) + PurchaseCreated SIN CAMBIOS;
--   (9) D6 — inmutabilidad de operaciones con cargo o movimiento posteado,
--       en AMBAS convenciones de reference_id (operation_id del formulario,
--       sales_orders.id del POS), y que operaciones SIN cargo/movimiento
--       siguen editables.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email      text := 'pagos-cableados-restantes-gate@test.local';
  v_user_id           uuid := gen_random_uuid();
  v_account_id        uuid;
  v_branch_id         uuid;
  v_branch2_id        uuid;
  v_cashbox_id        uuid;
  v_cashbox2_id       uuid;
  v_session_id        uuid;
  v_session2_id       uuid;
  v_product_id        uuid;
  v_client_id         uuid;
  v_client2_id        uuid;
  v_supplier_id       uuid;
  v_pm_cash           uuid;
  v_pm_credit         uuid;
  v_pm_transfer       uuid;
  v_pm_card           uuid;
  v_pm_check          uuid;
  v_pm_wallet         uuid;
  v_pm_other          uuid;
  v_resolved          boolean := false;

  v_result            jsonb;
  v_ca_id             uuid;
  v_sa_id             uuid;
  v_sa2_id            uuid;
  v_balance           numeric;
  v_count             integer;
  v_rejected          boolean;
  v_op_id             uuid;
  v_op2_id            uuid;
  v_so_id             uuid;
  v_sale_id           uuid;
  v_purchase_id       uuid;
  v_event_id          uuid;
  v_event_row         public.events;
  v_entry_id          uuid;
  v_debit_code        text;
  v_kind              text;
  v_expected_code     text;
  v_stock_before      numeric;
BEGIN
  -- ── Anchor sintético ───────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Pagos Cableados Restantes'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PAGOS-CABLEADOS-RESTANTES: no se pudo resolver cuenta para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id  FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_id FROM public.cashboxes WHERE branch_id = v_branch_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;
  SELECT id INTO v_pm_card     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'card' LIMIT 1;
  SELECT id INTO v_pm_wallet   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'wallet' LIMIT 1;
  SELECT id INTO v_pm_other    FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'other' LIMIT 1;

  IF v_branch_id IS NULL OR v_cashbox_id IS NULL OR v_pm_cash IS NULL OR v_pm_credit IS NULL
     OR v_pm_transfer IS NULL OR v_pm_card IS NULL OR v_pm_wallet IS NULL OR v_pm_other IS NULL THEN
    RAISE NOTICE 'GATE PAGOS-CABLEADOS-RESTANTES: branch/cashbox/catálogo (6 kind sembrados) no disponible para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- El seed de metodos-pago-operaciones (D11) siembra 6 de los 7 kind del
  -- catálogo (cash/transfer/card/wallet/credit/other) — 'check' NO se
  -- siembra por defecto (nunca se ejerció en prod). Se agrega a mano acá
  -- sólo para la tabla de 7 casos de la sección (8).
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
  VALUES (v_account_id, '__gate_pcr_check__', 'check', 99)
  RETURNING id INTO v_pm_check;

  -- Segunda sucursal + cashbox, para el caso "sesión abierta en OTRA sucursal" (6b).
  INSERT INTO public.branches (account_id, name, is_active, status)
  VALUES (v_account_id, '__gate_pcr_branch2__', true, 'active')
  RETURNING id INTO v_branch2_id;

  INSERT INTO public.cashboxes (branch_id, name, currency)
  VALUES (v_branch2_id, '__gate_pcr_cashbox2__', 'ARS')
  RETURNING id INTO v_cashbox2_id;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_pcr_product__', 1000, 400, 'GATE-PCR-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pcr_client__', 'active')
  RETURNING id INTO v_client_id;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pcr_client2__', 'active')
  RETURNING id INTO v_client2_id;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_id, '__gate_pcr_supplier__')
  RETURNING id INTO v_supplier_id;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE PAGOS-CABLEADOS-RESTANTES: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;
  v_resolved := true;

  -- ════════════════════════ (3) Helper _pay_register_party_charge ═══════════

  -- (3a) cliente sin CustomerAccount previa → lazy create + movimiento + evento
  v_ca_id := public._pay_register_party_charge(v_account_id, 'customer', v_client_id, 750, gen_random_uuid(), gen_random_uuid());
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 750 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3a): CustomerAccount.balance esperado 750, es %.', v_balance;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id AND movement_type = 'sale' AND amount = 750 AND balance_after = 750;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3a-mov): esperaba 1 customer_account_movement, hay %.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'CustomerAccountCharged' AND aggregate_id = v_ca_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3a-evt): esperaba 1 evento CustomerAccountCharged, hay %.', v_count;
  END IF;

  -- (3b) TRIANGULATE: mismo cliente, cuenta YA existente → balance_after ACUMULA
  PERFORM public._pay_register_party_charge(v_account_id, 'customer', v_client_id, 250, gen_random_uuid(), gen_random_uuid());
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3b): balance acumulado esperado 1000 (750+250), es %.', v_balance;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id AND balance_after = 1000;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3b-mov): esperaba el segundo movimiento con balance_after=1000, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3a-3b): helper customer — lazy create + movimiento + evento + balance_after acumulado.';

  -- (3c) proveedor sin SupplierAccount previa → lazy create + movimiento + evento
  v_sa_id := public._pay_register_party_charge(v_account_id, 'supplier', v_supplier_id, 400, gen_random_uuid(), gen_random_uuid());
  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 400 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3c): SupplierAccount.balance esperado 400, es %.', v_balance;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.supplier_account_movements WHERE supplier_account_id = v_sa_id AND movement_type = 'purchase' AND amount = 400 AND balance_after = 400;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3c-mov): esperaba 1 supplier_account_movement, hay %.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SupplierAccountCharged' AND aggregate_id = v_sa_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3c-evt): esperaba 1 evento SupplierAccountCharged, hay %.', v_count;
  END IF;

  -- (3d) TRIANGULATE: mismo proveedor, cuenta YA existente → balance_after ACUMULA
  v_sa2_id := public._pay_register_party_charge(v_account_id, 'supplier', v_supplier_id, 100, gen_random_uuid(), gen_random_uuid());
  IF v_sa2_id <> v_sa_id THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3d): el segundo cargo debería reusar la MISMA SupplierAccount (lazy get-or-create), obtuve una distinta.';
  END IF;
  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 500 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3d-bal): balance acumulado esperado 500 (400+100), es %.', v_balance;
  END IF;
  RAISE NOTICE 'PASS (3c-3d): helper supplier — lazy create + movimiento + evento + balance_after acumulado (misma cuenta reusada).';

  -- (3e) invalid_party_kind
  v_rejected := false;
  BEGIN
    PERFORM public._pay_register_party_charge(v_account_id, 'bogus', v_client_id, 100, gen_random_uuid(), gen_random_uuid());
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%invalid_party_kind%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (3e): p_party_kind fuera del vocabulario cerrado debería rechazarse con invalid_party_kind.';
  END IF;
  RAISE NOTICE 'PASS (3e): invalid_party_kind rechazado para un party_kind fuera de customer|supplier.';

  -- ══════════════ (5) rpc_create_sale_operation_v2 — crédito ═══════════════

  -- (5a) crédito postea cargo (cliente nuevo, sin CustomerAccount previa)
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-pcr-5a',
    p_client_id          => v_client2_id,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_credit
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT id, balance INTO v_ca_id, v_balance FROM public.customer_accounts WHERE account_id = v_account_id AND client_id = v_client2_id;
  IF v_ca_id IS NULL OR v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (5a): esperaba CustomerAccount con balance=1000 para el formulario a crédito, balance=%.', v_balance;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id AND reference_id = v_op_id AND amount = 1000;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (5a-mov, ESTRELLA): el formulario de venta a crédito debe postear cargo — 223 operaciones históricas no lo hacían. Esperaba 1 movement con reference_id=operation_id, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (5a, GATE ESTRELLA): rpc_create_sale_operation_v2 con kind=credit postea customer_account_movement — el camino del formulario queda cableado.';

  -- (5b) crédito sin cliente → credit_requires_client, ANTES de tocar stock
  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key => 'gate-pcr-5b',
      p_client_id        => NULL,
      p_date              => public.reporting_local_today(),
      p_currency          => 'ARS',
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000, 'quantity', 1)),
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%credit_requires_client%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (5b): venta a crédito sin cliente debería rechazarse con credit_requires_client.';
  END IF;
  IF (SELECT quantity FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id) <> v_stock_before THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (5b-stock): el guard debe correr ANTES del descuento de stock — el stock cambió pese al rechazo.';
  END IF;
  RAISE NOTICE 'PASS (5b): credit_requires_client corre antes de tocar stock.';

  -- (5c) no-crédito no toca la cuenta corriente
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key => 'gate-pcr-5c',
    p_client_id        => v_client2_id,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 500, 'quantity', 1)),
    p_branch_id          => v_branch_id,
    p_payment_method_id  => v_pm_transfer
  ) INTO v_result;
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (5c): una venta transfer NO debería tocar CustomerAccount.balance (seguía en 1000), quedó en %.', v_balance;
  END IF;
  RAISE NOTICE 'PASS (5c): kind no-credit (transfer) no postea cargo en cuenta corriente.';

  -- ══════════════ (6) Opt-in de caja en rpc_create_sale_operation_v2 ════════

  SELECT public.rpc_open_cash_session(v_cashbox_id, 500) INTO v_result;
  v_session_id := COALESCE((v_result->>'session_id')::uuid, (v_result->>'id')::uuid);
  IF v_session_id IS NULL THEN
    SELECT id INTO v_session_id FROM public.cash_sessions WHERE cashbox_id = v_cashbox_id AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;

  SELECT public.rpc_open_cash_session(v_cashbox2_id, 300) INTO v_result;
  v_session2_id := COALESCE((v_result->>'session_id')::uuid, (v_result->>'id')::uuid);
  IF v_session2_id IS NULL THEN
    SELECT id INTO v_session2_id FROM public.cash_sessions WHERE cashbox_id = v_cashbox2_id AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;

  -- (6a) kind no-cash + p_cash_session_id → cash_optin_requires_cash_kind
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-pcr-6a',
      p_client_id          => NULL,
      p_date                => public.reporting_local_today(),
      p_currency            => 'ARS',
      p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      p_branch_id            => v_branch_id,
      p_payment_method_id    => v_pm_transfer,
      p_cash_session_id      => v_session_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%cash_optin_requires_cash_kind%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6a): p_cash_session_id con kind=transfer debería rechazarse con cash_optin_requires_cash_kind.';
  END IF;

  -- (6b) sesión abierta en OTRA sucursal → cash_optin_requires_open_session
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-pcr-6b',
      p_client_id          => NULL,
      p_date                => public.reporting_local_today(),
      p_currency            => 'ARS',
      p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      p_branch_id            => v_branch_id,        -- venta en branch_id
      p_payment_method_id    => v_pm_cash,
      p_cash_session_id      => v_session2_id        -- sesión abierta en branch2_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%cash_optin_requires_open_session%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6b): sesión de OTRA sucursal debería rechazarse con cash_optin_requires_open_session.';
  END IF;

  -- (6c) fecha distinta de hoy → cash_optin_requires_today
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-pcr-6c',
      p_client_id          => NULL,
      p_date                => public.reporting_local_today() - 1,
      p_currency            => 'ARS',
      p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      p_branch_id            => v_branch_id,
      p_payment_method_id    => v_pm_cash,
      p_cash_session_id      => v_session_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%cash_optin_requires_today%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6c): fecha de ayer con opt-in de caja debería rechazarse con cash_optin_requires_today.';
  END IF;
  RAISE NOTICE 'PASS (6a-6c): las tres condiciones de servidor del opt-in de caja (kind, sucursal efectiva, fecha=hoy) rechazan correctamente.';

  -- (6d) opt-in exitoso → cash_movement + expected_balance sube
  SELECT expected_balance INTO v_balance FROM public.cash_sessions WHERE id = v_session_id;
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-pcr-6d',
    p_client_id          => NULL,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_cash,
    p_cash_session_id      => v_session_id
  ) INTO v_result;
  v_op2_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_id AND reference_id = v_op2_id AND amount = 200;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6d, ESTRELLA): esperaba 1 cash_movement de 200 con reference_id=operation_id, hay %. El efectivo del formulario debe existir para la caja.', v_count;
  END IF;
  IF (SELECT expected_balance FROM public.cash_sessions WHERE id = v_session_id) <> v_balance + 200 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6d-bal): expected_balance debería subir en 200 tras el opt-in.';
  END IF;

  -- (6e) TRIANGULATE: venta idéntica SIN opt-in (p_cash_session_id NULL) — cero movimiento
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-pcr-6e',
    p_client_id          => NULL,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_cash
    -- p_cash_session_id omitido — D5: ausencia = no-op
  ) INTO v_result;
  IF (SELECT expected_balance FROM public.cash_sessions WHERE id = v_session_id) <> v_balance + 200 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (6e): sin p_cash_session_id, expected_balance NO debería moverse — la ausencia de opt-in es no-op (D5).';
  END IF;
  RAISE NOTICE 'PASS (6d-6e, GATE ESTRELLA): opt-in de caja postea cash_movement + expected_balance; sin opt-in, cero efecto — asimetría D5 intacta.';

  -- ══════════ (5.3/6.2) La rama LEGACY (flag off) queda consistente ═════════
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account_id, 'sale_items_rpc_v2', false)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = false;

  SELECT public.rpc_create_sale_operation(
    p_idempotency_key   => 'gate-pcr-legacy-credit',
    p_client_id          => v_client2_id,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 300, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_credit
  ) INTO v_result;
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 1300 THEN  -- 1000 (5a) + 300 (legacy)
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (legacy-credit): rama legacy (flag off) debería postear el mismo cargo que la v2 — balance esperado 1300, es %.', v_balance;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'gate-pcr-legacy-credit-noclient',
      p_client_id        => NULL,
      p_date              => public.reporting_local_today(),
      p_currency          => 'ARS',
      p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      p_branch_id          => v_branch_id,
      p_payment_method_id  => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%credit_requires_client%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (legacy-credit-noclient): la rama legacy debe exigir credit_requires_client igual que la v2.';
  END IF;

  SELECT public.rpc_create_sale_operation(
    p_idempotency_key   => 'gate-pcr-legacy-cash',
    p_client_id          => NULL,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 150, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_cash,
    p_cash_session_id      => v_session_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_id AND reference_id = v_op_id AND amount = 150;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (legacy-cash): la rama legacy debe honrar el opt-in de caja igual que la v2.';
  END IF;
  RAISE NOTICE 'PASS (legacy): rpc_create_sale_operation con el flag sale_items_rpc_v2 en false replica crédito + opt-in de caja — ambas ramas del strangler consistentes.';

  UPDATE public.account_feature_flags SET enabled = true WHERE account_id = v_account_id AND flag_key = 'sale_items_rpc_v2';

  -- ══════════════ (7) rpc_create_purchase_operation — kind real al evento ═══

  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-pcr-7-transfer',
    p_date             => public.reporting_local_today(),
    p_description      => '__gate_pcr_purchase_transfer__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_transfer
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT payload->>'payment_method' INTO v_kind FROM public.events WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_id;
  IF v_kind <> 'transfer' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (7-transfer, ESTRELLA): PurchaseCreated.payload.payment_method esperado ''transfer'', es ''%''. Antes de este change el literal era SIEMPRE ''credit'' — las 38 compras de prod hoy postean todas a 2100 sin importar cómo se pagaron.', v_kind;
  END IF;

  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-pcr-7-cash',
    p_date             => public.reporting_local_today(),
    p_description      => '__gate_pcr_purchase_cash__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_cash
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT payload->>'payment_method' INTO v_kind FROM public.events WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_id;
  IF v_kind <> 'cash' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (7-cash): PurchaseCreated.payload.payment_method esperado ''cash'', es ''%''.', v_kind;
  END IF;

  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-pcr-7-none',
    p_date             => public.reporting_local_today(),
    p_description      => '__gate_pcr_purchase_none__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id         => v_branch_id
    -- p_payment_method_id omitido
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT payload->>'payment_method' INTO v_kind FROM public.events WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_id;
  IF v_kind <> 'credit' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (7-none): sin payment_method_id el COALESCE debe preservar ''credit'' (comportamiento histórico), es ''%''.', v_kind;
  END IF;
  RAISE NOTICE 'PASS (7, GATE ESTRELLA): rpc_create_purchase_operation emite el kind REAL (transfer/cash) y preserva credit por COALESCE cuando no hay forma de pago imputada.';

  -- ══════════════ (8) _journal_post_from_event — ruteo bancario + wallet ════

  -- (8a) tabla de 7 kind sobre SaleConfirmed → cuenta de débito esperada
  FOR v_kind, v_expected_code IN
    SELECT * FROM (VALUES
      ('cash',     '1100'),
      ('other',    '1100'),
      ('credit',   '1300'),
      ('transfer', '1110'),
      ('card',     '1110'),
      ('check',    '1110'),
      ('wallet',   '1110')   -- pagos-cableados-restantes (D7/OQ-1): antes caía en 1100
    ) AS t(kind, code)
  LOOP
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (v_account_id, 'SaleConfirmed', 'SalesOrder', gen_random_uuid(),
      jsonb_build_object(
        'account_id', v_account_id, 'sales_order_id', gen_random_uuid(),
        'operation_id', gen_random_uuid(), 'total', 555, 'payment_method', v_kind
      ), now())
    RETURNING id INTO v_event_id;

    SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;
    PERFORM public._journal_post_from_event(v_event_row);

    SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
    SELECT jl.account_code INTO v_debit_code FROM public.journal_lines jl WHERE jl.entry_id = v_entry_id AND jl.side = 'debit';

    IF v_debit_code <> v_expected_code THEN
      RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (8a-%): SaleConfirmed con payment_method=% debería debitar %, debitó %.', v_kind, v_kind, v_expected_code, v_debit_code;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (8a, GATE ESTRELLA): SaleConfirmed rutea correctamente los 7 kind — wallet ahora debita 1110 Banco (antes caía en 1100 por omisión).';

  -- (8b) PaymentReceived / PaymentMade — wallet también rutea a 1110
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_id, 'PaymentReceived', 'CustomerAccount', gen_random_uuid(),
    jsonb_build_object('amount', 321, 'payment_method', 'wallet', 'payment_id', gen_random_uuid()), now())
  RETURNING id INTO v_event_id;
  SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;
  PERFORM public._journal_post_from_event(v_event_row);
  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
  SELECT jl.account_code INTO v_debit_code FROM public.journal_lines jl WHERE jl.entry_id = v_entry_id AND jl.side = 'debit';
  IF v_debit_code <> '1110' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (8b-received): PaymentReceived con wallet debería debitar 1110, debitó %.', v_debit_code;
  END IF;

  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_id, 'PaymentMade', 'SupplierAccount', gen_random_uuid(),
    jsonb_build_object('amount', 321, 'payment_method', 'wallet', 'payment_id', gen_random_uuid()), now())
  RETURNING id INTO v_event_id;
  SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;
  PERFORM public._journal_post_from_event(v_event_row);
  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
  SELECT jl.account_code INTO v_debit_code FROM public.journal_lines jl WHERE jl.entry_id = v_entry_id AND jl.side = 'credit';
  IF v_debit_code <> '1110' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (8b-made): PaymentMade con wallet debería acreditar 1110, acreditó %.', v_debit_code;
  END IF;
  RAISE NOTICE 'PASS (8b): PaymentReceived y PaymentMade también rutean wallet a 1110 Banco.';

  -- (8c) PurchaseCreated — SIN CAMBIOS: wallet sigue cayendo en 2100 Proveedores
  -- (no tiene predicado v_is_bank — hallazgo documentado en la migración).
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_id, 'PurchaseCreated', 'Purchase', gen_random_uuid(),
    jsonb_build_object('account_id', v_account_id, 'operation_id', gen_random_uuid(), 'total', 555, 'payment_method', 'wallet', 'neto', NULL, 'iva_amount', NULL), now())
  RETURNING id INTO v_event_id;
  SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;
  PERFORM public._journal_post_from_event(v_event_row);
  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
  SELECT jl.account_code INTO v_debit_code FROM public.journal_lines jl WHERE jl.entry_id = v_entry_id AND jl.side = 'credit';
  IF v_debit_code <> '2100' THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (8c): PurchaseCreated con wallet debería SEGUIR acreditando 2100 Proveedores (sin predicado bancario en esta rama), acreditó %.', v_debit_code;
  END IF;
  RAISE NOTICE 'PASS (8c): PurchaseCreated queda SIN CAMBIOS — wallet sigue en 2100 Proveedores (alcance recortado, documentado en la migración).';

  -- ══════════════ (9) D6 — inmutabilidad de operaciones con cargo/movimiento ═

  -- (9a) venta a crédito del FORMULARIO (reference_id = operation_id) → edición bloqueada
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op2_id LIMIT 1;  -- reusa 5a's op? no: usemos el de 5a
  SELECT s.id, s.operation_id INTO v_sale_id, v_op_id
  FROM public.sales s
  JOIN public.customer_account_movements cam ON cam.reference_id = s.operation_id
  WHERE s.account_id = v_account_id
  ORDER BY s.created_at DESC LIMIT 1;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      p_sale_ids => ARRAY[v_sale_id],
      p_client_id => v_client2_id,
      p_date => public.reporting_local_today(),
      p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (9a, ESTRELLA): editar una venta del FORMULARIO con cargo de cuenta corriente posteado debería fallar con P0423.';
  END IF;

  -- (9b) venta con movimiento de caja posteado (formulario, reference_id=operation_id) → bloqueada
  SELECT s.id INTO v_sale_id
  FROM public.sales s
  JOIN public.cash_movements cm ON cm.reference_id = s.operation_id
  WHERE s.account_id = v_account_id
  ORDER BY s.created_at DESC LIMIT 1;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      p_sale_ids => ARRAY[v_sale_id],
      p_client_id => NULL,
      p_date => public.reporting_local_today(),
      p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (9b, ESTRELLA): editar una venta del FORMULARIO con movimiento de caja posteado debería fallar con P0423.';
  END IF;
  RAISE NOTICE 'PASS (9a-9b, GATE ESTRELLA): D6 bloquea la edición de operaciones del FORMULARIO con cargo o movimiento posteado (reference_id=operation_id).';

  -- (9c) venta POS a crédito (reference_id = sales_orders.id, NO operation_id) → también bloqueada
  SELECT public.rpc_quick_sale(
    p_idempotency_key  => 'gate-pcr-9c-quicksale',
    p_client_id         => v_client2_id,
    p_items              => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
    p_payment_method     => 'credit',
    p_branch_id          => v_branch_id,
    p_payment_method_id  => v_pm_credit
  ) INTO v_result;
  v_so_id := (v_result->>'sales_order_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = (v_result->>'operation_id')::uuid LIMIT 1;

  -- Confirma la premisa: el cargo del POS referencia sales_orders.id, NO sales.operation_id.
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE reference_id = v_so_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (9c-premisa): el cargo del POS debería referenciar sales_orders.id (%), no lo encontré.', v_so_id;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      p_sale_ids => ARRAY[v_sale_id],
      p_client_id => v_client2_id,
      p_date => public.reporting_local_today(),
      p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (9c, ESTRELLA): editar una venta del POS con cargo referenciado por sales_orders.id (no operation_id) debería fallar con P0423 también — las dos convenciones de reference_id deben cubrirse.';
  END IF;
  RAISE NOTICE 'PASS (9c, GATE ESTRELLA): D6 cubre AMBAS convenciones de reference_id — POS (sales_orders.id) y formulario (operation_id).';

  -- (9d) venta SIN cargo ni movimiento → sigue editable (impacto retroactivo cero)
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-pcr-9d-plain',
    p_client_id          => NULL,
    p_date                => public.reporting_local_today(),
    p_currency            => 'ARS',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 50, 'quantity', 1)),
    p_branch_id            => v_branch_id,
    p_payment_method_id    => v_pm_other
  ) INTO v_result;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = (v_result->>'operation_id')::uuid LIMIT 1;

  PERFORM public.rpc_atomic_update_sale_operation(
    p_sale_ids => ARRAY[v_sale_id],
    p_client_id => NULL,
    p_date => public.reporting_local_today(),
    p_currency => 'ARS',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 60, 'quantity', 1))
  );
  RAISE NOTICE 'PASS (9d): una venta SIN cargo ni movimiento posteado sigue siendo editable — D6 no sobre-bloquea.';

  -- (9e) compra con cargo de cuenta corriente (vía el helper, simulando el
  -- futuro camino de compras-proveedor-cuenta-corriente) → edición bloqueada
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-pcr-9e-purchase',
    p_date             => public.reporting_local_today(),
    p_description      => '__gate_pcr_purchase_charged__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  PERFORM public._pay_register_party_charge(v_account_id, 'supplier', v_supplier_id, 100, v_op_id, v_op_id);

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      p_purchase_ids => ARRAY[v_purchase_id],
      p_date => public.reporting_local_today(),
      p_description => '__gate_pcr_purchase_charged_edit__',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 110, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAGOS-CABLEADOS-RESTANTES FAILED (9e): editar una compra con cargo de cuenta corriente posteado debería fallar con P0423 (espejo del guard de venta, task 9.3).';
  END IF;

  -- (9f) compra SIN cargo → sigue editable
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-pcr-9f-purchase',
    p_date             => public.reporting_local_today(),
    p_description      => '__gate_pcr_purchase_plain__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id         => v_branch_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids => ARRAY[v_purchase_id],
    p_date => public.reporting_local_today(),
    p_description => '__gate_pcr_purchase_plain_edit__',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 120, 'quantity', 1))
  );
  RAISE NOTICE 'PASS (9e-9f): rpc_atomic_update_purchase_operation espeja el guard D6 (bloquea con cargo, no bloquea sin él) — impacto retroactivo cero (0 supplier_account_movements en prod hoy).';

  RAISE NOTICE 'PASS: gate pagos-cableados-restantes completo — helper, formulario a crédito, opt-in de caja, kind real en compras, ruteo bancario con wallet, e inmutabilidad D6 en ambas convenciones de reference_id.';
END $$;
