-- =============================================================================
-- GATE: test_purchase_edit_journal.sql
-- CHANGE: edicion-operaciones-con-dinero, tanda A, grupo 4 (task 4.2 / 4.4)
--
-- El defecto latente de design.md §Context: `rpc_atomic_update_purchase_operation` no emitia NINGUN evento contable.
-- El asiento `Purchase` del operation_id viejo quedaba vivo, y un `PurchaseDeleted` posterior del id nuevo reintentaba
-- P0451 para siempre (evento pendiente envenenado, asiento original sin revertir).
--
-- Este gate corre el ciclo REAL con las RPCs y el despachador del outbox:
--   alta -> (despacho) -> edicion -> (despacho) -> segunda edicion -> (despacho) -> borrado -> (despacho)
-- y exige que TODOS los asientos de la compra terminen revertidos, que no quede ningun evento pendiente y que la
-- compra historica (sin PurchaseCreated) no emita un PurchaseAdjusted sin asiento que ajustar.
--
-- Una transaccion que termina en ROLLBACK (sin residuo, asertado al final).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_branch uuid;
  v_product uuid;
  v_res  jsonb;
  v_op1 uuid; v_op2 uuid; v_op3 uuid;
  v_ids  uuid[];
  v_n    int;
  v_pending int;
  v_hist uuid;
  r record;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'purchase-edit-journal@test.local', now(), now(), jsonb_build_object('name', 'Gate Purchase Edit Journal'));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_acc LIMIT 1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_acc, '__gate_pej_product__', 'PEJ-1', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_product, v_branch, 100);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'SETUP FAILED: auth.uid()'; END IF;

  -- ── alta + despacho ─────────────────────────────────────────────────────────────────────────────────────
  v_res := public.rpc_create_purchase_operation('pej-' || gen_random_uuid()::text, CURRENT_DATE, 'compra gate',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 100.00, 'quantity', 5, 'unit_id', NULL)), v_branch);
  v_op1 := (v_res->>'operation_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(10000);
  IF (SELECT count(*) FROM public.journal_entries WHERE account_id = v_acc AND source_doc_ref = v_op1 AND status = 'posted') <> 1 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (alta): el alta debia postear su asiento';
  END IF;

  -- ── primera edicion: emite PurchaseAdjusted con el id viejo y el nuevo ─────────────────────────────────
  SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op1;
  v_res := public.rpc_atomic_update_purchase_operation(v_ids, CURRENT_DATE, 'compra gate editada',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 120.00, 'quantity', 5, 'unit_id', NULL)));
  v_op2 := (v_res->>'operation_id')::uuid;
  -- edicion-operaciones-con-dinero (tanda B, D2): el operation_id de la compra es ESTABLE: old = new.
  IF v_op2 IS DISTINCT FROM v_op1 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (id estable): la edicion debia conservar el operation_id (%), devolvio %', v_op1, v_op2;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseAdjusted' AND account_id = v_acc AND aggregate_id = v_op2
                  AND (payload->>'old_operation_id')::uuid = v_op1 AND (payload->>'new_operation_id')::uuid = v_op2 AND (payload->>'total')::numeric = 600) THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (edit1): faltó el PurchaseAdjusted con old=% y new=% y el total 600', v_op1, v_op2;
  END IF;
  PERFORM public.rpc_process_outbox_dispatch(10000);
  IF (SELECT count(*) FROM public.journal_entries WHERE account_id = v_acc AND source_doc_ref = v_op2 AND status = 'posted' AND reversal_of IS NULL) <> 1
     OR (SELECT count(*) FROM public.journal_entries WHERE account_id = v_acc AND source_doc_ref = v_op1 AND reversal_of IS NULL AND status = 'reversed') <> 1 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (edit1-asientos): el asiento viejo debia quedar reversed y existir UNO vigente (mismo id, contra-asiento aparte)';
  END IF;
  IF (SELECT sum(jl.amount) FROM public.journal_lines jl JOIN public.journal_entries je ON je.id = jl.entry_id
       WHERE je.account_id = v_acc AND je.source_doc_ref = v_op2 AND je.status = 'posted' AND je.reversal_of IS NULL AND jl.side = 'debit') <> 600 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (edit1-importe): el asiento vigente debia ser por 600';
  END IF;

  -- ── segunda edicion: el chain sigue (el PurchaseAdjusted anterior habilita el siguiente) ──────────────────
  SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op2;
  v_res := public.rpc_atomic_update_purchase_operation(v_ids, CURRENT_DATE, 'compra gate editada 2',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 130.00, 'quantity', 5, 'unit_id', NULL)));
  v_op3 := (v_res->>'operation_id')::uuid;
  PERFORM public.rpc_process_outbox_dispatch(10000);
  IF (SELECT count(*) FROM public.journal_entries WHERE account_id = v_acc AND source_doc_ref = v_op3 AND status = 'posted' AND reversal_of IS NULL) <> 1 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (edit2): la segunda edicion debia dejar UN asiento vigente con el id nuevo';
  END IF;

  -- ── borrado: revierte lo vigente, sin P0451 ──────────────────────────────────────────────────────────────
  PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op3);
  PERFORM public.rpc_process_outbox_dispatch(10000);

  SELECT count(*) INTO v_pending FROM public.events WHERE account_id = v_acc AND processed_at IS NULL;
  IF v_pending <> 0 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (4.4): quedaron % eventos pendientes (P0451 envenenado) tras alta -> edicion -> edicion -> borrado', v_pending;
  END IF;
  SELECT count(*) INTO v_n FROM public.journal_entries
   WHERE account_id = v_acc AND reversal_of IS NULL AND status <> 'reversed';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (4.4): % asientos de la compra siguen vigentes despues de borrarla', v_n;
  END IF;
  -- el libro diario de la compra cierra en cero: todo debito tiene su credito inverso
  FOR r IN
    SELECT jl.account_code,
           SUM(CASE jl.side WHEN 'debit' THEN jl.amount ELSE -jl.amount END) AS saldo
    FROM public.journal_lines jl JOIN public.journal_entries je ON je.id = jl.entry_id
    WHERE je.account_id = v_acc GROUP BY jl.account_code
  LOOP
    IF r.saldo <> 0 THEN
      RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (4.4-saldo): la cuenta % del libro diario debia cerrar en 0 y cierra en %', r.account_code, r.saldo;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (4.4): compra asentada -> editada dos veces -> borrada: todos los asientos revertidos, libro diario en 0 y 0 eventos pendientes.';

  -- ── compra historica (sin PurchaseCreated): editarla NO emite un evento sin asiento ──────────────────────
  v_hist := gen_random_uuid();
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user, v_acc, v_product, 50, 1, 50, 'historica', CURRENT_DATE, v_hist, v_branch);
  SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_hist;
  PERFORM public.rpc_atomic_update_purchase_operation(v_ids, CURRENT_DATE, 'historica editada',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 60.00, 'quantity', 1, 'unit_id', NULL)));
  IF EXISTS (SELECT 1 FROM public.events WHERE account_id = v_acc AND event_type = 'PurchaseAdjusted' AND (payload->>'old_operation_id')::uuid = v_hist) THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (historica): editar una compra sin asiento no debe emitir PurchaseAdjusted (evento envenenado)';
  END IF;
  RAISE NOTICE 'PASS (historica): la compra sin PurchaseCreated no emite PurchaseAdjusted.';
END $$;

ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = 'purchase-edit-journal@test.local') THEN
    RAISE EXCEPTION 'GATE PURCHASE-EDIT-JOURNAL FAILED (cleanup): quedo el anchor';
  END IF;
  RAISE NOTICE 'PASS: gate purchase-edit-journal completo y sin residuo.';
END $$;
