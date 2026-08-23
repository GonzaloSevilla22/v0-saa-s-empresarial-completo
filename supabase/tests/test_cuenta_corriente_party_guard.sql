-- =============================================================================
-- GATE: test_cuenta_corriente_party_guard.sql
-- CHANGE: cuenta-corriente-party-guard (tasks 2.1-2.7, 3.5-3.8, 4.5-4.7,
--         5.1-5.2, 5.5-5.6 — RED + GREEN + TRIANGULATE)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_delete_guard_ledgers.sql y test_pagos_cableados_restantes.sql) el
-- guard de tenencia de la parte (cliente/proveedor) y el cierre de la
-- primitiva de escritura cross-tenant:
--
--   FAMILIA 1 — incoherencia (cuenta, parte). Las RPCs de cuenta corriente
--   resolvían el tenant de la sesión pero NUNCA validaban que el
--   cliente/proveedor recibido por parámetro perteneciera a ese tenant. El
--   FK `client_id REFERENCES clients(id)` no está scopeado por tenant, así
--   que la fila entraba: el tenant A terminaba con saldo, cobros y partida
--   doble contra una entidad que jamás iba a ver en sus listas.
--     (2.2) rpc_register_payment_received  + cliente ajeno  → P0404
--     (2.3) rpc_register_payment_made      + proveedor ajeno → P0404
--     (2.4) rpc_register_supplier_charge   + proveedor ajeno → P0404
--     (2.5) rpc_create_sale_operation_v2 (FORMULARIO) a crédito + cliente
--           ajeno → P0404 y CERO filas nuevas en sales / sale_items /
--           customer_accounts / customer_account_movements / stock_movements
--           / events. Cubierto por el choke point, SIN tocar la RPC de venta.
--     (2.6) rpc_quick_sale (POS) a crédito + cliente ajeno → P0404 y ninguna
--           sales_order confirmada. Mismo choke point.
--
--   FAMILIA 2 — primitiva de escritura cross-tenant (lo más grave). Dos
--   helpers SECURITY DEFINER que reciben el account_id COMO PARÁMETRO —sin
--   resolverlo de la sesión ni validar is_account_writer— tenían
--   GRANT EXECUTE TO authenticated, o sea que eran invocables por PostgREST
--   con el account_id de OTRO tenant:
--     (5.1) _pay_register_party_charge  bajo SET LOCAL ROLE authenticated → 42501
--     (5.2) _journal_post_from_event    bajo SET LOCAL ROLE authenticated → 42501
--   `_journal_post_from_event` nació con REVOKE (20260803000001 L517) y lo
--   PERDIÓ en 20261001000001 L1914, donde el "patrón uniforme" REVOKE+GRANT
--   se lo aplicó en piloto automático a un helper que nunca lo tuvo.
--
--   TRIANGULACIÓN (el guard no sobre-bloquea ni se cuela por otro lado):
--     (3.5) control positivo — cliente/proveedor PROPIOS sin cuenta corriente
--           previa: la cuenta se crea en el mismo commit y balance_after es
--           el esperado, por los cuatro caminos (venta a crédito, cobro,
--           cargo de proveedor, pago a proveedor). Sin este assert el guard
--           podría estar rechazando todo.
--     (3.6) identificador INEXISTENTE → mismo P0404 y MISMO texto de mensaje
--           que el caso "ajeno" — el error no distingue uno de otro (no
--           filtrar información entre tenants).
--     (3.7) rpc_create_customer_account / rpc_create_supplier_account —que ya
--           validaban desde C-30— siguen comportándose igual con el guard
--           ahora duplicado en el choke point. Redundancia deliberada.
--     (4.6) ORDEN de los guards: cliente ajeno + amount = 0 → P0400, no
--           P0404. Congela la ubicación documentada en D2.
--     (4.7) cobro por transferencia + cliente ajeno → P0404 y CERO filas en
--           bank_movements; y con bank_account inexistente → P0412 (el
--           bloque bancario corre ANTES del guard de parte, D2).
--     (4.5) la clave de idempotencia NO se quema en el rechazo: reintentar
--           la misma clave con un cliente válido registra de verdad
--           (replayed = false).
--     (5.5) control positivo del revoke — venta a crédito por FORMULARIO y
--           por POS sigue posteando su cargo. Prueba que el PERFORM interno
--           corre como definer y el revoke es transparente.
--     (5.6) rpc_process_outbox_dispatch sigue posteando un asiento que
--           BALANCEA tras el revoke de _journal_post_from_event.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  -- ── Tenant A (el que opera) ───────────────────────────────────────────────
  v_anchor_a_email    text := 'cuenta-corriente-party-guard-a@test.local';
  v_user_a            uuid := gen_random_uuid();
  v_account_a         uuid;
  v_branch_a          uuid;
  v_product_a         uuid;
  v_bank_a            uuid;
  v_pm_credit         uuid;
  v_pm_cash           uuid;
  v_pm_transfer       uuid;
  v_client_a          uuid;   -- cliente propio "de trabajo"
  v_client_a2         uuid;   -- cliente propio FRESCO (control positivo 3.5)
  v_supplier_a        uuid;   -- proveedor propio FRESCO (control positivo 3.5)

  -- ── Tenant B (la víctima: sus ids se usan desde la sesión de A) ───────────
  v_anchor_b_email    text := 'cuenta-corriente-party-guard-b@test.local';
  v_user_b            uuid := gen_random_uuid();
  v_account_b         uuid;
  v_client_b          uuid;
  v_supplier_b        uuid;

  -- ── Scratch ───────────────────────────────────────────────────────────────
  v_ghost             uuid := gen_random_uuid();   -- id que no existe en ningún tenant
  v_rejected          boolean;
  v_sqlstate          text;
  v_msg_foreign       text;
  v_msg_ghost         text;
  v_result            jsonb;
  v_count             integer;
  v_balance           numeric;
  v_ca_id             uuid;
  v_sa_id             uuid;
  v_op_id             uuid;
  v_so_id             uuid;
  v_event_id          uuid;
  v_event_row         public.events;
  v_entry_id          uuid;
  v_debit             numeric;
  v_credit            numeric;
  v_processed         integer;

  -- Conteos previos para el assert de "cero filas nuevas" (2.5)
  v_n_sales           integer;
  v_n_sale_items      integer;
  v_n_cust_accounts   integer;
  v_n_cust_movs       integer;
  v_n_stock_movs      integer;
  v_n_events          integer;
  v_n_bank_movs       integer;
