-- =============================================================================
-- GATE: test_edicion_dinero_venta.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda B, grupo 7 (tasks 7.1-7.5)
--
-- EJECUTA rpc_atomic_update_sale_operation sobre ventas con dinero registrado en los cuatro libros y asserta, por
-- escenario de specs/operation-money-edit y de los deltas de libros:
--   (V1)  venta a credito: sube (cargo nuevo primero, sin P0425 aunque ya haya un cobro), baja con P0425 cuando el saldo
--         final quedaria negativo, cambia de cliente, conserva o fija el vencimiento
--   (V2)  efectivo del dia y de una sesion CERRADA (la correccion va a la sesion abierta de la MISMA caja), P0426 sin
--         sesion abierta, cash_intent_required al cambiar de sucursal, cash_optin_requires_today para una retroactiva
--         sin huella de caja
--   (V3)  transferencia: espejo + movimiento nuevo, P0424, cuenta conservada
--   (V4)  sin cambio economico = sin escritura en NINGUN libro (ni se exige caja abierta)
--   (V5)  herencia: credito historico sin cargo y transferencia sin movimiento NO inventan un efecto
--   (V6)  cambio de forma de pago entre los cuatro libros
--   (V7)  venta del POS (referencia = sales_orders.id): edicion, rastro contable SaleOperationAdjusted con
--         sales_order_id, forma de pago de la orden sincronizada
--   (V8)  CAE / en vuelo / remito siguen bloqueando: los EJECUTA test_venta_editable_sin_cae.sql (rebasado en esta tanda)
--   (V9)  operation_id ESTABLE y auditoria en audit_logs
--   (V10) rol (OQ-4): corregir dinero es del dueno o un administrador; sin dinero, el rol de siempre
--   (V11) p_dry_run: devuelve el plan sin escribir y el plan ejecutado es el MISMO
--   (V12) borrar despues de editar compensa exactamente lo vivo
--
-- Una transaccion con ROLLBACK; el ultimo bloque asserta el cleanup.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _ev (k text PRIMARY KEY, v uuid);

-- ── Helpers de sesion ────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.id(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT v FROM _ev WHERE k = p_k $$;

CREATE FUNCTION pg_temp.as_user(p_user uuid, p_account uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_user::text, 'role', 'authenticated',
     'app_metadata', jsonb_build_object('account_id', p_account::text))::text, true);
END $f$;

CREATE FUNCTION pg_temp.eq(p_label text, p_got text, p_want text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_want THEN
    RAISE EXCEPTION 'GATE EDICION-DINERO-VENTA FAILED [%]: esperaba <%> y dio <%>', p_label, p_want, p_got;
  END IF;
END $f$;

-- Corre una expresion SQL; NUNCA lanza: devuelve estado/mensaje/resultado.
CREATE FUNCTION pg_temp.try(p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb) LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE format('SELECT to_jsonb(%s)', p_expr) INTO o_res;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
END $f$;

-- Huella neta: suma por libro (y cantidad de filas).
CREATE FUNCTION pg_temp.fp(p_refs uuid[], p_book text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(SUM(net), 0)::text || '/' || count(*)::text
  FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', p_refs) WHERE book = p_book
$$;

-- Cantidad de filas en los cuatro libros (para probar "sin escritura").
CREATE FUNCTION pg_temp.ledger_rows() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.customer_account_movements WHERE account_id = pg_temp.id('acc')) || '/' ||
         (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
            JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id
           WHERE b.account_id = pg_temp.id('acc')) || '/' ||
         (SELECT count(*) FROM public.bank_movements WHERE account_id = pg_temp.id('acc')) || '/' ||
         (SELECT count(*) FROM public.events WHERE account_id = pg_temp.id('acc'))
$$;

CREATE FUNCTION pg_temp.items(p_amount numeric, p_qty numeric DEFAULT 1) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('product_id', pg_temp.id('product'), 'amount', p_amount, 'quantity', p_qty))
$$;

CREATE FUNCTION pg_temp.sale_ids(p_op uuid) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT array_agg(id ORDER BY id) FROM public.sales WHERE operation_id = p_op
$$;

-- Alta REAL de una venta; devuelve su operation_id.
CREATE FUNCTION pg_temp.mk_sale(p_pm uuid, p_client uuid, p_amount numeric, p_session uuid DEFAULT NULL,
                                p_bank uuid DEFAULT NULL, p_date date DEFAULT NULL, p_due date DEFAULT NULL,
                                p_branch uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_create_sale_operation_v2(gen_random_uuid()::text, p_client, COALESCE(p_date, public.reporting_local_today()), 'ARS',
         pg_temp.items(p_amount), COALESCE(p_branch, pg_temp.id('branch')), NULL, p_pm, p_session, p_bank, p_due);
  RETURN (r->>'operation_id')::uuid;
END $f$;

-- Edicion REAL (o en seco) de la venta. p_extra son argumentos con nombre adicionales.
CREATE FUNCTION pg_temp.edit(p_op uuid, p_client uuid, p_amount numeric, p_extra text DEFAULT '', p_date date DEFAULT NULL,
                             OUT o_state text, OUT o_msg text, OUT o_res jsonb) LANGUAGE plpgsql AS $f$
BEGIN
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], %L::uuid, %L::date, ''ARS'', %L::jsonb %s)',
    pg_temp.sale_ids(p_op), p_client, COALESCE(p_date, public.reporting_local_today()), pg_temp.items(p_amount), p_extra)) t;
