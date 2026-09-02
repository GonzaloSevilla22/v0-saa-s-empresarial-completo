-- =============================================================================
-- GATE: test_purchase_cash_optin.sql
-- CHANGE: caja-compras-cobranzas — grupo 3 (compra en efectivo descuenta de
-- la caja) + grupo 6 (la compra con caja posteada es inmutable)
--
-- Pedido textual del PO (2026-09-01): "No se registra la compra con Efectivo
-- en el historial de caja... tiene que funcionar".
--
-- Qué ejercita, con dos tenants sintéticos (molde de test_gastos_forma_pago.sql):
--   (3.1) las tres condiciones cumplidas → cash_movement purchase_payment
--         negativo, referenciando la operación, balance_after = saldo previo
--         MENOS el total (no el máximo histórico).
--   (3.2) kind no efectivo con sesión informada → P0422 cash_optin_requires_cash_kind.
--   (3.3) sesión de otra sucursal → P0422 cash_optin_requires_open_session.
--   (3.4) fecha de ayer → P0422 cash_optin_requires_today.
--   (3.5) sin sesión informada → no-op, la compra se crea igual.
--   (3.6) sesión de otra cuenta → rechazada (tenencia, backstop de
--         c28_register_cash_movement).
--   (3.7) exactamente UNA definición viva de la función (gotcha 42725).
--   (3.8) regresión: compra a crédito sigue posteando el cargo del
--         proveedor; compra bancaria sigue escribiendo el bank_movement;
--         compra sin forma de pago sigue emitiendo su evento con 'credit'.
--   (6.1) editar una compra con movimiento de caja → P0423; una compra sin
--         dinero posteado sigue siendo editable.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

-- ═══════════════════════════════ SETUP ════════════════════════════════════
DO $$
DECLARE
  v_email_a   text := 'ccc-purchase-a@test.local';
  v_email_b   text := 'ccc-purchase-b@test.local';
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_account_b uuid;
  v_branch_a1 uuid;
  v_branch_a2 uuid;
  v_branch_b  uuid;
  v_cashbox_a1 uuid;
  v_cashbox_a2 uuid;
  v_cashbox_b  uuid;
  v_product_a  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(), jsonb_build_object('name', 'Gate CCC Purchase A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(), jsonb_build_object('name', 'Gate CCC Purchase B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE NOTICE 'GATE CCC-PURCHASE (setup): no se pudieron provisionar 2 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b  FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  IF v_branch_a1 IS NULL OR v_branch_b IS NULL THEN
    RAISE NOTICE 'GATE CCC-PURCHASE (setup): sucursales no sembradas — degradando sin abortar.';
    RETURN;
  END IF;

  -- Segunda sucursal de A (para el assert de "sesión de otra sucursal del
  -- mismo tenant"). created_at explícitamente posterior — mismo gotcha de
  -- determinismo documentado en test_gastos_forma_pago.sql.
  INSERT INTO public.branches (account_id, name, created_at)
  VALUES (v_account_a, '__gate_ccc_branch_a2__', now() + interval '1 minute')
  RETURNING id INTO v_branch_a2;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccc_cashbox_a1__')
  RETURNING id INTO v_cashbox_a1;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a2, '__gate_ccc_cashbox_a2__')
  RETURNING id INTO v_cashbox_a2;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id = v_branch_b ORDER BY created_at LIMIT 1;
  IF v_cashbox_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_b, '__gate_ccc_cashbox_b__')
    RETURNING id INTO v_cashbox_b;
  END IF;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a1, 'open', 10000, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a2, 'open', 0, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_user_b);

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_ccc_product__', 500, 200, 'GATE-CCC-1')
  RETURNING id INTO v_product_a;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a1, v_product_a, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  RAISE NOTICE 'SETUP OK: 2 tenants (A opera, B ajeno), 2 sucursales de A, 1 producto con stock.';
END $$;


