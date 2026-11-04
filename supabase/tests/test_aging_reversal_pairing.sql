-- =============================================================================
-- GATE: test_aging_reversal_pairing.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 2 (tasks 2.1-2.3)
--
-- Emparejamiento de la REVERSION de un cargo en el aging FIFO (D9).
--
-- La imputacion de cobros a cargos es una derivacion FIFO por linea de flotacion (cobranzas-vencimientos D4).
-- Hasta hoy el credito de una reversion de cargo (`credit_note` del cliente, `debit_note` del proveedor) iba al
-- POZO general: revertir el cargo de una venta editada cancelaba el cargo MAS VIEJO de la cuenta y no el propio.
-- El saldo total no cambia, pero si el reparto por cargo y con el los tramos de mora, el aviso diario de deuda
-- vencida y la posibilidad de cambiar un vencimiento. Con la edicion de operaciones con dinero eso deja de ser
-- un caso raro (6-7 borrados historicos) y pasa a ser frecuente.
--
-- Regla (D9): la reversion cancela PRIMERO los cargos de su misma referencia y de la misma cuenta corriente, en
-- el orden de la linea de flotacion de esos cargos; el remanente va al pozo. El invariante de cierre (suma de lo
-- abierto = saldo) se conserva.
--
-- El gate EJECUTA los cinco lugares SQL que derivan la imputacion sobre el MISMO ledger sintetico:
--   rpc_receivables_report · rpc_payables_report · _produce_receivables_overdue_digest ·
--   rpc_update_customer_charge_due_date · rpc_update_supplier_charge_due_date
-- y la funcion unica que los alimenta (_customer_open_items / _supplier_open_items). El sexto y septimo lugar
-- (el CTE de Python que usan los dos repositorios) lo cubre backend/tests/test_aging_reversal_pairing.py contra
-- esta misma base.
--
-- Todo en UNA transaccion que termina en ROLLBACK (sin residuo, asertado al final).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE _ag (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
  v_user   uuid := gen_random_uuid();
  v_acc    uuid;
  v_cx uuid; v_cy uuid; v_cz uuid; v_cn uuid;
  v_ax uuid; v_ay uuid; v_az uuid; v_an uuid;
  v_sx uuid; v_sa uuid;
  v_t      date := public.reporting_local_today();
  v_ref_a  uuid := gen_random_uuid();
  v_ref_b  uuid := gen_random_uuid();
  v_ref_r  uuid := gen_random_uuid();
  v_ref_z  uuid := gen_random_uuid();
  v_ref_v  uuid := gen_random_uuid();
  v_ref_w  uuid := gen_random_uuid();
  v_mov_a  uuid;
  v_sup_a  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'aging-pairing@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Aging Pairing'));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: sin cuenta para el anchor'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'SETUP FAILED: auth.uid()'; END IF;

  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_acc, '__ag_x__', 'active') RETURNING id INTO v_cx;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_acc, '__ag_y__', 'active') RETURNING id INTO v_cy;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_acc, '__ag_z__', 'active') RETURNING id INTO v_cz;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_acc, '__ag_n__', 'active') RETURNING id INTO v_cn;
  v_ax := public.c30_get_or_create_customer_account(v_acc, v_cx);
  v_ay := public.c30_get_or_create_customer_account(v_acc, v_cy);
  v_az := public.c30_get_or_create_customer_account(v_acc, v_cz);
  v_an := public.c30_get_or_create_customer_account(v_acc, v_cn);

  -- ── Cliente X: el caso de la spec. A (otra venta, vencida) y B editada (1000 -> 1200) ────────────────────
  PERFORM public.c30_register_customer_account_movement(v_ax, 500,  'sale',        v_ref_a, v_t - 5);
  PERFORM public.c30_register_customer_account_movement(v_ax, 1000, 'sale',        v_ref_b, v_t + 10);
  PERFORM public.c30_register_customer_account_movement(v_ax, 1200, 'sale',        v_ref_b, v_t + 10);   -- cargo nuevo primero (D5)
  PERFORM public.c30_register_customer_account_movement(v_ax, -1000,'credit_note', v_ref_b);
  -- Orden de insercion real de una edicion: A, B1, B2, reversion. created_at escalonado para fijar la linea de flotacion.
  UPDATE public.customer_account_movements SET created_at = now() - interval '4 days' WHERE customer_account_id = v_ax AND reference_id = v_ref_a;
  UPDATE public.customer_account_movements SET created_at = now() - interval '3 days' WHERE customer_account_id = v_ax AND reference_id = v_ref_b AND amount = 1000;
  UPDATE public.customer_account_movements SET created_at = now() - interval '2 days' WHERE customer_account_id = v_ax AND reference_id = v_ref_b AND amount = 1200;
  UPDATE public.customer_account_movements SET created_at = now() - interval '1 days' WHERE customer_account_id = v_ax AND movement_type = 'credit_note';
  SELECT id INTO v_mov_a FROM public.customer_account_movements WHERE customer_account_id = v_ax AND reference_id = v_ref_a;

  -- ── Cliente Y: cadena de dos ediciones (c1, r1, c2, r2, c3) + un cargo ajeno mas viejo ──────────────────
  PERFORM public.c30_register_customer_account_movement(v_ay, 300,  'sale',        v_ref_z, v_t - 2);
  PERFORM public.c30_register_customer_account_movement(v_ay, 1000, 'sale',        v_ref_r, v_t + 10);
  PERFORM public.c30_register_customer_account_movement(v_ay, 1200, 'sale',        v_ref_r, v_t + 10);
  PERFORM public.c30_register_customer_account_movement(v_ay, -1000,'credit_note', v_ref_r);
  PERFORM public.c30_register_customer_account_movement(v_ay, 900,  'sale',        v_ref_r, v_t + 10);
  PERFORM public.c30_register_customer_account_movement(v_ay, -1200,'credit_note', v_ref_r);
  UPDATE public.customer_account_movements SET created_at = now() - interval '9 days' WHERE customer_account_id = v_ay AND reference_id = v_ref_z;
  UPDATE public.customer_account_movements SET created_at = now() - interval '8 days' WHERE customer_account_id = v_ay AND amount = 1000 AND movement_type = 'sale';
  UPDATE public.customer_account_movements SET created_at = now() - interval '7 days' WHERE customer_account_id = v_ay AND amount = 1200 AND movement_type = 'sale';
  UPDATE public.customer_account_movements SET created_at = now() - interval '6 days' WHERE customer_account_id = v_ay AND amount = -1000;
  UPDATE public.customer_account_movements SET created_at = now() - interval '5 days' WHERE customer_account_id = v_ay AND amount = 900;
  UPDATE public.customer_account_movements SET created_at = now() - interval '4 days' WHERE customer_account_id = v_ay AND amount = -1200;

  -- ── Cliente Z (control): una nota de credito HUERFANA (sin cargo de su referencia) va al pozo ───────────
  PERFORM public.c30_register_customer_account_movement(v_az, 400, 'sale',        v_ref_v, v_t - 3);
  PERFORM public.c30_register_customer_account_movement(v_az, -100,'credit_note', v_ref_w);
  -- ── Cliente N (control): una nota de credito SIN referencia tambien va al pozo ────────────────────────
  PERFORM public.c30_register_customer_account_movement(v_an, 400, 'sale',        gen_random_uuid(), v_t - 3);
  PERFORM public.c30_register_customer_account_movement(v_an, -100,'credit_note', NULL);

  -- ── Proveedor X: espejo exacto del cliente X ──────────────────────────────────────────────────────────
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc, '__ag_s__') RETURNING id INTO v_sx;
  v_sa := public.c30_get_or_create_supplier_account(v_acc, v_sx);
  PERFORM public.c30_register_supplier_account_movement(v_sa, 500,  'purchase',   v_ref_a, v_t - 5);
  PERFORM public.c30_register_supplier_account_movement(v_sa, 1000, 'purchase',   v_ref_b, v_t + 10);
  PERFORM public.c30_register_supplier_account_movement(v_sa, 1200, 'purchase',   v_ref_b, v_t + 10);
  PERFORM public.c30_register_supplier_account_movement(v_sa, -1000,'debit_note', v_ref_b);
  UPDATE public.supplier_account_movements SET created_at = now() - interval '4 days' WHERE supplier_account_id = v_sa AND reference_id = v_ref_a;
  UPDATE public.supplier_account_movements SET created_at = now() - interval '3 days' WHERE supplier_account_id = v_sa AND reference_id = v_ref_b AND amount = 1000;
  UPDATE public.supplier_account_movements SET created_at = now() - interval '2 days' WHERE supplier_account_id = v_sa AND reference_id = v_ref_b AND amount = 1200;
  UPDATE public.supplier_account_movements SET created_at = now() - interval '1 days' WHERE supplier_account_id = v_sa AND movement_type = 'debit_note';
  SELECT id INTO v_sup_a FROM public.supplier_account_movements WHERE supplier_account_id = v_sa AND reference_id = v_ref_a;

  INSERT INTO _ag VALUES ('user', v_user), ('acc', v_acc), ('cx', v_cx), ('cy', v_cy), ('cz', v_cz), ('cn', v_cn),
    ('ax', v_ax), ('ay', v_ay), ('az', v_az), ('an', v_an), ('sx', v_sx), ('sa', v_sa),
    ('mov_a', v_mov_a), ('sup_a', v_sup_a);
