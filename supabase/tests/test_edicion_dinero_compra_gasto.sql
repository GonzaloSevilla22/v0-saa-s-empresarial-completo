-- =============================================================================
-- GATE: test_edicion_dinero_compra_gasto.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda B, grupos 8 y 9 (tasks 8.1-8.3, 9.1-9.2)
--
-- EJECUTA rpc_atomic_update_purchase_operation y rpc_update_expense con dinero registrado:
--   (P1) compra a credito: sube sin P0425 (cargo nuevo primero), baja con P0425, cambia de proveedor
--   (P2) efectivo del dia / de una sesion cerrada -> la correccion va a la sesion ABIERTA de la misma caja; P0426 sin sesion
--   (P3) transferencia: espejo + nuevo
--   (P4) efectivo -> credito (antes credit_transition_not_allowed)
--   (P5) herencia: credito historico sin proveedor ni cargo
--   (P6) PurchaseAdjusted con el id ESTABLE (old = new); (P7) auditoria; (P8) borrar despues de editar; (P9) p_dry_run
--   (X1) gasto en efectivo del dia y de una sesion cerrada; (X2) efectivo -> transferencia (asiento acredita banco);
--   (X3) transferencia -> efectivo (asiento acredita caja: la huella bancaria quedo en cero); (X4) solo categoria con la
--        caja cerrada = sin escrituras; (X5) credit sigue rechazado; (X6) p_dry_run; (X7) auditoria; (X8) borrado
--   (R)  rol (OQ-4): corregir dinero es del dueno o un administrador, en compra y en gasto
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
    RAISE EXCEPTION 'GATE EDICION-DINERO-COMPRA-GASTO FAILED [%]: esperaba <%> y dio <%>', p_label, p_want, p_got;
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
CREATE FUNCTION pg_temp.fp(p_kind text, p_refs uuid[], p_book text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(SUM(net), 0)::text || '/' || count(*)::text
  FROM public.op_money_footprint(pg_temp.id('acc'), p_kind, p_refs) WHERE book = p_book
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

CREATE FUNCTION pg_temp.purchase_ids(p_op uuid) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT array_agg(id ORDER BY id) FROM public.purchases WHERE operation_id = p_op
$$;

CREATE FUNCTION pg_temp.mk_purchase(p_pm uuid, p_supplier uuid, p_amount numeric, p_session uuid DEFAULT NULL,
                                    p_bank uuid DEFAULT NULL, p_date date DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_create_purchase_operation(gen_random_uuid()::text, COALESCE(p_date, public.reporting_local_today()), 'gate compra',
         pg_temp.items(p_amount), pg_temp.id('branch'), NULL, p_pm, p_bank, p_supplier, p_session, NULL);
  RETURN (r->>'operation_id')::uuid;
END $f$;

CREATE FUNCTION pg_temp.edit_p(p_op uuid, p_supplier uuid, p_amount numeric, p_extra text DEFAULT '', p_date date DEFAULT NULL,
                               OUT o_state text, OUT o_msg text, OUT o_res jsonb) LANGUAGE plpgsql AS $f$
BEGIN
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''gate compra editada'', %L::jsonb, p_supplier_id => %L::uuid, p_supplier_provided => true %s)',
    pg_temp.purchase_ids(p_op), COALESCE(p_date, public.reporting_local_today()), pg_temp.items(p_amount), p_supplier, p_extra)) t;
END $f$;