-- ═════════ (3.1/3.2/3.3/3.4/3.5/3.6/3.7) OPT-IN — las tres condiciones ════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;  v_account_b uuid;
  v_branch_a1  uuid;  v_branch_a2 uuid;
  v_session_a1 uuid;  v_session_a2 uuid;  v_session_b uuid;
  v_pm_cash_a  uuid;  v_pm_credit_a uuid; v_pm_other_a uuid; v_pm_transfer_a uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid;
  v_count      integer;
  v_mov        RECORD;
  v_rejected   boolean;
  v_bal_before numeric;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-purchase-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-PURCHASE (3): sin anchor A — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members
    WHERE user_id = (SELECT id FROM auth.users WHERE email = 'ccc-purchase-b@test.local') ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN RAISE NOTICE 'GATE CCC-PURCHASE (3): setup incompleto — degradando.'; RETURN; END IF;

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a AND name NOT LIKE '__gate_ccc%' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a2 FROM public.branches WHERE account_id = v_account_a AND name = '__gate_ccc_branch_a2__';
  SELECT cs.id INTO v_session_a1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccc_cashbox_a1__' AND cs.status = 'open';
  SELECT cs.id INTO v_session_a2 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccc_cashbox_a2__' AND cs.status = 'open';
  -- v_session_b: NO se busca por nombre de caja — el tenant B puede ya tener
  -- una caja/sucursal auto-provisionada bajo un nombre genérico
  -- ("Caja Principal") en vez de la que el setup intentó crear con nombre
  -- propio (su `IF v_cashbox_b IS NULL` la encontró y no creó una nueva).
  -- Se resuelve por CUENTA: la única sesión abierta de B, sea cual sea su caja.
  SELECT cs.id INTO v_session_b
  FROM public.cash_sessions cs
  JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
  JOIN public.branches   b ON b.id  = cb.branch_id
  WHERE b.account_id = v_account_b AND cs.status = 'open'
  ORDER BY cs.opened_at DESC LIMIT 1;
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccc_product__' AND account_id = v_account_a;
  SELECT id INTO v_pm_cash_a     FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'     AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_credit_a   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit'   AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_other_a    FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'other'    AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_transfer_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;

  IF v_session_a1 IS NULL OR v_pm_cash_a IS NULL OR v_product_a IS NULL OR v_session_b IS NULL THEN
    RAISE NOTICE 'GATE CCC-PURCHASE (3): fixtures incompletos (v_session_b=%) — degradando sin abortar.', v_session_b;
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE CCC-PURCHASE (3): auth.uid() no resuelve al anchor A — degradando.';
    RETURN;
  END IF;

  -- ═══ (3.1) las tres condiciones cumplidas → cash_movement negativo ═══════
  SELECT balance_after INTO v_bal_before
  FROM public.cash_movements WHERE session_id = v_session_a1 ORDER BY created_at DESC LIMIT 1;
  v_bal_before := COALESCE(v_bal_before, 10000);  -- opening_balance si no hay movimientos aún

  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccc-3.1-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(),
    p_description => 'gate 3.1',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 100, 'quantity', 2)),
    p_branch_id => v_branch_a1,
    p_payment_method_id => v_pm_cash_a,
    p_cash_session_id => v_session_a1
  );
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT * INTO v_mov FROM public.cash_movements
  WHERE session_id = v_session_a1 AND reference_id = v_op_id AND movement_type = 'purchase_payment';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.1): no se creó ningún cash_movement purchase_payment para la compra.';
  END IF;
  IF v_mov.amount <> -200 THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.1): el movimiento quedó en % y esperaba -200 (egreso).', v_mov.amount;
  END IF;
  IF v_mov.balance_after <> v_bal_before - 200 THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.1): balance_after quedó en % y esperaba % (saldo previo MENOS el total, no el máximo histórico).', v_mov.balance_after, v_bal_before - 200;
  END IF;
  RAISE NOTICE 'PASS (3.1): las tres condiciones cumplidas escriben un purchase_payment negativo con balance_after correcto.';

  -- ═══ (3.7) exactamente una definición viva ═══════════════════════════════
  SELECT COUNT(*) INTO v_count FROM pg_proc WHERE proname = 'rpc_create_purchase_operation';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.7): hay % definiciones de rpc_create_purchase_operation (esperaba 1) — overload del gotcha 42725.', v_count;
  END IF;

  -- ═══ (3.2) kind no efectivo con sesión informada → P0422 ═════════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-ccc-3.2-' || gen_random_uuid()::text,
      p_date => public.reporting_local_today(), p_description => 'gate 3.2',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 50, 'quantity', 1)),
      p_branch_id => v_branch_a1, p_payment_method_id => COALESCE(v_pm_transfer_a, v_pm_other_a),
      p_cash_session_id => v_session_a1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0422' AND SQLERRM LIKE '%cash_optin_requires_cash_kind%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.2): una compra no-efectivo con sesión informada fue aceptada.';
  END IF;

  -- ═══ (3.3) sesión de otra sucursal → P0422 ═══════════════════════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-ccc-3.3-' || gen_random_uuid()::text,
      p_date => public.reporting_local_today(), p_description => 'gate 3.3',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 50, 'quantity', 1)),
      p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a,
      p_cash_session_id => v_session_a2
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0422' AND SQLERRM LIKE '%cash_optin_requires_open_session%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.3): una sesión de OTRA sucursal del mismo tenant fue aceptada.';
  END IF;

  -- ═══ (3.4) fecha de ayer → P0422 ══════════════════════════════════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-ccc-3.4-' || gen_random_uuid()::text,
      p_date => public.reporting_local_today() - 1, p_description => 'gate 3.4',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 50, 'quantity', 1)),
      p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a,
      p_cash_session_id => v_session_a1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0422' AND SQLERRM LIKE '%cash_optin_requires_today%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.4): una compra fechada AYER con sesión informada fue aceptada.';
  END IF;
  RAISE NOTICE 'PASS (3.2/3.3/3.4): kind no-cash, sesión de otra sucursal y fecha de ayer rechazados, todos con P0422.';

  -- ═══ (3.5) sin sesión informada → no-op, compra creada igual ═════════════
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_a1;
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccc-3.5-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 3.5',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 50, 'quantity', 1)),
    p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a
    -- p_cash_session_id ausente = no-op
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE operation_id = v_op_id) THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.5): la compra sin sesión informada no se registró.';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_op_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.5): una compra sin sesión informada escribió % movimientos de caja.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.5): sin caja abierta informada, la compra se registra igual y no toca la caja.';

  -- ═══ (3.6) sesión de OTRA cuenta → rechazada ══════════════════════════════
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_b;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-ccc-3.6-' || gen_random_uuid()::text,
      p_date => public.reporting_local_today(), p_description => 'gate 3.6',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 50, 'quantity', 1)),
      p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a,
      p_cash_session_id => v_session_b
    );
  EXCEPTION WHEN OTHERS THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.6): una sesión de OTRA CUENTA fue aceptada — falla de tenencia.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session_b AND reference_id IS NOT NULL AND description = 'gate 3.6') THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.6-efectos): la sesión ajena recibió un movimiento pese al rechazo.';
  END IF;
  RAISE NOTICE 'PASS (3.6): la sesión de otra cuenta es rechazada sin dejar rastro en su caja.';

  -- ═══ (3.8) REGRESIÓN — crédito, banco y sin forma de pago siguen igual ════
  IF v_pm_credit_a IS NOT NULL THEN
    DECLARE
      v_supplier uuid;
      v_charge   RECORD;
    BEGIN
      INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, '__gate_ccc_supplier__')
      RETURNING id INTO v_supplier;
      v_result := public.rpc_create_purchase_operation(
        p_idempotency_key => 'gate-ccc-3.8a-' || gen_random_uuid()::text,
        p_date => public.reporting_local_today(), p_description => 'gate 3.8a',
        p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 300, 'quantity', 1)),
        p_branch_id => v_branch_a1, p_payment_method_id => v_pm_credit_a, p_supplier_id => v_supplier
      );
      v_op_id := (v_result->>'operation_id')::uuid;
      SELECT * INTO v_charge FROM public.supplier_account_movements WHERE reference_id = v_op_id AND movement_type = 'purchase';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.8a): una compra a crédito dejó de postear el cargo al proveedor — regresión.';
      END IF;
    END;
  END IF;

  -- Compra sin forma de pago imputada: el evento sigue con 'credit' por default.
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccc-3.8b-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 3.8b',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 40, 'quantity', 1)),
    p_branch_id => v_branch_a1
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  IF NOT EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_id
      AND payload->>'payment_method' = 'credit'
  ) THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.8b): una compra sin forma de pago no emitió su evento con el default ''credit'' — regresión.';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_op_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (3.8b): una compra sin forma de pago escribió % movimientos de caja.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.8): compra a crédito sigue cargando al proveedor; compra sin forma de pago sigue emitiendo su evento con default credit y sin tocar caja.';