END $f$;

-- ── Fixture ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_cashier uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_acc uuid; v_acc_b uuid; v_branch uuid; v_branch2 uuid; v_cb uuid; v_cb2 uuid;
  v_s_old uuid; v_s_open uuid; v_s_open2 uuid; v_member uuid;
  v_ba uuid; v_ba2 uuid; v_pm_cash uuid; v_pm_tr uuid; v_pm_cr uuid; v_pm_cr2 uuid; v_pm_card uuid;
  v_client uuid; v_client2 uuid; v_product uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_owner,   'authenticated', 'authenticated', 'ed-dv-owner@test.local',   now(), now(), '{"name":"EDV Dueno"}'::jsonb),
    (v_cashier, 'authenticated', 'authenticated', 'ed-dv-cashier@test.local', now(), now(), '{"name":"EDV Cajero"}'::jsonb),
    (v_other,   'authenticated', 'authenticated', 'ed-dv-other@test.local',   now(), now(), '{"name":"EDV Otra cuenta"}'::jsonb);
  SELECT account_id INTO v_acc   FROM public.account_members WHERE user_id = v_owner;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id = v_other;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_member, 'cashier');

  v_branch := public.c26_default_branch(v_acc);
  SELECT id INTO v_cb FROM public.cashboxes WHERE branch_id = v_branch ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at) VALUES (v_acc, '__edv_branch2__', true, 'active', now()) RETURNING id INTO v_branch2;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch2, '__edv_caja2__') RETURNING id INTO v_cb2;
  PERFORM pg_temp.as_user(v_owner, v_acc);

  -- sesion VIEJA de la caja 1 (se cierra despues de recibir lo "viejo") + sesion abierta de cada caja
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cb, 'open', 0, v_owner) RETURNING id INTO v_s_old;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cb2, 'open', 0, v_owner) RETURNING id INTO v_s_open2;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES (v_acc, '__edv_bank__', 'ARS', 0) RETURNING id INTO v_ba;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES (v_acc, '__edv_bank2__', 'ARS', 0) RETURNING id INTO v_ba2;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_acc AND kind = 'cash'     AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_tr   FROM public.payment_methods WHERE account_id = v_acc AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_cr   FROM public.payment_methods WHERE account_id = v_acc AND kind = 'credit'   AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_card FROM public.payment_methods WHERE account_id = v_acc AND kind = 'card'     AND is_active AND deleted_at IS NULL LIMIT 1;
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order) VALUES (v_acc, '__edv_credit2__', 'credit', 99) RETURNING id INTO v_pm_cr2;

  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_owner, v_acc, '__edv_client__', 'active') RETURNING id INTO v_client;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_owner, v_acc, '__edv_client2__', 'active') RETURNING id INTO v_client2;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku) VALUES (v_owner, v_acc, '__edv_product__', 1000, 400, 'GATE-EDV-1') RETURNING id INTO v_product;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity) VALUES (v_acc, v_branch, v_product, 100000)
    ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100000;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity) VALUES (v_acc, v_branch2, v_product, 100000)
    ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100000;

  INSERT INTO _ev VALUES ('owner', v_owner), ('cashier', v_cashier), ('other', v_other), ('acc', v_acc), ('acc_b', v_acc_b),
    ('branch', v_branch), ('branch2', v_branch2), ('cb', v_cb), ('cb2', v_cb2), ('s_old', v_s_old), ('s_open2', v_s_open2),
    ('ba', v_ba), ('ba2', v_ba2), ('pm_cash', v_pm_cash), ('pm_tr', v_pm_tr), ('pm_cr', v_pm_cr), ('pm_cr2', v_pm_cr2), ('pm_card', v_pm_card),
    ('client', v_client), ('client2', v_client2), ('product', v_product);
  IF v_pm_cash IS NULL OR v_pm_tr IS NULL OR v_pm_cr IS NULL OR v_pm_card IS NULL OR v_cb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: formas de pago / caja sembradas faltantes';
  END IF;
END $$;

