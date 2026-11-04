-- =============================================================================
-- GATE: test_journal_consumer_noregression.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 3 (task 3.2: "las demas ramas quedan byte a byte")
--
-- Postea UN evento de cada uno de los 14 tipos que `_journal_post_from_event` ya consumia y compara el asiento
-- resultante (tipo/referencia de documento, contra-asiento o asiento nuevo, lineas cuenta/lado/importe) con el
-- esperado. Es la red de la reescritura del consumidor: las ramas que NO cambian tienen que seguir posteando
-- exactamente lo mismo.
--
-- Este archivo se corrio TAMBIEN contra el cuerpo previo (evidence/tanda-a/_journal_post_from_event.prev.sql,
-- md5 d7bfbb92...) antes de tocar nada: las mismas 14 expectativas pasan con el cuerpo viejo y con el nuevo.
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
    RAISE EXCEPTION 'GATE JOURNAL-NOREGRESSION FAILED (%): esperaba [%] y posteo [%]', p_label, p_want, p_got;
  END IF;
  RAISE NOTICE 'PASS (%): %', p_label, p_got;
END $f$;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_so   uuid := gen_random_uuid();
  v_opx  uuid := gen_random_uuid();
  v_opy  uuid := gen_random_uuid();
  v_pa   uuid := gen_random_uuid();
  v_pb   uuid := gen_random_uuid();
  v_pay1 uuid := gen_random_uuid();
  v_pay2 uuid := gen_random_uuid();
  v_e1   uuid := gen_random_uuid();
  v_e2   uuid := gen_random_uuid();
  v_cc   uuid;
  v_d    date := CURRENT_DATE;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'journal-noreg@test.local', now(), now(), jsonb_build_object('name', 'Gate Journal Noreg'));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION 'SETUP FAILED: sin cuenta'; END IF;
  INSERT INTO public.cost_centers (account_id, name) VALUES (v_acc, '__cc__') RETURNING id INTO v_cc;

  -- 1 SaleConfirmed (POS, transferencia) -> 1110 / 4100
  PERFORM pg_temp.expect('SaleConfirmed',
    pg_temp.post(v_acc, 'SaleConfirmed', 'SalesOrder', v_so,
      jsonb_build_object('sales_order_id', v_so, 'total', 1000, 'payment_method', 'transfer')),
    'N:SalesOrder:1110D1000,4100C1000');

  -- 2 PurchaseCreated (efectivo, con desglose) -> 5100 + 5200 / 1100
  PERFORM pg_temp.expect('PurchaseCreated',
    pg_temp.post(v_acc, 'PurchaseCreated', 'Purchase', v_pa,
      jsonb_build_object('operation_id', v_pa, 'total', 1210, 'neto', 1000, 'iva_amount', 210, 'payment_method', 'cash', 'cost_center_id', v_cc)),
    'N:Purchase:1100C1210,5100D1000,5200D210');

  -- 3 SaleOperationCreated (a credito) -> 1300 / 4100
  PERFORM pg_temp.expect('SaleOperationCreated',
    pg_temp.post(v_acc, 'SaleOperationCreated', 'SaleOperation', v_opx,
      jsonb_build_object('operation_id', v_opx, 'total', 800, 'payment_method', 'credit', 'sale_date', v_d)),
    'N:SaleOperation:1300D800,4100C800');
  PERFORM pg_temp.expect('SaleOperationCreated (segunda, para el borrado)',
    pg_temp.post(v_acc, 'SaleOperationCreated', 'SaleOperation', v_opy,
      jsonb_build_object('operation_id', v_opy, 'total', 600, 'payment_method', 'cash', 'sale_date', v_d)),
    'N:SaleOperation:1100D600,4100C600');

  -- 4 SaleOperationAdjusted (ids distintos, como hoy) -> contra del viejo + asiento nuevo
  PERFORM pg_temp.expect('SaleOperationAdjusted',
    pg_temp.post(v_acc, 'SaleOperationAdjusted', 'SaleOperation', v_opx,
      jsonb_build_object('old_operation_id', v_opx, 'new_operation_id', gen_random_uuid(), 'total', 900, 'payment_method', 'transfer', 'sale_date', v_d)),
    'R:SaleOperation:1300C800,4100D800 | N:SaleOperation:1110D900,4100C900');

  -- 5 PaymentReceived / 6 PaymentMade
  PERFORM pg_temp.expect('PaymentReceived',
    pg_temp.post(v_acc, 'PaymentReceived', 'CustomerAccount', v_pay1,
      jsonb_build_object('payment_id', v_pay1, 'amount', 300, 'payment_method', 'cash')),
    'N:CustomerAccount:1100D300,1300C300');
  PERFORM pg_temp.expect('PaymentMade',
    pg_temp.post(v_acc, 'PaymentMade', 'SupplierAccount', v_pay2,
      jsonb_build_object('payment_id', v_pay2, 'amount', 200, 'payment_method', 'transfer')),
    'N:SupplierAccount:1110C200,2100D200');

  -- 7 CreditNoteIssued: revierte el asiento del SaleConfirmed de arriba
  PERFORM pg_temp.expect('CreditNoteIssued',
    pg_temp.post(v_acc, 'CreditNoteIssued', 'SalesOrder', v_so,
      jsonb_build_object('source_sales_order_id', v_so, 'source_fiscal_document_id', gen_random_uuid())),
    'R:CreditNote:1110C1000,4100D1000');

  -- 8 SaleOperationDeleted / 9 PurchaseDeleted
  PERFORM pg_temp.expect('SaleOperationDeleted',
    pg_temp.post(v_acc, 'SaleOperationDeleted', 'SaleOperation', v_opy,
      jsonb_build_object('operation_id', v_opy, 'sales_order_id', NULL)),
    'R:SaleOperation:1100C600,4100D600');
  PERFORM pg_temp.expect('PurchaseDeleted',
    pg_temp.post(v_acc, 'PurchaseDeleted', 'Purchase', v_pa, jsonb_build_object('operation_id', v_pa)),
    'R:Purchase:1100D1210,5100C1000,5200C210');

  -- 10 PaymentReceivedReversed / 11 PaymentMadeReversed
  PERFORM pg_temp.expect('PaymentReceivedReversed',
    pg_temp.post(v_acc, 'PaymentReceivedReversed', 'CustomerAccount', v_pay1, jsonb_build_object('payment_id', v_pay1)),
    'R:CustomerAccount:1100C300,1300D300');
  PERFORM pg_temp.expect('PaymentMadeReversed',
    pg_temp.post(v_acc, 'PaymentMadeReversed', 'SupplierAccount', v_pay2, jsonb_build_object('payment_id', v_pay2)),
    'R:SupplierAccount:1110D200,2100C200');

  -- 12 ExpenseCreated / 13 ExpenseAdjusted / 14 ExpenseDeleted
  PERFORM pg_temp.expect('ExpenseCreated',
    pg_temp.post(v_acc, 'ExpenseCreated', 'Expense', v_e1,
      jsonb_build_object('expense_id', v_e1, 'amount', 500, 'kind', 'cash', 'cost_center_id', v_cc, 'expense_date', v_d)),
    'N:Expense:1100C500,5300D500');
  PERFORM pg_temp.expect('ExpenseAdjusted',
    pg_temp.post(v_acc, 'ExpenseAdjusted', 'Expense', v_e1,
      jsonb_build_object('expense_id', v_e1, 'amount', 300, 'kind', 'transfer', 'cost_center_id', v_cc, 'expense_date', v_d)),
    'R:Expense:1100D500,5300C500 | N:Expense:1110C300,5300D300');
  PERFORM pg_temp.expect('ExpenseCreated (segundo, para el borrado)',
    pg_temp.post(v_acc, 'ExpenseCreated', 'Expense', v_e2,
      jsonb_build_object('expense_id', v_e2, 'amount', 120, 'kind', 'cash', 'expense_date', v_d)),
    'N:Expense:1100C120,5300D120');
  PERFORM pg_temp.expect('ExpenseDeleted',
    pg_temp.post(v_acc, 'ExpenseDeleted', 'Expense', v_e2, jsonb_build_object('expense_id', v_e2)),
    'R:Expense:1100D120,5300C120');

  -- Un tipo fuera de alcance sigue siendo no-op
  PERFORM pg_temp.expect('tipo fuera de alcance',
    pg_temp.post(v_acc, 'SomethingElse', 'X', gen_random_uuid(), '{}'::jsonb),
    '(sin asiento)');
  RAISE NOTICE 'PASS: las 14 ramas preexistentes de _journal_post_from_event postean lo de siempre.';
END $$;

ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'journal-noreg@test.local') THEN
    RAISE EXCEPTION 'GATE JOURNAL-NOREGRESSION FAILED (cleanup): quedo el anchor';
  END IF;
  RAISE NOTICE 'PASS: gate journal-consumer-noregression completo y sin residuo.';
END $$;
