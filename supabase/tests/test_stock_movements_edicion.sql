-- =============================================================================
-- test_stock_movements_edicion.sql — Gates de comportamiento: stock-movements-
-- edicion.
--
-- Verifica 20260927000001_stock_movements_edicion.sql: rpc_atomic_update_
-- sale_operation / rpc_atomic_update_purchase_operation dejan de mover
-- branch_stock EN SILENCIO — cada REVERSE y cada APPLY que ya ejecutan contra
-- branch_stock queda espejado en stock_movements (design.md §D1/§D2), con el
-- helper canónico public.op_stock_movement (§D3) reemplazando los 4
-- PERFORM c21_apply_branch_stock_delta(...) sueltos de las dos RPCs.
--
-- El gate 6 (eliminar una operación EDITADA repone stock) es el que prueba el
-- bug de fondo: SalesRepository.delete_by_id / PurchaseRepository.delete_by_id
-- derivan la reversa leyendo stock_movements (reference_id = <op>.id,
-- reference_type = 'sale'|'purchase') — sin el movimiento APPLY de la
-- edición, rpc_reverse_stock_movement recorre cero filas y el stock nunca
-- vuelve. DEBE FALLAR contra el schema previo a esta migración.
--
-- Patrón del proyecto (test_operation_edit_lines.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user. Sesión simulada con set_config, LOCAL a la transacción de
-- este archivo — NUNCA usar este patrón contra prod.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';

  -- Anchor A: cuenta principal.
  v_email_a         text := 'stock-movements-edicion-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_a        uuid;
  v_client_a        uuid;

  -- Productos.
  v_p1              uuid;  -- cost inicial 600, luego movido a 900 (control positivo unit_cost_snapshot)
  v_p2              uuid;  -- swap target (editar producto)

  -- Compras.
  v_pp1             uuid;  -- cost inicial 300
  v_pp2             uuid;  -- swap target

  v_result          jsonb;
  v_op              uuid;
  v_count           integer;
  v_val_numeric     numeric;
  v_stock_before    numeric;
  v_stock_after     numeric;
  v_delta_sum       numeric;

  -- Movimientos de creación / edición / eliminación.
  v_sale_create     uuid;
  v_sale_v1         uuid;  -- 5→3 (gate 2/1.3)
  v_sale_v2         uuid;  -- A→B (gate 3/1.4)
  v_sale_svc        uuid;

  v_purch_create    uuid;
  v_purch_v1        uuid;
  v_purch_v2        uuid;
  v_purch_svc       uuid;

  -- Secuencia crear→editar→eliminar (gate 1.6/1.7).
  v_seq_p           uuid;
  v_seq_sale_0      uuid;
  v_seq_sale_1      uuid;
  v_seq_stock_initial numeric;
  v_seq_stock_final   numeric;

  v_seq_pp          uuid;
  v_seq_purch_0     uuid;
  v_seq_purch_1     uuid;
  v_seq_pstock_initial numeric;
  v_seq_pstock_final   numeric;

  -- Triangulación 3.1: agregar / eliminar línea.
  v_tri_p1          uuid;
  v_tri_p2          uuid;
  v_tri_op          uuid;
  v_tri_sale_1      uuid;
  v_tri_sale_2      uuid;

  -- Triangulación 3.2: colisión legacy (2 filas mismo product_id).
  v_coll_p          uuid;
  v_coll_sale_1     uuid;
  v_coll_sale_2     uuid;
  v_coll_new        uuid;

  -- Triangulación 3.3: doble edición encadenada.
  v_chain_p         uuid;
  v_chain_sale_0    uuid;
  v_chain_sale_1    uuid;
  v_chain_sale_2    uuid;
  v_chain_stock_initial numeric;
  v_chain_stock_final   numeric;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor A
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Stock Movements Edicion A', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor A — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate Stock Movements A')
  RETURNING id INTO v_client_a;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME P1', 'SME-P1', 600.00, 1000.00)
  RETURNING id INTO v_p1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME P2', 'SME-P2', 1500.00, 2000.00)
  RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME PP1', 'SME-PP1', 300.00, 500.00)
  RETURNING id INTO v_pp1;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME PP2', 'SME-PP2', 800.00, 1200.00)
  RETURNING id INTO v_pp2;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME SEQ', 'SME-SEQ', 200.00, 400.00)
  RETURNING id INTO v_seq_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_seq_p, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME SEQ Compra', 'SME-SEQP', 90.00, 150.00)
  RETURNING id INTO v_seq_pp;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_seq_pp, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME TRI 1', 'SME-TRI1', 30.00, 60.00)
  RETURNING id INTO v_tri_p1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_tri_p1, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME TRI 2', 'SME-TRI2', 35.00, 70.00)
  RETURNING id INTO v_tri_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_tri_p2, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME COLL', 'SME-COLL', 25.00, 50.00)
  RETURNING id INTO v_coll_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_coll_p, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto SME CHAIN', 'SME-CHAIN', 45.00, 90.00)
  RETURNING id INTO v_chain_p;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_chain_p, v_branch_a, 50);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.2 — creación (control negativo del propio gate): crear una venta
  -- emite su movimiento reference_type='sale' con quantity_delta correcto.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'sme-sale-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_create FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT COUNT(*), COALESCE(SUM(quantity_delta), 0) INTO v_count, v_val_numeric
  FROM public.stock_movements
  WHERE reference_id = v_sale_create AND reference_type = 'sale';
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2 creación): esperaba 1 movimiento reference_type=sale para la venta creada, hay %s', v_count));
  ELSIF v_val_numeric IS DISTINCT FROM -5 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2 creación): quantity_delta esperado -5, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.2): crear una venta emite su movimiento reference_type=sale con quantity_delta correcto';
  END IF;

  -- Cost drift ENTRE la creación y la edición — control positivo del acarreo (gate 1.9).
  UPDATE public.products SET cost = 900.00 WHERE id = v_p1;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.3 — editar cantidad (5→3): par espejo exacto.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_create], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_v1 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  -- Pata REVERSE: sale_return / sale_update / +5 sobre el id VIEJO.
  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_sale_create AND reference_type = 'sale_update' AND type = 'sale_return' AND quantity_delta = 5;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3 REVERSE): esperaba 1 movimiento type=sale_return/reference_type=sale_update/+5 sobre el id viejo, hay %s', v_count));
  END IF;

  -- Pata APPLY: sale / sale / -3 sobre el id NUEVO — indistinguible de la creación.
  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_sale_v1 AND reference_type = 'sale' AND type = 'sale' AND quantity_delta = -3;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3 APPLY): esperaba 1 movimiento type=sale/reference_type=sale/-3 sobre el id nuevo, hay %s', v_count));
  END IF;

  IF v_count = 1 THEN
    RAISE NOTICE 'PASS (1.3): editar cantidad 5→3 deja el par espejo — sale_return/+5 (viejo) y sale/-3 (nuevo)';
  END IF;

  -- branch_stock neto: -5 (creación) +5 (reversa) -3 (aplicación) = -3 desde el stock inicial de 100.
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  IF v_stock_after IS DISTINCT FROM 97 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3 branch_stock): esperado 97 (100-5+5-3), hay %s', v_stock_after));
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.9 — unit_cost_snapshot no se re-valúa: la pata APPLY conserva 600
  -- (costo al crearse) pese al cost drift a 900 antes de la edición.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.stock_movements
  WHERE reference_id = v_sale_v1 AND reference_type = 'sale' AND type = 'sale';
  IF v_val_numeric IS DISTINCT FROM 600.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.9): unit_cost_snapshot del movimiento APPLY debería seguir en 600 (acarreado), hay %s (products.cost ya es 900)', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.9): el movimiento de la pata APPLY conserva unit_cost_snapshot=600 pese al cost drift a 900';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.4 — editar producto (P1→P2): movimientos de AMBOS productos.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_v1], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 200.00, 'quantity', 3))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_v2 FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_sale_v1 AND reference_type = 'sale_update' AND type = 'sale_return'
    AND product_id = v_p1 AND quantity_delta = 3;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.4 REVERSE P1): esperaba 1 movimiento sale_return/+3 de P1 sobre el id viejo, hay %s', v_count));
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_sale_v2 AND reference_type = 'sale' AND type = 'sale'
    AND product_id = v_p2 AND quantity_delta = -3;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.4 APPLY P2): esperaba 1 movimiento sale/-3 de P2 sobre el id nuevo, hay %s', v_count));
  END IF;

  -- Control negativo: B (P2) no hereda nada de A (P1) — snapshot fresco de P2 (1500).
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.stock_movements
  WHERE reference_id = v_sale_v2 AND reference_type = 'sale' AND type = 'sale';
  IF v_val_numeric IS DISTINCT FROM 1500.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.4 control negativo): P2 debería tener snapshot fresco 1500, no heredar el de P1, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.4): editar producto (P1→P2) emite movimientos de ambos productos, P2 con snapshot fresco (sin heredar de P1)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.10 — línea de servicio (product_id NULL): cero movimientos.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'sme-sale-svc-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_svc FROM public.sales WHERE operation_id = v_op AND product_id IS NULL;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_svc], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 600.00, 'quantity', 1))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_svc FROM public.sales WHERE operation_id = v_op AND product_id IS NULL;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE reference_id = v_sale_svc;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.10): línea de servicio no debería emitir movimientos, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.10): editar una línea de servicio sigue sin emitir movimientos de stock, sin error';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.7 (compras) — espejo de 1.3/1.4/1.9 con signos invertidos.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_purchase_operation(
    'sme-purchase-create-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate SME',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 50.00, 'quantity', 10, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_create FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_purch_create AND reference_type = 'purchase' AND type = 'purchase' AND quantity_delta = 10;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 creación compra): esperaba 1 movimiento purchase/+10, hay %s', v_count));
  END IF;

  UPDATE public.products SET cost = 700.00 WHERE id = v_pp1;

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_create], CURRENT_DATE, 'Compra gate SME editada',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 50.00, 'quantity', 4))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_v1 FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_purch_create AND reference_type = 'purchase_update' AND type = 'purchase_return' AND quantity_delta = -10;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 REVERSE compra): esperaba 1 movimiento purchase_return/purchase_update/-10 sobre el id viejo, hay %s', v_count));
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_purch_v1 AND reference_type = 'purchase' AND type = 'purchase' AND quantity_delta = 4;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 APPLY compra): esperaba 1 movimiento purchase/+4 sobre el id nuevo, hay %s', v_count));
  END IF;

  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.stock_movements
  WHERE reference_id = v_purch_v1 AND reference_type = 'purchase' AND type = 'purchase';
  IF v_val_numeric IS DISTINCT FROM 300.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7/1.9 compra): unit_cost_snapshot debería acarrear 300 pese al drift a 700, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.7): editar una compra (10→4) deja el par espejo con signos invertidos y unit_cost_snapshot acarreado (300, no 700)';
  END IF;

  -- Cambiar de producto en compra (PP1→PP2).
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_v1], CURRENT_DATE, 'Compra gate SME swap',
    jsonb_build_array(jsonb_build_object('product_id', v_pp2, 'amount', 80.00, 'quantity', 2))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_v2 FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp2;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_purch_v1 AND reference_type = 'purchase_update' AND type = 'purchase_return'
    AND product_id = v_pp1 AND quantity_delta = -4;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 swap REVERSE): esperaba purchase_return/-4 de PP1, hay %s', v_count));
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_purch_v2 AND reference_type = 'purchase' AND type = 'purchase'
    AND product_id = v_pp2 AND quantity_delta = 2;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 swap APPLY): esperaba purchase/+2 de PP2, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.7 swap): cambiar de producto en una compra emite movimientos de ambos productos';
  END IF;

  -- Línea de servicio en compra: cero movimientos.
  v_result := public.rpc_create_purchase_operation(
    'sme-purchase-svc-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra servicio SME',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_svc FROM public.purchases WHERE operation_id = v_op AND product_id IS NULL;

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_svc], CURRENT_DATE, 'Compra servicio SME editada',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 550.00, 'quantity', 1))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_svc FROM public.purchases WHERE operation_id = v_op AND product_id IS NULL;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE reference_id = v_purch_svc;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.10 compra): línea de servicio de compra no debería emitir movimientos, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.10 compra): editar una línea de servicio de compra sigue sin emitir movimientos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.5 / 1.6 / 1.7(Σ) — secuencia crear→editar→eliminar sobre un
  -- anchor dedicado: la eliminación de una operación EDITADA repone stock
  -- (el bug de fondo — DEBE FALLAR en RED) y Σ quantity_delta reconstruye
  -- el delta total de branch_stock.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT quantity INTO v_seq_stock_initial FROM public.branch_stock WHERE product_id = v_seq_p AND branch_id = v_branch_a;

  v_result := public.rpc_create_sale_operation(
    'sme-seq-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_seq_p, 'amount', 100.00, 'quantity', 6, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_seq_sale_0 FROM public.sales WHERE operation_id = v_op AND product_id = v_seq_p;

  -- GATE 1.5: eliminar SIN editar repone stock (no-regresión — ya funcionaba).
  -- Se verifica sobre una copia: creamos, verificamos reversa por DELETE directo
  -- via rpc_reverse_stock_movement (mismo mecanismo que el backend), y luego
  -- recreamos para continuar con la secuencia de edición.
  DECLARE
    v_probe_op   uuid;
    v_probe_sale uuid;
    v_probe_before numeric;
    v_probe_after  numeric;
  BEGIN
    v_probe_before := (SELECT quantity FROM public.branch_stock WHERE product_id = v_seq_p AND branch_id = v_branch_a);
    v_result := public.rpc_create_sale_operation(
      'sme-probe-delete-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_seq_p, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
      v_branch_a, NULL
    );
    v_probe_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_probe_sale FROM public.sales WHERE operation_id = v_probe_op AND product_id = v_seq_p;

    PERFORM public.rpc_reverse_stock_movement(v_probe_sale, 'sale', 'Gate 1.5 probe delete');
    DELETE FROM public.sales WHERE id = v_probe_sale;

    v_probe_after := (SELECT quantity FROM public.branch_stock WHERE product_id = v_seq_p AND branch_id = v_branch_a);
    IF v_probe_after IS DISTINCT FROM v_probe_before THEN
      v_failures := array_append(v_failures, format('FAIL (1.5): eliminar una venta NO editada debería reponer stock al valor previo (%s), quedó en %s', v_probe_before, v_probe_after));
    ELSE
      RAISE NOTICE 'PASS (1.5): eliminar una venta no editada repone stock (contramovimiento + DELETE) — no-regresión';
    END IF;
  END;

  -- Editar la venta ancla (6→4).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_seq_sale_0], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_seq_p, 'amount', 100.00, 'quantity', 4))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_seq_sale_1 FROM public.sales WHERE operation_id = v_op AND product_id = v_seq_p;

  -- ── GATE 1.6 — EL GATE ESTRELLA: eliminar la operación EDITADA repone stock ──
  -- Reproduce exactamente lo que hace SalesRepository.delete_by_id: reversa
  -- vía rpc_reverse_stock_movement leyendo stock_movements (reference_id =
  -- <sale>.id, reference_type = 'sale') y DESPUÉS el DELETE del header.
  PERFORM public.rpc_reverse_stock_movement(v_seq_sale_1, 'sale', 'Gate 1.6 — venta editada eliminada');
  DELETE FROM public.sales WHERE id = v_seq_sale_1;

  SELECT quantity INTO v_seq_stock_final FROM public.branch_stock WHERE product_id = v_seq_p AND branch_id = v_branch_a;

  IF v_seq_stock_final IS DISTINCT FROM v_seq_stock_initial THEN
    v_failures := array_append(v_failures, format(
      'FAIL (1.6 — GATE ESTRELLA): eliminar una operación EDITADA debería reponer branch_stock al valor inicial (%s), quedó en %s. '
      'Esto reproduce el bug real: sin el movimiento reference_type=sale de la edición, rpc_reverse_stock_movement no encuentra nada para revertir.',
      v_seq_stock_initial, v_seq_stock_final));
  ELSE
    RAISE NOTICE 'PASS (1.6 — GATE ESTRELLA): eliminar una operación previamente EDITADA repone branch_stock al valor inicial — el bug de fondo está resuelto';
  END IF;

  -- GATE Σ reconstruye: sobre TODA la secuencia (crear→editar→eliminar) del
  -- producto v_seq_p, Σ quantity_delta agrupada == delta total aplicado a
  -- branch_stock, y el stock final == inicial (idéntico chequeo, vía suma).
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_delta_sum
  FROM public.stock_movements
  WHERE product_id = v_seq_p AND branch_id = v_branch_a AND account_id = v_account_a;
  IF v_delta_sum IS DISTINCT FROM (v_seq_stock_final - v_seq_stock_initial) THEN
    v_failures := array_append(v_failures, format('FAIL (Σ reconstruye): Σ quantity_delta (%s) debería igualar el delta de branch_stock (%s)', v_delta_sum, v_seq_stock_final - v_seq_stock_initial));
  ELSE
    RAISE NOTICE 'PASS (Σ reconstruye): la suma de quantity_delta de la secuencia crear→editar→eliminar reproduce el delta real de branch_stock';
  END IF;

  -- GATE huérfanos nuevos = 0: todo movimiento reference_type IN ('sale','purchase')
  -- de esta cuenta que apunte a una fila inexistente debe tener su
  -- contramovimiento de cierre (*_reversal o *_update) para el mismo reference_id.
  -- Los *_update/*_reversal quedan excluidos del chequeo por diseño (design §D7).
  SELECT COUNT(*) INTO v_count
  FROM public.stock_movements sm
  WHERE sm.account_id = v_account_a
    AND sm.reference_type IN ('sale', 'purchase')
    AND (
      (sm.reference_type = 'sale' AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sm.reference_id))
      OR
      (sm.reference_type = 'purchase' AND NOT EXISTS (SELECT 1 FROM public.purchases p WHERE p.id = sm.reference_id))
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.stock_movements closer
      WHERE closer.reference_id = sm.reference_id
        AND closer.reference_type IN ('sale_reversal', 'purchase_reversal', 'sale_update', 'purchase_update')
    );
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (huérfanos nuevos): %s movimiento(s) sale/purchase apuntan a una fila inexistente SIN contramovimiento de cierre', v_count));
  ELSE
    RAISE NOTICE 'PASS (huérfanos nuevos): ningún movimiento sale/purchase de la cuenta A quedó huérfano sin contramovimiento de cierre';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE espejo compras — secuencia crear→editar→eliminar (Σ + gate estrella).
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT quantity INTO v_seq_pstock_initial FROM public.branch_stock WHERE product_id = v_seq_pp AND branch_id = v_branch_a;

  v_result := public.rpc_create_purchase_operation(
    'sme-seq-purch-create-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra secuencia SME',
    jsonb_build_array(jsonb_build_object('product_id', v_seq_pp, 'amount', 90.00, 'quantity', 8, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_seq_purch_0 FROM public.purchases WHERE operation_id = v_op AND product_id = v_seq_pp;

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_seq_purch_0], CURRENT_DATE, 'Compra secuencia SME editada',
    jsonb_build_array(jsonb_build_object('product_id', v_seq_pp, 'amount', 90.00, 'quantity', 5))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_seq_purch_1 FROM public.purchases WHERE operation_id = v_op AND product_id = v_seq_pp;

  PERFORM public.rpc_reverse_stock_movement(v_seq_purch_1, 'purchase', 'Gate espejo compra — editada eliminada');
  DELETE FROM public.purchases WHERE id = v_seq_purch_1;

  SELECT quantity INTO v_seq_pstock_final FROM public.branch_stock WHERE product_id = v_seq_pp AND branch_id = v_branch_a;
  IF v_seq_pstock_final IS DISTINCT FROM v_seq_pstock_initial THEN
    v_failures := array_append(v_failures, format('FAIL (1.6 espejo compra): eliminar una compra EDITADA debería reponer branch_stock al valor inicial (%s), quedó en %s', v_seq_pstock_initial, v_seq_pstock_final));
  ELSE
    RAISE NOTICE 'PASS (1.6 espejo compra): eliminar una compra previamente editada repone branch_stock al valor inicial';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- TRIANGULACIÓN 3.1 — edición que AGREGA una línea nueva y edición que
  -- ELIMINA una línea existente (no solo cambio de cantidad).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'sme-tri-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_tri_p1, 'amount', 60.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_tri_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_tri_sale_1 FROM public.sales WHERE operation_id = v_tri_op AND product_id = v_tri_p1;

  -- Editar AGREGANDO una segunda línea (TRI1 se mantiene + TRI2 nuevo).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_tri_sale_1], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(
      jsonb_build_object('product_id', v_tri_p1, 'amount', 60.00, 'quantity', 2),
      jsonb_build_object('product_id', v_tri_p2, 'amount', 70.00, 'quantity', 1)
    )
  );
  v_tri_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_tri_sale_1 FROM public.sales WHERE operation_id = v_tri_op AND product_id = v_tri_p1;
  SELECT id INTO v_tri_sale_2 FROM public.sales WHERE operation_id = v_tri_op AND product_id = v_tri_p2;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_tri_sale_2 AND reference_type = 'sale' AND type = 'sale' AND product_id = v_tri_p2 AND quantity_delta = -1;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (3.1 agregar línea): esperaba movimiento sale/-1 para la línea NUEVA (TRI2), hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (3.1 agregar línea): editar agregando una línea nueva emite su movimiento sale/APPLY correcto';
  END IF;

  -- Editar ELIMINANDO la línea TRI2 (vuelve a quedar solo TRI1).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_tri_sale_1, v_tri_sale_2], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_tri_p1, 'amount', 60.00, 'quantity', 2))
  );
  v_tri_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_tri_sale_1 FROM public.sales WHERE operation_id = v_tri_op AND product_id = v_tri_p1;

  SELECT COUNT(*) INTO v_count FROM public.stock_movements
  WHERE reference_id = v_tri_sale_2 AND reference_type = 'sale_update' AND type = 'sale_return' AND product_id = v_tri_p2 AND quantity_delta = 1;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (3.1 eliminar línea): esperaba movimiento sale_return/+1 REVERSE para TRI2 (línea eliminada de la edición), hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (3.1 eliminar línea): editar quitando una línea existente emite su REVERSE correcto (TRI2 vuelve a stock)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- TRIANGULACIÓN 3.2 — colisión legacy: dos filas de header con el MISMO
  -- product_id → los movimientos suman correctamente y el snapshot es
  -- determinístico.
  -- ═══════════════════════════════════════════════════════════════════════
  DECLARE
    v_coll_op uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_a, v_account_a, v_client_a, v_coll_p, 50.00, 1, 50.00, 'ARS', CURRENT_DATE, v_coll_op, v_branch_a)
    RETURNING id INTO v_coll_sale_1;
    PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_coll_p, v_branch_a, -1);

    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_a, v_account_a, v_client_a, v_coll_p, 50.00, 1, 50.00, 'ARS', CURRENT_DATE, v_coll_op, v_branch_a)
    RETURNING id INTO v_coll_sale_2;
    PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_coll_p, v_branch_a, -1);

    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_coll_sale_1, v_coll_sale_2], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_coll_p, 'amount', 50.00, 'quantity', 2))
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_coll_new FROM public.sales WHERE operation_id = v_op AND product_id = v_coll_p;

    -- Dos REVERSE (una por cada fila vieja del header, +1 cada una) y un solo APPLY (-2).
    SELECT COUNT(*) INTO v_count FROM public.stock_movements
    WHERE reference_id IN (v_coll_sale_1, v_coll_sale_2) AND reference_type = 'sale_update' AND type = 'sale_return' AND quantity_delta = 1;
    IF v_count <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (3.2 colisión REVERSE): esperaba 2 movimientos sale_return/+1 (uno por fila vieja), hay %s', v_count));
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.stock_movements
    WHERE reference_id = v_coll_new AND reference_type = 'sale' AND type = 'sale' AND quantity_delta = -2;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (3.2 colisión APPLY): esperaba 1 movimiento sale/-2 consolidado, hay %s', v_count));
    ELSE
      RAISE NOTICE 'PASS (3.2 colisión): dos filas viejas del mismo product_id emiten dos REVERSE (+1/+1) y un solo APPLY consolidado (-2)';
    END IF;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- TRIANGULACIÓN 3.3 — doble edición encadenada: Σ del ledger sigue
  -- reconstruyendo branch_stock y no aparecen huérfanos sin cierre.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT quantity INTO v_chain_stock_initial FROM public.branch_stock WHERE product_id = v_chain_p AND branch_id = v_branch_a;

  v_result := public.rpc_create_sale_operation(
    'sme-chain-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_chain_p, 'amount', 90.00, 'quantity', 10, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_chain_sale_0 FROM public.sales WHERE operation_id = v_op AND product_id = v_chain_p;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_chain_sale_0], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_chain_p, 'amount', 90.00, 'quantity', 6))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_chain_sale_1 FROM public.sales WHERE operation_id = v_op AND product_id = v_chain_p;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_chain_sale_1], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_chain_p, 'amount', 90.00, 'quantity', 4))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_chain_sale_2 FROM public.sales WHERE operation_id = v_op AND product_id = v_chain_p;

  SELECT quantity INTO v_chain_stock_final FROM public.branch_stock WHERE product_id = v_chain_p AND branch_id = v_branch_a;

  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_delta_sum
  FROM public.stock_movements
  WHERE product_id = v_chain_p AND branch_id = v_branch_a AND account_id = v_account_a;

  IF v_delta_sum IS DISTINCT FROM (v_chain_stock_final - v_chain_stock_initial) THEN
    v_failures := array_append(v_failures, format('FAIL (3.3 doble edición): Σ quantity_delta (%s) debería igualar el delta de branch_stock (%s) tras dos ediciones encadenadas', v_delta_sum, v_chain_stock_final - v_chain_stock_initial));
  ELSIF v_chain_stock_final IS DISTINCT FROM (v_chain_stock_initial - 4) THEN
    v_failures := array_append(v_failures, format('FAIL (3.3 doble edición): branch_stock final esperado %s (inicial-4), hay %s', v_chain_stock_initial - 4, v_chain_stock_final));
  ELSE
    RAISE NOTICE 'PASS (3.3): doble edición encadenada (10→6→4) — Σ quantity_delta sigue reconstruyendo branch_stock exactamente';
  END IF;

  -- Sin huérfanos sin cierre para la cadena (las dos filas intermedias SON
  -- huérfanas por diseño — la reversa de la 2da edición referencia el id de
  -- la 1ra edición, que la misma transacción borró — pero tienen su propio
  -- cierre porque reference_type IN ('sale_update') queda excluido del check).
  SELECT COUNT(*) INTO v_count
  FROM public.stock_movements sm
  WHERE sm.account_id = v_account_a
    AND sm.reference_type = 'sale'
    AND sm.product_id = v_chain_p
    AND NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sm.reference_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.stock_movements closer
      WHERE closer.reference_id = sm.reference_id AND closer.reference_type IN ('sale_reversal', 'sale_update')
    );
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3.3 huérfanos): %s movimiento(s) sale de la cadena quedaron huérfanos sin cierre', v_count));
  ELSE
    RAISE NOTICE 'PASS (3.3 huérfanos): la cadena de dos ediciones no dejó huérfanos sin contramovimiento de cierre';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.12 — no-regresión del PR #415: el acarreo de sale_items/
  -- purchase_items sigue funcionando después de tocar las RPCs (spot-check:
  -- ya lo cubre exhaustivamente test_operation_edit_lines.sql, acá solo se
  -- verifica que las dos RPCs siguen produciendo exactamente 1 línea).
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_v2;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.12 no-regresión sale_items): esperaba 1 sale_items tras la edición P1→P2, hay %s — el acarreo de líneas del PR #415 podría haberse roto', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.12): el acarreo de sale_items del PR #415 sigue intacto después de tocar las RPCs de edición';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado
  -- ═══════════════════════════════════════════════════════════════════════
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK_MOVEMENTS_EDICION FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE STOCK_MOVEMENTS_EDICION PASSED: espejo REVERSE+APPLY en edición (venta y compra), unit_cost_snapshot acarreado, línea de servicio sin movimientos, Σ reconstruye, sin huérfanos nuevos, y el gate estrella (eliminar una operación editada repone stock) confirmado.';

  -- ── Limpieza ────────────────────────────────────────────────────────────
  DELETE FROM public.sale_items      WHERE account_id = v_account_a;
  DELETE FROM public.purchase_items  WHERE account_id = v_account_a;
  DELETE FROM public.stock_movements WHERE account_id = v_account_a;
  DELETE FROM public.sales           WHERE account_id = v_account_a;
  DELETE FROM public.purchases       WHERE account_id = v_account_a;
  DELETE FROM public.analytics_events WHERE user_id = v_user_a;
  DELETE FROM public.branch_stock    WHERE account_id = v_account_a;
  DELETE FROM public.products        WHERE account_id = v_account_a;
  DELETE FROM public.clients         WHERE account_id = v_account_a;
  DELETE FROM public.events          WHERE account_id = v_account_a;
  DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id = v_account_a;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id = v_account_a;
  DELETE FROM public.account_members       WHERE user_id = v_user_a;
  DELETE FROM public.accounts              WHERE id = v_account_a;
  DELETE FROM public.profiles              WHERE id = v_user_a;
  DELETE FROM public.email_logs            WHERE user_id = v_user_a;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_a;
  DELETE FROM auth.users                   WHERE id = v_user_a;

EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      DELETE FROM public.sale_items      WHERE account_id = v_account_a;
      DELETE FROM public.purchase_items  WHERE account_id = v_account_a;
      DELETE FROM public.stock_movements WHERE account_id = v_account_a;
      DELETE FROM public.sales           WHERE account_id = v_account_a;
      DELETE FROM public.purchases       WHERE account_id = v_account_a;
      DELETE FROM public.analytics_events WHERE user_id = v_user_a;
      DELETE FROM public.branch_stock    WHERE account_id = v_account_a;
      DELETE FROM public.products        WHERE account_id = v_account_a;
      DELETE FROM public.clients         WHERE account_id = v_account_a;
      DELETE FROM public.events          WHERE account_id = v_account_a;
      DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches        WHERE account_id = v_account_a;
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_feature_flags WHERE account_id = v_account_a;
      DELETE FROM public.account_members       WHERE user_id = v_user_a;
      DELETE FROM public.accounts              WHERE id = v_account_a;
      DELETE FROM public.profiles              WHERE id = v_user_a;
      DELETE FROM public.email_logs            WHERE user_id = v_user_a;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_a;
      DELETE FROM auth.users                   WHERE id = v_user_a;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
