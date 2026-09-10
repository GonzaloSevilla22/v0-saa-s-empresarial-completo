-- =============================================================================
-- GATE: test_asiento_contable_gastos.sql
-- CHANGE: asiento-contable-gastos — grupos 3, 4, 5 y 6 (el asiento del gasto)
--
-- Pedido: cerrar D10 de gastos-forma-pago ("este change deja lista la forma
-- de pago, que es el dato que le falta al asiento futuro para elegir la
-- contrapartida") — el gasto pasa a producir su asiento de partida doble por
-- el mismo outbox que ya sirve a la venta, la compra y los cobros.
--
-- Qué ejercita, con dos tenants sintéticos y sesión vía request.jwt.claims
-- (mismo molde que test_gastos_forma_pago.sql / test_cobranzas_reverso.sql):
--
--   (A) _journal_expense_credit_account — mapeo puro, SIN ningún gasto,
--       evento ni asiento existente (D4).
--   (B) Alta en efectivo → ExpenseCreated → relay → asiento 5300/1100, balancea.
--   (C) Los 4 kind bancarios acreditan 1110; sin forma de pago acredita 1100
--       y NO 2100 (OQ-1).
--   (D) CONTROL NEGATIVO OQ-2: cash SIN opt-in de caja → acredita 1100 igual.
--   (E) Fecha (D5): el asiento cae en el día del gasto, no en el del relay.
--   (F) Edición (D6): gasto sin movimientos de dinero, con asiento posteado →
--       edición procede, ExpenseAdjusted → contra-asiento + asiento nuevo.
--   (F-bis) Corrección de findings (revisor ronda 1, blocker): SEGUNDA
--       edición del mismo gasto → exactamente un asiento vigente y el 5300
--       neto refleja la ÚLTIMA edición, sin duplicar/triplicar.
--   (F2) Corrección de findings (revisor ronda 1, blocker): alta→edición→
--       borrado → cero asientos vigentes y el 5300 neto TOTAL en 0 (sin
--       plata fantasma tras borrar un gasto ya editado).
--   (F3) Corrección de findings (revisor ronda 1, major): editar la forma de
--       pago a un kind bancario NO acredita 1110 sin bank_movement real —
--       la edición nunca mueve banco (D6).
--   (G) Borrado: ExpenseDeleted → contra-asiento con la fila del gasto YA
--       borrada (borrado físico).
--   (H) D7 — el caso que evita el evento envenenado: gasto histórico no
--       emite nada; gasto creado-y-borrado antes del relay SÍ emite.
--   (I) Idempotencia (D13) y P0451 (ajuste/borrado sin asiento original).
--   (J) Tenencia — account_id correcto, sin cruce de cuentas, ACL del helper.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
--
-- Cleanup: DO block separado al final que resuelve los ids por email.
-- =============================================================================


-- ═══════════════════ (A) _journal_expense_credit_account ═══════════════════
-- Sin ningún gasto, evento ni asiento existente — es la prueba de que el
-- mapeo es una función invocable de forma aislada, y no un CASE embebido.
DO $$
DECLARE
  v_bank_kinds text[] := ARRAY['transfer', 'card', 'check', 'wallet'];
  v_cash_kinds text[] := ARRAY['cash', 'other'];
  v_kind       text;
  v_result     text;
BEGIN
  FOREACH v_kind IN ARRAY v_bank_kinds LOOP
    v_result := public._journal_expense_credit_account(v_kind);
    IF v_result <> '1110' THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (A): _journal_expense_credit_account(%) devolvió % y esperaba 1110.', v_kind, v_result;
    END IF;
  END LOOP;

  FOREACH v_kind IN ARRAY v_cash_kinds LOOP
    v_result := public._journal_expense_credit_account(v_kind);
    IF v_result <> '1100' THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (A): _journal_expense_credit_account(%) devolvió % y esperaba 1100.', v_kind, v_result;
    END IF;
  END LOOP;

  v_result := public._journal_expense_credit_account(NULL);
  IF v_result <> '1100' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (A): _journal_expense_credit_account(NULL) devolvió % y esperaba 1100 (sin imputar → caja, OQ-1).', v_result;
  END IF;

  RAISE NOTICE 'PASS (A): _journal_expense_credit_account mapea 1110 para transfer/card/check/wallet y 1100 para cash/other/NULL, invocable en aislamiento.';
END $$;


-- ═══════════════════════════ SETUP — 2 tenants ═══════════════════════════════
DO $$
DECLARE
  v_email_a    text := 'asiento-gastos-a@test.local';
  v_email_b    text := 'asiento-gastos-b@test.local';
  v_user_a     uuid := gen_random_uuid();
  v_user_b     uuid := gen_random_uuid();
  v_account_a  uuid;
  v_account_b  uuid;
  v_branch_a   uuid;
  v_cashbox_a  uuid;
  v_ba_a       uuid;
  v_cc_a       uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Asiento Gastos A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Asiento Gastos B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE NOTICE 'GATE ASIENTO-GASTOS (setup): no se pudieron provisionar 2 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a IS NULL THEN
    RAISE NOTICE 'GATE ASIENTO-GASTOS (setup): sucursal no sembrada — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a, '__gate_ag_cashbox_a__')
  RETURNING id INTO v_cashbox_a;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a, 'open', 10000, v_user_a);

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_ag_bank_a__', 'ARS', 100000) RETURNING id INTO v_ba_a;

  INSERT INTO public.payment_methods (account_id, name, kind, is_active, bank_account_id)
  VALUES
    (v_account_a, '__gate_ag_pm_cash__', 'cash', TRUE, NULL),
    (v_account_a, '__gate_ag_pm_transfer__', 'transfer', TRUE, v_ba_a),
    (v_account_a, '__gate_ag_pm_card__', 'card', TRUE, v_ba_a),
    (v_account_a, '__gate_ag_pm_check__', 'check', TRUE, v_ba_a),
    (v_account_a, '__gate_ag_pm_wallet__', 'wallet', TRUE, v_ba_a);

  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_a, '__gate_ag_cc_a__', 'AG-A', TRUE) RETURNING id INTO v_cc_a;

  RAISE NOTICE 'SETUP OK: tenant A (con caja+banco+5 formas de pago+centro de costo), tenant B (ajeno).';
