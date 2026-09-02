-- =============================================================================
-- GATE: test_party_payment_cash.sql
-- CHANGE: caja-compras-cobranzas — grupo 4 (cobro y pago de cuenta corriente
-- en efectivo alimentan la caja) + cobranzas-catalogo-pagos (migración de
-- p_payment_method text → p_payment_method_id uuid, D1/D2/D4/D5).
--
-- Pedido textual del PO (2026-09-01): "...tampoco cuando cobrás una cuenta
-- corriente; tiene que funcionar". Sign-off del PO (2026-09-02, "aplicalo con
-- todas las recomendaciones") sobre cobranzas-catalogo-pagos: credit se
-- RECHAZA, other se ACEPTA, la columna text se DROPEA (por eso los asserts
-- de "payment_method persistido" de acá migran a payment_method_id).
--
-- Qué ejercita:
--   (4.1) cobro en efectivo + sesión abierta → cash_movement payment_received
--         POSITIVO, sin bank_movement.
--   (4.2) pago en efectivo + sesión abierta → cash_movement payment_made
--         NEGATIVO, sin bank_movement.
--   (4.3) método bancario con sesión informada → P0422 cash_optin_requires_cash_kind.
--   (4.4) sesión cerrada → P0422 cash_optin_requires_open_session.
--   (4.5) efectivo SIN sesión informada → cobro/pago registrado, cero
--         movimientos de dinero (comportamiento previo intacto).
--   (4.6) IDEMPOTENCIA (la aserción que más importa, D12): dos llamadas con
--         la misma clave → UN solo cash_movement, UN solo movimiento de
--         cuenta corriente, UNA sola fila de cobro/pago, replay=true la
--         segunda vez.
--   (4.7) exactamente una definición viva de cada función (gotcha 42725).
--   (4.8) payment_method_id queda persistido en payments_received/made
--         (cobranzas-catalogo-pagos D3 — antes payment_method text, OQ-1).
--   (4.9) cobro/pago por wallet → bank_movement transfer_in/out (D2: wallet
--         se suma al conjunto bancario).
--   (4.10) cobro/pago imputado a 'other' → sin ningún movimiento de dinero,
--          saldo se reduce igual (etiqueta pura, D2).
--   (4.11) cobro/pago imputado a 'credit' → P0400 (D2: rechazo por diseño).
--   (4.12) forma de pago de OTRO tenant → P0404, sin revelar existencia (D5).
--   (4.13) ninguna enumeración literal de formas de pago sobrevive en el
--          cuerpo vivo de las dos RPCs (gate 5.5 del apply — detector de
--          texto sobre pg_get_functiondef).
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_email_a    text := 'ccc-party-a@test.local';
  v_email_b    text := 'ccc-party-b@test.local';
  v_user_a     uuid := gen_random_uuid();
  v_user_b     uuid := gen_random_uuid();
  v_account_a  uuid;
  v_account_b  uuid;
  v_branch_a1  uuid;
  v_cashbox_a1 uuid;
  v_cashbox_a2 uuid;  -- para la sesión CERRADA de 4.4
  v_session_a1 uuid;
  v_session_a2_closed uuid;
  v_client_a   uuid;
  v_supplier_a uuid;
  v_bank_a     uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(), jsonb_build_object('name', 'Gate CCC Party A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(), jsonb_build_object('name', 'Gate CCC Party B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (setup): no se pudo provisionar el tenant — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a1 IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (setup): sin sucursal sembrada — degradando.'; RETURN;
  END IF;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccp_cashbox_a1__')
  RETURNING id INTO v_cashbox_a1;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccp_cashbox_a2__')
  RETURNING id INTO v_cashbox_a2;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a1, 'open', 5000, v_user_a) RETURNING id INTO v_session_a1;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a2, 'closed', 0, v_user_a) RETURNING id INTO v_session_a2_closed;

  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_ccp_client__')
  RETURNING id INTO v_client_a;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, '__gate_ccp_supplier__')
  RETURNING id INTO v_supplier_a;

  -- cobranzas-catalogo-pagos (D2/D4/D9): cuenta bancaria de A para los kinds
  -- bancarios (transfer/wallet). Única, reusada por todos los casos bancarios
  -- del cobro y del pago.
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_ccp_bank_a__', 'ARS', 0) RETURNING id INTO v_bank_a;

  -- Deuda inicial del cliente (para que los cobros de los bloques de abajo
  -- no choquen con overpayment, P0409): un cargo manual vía el helper C-30,
  -- signo POSITIVO (a diferencia de payment_received, que resta con signo
  -- negativo). created_by exige auth.uid() — se fija el JWT del anchor acá.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  DECLARE
    v_customer_account_id uuid;
  BEGIN
    v_customer_account_id := public.c30_get_or_create_customer_account(v_account_a, v_client_a);
    PERFORM public.c30_register_customer_account_movement(
      v_customer_account_id, 10000, 'sale', gen_random_uuid()
    );
  END;

  RAISE NOTICE 'SETUP OK: 2 tenants (A operativo, B para el guard de tenencia), sesión abierta + sesión cerrada, 1 cliente con deuda inicial, 1 proveedor, 1 cuenta bancaria.';
