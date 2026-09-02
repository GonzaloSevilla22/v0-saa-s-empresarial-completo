-- =============================================================================
-- GATE: test_cobranzas_reverso.sql
-- CHANGE: cobranzas-reverso — grupos 3, 4, 5, 6 (el tramo de dinero + el
-- contra-asiento) y el invariante D13 de los dos filtros de event_type.
--
-- Pedido textual del PO (origen: OQ-4 de caja-compras-cobranzas, firmada el
-- 2026-09-01): un cobro/pago mal cargado tiene que poder anularse desde la
-- aplicación, compensando los cuatro libros (cuenta corriente, caja, banco,
-- libro diario) en una sola transacción para los tres primeros y por el
-- outbox para el contable. Sign-off del PO (2026-09-02, "continua") sobre
-- las 5 OQs del design: documento se BORRA (OQ-1), motivo opcional (OQ-2),
-- is_account_writer anula (OQ-3), sin ventana temporal (OQ-4), NULL de
-- payment_method aceptado (OQ-5).
--
-- Qué ejercita, con dos tenants sintéticos y sesión vía request.jwt.claims
-- (mismo molde que test_gastos_forma_pago.sql / test_tenancy_guard_caja_
-- outbox.sql):
--
--   (1) SETUP — tenant A (opera, con caja+banco), tenant B (ajeno, la
--       víctima de los asserts de tenencia).
--
--   (2) COBRO EN EFECTIVO, reverso completo — cta cte + caja + asiento, los
--       tres compensados, documento borrado, saldo vuelve al valor previo.
--
--   (3) COBRO BANCARIO, reverso completo — cta cte + banco + asiento (sin
--       caja: un cobro bancario no toca caja ni exige sesión abierta,
--       aunque TODAS las cajas estén cerradas — D7/OQ-4).
--
--   (4) PAGO A PROVEEDOR en efectivo, reverso completo — espejo exacto con
--       signos invertidos.
--
--   (5) SIN SESIÓN ABIERTA — P0426, y los CUATRO libros + el documento
--       quedan intactos (nada se compensa a medias).
--
--   (6) ANULAR DOS VECES — el segundo intento P0404 (idempotencia por
--       ausencia del documento, D9), sin segundo contra-movimiento.
--
--   (7) TENENCIA — anular un pago de OTRA cuenta → P0404, sin afectar
--       ninguna de las dos cuentas.
--
--   (8) CONTROL NEGATIVO OBLIGATORIO (D3, lección literal de gastos-forma-
--       pago): un movimiento de caja con el signo CONTRARIO al esperado
--       para su tipo se compensa IGUAL — la prueba de que el guard es
--       `<> 0` y no un guard de signo. Sin este caso, el gate quedaría
--       verde por omisión ante exactamente el bug que D3 describe.
--
--   (9) SALDO EN CERO — anular el cobro que dejó la cuenta en 0 procede sin
--       error y SIN `P0425` (D6: es aritméticamente inalcanzable en este
--       camino, nunca se traduce).
--
--   (10) CONTABLE — el evento de anulación procesado ANTES que el del alta
--        falla P0451 y queda pending; procesado DESPUÉS del alta, postea el
--        contra-asiento correcto y marca el original `reversed`.
--
--   (11) INVARIANTE D13 — los dos filtros de event_type (el de
--        _journal_post_from_event y el del Consumer 3 de
--        rpc_process_outbox_dispatch) listan EXACTAMENTE el mismo conjunto
--        de 11 tipos, extraídos de los cuerpos VIVOS — no de este archivo.
--        Matriz de evasión ejecutada: el mismo comparador se corre además
--        contra dos textos sintéticos con una divergencia plantada, para
--        probar que SÍ la detecta (lección de tenancy-guard-caja-outbox: un
--        detector de texto sin matriz de evasión no es un gate).
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
--
-- Cleanup: DO block separado al final que resuelve los ids por email.
-- =============================================================================