END $$;


-- ═════ (B) ALTA EN EFECTIVO → ExpenseCreated → relay → asiento 5300/1100 ═════
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_pm_cash   uuid;  v_cc_a      uuid;
  v_result    jsonb; v_exp_id    uuid;
  v_event_id  uuid;  v_payload   jsonb;
  v_entry     RECORD;
  v_debit     RECORD; v_credit RECORD;
  v_line_count integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (B): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_ag_pm_cash__';
  SELECT id INTO v_cc_a    FROM public.cost_centers    WHERE account_id = v_account_a AND name = '__gate_ag_cc_a__';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE ASIENTO-GASTOS (B): auth.uid() no resuelve al anchor A — degradando.';
    RETURN;
  END IF;

  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 1500, p_date => public.reporting_local_today(),
    p_description => 'gate B cash', p_cost_center_id => v_cc_a, p_payment_method_id => v_pm_cash
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  -- El evento existe ANTES de que el relay corra, y el asiento todavía no.
  SELECT id, payload INTO v_event_id, v_payload
  FROM public.events
  WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = v_exp_id;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): el alta de un gasto en efectivo no emitió ExpenseCreated.';
  END IF;
  IF v_payload->>'kind' <> 'cash' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): la carga del evento llevó kind=% y esperaba cash.', v_payload->>'kind';
  END IF;
  IF (v_payload->>'account_id')::uuid <> v_account_a THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): la carga del evento llevó account_id ajeno.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.journal_entries WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id) THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): el alta ya tiene asiento ANTES de que el relay procese el evento — la escritura contable tiene que ocurrir únicamente en el consumidor.';
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT * INTO v_entry FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): tras el relay no existe asiento posteado para el gasto en efectivo.';
  END IF;

  SELECT COUNT(*) INTO v_line_count FROM public.journal_lines WHERE entry_id = v_entry.id;
  IF v_line_count <> 2 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): el asiento tiene % líneas y esperaba 2 (sin desglose de IVA).', v_line_count;
  END IF;

  SELECT * INTO v_debit  FROM public.journal_lines WHERE entry_id = v_entry.id AND side = 'debit';
  SELECT * INTO v_credit FROM public.journal_lines WHERE entry_id = v_entry.id AND side = 'credit';

  IF v_debit.account_code <> '5300' OR v_debit.amount <> 1500 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): débito=%/% y esperaba 5300/1500.', v_debit.account_code, v_debit.amount;
  END IF;
  IF v_debit.cost_center_id IS DISTINCT FROM v_cc_a THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): la línea de débito no llevó el cost_center_id del gasto.';
  END IF;
  IF v_credit.account_code <> '1100' OR v_credit.amount <> 1500 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): crédito=%/% y esperaba 1100/1500.', v_credit.account_code, v_credit.amount;
  END IF;
  IF v_debit.amount <> v_credit.amount THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (B): el asiento no balancea (débito=% credito=%).', v_debit.amount, v_credit.amount;
  END IF;

  RAISE NOTICE 'PASS (B): gasto en efectivo asentado — 5300/1100 = 1500, con cost_center_id, balancea.';
END $$;


