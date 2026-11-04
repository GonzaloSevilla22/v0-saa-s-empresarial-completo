-- =============================================================================
-- GATE: test_op_money_footprint.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 1 (tasks 1.1-1.4)
--
-- La HUELLA NETA de una operacion (D3) y el BORRADO que compensa sobre ella.
--
-- Hoy las tres RPCs de borrado compensan sumando SOLO el tipo original del
-- documento (`movement_type = 'sale'` / `'purchase'` / `'expense'`). Eso es
-- correcto mientras una operacion tenga un unico movimiento por libro, pero deja
-- de serlo en cuanto una referencia acumula el movimiento original, su
-- compensacion y el movimiento nuevo (lo que produce una edicion con dinero, y
-- lo que ya produce hoy la edicion de un gasto): se compensa dos veces lo ya
-- compensado. Ademas la caja se agrupa por SESION y se lee con SELECT ... INTO,
-- que se queda con UNA sola fila, y el banco hace un espejo por fila.
--
-- Este gate EJECUTA las tres RPCs de borrado (nada de verificar que existen) con
-- ediciones plantadas a mano como `postgres`, el mismo estado que dejara una
-- edicion con dinero:
--   (S1) venta del POS (referencia = sales_orders.id) editada de 1000 a 1200 en
--        los TRES libros -> borrar compensa 1200 en cada uno, no 2200.
--   (S2) gasto editado de 500 a 300 -> borrar compensa 300, no 800.
--   (S3) caja repartida en DOS sesiones de la misma caja -> UNA compensacion.
--   (S4) huella neta cero (ya compensada) -> el borrado no exige sesion abierta
--        ni escribe nada.
--   (S5) signo invertido plantado -> se compensa igual (existencia, no signo).
--   (S6) venta del formulario sin ediciones: el MISMO resultado que antes
--        (equivalencia con el cuerpo previo guardado en evidence/tanda-a/).
--   (S7) compra editada (cuenta corriente del proveedor + caja).
--   (F)  la funcion `op_money_footprint`: filas, cuenta del libro, grupos por
--        caja y por familia bancaria, aislamiento entre cuentas.
--
-- Todo corre en UNA transaccion que termina en ROLLBACK: no hay residuo, y el
-- ultimo bloque lo ASERTA (cleanup asertado). Un fallo corta con ON_ERROR_STOP.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _fp_ids (k text PRIMARY KEY, v uuid);

