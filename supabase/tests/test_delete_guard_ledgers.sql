-- =============================================================================
-- GATE: test_delete_guard_ledgers.sql
-- CHANGE: delete-guard-ledgers (tasks 2.1-2.3, 3.1-3.3, 4.1-4.5, 5.1-5.9,
-- 6.1-6.10, 7.1-7.5 RED+GREEN+TRIANGULATE)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_pagos_cableados_restantes.sql) las piezas nuevas de este change:
--   (GATE ESTRELLA) rpc_delete_sale_operation sobre una operación con dinero
--       posteado en LOS CUATRO LIBROS simultáneamente (cuenta corriente,
--       caja, banco, contable) — los cuatro vuelven a su valor previo, el
--       contra-asiento existe y balancea, la venta desaparece, el kardex
--       se repone.
--   (P0423) venta con comprobante fiscal pending_cae/authorized → bloqueada,
--       nada se toca.
--   (P0425) venta a crédito ya cobrada → bloqueada, saldo intacto.
--   (P0426) venta con caja y SIN sesión abierta → bloqueada; con sesión
--       cerrada + otra abierta → compensa en la abierta, la cerrada intacta.
--   (D8) venta del POS → su sales_order pasa a canceled, transición
--       registrada, sale_operation_id desvinculado.
--   (idempotencia) reprocesar el mismo evento SaleOperationDeleted no postea
--       un segundo contra-asiento.
--   (compra) rpc_delete_purchase_operation — mismo molde sin fiscal/caja/
--       sales_order: P0425 de proveedor, espejo bancario, contra-asiento
--       Purchase con cost_center_id preservado.
--   (sin dinero) operación sin ningún libro posteado se borra como antes.
--   (spot-check) SaleConfirmed/PurchaseCreated (2 de las 7 ramas
--       preexistentes) siguen posteando igual — cobertura profunda de las 7
--       ya la dan test_pagos_cableados_restantes.sql y
--       test_asiento_venta_formulario.sql, re-corridos como safety net.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email      text := 'delete-guard-ledgers-gate@test.local';
  v_user_id           uuid := gen_random_uuid();
  v_account_id        uuid;
  v_branch_id         uuid;
  v_cashbox_id        uuid;
  v_session1_id       uuid;  -- sesión que se CIERRA (para el caso P0426b)
  v_session2_id       uuid;  -- sesión abierta actual
  v_bank_account_id   uuid;
  v_product_id        uuid;
  v_client_id         uuid;
  v_client2_id        uuid;
  v_supplier_id       uuid;
  v_fiscal_profile_id uuid;
  v_pos_id            uuid;
  v_resolved          boolean := false;

  -- gate estrella
  v_op1               uuid := gen_random_uuid();
  v_sale1_id          uuid;
  v_ca1_id            uuid;
  v_entry1_id         uuid;
  v_line_no           int;
  v_result            boolean;
  v_balance           numeric;
  v_cash_before        numeric;
  v_cash_after         numeric;
  v_bank_before        numeric;
  v_bank_after         numeric;
  v_count             int;
  v_reversed_entry_id uuid;
  v_orig_status       text;
  v_qty_before        numeric;
  v_qty_after         numeric;
  v_processed         int;

  -- P0423
  v_op2               uuid := gen_random_uuid();
  v_sale2_id          uuid;
  v_so2_id            uuid;
  v_fd2_id            uuid;
  v_rejected          boolean;

  -- venta-editable-sin-cae: el borrado sigue el MISMO predicado que la
  -- edición — un pendiente NO enviado se anula y la venta se borra; un
  -- pendiente MARCADO bloquea igual que authorized.
  v_op2b              uuid := gen_random_uuid();   -- pendiente SIN marca → se anula
  v_sale2b_id         uuid;
  v_so2b_id           uuid;
  v_fd2b_id           uuid;
  v_ca2b_id           uuid;
  v_op2c              uuid := gen_random_uuid();   -- pendiente MARCADO → P0423
  v_sale2c_id         uuid;
  v_so2c_id           uuid;
  v_fd2c_id           uuid;
  v_status_text       text;
  v_msg               text;

  -- P0425
  v_op3               uuid := gen_random_uuid();
  v_sale3_id          uuid;
  v_ca3_id            uuid;

  -- P0426
  v_op4               uuid := gen_random_uuid();
  v_sale4_id          uuid;
  v_cashbox4_id       uuid;

  -- POS cancel + idempotencia
  v_op5               uuid := gen_random_uuid();
  v_sale5_id          uuid;
  v_so5_id            uuid;
  v_event5_id         uuid;
  v_so5_status        text;
  v_so5_op            uuid;
  v_hist_count        int;

  -- compra
  v_op6               uuid := gen_random_uuid();
  v_purchase6_id      uuid;
  v_sa6_id            uuid;
  v_entry6_id         uuid;

  -- sin dinero
  v_op7               uuid := gen_random_uuid();
  v_sale7_id          uuid;