-- ── (V2 pre) venta en efectivo en la sesion VIEJA, que se cierra; despues la sesion abierta de hoy ──
DO $$
DECLARE v_op uuid; v_s_open uuid;
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cash'), pg_temp.id('client'), 1000, pg_temp.id('s_old'));
  INSERT INTO _ev VALUES ('op_cash_old', v_op);
  UPDATE public.cash_sessions SET status = 'closed', closed_by = pg_temp.id('owner'), closed_at = now(),
         closing_balance = 0, counted_balance = 0, expected_balance = 0, difference = 0 WHERE id = pg_temp.id('s_old');
  -- SIN sesion abierta en la caja 1 por ahora: la usan V2-c y V4.
END $$;

-- ═════════════════ V2-c / V4: sin sesion abierta ═════════════════
DO $$
DECLARE r record; v_op uuid := pg_temp.id('op_cash_old'); v_before text; v_prefix text;
BEGIN
  -- V4: corregir el cliente de una venta en efectivo de una sesion cerrada, SIN cambiar el total ni la forma de pago:
  -- H = E en la caja -> no hay escritura en ningun libro y no se exige sesion abierta.
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 1000, '');
  PERFORM pg_temp.eq('V4 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V4 caja intacta', pg_temp.fp(ARRAY[v_op], 'cash'), '1000.00/1');
  -- solo cambia el conteo de eventos (SaleOperationAdjusted si habia asiento) -> comparamos los tres libros de dinero
  PERFORM pg_temp.eq('V4 libros de dinero', split_part(pg_temp.ledger_rows(), '/', 1) || '/' || split_part(pg_temp.ledger_rows(), '/', 2) || '/' || split_part(pg_temp.ledger_rows(), '/', 3),
                     split_part(v_before, '/', 1) || '/' || split_part(v_before, '/', 2) || '/' || split_part(v_before, '/', 3));

  -- V2-c: cambiar el importe exige abrir la caja -> P0426 y NADA se escribe (el rechazo revierte todo).
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 1200, '');
  PERFORM pg_temp.eq('V2-c estado', r.o_state, 'P0426');
  PERFORM pg_temp.eq('V2-c libros intactos', pg_temp.ledger_rows(), v_before);
  PERFORM pg_temp.eq('V2-c venta intacta', (SELECT sum(total)::text FROM public.sales WHERE operation_id = v_op), '1000');

  -- V11 (parte): en seco devuelve el plan con el bloqueo COMO DATO y no escribe.
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 1200, ', p_dry_run => true');
  PERFORM pg_temp.eq('V11 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V11 dry_run', r.o_res->>'dry_run', 'true');
  PERFORM pg_temp.eq('V11 bloqueo', r.o_res->'plan'->'blocks'->0->>'code', 'P0426');
  PERFORM pg_temp.eq('V11 writes_money', r.o_res->'plan'->>'writes_money', 'true');
  PERFORM pg_temp.eq('V11 sin escritura', pg_temp.ledger_rows(), v_before);
  PERFORM pg_temp.eq('V11 venta intacta', (SELECT sum(total)::text FROM public.sales WHERE operation_id = v_op), '1000');
  RAISE NOTICE 'PASS (V4, V2-c, V11a)';
END $$;

-- Abre la sesion de hoy de la caja 1.
DO $$
DECLARE v_s uuid;
BEGIN
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (pg_temp.id('cb'), 'open', 0, pg_temp.id('owner')) RETURNING id INTO v_s;
  INSERT INTO _ev VALUES ('s_open', v_s);
END $$;

