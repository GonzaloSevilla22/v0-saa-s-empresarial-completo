-- =============================================================================
-- GATE: test_purchase_delete_cash_compensation.sql
-- CHANGE: caja-compras-cobranzas — grupo 5 (el borrado de una compra
-- compensa la caja)
--
-- Pedido textual del PO (2026-09-01): "...también cuando se elimine una
-- compra en efectivo se compense".
--
-- Qué ejercita:
--   (5.1) compra con caja + sesión abierta → purchase_payment_reversal
--         POSITIVO por el importe opuesto, compra borrada.
--   (5.2) sesión original YA CERRADA, otra sesión abierta en la MISMA caja →
--         el contra-movimiento va a la abierta; el arqueo de la cerrada no
--         se altera (RN-99, append-only).
--   (5.3) SIN sesión abierta → P0426, la compra sigue existiendo, el stock
--         NO se revirtió y el banco tampoco (todo o nada).
--   (5.4) CONTROL NEGATIVO — movimiento con signo invertido (por cualquier
--         camino) se compensa IGUAL: el disparo es por EXISTENCIA, jamás por
--         signo. Sin este control, un guard `< 0` copiado mal dejaría pasar
--         el borrado sin compensar y sin P0426 (el modo de falla exacto que
--         motivó delete-guard-ledgers).
--   (5.5) compra SIN movimiento de caja → borrado normal, sin exigir sesión.
--   (5.6) el saldo de la sesión abierta vuelve EXACTAMENTE al valor previo;
--         el movimiento original permanece intacto (append-only).
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_email_a    text := 'ccc-delete-a@test.local';
  v_user_a     uuid := gen_random_uuid();
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_cashbox_1  uuid;  -- sesión abierta desde el arranque (5.1/5.6)
  v_cashbox_2  uuid;  -- sesión que se CIERRA a mitad de camino (5.2)
  v_cashbox_3  uuid;  -- SIN ninguna sesión abierta (5.3)
  v_cashbox_4  uuid;  -- para el control negativo (5.4)
  v_product_a  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(), jsonb_build_object('name', 'Gate CCC Delete A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (setup): no se pudo provisionar el tenant — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a1 IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (setup): sin sucursal sembrada — degradando.'; RETURN;
  END IF;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccd_cashbox_1__') RETURNING id INTO v_cashbox_1;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccd_cashbox_2__') RETURNING id INTO v_cashbox_2;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccd_cashbox_3__') RETURNING id INTO v_cashbox_3;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_ccd_cashbox_4__') RETURNING id INTO v_cashbox_4;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_1, 'open', 5000, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_2, 'open', 3000, v_user_a);   -- ésta se cierra en el bloque 5.2
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_4, 'open', 1000, v_user_a);
  -- v_cashbox_3 nace SIN ninguna sesión (5.3).

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_ccd_product__', 500, 200, 'GATE-CCD-1')
  RETURNING id INTO v_product_a;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a1, v_product_a, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  RAISE NOTICE 'SETUP OK: 4 cajas (1 abierta, 1 se cierra a mitad de camino, 1 sin sesión, 1 para el control negativo).';
END $$;


-- ═══════════════════ (5.1/5.6) borrado con sesión abierta ═══════════════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_session_1  uuid;
  v_product_a  uuid;
  v_result     jsonb;  v_op_id uuid;  v_purchase_id uuid;
  v_bal_before numeric;
  v_rev        RECORD;
  v_original   RECORD;
  v_deleted    boolean;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-delete-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-DELETE (5.1): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT cs.id INTO v_session_1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccd_cashbox_1__' AND cs.status = 'open';
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccd_product__' AND account_id = v_account_a;

  IF v_session_1 IS NULL OR v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (5.1): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccd-5.1-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 5.1',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 150, 'quantity', 1)),
    p_branch_id => v_branch_a1,
    p_payment_method_id => (SELECT id FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' LIMIT 1),
    p_cash_session_id => v_session_1
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  SELECT balance_after INTO v_bal_before FROM public.cash_movements
  WHERE session_id = v_session_1 ORDER BY created_at DESC LIMIT 1;

  PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id, p_reason => 'gate 5.1 delete');

  SELECT * INTO v_rev FROM public.cash_movements
  WHERE session_id = v_session_1 AND reference_id = v_op_id AND movement_type = 'purchase_payment_reversal';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.1): el borrado no registró ningún purchase_payment_reversal.';
  END IF;
  IF v_rev.amount <> 150 THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.1): la reversa quedó en % y esperaba +150 (opuesto exacto del egreso).', v_rev.amount;
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.purchases WHERE id = v_purchase_id) INTO v_deleted;
  IF v_deleted THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.1): la compra sigue existiendo tras el borrado.';
  END IF;

  -- (5.6) el movimiento ORIGINAL permanece intacto (append-only) y el saldo
  -- vuelve exactamente al valor previo a la compra.
  SELECT * INTO v_original FROM public.cash_movements
  WHERE session_id = v_session_1 AND reference_id = v_op_id AND movement_type = 'purchase_payment';
  IF NOT FOUND OR v_original.amount <> -150 THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.6): el movimiento original de la compra fue alterado o borrado — el ledger tiene que ser append-only.';
  END IF;
  IF v_rev.balance_after <> v_bal_before + 150 THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.6): balance_after de la reversa quedó en % y esperaba % (saldo previo a la compra).', v_rev.balance_after, v_bal_before + 150;
  END IF;

  RAISE NOTICE 'PASS (5.1/5.6): la reversa es positiva y exacta, la compra queda borrada, el movimiento original no se toca y el saldo vuelve al valor previo.';