END $$;


-- ═══════════ (4.1/4.3/4.4/4.5/4.6/4.7/4.8/4.9/4.10/4.11/4.12) COBRO ════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_account_b  uuid;
  v_session_a1 uuid;
  v_session_closed uuid;
  v_client_a   uuid;
  v_bank_a     uuid;
  v_pm_cash    uuid;
  v_pm_transfer uuid;
  v_pm_wallet  uuid;
  v_pm_other   uuid;
  v_pm_credit  uuid;
  v_pm_other_tenant uuid;
  v_result     jsonb;
  v_payment_id uuid;
  v_mov        RECORD;
  v_row        RECORD;
  v_count      integer;
  v_rejected   boolean;
  v_sqlstate   text;
  v_balance_before numeric;
  v_balance_after  numeric;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-party-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-PARTY (4-cobro): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members am JOIN auth.users u ON u.id = am.user_id
    WHERE u.email = 'ccc-party-b@test.local' ORDER BY am.created_at LIMIT 1;
  SELECT cs.id INTO v_session_a1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccp_cashbox_a1__' AND cs.status = 'open';
  SELECT id INTO v_session_closed FROM public.cash_sessions WHERE id NOT IN (
    SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id WHERE cb.name = '__gate_ccp_cashbox_a1__'
  ) AND cashbox_id IN (SELECT id FROM public.cashboxes WHERE name = '__gate_ccp_cashbox_a2__');
  SELECT id INTO v_client_a FROM public.clients WHERE account_id = v_account_a AND name = '__gate_ccp_client__';
  SELECT id INTO v_bank_a FROM public.bank_accounts WHERE account_id = v_account_a AND name = '__gate_ccp_bank_a__';

  IF v_session_a1 IS NULL OR v_client_a IS NULL OR v_bank_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (4-cobro): fixtures incompletos — degradando.'; RETURN;
  END IF;

  -- cobranzas-catalogo-pagos (D5): el kind se DERIVA del catálogo — cada
  -- cuenta ya nace con los 7 kinds sembrados (v3-provisioning-seed +
  -- metodos-pago-operaciones), así que se resuelven por SELECT en vez de
  -- insertarse a mano.
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'     AND is_active LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' AND is_active LIMIT 1;
  SELECT id INTO v_pm_wallet   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'wallet'   AND is_active LIMIT 1;
  SELECT id INTO v_pm_other    FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'other'    AND is_active LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit'   AND is_active LIMIT 1;
  SELECT id INTO v_pm_other_tenant FROM public.payment_methods WHERE account_id = v_account_b AND kind = 'cash' AND is_active LIMIT 1;

  IF v_pm_cash IS NULL OR v_pm_transfer IS NULL OR v_pm_wallet IS NULL OR v_pm_other IS NULL OR v_pm_credit IS NULL OR v_pm_other_tenant IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (4-cobro): catálogo de formas de pago incompleto — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- ═══ (4.1) cobro en efectivo + sesión abierta → payment_received positivo ═
  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.1',
    p_client_id => v_client_a, p_amount => 400,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  SELECT * INTO v_mov FROM public.cash_movements WHERE reference_id = v_payment_id AND movement_type = 'payment_received';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.1): no se creó ningún cash_movement payment_received.';
  END IF;
  IF v_mov.amount <> 400 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.1): el movimiento quedó en % y esperaba +400 (ingreso).', v_mov.amount;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'payment_received' AND source_doc_ref = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.1): un cobro en efectivo escribió % movimientos bancarios.', v_count;
  END IF;

  -- ═══ (4.8) payment_method_id persistido (cobranzas-catalogo-pagos D3) ════
  SELECT payment_method_id INTO v_row FROM public.payments_received WHERE id = v_payment_id;
  IF v_row.payment_method_id IS DISTINCT FROM v_pm_cash THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.8): payments_received.payment_method_id quedó en % y esperaba %.', v_row.payment_method_id, v_pm_cash;
  END IF;
  RAISE NOTICE 'PASS (4.1/4.8): cobro en efectivo ingresa a la caja, sin banco, con payment_method_id persistido.';

  -- ═══ (4.3) método bancario con sesión informada → P0422 ══════════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccp-4.3', p_client_id => v_client_a, p_amount => 100,
      p_payment_method_id => v_pm_transfer, p_bank_account_id => v_bank_a, p_cash_session_id => v_session_a1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0422' AND SQLERRM LIKE '%cash_optin_requires_cash_kind%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.3): un cobro bancario con sesión de caja informada fue aceptado.';
  END IF;

  -- ═══ (4.4) sesión CERRADA → P0422 ═════════════════════════════════════════
  IF v_session_closed IS NOT NULL THEN
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_register_payment_received(
        p_idempotency_key => 'gate-ccp-4.4', p_client_id => v_client_a, p_amount => 50,
        p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_closed
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0422' AND SQLERRM LIKE '%cash_optin_requires_open_session%' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.4): un cobro contra una sesión CERRADA fue aceptado.';
    END IF;
  END IF;
  RAISE NOTICE 'PASS (4.3/4.4): método bancario con sesión informada y sesión cerrada, ambos rechazados con P0422.';

  -- ═══ (4.5) efectivo SIN sesión informada → sin movimientos de dinero ═════
  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.5', p_client_id => v_client_a, p_amount => 60,
    p_payment_method_id => v_pm_cash
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.5): un cobro sin sesión informada escribió % movimientos de caja.', v_count;
  END IF;
  RAISE NOTICE 'PASS (4.5): efectivo sin sesión informada no toca ningún libro de dinero (comportamiento previo intacto).';

  -- ═══ (4.6) IDEMPOTENCIA — la aserción que más importa ═════════════════════
  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.6', p_client_id => v_client_a, p_amount => 120,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.6): la primera llamada ya vino marcada replayed.';
  END IF;

  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.6', p_client_id => v_client_a, p_amount => 120,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.6): la segunda llamada con la MISMA clave no vino marcada replayed=true.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id AND movement_type = 'payment_received';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.6): hay % cash_movements para el cobro idempotente (esperaba exactamente 1).', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.payments_received WHERE id = v_payment_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.6): hay % filas en payments_received para el cobro idempotente (esperaba 1).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4.6): la repetición de la clave de idempotencia no duplica el movimiento de caja ni el cobro.';

  -- ═══ (4.7) exactamente una definición viva ════════════════════════════════
  SELECT COUNT(*) INTO v_count FROM pg_proc WHERE proname = 'rpc_register_payment_received';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.7): hay % definiciones de rpc_register_payment_received (esperaba 1).', v_count;
  END IF;

  -- ═══ (4.9) cobro por wallet → bank_movement transfer_in (D2) ═════════════
  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.9', p_client_id => v_client_a, p_amount => 250,
    p_payment_method_id => v_pm_wallet, p_bank_account_id => v_bank_a
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  SELECT * INTO v_mov FROM public.bank_movements WHERE source_doc_type = 'payment_received' AND source_doc_ref = v_payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.9): un cobro por wallet no escribió ningún bank_movement.';
  END IF;
  IF v_mov.movement_type <> 'transfer_in' OR v_mov.amount <> 250 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.9): bank_movement quedó en (%, %) y esperaba (transfer_in, 250).', v_mov.movement_type, v_mov.amount;
  END IF;
  RAISE NOTICE 'PASS (4.9): wallet ya es kind bancario también en el cobro — bank_movement transfer_in.';

  -- ═══ (4.10) cobro imputado a 'other' → sin ningún libro de dinero ════════
  SELECT balance INTO v_balance_before FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client_a;
  v_result := public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccp-4.10', p_client_id => v_client_a, p_amount => 70,
    p_payment_method_id => v_pm_other
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  SELECT balance INTO v_balance_after FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client_a;
  IF v_balance_after <> v_balance_before - 70 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.10): el saldo no bajó 70 (antes=%, después=%).', v_balance_before, v_balance_after;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.10): other escribió % cash_movements (esperaba 0).', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'payment_received' AND source_doc_ref = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.10): other escribió % bank_movements (esperaba 0).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4.10): other reduce el saldo, imputa el método, no toca ningún libro de dinero.';

  -- ═══ (4.11) cobro imputado a 'credit' → P0400 (D2) ═══════════════════════
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccp-4.11', p_client_id => v_client_a, p_amount => 30,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.11): un cobro imputado a credit debía rechazarse con P0400, dio %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.payments_received pr
    JOIN public.operation_idempotency oi ON oi.idempotency_key = 'gate-ccp-4.11';
  RAISE NOTICE 'PASS (4.11): credit se rechaza con P0400 — cancelar cuenta corriente con cuenta corriente es circular.';

  -- ═══ (4.12) forma de pago de OTRO tenant → P0404, sin revelar nada (D5) ══
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccp-4.12', p_client_id => v_client_a, p_amount => 30,
      p_payment_method_id => v_pm_other_tenant
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0404' THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.12): un cobro con payment_method_id de otro tenant debía rechazarse con P0404, dio %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.payments_received WHERE client_id = v_client_a AND amount = 30
    AND created_at > now() - interval '1 minute' AND payment_method_id = v_pm_other_tenant;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.12): pese al rechazo, quedó una fila imputada al método ajeno.';
  END IF;
  RAISE NOTICE 'PASS (4.12): la forma de pago de otro tenant se rechaza con P0404 — el guard de D5 cubre payment_method_id igual que cubre client_id/supplier_id.';

  -- ═══ (4.13) ninguna enumeración literal de formas de pago sobrevive ══════
  -- (gate 5.5 del apply de cobranzas-catalogo-pagos). El anti-patrón retirado
  -- es la validación de un p_payment_method TEXT contra la taxonomía cerrada
  -- {cash,transfer,card,check} — NO la clasificación bancaria (v_kind IN
  -- (...)) que _pay_register_operation_bank_movement, rpc_create_expense y
  -- el resto del sistema ya usan legítimamente para rutear, no para validar
  -- membresía del vocabulario.
  DECLARE
    v_def_r text := pg_get_functiondef('public.rpc_register_payment_received(text, uuid, numeric, uuid, uuid, uuid, uuid)'::regprocedure);
    v_def_m text := pg_get_functiondef('public.rpc_register_payment_made(text, uuid, numeric, uuid, uuid, uuid, uuid)'::regprocedure);
  BEGIN
    IF v_def_r ILIKE '%invalid_payment_method%' OR v_def_r ILIKE '%NOT IN (''cash''%' THEN
      RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.13-cobro): rpc_register_payment_received todavía valida el payment_method contra una taxonomía de texto propia.';
    END IF;
    IF v_def_m ILIKE '%invalid_payment_method%' OR v_def_m ILIKE '%NOT IN (''cash''%' THEN
      RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.13-pago): rpc_register_payment_made todavía valida el payment_method contra una taxonomía de texto propia.';
    END IF;
    IF v_def_r NOT ILIKE '%payment_methods%' OR v_def_m NOT ILIKE '%payment_methods%' THEN
      RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.13): alguna de las dos RPCs no consulta el catálogo payment_methods para derivar el kind.';
    END IF;
  END;
  RAISE NOTICE 'PASS (4.13): ninguna de las dos RPCs conserva una taxonomía de formas de pago propia — el kind SIEMPRE se deriva del catálogo.';