CREATE FUNCTION pg_temp.mk_expense(p_pm uuid, p_amount numeric, p_session uuid DEFAULT NULL, p_bank uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_create_expense('otros', p_amount, public.reporting_local_today(), 'gate gasto', pg_temp.id('branch'), NULL, p_pm, p_session, p_bank);
  RETURN (r->>'expense_id')::uuid;
END $f$;

CREATE FUNCTION pg_temp.edit_x(p_id uuid, p_extra text DEFAULT '',
                               OUT o_state text, OUT o_msg text, OUT o_res jsonb) LANGUAGE plpgsql AS $f$
BEGIN
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try(format(
    'public.rpc_update_expense(p_expense_id => %L::uuid %s)', p_id, p_extra)) t;
END $f$;

-- ── Fixture ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_cashier uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_acc uuid; v_acc_b uuid; v_branch uuid; v_branch2 uuid; v_cb uuid; v_cb2 uuid;
  v_s_old uuid; v_s_open uuid; v_s_open2 uuid; v_member uuid;
  v_ba uuid; v_ba2 uuid; v_pm_cash uuid; v_pm_tr uuid; v_pm_cr uuid; v_pm_cr2 uuid; v_pm_card uuid;
  v_client uuid; v_client2 uuid; v_product uuid; v_sup uuid; v_sup2 uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_owner,   'authenticated', 'authenticated', 'ed-dcg-owner@test.local',   now(), now(), '{"name":"EDCG Dueno"}'::jsonb),
    (v_cashier, 'authenticated', 'authenticated', 'ed-dcg-cashier@test.local', now(), now(), '{"name":"EDCG Cajero"}'::jsonb),
    (v_other,   'authenticated', 'authenticated', 'ed-dcg-other@test.local',   now(), now(), '{"name":"EDCG Otra cuenta"}'::jsonb);
  SELECT account_id INTO v_acc   FROM public.account_members WHERE user_id = v_owner;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id = v_other;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_member, 'cashier');

  v_branch := public.c26_default_branch(v_acc);
  SELECT id INTO v_cb FROM public.cashboxes WHERE branch_id = v_branch ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at) VALUES (v_acc, '__edcg_branch2__', true, 'active', now()) RETURNING id INTO v_branch2;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch2, '__edcg_caja2__') RETURNING id INTO v_cb2;
  PERFORM pg_temp.as_user(v_owner, v_acc);

  -- sesion VIEJA de la caja 1 (se cierra despues de recibir lo "viejo") + sesion abierta de cada caja
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cb, 'open', 0, v_owner) RETURNING id INTO v_s_old;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cb2, 'open', 0, v_owner) RETURNING id INTO v_s_open2;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES (v_acc, '__edcg_bank__', 'ARS', 0) RETURNING id INTO v_ba;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES (v_acc, '__edcg_bank2__', 'ARS', 0) RETURNING id INTO v_ba2;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_acc AND kind = 'cash'     AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_tr   FROM public.payment_methods WHERE account_id = v_acc AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_cr   FROM public.payment_methods WHERE account_id = v_acc AND kind = 'credit'   AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_card FROM public.payment_methods WHERE account_id = v_acc AND kind = 'card'     AND is_active AND deleted_at IS NULL LIMIT 1;
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order) VALUES (v_acc, '__edcg_credit2__', 'credit', 99) RETURNING id INTO v_pm_cr2;

  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_owner, v_acc, '__edcg_client__', 'active') RETURNING id INTO v_client;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_owner, v_acc, '__edcg_client2__', 'active') RETURNING id INTO v_client2;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc, '__edcg_sup__') RETURNING id INTO v_sup;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc, '__edcg_sup2__') RETURNING id INTO v_sup2;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku) VALUES (v_owner, v_acc, '__edcg_product__', 1000, 400, 'GATE-EDCG-1') RETURNING id INTO v_product;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity) VALUES (v_acc, v_branch, v_product, 100000)
    ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100000;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity) VALUES (v_acc, v_branch2, v_product, 100000)
    ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100000;

  INSERT INTO _ev VALUES ('owner', v_owner), ('cashier', v_cashier), ('other', v_other), ('acc', v_acc), ('acc_b', v_acc_b),
    ('branch', v_branch), ('branch2', v_branch2), ('cb', v_cb), ('cb2', v_cb2), ('s_old', v_s_old), ('s_open2', v_s_open2),
    ('ba', v_ba), ('ba2', v_ba2), ('pm_cash', v_pm_cash), ('pm_tr', v_pm_tr), ('pm_cr', v_pm_cr), ('pm_cr2', v_pm_cr2), ('pm_card', v_pm_card),
    ('client', v_client), ('client2', v_client2), ('product', v_product), ('sup', v_sup), ('sup2', v_sup2);
  IF v_pm_cash IS NULL OR v_pm_tr IS NULL OR v_pm_cr IS NULL OR v_pm_card IS NULL OR v_cb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: formas de pago / caja sembradas faltantes';
  END IF;
END $$;