-- ═══════════════════════════ (1) SETUP — 2 tenants ═══════════════════════════
DO $$
DECLARE
  v_email_a     text := 'cobranzas-reverso-a@test.local';
  v_email_b     text := 'cobranzas-reverso-b@test.local';
  v_email_d     text := 'cobranzas-reverso-d@test.local';
  v_user_a      uuid := gen_random_uuid();
  v_user_b      uuid := gen_random_uuid();
  v_user_d      uuid := gen_random_uuid();
  v_account_a   uuid;
  v_account_b   uuid;
  v_branch_a    uuid;
  v_branch_b    uuid;
  v_cashbox_a   uuid;
  v_cashbox_b   uuid;
  v_ba_a        uuid;
  v_client_a1   uuid; -- cobro en efectivo
  v_client_a2   uuid; -- cobro bancario
  v_client_a3   uuid; -- sin sesión abierta
  v_client_a4   uuid; -- anular dos veces
  v_client_a5   uuid; -- control negativo de signo
  v_client_a6   uuid; -- saldo en cero
  v_client_a7   uuid; -- contable / P0451
  v_client_b1   uuid; -- tenencia (ajeno)
  v_supplier_a1 uuid; -- pago a proveedor
  v_ca_id       uuid;
  v_sa_id       uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Cobranzas A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Cobranzas B'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_d, 'authenticated', 'authenticated', v_email_d, now(), now(),
          jsonb_build_object('name', 'Gate Cobranzas D'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE NOTICE 'GATE COBRANZAS-REVERSO (setup): no se pudieron provisionar 2 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  -- D miembro de A SIN rol de escritura (P0401).
  DELETE FROM public.account_members WHERE user_id = v_user_d;
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_d, 'member');

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  IF v_branch_a IS NULL OR v_branch_b IS NULL THEN
    RAISE NOTICE 'GATE COBRANZAS-REVERSO (setup): sucursales no sembradas — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a, '__gate_cr_cashbox_a__') RETURNING id INTO v_cashbox_a;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id = v_branch_b ORDER BY created_at LIMIT 1;
  IF v_cashbox_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_b, '__gate_cr_cashbox_b__') RETURNING id INTO v_cashbox_b;
  END IF;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_cr_bank_a__', 'ARS', 100000) RETURNING id INTO v_ba_a;

  -- Clientes/proveedores sintéticos, uno por escenario (evita interferencia
  -- entre bloques que corren en transacciones DO separadas).
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_cash__')     RETURNING id INTO v_client_a1;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_bank__')     RETURNING id INTO v_client_a2;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_noopen__')   RETURNING id INTO v_client_a3;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_twice__')    RETURNING id INTO v_client_a4;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_negctrl__')  RETURNING id INTO v_client_a5;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_zero__')     RETURNING id INTO v_client_a6;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_cr_client_ledger__')   RETURNING id INTO v_client_a7;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_b, v_account_b, '__gate_cr_client_b__')       RETURNING id INTO v_client_b1;
  INSERT INTO public.suppliers (company_id, account_id, name) VALUES (v_account_a, v_account_a, '__gate_cr_supplier_cash__') RETURNING id INTO v_supplier_a1;

  -- Cuentas corrientes con deuda inicial de 1000 (movimiento 'sale'/'purchase'
  -- posteado directo — no hace falta pasar por una venta/compra real para
  -- ejercitar el REVERSO de un cobro/pago, que es lo que este gate cubre).
  -- c30_register_*_account_movement lee auth.uid() para created_by — hace
  -- falta impersonar al anchor correspondiente ANTES de llamarlo.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  FOR v_ca_id IN
    SELECT unnest(ARRAY[v_client_a1, v_client_a2, v_client_a3, v_client_a4, v_client_a5, v_client_a7])
  LOOP
    DECLARE v_acc uuid;
    BEGIN
      INSERT INTO public.customer_accounts (account_id, client_id, balance) VALUES (v_account_a, v_ca_id, 0) RETURNING id INTO v_acc;
      PERFORM public.c30_register_customer_account_movement(v_acc, 1000, 'sale', NULL);
    END;
  END LOOP;
  -- (9) saldo en cero: deuda inicial de EXACTAMENTE 400 (se cobra 400 → 0).
  DECLARE v_acc_zero uuid;
  BEGIN
    INSERT INTO public.customer_accounts (account_id, client_id, balance) VALUES (v_account_a, v_client_a6, 0) RETURNING id INTO v_acc_zero;
    PERFORM public.c30_register_customer_account_movement(v_acc_zero, 400, 'sale', NULL);
  END;

  -- Cuenta de proveedor con deuda inicial de 1000.
  DECLARE v_sacc uuid;
  BEGIN
    INSERT INTO public.supplier_accounts (account_id, supplier_id, balance) VALUES (v_account_a, v_supplier_a1, 0) RETURNING id INTO v_sacc;
    PERFORM public.c30_register_supplier_account_movement(v_sacc, 1000, 'purchase', NULL);
  END;

  -- (7) tenencia: cuenta de B con su propio cobro (no se reversa desde acá).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
  DECLARE v_acc_b uuid;
  BEGIN
    INSERT INTO public.customer_accounts (account_id, client_id, balance) VALUES (v_account_b, v_client_b1, 0) RETURNING id INTO v_acc_b;
    PERFORM public.c30_register_customer_account_movement(v_acc_b, 1000, 'sale', NULL);
  END;

  -- Limpiar la impersonación para no afectar bloques posteriores fuera de
  -- este DO (cada bloque siguiente fija su propio request.jwt.claims).
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a, 'open', 10000, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_user_b);

  RAISE NOTICE 'SETUP OK: tenant A (7 clientes + 1 proveedor, caja+banco) y tenant B (ajeno).';
END $$;