-- ═══ (C) LOS 4 KIND BANCARIOS → 1110; SIN FORMA DE PAGO → 1100 (no 2100) ═════
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_pm        RECORD;
  v_kind_name text;
  v_result    jsonb; v_exp_id uuid;
  v_entry_id  uuid;  v_credit RECORD;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (C): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE ASIENTO-GASTOS (C): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  FOR v_kind_name IN SELECT unnest(ARRAY['transfer','card','check','wallet']) LOOP
    SELECT id INTO v_pm FROM public.payment_methods
    WHERE account_id = v_account_a AND name = '__gate_ag_pm_' || v_kind_name || '__';

    v_result := public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 800, p_date => public.reporting_local_today(),
      p_description => 'gate C ' || v_kind_name, p_payment_method_id => v_pm.id
    );
    v_exp_id := (v_result->>'expense_id')::uuid;
    PERFORM public.rpc_process_outbox_dispatch(100);

    SELECT id INTO v_entry_id FROM public.journal_entries
    WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
    SELECT * INTO v_credit FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'credit';

    IF v_credit.account_code <> '1110' THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (C): gasto kind=% acreditó % y esperaba 1110.', v_kind_name, v_credit.account_code;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (C-bancario): transfer/card/check/wallet acreditan 1110.';

  -- Sin forma de pago imputada.
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 400, p_date => public.reporting_local_today(),
    p_description => 'gate C sin forma de pago'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT id INTO v_entry_id FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
  SELECT * INTO v_credit FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'credit';

  IF v_credit.account_code <> '1100' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (C-sin-fp): gasto sin forma de pago acreditó % y esperaba 1100.', v_credit.account_code;
  END IF;
  IF v_credit.account_code = '2100' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (C-sin-fp): un gasto sin forma de pago NO puede acreditar 2100 Proveedores — no tiene contraparte.';
  END IF;
  RAISE NOTICE 'PASS (C-sin-fp): gasto sin forma de pago acredita 1100, nunca 2100.';
END $$;


-- ═══ (D) CONTROL NEGATIVO OQ-2 — cash SIN opt-in de caja acredita 1100 igual ═
DO $$
DECLARE
  v_user_a   uuid;  v_account_a uuid; v_pm_cash uuid;
  v_result   jsonb; v_exp_id    uuid; v_entry_id uuid;
  v_credit   RECORD; v_cash_count integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (D): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_ag_pm_cash__';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (D): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- Sin p_cash_session_id: NO hay opt-in de caja, así que no se escribe
  -- cash_movement — pero el asiento tiene que acreditar 1100 igual (D4/OQ-2).
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 250, p_date => public.reporting_local_today(),
    p_description => 'gate D sin opt-in', p_payment_method_id => v_pm_cash
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT COUNT(*) INTO v_cash_count FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_cash_count <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (D-setup): el gasto sin p_cash_session_id escribió % movimientos de caja — el fixture no aísla la condición que este bloque controla.', v_cash_count;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT id INTO v_entry_id FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
  SELECT * INTO v_credit FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'credit';

  IF v_credit.account_code <> '1100' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (D): gasto en efectivo SIN opt-in de caja acreditó % y esperaba 1100 igual — la adhesión gobierna el arqueo, no la cuenta contable.', v_credit.account_code;
  END IF;

  RAISE NOTICE 'PASS (D — CONTROL NEGATIVO OQ-2): cash sin sesión de caja abierta acredita 1100 igual.';
END $$;