-- Efectivo en la sesion VIEJA (compra y gasto) y despues se cierra.
DO $$
DECLARE v_p uuid; v_x uuid;
BEGIN
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_cash'), pg_temp.id('sup'), 1000, pg_temp.id('s_old'));
  v_x := pg_temp.mk_expense(pg_temp.id('pm_cash'), 500, pg_temp.id('s_old'));
  INSERT INTO _ev VALUES ('p_cash_old', v_p), ('x_cash_old', v_x);
  UPDATE public.cash_sessions SET status = 'closed', closed_by = pg_temp.id('owner'), closed_at = now(),
         closing_balance = 0, counted_balance = 0, expected_balance = 0, difference = 0 WHERE id = pg_temp.id('s_old');
END $$;

-- ═════════ X4 / X1-c / P2-c: sin sesion abierta ═════════
DO $$
DECLARE r record; v_p uuid := pg_temp.id('p_cash_old'); v_x uuid := pg_temp.id('x_cash_old'); v_before text;
BEGIN
  -- X4: gasto en efectivo de una sesion CERRADA; solo cambia la categoria -> H = E: sin escrituras y sin exigir caja abierta
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_category => ''servicios''');
  PERFORM pg_temp.eq('X4 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('X4 categoria', (SELECT category FROM public.expenses WHERE id = v_x), 'servicios');
  PERFORM pg_temp.eq('X4 caja intacta', pg_temp.fp('expense', ARRAY[v_x], 'cash'), '-500.00/1');
  PERFORM pg_temp.eq('X4 libros de dinero', split_part(pg_temp.ledger_rows(), '/', 1) || '/' || split_part(pg_temp.ledger_rows(), '/', 2) || '/' || split_part(pg_temp.ledger_rows(), '/', 3),
                     split_part(v_before, '/', 1) || '/' || split_part(v_before, '/', 2) || '/' || split_part(v_before, '/', 3));
  -- cambiar el importe exige caja abierta
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_amount => 300');
  PERFORM pg_temp.eq('X1-c P0426', r.o_state, 'P0426');
  PERFORM pg_temp.eq('X1-c gasto intacto', (SELECT amount::text FROM public.expenses WHERE id = v_x), '500.00');
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 1200);
  PERFORM pg_temp.eq('P2-c P0426', r.o_state, 'P0426');
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_amount => 300, p_dry_run => true');
  PERFORM pg_temp.eq('X6 en seco', r.o_res->'plan'->'blocks'->0->>'code', 'P0426');
  RAISE NOTICE 'PASS (X4, X1-c, P2-c)';
END $$;

DO $$
DECLARE v_s uuid;
BEGIN
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (pg_temp.id('cb'), 'open', 0, pg_temp.id('owner')) RETURNING id INTO v_s;
  INSERT INTO _ev VALUES ('s_open', v_s);
END $$;

-- ═════════ GASTOS ═════════
DO $$
DECLARE r record; v_x uuid := pg_temp.id('x_cash_old'); v_x2 uuid; v_ev jsonb; v_a record; r2 record;
BEGIN
  -- X1-b: la sesion es CERRADA -> compensa y registra en la abierta de la misma caja
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_amount => 300, p_reason => ''corregi el importe''');
  PERFORM pg_temp.eq('X1-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('X1-b huella', pg_temp.fp('expense', ARRAY[v_x], 'cash'), '-300.00/1');
  PERFORM pg_temp.eq('X1-b movimientos', (SELECT string_agg(movement_type || ':' || amount::text, ',' ORDER BY movement_type)
        FROM public.cash_movements WHERE session_id = pg_temp.id('s_open') AND reference_id = v_x), 'expense:-300.00,expense_reversal:500.00');
  -- ExpenseAdjusted con la contrapartida de la huella posterior: no hay banco -> kind NULL (caja)
  SELECT payload INTO v_ev FROM public.events WHERE event_type = 'ExpenseAdjusted' AND aggregate_id = v_x ORDER BY occurred_at DESC, id DESC LIMIT 1;
  PERFORM pg_temp.eq('X1-b ExpenseAdjusted kind', COALESCE(v_ev->>'kind', 'null'), 'null');
  PERFORM pg_temp.eq('X1-b ExpenseAdjusted amount', v_ev->>'amount', '300.00');
  -- auditoria
  SELECT * INTO v_a FROM public.audit_logs WHERE entity_id = v_x AND action = 'expense.edited';
  PERFORM pg_temp.eq('X7 auditoria', (v_a.id IS NOT NULL)::text, 'true');
  PERFORM pg_temp.eq('X7 motivo', v_a.metadata->>'reason', 'corregi el importe');
  PERFORM pg_temp.eq('X7 before', v_a.metadata->'before'->>'amount', '500.00');
  PERFORM pg_temp.eq('X7 after', v_a.metadata->'after'->>'amount', '300.00');

  -- X2: efectivo -> transferencia (cuenta bancaria explicita): la caja se compensa, el banco recibe el egreso;
  -- el asiento acredita BANCO (kind transfer) porque la huella posterior es bancaria.
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_tr')) || ', p_payment_method_provided => true, p_bank_account_id => '
                                      || quote_literal(pg_temp.id('ba')) || ', p_bank_account_provided => true');
  PERFORM pg_temp.eq('X2 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('X2 caja', pg_temp.fp('expense', ARRAY[v_x], 'cash'), '0/0');
  PERFORM pg_temp.eq('X2 banco', pg_temp.fp('expense', ARRAY[v_x], 'bank'), '-300.00/1');
  SELECT payload INTO v_ev FROM public.events WHERE event_type = 'ExpenseAdjusted' AND aggregate_id = v_x ORDER BY occurred_at DESC, id DESC LIMIT 1;
  PERFORM pg_temp.eq('X2 ExpenseAdjusted kind', v_ev->>'kind', 'transfer');

  -- X3: transferencia -> efectivo: el banco queda en cero (espejo) y el asiento acredita CAJA (kind NULL)
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cash')) || ', p_payment_method_provided => true, p_cash_session_id => '
                                      || quote_literal(pg_temp.id('s_open')) || ', p_cash_provided => true');
  PERFORM pg_temp.eq('X3 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('X3 banco', pg_temp.fp('expense', ARRAY[v_x], 'bank'), '0/0');
  PERFORM pg_temp.eq('X3 caja', pg_temp.fp('expense', ARRAY[v_x], 'cash'), '-300.00/1');
  SELECT payload INTO v_ev FROM public.events WHERE event_type = 'ExpenseAdjusted' AND aggregate_id = v_x ORDER BY occurred_at DESC, id DESC LIMIT 1;
  PERFORM pg_temp.eq('X3 ExpenseAdjusted kind', COALESCE(v_ev->>'kind', 'null'), 'null');

  -- X5: credit sigue rechazado
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cr')) || ', p_payment_method_provided => true');
  PERFORM pg_temp.eq('X5 credit', r.o_state, 'P0400');

  -- X6: el plan en seco es el que se ejecuta
  v_x2 := pg_temp.mk_expense(pg_temp.id('pm_cash'), 200, pg_temp.id('s_open'));
  SELECT * INTO r FROM pg_temp.edit_x(v_x2, ', p_amount => 260, p_dry_run => true');
  PERFORM pg_temp.eq('X6 dry_run', r.o_res->>'dry_run', 'true');
  PERFORM pg_temp.eq('X6 amount intacto', (SELECT amount::text FROM public.expenses WHERE id = v_x2), '200.00');
  SELECT * INTO r2 FROM pg_temp.edit_x(v_x2, ', p_amount => 260');
  PERFORM pg_temp.eq('X6 el plan ejecutado es el de la vista previa', (r2.o_res->'money')::text, (r.o_res->'plan')::text);
  -- borrar despues de editar compensa exactamente lo vivo
  PERFORM public.rpc_delete_expense(v_x2);
  PERFORM pg_temp.eq('X8 borrado', pg_temp.fp('expense', ARRAY[v_x2], 'cash'), '0/0');
  RAISE NOTICE 'PASS (X1, X2, X3, X5, X6, X7, X8: gastos)';
END $$;

-- ═════════ COMPRAS ═════════
DO $$
DECLARE r record; v_p uuid := pg_temp.id('p_cash_old'); v_ev jsonb; v_a record;
BEGIN
  -- P2-b: efectivo de sesion cerrada -> la correccion va a la abierta de la misma caja
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 1200, ', p_reason => ''corregi el costo''');
  PERFORM pg_temp.eq('P2-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P2-b operation_id estable', r.o_res->>'operation_id', v_p::text);
  PERFORM pg_temp.eq('P2-b huella', pg_temp.fp('purchase', ARRAY[v_p], 'cash'), '-1200.00/1');
  PERFORM pg_temp.eq('P2-b movimientos en la abierta', (SELECT string_agg(movement_type || ':' || amount::text, ',' ORDER BY movement_type)
        FROM public.cash_movements WHERE session_id = pg_temp.id('s_open') AND reference_id = v_p), 'purchase_payment:-1200.00,purchase_payment_reversal:1000.00');
  -- PurchaseAdjusted con el id ESTABLE (old = new)
  SELECT payload INTO v_ev FROM public.events WHERE event_type = 'PurchaseAdjusted' AND aggregate_id = v_p ORDER BY occurred_at DESC, id DESC LIMIT 1;
  PERFORM pg_temp.eq('P6 PurchaseAdjusted old', v_ev->>'old_operation_id', v_p::text);
  PERFORM pg_temp.eq('P6 PurchaseAdjusted new', v_ev->>'new_operation_id', v_p::text);
  PERFORM pg_temp.eq('P6 PurchaseAdjusted total', v_ev->>'total', '1200.00');
  SELECT * INTO v_a FROM public.audit_logs WHERE entity_id = v_p AND action = 'purchase_operation.edited';
  PERFORM pg_temp.eq('P7 auditoria', (v_a.id IS NOT NULL)::text, 'true');
  PERFORM pg_temp.eq('P7 motivo', v_a.metadata->>'reason', 'corregi el costo');
  PERFORM pg_temp.eq('P7 before', v_a.metadata->'before'->>'total', '1000.00');
  PERFORM pg_temp.eq('P7 after', v_a.metadata->'after'->>'total', '1200.00');
  RAISE NOTICE 'PASS (P2-b, P6, P7)';