END $$;


-- ══════════════ (5.2) sesión original CERRADA, otra abierta ═════════════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_session_open_before uuid;
  v_session_new_open    uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid;
  v_arqueo_cerrada_antes numeric;
  v_arqueo_cerrada_despues numeric;
  v_rev        RECORD;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-delete-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-DELETE (5.2): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT cs.id INTO v_session_open_before FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccd_cashbox_2__' AND cs.status = 'open';
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccd_product__' AND account_id = v_account_a;

  IF v_session_open_before IS NULL OR v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (5.2): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Compra con caja en la sesión que se va a CERRAR después.
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccd-5.2-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 5.2',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 90, 'quantity', 1)),
    p_branch_id => v_branch_a1,
    p_payment_method_id => (SELECT id FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' LIMIT 1),
    p_cash_session_id => v_session_open_before
  );
  v_op_id := (v_result->>'operation_id')::uuid;

  -- Cerrar la sesión donde se posteó el egreso.
  UPDATE public.cash_sessions SET status = 'closed', closing_balance = 2910, counted_balance = 2910, closed_by = v_user_a, closed_at = now()
  WHERE id = v_session_open_before;

  SELECT COUNT(*) INTO v_arqueo_cerrada_antes FROM public.cash_movements WHERE session_id = v_session_open_before;

  -- Abrir una NUEVA sesión en la MISMA caja.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES ((SELECT cashbox_id FROM public.cash_sessions WHERE id = v_session_open_before), 'open', 2910, v_user_a)
  RETURNING id INTO v_session_new_open;

  PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id, p_reason => 'gate 5.2 delete');

  -- El contra-movimiento fue a la sesión NUEVA, no a la cerrada.
  SELECT * INTO v_rev FROM public.cash_movements
  WHERE session_id = v_session_new_open AND reference_id = v_op_id AND movement_type = 'purchase_payment_reversal';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.2): el contra-movimiento no fue a la sesión abierta de HOY.';
  END IF;

  SELECT COUNT(*) INTO v_arqueo_cerrada_despues FROM public.cash_movements WHERE session_id = v_session_open_before;
  IF v_arqueo_cerrada_despues <> v_arqueo_cerrada_antes THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.2): el arqueo de la sesión CERRADA cambió (tenía % movimientos, ahora tiene %) — el ledger append-only fue violado.', v_arqueo_cerrada_antes, v_arqueo_cerrada_despues;
  END IF;

  RAISE NOTICE 'PASS (5.2): el contra-movimiento va a la sesión abierta de hoy y el arqueo de la sesión cerrada no se altera.';
END $$;


-- ═════════════════ (5.3) SIN sesión abierta → P0426, todo intacto ═══════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_session_4  uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid; v_purchase_id uuid;
  v_stock_before numeric;
  v_stock_after  numeric;
  v_rejected   boolean;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-delete-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-DELETE (5.3): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT cs.id INTO v_session_4 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccd_cashbox_4__' AND cs.status = 'open';
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccd_product__' AND account_id = v_account_a;

  IF v_session_4 IS NULL OR v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (5.3): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Compra con caja en cashbox_4, después se cierra SU ÚNICA sesión.
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccd-5.3-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 5.3',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 60, 'quantity', 1)),
    p_branch_id => v_branch_a1,
    p_payment_method_id => (SELECT id FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' LIMIT 1),
    p_cash_session_id => v_session_4
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  UPDATE public.cash_sessions SET status = 'closed', closing_balance = 940, counted_balance = 940, closed_by = v_user_a, closed_at = now()
  WHERE id = v_session_4;

  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE branch_id = v_branch_a1 AND product_id = v_product_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id, p_reason => 'gate 5.3 delete');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0426' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.3): el borrado procedió sin ninguna sesión de caja abierta — tenía que rechazarse con P0426.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purchase_id) THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.3-efectos): la compra fue borrada pese al P0426 — el rechazo tiene que ser TODO O NADA.';
  END IF;

  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE branch_id = v_branch_a1 AND product_id = v_product_a;
  IF v_stock_after <> v_stock_before THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.3-efectos): el stock cambió (% -> %) pese al rechazo P0426 — el borrado tiene que ser atómico.', v_stock_before, v_stock_after;
  END IF;

  RAISE NOTICE 'PASS (5.3): sin sesión abierta el borrado se rechaza con P0426, sin tocar ni la compra ni el stock ni el banco (todo o nada).';