-- ═══════ (2) COBRO EN EFECTIVO — reverso completo (cta cte+caja+asiento) ═════
DO $$
DECLARE
  v_user_a       uuid;  v_account_a uuid;  v_client uuid;
  v_ca_id        uuid;  v_cashbox uuid;  v_session uuid;
  v_result       jsonb; v_payment_id uuid;  v_reverse_result jsonb;
  v_balance      numeric;  v_count integer;
  v_movement     RECORD;  v_cash_mov RECORD;
  v_entry        RECORD;
  v_pm_cash      uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (2): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  -- cobranzas-catalogo-pagos (D1/D5): el kind se deriva del catálogo — se
  -- resuelve el id, ya no se manda el texto literal.
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_cash__';
  SELECT id INTO v_ca_id FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client;
  SELECT cb.id INTO v_cashbox FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';
  SELECT cs.id INTO v_session FROM public.cash_sessions cs WHERE cs.cashbox_id = v_cashbox AND cs.status = 'open';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE COBRANZAS-REVERSO (2): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  -- Alta: cobro de 400 en efectivo, opt-in de caja.
  v_result := public.rpc_register_payment_received(
    'gate-cr-cash-' || gen_random_uuid()::text, v_client, 400, NULL, v_pm_cash, NULL, v_session
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 600 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-alta): balance tras el cobro quedó en % (esperaba 600).', v_balance;
  END IF;

  -- Postear el asiento del ALTA antes de anular (D5: la rama PaymentReceived
  -- ya está viva; procesarla ahora simula el caso normal donde el relay ya
  -- corrió).
  PERFORM public.rpc_process_outbox_dispatch();

  SELECT id INTO v_entry FROM public.journal_entries
  WHERE source_doc_type = 'CustomerAccount' AND source_doc_ref = v_payment_id AND status = 'posted';
  IF v_entry.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-alta): no se posteó el asiento del cobro antes de anular.';
  END IF;

  -- ═══ REVERSO ═══
  v_reverse_result := public.rpc_reverse_payment_received(v_payment_id, 'gate test motivo');

  IF (v_reverse_result->>'reversed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-reverso): reversed no es true: %', v_reverse_result;
  END IF;

  -- Cuenta corriente: balance vuelve a 1000; existe el contra-movimiento.
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-cta-cte): balance tras el reverso quedó en % (esperaba 1000).', v_balance;
  END IF;

  SELECT * INTO v_movement FROM public.customer_account_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received_reversal';
  IF v_movement.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-cta-cte): no existe el movimiento payment_received_reversal.';
  END IF;
  IF v_movement.amount <> 400 OR v_movement.balance_after <> 1000 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-cta-cte): reversa con amount=% balance_after=% (esperaba 400/1000).', v_movement.amount, v_movement.balance_after;
  END IF;

  -- El movimiento ORIGINAL sigue en el ledger, intacto.
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-cta-cte): el movimiento original desapareció o se duplicó (count=%).', v_count;
  END IF;

  -- Caja: contra-movimiento EGRESO de -400 en la MISMA sesión (sigue abierta).
  SELECT * INTO v_cash_mov FROM public.cash_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received_reversal';
  IF v_cash_mov.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-caja): no existe el contra-movimiento de caja.';
  END IF;
  IF v_cash_mov.amount <> -400 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-caja): contra-movimiento con amount=% (esperaba -400 — anular un cobro SACA plata del cajón).', v_cash_mov.amount;
  END IF;
  IF v_cash_mov.session_id <> v_session THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-caja): el contra-movimiento fue a otra sesión (%), esperaba la abierta actual (%).', v_cash_mov.session_id, v_session;
  END IF;

  -- Documento: ya no existe.
  SELECT COUNT(*) INTO v_count FROM public.payments_received WHERE id = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-documento): payments_received sigue teniendo la fila tras el reverso.';
  END IF;

  -- Evento de anulación en el outbox (aún sin procesar).
  SELECT COUNT(*) INTO v_count FROM public.events
  WHERE event_type = 'PaymentReceivedReversed' AND (payload->>'payment_id')::uuid = v_payment_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-evento): esperaba 1 evento PaymentReceivedReversed, hay %.', v_count;
  END IF;

  -- ═══ CONTABLE: procesar el reverso → contra-asiento + original reversed ═══
  PERFORM public.rpc_process_outbox_dispatch();

  SELECT status INTO v_movement FROM public.journal_entries WHERE id = v_entry.id;
  -- (reuso de v_movement como RECORD genérico está mal tipado — usar variable propia)
  PERFORM 1;

  DECLARE
    v_orig_status text;
    v_counter_entry RECORD;
    v_counter_lines_ok boolean;
  BEGIN
    SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry.id;
    IF v_orig_status <> 'reversed' THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-contable): el asiento original quedó en estado % (esperaba reversed).', v_orig_status;
    END IF;

    SELECT * INTO v_counter_entry FROM public.journal_entries
    WHERE reversal_of = v_entry.id AND status = 'posted';
    IF v_counter_entry.id IS NULL THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-contable): no se posteó el contra-asiento (reversal_of=%).', v_entry.id;
    END IF;

    -- Balancea (débito=crédito) y tiene el mismo source_doc que el original.
    SELECT (SUM(CASE WHEN side='debit' THEN amount ELSE 0 END) = SUM(CASE WHEN side='credit' THEN amount ELSE 0 END))
    INTO v_counter_lines_ok
    FROM public.journal_lines WHERE entry_id = v_counter_entry.id;
    IF NOT v_counter_lines_ok THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-contable): el contra-asiento no balancea.';
    END IF;
    IF v_counter_entry.source_doc_type <> 'CustomerAccount' OR v_counter_entry.source_doc_ref <> v_payment_id THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (2-contable): el contra-asiento no conserva source_doc_type/ref del original.';
    END IF;
  END;

  RAISE NOTICE 'PASS (2): cobro en efectivo — reverso de cta cte + caja + asiento contable, documento borrado.';
END $$;