END $$;

-- ── Los cinco lugares SQL sobre el mismo ledger ─────────────────────────────────────────────────────────
DO $$
DECLARE
  v_acc  uuid := (SELECT v FROM _ag WHERE k = 'acc');
  v_user uuid := (SELECT v FROM _ag WHERE k = 'user');
  r      record;
  v_n    int;
  v_meta numeric;
  v_res  jsonb;
  v_t    date := public.reporting_local_today();
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- (1) rpc_receivables_report — cliente X: A (500, vencido) sigue abierto; el cargo viejo de B esta en 0; el nuevo (1200) abierto.
  SELECT * INTO r FROM public.rpc_receivables_report(v_acc) WHERE client_id = (SELECT v FROM _ag WHERE k = 'cx');
  IF r.overdue_total <> 500 OR r.amount_overdue_1_30 <> 500 OR r.amount_current <> 1200 OR r.balance <> 1700 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (1-X): la reversion de B debe cancelar SU cargo, no el mas viejo de la cuenta. Esperaba vencido=500 (1_30=500), vigente=1200, saldo=1700; trae vencido=%, 1_30=%, vigente=%, saldo=%',
      r.overdue_total, r.amount_overdue_1_30, r.amount_current, r.balance;
  END IF;
  -- cliente Y: cadena de dos ediciones: queda abierto sólo c3 (900) y el cargo ajeno (300, vencido)
  SELECT * INTO r FROM public.rpc_receivables_report(v_acc) WHERE client_id = (SELECT v FROM _ag WHERE k = 'cy');
  IF r.overdue_total <> 300 OR r.amount_current <> 900 OR r.balance <> 1200 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (1-Y): cadena de ediciones: debe quedar abierto sólo el ultimo cargo (900) y el ajeno (300 vencido); trae vencido=%, vigente=%, saldo=%',
      r.overdue_total, r.amount_current, r.balance;
  END IF;
  -- controles: la nota huerfana y la nota sin referencia van al pozo (cancelan su propio cargo, el unico)
  SELECT * INTO r FROM public.rpc_receivables_report(v_acc) WHERE client_id = (SELECT v FROM _ag WHERE k = 'cz');
  IF r.overdue_total <> 300 OR r.balance <> 300 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (1-Z): la nota huerfana va al pozo: vencido=300, saldo=300; trae vencido=%, saldo=%', r.overdue_total, r.balance;
  END IF;
  SELECT * INTO r FROM public.rpc_receivables_report(v_acc) WHERE client_id = (SELECT v FROM _ag WHERE k = 'cn');
  IF r.overdue_total <> 300 OR r.balance <> 300 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (1-N): la nota sin referencia va al pozo: vencido=300, saldo=300; trae vencido=%, saldo=%', r.overdue_total, r.balance;
  END IF;
  -- invariante de cierre en TODOS los clientes del fixture
  FOR r IN SELECT * FROM public.rpc_receivables_report(v_acc) LOOP
    IF r.amount_current + r.overdue_total + r.amount_no_due_date <> r.balance THEN
      RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (1-cierre): la suma de tramos (%) no es el saldo (%) para el cliente %',
        r.amount_current + r.overdue_total + r.amount_no_due_date, r.balance, r.client_name;
    END IF;
  END LOOP;

  -- (2) rpc_payables_report — espejo del cliente X
  SELECT * INTO r FROM public.rpc_payables_report(v_acc) WHERE supplier_id = (SELECT v FROM _ag WHERE k = 'sx');
  IF r.overdue_total <> 500 OR r.amount_overdue_1_30 <> 500 OR r.amount_current <> 1200 OR r.balance <> 1700 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (2): espejo proveedor: esperaba vencido=500, vigente=1200, saldo=1700; trae vencido=%, vigente=%, saldo=%',
      r.overdue_total, r.amount_current, r.balance;
  END IF;

  -- (3) _produce_receivables_overdue_digest — el aviso diario suma sólo lo vencido: 500 (X) + 300 (Y) + 300 (Z) + 300 (N) = 1400
  PERFORM public._produce_receivables_overdue_digest();
  SELECT (el.metadata->>'overdue_total')::numeric INTO v_meta
  FROM public.email_logs el
  WHERE el.user_id = v_user AND el.event_type = 'receivables_overdue_digest' AND (el.metadata->>'account_id')::uuid = v_acc
  ORDER BY el.created_at DESC LIMIT 1;
  IF v_meta IS DISTINCT FROM 1400 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (3): el aviso diario de deuda vencida debia sumar 1400 y suma %', v_meta;
  END IF;
  SELECT (el.metadata->>'overdue_total')::numeric INTO v_meta
  FROM public.email_logs el
  WHERE el.user_id = v_user AND el.event_type = 'payables_overdue_digest' AND (el.metadata->>'account_id')::uuid = v_acc
  ORDER BY el.created_at DESC LIMIT 1;
  IF v_meta IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (3b): el aviso de deuda vencida con proveedores debia sumar 500 y suma %', v_meta;
  END IF;

  -- (4) rpc_update_customer_charge_due_date: el cargo A sigue ABIERTO (500) y por lo tanto su vencimiento se puede cambiar;
  --     con el reparto viejo la reversion de B lo cancelaba y esto levantaba charge_fully_settled.
  BEGIN
    v_res := public.rpc_update_customer_charge_due_date((SELECT v FROM _ag WHERE k = 'mov_a'), v_t + 30, 'gate aging');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (4): el cargo A sigue abierto, su vencimiento tiene que poder cambiarse; levanto % (%)', SQLSTATE, SQLERRM;
  END;
  IF (v_res->>'due_date')::date <> v_t + 30 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (4b): el vencimiento no cambio: %', v_res;
  END IF;

  -- (5) rpc_update_supplier_charge_due_date — espejo
  BEGIN
    v_res := public.rpc_update_supplier_charge_due_date((SELECT v FROM _ag WHERE k = 'sup_a'), v_t + 30, 'gate aging');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (5): el cargo A del proveedor sigue abierto; levanto % (%)', SQLSTATE, SQLERRM;
  END;
  RAISE NOTICE 'PASS (1-5): los cinco lugares SQL reparten la imputacion con el emparejamiento de la reversion.';