-- ── Fixture ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_user_a   uuid := gen_random_uuid();
  v_user_b   uuid := gen_random_uuid();
  v_acc_a    uuid;
  v_acc_b    uuid;
  v_branch   uuid;
  v_cashbox  uuid;
  v_cashbox2 uuid;
  v_sc       uuid;   -- sesion que se CIERRA (caja 1)
  v_so       uuid;   -- sesion abierta (caja 1)
  v_sc2      uuid;   -- sesion cerrada de la caja 2 (sin sesion abierta)
  v_product  uuid;
  v_client   uuid;
  v_supplier uuid;
  v_bank     uuid;
  v_ca       uuid;
  v_sa       uuid;
  v_order1   uuid := gen_random_uuid();
  v_op1      uuid := gen_random_uuid();
  v_exp2     uuid;
  v_op3      uuid := gen_random_uuid();
  v_op4      uuid := gen_random_uuid();
  v_op5      uuid := gen_random_uuid();
  v_op6      uuid := gen_random_uuid();
  v_op7      uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'op-footprint-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Op Footprint A')),
         (v_user_b, 'authenticated', 'authenticated', 'op-footprint-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Op Footprint B'));

  SELECT account_id INTO v_acc_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  IF v_acc_a IS NULL OR v_acc_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creo la cuenta de los anchors';
  END IF;

  SELECT id INTO v_branch  FROM public.branches  WHERE account_id = v_acc_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox FROM public.cashboxes WHERE branch_id = v_branch ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL OR v_cashbox IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta A no tiene sucursal o caja';
  END IF;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch, '__gate_fp_caja2__') RETURNING id INTO v_cashbox2;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_acc_a, '__gate_fp_product__', 1000, 400, 'GATE-FP-1') RETURNING id INTO v_product;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_acc_a, v_branch, v_product, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_acc_a, '__gate_fp_client__', 'active') RETURNING id INTO v_client;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc_a, '__gate_fp_supplier__') RETURNING id INTO v_supplier;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_acc_a, '__gate_fp_bank__', 'ARS', 0) RETURNING id INTO v_bank;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION 'SETUP FAILED: auth.uid() no resuelve al anchor A';
  END IF;

  -- Sesiones: la CERRADA recibe antes de cerrarse todo lo "viejo".
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox, 'open', 0, v_user_a) RETURNING id INTO v_sc;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox2, 'open', 0, v_user_a) RETURNING id INTO v_sc2;

  v_ca := public.c30_get_or_create_customer_account(v_acc_a, v_client);
  v_sa := public.c30_get_or_create_supplier_account(v_acc_a, v_supplier);

  -- ── S1: venta del POS (ref = sales_orders.id), editada 1000 -> 1200 ───────
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, v_client, v_product, 1200, 1, 1200, 'ARS', CURRENT_DATE, v_op1, v_branch);
  INSERT INTO public.sales_orders (id, account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_order1, v_acc_a, v_branch, v_client, 'confirmed', 1200, v_user_a, v_op1);
  PERFORM public.c30_register_customer_account_movement(v_ca, 1000, 'sale', v_order1);
  PERFORM public.c28_register_cash_movement(v_sc, 1000, 'sale', v_order1);
  PERFORM public._register_bank_movement(v_bank, 1000, 'transfer_in', 'sale', v_order1, CURRENT_DATE - 3, v_branch, 'gate fp s1 original');

  -- ── S2: gasto editado 500 -> 300 ──────────────────────────────────────────
  INSERT INTO public.expenses (user_id, account_id, category, amount, date, description, branch_id)
  VALUES (v_user_a, v_acc_a, 'otros', 300, now(), '__gate_fp_expense__', v_branch) RETURNING id INTO v_exp2;
  PERFORM public.c28_register_cash_movement(v_sc, -500, 'expense', v_exp2);
  PERFORM public._register_bank_movement(v_bank, -500, 'transfer_out', 'expense', v_exp2, CURRENT_DATE - 3, v_branch, 'gate fp s2 original');

  -- ── S3: venta con caja en dos sesiones de la MISMA caja (400 + 600) ───────
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, NULL, v_product, 1000, 1, 1000, 'ARS', CURRENT_DATE, v_op3, v_branch);
  PERFORM public.c28_register_cash_movement(v_sc, 400, 'sale', v_op3);

  -- ── S4: huella ya compensada, en una caja SIN sesion abierta ─────────────
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, NULL, v_product, 1000, 1, 1000, 'ARS', CURRENT_DATE, v_op4, v_branch);
  PERFORM public.c28_register_cash_movement(v_sc2, 1000, 'sale', v_op4);
  PERFORM public.c28_register_cash_movement(v_sc2, -1000, 'sale_reversal', v_op4);

  -- ── S7: compra editada 800 -> 1000 (cuenta corriente del proveedor + caja) ─
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id, supplier_id)
  VALUES (v_user_a, v_acc_a, v_product, 1000, 1, 1000, '__gate_fp_purchase__', CURRENT_DATE, v_op7, v_branch, v_supplier);
  PERFORM public.c30_register_supplier_account_movement(v_sa, 800, 'purchase', v_op7);
  PERFORM public.c28_register_cash_movement(v_sc, -800, 'purchase_payment', v_op7);

  -- Cierra la sesion "vieja" de cada caja.
  UPDATE public.cash_sessions SET status = 'closed', closed_by = v_user_a, closed_at = now(),
         closing_balance = 0, counted_balance = 0, expected_balance = 0, difference = 0
   WHERE id IN (v_sc, v_sc2);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox, 'open', 0, v_user_a) RETURNING id INTO v_so;

  -- ── Lo "nuevo" de las ediciones, ya en la sesion abierta ──────────────────
  -- S1: reversion de 1000 y movimiento nuevo de 1200, con la MISMA referencia.
  PERFORM public.c30_register_customer_account_movement(v_ca, 1200, 'sale', v_order1);   -- cargo nuevo primero (D5)
  PERFORM public.c30_register_customer_account_movement(v_ca, -1000, 'credit_note', v_order1);
  PERFORM public.c28_register_cash_movement(v_so, -1000, 'sale_reversal', v_order1);
  PERFORM public.c28_register_cash_movement(v_so, 1200, 'sale', v_order1);
  PERFORM public._register_bank_movement(v_bank, -1000, 'transfer_out', 'sale', v_order1, CURRENT_DATE, v_branch, 'gate fp s1 espejo');
  PERFORM public._register_bank_movement(v_bank, 1200, 'transfer_in', 'sale', v_order1, CURRENT_DATE - 3, v_branch, 'gate fp s1 nuevo');
  -- S2
  PERFORM public.c28_register_cash_movement(v_so, 500, 'expense_reversal', v_exp2);
  PERFORM public.c28_register_cash_movement(v_so, -300, 'expense', v_exp2);
  PERFORM public._register_bank_movement(v_bank, 500, 'transfer_in', 'expense', v_exp2, CURRENT_DATE, v_branch, 'gate fp s2 espejo');
  PERFORM public._register_bank_movement(v_bank, -300, 'transfer_out', 'expense', v_exp2, CURRENT_DATE - 3, v_branch, 'gate fp s2 nuevo');
  -- S3: el resto de la caja en la sesion abierta
  PERFORM public.c28_register_cash_movement(v_so, 600, 'sale', v_op3);
  -- S5: signo invertido plantado (un 'sale' NEGATIVO)
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, NULL, v_product, 300, 1, 300, 'ARS', CURRENT_DATE, v_op5, v_branch);
  PERFORM public.c28_register_cash_movement(v_so, -300, 'sale', v_op5);
  -- S6: venta del formulario SIN ediciones, en los tres libros
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, v_client, v_product, 1000, 1, 1000, 'ARS', CURRENT_DATE, v_op6, v_branch);
  PERFORM public.c30_register_customer_account_movement(v_ca, 1000, 'sale', v_op6);
  PERFORM public.c28_register_cash_movement(v_so, 1000, 'sale', v_op6);
  PERFORM public._register_bank_movement(v_bank, 1000, 'transfer_in', 'sale', v_op6, CURRENT_DATE, v_branch, 'gate fp s6');
  -- S7: la edicion de la compra
  PERFORM public.c30_register_supplier_account_movement(v_sa, 1000, 'purchase', v_op7);
  PERFORM public.c30_register_supplier_account_movement(v_sa, -800, 'debit_note', v_op7);
  PERFORM public.c28_register_cash_movement(v_so, 800, 'purchase_payment_reversal', v_op7);
  PERFORM public.c28_register_cash_movement(v_so, -1000, 'purchase_payment', v_op7);

  INSERT INTO _fp_ids VALUES
    ('user_a', v_user_a), ('user_b', v_user_b), ('acc_a', v_acc_a), ('acc_b', v_acc_b), ('branch', v_branch),
    ('cashbox', v_cashbox), ('cashbox2', v_cashbox2), ('sc', v_sc), ('so', v_so), ('sc2', v_sc2),
    ('product', v_product), ('client', v_client), ('supplier', v_supplier), ('bank', v_bank),
    ('ca', v_ca), ('sa', v_sa), ('order1', v_order1), ('op1', v_op1), ('exp2', v_exp2),
    ('op3', v_op3), ('op4', v_op4), ('op5', v_op5), ('op6', v_op6), ('op7', v_op7);