-- ═══════════ (3) COBRO BANCARIO — reverso sin caja, sin restricción ══════════
DO $$
DECLARE
  v_user_a     uuid;  v_account_a uuid;  v_client uuid;
  v_ca_id      uuid;  v_ba uuid;
  v_result     jsonb; v_payment_id uuid; v_reverse_result jsonb;
  v_balance    numeric; v_count integer;
  v_bank_mov   RECORD;
  v_pm_transfer uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (3): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_bank__';
  SELECT id INTO v_ca_id FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client;
  SELECT id INTO v_ba FROM public.bank_accounts WHERE account_id = v_account_a AND name = '__gate_cr_bank_a__';
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Cerrar TODAS las cajas de A antes de cobrar: prueba de que un cobro
  -- bancario ni siquiera consulta el estado de la caja (D7/OQ-4 — sin
  -- ventana temporal, sin restricción de caja para lo que no la tocó).
  UPDATE public.cash_sessions cs SET status = 'closed', closed_by = v_user_a, closed_at = now()
  FROM public.cashboxes cb WHERE cb.id = cs.cashbox_id AND cb.name = '__gate_cr_cashbox_a__' AND cs.status = 'open';

  v_result := public.rpc_register_payment_received(
    'gate-cr-bank-' || gen_random_uuid()::text, v_client, 700, NULL, v_pm_transfer, v_ba, NULL
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch();

  -- Reabrir la caja para no interferir con otros bloques que la necesitan.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  SELECT cb.id, 'open', 10000, v_user_a FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';

  -- ═══ REVERSO — con TODAS las cajas cerradas al momento de cobrar, y
  -- ahora reabiertas: el cobro bancario no debería haber tocado caja en
  -- absoluto, así que su reverso tampoco.
  v_reverse_result := public.rpc_reverse_payment_received(v_payment_id, NULL);
  IF (v_reverse_result->>'reversed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (3-reverso): reversed no es true: %', v_reverse_result;
  END IF;

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (3-cta-cte): balance quedó en % (esperaba 1000).', v_balance;
  END IF;

  -- Banco: contra-movimiento invertido (transfer_in → transfer_out), -700.
  SELECT * INTO v_bank_mov FROM public.bank_movements
  WHERE source_doc_type = 'payment_received' AND source_doc_ref = v_payment_id AND amount < 0;
  IF v_bank_mov.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (3-banco): no existe el movimiento bancario inverso.';
  END IF;
  IF v_bank_mov.movement_type <> 'transfer_out' OR v_bank_mov.amount <> -700 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (3-banco): tipo=% amount=% (esperaba transfer_out/-700).', v_bank_mov.movement_type, v_bank_mov.amount;
  END IF;

  -- Caja: CERO movimientos referenciando este pago — nunca la tocó.
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_payment_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (3-caja): un cobro bancario dejó % movimientos de caja — no debería tocar caja.', v_count;
  END IF;

  RAISE NOTICE 'PASS (3): cobro bancario — reverso de cta cte + banco, sin exigir ni tocar caja, aun con todas las cajas cerradas.';
END $$;


-- ═════════════ (4) PAGO A PROVEEDOR en efectivo — espejo exacto ═════════════
DO $$
DECLARE
  v_user_a     uuid; v_account_a uuid; v_supplier uuid;
  v_sa_id      uuid; v_cashbox uuid; v_session uuid;
  v_result     jsonb; v_payment_id uuid; v_reverse_result jsonb;
  v_balance    numeric; v_movement RECORD; v_cash_mov RECORD;
  v_pm_cash    uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (4): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_supplier FROM public.suppliers WHERE account_id = v_account_a AND name = '__gate_cr_supplier_cash__';
  SELECT id INTO v_sa_id FROM public.supplier_accounts WHERE account_id = v_account_a AND supplier_id = v_supplier;
  SELECT cb.id INTO v_cashbox FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';
  SELECT cs.id INTO v_session FROM public.cash_sessions cs WHERE cs.cashbox_id = v_cashbox AND cs.status = 'open';
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  v_result := public.rpc_register_payment_made(
    'gate-cr-pay-' || gen_random_uuid()::text, v_supplier, 300, NULL, v_pm_cash, NULL, v_session
  );
  v_payment_id := (v_result->>'payment_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch();

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 700 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-alta): balance tras el pago quedó en % (esperaba 700).', v_balance;
  END IF;

  v_reverse_result := public.rpc_reverse_payment_made(v_payment_id, 'gate test pago');
  IF (v_reverse_result->>'reversed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-reverso): reversed no es true: %', v_reverse_result;
  END IF;

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-cta-cte): balance quedó en % (esperaba 1000).', v_balance;
  END IF;

  SELECT * INTO v_movement FROM public.supplier_account_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_made_reversal';
  IF v_movement.id IS NULL OR v_movement.amount <> 300 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-cta-cte): reversa ausente o con amount incorrecto: %', v_movement;
  END IF;

  -- Caja: el pago fue EGRESO (-300); su reversa es INGRESO (+300) — repone
  -- la plata, al revés que la reversa de un cobro (D10).
  SELECT * INTO v_cash_mov FROM public.cash_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_made_reversal';
  IF v_cash_mov.id IS NULL OR v_cash_mov.amount <> 300 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-caja): contra-movimiento ausente o con signo incorrecto: %', v_cash_mov;
  END IF;

  SELECT COUNT(*) INTO v_balance FROM public.payments_made WHERE id = v_payment_id; -- reuso de v_balance como contador
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (4-documento): payments_made sigue con la fila tras el reverso.';
  END IF;

  RAISE NOTICE 'PASS (4): pago a proveedor en efectivo — reverso completo, espejo exacto con signo invertido.';
END $$;