-- ═══════════════ (E) FECHA (D5) — el asiento cae en el día del gasto ════════
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_past_date date := CURRENT_DATE - 5;
  v_result    jsonb; v_exp_id uuid;
  v_entry     RECORD;
  v_expected  timestamptz;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (E): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (E): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- Gasto fechado 5 días atrás, procesado HOY por el relay: el asiento tiene
  -- que caer en el día DEL GASTO, no en el día del posteo (D5).
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 300, p_date => v_past_date,
    p_description => 'gate E fecha pasada'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT * INTO v_entry FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';

  v_expected := (v_past_date + TIME '12:00:00') AT TIME ZONE 'America/Argentina/Mendoza';

  IF v_entry.posted_at <> v_expected THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (E): posted_at=% y esperaba % (mediodía ART del día del gasto).', v_entry.posted_at, v_expected;
  END IF;
  IF (v_entry.posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date <> v_past_date THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (E): el asiento cae en % (ART) y esperaba el día del gasto %. Corrimiento de día por casteo en la zona equivocada.', (v_entry.posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date, v_past_date;
  END IF;

  RAISE NOTICE 'PASS (E): el asiento cae en el día del gasto (%) en zona ART, no en el día del relay.', v_past_date;
END $$;


-- ═══════════ (F) EDICIÓN (D6) — asiento posteado, edición procede ═══════════
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_result    jsonb; v_exp_id    uuid;
  v_orig_entry RECORD; v_contra_entry RECORD; v_new_entry RECORD;
  v_orig_status text;
  v_debit RECORD; v_credit RECORD;
  v_sum_d numeric; v_sum_c numeric;
  -- (F-bis) revisor ronda 1 (blocker): segunda edición del mismo gasto.
  v_open_count integer;
  v_net_5300   numeric;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- Gasto SIN forma de pago (sin movimientos de dinero) → editable pase lo
  -- que pase con el asiento (D6, dos escenarios normativos de expense-operation).
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 600, p_date => public.reporting_local_today(),
    p_description => 'gate F editable'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT * INTO v_orig_entry FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F-setup): el gasto no quedó con asiento posteado antes de editarlo.';
  END IF;

  -- La edición NO debe rechazarse con P0423: el gasto no tiene movimientos.
  PERFORM public.rpc_update_expense(p_expense_id => v_exp_id, p_amount => 900);

  SELECT COUNT(*) INTO v_sum_d FROM public.events
  WHERE event_type = 'ExpenseAdjusted' AND aggregate_id = v_exp_id;
  IF v_sum_d = 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): la edición no emitió ExpenseAdjusted.';
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_orig_entry.id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): el asiento original quedó % y esperaba reversed.', v_orig_status;
  END IF;

  SELECT * INTO v_contra_entry FROM public.journal_entries WHERE reversal_of = v_orig_entry.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): no existe contra-asiento referenciando al original.';
  END IF;

  SELECT * INTO v_new_entry FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted'
    AND id <> v_orig_entry.id AND id <> v_contra_entry.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): no existe el asiento nuevo con el importe editado.';
  END IF;

  SELECT * INTO v_debit  FROM public.journal_lines WHERE entry_id = v_new_entry.id AND side = 'debit';
  IF v_debit.amount <> 900 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): el asiento nuevo debita % y esperaba 900 (importe editado).', v_debit.amount;
  END IF;

  -- Los tres asientos balancean.
  FOR v_sum_d, v_sum_c IN
    SELECT COALESCE(SUM(amount) FILTER (WHERE side='debit'),0), COALESCE(SUM(amount) FILTER (WHERE side='credit'),0)
    FROM public.journal_lines WHERE entry_id IN (v_orig_entry.id, v_contra_entry.id, v_new_entry.id)
    GROUP BY entry_id
  LOOP
    IF v_sum_d <> v_sum_c THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F): un asiento del trío no balancea (%/%).', v_sum_d, v_sum_c;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS (F): edición sin P0423 — original reversed, contra-asiento y asiento nuevo con el importe editado, los tres balancean.';

  -- ── (F-bis) SEGUNDA edición del MISMO gasto (revisor, ronda 1, blocker) ───
  -- Sin el fix del lookup (AND reversal_of IS NULL), la 2a edición encuentra
  -- DOS filas status='posted' para este source_doc_ref (v_new_entry Y
  -- v_contra_entry) y el LIMIT 1 sin desempate puede elegir la del
  -- contra-asiento — revirtiéndolo en vez de v_new_entry. El síntoma: queda
  -- más de un asiento "vigente" y el 5300 neto duplica/triplica el importe.
  PERFORM public.rpc_update_expense(p_expense_id => v_exp_id, p_amount => 1300);
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT COUNT(*) INTO v_open_count FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id
    AND status = 'posted' AND reversal_of IS NULL;
  IF v_open_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F-bis): tras la 2a edición hay % asiento(s) vigente(s) (posted, reversal_of IS NULL) y esperaba exactamente 1 — la 2a edición revirtió el asiento equivocado.', v_open_count;
  END IF;

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_new_entry.id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F-bis): el asiento de la 1a edición (900) no quedó reversed tras la 2a edición — se revirtió otra fila en su lugar.';
  END IF;

  -- Invariante de negocio, independiente de la implementación del lookup:
  -- sumando TODAS las líneas 5300 de este gasto (cualquier status — cada
  -- contra-asiento cancela EXACTAMENTE lo que targetea, correcto o no), el
  -- neto tiene que ser el importe de la ÚLTIMA edición. Si el lookup revierte
  -- la fila equivocada, alguna entry queda huérfana (sin su contra) y el neto
  -- no da 1300 — es la reproducción exacta del finding del revisor (6000 en
  -- vez de 3000 tras la 3a edición).
  SELECT COALESCE(SUM(CASE WHEN jl.side = 'debit' THEN jl.amount ELSE -jl.amount END), 0)
    INTO v_net_5300
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.entry_id
  WHERE je.source_doc_type = 'Expense' AND je.source_doc_ref = v_exp_id
    AND jl.account_code = '5300';
  IF v_net_5300 <> 1300 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F-bis): el 5300 neto TOTAL del gasto es % y esperaba 1300 (importe de la 2a edición) — duplicación/triplicación por revertir el asiento equivocado.', v_net_5300;
  END IF;

  RAISE NOTICE 'PASS (F-bis): segunda edición del mismo gasto — exactamente un asiento vigente, y el 5300 neto refleja el importe de la ÚLTIMA edición (1300), sin duplicar.';