BEGIN
  -- ── Anchor sintético ───────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Delete Guard Ledgers'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE DELETE-GUARD-LEDGERS: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id  FROM public.branches  WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_id FROM public.cashboxes WHERE branch_id  = v_branch_id  ORDER BY created_at LIMIT 1;

  IF v_branch_id IS NULL OR v_cashbox_id IS NULL THEN
    RAISE NOTICE 'GATE DELETE-GUARD-LEDGERS: branch/cashbox no disponibles para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_dgl_product__', 1000, 400, 'GATE-DGL-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_dgl_client__', 'active')
  RETURNING id INTO v_client_id;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_dgl_client2__', 'active')
  RETURNING id INTO v_client2_id;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_id, '__gate_dgl_supplier__')
  RETURNING id INTO v_supplier_id;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_id, '__gate_dgl_bank__', 'ARS', 0)
  RETURNING id INTO v_bank_account_id;

  -- venta-editable-sin-cae (HALLAZGO, no previsto por el plan): el bloque
  -- fiscal de este gate arrancaba con
  -- `SELECT id INTO v_fiscal_profile_id FROM fiscal_profiles WHERE account_id = ...`
  -- y el anchor sintético NUNCA tuvo perfil fiscal ni punto de venta, así que
  -- contra un `supabase db reset` limpio (que es exactamente cómo corre en CI)
  -- el gate imprimía "se omite el caso P0423" y el ÚNICO test del guard fiscal
  -- del BORRADO no se ejecutaba nunca. Se siembran acá para que el bloque
  -- corra de verdad. CUIT propio (20777777775): fn_guard_pos_cuit_cross_account
  -- (G9 de fiscal-emision-segura) rechaza con P0435 el mismo CUIT + mismo
  -- número de punto de venta activo en otra cuenta, y los demás gates fiscales
  -- ya usan 201111111xx / 205555555xx / 20666666663 / 27888888884.
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_id, '20777777775', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fiscal_profile_id;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fiscal_profile_id, v_account_id, 1, true)
  RETURNING id INTO v_pos_id;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE DELETE-GUARD-LEDGERS: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;
  v_resolved := true;

  -- Dos sesiones de caja: session1 se CERRARÁ (para ejercitar P0426b), session2 queda abierta.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 0, v_user_id)
  RETURNING id INTO v_session1_id;

  UPDATE public.cash_sessions SET status = 'closed', closed_by = v_user_id, closed_at = now(),
    closing_balance = 0, counted_balance = 0, expected_balance = 0, difference = 0
  WHERE id = v_session1_id;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 0, v_user_id)
  RETURNING id INTO v_session2_id;

  -- ════════════════════ (GATE ESTRELLA) 4 libros a la vez ════════════════════
  -- Venta a crédito ($1000) con, ADEMÁS, caja ($1000, sesión abierta) y banco
  -- ($1000, transfer_in) posteados sobre la MISMA operación — no es el flujo
  -- de un solo payment_method real, es el peor caso para probar que la RPC
  -- compensa los CUATRO libros a la vez, sin dejar ninguno a mitad de camino.

  INSERT INTO public.sales
    (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES
    (v_user_id, v_account_id, v_client_id, v_product_id, 1000, 1, 1000, 'ARS', CURRENT_DATE, v_op1, v_branch_id)
  RETURNING id INTO v_sale1_id;

  INSERT INTO public.stock_movements
    (user_id, account_id, product_id, product_name, type, quantity_delta,
     quantity_before, quantity_after, reference_id, reference_type, branch_id)
  VALUES
    (v_user_id, v_account_id, v_product_id, '__gate_dgl_product__', 'sale', -1,
     1000, 999, v_sale1_id, 'sale', v_branch_id);

  UPDATE public.branch_stock SET quantity = 999 WHERE branch_id = v_branch_id AND product_id = v_product_id;

  v_ca1_id := public.c30_get_or_create_customer_account(v_account_id, v_client_id);
  PERFORM public.c30_register_customer_account_movement(v_ca1_id, 1000, 'sale', v_op1);

  PERFORM public.c28_register_cash_movement(v_session2_id, 1000, 'sale', v_op1);
  SELECT v_ba.opening_balance + COALESCE(SUM(bm.amount), 0) INTO v_bank_before
    FROM public.bank_accounts v_ba LEFT JOIN public.bank_movements bm ON bm.bank_account_id = v_ba.id
   WHERE v_ba.id = v_bank_account_id GROUP BY v_ba.opening_balance;
  PERFORM public._register_bank_movement(v_bank_account_id, 1000, 'transfer_in', 'sale', v_op1, CURRENT_DATE, v_branch_id, 'gate dgl');

  -- Marcar el movimiento bancario original como conciliado (D6: el espejo se
  -- postea igual, unreconciled, sin tocar el original).
  UPDATE public.bank_movements SET reconciliation_status = 'matched', reconciled_at = now()
  WHERE bank_account_id = v_bank_account_id AND source_doc_ref = v_op1;

  INSERT INTO public.journal_entries (account_id, posted_at, source_doc_type, source_doc_ref, status)
  VALUES (v_account_id, now(), 'SaleOperation', v_op1, 'posted')
  RETURNING id INTO v_entry1_id;

  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no)
  VALUES (v_entry1_id, v_account_id, '1300', 'debit', 1000, 1);
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no)
  VALUES (v_entry1_id, v_account_id, '4100', 'credit', 1000, 2);

  -- Pre-condiciones
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca1_id;
  IF v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-pre): balance de cliente esperado 1000 antes de borrar, es %.', v_balance;
  END IF;

  -- ── Borrar ────────────────────────────────────────────────────────────────
  v_result := public.rpc_delete_sale_operation(p_operation_id => v_op1);
  IF NOT v_result THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella): rpc_delete_sale_operation devolvió false.';
  END IF;

  -- Despachar el outbox para que el contra-asiento se postee.
  PERFORM public.rpc_process_outbox_dispatch(1000);

  -- (1) Cuenta corriente vuelve a 0
  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca1_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-1): saldo de cliente esperado 0 tras borrar, es %.', v_balance;
  END IF;

  -- (2) Caja: sesión abierta vuelve a su balance de apertura
  SELECT opening_balance + COALESCE(SUM(amount), 0) INTO v_cash_after
  FROM public.cash_sessions cs LEFT JOIN public.cash_movements cm ON cm.session_id = cs.id
  WHERE cs.id = v_session2_id GROUP BY opening_balance;
  IF v_cash_after <> 0 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-2): saldo de sesión abierta esperado 0 tras borrar, es %.', v_cash_after;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements
  WHERE session_id = v_session2_id AND movement_type = 'sale_reversal' AND reference_id = v_op1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-2b): esperaba 1 movimiento sale_reversal, hay %.', v_count;
  END IF;

  -- (3) Banco: saldo vuelve a 0; original SIGUE conciliado; espejo unreconciled
  SELECT v_ba.opening_balance + COALESCE(SUM(bm.amount), 0) INTO v_bank_after
    FROM public.bank_accounts v_ba LEFT JOIN public.bank_movements bm ON bm.bank_account_id = v_ba.id
   WHERE v_ba.id = v_bank_account_id GROUP BY v_ba.opening_balance;
  IF v_bank_after <> v_bank_before THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-3): saldo bancario esperado % tras borrar, es %.', v_bank_before, v_bank_after;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id AND source_doc_ref = v_op1
      AND movement_type = 'transfer_in' AND reconciliation_status = 'matched'
  ) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-3b): el movimiento bancario ORIGINAL debe seguir matched.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id AND source_doc_ref = v_op1
      AND movement_type = 'transfer_out' AND amount = -1000 AND reconciliation_status = 'unreconciled'
  ) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-3c): esperaba el espejo transfer_out(-1000) unreconciled.';
  END IF;

  -- (4) Contable: original reversed + contra-asiento balanceado con reversal_of
  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry1_id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-4a): asiento original esperado reversed, es %.', v_orig_status;
  END IF;

  SELECT id INTO v_reversed_entry_id FROM public.journal_entries
  WHERE reversal_of = v_entry1_id AND status = 'posted';
  IF v_reversed_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-4b): no se encontró el contra-asiento (reversal_of=%).', v_entry1_id;
  END IF;

  SELECT
    COALESCE(SUM(CASE WHEN side='debit' THEN amount END),0),
    COALESCE(SUM(CASE WHEN side='credit' THEN amount END),0)
  INTO v_cash_before, v_cash_after  -- reuso de variables numeric como scratch
  FROM public.journal_lines WHERE entry_id = v_reversed_entry_id;
  IF v_cash_before <> v_cash_after THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-4c): contra-asiento no balancea (debit=%, credit=%).', v_cash_before, v_cash_after;
  END IF;
  IF v_cash_before <> 1000 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-4d): contra-asiento esperado por 1000 en cada lado, es %.', v_cash_before;
  END IF;

  -- (5) Kardex repuesto (999 → 1000)
  SELECT quantity INTO v_qty_after FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  IF v_qty_after <> 1000 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-5): stock esperado 1000 tras borrar, es %.', v_qty_after;
  END IF;

  -- (6) La venta ya no existe
  IF EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale1_id) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (estrella-6): la venta sigue existiendo tras el borrado.';
  END IF;

  RAISE NOTICE 'PASS (GATE ESTRELLA): borrar una operación con dinero en los 4 libros los deja en cero neto + contra-asiento balanceado + kardex repuesto + venta borrada.';

  -- ════════════════════ (P0423) fiscal bloquea el borrado ════════════════════
  SELECT id INTO v_fiscal_profile_id FROM public.fiscal_profiles WHERE account_id = v_account_id LIMIT 1;
  SELECT id INTO v_pos_id FROM public.points_of_sale WHERE account_id = v_account_id LIMIT 1;

  IF v_fiscal_profile_id IS NOT NULL AND v_pos_id IS NOT NULL THEN
    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_id, v_account_id, v_client_id, v_product_id, 500, 1, 500, 'ARS', CURRENT_DATE, v_op2, v_branch_id)
    RETURNING id INTO v_sale2_id;

    -- fiscal-riesgos-residuales (R2): trg_guard_fiscal_document_insert_interno
    -- rechaza con P0436 un INSERT que no nazca pending_cae. Este fixture
    -- siembra el estado FINAL de un comprobante emitido (al que por el camino
    -- legítimo se llega con un UPDATE del relay), así que elude el trigger de
    -- forma acotada — mismo patrón que este archivo ya usa en su limpieza.
    SET session_replication_role = replica;
    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, client_id, total, status)
    VALUES (v_account_id, v_fiscal_profile_id, v_pos_id, 'factura_b', 1, 99001, v_client_id, 500, 'authorized')
    RETURNING id INTO v_fd2_id;
    SET session_replication_role = DEFAULT;

    INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, sale_operation_id, fiscal_document_id, created_by)
    VALUES (v_account_id, v_branch_id, v_client_id, 'confirmed', 500, v_op2, v_fd2_id, v_user_id)
    RETURNING id INTO v_so2_id;

    v_rejected := false;
    BEGIN
      PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op2);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423): borrar una venta con comprobante authorized debería fallar con P0423.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale2_id) THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-intacto): la venta bloqueada no debería haberse borrado.';
    END IF;
    RAISE NOTICE 'PASS (P0423): venta con comprobante fiscal emitido no se puede borrar — venta, comprobante y orden intactos.';

    -- ══════ venta-editable-sin-cae: pendiente NO enviado → se BORRA y el ══════
    -- comprobante se ANULA en la misma transacción, además de compensar la
    -- cuenta corriente. El comprobante NACE pending_cae limpio (camino
    -- legítimo, sin eludir trg_guard_fiscal_document_insert_interno) — así el
    -- control positivo del trigger de INSERT sigue vivo en este archivo.
    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_id, v_account_id, v_client_id, v_product_id, 400, 1, 400, 'ARS', CURRENT_DATE, v_op2b, v_branch_id)
    RETURNING id INTO v_sale2b_id;

    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, client_id, total, status)
    VALUES (v_account_id, v_fiscal_profile_id, v_pos_id, 'factura_b', 1, 99002, v_client_id, 400, 'pending_cae')
    RETURNING id INTO v_fd2b_id;

    INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, sale_operation_id, fiscal_document_id, created_by)
    VALUES (v_account_id, v_branch_id, v_client_id, 'confirmed', 400, v_op2b, v_fd2b_id, v_user_id)
    RETURNING id INTO v_so2b_id;

    v_ca2b_id := public.c30_get_or_create_customer_account(v_account_id, v_client_id);
    PERFORM public.c30_register_customer_account_movement(v_ca2b_id, 400, 'sale', v_op2b);
    SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca2b_id;

    v_result := public.rpc_delete_sale_operation(p_operation_id => v_op2b, p_reason => 'borrado con comprobante pendiente');

    IF NOT v_result THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado): rpc_delete_sale_operation devolvió false para una venta con comprobante pendiente NO enviado.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale2b_id) THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado): la venta debería haberse borrado.';
    END IF;
    SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_fd2b_id;
    IF v_status_text IS DISTINCT FROM 'voided' THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado): el comprobante pendiente debería quedar voided, quedó %.', COALESCE(v_status_text, '<inexistente>');
    END IF;
    SELECT COUNT(*) INTO v_count
    FROM   public.document_status_history
    WHERE  document_type = 'fiscal_document' AND document_id = v_fd2b_id
      AND  from_status = 'pending_cae' AND to_status = 'voided'
      AND  reason IS NOT NULL AND trim(reason) <> '';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado-historial): esperaba 1 transición pending_cae→voided con motivo, hay %.', v_count;
    END IF;
    -- La compensación de los libros sigue corriendo (el guard fiscal no aborta).
    SELECT balance INTO v_cash_before FROM public.customer_accounts WHERE id = v_ca2b_id;
    IF v_cash_before <> v_balance - 400 THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado-cta-cte): el cargo debía compensarse (% → %), quedó %.', v_balance, v_balance - 400, v_cash_before;
    END IF;
    -- D8: la orden se cancela y conserva el vínculo al comprobante anulado.
    SELECT status INTO v_status_text FROM public.sales_orders WHERE id = v_so2b_id;
    IF v_status_text IS DISTINCT FROM 'canceled' THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado-orden): la orden debería quedar canceled, quedó %.', COALESCE(v_status_text, '<inexistente>');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so2b_id AND fiscal_document_id = v_fd2b_id) THEN
      RAISE EXCEPTION 'GATE DGL FAILED (voided-borrado-vinculo): la orden debe conservar fiscal_document_id apuntando al comprobante anulado (D5).';
    END IF;
    RAISE NOTICE 'PASS (voided-borrado): borrar una venta con comprobante pendiente NO enviado lo anula (voided + historial con motivo), compensa la cuenta corriente y cancela la orden conservando el vínculo.';

    -- ══════ venta-editable-sin-cae: pendiente MARCADO → P0423, nada se toca ══════
    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_id, v_account_id, v_client_id, v_product_id, 600, 1, 600, 'ARS', CURRENT_DATE, v_op2c, v_branch_id)
    RETURNING id INTO v_sale2c_id;

    INSERT INTO public.fiscal_documents
      (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, client_id, total, status)
    VALUES (v_account_id, v_fiscal_profile_id, v_pos_id, 'factura_b', 1, 99003, v_client_id, 600, 'pending_cae')
    RETURNING id INTO v_fd2c_id;
    -- La marca se pone por UPDATE (el INSERT con marca lo rechaza P0436) —
    -- exactamente lo que hace el relay antes del FECAESolicitar.
    UPDATE public.fiscal_documents
    SET    cae_submit_started_at = now(), arca_requested_number = 99003
    WHERE  id = v_fd2c_id;

    INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, sale_operation_id, fiscal_document_id, created_by)
    VALUES (v_account_id, v_branch_id, v_client_id, 'confirmed', 600, v_op2c, v_fd2c_id, v_user_id)
    RETURNING id INTO v_so2c_id;

    v_rejected := false;
    v_msg := NULL;
    BEGIN
      PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op2c);
    EXCEPTION
      WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-marcado): borrar una venta cuyo comprobante YA salió hacia ARCA debería fallar con P0423.';
    END IF;
    IF position('fiscal_document_sent_immutable' in COALESCE(v_msg, '')) = 0 THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-marcado-token): esperaba el token fiscal_document_sent_immutable, obtuvo: %', COALESCE(v_msg, '<sin mensaje>');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale2c_id) THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-marcado-intacto): la venta bloqueada no debería haberse borrado.';
    END IF;
    SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_fd2c_id;
    IF v_status_text IS DISTINCT FROM 'pending_cae' THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-marcado-comprobante): un comprobante MARCADO jamás debe anularse, quedó %.', COALESCE(v_status_text, '<inexistente>');
    END IF;
    SELECT status INTO v_status_text FROM public.sales_orders WHERE id = v_so2c_id;
    IF v_status_text IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'GATE DGL FAILED (P0423-marcado-orden): la orden no debería haberse cancelado, quedó %.', COALESCE(v_status_text, '<inexistente>');
    END IF;
    RAISE NOTICE 'PASS (P0423-marcado): borrar una venta cuyo comprobante ya se envió a ARCA falla con P0423/fiscal_document_sent_immutable — venta, comprobante y orden intactos.';
  ELSE
    RAISE NOTICE 'GATE DGL: sin fiscal_profile/point_of_sale sembrados para el anchor — se omite el caso P0423.';
  END IF;

  -- ════════════════════ (P0425) saldo negativo bloquea ═══════════════════════
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_id, v_account_id, v_client2_id, v_product_id, 800, 1, 800, 'ARS', CURRENT_DATE, v_op3, v_branch_id)
  RETURNING id INTO v_sale3_id;

  v_ca3_id := public.c30_get_or_create_customer_account(v_account_id, v_client2_id);
  PERFORM public.c30_register_customer_account_movement(v_ca3_id, 800, 'sale', v_op3);
  -- El cliente ya pagó de más (payment_received > cargo) — dejaría el saldo negativo si se revierte.
  PERFORM public.c30_register_customer_account_movement(v_ca3_id, -800, 'payment_received', NULL);

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca3_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0425-pre): saldo esperado 0 (cargo+pago), es %.', v_balance;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op3);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0425' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0425): borrar una venta ya cobrada debería fallar con P0425.';
  END IF;

  SELECT balance INTO v_balance FROM public.customer_accounts WHERE id = v_ca3_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0425-post): el saldo no debe modificarse cuando el borrado se rechaza, es %.', v_balance;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale3_id) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0425-intacto): la venta bloqueada no debería haberse borrado.';
  END IF;
  RAISE NOTICE 'PASS (P0425): venta a crédito ya cobrada no se puede borrar — el saldo del cliente no se toca.';

  -- ════════════════ (P0426) sin sesión abierta bloquea; sesión cerrada respetada ═══════
  INSERT INTO public.cashboxes (branch_id, name, currency)
  VALUES (v_branch_id, '__gate_dgl_cashbox_noopen__', 'ARS')
  RETURNING id INTO v_cashbox4_id;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox4_id, 'open', 0, v_user_id)
  RETURNING id INTO v_session1_id;  -- reuso de variable, ya no se necesita el valor anterior

  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_id, v_account_id, NULL, v_product_id, 300, 1, 300, 'ARS', CURRENT_DATE, v_op4, v_branch_id)
  RETURNING id INTO v_sale4_id;

  PERFORM public.c28_register_cash_movement(v_session1_id, 300, 'sale', v_op4);

  UPDATE public.cash_sessions SET status = 'closed', closed_by = v_user_id, closed_at = now(),
    closing_balance = 300, counted_balance = 300, expected_balance = 300, difference = 0
  WHERE id = v_session1_id;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op4);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0426' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426): borrar una venta con caja cerrada y sin sesión abierta debería fallar con P0426.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale4_id) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426-intacto): la venta bloqueada no debería haberse borrado.';
  END IF;
  RAISE NOTICE 'PASS (P0426): venta con caja cerrada y sin sesión abierta en esa caja no se puede borrar.';

  -- Abrir una sesión nueva en la MISMA caja y reintentar: debe compensar ahí,
  -- dejando la sesión cerrada (con su arqueo firmado) intacta.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox4_id, 'open', 0, v_user_id)
  RETURNING id INTO v_session2_id;  -- reuso de variable

  v_result := public.rpc_delete_sale_operation(p_operation_id => v_op4);
  IF NOT v_result THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426b): el borrado debería proceder una vez abierta la sesión.';
  END IF;

  SELECT closing_balance INTO v_balance FROM public.cash_sessions WHERE id = v_session1_id;
  IF v_balance <> 300 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426b-arqueo): el arqueo de la sesión CERRADA no debe modificarse, closing_balance=%.', v_balance;
  END IF;

  -- La sesión nueva arrancó en 0 y solo recibe el sale_reversal(-300) — su
  -- propio saldo queda en -300 (D5: "el arqueo del día de la anulación
  -- mostrará una salida que no corresponde a una venta de ese día", es
  -- correcto contablemente). Lo que importa es que NO cayó en la cerrada.
  SELECT opening_balance + COALESCE(SUM(amount),0) INTO v_balance
  FROM public.cash_sessions cs LEFT JOIN public.cash_movements cm ON cm.session_id = cs.id
  WHERE cs.id = v_session2_id GROUP BY opening_balance;
  IF v_balance <> -300 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426b-nueva): la sesión nueva debería terminar en -300 (compensó el sale_reversal), es %.', v_balance;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements
  WHERE session_id = v_session2_id AND movement_type = 'sale_reversal' AND reference_id = v_op4;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426b-mov): esperaba 1 sale_reversal en la sesión nueva, hay %.', v_count;
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session1_id AND movement_type = 'sale_reversal') THEN
    RAISE EXCEPTION 'GATE DGL FAILED (P0426b-cerrada): la sesión CERRADA no debe recibir el sale_reversal.';
  END IF;
  RAISE NOTICE 'PASS (P0426b): con una sesión abierta nueva, el borrado compensa ahí — la sesión cerrada y su arqueo quedan intactos.';

  -- ═══════════ (D8 + idempotencia) borrado del POS cancela la sales_order ════════════
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_id, v_account_id, v_client_id, v_product_id, 700, 1, 700, 'ARS', CURRENT_DATE, v_op5, v_branch_id)
  RETURNING id INTO v_sale5_id;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, sale_operation_id, created_by)
  VALUES (v_account_id, v_branch_id, v_client_id, 'confirmed', 700, v_op5, v_user_id)
  RETURNING id INTO v_so5_id;

  INSERT INTO public.journal_entries (account_id, posted_at, source_doc_type, source_doc_ref, status)
  VALUES (v_account_id, now(), 'SalesOrder', v_so5_id, 'posted')
  RETURNING id INTO v_entry1_id;
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no)
  VALUES (v_entry1_id, v_account_id, '1100', 'debit', 700, 1);
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no)
  VALUES (v_entry1_id, v_account_id, '4100', 'credit', 700, 2);

  v_result := public.rpc_delete_sale_operation(p_operation_id => v_op5);
  IF NOT v_result THEN
    RAISE EXCEPTION 'GATE DGL FAILED (D8): rpc_delete_sale_operation devolvió false para la venta POS.';
  END IF;

  SELECT status, sale_operation_id INTO v_so5_status, v_so5_op FROM public.sales_orders WHERE id = v_so5_id;
  IF v_so5_status <> 'canceled' THEN
    RAISE EXCEPTION 'GATE DGL FAILED (D8-status): sales_order esperada canceled, es %.', v_so5_status;
  END IF;
  IF v_so5_op IS NOT NULL THEN
    RAISE EXCEPTION 'GATE DGL FAILED (D8-unlink): sale_operation_id debería quedar NULL, es %.', v_so5_op;
  END IF;

  SELECT COUNT(*) INTO v_hist_count FROM public.document_status_history
  WHERE document_type = 'sales_order' AND document_id = v_so5_id
    AND from_status = 'confirmed' AND to_status = 'canceled';
  IF v_hist_count <> 1 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (D8-historial): esperaba 1 fila confirmed→canceled en document_status_history, hay %.', v_hist_count;
  END IF;
  RAISE NOTICE 'PASS (D8): borrar una venta del POS cancela su sales_order (status + desvínculo + transición registrada).';

  -- Contable: resuelve por la convención SalesOrder (segunda), y despachar el
  -- evento DOS veces no debe postear un segundo contra-asiento.
  PERFORM public.rpc_process_outbox_dispatch(1000);
  PERFORM public.rpc_process_outbox_dispatch(1000);  -- reproceso — no debe pasar nada

  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE reversal_of = v_entry1_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (D8-contable / idempotencia): esperaba EXACTAMENTE 1 contra-asiento tras dos dispatch, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (idempotencia): reprocesar el batch del outbox no duplica el contra-asiento del borrado.';

  -- ════════════════════ (compra) rpc_delete_purchase_operation ═══════════════
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id, supplier_id)
  VALUES (v_user_id, v_account_id, v_product_id, 600, 1, 600, '__gate_dgl_purchase__', CURRENT_DATE, v_op6, v_branch_id, v_supplier_id)
  RETURNING id INTO v_purchase6_id;

  INSERT INTO public.stock_movements
    (user_id, account_id, product_id, product_name, type, quantity_delta,
     quantity_before, quantity_after, reference_id, reference_type, branch_id)
  VALUES
    (v_user_id, v_account_id, v_product_id, '__gate_dgl_product__', 'purchase', 1,
     1000, 1001, v_purchase6_id, 'purchase', v_branch_id);
  UPDATE public.branch_stock SET quantity = 1001 WHERE branch_id = v_branch_id AND product_id = v_product_id;

  v_sa6_id := public.c30_get_or_create_supplier_account(v_account_id, v_supplier_id);
  PERFORM public.c30_register_supplier_account_movement(v_sa6_id, 600, 'purchase', v_op6);

  INSERT INTO public.journal_entries (account_id, posted_at, source_doc_type, source_doc_ref, status)
  VALUES (v_account_id, now(), 'Purchase', v_op6, 'posted')
  RETURNING id INTO v_entry6_id;
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
  VALUES (v_entry6_id, v_account_id, '5100', 'debit', 600, 1, NULL);
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
  VALUES (v_entry6_id, v_account_id, '2100', 'credit', 600, 2, NULL);

  v_result := public.rpc_delete_purchase_operation(p_operation_id => v_op6);
  IF NOT v_result THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra): rpc_delete_purchase_operation devolvió false.';
  END IF;

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa6_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra-saldo): saldo de proveedor esperado 0 tras borrar, es %.', v_balance;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.supplier_account_movements
    WHERE supplier_account_id = v_sa6_id AND movement_type = 'debit_note' AND amount = -600
  ) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra-debit_note): esperaba un movimiento debit_note(-600).';
  END IF;

  SELECT quantity INTO v_qty_after FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  IF v_qty_after <> 1000 THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra-stock): stock esperado 1000 tras borrar la compra, es %.', v_qty_after;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry6_id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra-contable): asiento Purchase original esperado reversed, es %.', v_orig_status;
  END IF;

  IF NOT EXISTS (
    SELECT 1 jl1 FROM public.journal_entries je
    JOIN public.journal_lines jl ON jl.entry_id = je.id AND jl.account_code = '5100' AND jl.cost_center_id IS NULL
    WHERE je.reversal_of = v_entry6_id
  ) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (compra-cost-center): cost_center_id (NULL en este fixture) debe preservarse en la reversión.';
  END IF;

  RAISE NOTICE 'PASS (compra): rpc_delete_purchase_operation revierte saldo de proveedor (debit_note), banco, stock y postea el contra-asiento Purchase preservando cost_center_id.';

  -- ════════════════════ (sin dinero) se borra como antes ═════════════════════
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_id, v_account_id, NULL, v_product_id, 100, 1, 100, 'ARS', CURRENT_DATE, v_op7, v_branch_id)
  RETURNING id INTO v_sale7_id;

  v_result := public.rpc_delete_sale_operation(p_operation_id => v_op7);
  IF NOT v_result OR EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale7_id) THEN
    RAISE EXCEPTION 'GATE DGL FAILED (sin-dinero): una venta sin dinero posteado debe borrarse igual que antes.';
  END IF;
  RAISE NOTICE 'PASS (sin dinero): venta sin cargo/caja/banco se borra sin generar movimientos financieros nuevos.';

  -- ════════════════════ (operación inexistente) ══════════════════════════════
  v_result := public.rpc_delete_sale_operation(p_sale_id => gen_random_uuid());
  IF v_result THEN
    RAISE EXCEPTION 'GATE DGL FAILED (inexistente): rpc_delete_sale_operation debería devolver false para un id inexistente.';
  END IF;
  RAISE NOTICE 'PASS (inexistente): id inexistente devuelve false, sin excepción — el service lo traduce a 404.';

  RAISE NOTICE 'PASS: gate delete-guard-ledgers completo — 4 libros compensados a la vez (estrella), P0423/P0425/P0426, cancelación de sales_order del POS + idempotencia del outbox, espejo de compra con debit_note y cost_center_id preservado, operación sin dinero, id inexistente.';
END $$;