END $$;

DO $$
DECLARE r record; v_p uuid; v_sa uuid; v_bal numeric; v_before text;
BEGIN
  -- P1: compra a credito
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_cr'), pg_temp.id('sup'), 1000);
  SELECT id INTO v_sa FROM public.supplier_accounts WHERE account_id = pg_temp.id('acc') AND supplier_id = pg_temp.id('sup');
  PERFORM pg_temp.eq('P1 cargo', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '1000.00/1');
  SELECT balance INTO v_bal FROM public.supplier_accounts WHERE id = v_sa;
  PERFORM public.c30_register_supplier_account_movement(v_sa, -400, 'payment_made', NULL);
  -- sube con un pago previo: sin P0425 (cargo nuevo primero)
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 1200);
  PERFORM pg_temp.eq('P1-a estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P1-a huella', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '1200.00/1');
  PERFORM pg_temp.eq('P1-a saldo', (SELECT balance::text FROM public.supplier_accounts WHERE id = v_sa), (v_bal + 200 - 400)::text);
  -- baja por debajo de lo pagado -> P0425
  SELECT balance INTO v_bal FROM public.supplier_accounts WHERE id = v_sa;
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 1200 - (v_bal + 1));
  PERFORM pg_temp.eq('P1-b P0425', r.o_state, 'P0425');
  PERFORM pg_temp.eq('P1-b huella intacta', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '1200.00/1');
  -- cambia de proveedor: el cargo se traslada
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup2'), 900);
  PERFORM pg_temp.eq('P1-c estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P1-c un solo ledger', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '900.00/1');
  PERFORM pg_temp.eq('P1-c proveedor nuevo', (SELECT sum(net)::text FROM public.op_money_footprint(pg_temp.id('acc'), 'purchase', ARRAY[v_p]) f
        WHERE f.book = 'account' AND f.ledger_id = (SELECT id FROM public.supplier_accounts WHERE supplier_id = pg_temp.id('sup2'))), '900.00');

  -- P3: transferencia: espejo + nuevo
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_tr'), NULL, 700, NULL, pg_temp.id('ba'));
  SELECT * INTO r FROM pg_temp.edit_p(v_p, NULL, 800);
  PERFORM pg_temp.eq('P3 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P3 banco', pg_temp.fp('purchase', ARRAY[v_p], 'bank'), '-800.00/1');

  -- P4: efectivo -> credito (antes credit_transition_not_allowed)
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_cash'), pg_temp.id('sup'), 600, pg_temp.id('s_open'));
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 600, ', p_payment_method_id => ' || quote_literal(pg_temp.id('pm_cr')) || ', p_payment_method_provided => true');
  PERFORM pg_temp.eq('P4 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P4 cuenta corriente', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '600.00/1');
  PERFORM pg_temp.eq('P4 caja en cero', pg_temp.fp('purchase', ARRAY[v_p], 'cash'), '0/0');

  -- P5: credito HISTORICO sin proveedor y sin cargo: editar el importe NO inventa un cargo ni exige proveedor
  v_p := gen_random_uuid();
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id, payment_method_id)
  VALUES (pg_temp.id('owner'), pg_temp.id('acc'), pg_temp.id('product'), 300, 1, 300, 'historica', now(), v_p, pg_temp.id('branch'), pg_temp.id('pm_cr'));
  SELECT * INTO r FROM pg_temp.edit_p(v_p, NULL, 350);
  PERFORM pg_temp.eq('P5 estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P5 sin cargo', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '0/0');
  -- ...pero si cambia el contrato (le pone proveedor) SI se postea el cargo
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 350);
  PERFORM pg_temp.eq('P5-b estado', r.o_state, '00000');
  PERFORM pg_temp.eq('P5-b cargo', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '350.00/1');

  -- P8: borrar despues de editar compensa exactamente lo vivo
  PERFORM public.rpc_delete_purchase_operation(NULL, v_p, 'gate');
  PERFORM pg_temp.eq('P8 cuenta en cero', pg_temp.fp('purchase', ARRAY[v_p], 'account'), '0/0');
  -- P9: en seco no escribe
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_cash'), NULL, 100, pg_temp.id('s_open'));
  v_before := pg_temp.ledger_rows();
  SELECT * INTO r FROM pg_temp.edit_p(v_p, NULL, 130, ', p_dry_run => true');
  PERFORM pg_temp.eq('P9 sin escritura', pg_temp.ledger_rows(), v_before);
  PERFORM pg_temp.eq('P9 dry_run', r.o_res->>'dry_run', 'true');
  RAISE NOTICE 'PASS (P1, P3, P4, P5, P8, P9: compras)';