END $$;


-- ═══ (F2) ALTA → EDICIÓN → BORRADO (revisor, ronda 1, blocker) ══════════════
-- Sin el fix, el borrado de un gasto YA editado revierte el contra-asiento
-- de la edición en vez del asiento vigente: el 5300 neto tras borrar queda
-- en el importe editado — plata fantasma sin ningún documento (el gasto ya
-- no existe) que la respalde, en un ledger append-only.
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_result    jsonb; v_exp_id    uuid;
  v_open_count integer;
  v_net_5300   numeric;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F2): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F2): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 500, p_date => public.reporting_local_today(),
    p_description => 'gate F2 alta-edicion-borrado'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  PERFORM public.rpc_update_expense(p_expense_id => v_exp_id, p_amount => 800);
  PERFORM public.rpc_process_outbox_dispatch(100);

  PERFORM public.rpc_delete_expense(v_exp_id);
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT COUNT(*) INTO v_open_count FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id
    AND status = 'posted' AND reversal_of IS NULL;
  IF v_open_count <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F2): tras borrar un gasto YA EDITADO quedan % asiento(s) "vigente(s)" (posted, reversal_of IS NULL) y esperaba 0 — el borrado revirtió el asiento equivocado.', v_open_count;
  END IF;

  SELECT COALESCE(SUM(CASE WHEN jl.side = 'debit' THEN jl.amount ELSE -jl.amount END), 0)
    INTO v_net_5300
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.entry_id
  WHERE je.source_doc_type = 'Expense' AND je.source_doc_ref = v_exp_id
    AND jl.account_code = '5300';
  IF v_net_5300 <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F2): el 5300 neto TOTAL del gasto (todas las entries, cualquier status) tras alta→edición→borrado es % y esperaba 0 — plata fantasma sin documento que la respalde (el gasto ya no existe).', v_net_5300;
  END IF;

  RAISE NOTICE 'PASS (F2): alta→edición→borrado — cero asientos vigentes y el 5300 neto TOTAL del gasto queda en 0.';
END $$;


-- ═ (F3) EDICIÓN A KIND BANCARIO NO ACREDITA 1110 SIN bank_movement REAL ═════
-- (revisor, ronda 1, major): rpc_update_expense NUNCA llama a
-- _pay_register_operation_bank_movement (D6 — la edición no mueve dinero).
-- Cambiar la forma de pago a un kind bancario en la edición NO puede
-- acreditar 1110 Banco sin ningún bank_movement real que lo respalde
-- (design.md D4: "el asiento nombra la cuenta que efectivamente se movió").
DO $$
DECLARE
  v_user_a      uuid;  v_account_a uuid;
  v_pm_transfer uuid;
  v_result      jsonb; v_exp_id    uuid;
  v_entry_id    uuid;  v_credit    RECORD;
  v_bank_count  integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F3): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_ag_pm_transfer__';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (F3): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- Alta SIN forma de pago — nunca toca banco.
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 400, p_date => public.reporting_local_today(),
    p_description => 'gate F3 sin forma de pago'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  -- Edición: cambia a una forma de pago BANCARIA. rpc_update_expense jamás
  -- llama al helper de banco — bank_movements tiene que seguir en CERO.
  PERFORM public.rpc_update_expense(
    p_expense_id => v_exp_id, p_payment_method_id => v_pm_transfer, p_payment_method_provided => true
  );
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT COUNT(*) INTO v_bank_count FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_bank_count <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F3-setup): la edición escribió % bank_movement(s) — rpc_update_expense no puede mover banco (D6), el fixture no aísla la condición que este bloque controla.', v_bank_count;
  END IF;

  SELECT id INTO v_entry_id FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id
    AND status = 'posted' AND reversal_of IS NULL;
  SELECT * INTO v_credit FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'credit';

  IF v_credit.account_code <> '1100' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (F3): editar la forma de pago a transfer acreditó % y esperaba 1100 — no existe ningún bank_movement real que respalde 1110 Banco.', v_credit.account_code;
  END IF;

  RAISE NOTICE 'PASS (F3): editar la forma de pago a un kind bancario NO acredita 1110 sin bank_movement real — sigue en 1100.';
END $$;