-- ═════════════════ V2: efectivo ═════════════════
DO $$
DECLARE r record; v_op uuid := pg_temp.id('op_cash_old'); v_op2 uuid; v_ids uuid[]; v_old_op uuid;
BEGIN
  -- V2-b: la venta vive en una sesion CERRADA -> la correccion (reversion + importe nuevo) va a la sesion ABIERTA de la MISMA caja.
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1200, '');
  PERFORM pg_temp.eq('V2-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V2-b operation_id estable', r.o_res->>'operation_id', v_op::text);
  PERFORM pg_temp.eq('V2-b huella neta de caja', pg_temp.fp(ARRAY[v_op], 'cash'), '1200.00/1');
  PERFORM pg_temp.eq('V2-b sesion cerrada intacta', (SELECT count(*)::text FROM public.cash_movements WHERE session_id = pg_temp.id('s_old')), '1');
  PERFORM pg_temp.eq('V2-b la reversion y el nuevo van a la abierta', (SELECT string_agg(movement_type || ':' || amount::text, ',' ORDER BY created_at, movement_type)
            FROM public.cash_movements WHERE session_id = pg_temp.id('s_open') AND reference_id = v_op), 'sale:1200.00,sale_reversal:-1000.00');

  -- V2-a: efectivo de HOY: baja de 1200 a 700 en una venta creada hoy en la sesion abierta.
  v_op2 := pg_temp.mk_sale(pg_temp.id('pm_cash'), NULL, 1000, pg_temp.id('s_open'));
  SELECT * INTO r FROM pg_temp.edit(v_op2, NULL, 700, '');
  PERFORM pg_temp.eq('V2-a estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V2-a huella', pg_temp.fp(ARRAY[v_op2], 'cash'), '700.00/1');
  INSERT INTO _ev VALUES ('op_cash_today', v_op2);

  -- V2-d: cambio de sucursal sin intencion de caja -> cash_intent_required (P0422).
  SELECT * INTO r FROM pg_temp.edit(v_op2, NULL, 700, ', p_branch_id => ' || quote_literal(pg_temp.id('branch2')) || ', p_branch_provided => true');
  PERFORM pg_temp.eq('V2-d estado', r.o_state, 'P0422');
  IF r.o_msg NOT LIKE 'cash_intent_required:%' THEN RAISE EXCEPTION 'V2-d mensaje: %', r.o_msg; END IF;
  PERFORM pg_temp.eq('V2-d huella intacta', pg_temp.fp(ARRAY[v_op2], 'cash'), '700.00/1');
  -- ...y con la intencion explicita (sesion abierta de la caja 2) la edicion procede: compensa en la caja vieja y registra en la nueva.
  SELECT * INTO r FROM pg_temp.edit(v_op2, NULL, 700, ', p_branch_id => ' || quote_literal(pg_temp.id('branch2')) || ', p_branch_provided => true, p_cash_session_id => '
                                    || quote_literal(pg_temp.id('s_open2')) || ', p_cash_provided => true');
  PERFORM pg_temp.eq('V2-d con intencion', r.o_state, '00000');
  PERFORM pg_temp.eq('V2-d caja 1 en cero', (SELECT COALESCE(sum(net), 0)::text FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', ARRAY[v_op2]) WHERE book = 'cash' AND ledger_id = pg_temp.id('cb')), '0');
  PERFORM pg_temp.eq('V2-d caja 2', (SELECT sum(net)::text FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', ARRAY[v_op2]) WHERE book = 'cash' AND ledger_id = pg_temp.id('cb2')), '700.00');

  -- V2-e: retroactiva SIN huella de caja (transferencia de ayer) que pasa a efectivo -> cash_optin_requires_today.
  v_op2 := pg_temp.mk_sale(pg_temp.id('pm_tr'), NULL, 500, NULL, NULL, public.reporting_local_today() - 1);
  SELECT * INTO r FROM pg_temp.edit(v_op2, NULL, 500, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cash')) || ', p_payment_method_provided => true, p_cash_session_id => '
                                    || quote_literal(pg_temp.id('s_open')) || ', p_cash_provided => true', public.reporting_local_today() - 1);
  PERFORM pg_temp.eq('V2-e estado', r.o_state, 'P0422');
  IF r.o_msg NOT LIKE 'cash_optin_requires_today:%' THEN RAISE EXCEPTION 'V2-e mensaje: %', r.o_msg; END IF;
  RAISE NOTICE 'PASS (V2: efectivo del dia, sesion cerrada, sucursal, retroactiva)';
END $$;

-- ═════════════════ V1: cuenta corriente ═════════════════
DO $$
DECLARE r record; v_op uuid; v_ca uuid; v_bal numeric; v_due date; v_today date := public.reporting_local_today();
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cr'), pg_temp.id('client'), 1000, NULL, NULL, NULL, v_today + 10);
  INSERT INTO _ev VALUES ('op_credit', v_op);
  SELECT id INTO v_ca FROM public.customer_accounts WHERE account_id = pg_temp.id('acc') AND client_id = pg_temp.id('client');
  PERFORM pg_temp.eq('V1 cargo inicial', pg_temp.fp(ARRAY[v_op], 'account'), '1000.00/1');
  -- un cobro previo de 400 (saldo 600 + lo de las otras ventas del cliente)
  SELECT balance INTO v_bal FROM public.customer_accounts WHERE id = v_ca;
  PERFORM public.c30_register_customer_account_movement(v_ca, -400, 'payment_received', NULL);

  -- V1-a: SUBE a 1200 -> cargo nuevo primero y despues la reversion: no hay P0425 pese al cobro previo.
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1200, '');
  PERFORM pg_temp.eq('V1-a estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V1-a huella', pg_temp.fp(ARRAY[v_op], 'account'), '1200.00/1');
  PERFORM pg_temp.eq('V1-a saldo', (SELECT balance::text FROM public.customer_accounts WHERE id = v_ca), (v_bal + 200 - 400)::text);
  -- (la prueba del orden 'cargo nuevo primero': con la reversion antes, 600 - 1000 < 0 daria P0425)
  -- V1-b: el vencimiento se CONSERVA al no mandarlo
  SELECT due_date INTO v_due FROM public.customer_account_movements WHERE customer_account_id = v_ca AND reference_id = v_op AND movement_type = 'sale' ORDER BY created_at DESC, id DESC LIMIT 1;
  PERFORM pg_temp.eq('V1-b vencimiento conservado', v_due::text, (v_today + 10)::text);

  -- V1-c: BAJA por debajo de lo cobrado -> P0425 y nada se escribe. Saldo actual = v_bal + 200 - 400 = (otros) + 1200 - 400
  SELECT balance INTO v_bal FROM public.customer_accounts WHERE id = v_ca;
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1200 - (v_bal + 1) - 0, '');   -- baja tanto que el saldo final es -1
  PERFORM pg_temp.eq('V1-c estado', r.o_state, 'P0425');
  PERFORM pg_temp.eq('V1-c huella intacta', pg_temp.fp(ARRAY[v_op], 'account'), '1200.00/1');
  PERFORM pg_temp.eq('V1-c saldo intacto', (SELECT balance::text FROM public.customer_accounts WHERE id = v_ca), v_bal::text);
  -- ...que la vista previa anticipa como dato
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1200 - (v_bal + 1), ', p_dry_run => true');
  PERFORM pg_temp.eq('V1-c plan P0425', r.o_res->'plan'->'blocks'->0->>'code', 'P0425');
  PERFORM pg_temp.eq('V1-c plan saldo proyectado', r.o_res->'plan'->'account'->>'projected_balance', '-1.00');

  -- V1-d: BAJA sin llegar a negativo
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 900, '');
  PERFORM pg_temp.eq('V1-d estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V1-d huella', pg_temp.fp(ARRAY[v_op], 'account'), '900.00/1');

  -- V1-e: cambia de CLIENTE -> el cargo se traslada (cuenta nueva con el cargo, la vieja con huella 0).
  -- (Sobre la venta ya cobrada en parte, mover el cargo dejaria negativa la cuenta vieja: P0425, correcto.)
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 900, '');
  PERFORM pg_temp.eq('V1-e cobrada en parte', r.o_state, 'P0425');
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cr'), pg_temp.id('client'), 900);
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 900, '');
  PERFORM pg_temp.eq('V1-e estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V1-e cuenta nueva', (SELECT sum(net)::text FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', ARRAY[v_op]) f
        WHERE f.book = 'account' AND f.ledger_id = (SELECT id FROM public.customer_accounts WHERE client_id = pg_temp.id('client2'))), '900.00');
  PERFORM pg_temp.eq('V1-e un solo ledger con huella', pg_temp.fp(ARRAY[v_op], 'account'), '900.00/1');
  -- V1-f: vencimiento EXPLICITO, y anterior a la fecha -> P0400
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 900, format(', p_due_date => %L, p_due_date_provided => true', v_today + 30));
  PERFORM pg_temp.eq('V1-f estado', r.o_state, '00000');
  SELECT max(due_date) INTO v_due FROM public.customer_account_movements WHERE reference_id = v_op AND movement_type = 'sale';   -- (max: todas las filas comparten created_at dentro de la transaccion del gate)
  PERFORM pg_temp.eq('V1-f vencimiento explicito', v_due::text, (v_today + 30)::text);
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client2'), 900, format(', p_due_date => %L, p_due_date_provided => true', v_today - 5));
  PERFORM pg_temp.eq('V1-f vencimiento anterior', r.o_state, 'P0400');
  RAISE NOTICE 'PASS (V1: cuenta corriente)';