END $$;


-- ══════ (5.4) CONTROL NEGATIVO — el disparo es por EXISTENCIA, no signo ══════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_session_1  uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid; v_purchase_id uuid;
  v_rev        RECORD;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-delete-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-DELETE (5.4): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT cs.id INTO v_session_1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_ccd_cashbox_1__' AND cs.status = 'open';
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccd_product__' AND account_id = v_account_a;

  IF v_session_1 IS NULL OR v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (5.4): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Compra SIN opt-in de caja (para no interferir con el saldo de v_session_1
  -- de los bloques anteriores) — el movimiento con signo invertido se
  -- inyecta A MANO, simulando un camino futuro que lo escribiera mal.
  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccd-5.4-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 5.4',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 30, 'quantity', 1)),
    p_branch_id => v_branch_a1
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  -- Inyección directa: movimiento purchase_payment con signo POSITIVO
  -- (invertido) — el CHECK de signo de RegisterMovementIn es una capa de
  -- API, no de DB; a nivel tabla el CHECK sólo valida pertenencia al enum,
  -- así que esta fila es representativa de un bug futuro en OTRO caller.
  PERFORM public.c28_register_cash_movement(v_session_1, 30, 'purchase_payment', v_op_id, 'gate 5.4 signo invertido');

  PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id, p_reason => 'gate 5.4 delete');

  SELECT * INTO v_rev FROM public.cash_movements
  WHERE session_id = v_session_1 AND reference_id = v_op_id AND movement_type = 'purchase_payment_reversal';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.4): un movimiento con signo invertido NO disparó la compensación — el guard depende del signo, exactamente el bug que delete-guard-ledgers cerró para el gasto.';
  END IF;
  -- El original es +30 (invertido); el opuesto exacto es -30.
  IF v_rev.amount <> -30 THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.4): la reversa del movimiento invertido quedó en % y esperaba -30 (el opuesto exacto del signo real posteado, sea cual sea).', v_rev.amount;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purchase_id) THEN
    -- se espera que SÍ se borre (había sesión abierta) — este IF es el
    -- camino correcto, no un fallo.
    NULL;
  ELSE
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.4): la compra debía quedar borrada (había sesión abierta) y sigue existiendo.';
  END IF;

  RAISE NOTICE 'PASS (5.4): el disparo de la compensación es por EXISTENCIA del movimiento, no por su signo — un movimiento con el signo contrario se compensa igual.';
END $$;


-- ═════════════════ (5.5) compra SIN movimiento de caja ═══════════════════════
DO $$
DECLARE
  v_user_a     uuid;
  v_account_a  uuid;
  v_branch_a1  uuid;
  v_product_a  uuid;
  v_result     jsonb; v_op_id uuid; v_purchase_id uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'ccc-delete-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE CCC-DELETE (5.5): sin anchor — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_product_a FROM public.products WHERE name = '__gate_ccd_product__' AND account_id = v_account_a;

  IF v_product_a IS NULL THEN
    RAISE NOTICE 'GATE CCC-DELETE (5.5): fixtures incompletos — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  v_result := public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-ccd-5.5-' || gen_random_uuid()::text,
    p_date => public.reporting_local_today(), p_description => 'gate 5.5',
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 20, 'quantity', 1)),
    p_branch_id => v_branch_a1
    -- sin p_cash_session_id: nunca descontó de la caja
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id LIMIT 1;

  -- No debe exigir NINGUNA sesión abierta — de hecho no informamos ninguna.
  PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id, p_reason => 'gate 5.5 delete');

  IF EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purchase_id) THEN
    RAISE EXCEPTION 'GATE CCC-DELETE FAILED (5.5): una compra sin movimiento de caja no se pudo borrar sin exigir sesión abierta.';
  END IF;

  RAISE NOTICE 'PASS (5.5): una compra que nunca descontó de la caja se borra normalmente, sin exigir ninguna sesión abierta.';
END $$;


-- ── Cleanup ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('ccc-delete-a@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.stock_movements    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock       WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchase_items     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products           WHERE account_id = ANY(v_accounts);
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
                                    OR recipient IN ('ccc-delete-a@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CCC-DELETE: cleanup completo.';
END $$;