-- ═══════════════ (G) BORRADO — contra-asiento con la fila ya borrada ════════
DO $$
DECLARE
  v_user_a     uuid;  v_account_a uuid;
  v_result     jsonb; v_exp_id    uuid;
  v_orig_id    uuid;  v_orig_status text;
  v_contra     RECORD;
  v_cc_a       uuid;
  v_debit_orig   RECORD; v_debit_contra RECORD;
  v_credit_orig  RECORD; v_credit_contra RECORD;
  v_line_count   integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (G): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cc_a FROM public.cost_centers WHERE account_id = v_account_a AND name = '__gate_ag_cc_a__';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (G): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 700, p_date => public.reporting_local_today(),
    p_description => 'gate G borrado', p_cost_center_id => v_cc_a
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT id INTO v_orig_id FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id AND status = 'posted';
  IF v_orig_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G-setup): el gasto no quedó asentado antes de borrarlo.';
  END IF;

  PERFORM public.rpc_delete_expense(v_exp_id);

  IF EXISTS (SELECT 1 FROM public.expenses WHERE id = v_exp_id) THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G-setup): el borrado no eliminó la fila del gasto (borrado físico).';
  END IF;

  -- El evento de borrado ya existe con la fila del gasto YA borrada.
  IF NOT EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseDeleted' AND aggregate_id = v_exp_id
  ) THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el borrado no emitió ExpenseDeleted.';
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_orig_id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el asiento original quedó % y esperaba reversed (el contra-asiento se posteó con la fila del gasto ya borrada).', v_orig_status;
  END IF;

  SELECT * INTO v_contra FROM public.journal_entries WHERE reversal_of = v_orig_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): no existe contra-asiento referenciando al original.';
  END IF;
  IF v_contra.source_event_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el contra-asiento del borrado no lleva su propio source_event_id (única entry del evento).';
  END IF;

  SELECT COUNT(*) INTO v_line_count FROM public.journal_lines WHERE entry_id = v_contra.id;
  IF v_line_count <> 2 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el contra-asiento tiene % líneas y esperaba 2.', v_line_count;
  END IF;

  SELECT * INTO v_debit_orig   FROM public.journal_lines WHERE entry_id = v_orig_id AND side = 'debit';
  SELECT * INTO v_credit_orig  FROM public.journal_lines WHERE entry_id = v_orig_id AND side = 'credit';
  SELECT * INTO v_debit_contra  FROM public.journal_lines WHERE entry_id = v_contra.id AND side = 'credit';  -- lado invertido: el débito original aparece como crédito
  SELECT * INTO v_credit_contra FROM public.journal_lines WHERE entry_id = v_contra.id AND side = 'debit';   -- el crédito original aparece como débito

  IF v_debit_contra.account_code <> v_debit_orig.account_code OR v_debit_contra.amount <> v_debit_orig.amount THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el lado invertido del débito original (%/%) no coincide con % / % en el contra-asiento.', v_debit_orig.account_code, v_debit_orig.amount, v_debit_contra.account_code, v_debit_contra.amount;
  END IF;
  IF v_debit_contra.cost_center_id IS DISTINCT FROM v_debit_orig.cost_center_id THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el cost_center_id no sobrevivió a la reversión (original=% contra=%).', v_debit_orig.cost_center_id, v_debit_contra.cost_center_id;
  END IF;
  IF v_credit_contra.account_code <> v_credit_orig.account_code OR v_credit_contra.amount <> v_credit_orig.amount THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (G): el lado invertido del crédito original no coincide en el contra-asiento.';
  END IF;

  RAISE NOTICE 'PASS (G): borrado físico + ExpenseDeleted + contra-asiento con lados invertidos, cost_center_id preservado, source_event_id propio.';
END $$;