END $$;

-- ── Borrados: cada libro compensa EXACTAMENTE su huella neta ─────────────────
DO $$
DECLARE
  i          record;
  v_n        int;
  v_sum      numeric;
  v_sessions int;
  v_ok       boolean;
  v_pre_cash int;
  v_msg      text;
BEGIN
  SELECT * INTO i FROM (SELECT
    (SELECT v FROM _fp_ids WHERE k='user_a') user_a, (SELECT v FROM _fp_ids WHERE k='acc_a') acc_a,
    (SELECT v FROM _fp_ids WHERE k='cashbox') cashbox, (SELECT v FROM _fp_ids WHERE k='cashbox2') cashbox2,
    (SELECT v FROM _fp_ids WHERE k='so') so, (SELECT v FROM _fp_ids WHERE k='sc') sc, (SELECT v FROM _fp_ids WHERE k='sc2') sc2,
    (SELECT v FROM _fp_ids WHERE k='bank') bank, (SELECT v FROM _fp_ids WHERE k='ca') ca, (SELECT v FROM _fp_ids WHERE k='sa') sa,
    (SELECT v FROM _fp_ids WHERE k='order1') order1, (SELECT v FROM _fp_ids WHERE k='op1') op1,
    (SELECT v FROM _fp_ids WHERE k='exp2') exp2, (SELECT v FROM _fp_ids WHERE k='op3') op3,
    (SELECT v FROM _fp_ids WHERE k='op4') op4, (SELECT v FROM _fp_ids WHERE k='op5') op5,
    (SELECT v FROM _fp_ids WHERE k='op6') op6, (SELECT v FROM _fp_ids WHERE k='op7') op7) x;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', i.user_a::text, 'role', 'authenticated')::text, true);

  -- pre-condicion: el saldo vigente de la venta editada es 1200
  SELECT balance INTO v_sum FROM public.customer_accounts WHERE id = i.ca;
  IF v_sum <> 2200 THEN  -- 1200 (S1) + 1000 (S6)
    RAISE EXCEPTION 'SETUP FAILED: saldo del cliente esperado 2200 antes de borrar, es %', v_sum;
  END IF;

  -- ═══ S1: venta del POS editada (3 libros) ═══════════════════════════════
  BEGIN
    PERFORM public.rpc_delete_sale_operation(p_operation_id => i.op1);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1): borrar la venta del POS editada levanto % (%): el borrado debe compensar la huella NETA de 1200, no sumar el tipo original', SQLSTATE, v_msg;
  END;
  -- cuenta corriente: la huella neta (1200) queda en cero
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.customer_account_movements
   WHERE customer_account_id = i.ca AND reference_id = i.order1 AND movement_type IN ('sale', 'credit_note');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-cc): la huella neta de cuenta corriente debia quedar en 0, es %', v_sum;
  END IF;
  -- caja: ni de menos ni de mas, y a la sesion ABIERTA
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.cash_movements
   WHERE reference_id = i.order1 AND movement_type IN ('sale', 'sale_reversal');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-caja): la huella neta de caja debia quedar en 0 (compensar el neto 1200, no 2200), es %', v_sum;
  END IF;
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_n, v_sum FROM public.cash_movements
   WHERE session_id = i.so AND reference_id = i.order1 AND movement_type = 'sale_reversal' AND amount = -1200;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-caja-sesion): esperaba UNA reversion de -1200 en la sesion abierta con la referencia de la orden, hay %', v_n;
  END IF;
  -- banco: neto 0 y el espejo del neto, sin conciliar
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.bank_movements
   WHERE bank_account_id = i.bank AND source_doc_type = 'sale' AND source_doc_ref = i.order1;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-banco): la huella neta bancaria debia quedar en 0, es %', v_sum;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.bank_movements
                  WHERE bank_account_id = i.bank AND source_doc_ref = i.order1 AND movement_type = 'transfer_out'
                    AND amount = -1200 AND reconciliation_status = 'unreconciled'
                    AND description = 'Reversión por borrado de operación') THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-banco-espejo): esperaba UN espejo transfer_out de -1200 unreconciled (una compensacion por fila de huella)';
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales WHERE operation_id = i.op1) THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S1-fila): la venta no se borro';
  END IF;
  RAISE NOTICE 'PASS (S1): borrar una venta del POS editada compensa la huella neta (1200) en los tres libros, con la referencia de la orden.';

  -- ═══ S2: gasto editado ═══════════════════════════════════════════════════
  BEGIN
    PERFORM public.rpc_delete_expense(i.exp2);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S2): borrar el gasto editado levanto % (%)', SQLSTATE, v_msg;
  END;
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.cash_movements
   WHERE reference_id = i.exp2 AND movement_type IN ('expense', 'expense_reversal');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S2-caja): borrar un gasto editado de 500 a 300 debe reponer 300 y dejar la huella en 0 (no reponer 800); neto = %', v_sum;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.bank_movements
   WHERE bank_account_id = i.bank AND source_doc_type = 'expense' AND source_doc_ref = i.exp2;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S2-banco): la huella neta bancaria del gasto debia quedar en 0, es %', v_sum;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.bank_movements
                  WHERE source_doc_ref = i.exp2 AND movement_type = 'transfer_in' AND amount = 300
                    AND reconciliation_status = 'unreconciled' AND description LIKE 'Reversión por borrado de gasto%') THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S2-banco-espejo): esperaba UN espejo transfer_in de +300 con el marcador del borrado de gasto';
  END IF;
  RAISE NOTICE 'PASS (S2): borrar un gasto editado repone el neto (300), no la suma del tipo original (800).';

  -- ═══ S3: caja repartida en dos sesiones de la misma caja ═════════════════
  PERFORM public.rpc_delete_sale_operation(p_operation_id => i.op3);
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.cash_movements
   WHERE reference_id = i.op3 AND movement_type IN ('sale', 'sale_reversal');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S3-neto): con la caja repartida en dos sesiones la huella neta debia quedar en 0, es % (el SELECT ... INTO se quedaba con UNA sola sesion)', v_sum;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.cash_movements
   WHERE reference_id = i.op3 AND movement_type = 'sale_reversal';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S3-una): esperaba UNA unica compensacion para la caja, hay %', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cash_movements
                  WHERE session_id = i.so AND reference_id = i.op3 AND movement_type = 'sale_reversal' AND amount = -1000) THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S3-sesion): la compensacion de -1000 va a la sesion ABIERTA de la misma caja';
  END IF;
  RAISE NOTICE 'PASS (S3): una caja en dos sesiones se compensa con UNA fila de -1000 en la sesion abierta.';

  -- ═══ S4: huella neta cero -> sin sesion abierta, sin escritura ═══════════
  SELECT COUNT(*) INTO v_pre_cash FROM public.cash_movements WHERE session_id = i.sc2;
  BEGIN
    PERFORM public.rpc_delete_sale_operation(p_operation_id => i.op4);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S4): una huella ya compensada (neto 0) no debe exigir sesion abierta; levanto % (%)', SQLSTATE, v_msg;
  END;
  SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = i.sc2;
  IF v_n <> v_pre_cash THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S4-escritura): una huella neta cero no debe escribir nada; la caja paso de % a % movimientos', v_pre_cash, v_n;
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales WHERE operation_id = i.op4) THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S4-fila): la venta no se borro';
  END IF;
  RAISE NOTICE 'PASS (S4): neto cero = ya compensado: se borra sin sesion abierta y sin escribir.';

  -- ═══ S5: signo invertido plantado: se compensa igual ═════════════════════
  PERFORM public.rpc_delete_sale_operation(p_operation_id => i.op5);
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.cash_movements
   WHERE reference_id = i.op5 AND movement_type IN ('sale', 'sale_reversal');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S5): un movimiento de venta con signo invertido (-300) debia compensarse igual (existencia, no signo); neto = %', v_sum;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.cash_movements
                  WHERE session_id = i.so AND reference_id = i.op5 AND movement_type = 'sale_reversal' AND amount = 300) THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S5-opuesto): la compensacion debia ser el opuesto exacto (+300)';
  END IF;
  RAISE NOTICE 'PASS (S5): el disparo es por existencia del neto, nunca por signo.';

  -- ═══ S6: sin ediciones -> el mismo resultado que antes (equivalencia) ════
  PERFORM public.rpc_delete_sale_operation(p_operation_id => i.op6);
  IF NOT EXISTS (SELECT 1 FROM public.customer_account_movements
                  WHERE customer_account_id = i.ca AND movement_type = 'credit_note' AND amount = -1000 AND reference_id = i.op6)
     OR NOT EXISTS (SELECT 1 FROM public.cash_movements
                  WHERE session_id = i.so AND movement_type = 'sale_reversal' AND amount = -1000 AND reference_id = i.op6)
     OR NOT EXISTS (SELECT 1 FROM public.bank_movements
                  WHERE bank_account_id = i.bank AND source_doc_ref = i.op6 AND movement_type = 'transfer_out' AND amount = -1000
                    AND description = 'Reversión por borrado de operación' AND reconciliation_status = 'unreconciled')
  THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S6): el borrado de una venta SIN ediciones debe dejar los mismos contra-movimientos que antes (credit_note -1000, sale_reversal -1000, espejo transfer_out -1000)';
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE reference_id = i.op6 AND movement_type = 'sale_reversal';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S6-una): una sola reversion de caja, hay %', v_n;
  END IF;
  RAISE NOTICE 'PASS (S6): equivalencia — una venta sin ediciones se borra con los mismos libros e importes de siempre.';

  -- ═══ S7: compra editada ══════════════════════════════════════════════════
  BEGIN
    PERFORM public.rpc_delete_purchase_operation(p_operation_id => i.op7);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S7): borrar la compra editada levanto % (%)', SQLSTATE, v_msg;
  END;
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.supplier_account_movements
   WHERE supplier_account_id = i.sa AND reference_id = i.op7 AND movement_type IN ('purchase', 'debit_note');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S7-cc): la huella neta del proveedor debia quedar en 0, es %', v_sum;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_sum FROM public.cash_movements
   WHERE reference_id = i.op7 AND movement_type IN ('purchase_payment', 'purchase_payment_reversal');
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (S7-caja): la huella neta de caja de la compra debia quedar en 0, es %', v_sum;
  END IF;
  RAISE NOTICE 'PASS (S7): borrar una compra editada compensa la huella neta de proveedor y caja.';