END $$;

-- ═════════════════ V3: banco ═════════════════
DO $$
DECLARE r record; v_op uuid; v_before text; v_today date := public.reporting_local_today();
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_tr'), NULL, 1000, NULL, pg_temp.id('ba'));
  PERFORM pg_temp.eq('V3 alta', pg_temp.fp(ARRAY[v_op], 'bank'), '1000.00/1');
  -- cambia el total: espejo + movimiento nuevo, MISMA cuenta bancaria
  SELECT * INTO r FROM pg_temp.edit(v_op, NULL, 1300, '');
  PERFORM pg_temp.eq('V3-a estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V3-a huella', pg_temp.fp(ARRAY[v_op], 'bank'), '1300.00/1');
  PERFORM pg_temp.eq('V3-a cuenta conservada', (SELECT ledger_id::text FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', ARRAY[v_op]) WHERE book = 'bank'), pg_temp.id('ba')::text);
  PERFORM pg_temp.eq('V3-a el espejo va con fecha de hoy y sin conciliar', (SELECT count(*)::text FROM public.bank_movements
        WHERE source_doc_ref = v_op AND amount = -1000 AND value_date = CURRENT_DATE), '1');
  -- sin cambio economico: ningun movimiento nuevo
  v_before := (SELECT count(*)::text FROM public.bank_movements WHERE account_id = pg_temp.id('acc'));
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1300, '');
  PERFORM pg_temp.eq('V3-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V3-b sin escritura bancaria', (SELECT count(*)::text FROM public.bank_movements WHERE account_id = pg_temp.id('acc')), v_before);
  -- cuenta bancaria explicita distinta
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1300, ', p_bank_account_id => ' || quote_literal(pg_temp.id('ba2')) || ', p_bank_account_provided => true');
  PERFORM pg_temp.eq('V3-c estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V3-c cuenta nueva', (SELECT ledger_id::text FROM public.op_money_footprint(pg_temp.id('acc'), 'sale', ARRAY[v_op]) WHERE book = 'bank'), pg_temp.id('ba2')::text);
  -- periodo conciliado y cerrado -> P0424 (el movimiento nuevo cae en el periodo)
  INSERT INTO public.reconciliation_sessions (bank_account_id, account_id, status, period_from, period_to, statement_closing_balance, opened_by, closed_by, closed_at)
  VALUES (pg_temp.id('ba2'), pg_temp.id('acc'), 'closed', v_today - 60, v_today - 30, 0, pg_temp.id('owner'), pg_temp.id('owner'), now());
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1500, '', v_today - 40);
  PERFORM pg_temp.eq('V3-d P0424', r.o_state, 'P0424');
  PERFORM pg_temp.eq('V3-d huella intacta', pg_temp.fp(ARRAY[v_op], 'bank'), '1300.00/1');
  RAISE NOTICE 'PASS (V3: banco)';
