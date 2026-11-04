-- =============================================================================
-- GATE: test_journal_consumer_edicion.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 3 (tasks 3.1-3.3)
--
-- El consumidor contable (`_journal_post_from_event`) cuando el identificador de operacion es ESTABLE y la
-- compra tambien se ajusta:
--
--  (B1) SaleOperationDeleted / (B5) PurchaseDeleted / (B2) SaleOperationAdjusted localizan el asiento VIGENTE
--       con `reversal_of IS NULL`. Con un id estable, despues de una edicion hay para la misma referencia el
--       original (reversed), su contra-asiento (posted, reversal_of <> NULL) y el asiento nuevo (posted): sin ese
--       filtro `LIMIT 1` puede elegir el contra-asiento y revertir lo que ya estaba revertido.
--  (B3) SaleOperationAdjusted resuelve las DOS convenciones (SaleOperation por operation_id; SalesOrder por
--       sales_order_id del payload): una venta del POS editada ajusta su asiento SaleConfirmed.
--  (B4) CreditNoteIssued tambien resuelve (SaleOperation, sales_orders.sale_operation_id): una venta del POS
--       editada y facturada tiene su asiento vigente como SaleOperation; antes reintentaba P0451 para siempre.
--  (B6) PurchaseAdjusted: rama nueva = revertir como PurchaseDeleted + postear como PurchaseCreated.
--  (B7) El despachador la rutea (Consumer 3): el filtro de event_type del despachador y el del helper listan
--       el MISMO conjunto de 15 tipos (el invariante lo fija ademas test_cobranzas_reverso.sql, bloque 11).
--
-- Una transaccion que termina en ROLLBACK (sin residuo, asertado al final).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.post(p_acc uuid, p_type text, p_agg_type text, p_agg uuid, p_payload jsonb)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_before uuid[];
  v_ev     public.events%ROWTYPE;
  v_id     uuid;
  v_out    text;
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_before FROM public.journal_entries WHERE account_id = p_acc;
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (p_acc, p_type, p_agg_type, p_agg, p_payload, now()) RETURNING id INTO v_id;
  SELECT * INTO v_ev FROM public.events WHERE id = v_id;
  PERFORM public._journal_post_from_event(v_ev);
  SELECT string_agg(x.d, ' | ' ORDER BY x.k) INTO v_out
  FROM (
    SELECT (CASE WHEN je.reversal_of IS NULL THEN '2' ELSE '1' END) || je.source_doc_type || je.id::text AS k,
           (CASE WHEN je.reversal_of IS NULL THEN 'N:' ELSE 'R:' END) || je.source_doc_type || ':' ||
           (SELECT string_agg(jl.account_code || upper(left(jl.side, 1)) || trim_scale(jl.amount)::text, ',' ORDER BY jl.account_code, jl.side)
              FROM public.journal_lines jl WHERE jl.entry_id = je.id) AS d
    FROM public.journal_entries je
    WHERE je.account_id = p_acc AND NOT (je.id = ANY (v_before))
  ) x;
  RETURN COALESCE(v_out, '(sin asiento)');
END $f$;

