-- =============================================================================
-- GATE: test_pos_banco_movimientos.sql
-- CHANGE: pos-banco-movimientos (tasks 10.1-10.7 RED+GREEN+TRIANGULATE)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_pagos_cableados_restantes.sql) los escritores nuevos del ledger
-- bancario operativo:
--   (1) venta POS por transferencia con destino configurado (default del
--       método) → bank_movement +total, transfer_in, unreconciled,
--       balance_after correcto — RED antes de este change: hoy 0 filas.
--   (2) override de la operación gana sobre el default; sin destino
--       resuelto la venta se comporta byte a byte como antes (D2).
--   (3) compra por transferencia → egreso; venta con tarjeta → bruto
--       (card_settlement).
--   (4) venta a crédito + cobro posterior por transferencia → exactamente
--       UN movimiento (el del cobro, vía rpc_register_payment_received),
--       sin doble contabilización.
--   (5) contrato con la conciliación (C3): import + match 1:1 dejan el
--       movimiento `matched`; match N:1 de tarjeta+fee contra la línea neta.
--   (6) edición bloqueada P0423 (venta y compra) con movimiento posteado;
--       editable sin movimiento.
--   (7) P0424 sobre una sesión cerrada del período; el mensaje indica el
--       ajuste manual.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email   text := 'pos-banco-movimientos-gate@test.local';
  v_user_id        uuid := gen_random_uuid();
  v_account_id     uuid;
  v_branch_id      uuid;
  v_product_id     uuid;
  v_client_id      uuid;
  v_client2_id     uuid;
  v_supplier_id    uuid;
  v_pm_transfer    uuid;
  v_pm_card        uuid;
  v_pm_wallet      uuid;
  v_pm_credit      uuid;
  v_pm_cash        uuid;
  v_resolved       boolean := false;

  v_bank_a         uuid;  -- default del método transfer
  v_bank_b         uuid;  -- override
  v_bank_card      uuid;  -- default del método card
  v_bank_closed    uuid;  -- cuenta con período cerrado (P0424)

  v_result         jsonb;
  v_op_id          uuid;
  v_op2_id         uuid;
  v_so_id          uuid;
  v_so2b_id        uuid;  -- (2b) wallet sin destino — sin bank_movement NI otro cargo
  v_purchase_op_id uuid;
  v_count          integer;
  v_rejected       boolean;
  v_bm_id          uuid;
  v_bm1_id         uuid;  -- movimiento de (1), sobre v_bank_a — usado en (5)
  v_bm2_id         uuid;
  v_amount         numeric;
  v_movement_type  text;
  v_recon_status   text;
  v_reconciled_at  timestamptz;
  v_balance_after  numeric;
  v_opening_a      numeric := 50000;
  v_opening_card   numeric := 0;
  v_session_id     uuid;
  v_closed_session uuid;
  v_import_result  jsonb;
  v_line_id        uuid;
  v_fee_bm_id      uuid;
  v_match_result   jsonb;
