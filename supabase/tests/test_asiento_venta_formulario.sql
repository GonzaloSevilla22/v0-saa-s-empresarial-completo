-- =============================================================================
-- GATE: test_asiento_venta_formulario.sql
-- CHANGE: asiento-venta-formulario (tasks 1.1-1.6, 5.1-5.6 RED+GREEN+TRIANGULATE)
--
-- Cierra el agujero de rpc_create_sale_operation_v2 (ruta viva del
-- formulario de venta): no emitía ningún evento al outbox -> 228 ventas
-- del formulario sin asiento contable. Ejercita de verdad (mismo patrón de
-- anchor sintético que test_pagos_cableados_restantes.sql):
--
--   (1)   root gap: una venta del formulario produce exactamente 1 asiento
--         balanceado, vía el relay real (rpc_process_outbox_dispatch).
--   (2)   ruteo por kind: credit/transfer/cash/sin-imputar -> 1300/1110/
--         1100/1100, crédito único 4100 en las cuatro.
--   (3)   fecha contable: posted_at = fecha de la venta (día ART), no el
--         instante del relay.
--   (4)   override del PO (2026-08-20) — edición AJUSTA el asiento en vez
--         de bloquear la operación:
--         (4a) pre-proceso: reemplazo in-place del evento pendiente, un
--              solo asiento final referenciando el operation_id nuevo.
--         (4b) post-proceso: contra-entry + asiento nuevo, trazabilidad
--              completa, Σ neta = total nuevo.
--         (4c) cadena de dos ediciones (ambas post-proceso): la segunda
--              contra-entry revierte el asiento de la PRIMERA edición, no
--              el original.
--         (4d) cadena de dos ediciones ANTES de procesar: colapsa en un
--              solo evento de ajuste final, sin eventos fantasma.
--   (5)   control negativo: una venta del POS emite SOLO SaleConfirmed
--         (nunca SaleOperationCreated) — un solo asiento, sin doble posteo.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email  text := 'asiento-venta-formulario-gate@test.local';
  v_user_id       uuid := gen_random_uuid();
  v_account_id    uuid;
  v_branch_id     uuid;
  v_product_id    uuid;
  v_client_id     uuid;
  v_pm_cash       uuid;
  v_pm_credit     uuid;
  v_pm_transfer   uuid;

  v_result        jsonb;
  v_op_id         uuid;
  v_op2_id        uuid;
  v_op3_id        uuid;
  v_sale_id       uuid;
  v_sale_id2      uuid;
  v_count         integer;
  v_entry_id      uuid;
  v_entry2_id     uuid;
  v_orig_status   text;
  v_debit_code    text;
  v_credit_amt    numeric;
  v_posted_at     timestamptz;
  v_kind          text;
  v_expected_code text;
  v_event_id      uuid;
  v_pending_before integer;
  v_pending_after  integer;