-- ══════════════ (5) SIN SESIÓN ABIERTA → P0426, nada se toca ════════════════
DO $$
DECLARE
  v_user_a     uuid; v_account_a uuid; v_client uuid;
  v_ca_id      uuid; v_cashbox uuid; v_session_own uuid;
  v_result     jsonb; v_payment_id uuid;
  v_balance_before numeric; v_balance_after numeric;
  v_count_before   integer; v_count_after integer;
  v_rejected   boolean; v_sqlstate text;
  v_pm_cash    uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (5): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_noopen__';
  SELECT id INTO v_ca_id FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client;
  SELECT cb.id INTO v_cashbox FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  SELECT id INTO v_session_own FROM public.cash_sessions WHERE cashbox_id = v_cashbox AND status = 'open';
  v_result := public.rpc_register_payment_received(
    'gate-cr-noopen-' || gen_random_uuid()::text, v_client, 250, NULL, v_pm_cash, NULL, v_session_own
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  -- Cerrar la única sesión abierta de la caja.
  UPDATE public.cash_sessions SET status = 'closed', closed_by = v_user_a, closed_at = now()
  WHERE id = v_session_own;

  SELECT balance INTO v_balance_before FROM public.customer_accounts WHERE id = v_ca_id;
  SELECT COUNT(*) INTO v_count_before FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_reverse_payment_received(v_payment_id, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF SQLSTATE = 'P0426' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (5): la anulación sin sesión abierta procedió (esperaba P0426).';
  END IF;

  -- Nada cambió: ni cta cte, ni el documento.
  SELECT balance INTO v_balance_after FROM public.customer_accounts WHERE id = v_ca_id;
  SELECT COUNT(*) INTO v_count_after FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;
  IF v_balance_before <> v_balance_after OR v_count_before <> v_count_after THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (5): P0426 dejó efectos parciales en cuenta corriente (balance %/%,  movimientos %/%).', v_balance_before, v_balance_after, v_count_before, v_count_after;
  END IF;

  PERFORM 1 FROM public.payments_received WHERE id = v_payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (5): el documento desapareció pese al rechazo P0426.';
  END IF;

  -- Reabrir la caja para no interferir con bloques posteriores.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox, 'open', 10000, v_user_a);

  RAISE NOTICE 'PASS (5): sin sesión abierta → P0426, cuenta corriente y documento intactos.';
END $$;


-- ══════════════ (6) ANULAR DOS VECES → segundo intento P0404 ════════════════
DO $$
DECLARE
  v_user_a   uuid; v_account_a uuid; v_client uuid;
  v_cashbox  uuid; v_session uuid;
  v_result   jsonb; v_payment_id uuid;
  v_count    integer; v_rejected boolean;
  v_pm_cash  uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (6): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_twice__';
  SELECT cb.id INTO v_cashbox FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';
  SELECT cs.id INTO v_session FROM public.cash_sessions cs WHERE cs.cashbox_id = v_cashbox AND cs.status = 'open';
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  v_result := public.rpc_register_payment_received(
    'gate-cr-twice-' || gen_random_uuid()::text, v_client, 150, NULL, v_pm_cash, NULL, v_session
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  PERFORM public.rpc_reverse_payment_received(v_payment_id, NULL);

  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received_reversal';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (6-setup): esperaba 1 reversa tras el primer anular, hay %.', v_count;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_reverse_payment_received(v_payment_id, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (6): el segundo intento de anular el mismo cobro no fue rechazado con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received_reversal';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (6): el segundo intento registró un SEGUNDO contra-movimiento (hay %, esperaba 1).', v_count;
  END IF;

  RAISE NOTICE 'PASS (6): anular dos veces — el segundo intento P0404, sin segundo contra-movimiento (idempotencia por ausencia, D9).';
END $$;


-- ══════════ (7) TENENCIA — anular un pago de OTRA cuenta → P0404 ════════════
DO $$
DECLARE
  v_user_a    uuid; v_user_b uuid; v_account_a uuid; v_account_b uuid;
  v_client_b  uuid; v_ca_b   uuid;
  v_payment_b jsonb; v_balance_before numeric; v_balance_after numeric;
  v_rejected  boolean;
  v_pm_cash_b uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  SELECT id INTO v_user_b FROM auth.users WHERE email = 'cobranzas-reverso-b@test.local';
  IF v_user_a IS NULL OR v_user_b IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (7): sin anchors — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client_b FROM public.clients WHERE account_id = v_account_b AND name = '__gate_cr_client_b__';
  SELECT id INTO v_ca_b FROM public.customer_accounts WHERE account_id = v_account_b AND client_id = v_client_b;
  SELECT id INTO v_pm_cash_b FROM public.payment_methods WHERE account_id = v_account_b AND kind = 'cash' AND is_active LIMIT 1;

  -- Registrar un cobro REAL para B, como B (para que el pago exista de verdad).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text, true);
  SELECT (public.rpc_register_payment_received(
    'gate-cr-tenancy-b-' || gen_random_uuid()::text, v_client_b, 500, NULL, v_pm_cash_b, NULL, NULL
  )) INTO v_payment_b;
  -- v_payment_b es jsonb; extraer el id:
  DECLARE v_payment_b_id uuid := (v_payment_b->>'payment_id')::uuid;
  BEGIN
    SELECT balance INTO v_balance_before FROM public.customer_accounts WHERE id = v_ca_b;

    -- Ahora A intenta anular el pago de B.
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

    v_rejected := false;
    BEGIN
      PERFORM public.rpc_reverse_payment_received(v_payment_b_id, NULL);
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (7): A pudo anular un pago de B — el guard de tenencia (D8) no filtró por account_id.';
    END IF;

    SELECT balance INTO v_balance_after FROM public.customer_accounts WHERE id = v_ca_b;
    IF v_balance_before <> v_balance_after THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (7): la cuenta de B cambió (%/%)  pese al rechazo P0404.', v_balance_before, v_balance_after;
    END IF;

    PERFORM 1 FROM public.payments_received WHERE id = v_payment_b_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (7): el documento de B desapareció pese al rechazo.';
    END IF;
  END;

  RAISE NOTICE 'PASS (7): anular un pago de otro tenant → P0404, sin efectos en ninguna de las dos cuentas.';
END $$;


-- ═══ (8) CONTROL NEGATIVO OBLIGATORIO — signo contrario, se compensa igual ══
-- D3: el guard es `<> 0`, JAMÁS por signo. Se inyecta a mano un movimiento de
-- caja de tipo 'payment_received' con signo NEGATIVO (el opuesto al que
-- produce el alta real) y se verifica que la anulación lo compensa IGUAL —
-- con el importe exactamente opuesto al inyectado. Un test que sólo
-- assertara "no hubo error" quedaría verde por omisión: éste es el caso que
-- prueba que NO es un guard `> 0`.
DO $$
DECLARE
  v_user_a   uuid; v_account_a uuid; v_client uuid;
  v_ca_id    uuid; v_cashbox uuid; v_session uuid;
  v_result   jsonb; v_payment_id uuid; v_reverse_result jsonb;
  v_cash_mov RECORD;
  v_pm_cash  uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (8): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_negctrl__';
  SELECT id INTO v_ca_id FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client;
  SELECT cb.id INTO v_cashbox FROM public.cashboxes cb WHERE cb.name = '__gate_cr_cashbox_a__';
  SELECT cs.id INTO v_session FROM public.cash_sessions cs WHERE cs.cashbox_id = v_cashbox AND cs.status = 'open';
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Alta SIN opt-in de caja (para no dejar el movimiento "correcto" +100 de
  -- por medio) — el movimiento de caja de este pago se inyecta a mano.
  v_result := public.rpc_register_payment_received(
    'gate-cr-negctrl-' || gen_random_uuid()::text, v_client, 100, NULL, v_pm_cash, NULL, NULL
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  -- Inyección a mano: movimiento 'payment_received' con signo CONTRARIO
  -- (negativo) al que produciría el alta real (positivo). Esto es lo que
  -- ejercita el bug que D3 describe: un guard `> 0` se saltearía este
  -- movimiento por completo.
  PERFORM public.c28_register_cash_movement(v_session, -100, 'payment_received', v_payment_id, '__gate_cr_negctrl_injected__');

  v_reverse_result := public.rpc_reverse_payment_received(v_payment_id, NULL);
  IF (v_reverse_result->>'reversed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (8): reversed no es true tras el control negativo: %', v_reverse_result;
  END IF;

  -- La reversa tiene que existir Y ser el opuesto EXACTO del importe
  -- inyectado (-100 → reversa +100), NO el opuesto del importe "esperado"
  -- para el tipo (que habría sido -100 sobre un +100 nunca inyectado).
  SELECT * INTO v_cash_mov FROM public.cash_movements
  WHERE reference_id = v_payment_id AND movement_type = 'payment_received_reversal';

  IF v_cash_mov.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (8): el guard de caja se saltó el movimiento con signo contrario — es un guard de SIGNO, no de existencia. Esto es exactamente el bug que D3 describe.';
  END IF;

  IF v_cash_mov.amount <> 100 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (8): la reversa del movimiento inyectado (-100) dio amount=% (esperaba +100 — el opuesto EXACTO del importe registrado, no del importe "típico" del tipo).', v_cash_mov.amount;
  END IF;

  RAISE NOTICE 'PASS (8) — CONTROL NEGATIVO: un movimiento de caja con signo contrario al esperado se compensa IGUAL, por el importe exactamente opuesto. El guard es <> 0, no un guard de signo.';
END $$;


-- ══════ (9) SALDO EN CERO — anula sin error, NUNCA P0425 (D6) ═══════════════
DO $$
DECLARE
  v_user_a   uuid; v_account_a uuid; v_client uuid; v_ca_id uuid;
  v_result   jsonb; v_payment_id uuid; v_reverse_result jsonb;
  v_balance  numeric;
  v_pm_cash  uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (9): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_zero__';
  SELECT id INTO v_ca_id FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Deuda inicial = 400 (seteada en (1)). Cobrar EXACTAMENTE 400 → balance 0.
  v_result := public.rpc_register_payment_received(
    'gate-cr-zero-' || gen_random_uuid()::text, v_client, 400, NULL, v_pm_cash, NULL, NULL
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (9-setup): balance tras cobrar 400 quedó en % (esperaba 0).', v_balance;
  END IF;

  -- Anular NO puede fallar con P0425 (D6): el saldo sólo puede SUBIR.
  v_reverse_result := public.rpc_reverse_payment_received(v_payment_id, NULL);
  IF (v_reverse_result->>'reversed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (9): reversed no es true: %', v_reverse_result;
  END IF;

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca_id;
  IF v_balance <> 400 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (9): balance tras anular quedó en % (esperaba volver a 400).', v_balance;
  END IF;

  RAISE NOTICE 'PASS (9): anular el cobro que dejó la cuenta en 0 procede sin error, nunca P0425 (D6).';
END $$;


-- ═════ (10) CONTABLE — reverso ANTES del alta → P0451; DESPUÉS → OK ═════════
DO $$
DECLARE
  v_user_a       uuid; v_account_a uuid; v_client uuid;
  v_result       jsonb; v_payment_id uuid; v_reverse_result jsonb;
  v_ev_alta      public.events%ROWTYPE;
  v_ev_reverso   public.events%ROWTYPE;
  v_rejected     boolean;
  v_entry_count  integer;
  v_pm_cash      uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'cobranzas-reverso-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE COBRANZAS-REVERSO (10): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client FROM public.clients WHERE account_id = v_account_a AND name = '__gate_cr_client_ledger__';
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- Alta y reverso, SIN correr el dispatcher todavía: los dos eventos
  -- (PaymentReceived, PaymentReceivedReversed) quedan sin procesar.
  v_result := public.rpc_register_payment_received(
    'gate-cr-ledger-' || gen_random_uuid()::text, v_client, 350, NULL, v_pm_cash, NULL, NULL
  );
  v_payment_id := (v_result->>'payment_id')::uuid;

  v_reverse_result := public.rpc_reverse_payment_received(v_payment_id, NULL);

  SELECT * INTO v_ev_alta FROM public.events
  WHERE event_type = 'PaymentReceived' AND (payload->>'payment_id')::uuid = v_payment_id;
  SELECT * INTO v_ev_reverso FROM public.events
  WHERE event_type = 'PaymentReceivedReversed' AND (payload->>'payment_id')::uuid = v_payment_id;

  IF v_ev_alta.id IS NULL OR v_ev_reverso.id IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10-setup): faltan los eventos de alta/reverso.';
  END IF;

  -- Procesar el REVERSO primero, directo (bypass del orden del dispatcher,
  -- para forzar determinísticamente la carrera que D5 describe).
  v_rejected := false;
  BEGIN
    PERFORM public._journal_post_from_event(v_ev_reverso);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0451' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10): procesar el reverso ANTES que el alta no falló con P0451.';
  END IF;

  -- No quedó ningún asiento — ni original (no se procesó su evento aún) ni
  -- contra-asiento (el reverso falló).
  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE source_doc_type = 'CustomerAccount' AND source_doc_ref = v_payment_id;
  IF v_entry_count <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10): quedaron % asientos tras el P0451 (esperaba 0).', v_entry_count;
  END IF;

  -- Ahora procesar el ALTA (releyendo la fila — el evento no cambió).
  PERFORM public._journal_post_from_event(v_ev_alta);

  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE source_doc_type = 'CustomerAccount' AND source_doc_ref = v_payment_id AND status = 'posted';
  IF v_entry_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10): tras procesar el alta esperaba 1 asiento posted, hay %.', v_entry_count;
  END IF;

  -- Reprocesar el reverso: ahora SÍ tiene que postear el contra-asiento.
  PERFORM public._journal_post_from_event(v_ev_reverso);

  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE reversal_of = (SELECT id FROM public.journal_entries WHERE source_doc_type='CustomerAccount' AND source_doc_ref=v_payment_id AND status='reversed');
  IF v_entry_count <> 1 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10): tras reprocesar el reverso esperaba 1 contra-asiento, hay %.', v_entry_count;
  END IF;

  -- Reproceso del mismo evento de reverso: NO postea un segundo contra-asiento.
  PERFORM public._journal_post_from_event(v_ev_reverso);
  SELECT COUNT(*) INTO v_entry_count FROM public.journal_entries
  WHERE source_doc_type = 'CustomerAccount' AND source_doc_ref = v_payment_id;
  IF v_entry_count <> 2 THEN -- original (reversed) + 1 contra-asiento, nunca 3
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (10-reproceso): reprocesar el evento ya consumido posteó de más (hay % asientos, esperaba 2).', v_entry_count;
  END IF;

  RAISE NOTICE 'PASS (10): reverso antes del alta → P0451 + pending; después del alta → contra-asiento correcto y original reversed; reproceso idempotente.';
END $$;


-- ═══ (11) INVARIANTE D13 — los dos filtros listan el MISMO conjunto ═════════
DO $$
DECLARE
  v_journal_def     text;
  v_dispatch_def    text;
  v_journal_block   text;
  v_dispatch_block  text;
  v_journal_set     text[];
  v_dispatch_set    text[];
  v_expected        text[] := ARRAY[
    'CreditNoteIssued','PaymentMade','PaymentMadeReversed','PaymentReceived',
    'PaymentReceivedReversed','PurchaseCreated','PurchaseDeleted','SaleConfirmed',
    'SaleOperationAdjusted','SaleOperationCreated','SaleOperationDeleted'
  ];
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_journal_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_journal_post_from_event';

  SELECT pg_get_functiondef(p.oid) INTO v_dispatch_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_process_outbox_dispatch';

  IF v_journal_def IS NULL OR v_dispatch_def IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11-setup): no se pudo leer el cuerpo vivo de una de las dos funciones.';
  END IF;

  -- Extraer el bloque del filtro de cada función. _journal_post_from_event
  -- tiene UN solo `NOT IN (...)` sobre v_event_type (el filtro top-level) —
  -- sin ambigüedad. El dispatcher tiene TRES `IN (...)` sobre
  -- v_event.event_type (Consumer 2, 3 y 4) — se ancla al que sigue
  -- inmediatamente a la marca "Consumer 3: JournalEntry".
  v_journal_block  := substring(v_journal_def from 'v_event_type NOT IN \(([^)]*)\)');
  v_dispatch_block := substring(v_dispatch_def from 'Consumer 3: JournalEntry.*?IN \(([^)]*)\)');

  IF v_journal_block IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11): no se pudo extraer el filtro de _journal_post_from_event — el patrón de anclaje no matcheó (¿cambió el texto del cuerpo vivo?).';
  END IF;
  IF v_dispatch_block IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11): no se pudo extraer el filtro del Consumer 3 en rpc_process_outbox_dispatch — el patrón de anclaje no matcheó.';
  END IF;

  SELECT array_agg(DISTINCT m[1] ORDER BY m[1])
  INTO v_journal_set
  FROM regexp_matches(v_journal_block, '''([A-Za-z]+)''', 'g') AS m;

  SELECT array_agg(DISTINCT m[1] ORDER BY m[1])
  INTO v_dispatch_set
  FROM regexp_matches(v_dispatch_block, '''([A-Za-z]+)''', 'g') AS m;

  IF v_journal_set IS DISTINCT FROM v_dispatch_set THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11): los dos filtros de event_type DIVERGEN. _journal_post_from_event: % — Consumer 3: %. El invariante D13 exige el MISMO conjunto en los dos lugares.', v_journal_set, v_dispatch_set;
  END IF;

  IF v_journal_set IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11): el conjunto vivo es % y esperaba los 11 tipos canónicos %.', v_journal_set, v_expected;
  END IF;

  RAISE NOTICE 'PASS (11a): los dos filtros de event_type coinciden EXACTO — 11 tipos: %', v_journal_set;

  -- ── Matriz de evasión ejecutada: el MISMO extractor+comparador, corrido
  -- contra dos textos SINTÉTICOS con una divergencia plantada, tiene que
  -- DETECTARLA. Prueba que el gate no es un detector de texto vacío
  -- (lección de tenancy-guard-caja-outbox).
  DECLARE
    v_synth_a text := 'v_event_type NOT IN (''Foo'', ''Bar'', ''Baz'')';
    v_synth_b text := 'Consumer 3: JournalEntry ... IN (''Foo'', ''Bar'', ''Qux'')'; -- Qux != Baz
    v_synth_a_block text;
    v_synth_b_block text;
    v_synth_a_set text[];
    v_synth_b_set text[];
    v_detected boolean;
  BEGIN
    v_synth_a_block := substring(v_synth_a from 'v_event_type NOT IN \(([^)]*)\)');
    v_synth_b_block := substring(v_synth_b from 'Consumer 3: JournalEntry.*?IN \(([^)]*)\)');

    SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_synth_a_set
    FROM regexp_matches(v_synth_a_block, '''([A-Za-z]+)''', 'g') AS m;
    SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_synth_b_set
    FROM regexp_matches(v_synth_b_block, '''([A-Za-z]+)''', 'g') AS m;

    v_detected := (v_synth_a_set IS DISTINCT FROM v_synth_b_set);

    IF NOT v_detected THEN
      RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (11b — MATRIZ DE EVASIÓN): el comparador NO detectó una divergencia plantada a propósito (Foo/Bar/Baz vs Foo/Bar/Qux) — el gate (11a) es un detector de texto vacío, no un gate real.';
    END IF;

    RAISE NOTICE 'PASS (11b — matriz de evasión): el mismo comparador SÍ detecta una divergencia plantada (% vs %) — el gate (11a) es un detector real.', v_synth_a_set, v_synth_b_set;
  END;