CREATE FUNCTION pg_temp.expect(p_label text, p_got text, p_want text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_want THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (%): esperaba [%] y posteo [%]', p_label, p_want, p_got;
  END IF;
  RAISE NOTICE 'PASS (%): %', p_label, p_got;
END $f$;

-- Un asiento posteado a mano (como lo dejaria el consumidor), con sus lineas.
CREATE FUNCTION pg_temp.entry(p_acc uuid, p_doc text, p_ref uuid, p_status text, p_reversal_of uuid,
                              p_debit_code text, p_credit_code text, p_amount numeric) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.journal_entries (account_id, posted_at, source_doc_type, source_doc_ref, status, reversal_of)
  VALUES (p_acc, now(), p_doc, p_ref, p_status, p_reversal_of) RETURNING id INTO v_id;
  INSERT INTO public.journal_lines (entry_id, account_id, account_code, side, amount, line_no)
  VALUES (v_id, p_acc, p_debit_code,  CASE WHEN p_reversal_of IS NULL THEN 'debit'  ELSE 'credit' END, p_amount, 1),
         (v_id, p_acc, p_credit_code, CASE WHEN p_reversal_of IS NULL THEN 'credit' ELSE 'debit'  END, p_amount, 2);
  RETURN v_id;
END $f$;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_d    date := CURRENT_DATE;
  v_cc   uuid;
  v_out  text;
  v_n    int;
  v_op   uuid; v_e1 uuid; v_r1 uuid; v_e2 uuid; v_so uuid; v_ev uuid; v_sqlstate text;
  v_client uuid;
  v_branch uuid;
  v_pa uuid; v_ra uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'journal-edicion@test.local', now(), now(), jsonb_build_object('name', 'Gate Journal Edicion'));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: sin cuenta'; END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_acc LIMIT 1;
  INSERT INTO public.cost_centers (account_id, name) VALUES (v_acc, '__cc__') RETURNING id INTO v_cc;
  INSERT INTO public.clients (user_id, account_id, name, status) VALUES (v_user, v_acc, '__c__', 'active') RETURNING id INTO v_client;

  -- ═══ B1: SaleOperationDeleted con id estable: original (reversed), contra (posted), nuevo (posted) ═══════
  v_op := gen_random_uuid();
  v_e1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1000);
  v_r1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', v_e1, '1300', '4100', 1000);
  UPDATE public.journal_entries SET status = 'reversed' WHERE id = v_e1;
  v_e2 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1200);
  v_out := pg_temp.post(v_acc, 'SaleOperationDeleted', 'SaleOperation', v_op, jsonb_build_object('operation_id', v_op));
  PERFORM pg_temp.expect('B1 SaleOperationDeleted revierte el asiento VIGENTE (1200), no el contra-asiento', v_out,
    'R:SaleOperation:1300C1200,4100D1200');
  IF (SELECT status FROM public.journal_entries WHERE id = v_e2) <> 'reversed'
     OR NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE reversal_of = v_e2)
     OR EXISTS (SELECT 1 FROM public.journal_entries WHERE reversal_of = v_r1) THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B1-vigente): el contra-asiento debia apuntar al asiento vigente (reversal_of = e2) y nunca al contra-asiento anterior';
  END IF;

  -- ═══ B2: SaleOperationAdjusted con id estable (old = new) ══════════════════════════════════════════════
  v_op := gen_random_uuid();
  v_e1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1000);
  v_r1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', v_e1, '1300', '4100', 1000);
  UPDATE public.journal_entries SET status = 'reversed' WHERE id = v_e1;
  v_e2 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1200);
  v_out := pg_temp.post(v_acc, 'SaleOperationAdjusted', 'SaleOperation', v_op,
    jsonb_build_object('old_operation_id', v_op, 'new_operation_id', v_op, 'total', 900, 'payment_method', 'cash', 'sale_date', v_d));
  PERFORM pg_temp.expect('B2 SaleOperationAdjusted con id estable', v_out,
    'R:SaleOperation:1300C1200,4100D1200 | N:SaleOperation:1100D900,4100C900');
  SELECT count(*) INTO v_n FROM public.journal_entries
   WHERE source_doc_type = 'SaleOperation' AND source_doc_ref = v_op AND status = 'posted' AND reversal_of IS NULL;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B2-unico): debia quedar UN solo asiento vigente de la operacion, hay %', v_n;
  END IF;

  -- ═══ B3: SaleOperationAdjusted de una venta del POS (asiento SalesOrder) ═══════════════════════════════
  v_op := gen_random_uuid(); v_so := gen_random_uuid();
  v_e1 := pg_temp.entry(v_acc, 'SalesOrder', v_so, 'posted', NULL, '1100', '4100', 1000);
  v_out := pg_temp.post(v_acc, 'SaleOperationAdjusted', 'SaleOperation', v_op,
    jsonb_build_object('old_operation_id', v_op, 'new_operation_id', v_op, 'sales_order_id', v_so,
                       'total', 1400, 'payment_method', 'transfer', 'sale_date', v_d));
  PERFORM pg_temp.expect('B3 SaleOperationAdjusted de una venta del POS (SalesOrder)', v_out,
    'R:SalesOrder:1100C1000,4100D1000 | N:SaleOperation:1110D1400,4100C1400');
  IF (SELECT status FROM public.journal_entries WHERE id = v_e1) <> 'reversed'
     OR NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_doc_type = 'SalesOrder' AND source_doc_ref = v_so AND reversal_of = v_e1) THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B3-contra): el contra-asiento debia conservar el tipo y la referencia del asiento SalesOrder revertido';
  END IF;

  -- ═══ B4: CreditNoteIssued sobre una venta cuyo asiento vigente es SaleOperation ════════════════════════
  v_op := gen_random_uuid(); v_so := gen_random_uuid();
  INSERT INTO public.sales_orders (id, account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_so, v_acc, v_branch, v_client, 'confirmed', 1000, v_user, v_op);
  v_e1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1000);
  v_r1 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', v_e1, '1300', '4100', 1000);
  UPDATE public.journal_entries SET status = 'reversed' WHERE id = v_e1;
  v_e2 := pg_temp.entry(v_acc, 'SaleOperation', v_op, 'posted', NULL, '1300', '4100', 1300);
  v_out := pg_temp.post(v_acc, 'CreditNoteIssued', 'SalesOrder', v_so,
    jsonb_build_object('source_sales_order_id', v_so, 'source_fiscal_document_id', gen_random_uuid()));
  PERFORM pg_temp.expect('B4 CreditNoteIssued resuelve el asiento SaleOperation vigente', v_out,
    'R:CreditNote:1300C1300,4100D1300');
  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE reversal_of = v_e2) OR EXISTS (SELECT 1 FROM public.journal_entries WHERE reversal_of = v_r1 AND source_doc_type = 'CreditNote') THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B4-vigente): la nota de credito debia revertir el asiento vigente (e2)';
  END IF;
  -- sin ningun asiento vigente: sigue reintentando (P0451)
  v_so := gen_random_uuid();
  BEGIN
    PERFORM pg_temp.post(v_acc, 'CreditNoteIssued', 'SalesOrder', v_so,
      jsonb_build_object('source_sales_order_id', v_so, 'source_fiscal_document_id', gen_random_uuid()));
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B4-sin-asiento): debia levantar P0451';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0451' THEN RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B4-sin-asiento): esperaba P0451 y levanto % (%)', v_sqlstate, SQLERRM; END IF;
  END;

  -- ═══ B5: PurchaseDeleted / ExpenseDeleted con asiento vigente entre original y contra ═════════════════
  v_pa := gen_random_uuid();
  v_e1 := pg_temp.entry(v_acc, 'Purchase', v_pa, 'posted', NULL, '5100', '1100', 500);
  v_r1 := pg_temp.entry(v_acc, 'Purchase', v_pa, 'posted', v_e1, '5100', '1100', 500);
  UPDATE public.journal_entries SET status = 'reversed' WHERE id = v_e1;
  v_e2 := pg_temp.entry(v_acc, 'Purchase', v_pa, 'posted', NULL, '5100', '2100', 700);
  v_out := pg_temp.post(v_acc, 'PurchaseDeleted', 'Purchase', v_pa, jsonb_build_object('operation_id', v_pa));
  PERFORM pg_temp.expect('B5 PurchaseDeleted revierte el asiento vigente (700)', v_out, 'R:Purchase:2100D700,5100C700');

  -- ═══ B6: PurchaseAdjusted ═════════════════════════════════════════════════════════════════════════════
  -- (a) efectivo -> efectivo
  v_pa := gen_random_uuid();
  PERFORM pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa,
    jsonb_build_object('operation_id', v_pa, 'total', 1000, 'payment_method', 'cash', 'cost_center_id', v_cc));
  v_out := pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
    jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 1500, 'payment_method', 'cash', 'cost_center_id', v_cc));
  PERFORM pg_temp.expect('B6a PurchaseAdjusted efectivo->efectivo', v_out,
    'R:Purchase:1100D1000,5100C1000 | N:Purchase:1100C1500,5100D1500');
  IF NOT EXISTS (SELECT 1 FROM public.journal_lines jl JOIN public.journal_entries je ON je.id = jl.entry_id
                  WHERE je.source_doc_ref = v_pa AND je.reversal_of IS NULL AND je.status = 'posted' AND jl.account_code = '5100' AND jl.cost_center_id = v_cc) THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6a-cc): el asiento nuevo debia conservar el centro de costo en 5100';
  END IF;
  -- (b) efectivo -> credito (otra operacion, ids distintos como en la tanda A)
  v_pa := gen_random_uuid(); v_ra := gen_random_uuid();
  PERFORM pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa,
    jsonb_build_object('operation_id', v_pa, 'total', 1000, 'payment_method', 'cash'));
  v_out := pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
    jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_ra, 'total', 1000, 'payment_method', 'credit'));
  PERFORM pg_temp.expect('B6b PurchaseAdjusted efectivo->credito (id nuevo)', v_out,
    'R:Purchase:1100D1000,5100C1000 | N:Purchase:2100C1000,5100D1000');
  IF NOT EXISTS (SELECT 1 FROM public.journal_entries WHERE source_doc_type = 'Purchase' AND source_doc_ref = v_ra AND status = 'posted' AND reversal_of IS NULL) THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6b-ref): el asiento nuevo debia quedar bajo el new_operation_id';
  END IF;
  -- (c) con IVA
  v_pa := gen_random_uuid();
  PERFORM pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa,
    jsonb_build_object('operation_id', v_pa, 'total', 1210, 'neto', 1000, 'iva_amount', 210, 'payment_method', 'cash'));
  v_out := pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
    jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 2420, 'neto', 2000, 'iva_amount', 420, 'payment_method', 'cash'));
  PERFORM pg_temp.expect('B6c PurchaseAdjusted con IVA', v_out,
    'R:Purchase:1100D1210,5100C1000,5200C210 | N:Purchase:1100C2420,5100D2000,5200D420');
  -- (d) adelantado al alta: sin el asiento original reintenta (P0451) y no deja nada; despues del alta, funciona
  v_pa := gen_random_uuid();
  BEGIN
    PERFORM pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
      jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 100, 'payment_method', 'cash'));
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6d): PurchaseAdjusted sin el alta debia levantar P0451';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0451' THEN RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6d): esperaba P0451 y levanto % (%)', v_sqlstate, SQLERRM; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.journal_entries WHERE source_doc_ref = v_pa) THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6d-limpio): el reintento no debia dejar asientos';
  END IF;
  PERFORM pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa, jsonb_build_object('operation_id', v_pa, 'total', 100, 'payment_method', 'cash'));
  v_out := pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
    jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 100, 'payment_method', 'credit'));
  PERFORM pg_temp.expect('B6d PurchaseAdjusted despues del alta', v_out, 'R:Purchase:1100D100,5100C100 | N:Purchase:2100C100,5100D100');
  -- (e) doble proceso del mismo evento: idempotente
  SELECT id INTO v_ev FROM public.events WHERE event_type = 'PurchaseAdjusted' AND aggregate_id = v_pa ORDER BY created_at DESC LIMIT 1;
  SELECT count(*) INTO v_n FROM public.journal_entries WHERE account_id = v_acc;
  PERFORM public._journal_post_from_event((SELECT e FROM public.events e WHERE e.id = v_ev));
  IF (SELECT count(*) FROM public.journal_entries WHERE account_id = v_acc) <> v_n THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6e): reprocesar el mismo evento no debe postear de nuevo';
  END IF;
  -- (f) balance: neto + iva distintos del total -> P0450
  v_pa := gen_random_uuid();
  PERFORM pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa, jsonb_build_object('operation_id', v_pa, 'total', 100, 'payment_method', 'cash'));
  BEGIN
    PERFORM pg_temp.post(v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
      jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 1000, 'neto', 1000, 'iva_amount', 210, 'payment_method', 'cash'));
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6f): un asiento que no balancea debia levantar P0450';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0450' THEN RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B6f): esperaba P0450 y levanto % (%)', v_sqlstate, SQLERRM; END IF;
  END;

  -- ═══ B7: el despachador ruta PurchaseAdjusted (Consumer 3) ═════════════════════════════════════════════
  v_pa := gen_random_uuid();
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'PurchaseCreated', 'Purchase', v_pa, jsonb_build_object('operation_id', v_pa, 'total', 300, 'payment_method', 'cash'), now() - interval '2 seconds');
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'PurchaseAdjusted', 'Purchase', v_pa,
          jsonb_build_object('old_operation_id', v_pa, 'new_operation_id', v_pa, 'total', 350, 'payment_method', 'cash'), now() - interval '1 second');
  PERFORM public.rpc_process_outbox_dispatch(10000);
  SELECT count(*) INTO v_n FROM public.journal_entries WHERE account_id = v_acc AND source_doc_ref = v_pa;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B7): el despachador debia postear alta + contra-asiento + asiento nuevo (3), hay %', v_n;
  END IF;
  IF EXISTS (SELECT 1 FROM public.events WHERE account_id = v_acc AND processed_at IS NULL AND event_type = 'PurchaseAdjusted') THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (B7-procesado): el PurchaseAdjusted debia quedar procesado';
  END IF;
  RAISE NOTICE 'PASS (B7): el despachador ruta PurchaseAdjusted.';
END $$;

ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'journal-edicion@test.local') THEN
    RAISE EXCEPTION 'GATE JOURNAL-EDICION FAILED (cleanup): quedo el anchor';
  END IF;
  RAISE NOTICE 'PASS: gate journal-consumer-edicion completo y sin residuo.';
END $$;