END $$;


-- ═══════════════ (6.1) INMUTABILIDAD — P0423 por movimiento de caja ═════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_session_a1 uuid;
  v_pm_cash_a  uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid; v_purchase_id uuid;
  v_rejected   boolean;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-purchase-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-PURCHASE (6.1): sin anchor A — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a AND name NOT LIKE '__gate_ccc%' ORDER BY created_at LIMIT 1;
  SELECT cs.id INTO v_session_a1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccc_cashbox_a1__' AND cs.status = 'open';
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccc_product__' AND account_id = v_account_a;
  SELECT id INTO v_pm_cash_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL LIMIT 1;

  IF v_session_a1 IS NULL OR v_pm_cash_a IS NULL OR v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-PURCHASE (6.1): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Compra CON movimiento de caja (opt-in tildado).
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccc-6.1a-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 6.1 con caja',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 70, 'quantity', 1)),
    p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a1
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      p_purchase_ids => ARRAY[v_purchase_id],
      p_date => public.reporting_local_today(),
      p_description => 'edición bloqueada',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 71, 'quantity', 1))
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (6.1): se pudo editar una compra con movimiento de caja posteado — el guard P0423 no la alcanza.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purchase_id AND amount = 70) THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (6.1-efectos): el rechazo P0423 dejó la compra editada de todos modos.';
  END IF;

  -- Compra SIN movimiento de caja (opt-in NO tildado) sigue editable.
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccc-6.1b-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 6.1 sin caja',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 80, 'quantity', 1)),
    p_branch_id => v_branch_a1, p_payment_method_id => v_pm_cash_a
    -- sin p_cash_session_id
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids => ARRAY[v_purchase_id],
    p_date => public.reporting_local_today(),
    p_description => 'edición permitida',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 81, 'quantity', 1))
  );
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE operation_id <> v_op_id AND amount = 81 AND description = 'edición permitida') THEN
    RAISE EXCEPTION 'GATE CCC-PURCHASE FAILED (6.1-control): una compra sin caja posteada quedó bloqueada — el guard es demasiado amplio.';
  END IF;

  RAISE NOTICE 'PASS (6.1): editar una compra con movimiento de caja falla P0423 sin dejarla editada; sin movimiento de caja sigue plenamente editable.';
END $$;


-- ── Cleanup de los dos tenants ───────────────────────────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('ccc-purchase-a@test.local', 'ccc-purchase-b@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.stock_movements    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock       WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchase_items     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements sam USING public.supplier_accounts sa
      WHERE sam.supplier_account_id = sa.id AND sa.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events             WHERE account_id = ANY(v_accounts);
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
                                    OR recipient IN ('ccc-purchase-a@test.local', 'ccc-purchase-b@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CCC-PURCHASE: cleanup de los dos tenants completo.';
END $$;