END $$;

-- ── La funcion unica que los alimenta, comparada con los lugares anteriores ─────────────────────────────
DO $$
DECLARE
  v_acc  uuid := (SELECT v FROM _ag WHERE k = 'acc');
  v_user uuid := (SELECT v FROM _ag WHERE k = 'user');
  v_open numeric;
  v_ax   uuid := (SELECT v FROM _ag WHERE k = 'ax');
  v_ay   uuid := (SELECT v FROM _ag WHERE k = 'ay');
  v_sa   uuid := (SELECT v FROM _ag WHERE k = 'sa');
  v_bal  numeric;
  r      record;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- Cliente X: tres cargos, abiertos 500 (A), 0 (B1) y 1200 (B2)
  IF (SELECT array_agg(o.open_amount ORDER BY o.open_amount) FROM public._customer_open_items(v_acc, v_ax) o) IS DISTINCT FROM ARRAY[0, 500, 1200]::numeric[] THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H1): cargos abiertos de X: %', (SELECT array_agg(o.open_amount ORDER BY o.open_amount) FROM public._customer_open_items(v_acc, v_ax) o);
  END IF;
  -- Cliente Y (cadena): c1=0, c2=0, c3=900, ajeno=300
  IF (SELECT array_agg(o.open_amount ORDER BY o.open_amount) FROM public._customer_open_items(v_acc, v_ay) o) IS DISTINCT FROM ARRAY[0, 0, 300, 900]::numeric[] THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H2): cadena de ediciones, cargos abiertos de Y: %', (SELECT array_agg(o.open_amount ORDER BY o.open_amount) FROM public._customer_open_items(v_acc, v_ay) o);
  END IF;
  -- Invariante de cierre sobre TODAS las cuentas corrientes de la cuenta: suma de abierto = saldo
  FOR r IN SELECT ca.id, ca.balance FROM public.customer_accounts ca WHERE ca.account_id = v_acc LOOP
    SELECT COALESCE(SUM(o.open_amount), 0) INTO v_open FROM public._customer_open_items(v_acc, r.id) o;
    IF v_open <> r.balance THEN
      RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H3): invariante de cierre roto en la cuenta %: abierto=%, saldo=%', r.id, v_open, r.balance;
    END IF;
  END LOOP;
  FOR r IN SELECT sa.id, sa.balance FROM public.supplier_accounts sa WHERE sa.account_id = v_acc LOOP
    SELECT COALESCE(SUM(o.open_amount), 0) INTO v_open FROM public._supplier_open_items(v_acc, r.id) o;
    IF v_open <> r.balance THEN
      RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H4): invariante de cierre roto en la cuenta de proveedor %: abierto=%, saldo=%', r.id, v_open, r.balance;
    END IF;
  END LOOP;
  -- Sin parte: todas las cuentas de la cuenta; y la funcion es interna (nunca por PostgREST).
  IF (SELECT COUNT(DISTINCT o.party_account_id) FROM public._customer_open_items(v_acc) o) <> 4 THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H5): sin parte debia devolver las cuatro cuentas corrientes';
  END IF;
  IF has_function_privilege('authenticated', 'public._customer_open_items(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._customer_open_items(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._supplier_open_items(uuid, uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._supplier_open_items(uuid, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (H6): las funciones de abierto por cargo son internas';
  END IF;
  RAISE NOTICE 'PASS (H): _customer_open_items / _supplier_open_items — cadena, huerfana, invariante de cierre e ACL.';
END $$;

ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'aging-pairing@test.local') THEN
    RAISE EXCEPTION 'GATE AGING-PAIRING FAILED (cleanup): quedo el anchor';
  END IF;
  RAISE NOTICE 'PASS: gate aging-reversal-pairing completo y sin residuo.';
END $$;
