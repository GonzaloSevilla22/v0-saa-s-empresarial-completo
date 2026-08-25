-- =============================================================================
-- test_operation_edit_lines.sql — Gates de comportamiento: edicion-operaciones-
-- lineas (OQ-1 de deudas-menores-agosto).
--
-- Verifica 20260926000001_edicion_operaciones_lineas.sql: rpc_atomic_update_
-- sale_operation / rpc_atomic_update_purchase_operation dejan de destruir
-- sale_items/purchase_items en cada edición (REVERSE→DELETE→APPLY, FK
-- ON DELETE CASCADE) y aplican la política de snapshot de design.md §D2/§D4/
-- §D5: acarreo por product_id si el producto no cambia (aunque products.cost
-- se haya movido entre la creación y la edición — control positivo), snapshot
-- fresco si cambia o si la operación nunca tuvo línea, header de compra
-- siempre poblado, línea gobernada por el flag sale_items_rpc_v2 (D3).
--
-- Patrón del proyecto (test_sale_items_rpc_v2_activation.sql): acumular
-- fallos en text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user. Sesión simulada con set_config, LOCAL a la transacción de
-- este archivo — NUNCA usar este patrón contra prod.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';

  -- Anchor A: cuenta principal (flag por defecto = v2/opt-out).
  v_email_a         text := 'edicion-operaciones-lineas-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_a        uuid;
  v_client_a        uuid;

  -- Anchor B: cuenta con kill-switch explícito (enabled=false).
  v_email_b         text := 'edicion-operaciones-lineas-b@test.local';
  v_user_b          uuid := gen_random_uuid();
  v_account_b       uuid;
  v_branch_b        uuid;
  v_client_b        uuid;
  v_product_b       uuid;

  -- Anchor C: dueño de un producto ajeno (gate P0403).
  v_email_c         text := 'edicion-operaciones-lineas-c@test.local';
  v_user_c          uuid := gen_random_uuid();
  v_account_c       uuid;
  v_product_foreign uuid;

  -- Productos del anchor A.
  v_p1              uuid;  -- cost inicial 600, luego movido a 900 (control positivo)
  v_p2              uuid;  -- cost 1500 (swap target)
  v_q1              uuid;  -- caso mixto: conserva
  v_q2              uuid;  -- caso mixto: reemplazado
  v_q3              uuid;  -- caso mixto: producto nuevo
  v_parent          uuid;  -- producto con variantes (gate P0422)
  v_child           uuid;
  v_low_stock       uuid;  -- stock chico para gate P0409

  v_result          jsonb;
  v_op              uuid;
  v_sale_0          uuid;
  v_sale_1          uuid;
  v_sale_2          uuid;
  v_sale_3          uuid;
  v_sale_svc        uuid;
  v_sale_legacy     uuid;
  v_count           integer;
  v_val_numeric     numeric;
  v_val_text        text;
  v_stock           numeric;
  v_sqlstate        text;

  -- Compras.
  v_pp1             uuid;  -- cost inicial 300, luego movido a 700
  v_pp2             uuid;  -- cost 800 (swap target)
  v_purch_0         uuid;
  v_purch_1         uuid;
  v_purch_2         uuid;
  v_purch_legacy    uuid;
  v_purch_headeronly uuid;
  v_purch_svc       uuid;

  -- Colisión (task 4.2): dos filas viejas de header con el MISMO product_id.
  v_coll_sale_1     uuid;
  v_coll_sale_2     uuid;
  v_coll_expected   numeric;
  v_coll_new        uuid;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor A
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Edicion Operaciones A', 'phone', '', 'locality', '', 'province', ''))
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
  VALUES (v_user_a, v_account_a, 'Cliente Gate Edicion A')
  RETURNING id INTO v_client_a;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate P1', 'EOL-P1', 600.00, 1000.00)
  RETURNING id INTO v_p1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate P2', 'EOL-P2', 1500.00, 2000.00)
  RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate Q1', 'EOL-Q1', 50.00, 100.00)
  RETURNING id INTO v_q1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_q1, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate Q2', 'EOL-Q2', 60.00, 120.00)
  RETURNING id INTO v_q2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_q2, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate Q3', 'EOL-Q3', 70.00, 140.00)
  RETURNING id INTO v_q3;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_q3, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, is_variant)
  VALUES (v_user_a, v_account_a, 'Producto Gate Parent', 'EOL-PARENT', 40.00, 80.00, false)
  RETURNING id INTO v_parent;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_parent, v_branch_a, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, is_variant, parent_id)
  VALUES (v_user_a, v_account_a, 'Producto Gate Child', 'EOL-CHILD', 40.00, 80.00, true, v_parent)
  RETURNING id INTO v_child;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate Low Stock', 'EOL-LOW', 20.00, 40.00)
  RETURNING id INTO v_low_stock;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_low_stock, v_branch_a, 3);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate PP1', 'EOL-PP1', 300.00, 500.00)
  RETURNING id INTO v_pp1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pp1, v_branch_a, 0);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate PP2', 'EOL-PP2', 800.00, 1200.00)
  RETURNING id INTO v_pp2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pp2, v_branch_a, 0);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.2 / 1.3 / 1.4 — secuencia de ediciones sobre la misma venta:
  -- cantidad → precio → cambio de producto.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'eol-sale-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_0 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_0;
  IF v_val_numeric IS DISTINCT FROM 600.00 THEN
    v_failures := array_append(v_failures, format('FAIL (setup 1.2): sale_items recién creado debería tener unit_cost_snapshot=600, hay %s', v_val_numeric));
  END IF;

  -- Cost drift ENTRE la creación y la edición — control positivo del acarreo.
  UPDATE public.products SET cost = 900.00 WHERE id = v_p1;

  -- ── 1.2: editar cantidad → 1 sola línea, cantidad nueva, snapshot intacto ──
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_0], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_1 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_1;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2): editar cantidad debería dejar exactamente 1 sale_items, hay %s', v_count));
  END IF;
  SELECT quantity INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_1;
  IF v_val_numeric IS DISTINCT FROM 5 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2): quantity esperada 5, hay %s', v_val_numeric));
  END IF;
  SELECT subtotal INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_1;
  IF v_val_numeric IS DISTINCT FROM 500.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2): subtotal esperado 500.00, hay %s', v_val_numeric));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_1;
  IF v_val_numeric IS DISTINCT FROM 600.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.2 control positivo): unit_cost_snapshot debería seguir en 600 (acarreado) aunque products.cost ya es 900, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.2): editar cantidad preserva unit_cost_snapshot=600 pese al cost drift a 900';
  END IF;

  -- ── 1.3: editar precio unitario → price/subtotal nuevos, snapshot intacto ──
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_1], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 150.00, 'quantity', 5))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_2 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT price INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_2;
  IF v_val_numeric IS DISTINCT FROM 150.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3): price esperado 150.00, hay %s', v_val_numeric));
  END IF;
  SELECT subtotal INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_2;
  IF v_val_numeric IS DISTINCT FROM 750.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3): subtotal esperado 750.00, hay %s', v_val_numeric));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_2;
  IF v_val_numeric IS DISTINCT FROM 600.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.3): editar precio no debería tocar unit_cost_snapshot (600), hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.3): editar precio deja price/subtotal nuevos y unit_cost_snapshot intacto';
  END IF;

  -- ── 1.4: cambiar de producto (P1→P2) → snapshot FRESCO de P2, sin heredar P1 ──
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_2], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 200.00, 'quantity', 3))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_3 AND product_id = v_p2;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.4): debería haber 1 sale_items referenciando P2, hay %s', v_count));
  END IF;
  SELECT unit_cost_snapshot, name_snapshot INTO v_val_numeric, v_val_text FROM public.sale_items WHERE sale_id = v_sale_3;
  IF v_val_numeric IS DISTINCT FROM 1500.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.4 control negativo): unit_cost_snapshot debería ser el costo ACTUAL de P2 (1500), hay %s — no debe heredar el 600 de P1', v_val_numeric));
  ELSIF v_val_text IS DISTINCT FROM 'Producto Gate P2' THEN
    v_failures := array_append(v_failures, format('FAIL (1.4): name_snapshot debería ser de P2, hay %s', v_val_text));
  ELSE
    RAISE NOTICE 'PASS (1.4): cambiar de producto congela snapshot fresco de P2 (1500), sin heredar nada de P1';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.5 — operación sin línea previa (legacy, insertada sin pasar por
  -- la RPC de creación) → la edición hace nacer la línea con snapshot fresco.
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_client_a, v_p1, 300.00, 2, 600.00, 'ARS', CURRENT_DATE, gen_random_uuid(), v_branch_a)
  RETURNING id INTO v_sale_legacy;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_legacy;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, 'SETUP FAILED (1.5): la venta legacy no debería tener sale_items todavía');
  END IF;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_legacy], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 300.00, 'quantity', 2))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_legacy FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_legacy;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.5): editar una operación sin línea previa debería crear 1 sale_items, hay %s', v_count));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_sale_legacy;
  IF v_val_numeric IS DISTINCT FROM 900.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.5): snapshot fresco debería tomar el costo ACTUAL de P1 (900, ya movido), hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.5): editar una operación sin línea previa la hace nacer con snapshot fresco';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.6 — línea de servicio (product_id NULL): sin fila, sin error.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'eol-sale-svc-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
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

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_svc;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.6): editar una línea de servicio no debería generar sale_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.6): editar una línea de servicio sigue sin generar sale_items';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Triangulación 4.3 — caso MIXTO: en la misma edición, un ítem conserva
  -- producto (acarrea) y otro cambia de producto (fresco).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'eol-sale-mixed-create-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(
      jsonb_build_object('product_id', v_q1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL),
      jsonb_build_object('product_id', v_q2, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)
    ),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;

  -- Q1 sube de costo antes de la edición (para distinguir acarreo de fresco).
  UPDATE public.products SET cost = 999.00 WHERE id = v_q1;

  DECLARE
    v_old_q1 uuid;
    v_old_q2 uuid;
    v_new_q1 uuid;
    v_new_q3 uuid;
  BEGIN
    SELECT id INTO v_old_q1 FROM public.sales WHERE operation_id = v_op AND product_id = v_q1;
    SELECT id INTO v_old_q2 FROM public.sales WHERE operation_id = v_op AND product_id = v_q2;

    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_old_q1, v_old_q2], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(
        jsonb_build_object('product_id', v_q1, 'amount', 100.00, 'quantity', 4),
        jsonb_build_object('product_id', v_q3, 'amount', 100.00, 'quantity', 1)
      )
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_new_q1 FROM public.sales WHERE operation_id = v_op AND product_id = v_q1;
    SELECT id INTO v_new_q3 FROM public.sales WHERE operation_id = v_op AND product_id = v_q3;

    SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_new_q1;
    IF v_val_numeric IS DISTINCT FROM 50.00 THEN
      v_failures := array_append(v_failures, format('FAIL (4.3 mixto/acarreo): Q1 debería conservar unit_cost_snapshot=50 (costo al crearse), hay %s', v_val_numeric));
    END IF;

    SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_new_q3;
    IF v_val_numeric IS DISTINCT FROM 70.00 THEN
      v_failures := array_append(v_failures, format('FAIL (4.3 mixto/fresco): Q3 debería tener snapshot fresco = costo actual (70), hay %s', v_val_numeric));
    END IF;

    IF v_val_numeric IS NOT DISTINCT FROM 70.00
       AND (SELECT unit_cost_snapshot FROM public.sale_items WHERE sale_id = v_new_q1) IS NOT DISTINCT FROM 50.00 THEN
      RAISE NOTICE 'PASS (4.3): caso mixto — Q1 acarrea, Q3 (nuevo, reemplaza a Q2) congela fresco, en la misma edición';
    END IF;

    -- Q2 ya no está referenciada: no debe quedar ninguna línea suya viva.
    SELECT COUNT(*) INTO v_count FROM public.sale_items si
      JOIN public.sales s ON s.id = si.sale_id
      WHERE s.operation_id = v_op AND si.product_id = v_q2;
    IF v_count <> 0 THEN
      v_failures := array_append(v_failures, format('FAIL (4.3): Q2 fue reemplazada por Q3, no debería quedar línea de Q2 en la operación resultante, hay %s', v_count));
    END IF;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Triangulación 4.2 — colisión: dos filas viejas de header con el MISMO
  -- product_id (forma legacy 1-operación:N-filas) → acarreo determinístico
  -- (DISTINCT ON product_id ORDER BY product_id, id).
  -- ═══════════════════════════════════════════════════════════════════════
  DECLARE
    v_coll_op uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_a, v_account_a, v_client_a, v_p1, 100.00, 1, 100.00, 'ARS', CURRENT_DATE, v_coll_op, v_branch_a)
    RETURNING id INTO v_coll_sale_1;
    INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot, name_snapshot)
    VALUES (v_coll_sale_1, v_p1, v_account_a, 1, 100.00, 100.00, 111.11, 'Snapshot viejo A');

    INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
    VALUES (v_user_a, v_account_a, v_client_a, v_p1, 100.00, 1, 100.00, 'ARS', CURRENT_DATE, v_coll_op, v_branch_a)
    RETURNING id INTO v_coll_sale_2;
    INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot, name_snapshot)
    VALUES (v_coll_sale_2, v_p1, v_account_a, 1, 100.00, 100.00, 222.22, 'Snapshot viejo B');

    -- Pick determinístico: el de menor id (ORDER BY product_id, id).
    SELECT unit_cost_snapshot INTO v_coll_expected
    FROM public.sale_items WHERE sale_id IN (v_coll_sale_1, v_coll_sale_2) ORDER BY id LIMIT 1;

    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_coll_sale_1, v_coll_sale_2], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2))
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_coll_new FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

    SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_coll_new;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (4.2 colisión): debería consolidar en 1 sola sale_items, hay %s', v_count));
    END IF;

    SELECT unit_cost_snapshot INTO v_val_numeric FROM public.sale_items WHERE sale_id = v_coll_new;
    IF v_val_numeric IS DISTINCT FROM v_coll_expected THEN
      v_failures := array_append(v_failures, format('FAIL (4.2 colisión): acarreo no determinístico — esperaba %s (menor id), hay %s', v_coll_expected, v_val_numeric));
    ELSE
      RAISE NOTICE 'PASS (4.2): colisión de dos líneas viejas con el mismo product_id resuelta de forma determinística (DISTINCT ON product_id, id)';
    END IF;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.9 — guards y stock: P0400, P0403, P0409, P0422 siguen disparando
  -- en la edición, y branch_stock refleja el neto reversa+aplicación.
  -- ═══════════════════════════════════════════════════════════════════════

  -- P0400: cantidad <= 0.
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_3], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 200.00, 'quantity', 0))
    );
    v_failures := array_append(v_failures, 'FAIL (1.9/P0400): editar con cantidad 0 debería lanzar excepción');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0400' THEN
      v_failures := array_append(v_failures, format('FAIL (1.9/P0400): esperaba SQLSTATE P0400, fue %s (%s)', v_sqlstate, SQLERRM));
    ELSE
      RAISE NOTICE 'PASS (1.9/P0400): cantidad <= 0 sigue rechazada en la edición';
    END IF;
  END;

  -- Recuperar el id vigente de la venta (el intento fallido no la tocó).
  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = (SELECT operation_id FROM public.sales WHERE id = v_sale_3) LIMIT 1;

  -- P0403: producto de otro usuario.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_c, 'authenticated', 'authenticated', v_email_c, now(), now(),
          jsonb_build_object('name', 'Gate Edicion Operaciones C', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;
  SELECT account_id INTO v_account_c FROM public.account_members WHERE user_id = v_user_c ORDER BY created_at LIMIT 1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_c, v_account_c, 'Producto Ajeno', 'EOL-FOREIGN', 10.00, 20.00)
  RETURNING id INTO v_product_foreign;

  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_3], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_foreign, 'amount', 20.00, 'quantity', 1))
    );
    v_failures := array_append(v_failures, 'FAIL (1.9/P0403): editar referenciando un producto ajeno debería lanzar excepción');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0403' THEN
      v_failures := array_append(v_failures, format('FAIL (1.9/P0403): esperaba SQLSTATE P0403, fue %s (%s)', v_sqlstate, SQLERRM));
    ELSE
      RAISE NOTICE 'PASS (1.9/P0403): producto ajeno sigue rechazado en la edición';
    END IF;
  END;

  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = (SELECT operation_id FROM public.sales WHERE id = v_sale_3) LIMIT 1;

  -- P0422: producto con variantes.
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_3], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_parent, 'amount', 80.00, 'quantity', 1))
    );
    v_failures := array_append(v_failures, 'FAIL (1.9/P0422): editar referenciando un producto con variantes debería lanzar excepción');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0422' THEN
      v_failures := array_append(v_failures, format('FAIL (1.9/P0422): esperaba SQLSTATE P0422, fue %s (%s)', v_sqlstate, SQLERRM));
    ELSE
      RAISE NOTICE 'PASS (1.9/P0422): producto con variantes sigue rechazado en la edición';
    END IF;
  END;

  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = (SELECT operation_id FROM public.sales WHERE id = v_sale_3) LIMIT 1;

  -- P0409: stock insuficiente (v_low_stock tiene 3 unidades).
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_3], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_low_stock, 'amount', 40.00, 'quantity', 999))
    );
    v_failures := array_append(v_failures, 'FAIL (1.9/P0409): editar pidiendo más stock del disponible debería lanzar excepción');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0409' THEN
      v_failures := array_append(v_failures, format('FAIL (1.9/P0409): esperaba SQLSTATE P0409, fue %s (%s)', v_sqlstate, SQLERRM));
    ELSE
      RAISE NOTICE 'PASS (1.9/P0409): stock insuficiente sigue rechazado en la edición';
    END IF;
  END;

  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = (SELECT operation_id FROM public.sales WHERE id = v_sale_3) LIMIT 1;

  -- Neto de stock: reversa + aplicación deja branch_stock exacto.
  SELECT quantity INTO v_stock FROM public.branch_stock WHERE product_id = v_low_stock AND branch_id = v_branch_a;
  IF v_stock IS DISTINCT FROM 3 THEN
    v_failures := array_append(v_failures, format('FAIL (1.9 stock): los intentos fallidos de P0409 no deberían haber movido branch_stock de v_low_stock (esperado 3), hay %s', v_stock));
  END IF;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_3], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_low_stock, 'amount', 40.00, 'quantity', 2))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_stock FROM public.branch_stock WHERE product_id = v_low_stock AND branch_id = v_branch_a;
  IF v_stock IS DISTINCT FROM 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.9 stock): branch_stock de v_low_stock esperado 1 (3-2) tras la edición, hay %s', v_stock));
  ELSE
    RAISE NOTICE 'PASS (1.9): guards P0400/P0403/P0409/P0422 disparan en la edición y branch_stock refleja el neto correcto';
  END IF;
  SELECT id INTO v_sale_3 FROM public.sales WHERE operation_id = v_op AND product_id = v_low_stock;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.10 — higiene referencial: sin huérfanos, sin más de 1 línea por
  -- fila de header, para toda la cuenta A.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count
  FROM public.sale_items si
  LEFT JOIN public.sales s ON s.id = si.sale_id
  WHERE si.account_id = v_account_a AND s.id IS NULL;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.10): hay %s sale_items huérfanas (sale_id sin fila padre) en la cuenta A', v_count));
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM (
    SELECT sale_id FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
    WHERE s.account_id = v_account_a
    GROUP BY sale_id HAVING COUNT(*) > 1
  ) dup;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.10): hay %s filas de header con más de 1 línea en la cuenta A', v_count));
  END IF;

  IF v_count = 0 THEN
    RAISE NOTICE 'PASS (1.10): sin sale_items huérfanas ni headers con más de 1 línea en la cuenta A';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.11 — doble submit: reintentar con ids ya borrados → P0404, sin
  -- líneas duplicadas ni huérfanas.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE account_id = v_account_a;

  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_0], v_client_a, CURRENT_DATE, 'ARS',   -- v_sale_0: reemplazada hace varias ediciones, ya no existe
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1))
    );
    v_failures := array_append(v_failures, 'FAIL (1.11): reintentar con un sale_id ya borrado debería lanzar excepción');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> 'P0404' THEN
      v_failures := array_append(v_failures, format('FAIL (1.11): esperaba SQLSTATE P0404, fue %s (%s)', v_sqlstate, SQLERRM));
    END IF;
  END;

  DECLARE
    v_count_after integer;
  BEGIN
    SELECT COUNT(*) INTO v_count_after FROM public.sale_items WHERE account_id = v_account_a;
    IF v_count_after <> v_count THEN
      v_failures := array_append(v_failures, format('FAIL (1.11): el doble submit fallido no debería alterar sale_items (antes=%s, después=%s)', v_count, v_count_after));
    ELSE
      RAISE NOTICE 'PASS (1.11): doble submit con ids ya borrados falla con P0404 sin dejar líneas duplicadas ni huérfanas';
    END IF;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.7 (compras) — espejo de 1.2-1.6 + header purchases poblado.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_purchase_operation(
    'eol-purchase-create-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate edicion',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 50.00, 'quantity', 4, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_0 FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchases WHERE id = v_purch_0;
  IF v_val_numeric IS DISTINCT FROM 300.00 THEN
    v_failures := array_append(v_failures, format('SETUP FAILED (1.7): header purchases recién creado debería tener unit_cost_snapshot=300, hay %s', v_val_numeric));
  END IF;

  -- Cost drift.
  UPDATE public.products SET cost = 700.00 WHERE id = v_pp1;

  -- Editar cantidad: acarreo en purchase_items Y en el header.
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_0], CURRENT_DATE, 'Compra gate edicion (editada)',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 50.00, 'quantity', 9))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_1 FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purch_1;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 qty): esperaba 1 purchase_items, hay %s', v_count));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchase_items WHERE purchase_id = v_purch_1;
  IF v_val_numeric IS DISTINCT FROM 300.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 qty/línea): purchase_items debería acarrear unit_cost_snapshot=300 pese al drift a 700, hay %s', v_val_numeric));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchases WHERE id = v_purch_1;
  IF v_val_numeric IS DISTINCT FROM 300.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 qty/header): el header purchases también debería acarrear unit_cost_snapshot=300, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.7 qty): editar cantidad de compra acarrea el snapshot en purchase_items Y en el header';
  END IF;

  -- Cambiar de producto (PP1→PP2) → snapshot fresco en línea y header.
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_1], CURRENT_DATE, 'Compra gate edicion (swap)',
    jsonb_build_array(jsonb_build_object('product_id', v_pp2, 'amount', 80.00, 'quantity', 2))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_2 FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp2;

  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchase_items WHERE purchase_id = v_purch_2;
  IF v_val_numeric IS DISTINCT FROM 800.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 swap/línea): purchase_items debería tener el costo fresco de PP2 (800), hay %s', v_val_numeric));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchases WHERE id = v_purch_2;
  IF v_val_numeric IS DISTINCT FROM 800.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 swap/header): el header también debería quedar con el costo fresco de PP2 (800), hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.7 swap): cambiar de producto en una compra congela el snapshot fresco en línea y header, sin heredar nada de PP1';
  END IF;

  -- Compra sin línea previa (legacy). Se compensa branch_stock por el
  -- quantity de la fila directa (una compra real vía RPC ya lo habría
  -- sumado al crearse) para que el STEP1/REVERSE de la edición no la lleve
  -- a negativo.
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_pp1, 90.00, 1, 90.00, 'Compra legacy sin línea', CURRENT_DATE, gen_random_uuid(), v_branch_a)
  RETURNING id INTO v_purch_legacy;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pp1, v_branch_a, 1);

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_legacy], CURRENT_DATE, 'Compra legacy editada',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 90.00, 'quantity', 1))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_legacy FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purch_legacy;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 legacy): editar una compra sin línea previa debería crear 1 purchase_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.7 legacy): editar una compra sin línea previa la hace nacer, con header poblado';
  END IF;

  -- Compra con snapshot SOLO en el header (sin purchase_items) — cubre el
  -- caso real de prod (179/186): el acarreo debe caer al header, no re-
  -- precificar a costo actual.
  INSERT INTO public.purchases (
    user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id,
    name_snapshot, sku_snapshot, unit_cost_snapshot, snapshot_backfilled
  ) VALUES (
    v_user_a, v_account_a, v_pp1, 55.00, 1, 55.00, 'Compra header-only', CURRENT_DATE, gen_random_uuid(), v_branch_a,
    'PP1 histórico', 'EOL-PP1-HIST', 555.00, false
  ) RETURNING id INTO v_purch_headeronly;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pp1, v_branch_a, 1);

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_headeronly], CURRENT_DATE, 'Compra header-only editada',
    jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 55.00, 'quantity', 3))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_headeronly FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchase_items WHERE purchase_id = v_purch_headeronly;
  IF v_val_numeric IS DISTINCT FROM 555.00 THEN
    v_failures := array_append(v_failures, format('FAIL (header-only): purchase_items debería acarrear el snapshot que SOLO vivía en el header (555), no el costo actual, hay %s', v_val_numeric));
  END IF;
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchases WHERE id = v_purch_headeronly;
  IF v_val_numeric IS DISTINCT FROM 555.00 THEN
    v_failures := array_append(v_failures, format('FAIL (header-only): el header debería conservar 555, hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (header-only): compra con snapshot solo en el header (sin purchase_items) preserva ese valor al editar, en vez de re-precificar a costo actual';
  END IF;

  -- Línea de servicio en compra.
  v_result := public.rpc_create_purchase_operation(
    'eol-purchase-svc-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra servicio',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_svc FROM public.purchases WHERE operation_id = v_op AND product_id IS NULL;

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_svc], CURRENT_DATE, 'Compra servicio editada',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 550.00, 'quantity', 1))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_svc FROM public.purchases WHERE operation_id = v_op AND product_id IS NULL;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purch_svc;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.7 servicio): línea de servicio no debería generar purchase_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (1.7 servicio): editar una línea de servicio de compra sigue sin generar purchase_items';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1.8 — kill-switch (cuenta B, enabled=false): la edición no escribe
  -- línea; header y stock se comportan igual.
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Edicion Operaciones B', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account_b, 'sale_items_rpc_v2', false)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = false;

  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_b, v_account_b, 'Cliente Gate B') RETURNING id INTO v_client_b;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_b, v_account_b, 'Producto Gate B', 'EOL-B1', 40.00, 80.00)
  RETURNING id INTO v_product_b;
  PERFORM public.c21_apply_branch_stock_delta(v_account_b, v_product_b, v_branch_b, 50);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_b::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_b::text, true);

  v_result := public.rpc_create_sale_operation(
    'eol-sale-killswitch-' || gen_random_uuid()::text, v_client_b, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 80.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_b, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_0 FROM public.sales WHERE operation_id = v_op AND product_id = v_product_b;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_0], v_client_b, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 80.00, 'quantity', 5))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_1 FROM public.sales WHERE operation_id = v_op AND product_id = v_product_b;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_1;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.8 sale): kill-switch debería mantener la edición sin sale_items, hay %s', v_count));
  END IF;
  IF v_sale_1 IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL (1.8 sale): la venta debería seguir editándose (header) aunque el flag esté apagado');
  END IF;

  v_result := public.rpc_create_purchase_operation(
    'eol-purchase-killswitch-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra kill-switch',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 40.00, 'quantity', 3, 'unit_id', NULL)),
    v_branch_b, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_0 FROM public.purchases WHERE operation_id = v_op AND product_id = v_product_b;

  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_0], CURRENT_DATE, 'Compra kill-switch editada',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 40.00, 'quantity', 7))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_1 FROM public.purchases WHERE operation_id = v_op AND product_id = v_product_b;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purch_1;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (1.8 purchase): kill-switch debería mantener la edición sin purchase_items, hay %s', v_count));
  END IF;

  -- D5: el header de compra se puebla SIEMPRE, incluso con el flag apagado
  -- (igual que en la creación — solo la línea está gobernada por el flag).
  SELECT unit_cost_snapshot INTO v_val_numeric FROM public.purchases WHERE id = v_purch_1;
  IF v_val_numeric IS DISTINCT FROM 40.00 THEN
    v_failures := array_append(v_failures, format('FAIL (1.8 purchase/header): el header debería seguir poblándose aunque el flag esté apagado (40), hay %s', v_val_numeric));
  ELSE
    RAISE NOTICE 'PASS (1.8): kill-switch mantiene la edición sin línea (venta y compra) pero el header de compra se sigue poblando';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado
  -- ═══════════════════════════════════════════════════════════════════════
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE OPERATION_EDIT_LINES FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE OPERATION_EDIT_LINES PASSED: acarreo/re-snapshot en edición (venta y compra), header de compra, colisión determinística, caso mixto, kill-switch, guards y doble submit — todos verificados.';

  -- ── Limpieza hijo→padre ──────────────────────────────────────────────────
  DELETE FROM public.sale_items     WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.purchase_items WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.stock_movements WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.sales          WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.purchases      WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM public.branch_stock   WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.products       WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.clients        WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.events         WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b, v_account_c));
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches       WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b, v_account_c);
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b, v_user_c);

EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      DELETE FROM public.sale_items     WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.purchase_items WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.stock_movements WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.sales          WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.purchases      WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b, v_user_c);
      DELETE FROM public.branch_stock   WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.products       WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.clients        WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.events         WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b, v_account_c));
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches       WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b, v_user_c);
      DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b, v_account_c);
      DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b, v_user_c);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b, v_user_c);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b, v_user_c);
      DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b, v_user_c);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