END $$;

-- ═════════════════ V5: herencia ═════════════════
DO $$
DECLARE r record; v_op uuid := gen_random_uuid(); v_op_tr uuid := gen_random_uuid(); v_before text;
BEGIN
  -- credito HISTORICO: sale con forma de pago a credito y cliente, pero SIN cargo (las 241 del formulario)
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id, payment_method_id)
  VALUES (pg_temp.id('owner'), pg_temp.id('acc'), pg_temp.id('client'), pg_temp.id('product'), 800, 1, 800, 'ARS', now(), v_op, pg_temp.id('branch'), pg_temp.id('pm_cr'));
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 900, '');   -- mismo cliente, misma forma de pago
  PERFORM pg_temp.eq('V5-a estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V5-a no se inventa un cargo', pg_temp.fp(ARRAY[v_op], 'account'), '0/0');
  -- cambiar a OTRA forma de pago a credito SI cambia el contrato -> postea el cargo
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 900, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cr2')) || ', p_payment_method_provided => true');
  PERFORM pg_temp.eq('V5-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V5-b cargo posteado', pg_temp.fp(ARRAY[v_op], 'account'), '900.00/1');
  -- transferencia historica sin movimiento bancario: editar el importe no lo inventa
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id, payment_method_id)
  VALUES (pg_temp.id('owner'), pg_temp.id('acc'), NULL, pg_temp.id('product'), 500, 1, 500, 'ARS', now(), v_op_tr, pg_temp.id('branch'), pg_temp.id('pm_tr'));
  SELECT * INTO r FROM pg_temp.edit(v_op_tr, NULL, 600, '');
  PERFORM pg_temp.eq('V5-c estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V5-c sin banco', pg_temp.fp(ARRAY[v_op_tr], 'bank'), '0/0');
  RAISE NOTICE 'PASS (V5: herencia)';
END $$;

-- ═════════════════ V6: cambio de forma de pago entre libros ═════════════════
DO $$
DECLARE r record; v_op uuid; v_s uuid := pg_temp.id('s_open');
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cr'), pg_temp.id('client'), 1000);
  PERFORM pg_temp.eq('V6 credito', pg_temp.fp(ARRAY[v_op], 'account') || '|' || pg_temp.fp(ARRAY[v_op], 'cash') || '|' || pg_temp.fp(ARRAY[v_op], 'bank'), '1000.00/1|0/0|0/0');
  -- credito -> efectivo: cuenta corriente en 0 (reversion), caja 1000
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1000, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cash')) || ', p_payment_method_provided => true, p_cash_session_id => ' || quote_literal(v_s) || ', p_cash_provided => true');
  PERFORM pg_temp.eq('V6 a efectivo estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V6 a efectivo', pg_temp.fp(ARRAY[v_op], 'account') || '|' || pg_temp.fp(ARRAY[v_op], 'cash') || '|' || pg_temp.fp(ARRAY[v_op], 'bank'), '0/0|1000.00/1|0/0');
  -- efectivo -> transferencia: caja en 0 (reversion), banco 1000
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1000, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_tr')) || ', p_payment_method_provided => true, p_bank_account_id => ' || quote_literal(pg_temp.id('ba')) || ', p_bank_account_provided => true');
  PERFORM pg_temp.eq('V6 a transferencia estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V6 a transferencia', pg_temp.fp(ARRAY[v_op], 'account') || '|' || pg_temp.fp(ARRAY[v_op], 'cash') || '|' || pg_temp.fp(ARRAY[v_op], 'bank'), '0/0|0/0|1000.00/1');
  -- transferencia -> credito: banco en 0, cuenta corriente 1000 (el cliente es obligatorio y esta)
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1000, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cr')) || ', p_payment_method_provided => true');
  PERFORM pg_temp.eq('V6 a credito estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V6 a credito', pg_temp.fp(ARRAY[v_op], 'account') || '|' || pg_temp.fp(ARRAY[v_op], 'cash') || '|' || pg_temp.fp(ARRAY[v_op], 'bank'), '1000.00/1|0/0|0/0');
  -- credito SIN cliente -> P0400 credit_requires_client (el contrato cambio)
  SELECT * INTO r FROM pg_temp.edit(v_op, NULL, 1000, '');
  PERFORM pg_temp.eq('V6 credito sin cliente', r.o_state, 'P0400');
  RAISE NOTICE 'PASS (V6: cambio entre libros)';