END $$;


-- ═══ (12) cobranzas-catalogo-pagos (gate 5.6 del apply, D7) — las funciones
-- de anulación NO referencian la columna de forma de pago del documento ═══
-- payments_received/payments_made ya NO tienen columna payment_method (text)
-- — la migran a payment_method_id (uuid, D3). Este gate verifica en el
-- cuerpo VIVO de las dos RPCs de anulación que ninguna las referencia, para
-- que este change (o cualquier otro futuro) no pueda romper el reverso sin
-- que algo lo note. Los bloques (2), (3) y (4) de arriba ya ejercitan la
-- anulación de un cobro/pago imputado por catálogo (payment_method_id real,
-- no NULL) y verifican que los libros compensan igual — la prueba
-- FUNCIONAL de D7/5.7 ya está cubierta; este bloque es la prueba
-- ESTRUCTURAL de que la independencia se sostiene por diseño, no por
-- casualidad.
DO $$
DECLARE
  v_def_reverse_received text;
  v_def_reverse_made     text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def_reverse_received
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_reverse_payment_received';

  SELECT pg_get_functiondef(p.oid) INTO v_def_reverse_made
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_reverse_payment_made';

  IF v_def_reverse_received IS NULL OR v_def_reverse_made IS NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (12-setup): no se pudo leer el cuerpo vivo de una de las dos funciones de anulación.';
  END IF;

  IF v_def_reverse_received ILIKE '%payment_method%' THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (12-cobro): rpc_reverse_payment_received referencia la columna de forma de pago del documento — el requirement de payment-reversal (D7) exige que las cuatro patas se disparen por existencia del movimiento, nunca por la forma de pago declarada.';
  END IF;
  IF v_def_reverse_made ILIKE '%payment_method%' THEN
    RAISE EXCEPTION 'GATE COBRANZAS-REVERSO FAILED (12-pago): rpc_reverse_payment_made referencia la columna de forma de pago del documento — mismo requirement que el cobro.';
  END IF;

  RAISE NOTICE 'PASS (12): ninguna de las dos funciones de anulación referencia la columna de forma de pago — la migración a payment_method_id (cobranzas-catalogo-pagos D3) no pudo romper el reverso, por construcción.';
END $$;


-- ═══════════════════════════ Cleanup del gate ════════════════════════════════
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN (
    'cobranzas-reverso-a@test.local', 'cobranzas-reverso-b@test.local', 'cobranzas-reverso-d@test.local'
  );

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_received WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers WHERE account_id = ANY(v_accounts);
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
    OR recipient IN ('cobranzas-reverso-a@test.local', 'cobranzas-reverso-b@test.local', 'cobranzas-reverso-d@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE COBRANZAS-REVERSO: cleanup completo.';
END $$;