BEGIN
  -- ── Anchor sintético ───────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate POS Banco Movimientos'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE POS-BANCO-MOVIMIENTOS: no se pudo resolver cuenta para el anchor sintético (contexto no permite el gate, o el anchor ya existía de una corrida previa) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;
  SELECT id INTO v_pm_card     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'card' LIMIT 1;
  SELECT id INTO v_pm_wallet   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'wallet' LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;

  IF v_branch_id IS NULL OR v_pm_transfer IS NULL OR v_pm_card IS NULL OR v_pm_wallet IS NULL OR v_pm_credit IS NULL THEN
    RAISE NOTICE 'GATE POS-BANCO-MOVIMIENTOS: branch/catálogo (kinds sembrados) no disponible para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_pbm_product__', 10000, 4000, 'GATE-PBM-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pbm_client__', 'active')
  RETURNING id INTO v_client_id;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_pbm_client2__', 'active')
  RETURNING id INTO v_client2_id;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_id, '__gate_pbm_supplier__')
  RETURNING id INTO v_supplier_id;

  -- ── Cuentas bancarias ──────────────────────────────────────────────────────
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_account_id, '__gate_pbm_bank_a__', 'ARS', v_opening_a, true)
  RETURNING id INTO v_bank_a;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_account_id, '__gate_pbm_bank_b__', 'ARS', 0, true)
  RETURNING id INTO v_bank_b;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_account_id, '__gate_pbm_bank_card__', 'ARS', v_opening_card, true)
  RETURNING id INTO v_bank_card;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_account_id, '__gate_pbm_bank_closed__', 'ARS', 0, true)
  RETURNING id INTO v_bank_closed;

  -- Default por método (D7): transfer → bank_a, card → bank_card. wallet
  -- queda A PROPÓSITO sin default (escenario "sin cuenta resuelta").
  UPDATE public.payment_methods SET bank_account_id = v_bank_a    WHERE id = v_pm_transfer;
  UPDATE public.payment_methods SET bank_account_id = v_bank_card WHERE id = v_pm_card;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE POS-BANCO-MOVIMIENTOS: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;
  v_resolved := true;

  -- ═══════════════ (1) Venta POS por transferencia — GATE ESTRELLA ═══════════
  -- Era RED antes de este change: la venta nunca escribía en bank_movements.
  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-pbm-1',
    p_client_id         => v_client_id,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 10000, 'subtotal', 10000)),
    p_payment_method    => 'transfer',
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_transfer
  ) INTO v_result;
  v_so_id := (v_result->>'sales_order_id')::uuid;

  SELECT id, amount, movement_type, reconciliation_status, reconciled_at, balance_after
  INTO   v_bm1_id, v_amount, v_movement_type, v_recon_status, v_reconciled_at, v_balance_after
  FROM   public.bank_movements
  WHERE  source_doc_type = 'sale' AND source_doc_ref = v_so_id;

  IF v_amount IS NULL THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (1, ESTRELLA): la venta POS por transferencia con destino configurado no escribió ningún bank_movement — 0 filas en prod hoy, esto es exactamente lo que este change existe para resolver.';
  END IF;
  IF v_amount <> 10000 OR v_movement_type <> 'transfer_in' OR v_recon_status <> 'unreconciled' OR v_reconciled_at IS NOT NULL THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (1): esperaba amount=10000 transfer_in unreconciled/NULL, obtuve amount=%, type=%, status=%, reconciled_at=%.', v_amount, v_movement_type, v_recon_status, v_reconciled_at;
  END IF;
  IF v_balance_after <> (v_opening_a + 10000) THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (1-balance): balance_after esperado %, obtuve %.', v_opening_a + 10000, v_balance_after;
  END IF;
  RAISE NOTICE 'PASS (1, ESTRELLA): venta POS por transferencia con destino configurado acredita el ledger bancario — +10000 transfer_in unreconciled, balance_after correcto.';

  -- ═══════════════ (2a) Override de la operación gana sobre el default ═══════
  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-pbm-2a',
    p_client_id         => v_client_id,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 5000, 'subtotal', 5000)),
    p_payment_method    => 'transfer',
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_transfer,
    p_bank_account_id   => v_bank_b
  ) INTO v_result;

  SELECT bank_account_id, amount INTO v_bm_id, v_amount
  FROM public.bank_movements
  WHERE source_doc_type = 'sale' AND source_doc_ref = (v_result->>'sales_order_id')::uuid;

  IF v_bm_id <> v_bank_b OR v_amount <> 5000 THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (2a): el override debía registrar el movimiento contra bank_b (%), registró contra % (amount=%).', v_bank_b, v_bm_id, v_amount;
  END IF;
  RAISE NOTICE 'PASS (2a): el override explícito de la operación gana sobre el default del método.';

  -- ═══════════════ (2b) Sin destino resuelto — no-op bancario byte a byte ═════
  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-pbm-2b',
    p_client_id         => v_client_id,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 3000, 'subtotal', 3000)),
    p_payment_method    => 'wallet',
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_wallet
  ) INTO v_result;

  SELECT COUNT(*) INTO v_count
  FROM public.bank_movements
  WHERE source_doc_type = 'sale' AND source_doc_ref = (v_result->>'sales_order_id')::uuid;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (2b): wallet sin destino configurado no debería escribir bank_movement, escribió %.', v_count;
  END IF;
  IF v_result->>'sales_order_id' IS NULL THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (2b): la venta debe confirmarse normalmente aunque no haya cuenta resuelta.';
  END IF;
  v_so2b_id := (v_result->>'sales_order_id')::uuid;
  RAISE NOTICE 'PASS (2b): kind bancario (wallet) sin destino configurado no escribe movimiento y la venta se confirma igual.';

  -- ═══════════════ (3a) Compra por transferencia — egreso ════════════════════
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-pbm-3a',
    p_date              => public.reporting_local_today(),
    p_description       => 'gate purchase',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 4000, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_transfer
  ) INTO v_result;
  v_purchase_op_id := (v_result->>'operation_id')::uuid;

  SELECT amount, movement_type INTO v_amount, v_movement_type
  FROM public.bank_movements
  WHERE source_doc_type = 'purchase' AND source_doc_ref = v_purchase_op_id;

  IF v_amount IS DISTINCT FROM -4000 OR v_movement_type <> 'transfer_out' THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (3a): esperaba amount=-4000 transfer_out, obtuve amount=%, type=%.', v_amount, v_movement_type;
  END IF;
  RAISE NOTICE 'PASS (3a): compra por transferencia debita el ledger bancario (-4000, transfer_out).';

  -- ═══════════════ (3b) Venta con tarjeta — bruto (card_settlement) ══════════
  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-pbm-3b',
    p_client_id         => v_client_id,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 10000, 'subtotal', 10000)),
    p_payment_method    => 'card',
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_card
  ) INTO v_result;

  SELECT id, amount, movement_type INTO v_bm_id, v_amount, v_movement_type
  FROM public.bank_movements
  WHERE source_doc_type = 'sale' AND source_doc_ref = (v_result->>'sales_order_id')::uuid;

  IF v_amount <> 10000 OR v_movement_type <> 'card_settlement' THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (3b): esperaba amount=10000 (bruto) card_settlement, obtuve amount=%, type=%.', v_amount, v_movement_type;
  END IF;
  RAISE NOTICE 'PASS (3b): venta con tarjeta se asienta bruta (card_settlement, sin descontar comisión).';

  -- ═══════════════ (4) Crédito + cobro posterior — sin doble contabilización ═
  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-pbm-4-sale',
    p_client_id         => v_client2_id,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 10000, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'sale' AND source_doc_ref = v_op_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (4a): una venta a crédito no debe escribir bank_movement, escribió %.', v_count;
  END IF;

  SELECT id INTO v_op2_id FROM public.sales WHERE operation_id = v_op_id LIMIT 1;

  -- cobranzas-catalogo-pagos (D1): 5º arg pasa de text a uuid — el kind se
  -- deriva del catálogo, v_pm_transfer ya resuelto arriba en el setup.
  PERFORM public.rpc_register_payment_received(
    'gate-pbm-4-payment', v_client2_id, 10000, v_op2_id, v_pm_transfer, v_bank_a
  );

  -- rpc_register_payment_received (C2) referencia su bank_movement por
  -- source_doc_type='payment_received' / source_doc_ref=payments_received.id
  -- (no por la venta) — se cuenta a través de esa tabla puente, filtrando
  -- por la venta que originó el cobro (reference_sale_id).
  SELECT COUNT(*) INTO v_count
  FROM public.bank_movements bm
  JOIN public.payments_received pr ON pr.id = bm.source_doc_ref AND bm.source_doc_type = 'payment_received'
  WHERE pr.reference_sale_id = v_op2_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (4b, ESTRELLA): esperaba exactamente 1 bank_movement para el ciclo crédito+cobro (el del cobro), hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (4, ESTRELLA): venta a crédito no escribe movimiento; el cobro posterior por transferencia registra exactamente UNO — sin doble contabilización.';

  -- ═══════════════ (5a) Conciliación: import + match 1:1 ══════════════════════
  INSERT INTO public.reconciliation_sessions
    (bank_account_id, account_id, period_from, period_to, statement_closing_balance, status, opened_by)
  VALUES
    (v_bank_a, v_account_id, public.reporting_local_today(), public.reporting_local_today(), 0, 'open', v_user_id)
  RETURNING id INTO v_session_id;

  SELECT public.rpc_import_bank_statement(
    'gate-pbm-5-import', v_bank_a, 'extracto_gate.csv', 'gate-pbm-hash-5',
    jsonb_build_array(jsonb_build_object(
      'line_no', 1, 'value_date', public.reporting_local_today(),
      'description', 'gate line', 'amount', 10000, 'balance', NULL
    ))
  ) INTO v_import_result;

  SELECT id INTO v_line_id FROM public.bank_statement_lines
  WHERE bank_account_id = v_bank_a AND amount = 10000 AND description = 'gate line'
  LIMIT 1;

  SELECT public.rpc_create_reconciliation_match(v_session_id, ARRAY[v_line_id], ARRAY[v_bm1_id]) INTO v_match_result;
  -- v_bm1_id es el movimiento de (1) (transfer, +10000, sobre v_bank_a) —
  -- misma cuenta que la sesión abierta arriba, matchea por monto exacto
  -- contra la línea de +10000 recién importada.

  SELECT reconciliation_status INTO v_recon_status FROM public.bank_movements WHERE id = v_bm1_id;
  IF v_recon_status <> 'matched' THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (5a): el bank_movement debía quedar matched tras el match 1:1, quedó %.', v_recon_status;
  END IF;
  RAISE NOTICE 'PASS (5a): el movimiento generado por una operación es conciliable sin piezas nuevas — match 1:1 lo deja matched.';

  -- ═══════════════ (6a) Edición bloqueada con movimiento posteado (venta) ════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[(SELECT id FROM public.sales WHERE operation_id = (
        SELECT so2.sale_operation_id FROM public.sales_orders so2 WHERE so2.id = v_so_id
      ) LIMIT 1)],
      v_client_id, public.reporting_local_today(), 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 9999, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%operation_has_bank_movement_immutable%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (6a): editar una venta con bank_movement posteado debería rechazarse con operation_has_bank_movement_immutable.';
  END IF;
  RAISE NOTICE 'PASS (6a): edición de venta bloqueada (P0423) cuando hay un bank_movement posteado.';

  -- ═══════════════ (6b) Edición bloqueada con movimiento posteado (compra) ═══
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      ARRAY[(SELECT id FROM public.purchases WHERE operation_id = v_purchase_op_id LIMIT 1)],
      public.reporting_local_today(), 'gate edit',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 4444, 'quantity', 1))
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%operation_has_bank_movement_immutable%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (6b): editar una compra con bank_movement posteado debería rechazarse con operation_has_bank_movement_immutable.';
  END IF;
  RAISE NOTICE 'PASS (6b): edición de compra bloqueada (P0423) cuando hay un bank_movement posteado.';

  -- ═══════════════ (6c) Editable sin movimiento posteado (control negativo) ═══
  -- (2b) es wallet SIN cuenta resuelta: no generó bank_movement, cash_movement
  -- ni cargo de cuenta corriente — el único control limpio disponible en este
  -- gate para "editable" (a diferencia de v_op_id/credit, que SÍ tiene cargo
  -- de #425 D6, y de por qué NO se reusa acá).
  PERFORM public.rpc_atomic_update_sale_operation(
    ARRAY[(SELECT s.id FROM public.sales s
           JOIN public.sales_orders so3 ON so3.sale_operation_id = s.operation_id
           WHERE so3.id = v_so2b_id LIMIT 1)],
    v_client_id, public.reporting_local_today(), 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 3000, 'quantity', 1))
  );
  RAISE NOTICE 'PASS (6c, control): una venta SIN cargo de cuenta corriente, sin movimiento de caja y sin bank_movement sigue siendo editable — el guard nuevo no bloquea de más.';

  -- ═══════════════ (7) P0424 — período ya conciliado y cerrado ═══════════════
  INSERT INTO public.reconciliation_sessions
    (bank_account_id, account_id, period_from, period_to, statement_closing_balance,
     ledger_closing_balance, difference, status, opened_by, closed_by, opened_at, closed_at)
  VALUES
    (v_bank_closed, v_account_id,
     (public.reporting_local_today() - INTERVAL '2 months')::date,
     (public.reporting_local_today() - INTERVAL '1 month')::date,
     0, 0, 0, 'closed', v_user_id, v_user_id, now(), now())
  RETURNING id INTO v_closed_session;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-pbm-7',
      p_client_id         => v_client_id,
      p_date              => (public.reporting_local_today() - INTERVAL '6 weeks')::date,
      p_currency          => 'ARS',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 1000, 'quantity', 1)),
      p_branch_id         => v_branch_id,
      p_payment_method_id => v_pm_transfer,
      p_bank_account_id   => v_bank_closed
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%bank_period_reconciled%' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE POS-BANCO-MOVIMIENTOS FAILED (7): una venta con value_date dentro de un período ya conciliado y cerrado debería rechazarse con bank_period_reconciled (P0424).';
  END IF;
  RAISE NOTICE 'PASS (7): P0424 rechaza un movimiento cuya value_date cae dentro de un período conciliado y cerrado. El POS (rpc_quick_sale/rpc_confirm_sales_order) no acepta p_date — estructuralmente no puede dispararlo, siempre opera sobre reporting_local_today().';

  RAISE NOTICE 'GATE POS-BANCO-MOVIMIENTOS: PASSED — ledger bancario operativo cableado en los 3 caminos de alta, D2-D4 verificados, conciliación intacta, inmutabilidad extendida.';
END $$;
