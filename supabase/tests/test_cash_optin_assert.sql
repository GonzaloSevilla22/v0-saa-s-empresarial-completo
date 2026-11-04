-- =============================================================================
-- GATE: test_cash_optin_assert.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda B, grupo 6 (tasks 6.1-6.3, D16)
--
-- UNA sola validacion del opt-in de caja. Hoy las tres condiciones (kind = cash,
-- sesion abierta en la sucursal efectiva, fecha de hoy) estan copiadas en TRES
-- altas: rpc_create_sale_operation_v2, rpc_create_purchase_operation
-- (_purchase_operation_core) y rpc_create_expense. La edicion con dinero las
-- necesita con una variante (sin la fecha de hoy si la operacion ya tenia huella
-- de caja), asi que nace `_cash_optin_assert` y las tres altas migran a ella.
--
-- Este gate EJECUTA las tres altas (nada de mirar texto) con la MATRIZ de las tres
-- condiciones y asserta token, ERRCODE y mensaje EXACTOS. Se corrio antes de la
-- migracion contra el cuerpo vivo (caracterizacion: PASA) y debe dar el MISMO
-- veredicto despues (task 6.3). Ademas ejecuta el helper directo, incluida la
-- variante de correccion (p_had_cash_footprint = true).
--
--   (M) matriz x 3 altas:  A kind no cash | B sesion cerrada | C sesion de otra
--       sucursal | D fecha != hoy | E camino feliz (escribe la caja) | F sin sesion
--       (no-op)
--   (H) helper directo: los mismos veredictos + variante de correccion + sesion
--       NULL = no-op
--
-- Una transaccion con ROLLBACK; el ultimo bloque asserta el cleanup.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _co_ids (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE _co_res (doc text, caso text, state text, msg text, writes int);

DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_acc     uuid;
  v_branch  uuid;
  v_branch2 uuid;
  v_cb      uuid;
  v_cb2     uuid;
  v_s_open  uuid;
  v_s_closed uuid;
  v_s_other uuid;
  v_pm_cash uuid;
  v_pm_tr   uuid;
  v_product uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'cash-optin@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Cash Optin'));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user LIMIT 1;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_acc ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cb FROM public.cashboxes WHERE branch_id = v_branch ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL OR v_branch IS NULL OR v_cb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: sin cuenta/sucursal/caja';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
  VALUES (v_acc, '__gate_co_branch2__', true, 'active', now()) RETURNING id INTO v_branch2;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch2, '__gate_co_caja2__') RETURNING id INTO v_cb2;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cb, 'open', 0, v_user) RETURNING id INTO v_s_closed;
  UPDATE public.cash_sessions SET status = 'closed', closed_by = v_user, closed_at = now(),
         closing_balance = 0, counted_balance = 0, expected_balance = 0, difference = 0 WHERE id = v_s_closed;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cb, 'open', 0, v_user) RETURNING id INTO v_s_open;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cb2, 'open', 0, v_user) RETURNING id INTO v_s_other;

  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_acc AND kind = 'cash' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_tr   FROM public.payment_methods WHERE account_id = v_acc AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_tr IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta no tiene formas de pago cash/transfer sembradas';
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user, v_acc, '__gate_co_product__', 100, 40, 'GATE-CO-1') RETURNING id INTO v_product;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_acc, v_branch, v_product, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO _co_ids VALUES ('user', v_user), ('acc', v_acc), ('branch', v_branch), ('branch2', v_branch2),
    ('cb', v_cb), ('s_open', v_s_open), ('s_closed', v_s_closed), ('s_other', v_s_other),
    ('pm_cash', v_pm_cash), ('pm_tr', v_pm_tr), ('product', v_product);
END $$;