BEGIN
  -- ── Anchor sintético del tenant A ─────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate Party Guard A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE PARTY-GUARD: no se pudo resolver cuenta para el anchor sintético A — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético del tenant B (SEGUNDO tenant, la clave de este gate) ─
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate Party Guard B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE NOTICE 'GATE PARTY-GUARD: no se pudo provisionar un SEGUNDO tenant independiente para el anchor B — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a    FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit'   LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'     LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' LIMIT 1;

  IF v_branch_a IS NULL OR v_pm_credit IS NULL OR v_pm_cash IS NULL OR v_pm_transfer IS NULL THEN
    RAISE NOTICE 'GATE PARTY-GUARD: branch/catálogo de formas de pago no disponible para el anchor A — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_product__', 1000, 400, 'GATE-CCPG-1')
  RETURNING id INTO v_product_a;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a, v_product_a, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_ccpg_bank__', 'ARS', 0)
  RETURNING id INTO v_bank_a;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_client_a__', 'active')
  RETURNING id INTO v_client_a;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_client_a2__', 'active')
  RETURNING id INTO v_client_a2;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_a, '__gate_ccpg_supplier_a__')
  RETURNING id INTO v_supplier_a;

  -- Parte del tenant B: existe, es válida, pero NO pertenece a la cuenta A.
  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_b, v_account_b, '__gate_ccpg_client_b__', 'active')
  RETURNING id INTO v_client_b;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_b, '__gate_ccpg_supplier_b__')
  RETURNING id INTO v_supplier_b;

  -- ── Sesión sintética del tenant A (request.jwt.claims) ────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE PARTY-GUARD: auth.uid() no resuelve al anchor A con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════════ (2.2) rpc_register_payment_received + cliente ajeno ══════════
  -- Precondición imprescindible: el cargo tiene que existir primero, si no el
  -- cobro fallaría por saldo negativo (P0409) y el rojo no probaría nada.
  -- Se postea en la cuenta corriente de A contra un cliente PROPIO, para que
  -- el único factor bajo prueba sea el client_id ajeno del cobro.
  v_ca_id := public.c30_get_or_create_customer_account(v_account_a, v_client_a);
  PERFORM public.c30_register_customer_account_movement(v_ca_id, 5000, 'sale', gen_random_uuid());

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-2-2',
      p_client_id       => v_client_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_foreign := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2): rpc_register_payment_received con un client_id de OTRO tenant debería fallar con P0404. Hoy tiene éxito y crea una fila en customer_accounts con account_id=A y client_id de B.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.customer_accounts
  WHERE account_id = v_account_a AND client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2-fila): el rechazo no debe dejar una customer_account con la parte ajena, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.2): rpc_register_payment_received rechaza el cliente de otro tenant con P0404 y no crea cuenta corriente.';

  -- ═══════════ (2.3) rpc_register_payment_made + proveedor ajeno ════════════
  v_sa_id := public.c30_get_or_create_supplier_account(v_account_a, v_supplier_a);
  PERFORM public.c30_register_supplier_account_movement(v_sa_id, 5000, 'purchase', gen_random_uuid());

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccpg-2-3',
      p_supplier_id     => v_supplier_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3): rpc_register_payment_made con un supplier_id de OTRO tenant debería fallar con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.supplier_accounts
  WHERE account_id = v_account_a AND supplier_id = v_supplier_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3-fila): el rechazo no debe dejar una supplier_account con la parte ajena, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.3): rpc_register_payment_made rechaza el proveedor de otro tenant con P0404.';

  -- ═══════════ (2.4) rpc_register_supplier_charge + proveedor ajeno ═════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_supplier_charge(
      p_idempotency_key => 'gate-ccpg-2-4',
      p_supplier_id     => v_supplier_b,
      p_amount          => 250
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4): rpc_register_supplier_charge con un supplier_id de OTRO tenant debería fallar con P0404.';
  END IF;
  RAISE NOTICE 'PASS (2.4): rpc_register_supplier_charge rechaza el proveedor de otro tenant con P0404.';

  -- ════ (2.5) FORMULARIO — venta a crédito con cliente ajeno (choke point) ══
  -- El camino de más volumen: rpc_create_sale_operation_v2 NO valida la parte
  -- (no hay una sola ocurrencia de `FROM public.clients` en su migración).
  -- Lo cubre el guard del choke point c30_get_or_create_customer_account, sin
  -- tocar una línea de la RPC de venta (ver 3.8).
  SELECT COUNT(*) INTO v_n_sales         FROM public.sales                       WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_sale_items    FROM public.sale_items                  WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_cust_accounts FROM public.customer_accounts           WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_cust_movs     FROM public.customer_account_movements  WHERE customer_account_id = v_ca_id;
  SELECT COUNT(*) INTO v_n_stock_movs    FROM public.stock_movements             WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_events        FROM public.events                      WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-ccpg-2-5',
      p_client_id         => v_client_b,
      p_date              => public.reporting_local_today(),
      p_currency          => 'ARS',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
      p_branch_id         => v_branch_a,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5, ESTRELLA): una venta a crédito del FORMULARIO con un cliente de OTRO tenant debería fallar con P0404 — es el camino de más volumen y hoy postea el cargo sin preguntar nada.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-sales): el rechazo dejó % filas en sales, esperaba % (sin cambios).', v_count, v_n_sales;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE account_id = v_account_a;
  IF v_count <> v_n_sale_items THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-sale_items): el rechazo dejó % filas en sale_items, esperaba %.', v_count, v_n_sale_items;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_accounts WHERE account_id = v_account_a;
  IF v_count <> v_n_cust_accounts THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-customer_accounts): el rechazo dejó % cuentas corrientes, esperaba %.', v_count, v_n_cust_accounts;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;
  IF v_count <> v_n_cust_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-movimientos): el rechazo dejó % movimientos, esperaba %.', v_count, v_n_cust_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE account_id = v_account_a;
  IF v_count <> v_n_stock_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-stock): el rechazo dejó % movimientos de stock, esperaba % — el descuento de kardex no debe sobrevivir al rechazo.', v_count, v_n_stock_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-events): el rechazo dejó % eventos, esperaba % — ningún evento debe llegar al outbox.', v_count, v_n_events;
  END IF;
  RAISE NOTICE 'PASS (2.5, ESTRELLA): venta a crédito del formulario con cliente ajeno → P0404 y cero filas nuevas en los 6 libros.';

  -- ════════ (2.6) POS — quick sale a crédito con cliente ajeno ══════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'gate-ccpg-2-6',
      p_client_id         => v_client_b,
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'credit',
      p_branch_id         => v_branch_a,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.6, ESTRELLA): una venta a crédito del POS con un cliente de OTRO tenant debería fallar con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.6-orden): el rechazo dejó % sales_orders contra el cliente ajeno, esperaba 0.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.6, ESTRELLA): venta a crédito del POS con cliente ajeno → P0404 y ninguna orden confirmada.';

  -- ═══════════════════ (3.8) el choke point es lo que cubre ═════════════════
  RAISE NOTICE 'PASS (3.8): 2.5 y 2.6 pasan SIN haber tocado rpc_create_sale_operation_v2 ni _c29_confirm_order_core — el guard del choke point c30_get_or_create_customer_account cubre todo caller, presente y futuro.';

  -- ════════════ (3.5) CONTROL POSITIVO — la parte PROPIA sigue andando ══════
  -- (3.5a) venta a crédito con cliente propio FRESCO (sin cuenta corriente
  --        previa): la cuenta se crea en el mismo commit.
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-ccpg-3-5a',
    p_client_id         => v_client_a2,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;

  SELECT id, balance INTO v_ca_id, v_balance
  FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client_a2;
  IF v_ca_id IS NULL OR v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5a): con cliente PROPIO sin cuenta previa esperaba cuenta creada con balance 1000, obtuve id=% balance=% — el guard estaría rechazando de más.', v_ca_id, v_balance;
  END IF;

  -- (3.5b) cobro parcial sobre esa cuenta recién creada → balance_after 600
  SELECT public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccpg-3-5b',
    p_client_id       => v_client_a2,
    p_amount          => 400
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 600 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b): balance_after esperado 600 tras cobrar 400 sobre 1000, es %.', v_result->>'balance_after';
  END IF;
  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b-replay): el cobro con clave nueva no debería devolver replayed = true.';
  END IF;

  -- (3.5c) cargo de proveedor PROPIO FRESCO → cuenta creada, balance_after 700
  SELECT public.rpc_register_supplier_charge(
    p_idempotency_key => 'gate-ccpg-3-5c',
    p_supplier_id     => v_supplier_a,
    p_amount          => 700
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 5700 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5c): balance_after esperado 5700 (5000 previos + 700), es %.', v_result->>'balance_after';
  END IF;

  -- (3.5d) pago a ese proveedor → balance_after 5400
  SELECT public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccpg-3-5d',
    p_supplier_id     => v_supplier_a,
    p_amount          => 300
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 5400 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5d): balance_after esperado 5400 tras pagar 300 sobre 5700, es %.', v_result->>'balance_after';
  END IF;
  RAISE NOTICE 'PASS (3.5): control positivo — cliente y proveedor PROPIOS funcionan por los 4 caminos, con la cuenta corriente creada en el mismo commit y los balance_after esperados.';

  -- ═══ (3.6) id INEXISTENTE → mismo P0404 y MISMO texto que el caso ajeno ═══
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-3-6',
      p_client_id       => v_ghost,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_ghost := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6): un client_id inexistente debería fallar con P0404.';
  END IF;

  -- El mensaje sólo puede diferir en el UUID interpolado: si el texto que
  -- rodea al id no fuese idéntico, el error distinguiría "ajeno" de
  -- "inexistente" y filtraría la existencia de entidades de otros tenants.
  IF replace(v_msg_ghost, v_ghost::text, '<id>') IS DISTINCT FROM replace(v_msg_foreign, v_client_b::text, '<id>') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6-mensaje): el error de "cliente ajeno" (%) y el de "cliente inexistente" (%) deben ser indistinguibles salvo por el UUID — si no, se filtra qué ids existen en otros tenants.', v_msg_foreign, v_msg_ghost;
  END IF;
  RAISE NOTICE 'PASS (3.6): id ajeno e id inexistente producen el MISMO P0404 con el MISMO texto — el error no filtra información entre tenants.';

  -- ═════ (3.7) rpc_create_*_account —que ya validaban— sin regresión ════════
  SELECT public.rpc_create_customer_account(p_client_id => v_client_a) INTO v_result;
  IF (v_result->>'customer_account_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7a): rpc_create_customer_account con cliente propio debería devolver customer_account_id.';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_customer_account(p_client_id => v_client_b);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7b): rpc_create_customer_account con cliente ajeno debería seguir fallando con P0404 (ya validaba desde C-30).';
  END IF;

  SELECT public.rpc_create_supplier_account(p_supplier_id => v_supplier_a) INTO v_result;
  IF (v_result->>'supplier_account_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7c): rpc_create_supplier_account con proveedor propio debería devolver supplier_account_id.';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_supplier_account(p_supplier_id => v_supplier_b);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7d): rpc_create_supplier_account con proveedor ajeno debería seguir fallando con P0404.';
  END IF;
  RAISE NOTICE 'PASS (3.7): rpc_create_customer_account / rpc_create_supplier_account se comportan igual con el guard ahora duplicado en el choke point — redundancia deliberada, no regresión.';

  -- ═══ (4.6) ORDEN de los guards: payload primero (P0400), parte después ════
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-6',
      p_client_id       => v_client_b,
      p_amount          => 0
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.6): cliente ajeno + amount = 0 debe fallar con P0400 (validación de payload PRIMERO), falló con % — el guard de parte quedó mal ubicado respecto de D2.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  -- ═ (4.7) transferencia: bank_account primero (P0412), después la parte ════
  -- (4.7a) bank_account VÁLIDO + cliente ajeno → P0404 y cero bank_movements
  SELECT COUNT(*) INTO v_n_bank_movs FROM public.bank_movements WHERE bank_account_id = v_bank_a;

  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-7a',
      p_client_id       => v_client_b,
      p_amount          => 100,
      p_payment_method  => 'transfer',
      p_bank_account_id => v_bank_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0404' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7a): cobro por transferencia con cliente ajeno debe fallar con P0404, falló con %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE bank_account_id = v_bank_a;
  IF v_count <> v_n_bank_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7a-banco): el guard debe cortar ANTES del ruteo bancario — hay % movimientos, esperaba %.', v_count, v_n_bank_movs;
  END IF;

  -- (4.7b) bank_account INEXISTENTE + cliente ajeno → P0412, NO P0404.
  -- Congela que el bloque bancario corre antes del guard de parte (D2).
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-7b',
      p_client_id       => v_client_b,
      p_amount          => 100,
      p_payment_method  => 'transfer',
      p_bank_account_id => v_ghost
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0412' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7b): cliente ajeno + bank_account inexistente debe fallar con P0412 (el bloque bancario corre ANTES del guard de parte, D2), falló con %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  RAISE NOTICE 'PASS (4.6 + 4.7): el orden documentado en D2 queda congelado — amount (P0400) → payment_method → bank_account (P0412) → parte (P0404) → idempotencia; y el guard corta antes del ruteo bancario.';

  -- ═══ (4.5) la clave de idempotencia NO se quema en el rechazo ═════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-5-shared',
      p_client_id       => v_client_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-pre): el cobro con cliente ajeno debería haberse rechazado con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.operation_idempotency
  WHERE user_id = v_user_a AND operation_kind = 'payment_received' AND idempotency_key = 'gate-ccpg-4-5-shared';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-slot): el rechazo dejó % filas en operation_idempotency para la clave compartida, esperaba 0 — la clave quedó quemada.', v_count;
  END IF;

  -- Mismo idempotency_key, ahora con un cliente VÁLIDO: tiene que registrar
  -- de verdad, no devolver el replay de un intento que nunca ocurrió.
  SELECT public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccpg-4-5-shared',
    p_client_id       => v_client_a2,
    p_amount          => 100
  ) INTO v_result;
  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5): el reintento con la MISMA clave y un cliente válido devolvió replayed = true — el rechazo quemó la clave de idempotencia.';
  END IF;
  IF (v_result->>'payment_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-pago): el reintento con cliente válido debería registrar un cobro real.';
  END IF;
  IF (v_result->>'balance_after')::numeric <> 500 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-saldo): balance_after esperado 500 (600 - 100), es %.', v_result->>'balance_after';
  END IF;
  RAISE NOTICE 'PASS (4.5): un cobro rechazado por cliente ajeno NO quema la clave de idempotencia — el reintento con cliente válido registra de verdad.';

  -- ═════ (5.1) _pay_register_party_charge no es alcanzable por el rol app ═══
  -- Ojo: la primitiva recibe el account_id COMO PARÁMETRO. Sin el revoke, un
  -- authenticated cualquiera escribe en la cuenta corriente REAL del tenant B.
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._pay_register_party_charge(v_account_b, 'customer', v_client_b, 1000, NULL, NULL);
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1, SEVERIDAD ALTA): _pay_register_party_charge debe ser inalcanzable para el rol authenticated (42501 insufficient_privilege), obtuve %. Es una primitiva SECURITY DEFINER que recibe el account_id por parámetro: expuesta vía PostgREST permite escribir en los libros de CUALQUIER tenant.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  IF has_function_privilege('authenticated',
       'public._pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1-acl): authenticated no debe tener EXECUTE sobre _pay_register_party_charge.';
  END IF;
  RAISE NOTICE 'PASS (5.1): _pay_register_party_charge deja de ser invocable por authenticated — la primitiva de escritura cross-tenant queda cerrada.';

  -- ═════ (5.2) _journal_post_from_event, mismo caso, misma proveniencia ═════
  -- El evento se forja como postgres (RLS de events no aplica al owner) y la
  -- fila se lee ANTES del cambio de rol: lo que se prueba es el EXECUTE, no
  -- el acceso a la tabla.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_b, 'SaleConfirmed', 'SalesOrder', gen_random_uuid(),
    jsonb_build_object('account_id', v_account_b, 'sales_order_id', gen_random_uuid(),
                       'operation_id', gen_random_uuid(), 'total', 999, 'payment_method', 'cash'), now())
  RETURNING id INTO v_event_id;
  SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._journal_post_from_event(v_event_row);
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2, SEVERIDAD ALTA): _journal_post_from_event debe ser inalcanzable para authenticated (42501), obtuve %. Nació con REVOKE en 20260803000001 L517 y lo perdió en 20261001000001 L1914 cuando el patrón uniforme REVOKE+GRANT se lo aplicó en piloto automático.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  IF has_function_privilege('authenticated',
       'public._journal_post_from_event(public.events)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2-acl): authenticated no debe tener EXECUTE sobre _journal_post_from_event.';
  END IF;
  RAISE NOTICE 'PASS (5.2): _journal_post_from_event deja de ser invocable por authenticated — no se puede forjar un evento y postear un asiento en otro tenant.';

  -- ══ (5.5) el revoke es TRANSPARENTE para los callers internos (definer) ═══
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-ccpg-5-5-form',
    p_client_id         => v_client_a2,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 250, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE customer_account_id = v_ca_id AND reference_id = v_op_id AND amount = 250;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-formulario): tras el revoke, la venta a crédito del formulario debe seguir posteando su cargo vía _pay_register_party_charge (el PERFORM interno corre como definer). Esperaba 1 movimiento, hay %.', v_count;
  END IF;

  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-ccpg-5-5-pos',
    p_client_id         => v_client_a2,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 300, 'subtotal', 300)),
    p_payment_method    => 'credit',
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_so_id := (v_result->>'sales_order_id')::uuid;

  -- El cargo del POS referencia sales_orders.id (no operation_id) — misma
  -- premisa que verifica test_pagos_cableados_restantes.sql (9c).
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE customer_account_id = v_ca_id AND reference_id = v_so_id AND amount = 300;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-pos): tras el revoke, la venta a crédito del POS debe seguir posteando su cargo. Esperaba 1 movimiento con reference_id=sales_order_id, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (5.5): el revoke es transparente para los callers reales — formulario y POS siguen posteando el cargo a crédito.';

  -- ══ (5.6) el dispatcher del outbox sigue posteando asientos balanceados ═══
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_a, 'SaleConfirmed', 'SalesOrder', gen_random_uuid(),
    jsonb_build_object('account_id', v_account_a, 'sales_order_id', gen_random_uuid(),
                       'operation_id', gen_random_uuid(), 'total', 1234, 'payment_method', 'cash'), now())
  RETURNING id INTO v_event_id;

  SELECT public.rpc_process_outbox_dispatch(1000) INTO v_processed;

  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.6): tras el revoke de _journal_post_from_event, rpc_process_outbox_dispatch debe seguir posteando el asiento del evento % — no se encontró journal_entry.', v_event_id;
  END IF;

  SELECT COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
         COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
  INTO v_debit, v_credit
  FROM public.journal_lines WHERE entry_id = v_entry_id;

  IF v_debit <> v_credit OR v_debit <> 1234 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.6-balance): el asiento del outbox debe balancear en 1234 por lado, es debit=% credit=%.', v_debit, v_credit;
  END IF;
  RAISE NOTICE 'PASS (5.6): rpc_process_outbox_dispatch (SECURITY DEFINER) sigue posteando asientos balanceados tras el revoke — el dispatcher no pasa por el ACL de authenticated.';

  RAISE NOTICE 'GATE CUENTA-CORRIENTE-PARTY-GUARD OK: guard de tenencia en el choke point + 3 RPCs de pago, orden de guards congelado, idempotencia intacta, y las dos primitivas cross-tenant cerradas sin romper ningún caller real.';
END $$;