-- ═══════════════ (H) D7 — evita el evento envenenado ════════════════════════
DO $$
DECLARE
  v_user_a     uuid;  v_account_a uuid; v_branch_a uuid;
  v_hist_id    uuid;
  v_count      integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (H): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (H): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- ── (H1) Gasto HISTÓRICO: insertado directo, SIN pasar por rpc_create_expense
  -- → nunca tuvo ExpenseCreated. Editarlo y borrarlo NO debe emitir nada.
  INSERT INTO public.expenses (user_id, account_id, category, amount, date, branch_id, description)
  VALUES (v_user_a, v_account_a, 'Otros', 500, public.reporting_local_today(), v_branch_a, 'gate H historico')
  RETURNING id INTO v_hist_id;

  PERFORM public.rpc_update_expense(p_expense_id => v_hist_id, p_amount => 550);

  SELECT COUNT(*) INTO v_count FROM public.events WHERE aggregate_id = v_hist_id AND aggregate_type = 'Expense';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H1-edicion): editar un gasto histórico emitió % evento(s) — D7 exige CERO.', v_count;
  END IF;

  PERFORM public.rpc_delete_expense(v_hist_id);

  SELECT COUNT(*) INTO v_count FROM public.events WHERE aggregate_id = v_hist_id AND aggregate_type = 'Expense';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H1-borrado): borrar un gasto histórico emitió % evento(s) — se reintentaría con P0451 cada minuto para siempre.', v_count;
  END IF;
  IF EXISTS (SELECT 1 FROM public.expenses WHERE id = v_hist_id) THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H1-borrado): el gasto histórico no se borró.';
  END IF;

  RAISE NOTICE 'PASS (H1): gasto histórico — editar y borrar procede sin emitir ningún evento contable.';

  -- ── (H2) GEMELO: creado y borrado ANTES de que el relay corra su alta ──────
  DECLARE
    v_new_id   uuid;
    v_result   jsonb;
    v_created_count integer;
    v_deleted_count integer;
    v_entry_id uuid;
    v_status   text;
  BEGIN
    v_result := public.rpc_create_expense(
      p_category => 'Otros', p_amount => 350, p_date => public.reporting_local_today(),
      p_description => 'gate H2 creado y borrado rapido'
    );
    v_new_id := (v_result->>'expense_id')::uuid;

    -- Borrado ANTES de que el relay procese el alta.
    PERFORM public.rpc_delete_expense(v_new_id);

    SELECT COUNT(*) INTO v_created_count FROM public.events WHERE event_type = 'ExpenseCreated' AND aggregate_id = v_new_id;
    SELECT COUNT(*) INTO v_deleted_count FROM public.events WHERE event_type = 'ExpenseDeleted' AND aggregate_id = v_new_id;

    IF v_created_count <> 1 THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H2-setup): esperaba 1 ExpenseCreated sin procesar, hay %.', v_created_count;
    END IF;
    IF v_deleted_count <> 1 THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H2): borrar un gasto recién creado (alta aún sin procesar) NO emitió ExpenseDeleted — el predicado D7 tiene que mirar el EVENTO, no el asiento.';
    END IF;

    -- El relay procesa en orden de ocurrencia: el alta antes que el borrado.
    PERFORM public.rpc_process_outbox_dispatch(100);

    SELECT id, status INTO v_entry_id, v_status FROM public.journal_entries
    WHERE source_doc_type = 'Expense' AND source_doc_ref = v_new_id AND status = 'reversed';
    IF v_entry_id IS NULL THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H2): tras procesar alta+borrado en orden, no quedó el asiento original reversed.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE reversal_of = v_entry_id) THEN
      RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (H2): no existe el contra-asiento del borrado tras procesar en orden.';
    END IF;

    RAISE NOTICE 'PASS (H2): gasto creado y borrado antes del relay — ExpenseDeleted SÍ se emite, y procesados en orden el asiento se postea y su contra-asiento a continuación.';
  END;
END $$;


-- ═══ (I) IDEMPOTENCIA (D13) Y P0451 (ajuste/borrado sin asiento original) ═══
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_result    jsonb; v_exp_id    uuid;
  v_event_row public.events%ROWTYPE;
  v_entry_count integer;
  v_phantom_id  uuid := gen_random_uuid();
  v_phantom_event public.events%ROWTYPE;
  v_raised    boolean := false;
  v_sqlstate  text;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (I): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (I): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- (I.1) Reprocesar el mismo ExpenseCreated no duplica el asiento.
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 450, p_date => public.reporting_local_today(),
    p_description => 'gate I idempotencia'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT * INTO v_event_row FROM public.events
  WHERE event_type = 'ExpenseCreated' AND aggregate_id = v_exp_id;

  PERFORM public._journal_post_from_event(v_event_row);
  PERFORM public._journal_post_from_event(v_event_row);  -- segunda vez, directo

  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id;
  IF v_entry_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (I.1): reprocesar el mismo evento produjo % asientos y esperaba 1.', v_entry_count;
  END IF;
  RAISE NOTICE 'PASS (I.1): reprocesar el mismo ExpenseCreated no duplica el asiento.';

  -- (I.2) ExpenseAdjusted sin asiento original → P0451, no aborta el resto.
  v_phantom_event.id := gen_random_uuid();
  v_phantom_event.account_id := v_account_a;
  v_phantom_event.event_type := 'ExpenseAdjusted';
  v_phantom_event.aggregate_type := 'Expense';
  v_phantom_event.aggregate_id := v_phantom_id;
  v_phantom_event.payload := jsonb_build_object(
    'account_id', v_account_a, 'expense_id', v_phantom_id, 'amount', 999,
    'expense_date', public.reporting_local_today()::text, 'kind', 'cash'
  );
  v_phantom_event.occurred_at := now();

  BEGIN
    PERFORM public._journal_post_from_event(v_phantom_event);
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (I.2): un ExpenseAdjusted sin asiento original NO levantó excepción.';
  END IF;
  IF v_sqlstate <> 'P0451' THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (I.2): SQLSTATE=% y esperaba P0451.', v_sqlstate;
  END IF;
  IF EXISTS (SELECT 1 FROM public.journal_entries WHERE source_doc_type = 'Expense' AND source_doc_ref = v_phantom_id) THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (I.2): quedó un asiento huérfano para el ExpenseAdjusted fallido.';
  END IF;

  -- El resto del lote (el (I.1) de más arriba) sigue intacto.
  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id;
  IF v_entry_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (I.2): el fallo del evento fantasma afectó el asiento de otro evento.';
  END IF;

  RAISE NOTICE 'PASS (I.2): ExpenseAdjusted sin asiento original → P0451, sin asiento huérfano, sin afectar el resto.';