-- ── (M) Matriz contra las tres altas ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.alta(p_doc text, p_pm uuid, p_session uuid, p_date date, p_key text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_acc uuid := (SELECT v FROM _co_ids WHERE k = 'acc');
  v_branch uuid := (SELECT v FROM _co_ids WHERE k = 'branch');
  v_product uuid := (SELECT v FROM _co_ids WHERE k = 'product');
  v_state text; v_msg text; v_before int; v_after int;
BEGIN
  SELECT count(*) INTO v_before FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
   JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_acc;
  BEGIN
    IF p_doc = 'sale' THEN
      PERFORM public.rpc_create_sale_operation_v2(
        p_doc || ':' || p_key, NULL, p_date, 'ARS',
        jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 100, 'quantity', 1)),
        v_branch, NULL, p_pm, p_session, NULL, NULL);
    ELSIF p_doc = 'purchase' THEN
      PERFORM public.rpc_create_purchase_operation(
        p_doc || ':' || p_key, p_date, 'gate co compra',
        jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 100, 'quantity', 1)),
        v_branch, NULL, p_pm, NULL, NULL, p_session, NULL);
    ELSE
      PERFORM public.rpc_create_expense('otros', 100, p_date, 'gate co gasto', v_branch, NULL, p_pm, p_session, NULL);
    END IF;
    v_state := 'OK'; v_msg := NULL;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  SELECT count(*) INTO v_after FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
   JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_acc;
  -- el caso feliz escribe; los rechazos no dejan rastro (la excepcion revierte el sub-bloque)
  INSERT INTO _co_res VALUES (p_doc, p_key, v_state, v_msg, v_after - v_before);
END $$;

DO $$
DECLARE
  d text;
  v_today date := public.reporting_local_today();
  v_pm_cash uuid := (SELECT v FROM _co_ids WHERE k = 'pm_cash');
  v_pm_tr uuid := (SELECT v FROM _co_ids WHERE k = 'pm_tr');
  v_open uuid := (SELECT v FROM _co_ids WHERE k = 's_open');
  v_closed uuid := (SELECT v FROM _co_ids WHERE k = 's_closed');
  v_other uuid := (SELECT v FROM _co_ids WHERE k = 's_other');
BEGIN
  FOREACH d IN ARRAY ARRAY['sale', 'purchase', 'expense'] LOOP
    PERFORM pg_temp.alta(d, v_pm_tr,   v_open,   v_today,     'A');
    PERFORM pg_temp.alta(d, v_pm_cash, v_closed, v_today,     'B');
    PERFORM pg_temp.alta(d, v_pm_cash, v_other,  v_today,     'C');
    PERFORM pg_temp.alta(d, v_pm_cash, v_open,   v_today - 1, 'D');
    PERFORM pg_temp.alta(d, v_pm_cash, v_open,   v_today,     'E');
    PERFORM pg_temp.alta(d, v_pm_cash, NULL,     v_today,     'F');
  END LOOP;
END $$;

DO $$
DECLARE
  d text; c text; r record; v_fail text := '';
  v_exp_state text; v_exp_msg text; v_noun_a text; v_noun_b text; v_noun_c text;
BEGIN
  FOR r IN SELECT * FROM _co_res ORDER BY doc, caso LOOP
    d := r.doc; c := r.caso;
    v_noun_a := CASE d WHEN 'sale' THEN 'de la venta' WHEN 'purchase' THEN 'de la compra' ELSE 'del gasto' END;
    v_noun_b := CASE d WHEN 'sale' THEN 'una venta' WHEN 'purchase' THEN 'una compra' ELSE 'un gasto' END;
    v_exp_state := 'P0422';
    IF c = 'A' THEN
      v_exp_msg := 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: transfer)';
    ELSIF c IN ('B', 'C') THEN
      v_exp_msg := 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva ' || v_noun_a;
    ELSIF c = 'D' THEN
      v_exp_msg := 'cash_optin_requires_today: sólo se puede registrar en caja ' || v_noun_b || CASE d WHEN 'expense' THEN ' fechado' ELSE ' fechada' END || ' hoy (' || public.reporting_local_today() || ')';
    ELSE
      v_exp_state := 'OK'; v_exp_msg := NULL;
    END IF;
    IF r.state IS DISTINCT FROM v_exp_state OR r.msg IS DISTINCT FROM v_exp_msg THEN
      v_fail := v_fail || format(E'\n  %s/%s: esperaba [%s | %s] y dio [%s | %s]', d, c, v_exp_state, v_exp_msg, r.state, r.msg);
    END IF;
    IF c = 'E' AND r.writes <> 1 THEN
      v_fail := v_fail || format(E'\n  %s/E: el camino feliz debia escribir 1 movimiento de caja y escribio %s', d, r.writes);
    END IF;
    IF c <> 'E' AND r.writes <> 0 THEN
      v_fail := v_fail || format(E'\n  %s/%s: no debia escribir caja y escribio %s', d, c, r.writes);
    END IF;
  END LOOP;
  IF v_fail <> '' THEN
    RAISE EXCEPTION 'GATE CASH-OPTIN (M) FAILED:%', v_fail;
  END IF;
  IF (SELECT count(*) FROM _co_res) <> 18 THEN
    RAISE EXCEPTION 'GATE CASH-OPTIN (M) FAILED: la matriz debia dar 18 filas y dio %', (SELECT count(*) FROM _co_res);
  END IF;
  RAISE NOTICE 'PASS (M): 3 altas x 6 casos con token, ERRCODE y mensaje exactos';