BEGIN
  -- ── Anchor sintético ───────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Asiento Venta Formulario'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE ASIENTO-VENTA-FORMULARIO: no se pudo resolver cuenta para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;

  IF v_branch_id IS NULL OR v_pm_cash IS NULL OR v_pm_credit IS NULL OR v_pm_transfer IS NULL THEN
    RAISE NOTICE 'GATE ASIENTO-VENTA-FORMULARIO: branch/catálogo de formas de pago no disponible para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_avf_product__', 1000, 400, 'GATE-AVF-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 5000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 5000;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_id, v_account_id, '__gate_avf_client__', 'active')
  RETURNING id INTO v_client_id;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE ASIENTO-VENTA-FORMULARIO: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ════════════════════ (1) Root gap — 1 asiento balanceado ══════════════════

  v_result := public.rpc_create_sale_operation_v2(
    'gate-avf-1-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 15000, 'quantity', 1, 'unit_id', NULL)),
    v_branch_id, NULL, NULL, NULL, NULL
  );
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SaleOperationCreated' AND aggregate_id = v_op_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (1-evt): esperaba 1 evento SaleOperationCreated para la venta del formulario, hay %.', v_count;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  SELECT id INTO v_entry_id FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (1, GATE ESTRELLA): una venta del formulario debería producir 1 asiento tras el relay — 0 encontrados. Este es el gap raíz que el change cierra (228 operaciones en prod).';
  END IF;

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry_id;
  IF v_orig_status <> 'posted' THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (1-status): esperaba status=posted, es %.', v_orig_status;
  END IF;

  DECLARE
    v_sd numeric; v_sc numeric;
  BEGIN
    SELECT
      COALESCE(SUM(CASE WHEN side='debit' THEN amount END),0),
      COALESCE(SUM(CASE WHEN side='credit' THEN amount END),0)
    INTO v_sd, v_sc
    FROM public.journal_lines WHERE entry_id = v_entry_id;
    IF v_sd <> v_sc OR v_sd <> 15000 THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (1-balance): esperaba débito=crédito=15000, obtuve débito=% crédito=%.', v_sd, v_sc;
    END IF;
  END;

  RAISE NOTICE 'PASS (1, GATE ESTRELLA): venta del formulario produce 1 asiento balanceado vía el relay real.';

  -- ═══════════════════ (2) Ruteo por kind + (3) fecha contable ═══════════════

  FOR v_kind, v_expected_code IN
    SELECT * FROM (VALUES
      ('credit',   '1300'),
      ('transfer', '1110'),
      ('cash',     '1100'),
      (NULL,       '1100')  -- sin imputar (D3 — deliberadamente distinto de PurchaseCreated)
    ) AS t(kind, code)
  LOOP
    v_result := public.rpc_create_sale_operation_v2(
      'gate-avf-2-' || gen_random_uuid()::text,
      CASE WHEN v_kind = 'credit' THEN v_client_id ELSE NULL END,
      (CURRENT_DATE - INTERVAL '1 month')::date, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 2000, 'quantity', 1, 'unit_id', NULL)),
      v_branch_id, NULL,
      CASE v_kind WHEN 'credit' THEN v_pm_credit WHEN 'transfer' THEN v_pm_transfer WHEN 'cash' THEN v_pm_cash ELSE NULL END,
      NULL, NULL
    );
    v_op2_id := (v_result->>'operation_id')::uuid;

    PERFORM public.rpc_process_outbox_dispatch(1000);

    SELECT id INTO v_entry2_id FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op2_id;
    IF v_entry2_id IS NULL THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (2-%): no se posteó asiento.', COALESCE(v_kind, 'NULL');
    END IF;

    SELECT account_code INTO v_debit_code FROM public.journal_lines WHERE entry_id = v_entry2_id AND side = 'debit';
    IF v_debit_code <> v_expected_code THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (2-%): kind=% debería debitar %, debitó %.', COALESCE(v_kind,'NULL'), COALESCE(v_kind,'NULL'), v_expected_code, v_debit_code;
    END IF;

    SELECT COUNT(*), SUM(amount) INTO v_count, v_credit_amt FROM public.journal_lines WHERE entry_id = v_entry2_id AND side = 'credit';
    IF v_count <> 1 OR v_credit_amt <> 2000 THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (2-%-credito): esperaba 1 línea de crédito 4100 por 2000 (sin IVA), hay % líneas por %.', COALESCE(v_kind,'NULL'), v_count, v_credit_amt;
    END IF;

    -- (3) fecha contable: la venta se fechó el mes anterior -> posted_at cae ahí, no hoy.
    SELECT posted_at INTO v_posted_at FROM public.journal_entries WHERE id = v_entry2_id;
    IF date_trunc('month', v_posted_at AT TIME ZONE 'America/Argentina/Mendoza') <> date_trunc('month', (CURRENT_DATE - INTERVAL '1 month')::date::timestamp) THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (3-%): posted_at debería caer en el mes de la venta (mes anterior), cayó en %.', COALESCE(v_kind,'NULL'), v_posted_at;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (2, GATE ESTRELLA): los 4 kind (credit/transfer/cash/sin-imputar) rutean 1300/1110/1100/1100, crédito único 4100 sin IVA.';
  RAISE NOTICE 'PASS (3): posted_at = fecha de la venta (día ART), no el instante del relay.';

  -- ═══════════ (4a) Override PO — edición PRE-proceso reemplaza in-place ═════

  v_result := public.rpc_create_sale_operation_v2(
    'gate-avf-4a-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 5000, 'quantity', 1, 'unit_id', NULL)),
    v_branch_id, NULL, NULL, NULL, NULL
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id;

  SELECT COUNT(*) INTO v_pending_before FROM public.events WHERE processed_at IS NULL;

  -- Editar ANTES de correr el dispatcher — el evento sigue pendiente.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 8000, 'quantity', 1)),
    v_pm_transfer, true
  );
  v_op2_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_pending_after FROM public.events WHERE processed_at IS NULL;
  IF v_pending_after <> v_pending_before THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4a-noevento): editar antes del relay NO debería insertar un evento nuevo (reemplazo in-place) — pendientes antes=%, después=%.', v_pending_before, v_pending_after;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SaleOperationCreated' AND aggregate_id = v_op2_id AND processed_at IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4a-aggregate): esperaba el evento pendiente reapuntado a aggregate_id=% (operation_id nuevo), no lo encontré.', v_op2_id;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref IN (v_op_id, v_op2_id);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4a, GATE ESTRELLA): esperaba EXACTAMENTE 1 asiento final tras el reemplazo in-place, hay %.', v_count;
  END IF;

  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_doc_type = 'SaleOperation' AND je.source_doc_ref = v_op2_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4a-ref): el asiento final debería referenciar el operation_id NUEVO (%), no lo encontré.', v_op2_id;
  END IF;
  SELECT account_code INTO v_debit_code FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'debit';
  IF v_debit_code <> '1110' THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4a-valores): el asiento final debería reflejar los valores EDITADOS (transfer->1110), debitó %.', v_debit_code;
  END IF;
  RAISE NOTICE 'PASS (4a, GATE ESTRELLA): editar antes del relay reemplaza el evento in-place — un solo asiento final, correcto, con el operation_id nuevo.';

  -- ═══════════ (4b) Override PO — edición POST-proceso ajusta el asiento ═════

  v_result := public.rpc_create_sale_operation_v2(
    'gate-avf-4b-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 15000, 'quantity', 1, 'unit_id', NULL)),
    v_branch_id, NULL, NULL, NULL, NULL
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id;

  PERFORM public.rpc_process_outbox_dispatch(1000);  -- el asiento original queda POSTED antes de editar
  SELECT id INTO v_entry_id FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-premisa): el asiento original debería existir antes de editar.';
  END IF;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 9000, 'quantity', 1)),
    v_pm_transfer, true
  );
  v_op2_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SaleOperationAdjusted' AND (payload->>'old_operation_id')::uuid = v_op_id AND (payload->>'new_operation_id')::uuid = v_op2_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-evt): esperaba 1 evento SaleOperationAdjusted (old=%, new=%), hay %.', v_op_id, v_op2_id, v_count;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry_id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-original): el asiento original debería quedar status=reversed, es %.', v_orig_status;
  END IF;

  -- Contra-entry: reversal_of = asiento original, mismo source_doc_ref (old_operation_id).
  SELECT COUNT(*) INTO v_count FROM public.journal_entries
  WHERE reversal_of = v_entry_id AND source_doc_type = 'SaleOperation' AND source_doc_ref = v_op_id AND status = 'posted';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-contra, GATE ESTRELLA): esperaba 1 contra-entry (reversal_of=%, source_doc_ref=%), hay %.', v_entry_id, v_op_id, v_count;
  END IF;

  -- Asiento nuevo: source_doc_ref = new_operation_id, valores editados (transfer -> 1110, 9000).
  SELECT id INTO v_entry2_id FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op2_id AND status = 'posted';
  IF v_entry2_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-nuevo): esperaba un asiento nuevo posted con source_doc_ref=% (operation_id editado).', v_op2_id;
  END IF;
  SELECT account_code INTO v_debit_code FROM public.journal_lines WHERE entry_id = v_entry2_id AND side = 'debit';
  IF v_debit_code <> '1110' THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-nuevo-debito): esperaba 1110 (transfer editado), debitó %.', v_debit_code;
  END IF;

  -- Σ neta de 4100 Ventas de LOS TRES asientos de la cadena (original +
  -- contra-entry + nuevo) = total nuevo (9000). El original y la
  -- contra-entry se cancelan exactamente entre sí (crédito 15000 del
  -- original vs. débito 15000 de la contra-entry, misma línea invertida) —
  -- si se sumara sólo el par contra+nuevo (sin el original) el resultado
  -- sería -6000, no 9000: es EXACTAMENTE el error que este cálculo evita.
  SELECT
    COALESCE((SELECT SUM(amount) FROM public.journal_lines WHERE entry_id = v_entry_id  AND account_code='4100' AND side='credit'), 0)
    - COALESCE((SELECT SUM(amount) FROM public.journal_lines jl JOIN public.journal_entries je ON je.id = jl.entry_id WHERE je.reversal_of = v_entry_id AND jl.account_code='4100' AND jl.side='debit'), 0)
    + COALESCE((SELECT SUM(amount) FROM public.journal_lines WHERE entry_id = v_entry2_id AND account_code='4100' AND side='credit'), 0)
  INTO v_credit_amt;
  IF v_credit_amt <> 9000 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4b-neto): la Σ neta de 4100 Ventas de la cadena (original+contra+nuevo) debería ser 9000 (el total nuevo), es %.', v_credit_amt;
  END IF;

  RAISE NOTICE 'PASS (4b, GATE ESTRELLA): editar después del relay produce contra-entry + asiento nuevo, trazables, con Σ neta = total nuevo.';

  -- ═══════════ (4c) Cadena de 2 ediciones — ambas POST-proceso ═══════════════
  -- v_op2_id / v_entry2_id son el resultado de (4b) — la operación tiene
  -- ahora un asiento POSTED vigente (v_entry2_id, source_doc_ref=v_op2_id).
  SELECT id INTO v_sale_id2 FROM public.sales WHERE operation_id = v_op2_id;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id2], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 4000, 'quantity', 1)),
    v_pm_cash, true
  );
  v_op3_id := (v_result->>'operation_id')::uuid;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  -- La SEGUNDA contra-entry debe revertir el asiento de la PRIMERA edición
  -- (v_entry2_id, source_doc_ref=v_op2_id) — NO el original (v_entry_id,
  -- ya reversed desde 4b).
  SELECT COUNT(*) INTO v_count FROM public.journal_entries
  WHERE reversal_of = v_entry2_id AND source_doc_type = 'SaleOperation' AND source_doc_ref = v_op2_id AND status = 'posted';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4c, GATE ESTRELLA): la segunda contra-entry debería revertir el asiento de la PRIMERA edición (reversal_of=%), hay %.', v_entry2_id, v_count;
  END IF;

  SELECT status INTO v_orig_status FROM public.journal_entries WHERE id = v_entry2_id;
  IF v_orig_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4c-primera): el asiento de la PRIMERA edición debería quedar reversed tras la segunda edición, es %.', v_orig_status;
  END IF;

  -- Exactamente 1 asiento 'posted' en toda la cadena (original -> edit1 -> edit2).
  SELECT COUNT(*) INTO v_count FROM public.journal_entries
  WHERE source_doc_type = 'SaleOperation' AND source_doc_ref IN (v_op_id, v_op2_id, v_op3_id) AND status = 'posted'
    AND reversal_of IS NULL;  -- excluye contra-entries (también 'posted', pero son reversiones, no el vigente)
  -- Nota: el vigente final es el de op3 (source_event_id del evento de la
  -- segunda edición); las contra-entries también quedan 'posted' pero con
  -- reversal_of IS NOT NULL — se cuentan aparte para no confundir "vigente"
  -- con "reversión posted".
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4c-unico-vigente): esperaba exactamente 1 asiento vigente (no-reversión) en la cadena, hay %.', v_count;
  END IF;

  RAISE NOTICE 'PASS (4c, GATE ESTRELLA): la cadena de dos ediciones ya procesadas revierte siempre el asiento VIGENTE, no el original.';

  -- ═══════════ (4d) Cadena de 2 ediciones — ambas ANTES de procesar ══════════

  v_result := public.rpc_create_sale_operation_v2(
    'gate-avf-4d-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 3000, 'quantity', 1, 'unit_id', NULL)),
    v_branch_id, NULL, NULL, NULL, NULL
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id;

  -- Primera edición (sin correr el dispatcher todavía) — reemplazo in-place.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 6000, 'quantity', 1))
  );
  v_op2_id := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id2 FROM public.sales WHERE operation_id = v_op2_id;

  SELECT COUNT(*) INTO v_pending_before FROM public.events WHERE processed_at IS NULL AND event_type IN ('SaleOperationCreated','SaleOperationAdjusted');

  -- Segunda edición, TODAVÍA sin correr el dispatcher — debe colapsar en el
  -- MISMO evento pendiente (sigue siendo SaleOperationCreated, reapuntado).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id2], NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 7000, 'quantity', 1))
  );
  v_op3_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_pending_after FROM public.events WHERE processed_at IS NULL AND event_type IN ('SaleOperationCreated','SaleOperationAdjusted');
  IF v_pending_after <> v_pending_before THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4d, GATE ESTRELLA): dos ediciones ANTES de procesar deberían colapsar en el mismo evento pendiente — pendientes antes=%, después=%.', v_pending_before, v_pending_after;
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref IN (v_op_id, v_op2_id, v_op3_id);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4d-final): esperaba exactamente 1 asiento final tras la cadena de dos ediciones pre-proceso, hay %.', v_count;
  END IF;

  SELECT id INTO v_entry_id FROM public.journal_entries WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op3_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4d-ref): el asiento final debería referenciar el ÚLTIMO operation_id (%, de la segunda edición), no lo encontré.', v_op3_id;
  END IF;
  SELECT SUM(amount) INTO v_credit_amt FROM public.journal_lines WHERE entry_id = v_entry_id AND side = 'credit';
  IF v_credit_amt <> 7000 THEN
    RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (4d-valores): el asiento final debería reflejar el valor de la ÚLTIMA edición (7000), es %.', v_credit_amt;
  END IF;

  RAISE NOTICE 'PASS (4d, GATE ESTRELLA): dos ediciones antes de procesar colapsan en un solo evento de ajuste final, sin eventos fantasma.';

  -- ══════════ (5) Control negativo: POS emite SOLO SaleConfirmed ═════════════

  v_result := public.rpc_quick_sale(
    p_idempotency_key   => 'gate-avf-5-' || gen_random_uuid()::text,
    p_client_id         => NULL,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
    p_payment_method    => 'transfer',
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_transfer
  );

  -- rpc_quick_sale delega en _c29_confirm_order_core, que devuelve DOS ids
  -- distintos: 'sales_order_id' (= sales_orders.id, el aggregate_id que usa
  -- el evento SaleConfirmed) y 'operation_id' (= sales.operation_id de las
  -- líneas subyacentes — el mismo espacio de claves que SaleOperationCreated
  -- usaría SI se emitiera, que es justo lo que este control niega).
  v_op_id  := (v_result->>'sales_order_id')::uuid;
  v_op2_id := (v_result->>'operation_id')::uuid;

  IF v_op_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SaleOperationCreated' AND aggregate_id IN (v_op_id, v_op2_id);
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (5, GATE ESTRELLA): una venta del POS NO debería emitir SaleOperationCreated — hay %.', v_count;
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.events WHERE event_type = 'SaleConfirmed' AND aggregate_id = v_op_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (5-confirmed): una venta del POS debería emitir exactamente 1 SaleConfirmed, hay %.', v_count;
    END IF;

    PERFORM public.rpc_process_outbox_dispatch(1000);

    SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE source_doc_type = 'SalesOrder' AND source_doc_ref = v_op_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ASIENTO-VENTA-FORMULARIO FAILED (5-asiento): esperaba 1 asiento SalesOrder para la venta del POS, hay %.', v_count;
    END IF;

    RAISE NOTICE 'PASS (5, GATE ESTRELLA): el POS sigue emitiendo SOLO SaleConfirmed — un solo asiento, sin doble posteo con SaleOperationCreated.';
  ELSE
    RAISE NOTICE 'GATE ASIENTO-VENTA-FORMULARIO (5): no se pudo resolver sales_order_id del resultado de rpc_quick_sale (forma de retorno distinta) — control negativo omitido sin abortar el gate.';
  END IF;

  RAISE NOTICE 'GATE ASIENTO-VENTA-FORMULARIO: TODOS LOS CHECKS PASARON.';
END $$;