END $$;

-- ═════════════════ V7: venta del POS (referencia = sales_orders.id) ═════════════════
DO $$
DECLARE r record; v_op uuid := gen_random_uuid(); v_order uuid := gen_random_uuid(); v_ev uuid; v_cnt int;
BEGIN
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id, payment_method_id)
  VALUES (pg_temp.id('owner'), pg_temp.id('acc'), pg_temp.id('client'), pg_temp.id('product'), 1000, 1, 1000, 'ARS', now(), v_op, pg_temp.id('branch'), pg_temp.id('pm_cash'));
  INSERT INTO public.sales_orders (id, account_id, branch_id, client_id, status, total, created_by, sale_operation_id, payment_method_id)
  VALUES (v_order, pg_temp.id('acc'), pg_temp.id('branch'), pg_temp.id('client'), 'confirmed', 1000, pg_temp.id('owner'), v_op, pg_temp.id('pm_cash'));
  PERFORM public.c28_register_cash_movement(pg_temp.id('s_open'), 1000, 'sale', v_order);
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (pg_temp.id('acc'), 'SaleConfirmed', 'SalesOrder', v_order,
          jsonb_build_object('account_id', pg_temp.id('acc'), 'sales_order_id', v_order, 'operation_id', v_op, 'total', 1000, 'payment_method', 'cash'), now());
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1500, '');
  PERFORM pg_temp.eq('V7 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V7 operation_id estable', r.o_res->>'operation_id', v_op::text);
  PERFORM pg_temp.eq('V7 la huella suma las dos referencias', pg_temp.fp(ARRAY[v_op, v_order], 'cash'), '1500.00/1');
  PERFORM pg_temp.eq('V7 la referencia de la orden quedo en cero', (SELECT COALESCE(sum(amount), 0)::text FROM public.cash_movements WHERE reference_id = v_order), '0.00');
  PERFORM pg_temp.eq('V7 la orden sigue a la operacion', (SELECT total::text FROM public.sales_orders WHERE id = v_order), '1500.00');
  -- rastro contable: SaleOperationAdjusted con sales_order_id (el asiento vigente es SalesOrder)
  SELECT count(*) INTO v_cnt FROM public.events WHERE event_type = 'SaleOperationAdjusted' AND (payload->>'sales_order_id')::uuid = v_order
     AND (payload->>'old_operation_id')::uuid = v_op AND (payload->>'new_operation_id')::uuid = v_op AND (payload->>'total')::numeric = 1500;
  PERFORM pg_temp.eq('V7 evento contable del POS', v_cnt::text, '1');
  -- forma de pago de la orden sincronizada
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1500, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_tr')) || ', p_payment_method_provided => true, p_bank_account_id => ' || quote_literal(pg_temp.id('ba')) || ', p_bank_account_provided => true');
  PERFORM pg_temp.eq('V7 a transferencia', r.o_state, '00000');
  PERFORM pg_temp.eq('V7 forma de pago de la orden', (SELECT payment_method_id::text FROM public.sales_orders WHERE id = v_order), pg_temp.id('pm_tr')::text);
  PERFORM pg_temp.eq('V7 caja en cero', pg_temp.fp(ARRAY[v_op, v_order], 'cash'), '0/0');
  PERFORM pg_temp.eq('V7 banco', pg_temp.fp(ARRAY[v_op, v_order], 'bank'), '1500.00/1');
  -- V12: borrar despues de editar compensa exactamente lo vivo
  PERFORM public.rpc_delete_sale_operation(NULL, v_op, 'gate');
  PERFORM pg_temp.eq('V12 banco en cero', pg_temp.fp(ARRAY[v_op, v_order], 'bank'), '0/0');
  PERFORM pg_temp.eq('V12 caja en cero', pg_temp.fp(ARRAY[v_op, v_order], 'cash'), '0/0');
  RAISE NOTICE 'PASS (V7, V12: POS y borrado despues de editar)';
END $$;