END $$;

-- ── (H) Helper directo ───────────────────────────────────────────────────────
DO $$
DECLARE
  v_acc uuid := (SELECT v FROM _co_ids WHERE k = 'acc');
  v_branch uuid := (SELECT v FROM _co_ids WHERE k = 'branch');
  v_open uuid := (SELECT v FROM _co_ids WHERE k = 's_open');
  v_closed uuid := (SELECT v FROM _co_ids WHERE k = 's_closed');
  v_other uuid := (SELECT v FROM _co_ids WHERE k = 's_other');
  v_today date := public.reporting_local_today();
  v_state text; v_msg text;
BEGIN
  -- sesion NULL = no-op, cualquiera sea el resto
  PERFORM public._cash_optin_assert(v_acc, NULL, 'transfer', v_branch, v_today - 9, false, 'sale');

  -- camino feliz
  PERFORM public._cash_optin_assert(v_acc, v_open, 'cash', v_branch, v_today, false, 'sale');

  -- VARIANTE DE CORRECCION: con huella de caja previa la fecha de hoy NO se exige...
  PERFORM public._cash_optin_assert(v_acc, v_open, 'cash', v_branch, v_today - 30, true, 'expense');

  -- ...pero las otras dos condiciones siguen intactas con huella previa.
  BEGIN
    PERFORM public._cash_optin_assert(v_acc, v_open, 'transfer', v_branch, v_today, true, 'sale');
    RAISE EXCEPTION 'H1: debia rechazar kind no cash con huella previa';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE; v_msg := SQLERRM;
    IF v_state <> 'P0422' OR v_msg NOT LIKE 'cash_optin_requires_cash_kind:%' THEN
      RAISE EXCEPTION 'H1: dio [% | %]', v_state, v_msg;
    END IF;
  END;
  BEGIN
    PERFORM public._cash_optin_assert(v_acc, v_closed, 'cash', v_branch, v_today, true, 'purchase');
    RAISE EXCEPTION 'H2: debia rechazar sesion cerrada con huella previa';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE; v_msg := SQLERRM;
    IF v_state <> 'P0422' OR v_msg NOT LIKE 'cash_optin_requires_open_session:%de la compra' THEN
      RAISE EXCEPTION 'H2: dio [% | %]', v_state, v_msg;
    END IF;
  END;
  BEGIN
    PERFORM public._cash_optin_assert(v_acc, v_other, 'cash', v_branch, v_today, true, 'sale');
    RAISE EXCEPTION 'H3: debia rechazar sesion de otra sucursal con huella previa';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state <> 'P0422' THEN RAISE EXCEPTION 'H3: dio [%]', v_state; END IF;
  END;
  -- sin huella previa la fecha de hoy SI se exige (mismo veredicto que el alta)
  BEGIN
    PERFORM public._cash_optin_assert(v_acc, v_open, 'cash', v_branch, v_today - 1, false, 'sale');
    RAISE EXCEPTION 'H4: debia rechazar fecha != hoy sin huella previa';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE; v_msg := SQLERRM;
    IF v_state <> 'P0422' OR v_msg NOT LIKE 'cash_optin_requires_today:%' THEN
      RAISE EXCEPTION 'H4: dio [% | %]', v_state, v_msg;
    END IF;
  END;
  RAISE NOTICE 'PASS (H): helper directo, variante de correccion y no-op con sesion NULL';
END $$;

-- ── Cleanup asertado ─────────────────────────────────────────────────────────
ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'cash-optin@test.local')
     OR EXISTS (SELECT 1 FROM public.branches WHERE name = '__gate_co_branch2__') THEN
    RAISE EXCEPTION 'CLEANUP FAILED: quedaron filas del gate test_cash_optin_assert';
  END IF;
  RAISE NOTICE 'PASS (cleanup): sin residuo';
END $$;