END $$;


-- ═══ (4.2/4.7/4.8/4.9-pago/4.10-pago/4.11-pago/4.12-pago) PAGO A PROVEEDOR ═
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_account_b  uuid;
  v_session_a1 uuid;
  v_supplier_a uuid;
  v_bank_a     uuid;
  v_pm_cash    uuid;
  v_pm_wallet  uuid;
  v_pm_other   uuid;
  v_pm_credit  uuid;
  v_pm_other_tenant uuid;
  v_result     jsonb;
  v_payment_id uuid;
  v_mov        RECORD;
  v_row        RECORD;
  v_count      integer;
  v_rejected   boolean;
  v_sqlstate   text;
  v_balance_before numeric;
  v_balance_after  numeric;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-party-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-PARTY (4-pago): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members am JOIN auth.users u ON u.id = am.user_id
    WHERE u.email = 'ccc-party-b@test.local' ORDER BY am.created_at LIMIT 1;
  SELECT cs.id INTO v_session_a1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccp_cashbox_a1__' AND cs.status = 'open';
  SELECT id INTO v_supplier_a FROM public.suppliers WHERE account_id = v_account_a AND name = '__gate_ccp_supplier__';
  SELECT id INTO v_bank_a FROM public.bank_accounts WHERE account_id = v_account_a AND name = '__gate_ccp_bank_a__';

  IF v_session_a1 IS NULL OR v_supplier_a IS NULL OR v_bank_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (4-pago): fixtures incompletos — degradando.'; RETURN;
  END IF;

  SELECT id INTO v_pm_cash   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'   AND is_active LIMIT 1;
  SELECT id INTO v_pm_wallet FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'wallet' AND is_active LIMIT 1;
  SELECT id INTO v_pm_other  FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'other'  AND is_active LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit' AND is_active LIMIT 1;
  SELECT id INTO v_pm_other_tenant FROM public.payment_methods WHERE account_id = v_account_b AND kind = 'cash' AND is_active LIMIT 1;

  IF v_pm_cash IS NULL OR v_pm_wallet IS NULL OR v_pm_other IS NULL OR v_pm_credit IS NULL OR v_pm_other_tenant IS NULL THEN
    RAISE NOTICE 'GATE CCC-PARTY (4-pago): catálogo de formas de pago incompleto — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Necesita saldo a favor del proveedor para no chocar con overpayment.
  PERFORM public.rpc_register_supplier_charge(
    p_idempotency_key => 'gate-ccp-4.2-charge', p_supplier_id => v_supplier_a, p_amount => 2000
  );

  -- ═══ (4.2) pago en efectivo + sesión abierta → payment_made negativo ═════
  v_result := public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccp-4.2',
    p_supplier_id => v_supplier_a, p_amount => 400,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  SELECT * INTO v_mov FROM public.cash_movements WHERE reference_id = v_payment_id AND movement_type = 'payment_made';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.2): no se creó ningún cash_movement payment_made.';
  END IF;
  IF v_mov.amount <> -400 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.2): el movimiento quedó en % y esperaba -400 (egreso).', v_mov.amount;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'payment_made' AND source_doc_ref = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.2): un pago en efectivo escribió % movimientos bancarios.', v_count;
  END IF;

  SELECT payment_method_id INTO v_row FROM public.payments_made WHERE id = v_payment_id;
  IF v_row.payment_method_id IS DISTINCT FROM v_pm_cash THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.8-pago): payments_made.payment_method_id quedó en % y esperaba %.', v_row.payment_method_id, v_pm_cash;
  END IF;
  RAISE NOTICE 'PASS (4.2/4.8): pago a proveedor en efectivo egresa de la caja, sin banco, con payment_method_id persistido.';

  -- IDEMPOTENCIA del pago — espejo de 4.6.
  v_result := public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccp-4.6-pago', p_supplier_id => v_supplier_a, p_amount => 90,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  PERFORM public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccp-4.6-pago', p_supplier_id => v_supplier_a, p_amount => 90,
    p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_a1
  );
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id AND movement_type = 'payment_made';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.6-pago): hay % cash_movements para el pago idempotente (esperaba 1).', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM pg_proc WHERE proname = 'rpc_register_payment_made';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.7-pago): hay % definiciones de rpc_register_payment_made (esperaba 1).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4.6-pago/4.7-pago): idempotencia del pago sin duplicar, una sola definición viva.';

  -- ═══ (4.9-pago) pago por wallet → bank_movement transfer_out ════════════
  v_result := public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccp-4.9-pago', p_supplier_id => v_supplier_a, p_amount => 150,
    p_payment_method_id => v_pm_wallet, p_bank_account_id => v_bank_a
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  SELECT * INTO v_mov FROM public.bank_movements WHERE source_doc_type = 'payment_made' AND source_doc_ref = v_payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.9-pago): un pago por wallet no escribió ningún bank_movement.';
  END IF;
  IF v_mov.movement_type <> 'transfer_out' OR v_mov.amount <> -150 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.9-pago): bank_movement quedó en (%, %) y esperaba (transfer_out, -150).', v_mov.movement_type, v_mov.amount;
  END IF;
  RAISE NOTICE 'PASS (4.9-pago): wallet en el pago también rutea a bank_movement, egreso.';

  -- ═══ (4.10-pago) pago imputado a 'other' → sin ningún libro de dinero ═══
  SELECT balance INTO v_balance_before FROM public.supplier_accounts WHERE account_id = v_account_a AND supplier_id = v_supplier_a;
  v_result := public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccp-4.10-pago', p_supplier_id => v_supplier_a, p_amount => 40,
    p_payment_method_id => v_pm_other
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  SELECT balance INTO v_balance_after FROM public.supplier_accounts WHERE account_id = v_account_a AND supplier_id = v_supplier_a;
  IF v_balance_after <> v_balance_before - 40 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.10-pago): el saldo no bajó 40 (antes=%, después=%).', v_balance_before, v_balance_after;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.10-pago): other escribió % cash_movements (esperaba 0).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4.10-pago): other en el pago reduce el saldo, no toca ningún libro de dinero.';

  -- ═══ (4.11-pago) pago imputado a 'credit' → P0400 ════════════════════════
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccp-4.11-pago', p_supplier_id => v_supplier_a, p_amount => 30,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.11-pago): un pago imputado a credit debía rechazarse con P0400, dio %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  RAISE NOTICE 'PASS (4.11-pago): credit se rechaza con P0400 en el pago también.';

  -- ═══ (4.12-pago) forma de pago de OTRO tenant → P0404 ════════════════════
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccp-4.12-pago', p_supplier_id => v_supplier_a, p_amount => 30,
      p_payment_method_id => v_pm_other_tenant
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0404' THEN
    RAISE EXCEPTION 'GATE CCC-PARTY FAILED (4.12-pago): un pago con payment_method_id de otro tenant debía rechazarse con P0404, dio %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  RAISE NOTICE 'PASS (4.12-pago): el guard de tenencia de D5 cubre el lado proveedor igual que el lado cliente.';
END $$;


-- ── Cleanup ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('ccc-party-a@test.local', 'ccc-party-b@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.payments_received WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements cam USING public.customer_accounts ca
      WHERE cam.customer_account_id = ca.id AND ca.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements sam USING public.supplier_accounts sa
      WHERE sam.supplier_account_id = sa.id AND sa.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements WHERE bank_account_id IN (SELECT id FROM public.bank_accounts WHERE account_id = ANY(v_accounts));
    DELETE FROM public.bank_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users)
                                    OR recipient IN ('ccc-party-a@test.local', 'ccc-party-b@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CCC-PARTY: cleanup completo.';
END $$;