-- ═════════════════ V9: operation_id estable y auditoria ═════════════════
DO $$
DECLARE r record; v_op uuid; v_a record; v_n int;
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cash'), NULL, 1000, pg_temp.id('s_open'));
  SELECT * INTO r FROM pg_temp.edit(v_op, NULL, 1100, ', p_reason => ''corregi el precio''');
  PERFORM pg_temp.eq('V9 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V9 operation_id estable', r.o_res->>'operation_id', v_op::text);
  PERFORM pg_temp.eq('V9 filas con el mismo id', (SELECT count(*)::text FROM public.sales WHERE operation_id = v_op), '1');
  SELECT * INTO v_a FROM public.audit_logs WHERE entity_id = v_op AND action = 'sale_operation.edited' AND account_id = pg_temp.id('acc');
  PERFORM pg_temp.eq('V9 audit_logs', (v_a.id IS NOT NULL)::text, 'true');
  PERFORM pg_temp.eq('V9 audit entity_type', v_a.entity_type, 'sale_operation');
  PERFORM pg_temp.eq('V9 audit usuario', v_a.user_id::text, pg_temp.id('owner')::text);
  PERFORM pg_temp.eq('V9 audit motivo', v_a.metadata->>'reason', 'corregi el precio');
  PERFORM pg_temp.eq('V9 audit before.total', v_a.metadata->'before'->>'total', '1000.00');
  PERFORM pg_temp.eq('V9 audit after.total', v_a.metadata->'after'->>'total', '1100.00');
  PERFORM pg_temp.eq('V9 audit money', (v_a.metadata->'money'->'cash'->>'action'), 'both');
  -- una edicion SIN dinero tambien deja rastro
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1100, '');
  SELECT count(*) INTO v_n FROM public.audit_logs WHERE entity_id = v_op AND action = 'sale_operation.edited';
  PERFORM pg_temp.eq('V9 dos ediciones, dos filas de auditoria', v_n::text, '2');
  RAISE NOTICE 'PASS (V9)';
END $$;

-- ═════════════════ V10: rol (OQ-4) ═════════════════
DO $$
DECLARE r record; v_op uuid; v_before text;
BEGIN
  -- venta en efectivo CARGADA por el cajero (es su autor)
  PERFORM pg_temp.as_user(pg_temp.id('cashier'), pg_temp.id('acc'));
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cash'), NULL, 1000, pg_temp.id('s_open'));
  -- sin tocar dinero: el rol de siempre alcanza
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1000, '');
  PERFORM pg_temp.eq('V10 sin dinero', r.o_state, '00000');
  -- tocando dinero: owner/admin
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1400, '');
  PERFORM pg_temp.eq('V10 cajero corrige dinero', r.o_state, 'P0403');
  IF r.o_msg NOT LIKE 'money_edit_requires_admin:%' THEN RAISE EXCEPTION 'V10 mensaje: %', r.o_msg; END IF;
  PERFORM pg_temp.eq('V10 nada escrito', pg_temp.ledger_rows(), v_before);
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1400, ', p_dry_run => true');
  PERFORM pg_temp.eq('V10 el plan lo informa como dato', r.o_res->'plan'->'blocks'->0->>'token', 'money_edit_requires_admin');
  PERFORM pg_temp.as_user(pg_temp.id('owner'), pg_temp.id('acc'));
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1400, '');
  PERFORM pg_temp.eq('V10 el dueno si', r.o_state, '00000');
  RAISE NOTICE 'PASS (V10: rol)';
END $$;

-- ═════════════════ V11: el plan en seco es el que se ejecuta ═════════════════
DO $$
DECLARE r record; r2 record; v_op uuid; v_before text;
BEGIN
  v_op := pg_temp.mk_sale(pg_temp.id('pm_cash'), pg_temp.id('client'), 1000, pg_temp.id('s_open'));
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit(v_op, pg_temp.id('client'), 1250, ', p_dry_run => true');
  PERFORM pg_temp.eq('V11b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('V11b sin escritura', pg_temp.ledger_rows(), v_before);
  PERFORM pg_temp.eq('V11b caja: registra y compensa', r.o_res->'plan'->'cash'->>'action', 'both');
  SELECT * INTO r2 FROM pg_temp.edit(v_op, pg_temp.id('client'), 1250, '');
  PERFORM pg_temp.eq('V11b estado real', r2.o_state, '00000');
  PERFORM pg_temp.eq('V11b el plan ejecutado es el de la vista previa', (r2.o_res->'money')::text, (r.o_res->'plan')::text);
  RAISE NOTICE 'PASS (V11)';
END $$;

-- ── Cleanup asertado ─────────────────────────────────────────────────────────
ROLLBACK;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'ed-dv-%@test.local')
     OR EXISTS (SELECT 1 FROM public.branches WHERE name = '__edv_branch2__') THEN
    RAISE EXCEPTION 'CLEANUP FAILED: quedaron filas del gate test_edicion_dinero_venta';
  END IF;
  RAISE NOTICE 'PASS (cleanup): sin residuo';
END $$;