END $$;

-- ═════════ ROL (OQ-4): corregir dinero es del dueno o un administrador ═════════
DO $$
DECLARE r record; v_x uuid; v_p uuid; v_member uuid; v_cp uuid := gen_random_uuid();
BEGIN
  -- un miembro con rol de COMPRAS que es autor de su compra en efectivo
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_cp, 'authenticated', 'authenticated', 'ed-dcg-compras@test.local', now(), now(), '{"name":"EDCG Compras"}'::jsonb);
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (pg_temp.id('acc'), v_cp, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (pg_temp.id('acc'), v_member, 'purchases');
  PERFORM pg_temp.as_user(v_cp, pg_temp.id('acc'));
  v_p := pg_temp.mk_purchase(pg_temp.id('pm_cash'), NULL, 100, pg_temp.id('s_open'));
  -- sin tocar dinero: el rol de siempre alcanza
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 100);
  PERFORM pg_temp.eq('R sin dinero', r.o_state, '00000');
  -- tocando dinero: owner/admin
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 140);
  PERFORM pg_temp.eq('R compras corrige dinero', r.o_state, 'P0403');
  IF r.o_msg NOT LIKE 'money_edit_requires_admin:%' THEN RAISE EXCEPTION 'R mensaje: %', r.o_msg; END IF;
  PERFORM pg_temp.as_user(pg_temp.id('owner'), pg_temp.id('acc'));
  SELECT * INTO r FROM pg_temp.edit_p(v_p, pg_temp.id('sup'), 140);
  PERFORM pg_temp.eq('R el dueno si', r.o_state, '00000');
  -- gasto: el dueno lo edita; un miembro sin rol de gasto sigue sin poder (P0401/P0403 de siempre)
  v_x := pg_temp.mk_expense(pg_temp.id('pm_cash'), 90, pg_temp.id('s_open'));
  SELECT * INTO r FROM pg_temp.edit_x(v_x, ', p_amount => 95');
  PERFORM pg_temp.eq('R gasto del dueno', r.o_state, '00000');
  RAISE NOTICE 'PASS (R: rol)';
END $$;

-- ── Cleanup asertado ─────────────────────────────────────────────────────────
ROLLBACK;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'ed-dcg-%@test.local')
     OR EXISTS (SELECT 1 FROM public.branches WHERE name = '__edcg_branch2__') THEN
    RAISE EXCEPTION 'CLEANUP FAILED: quedaron filas del gate test_edicion_dinero_compra_gasto';
  END IF;
  RAISE NOTICE 'PASS (cleanup): sin residuo';
END $$;