END $$;


-- ═══════════════════════ (J) TENENCIA Y ACL DEL HELPER ══════════════════════
DO $$
DECLARE
  v_user_a    uuid;  v_account_a uuid;
  v_user_b    uuid;  v_account_b uuid;
  v_result    jsonb; v_exp_id_a  uuid; v_exp_id_b uuid;
  v_entry_a   RECORD; v_entry_b RECORD;
  v_cross     integer;
  v_has_exec  boolean;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'asiento-gastos-a@test.local';
  SELECT id INTO v_user_b FROM auth.users WHERE email = 'asiento-gastos-b@test.local';
  IF v_user_a IS NULL OR v_user_b IS NULL THEN RAISE NOTICE 'GATE ASIENTO-GASTOS (J): setup incompleto — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 111, p_date => public.reporting_local_today(),
    p_description => 'gate J tenant A'
  );
  v_exp_id_a := (v_result->>'expense_id')::uuid;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
  v_result := public.rpc_create_expense(
    p_category => 'Otros', p_amount => 222, p_date => public.reporting_local_today(),
    p_description => 'gate J tenant B'
  );
  v_exp_id_b := (v_result->>'expense_id')::uuid;

  PERFORM public.rpc_process_outbox_dispatch(100);

  SELECT * INTO v_entry_a FROM public.journal_entries WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id_a;
  SELECT * INTO v_entry_b FROM public.journal_entries WHERE source_doc_type = 'Expense' AND source_doc_ref = v_exp_id_b;

  IF v_entry_a.account_id <> v_account_a THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (J): el asiento del gasto de A quedó en la cuenta %.', v_entry_a.account_id;
  END IF;
  IF v_entry_b.account_id <> v_account_b THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (J): el asiento del gasto de B quedó en la cuenta %.', v_entry_b.account_id;
  END IF;

  SELECT COUNT(*) INTO v_cross FROM public.journal_entries
  WHERE account_id = v_account_a AND source_doc_ref = v_exp_id_b;
  IF v_cross <> 0 THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (J): el gasto de B aparece bajo la cuenta de A.';
  END IF;

  -- El helper de mapeo no tiene EXECUTE ni para anon ni para authenticated
  -- (espejo de _journal_sale_debit_account, D12).
  SELECT has_function_privilege('anon', 'public._journal_expense_credit_account(text)', 'EXECUTE') INTO v_has_exec;
  IF v_has_exec THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (J-ACL): anon tiene EXECUTE sobre _journal_expense_credit_account.';
  END IF;
  SELECT has_function_privilege('authenticated', 'public._journal_expense_credit_account(text)', 'EXECUTE') INTO v_has_exec;
  IF v_has_exec THEN
    RAISE EXCEPTION 'GATE ASIENTO-GASTOS FAILED (J-ACL): authenticated tiene EXECUTE sobre _journal_expense_credit_account.';
  END IF;

  RAISE NOTICE 'PASS (J): el asiento lleva el account_id correcto, sin cruce entre tenants, y el helper de mapeo sin EXECUTE para anon ni authenticated.';
END $$;


-- ═══════════════════════════ Cleanup del gate ════════════════════════════════
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT array_agg(id) INTO v_users FROM auth.users
  WHERE email IN ('asiento-gastos-a@test.local', 'asiento-gastos-b@test.local');

  IF v_users IS NULL THEN
    RAISE NOTICE 'GATE ASIENTO-GASTOS cleanup: nada que limpiar (setup nunca corrió).';
    RETURN;
  END IF;

  SELECT array_agg(DISTINCT account_id) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF v_accounts IS NOT NULL THEN
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.expenses WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cost_centers WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts) AND name LIKE '__gate_ag_%';
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE ASIENTO-CONTABLE-GASTOS: cleanup completo.';
END $$;