END $$;

-- ── La funcion de huella neta (D3) ──────────────────────────────────────────
DO $$
DECLARE
  v_user_a   uuid := (SELECT v FROM _fp_ids WHERE k='user_a');
  v_acc_a    uuid := (SELECT v FROM _fp_ids WHERE k='acc_a');
  v_acc_b    uuid := (SELECT v FROM _fp_ids WHERE k='acc_b');
  v_branch   uuid := (SELECT v FROM _fp_ids WHERE k='branch');
  v_cashbox  uuid := (SELECT v FROM _fp_ids WHERE k='cashbox');
  v_so       uuid := (SELECT v FROM _fp_ids WHERE k='so');
  v_sc       uuid := (SELECT v FROM _fp_ids WHERE k='sc');
  v_bank     uuid := (SELECT v FROM _fp_ids WHERE k='bank');
  v_client   uuid := (SELECT v FROM _fp_ids WHERE k='client');
  v_ca       uuid := (SELECT v FROM _fp_ids WHERE k='ca');
  v_order1   uuid := (SELECT v FROM _fp_ids WHERE k='order1');
  v_ref      uuid := gen_random_uuid();
  v_ref2     uuid := gen_random_uuid();
  r          record;
  v_n        int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Despues de los borrados las referencias de S1 ya no tienen huella.
  SELECT COUNT(*) INTO v_n FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_order1]);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F0): tras borrar, la huella neta de la venta del POS debia ser vacia, trae % filas', v_n;
  END IF;

  -- Huella nueva: cuenta corriente 700 (sale 1000 - credit_note 300), caja 600 en dos sesiones
  -- (200 + 400), banco: transfer_in 500 + transfer_out -100 (misma familia) y card_settlement 90.
  PERFORM public.c30_register_customer_account_movement(v_ca, 1000, 'sale', v_ref);
  PERFORM public.c30_register_customer_account_movement(v_ca, -300, 'credit_note', v_ref);
  PERFORM public.c28_register_cash_movement(v_so, 200, 'sale', v_ref);
  PERFORM public.c28_register_cash_movement(v_so, 400, 'sale', v_ref);
  PERFORM public._register_bank_movement(v_bank, 500, 'transfer_in', 'sale', v_ref, CURRENT_DATE, v_branch, 'gate fp f');
  PERFORM public._register_bank_movement(v_bank, -100, 'transfer_out', 'sale', v_ref, CURRENT_DATE, v_branch, 'gate fp f');
  PERFORM public._register_bank_movement(v_bank, 90, 'card_settlement', 'sale', v_ref, CURRENT_DATE, v_branch, 'gate fp f');
  -- Ruido que NO entra: el mismo importe con OTRO tipo de documento y otra referencia.
  PERFORM public._register_bank_movement(v_bank, 77, 'transfer_in', 'purchase', v_ref, CURRENT_DATE, v_branch, 'gate fp ruido');
  PERFORM public.c28_register_cash_movement(v_so, 9, 'sale', v_ref2);

  SELECT COUNT(*) INTO v_n FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_ref]);
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F1): esperaba 4 filas (cuenta corriente, caja, banco-transferencia, banco-tarjeta), trae %', v_n;
  END IF;
  SELECT * INTO r FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_ref]) WHERE book = 'account';
  IF r.net <> 700 OR r.ledger_id <> v_ca OR r.reference_id <> v_ref THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F2): cuenta corriente esperada 700 sobre la cuenta del cliente, es % (ledger %)', r.net, r.ledger_id;
  END IF;
  SELECT * INTO r FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_ref]) WHERE book = 'cash';
  IF r.net <> 600 OR r.ledger_id <> v_cashbox THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F3): la caja se agrupa por CAJA: esperaba 600 sobre la caja %, es % sobre %', v_cashbox, r.net, r.ledger_id;
  END IF;
  SELECT * INTO r FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_ref]) WHERE book = 'bank' AND family = 'transfer';
  IF r.net <> 400 OR r.ledger_id <> v_bank OR r.mirror_type <> 'transfer_out' OR r.branch_id IS DISTINCT FROM v_branch THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F4): banco-transferencia esperado neto 400 con espejo transfer_out, es % / %', r.net, r.mirror_type;
  END IF;
  SELECT * INTO r FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[v_ref]) WHERE book = 'bank' AND family = 'card_settlement';
  IF r.net <> 90 OR r.mirror_type <> 'card_settlement' THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F5): banco-tarjeta esperado neto 90 con espejo del mismo tipo, es % / %', r.net, r.mirror_type;
  END IF;
  -- Aislamiento: la misma referencia pedida con la cuenta de OTRO tenant no trae nada.
  SELECT COUNT(*) INTO v_n FROM public.op_money_footprint(v_acc_b, 'sale', ARRAY[v_ref]);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F6): la huella de otra cuenta debe ser vacia, trae %', v_n;
  END IF;
  -- El tipo de documento acota los libros: un gasto no tiene cuenta corriente.
  SELECT COUNT(*) INTO v_n FROM public.op_money_footprint(v_acc_a, 'expense', ARRAY[v_ref]) WHERE book = 'account';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F7): el gasto no tiene cuenta corriente';
  END IF;
  -- Sin referencias, sin filas.
  SELECT COUNT(*) INTO v_n FROM public.op_money_footprint(v_acc_a, 'sale', ARRAY[]::uuid[]);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F8): sin referencias no hay huella';
  END IF;
  -- La variante legible: SECURITY INVOKER y ejecutable por authenticated, nunca por anon.
  IF NOT has_function_privilege('authenticated', 'public.op_money_footprint(uuid, text, uuid[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public.op_money_footprint(uuid, text, uuid[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F9): op_money_footprint debe ser ejecutable por authenticated y nunca por anon';
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.op_money_footprint(uuid, text, uuid[])'::regprocedure) THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (F10): op_money_footprint debe ser SECURITY INVOKER (la RLS filtra al que consulta)';
  END IF;
  RAISE NOTICE 'PASS (F): op_money_footprint — filas por libro, grupos por caja y por familia bancaria, espejo, aislamiento entre cuentas y ACL.';
END $$;

ROLLBACK;

-- ── Cleanup asertado: la transaccion no deja residuo ─────────────────────────
DO $$
DECLARE v_n int;
BEGIN
  SELECT COUNT(*) INTO v_n FROM auth.users WHERE email IN ('op-footprint-a@test.local', 'op-footprint-b@test.local');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (cleanup): quedaron % anchors', v_n;
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.products WHERE name = '__gate_fp_product__';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OP-FOOTPRINT FAILED (cleanup): quedaron % productos del fixture', v_n;
  END IF;
  RAISE NOTICE 'PASS: gate op-money-footprint completo (huella neta + borrado sobre la huella) y sin residuo.';
END $$;
