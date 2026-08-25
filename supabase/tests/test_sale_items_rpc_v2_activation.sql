-- =============================================================================
-- test_sale_items_rpc_v2_activation.sql — Gates de comportamiento:
-- deudas-menores-agosto (G1) — activación opt-out de sale_items_rpc_v2.
--
-- Verifica 20260924000001_activate_sale_items_rpc_v2.sql:
--   (a) Cuenta SIN ninguna fila en account_feature_flags: una venta y una
--       compra de producto escriben su línea (sale_items / purchase_items).
--       Esto es lo que hoy (antes de la migración) NO ocurre — ausencia de
--       fila = legacy — por eso este gate está RED contra el esquema previo.
--   (b) Kill-switch: cuenta con fila enabled=false sigue yendo por el camino
--       legacy (ninguna línea) para venta y compra.
--   (c) Línea de servicio (product_id NULL) NO genera fila en sale_items ni
--       en purchase_items, con o sin flag.
--   (d) Idempotencia: doble llamada con la misma idempotency_key crea una
--       sola venta/compra y una sola línea; la segunda llamada es replay.
--   (e) El stock se mueve igual que antes (stock_movements con el signo y
--       magnitud esperados, branch_stock actualizado).
--
-- Patrón del proyecto (test_kpis.sql / test_analytics_events.sql): acumular
-- fallos en text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user. Simulación de sesión JWT vía set_config (local a la
-- transacción de este archivo — NUNCA usar este patrón contra prod).
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR que este
-- archivo).
-- =============================================================================

DO $$
DECLARE
  v_failures         text[] := '{}';

  -- Anchor A: cuenta SIN fila de flag (el caso central del change).
  v_email_a          text := 'deudas-menores-agosto-g1-optout@test.local';
  v_user_a           uuid := gen_random_uuid();
  v_account_a        uuid;
  v_branch_a         uuid;
  v_client_a         uuid;
  v_product_a        uuid;
  v_product_svc_a    uuid;  -- no se usa como servicio real (products siempre tiene product_id); línea de servicio = product_id NULL en el payload

  -- Anchor B: cuenta con flag enabled=false explícito (kill-switch).
  v_email_b          text := 'deudas-menores-agosto-g1-killswitch@test.local';
  v_user_b           uuid := gen_random_uuid();
  v_account_b        uuid;
  v_branch_b         uuid;
  v_client_b         uuid;
  v_product_b        uuid;

  v_sale_result      jsonb;
  v_purchase_result  jsonb;
  v_sale_id          uuid;
  v_purchase_id      uuid;
  v_op_id            uuid;
  v_count            integer;
  v_stock_before      numeric;
  v_stock_after       numeric;
  v_movement_delta    numeric;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor A: cuenta nueva, SIN fila en account_feature_flags.
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate G1 Opt-out', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor A (opt-out) — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

  -- Verificación explícita de la premisa del gate: CERO filas de flag para esta cuenta.
  IF EXISTS (SELECT 1 FROM public.account_feature_flags WHERE account_id = v_account_a AND flag_key = 'sale_items_rpc_v2') THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta ancla A ya tiene una fila de flag — el gate necesita una cuenta sin ninguna';
  END IF;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto Gate G1 Opt-out', 'G1-OPTOUT-1', 123.45, 200.00)
  RETURNING id INTO v_product_a;

  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_product_a, v_branch_a, 50);

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate G1 Opt-out')
  RETURNING id INTO v_client_a;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- ── Gate (a-sale): venta de producto en cuenta sin flag → escribe sale_items ──
  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_product_a AND branch_id = v_branch_a;

  v_sale_result := public.rpc_create_sale_operation(
    'gate-g1-optout-sale-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 200.00, 'quantity', 3, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op_id := (v_sale_result->>'operation_id')::uuid;

  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id AND product_id = v_product_a;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_id AND product_id = v_product_a AND variant_id IS NULL;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL (a-sale): cuenta sin fila de flag debería escribir 1 fila en sale_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (a-sale): cuenta sin fila de flag escribe sale_items (opt-out activo)';
  END IF;

  -- ── Gate (e-sale): stock/ledger se mueve igual que antes ────────────────────
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_product_a AND branch_id = v_branch_a;
  IF v_stock_after IS DISTINCT FROM (v_stock_before - 3) THEN
    v_failures := array_append(v_failures,
      format('FAIL (e-sale): branch_stock no descontó 3 unidades (antes=%s, después=%s)', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (e-sale): branch_stock descontó exactamente 3 unidades';
  END IF;

  SELECT quantity_delta INTO v_movement_delta
  FROM public.stock_movements
  WHERE reference_id = v_sale_id AND reference_type = 'sale' AND type = 'sale';
  IF v_movement_delta IS DISTINCT FROM -3 THEN
    v_failures := array_append(v_failures,
      format('FAIL (e-sale): stock_movements.quantity_delta esperado -3, hay %s', v_movement_delta));
  ELSE
    RAISE NOTICE 'PASS (e-sale): stock_movements registra quantity_delta=-3';
  END IF;

  -- ── Gate (c-sale): línea de servicio (product_id NULL) no genera sale_items ──
  v_sale_result := public.rpc_create_sale_operation(
    'gate-g1-optout-sale-svc-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op_id := (v_sale_result->>'operation_id')::uuid;

  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id AND product_id IS NULL;
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      format('FAIL (c-sale): línea de servicio (product_id NULL) no debería generar sale_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (c-sale): línea de servicio no genera sale_items';
  END IF;

  -- ── Gate (d-sale): idempotencia — misma key dos veces → 1 venta, 1 línea ────
  DECLARE
    v_idem_key text := 'gate-g1-optout-sale-idem-' || gen_random_uuid()::text;
    v_result_1 jsonb;
    v_result_2 jsonb;
    v_op_1     uuid;
  BEGIN
    v_result_1 := public.rpc_create_sale_operation(
      v_idem_key, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 200.00, 'quantity', 1, 'unit_id', NULL)),
      v_branch_a, NULL
    );
    v_op_1 := (v_result_1->>'operation_id')::uuid;

    v_result_2 := public.rpc_create_sale_operation(
      v_idem_key, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 200.00, 'quantity', 1, 'unit_id', NULL)),
      v_branch_a, NULL
    );

    IF (v_result_2->>'replayed') IS DISTINCT FROM 'true' THEN
      v_failures := array_append(v_failures, 'FAIL (d-sale): la segunda llamada con la misma idempotency_key debería devolver replayed=true');
    END IF;
    IF (v_result_2->>'operation_id')::uuid IS DISTINCT FROM v_op_1 THEN
      v_failures := array_append(v_failures, 'FAIL (d-sale): la segunda llamada devolvió un operation_id distinto — no es un replay real');
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_1;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (d-sale): debería existir exactamente 1 venta para operation_id, hay %s', v_count));
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id WHERE s.operation_id = v_op_1;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (d-sale): debería existir exactamente 1 sale_items para operation_id, hay %s', v_count));
    ELSE
      RAISE NOTICE 'PASS (d-sale): idempotencia intacta — 1 venta, 1 sale_items, replay detectado';
    END IF;
  END;

  -- ── Gate (a-purchase): compra de producto en cuenta sin flag → purchase_items ──
  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_product_a AND branch_id = v_branch_a;

  v_purchase_result := public.rpc_create_purchase_operation(
    'gate-g1-optout-purchase-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate G1 opt-out',
    jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 100.00, 'quantity', 4, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op_id := (v_purchase_result->>'operation_id')::uuid;

  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id AND product_id = v_product_a;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purchase_id AND product_id = v_product_a AND variant_id IS NULL;
  IF v_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL (a-purchase): cuenta sin fila de flag debería escribir 1 fila en purchase_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (a-purchase): cuenta sin fila de flag escribe purchase_items (opt-out activo, mismo interruptor que venta)';
  END IF;

  -- ── Gate (e-purchase): stock aumenta igual que antes ─────────────────────────
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_product_a AND branch_id = v_branch_a;
  IF v_stock_after IS DISTINCT FROM (v_stock_before + 4) THEN
    v_failures := array_append(v_failures,
      format('FAIL (e-purchase): branch_stock no sumó 4 unidades (antes=%s, después=%s)', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (e-purchase): branch_stock sumó exactamente 4 unidades';
  END IF;

  -- ── Gate (c-purchase): línea de servicio no genera purchase_items ───────────
  v_purchase_result := public.rpc_create_purchase_operation(
    'gate-g1-optout-purchase-svc-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate G1 servicio',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL
  );
  v_op_id := (v_purchase_result->>'operation_id')::uuid;

  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id AND product_id IS NULL;
  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purchase_id;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      format('FAIL (c-purchase): línea de servicio no debería generar purchase_items, hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (c-purchase): línea de servicio no genera purchase_items';
  END IF;

  -- ── Gate (d-purchase): idempotencia — misma key dos veces → 1 compra, 1 línea ─
  DECLARE
    v_idem_key text := 'gate-g1-optout-purchase-idem-' || gen_random_uuid()::text;
    v_result_1 jsonb;
    v_result_2 jsonb;
    v_op_1     uuid;
  BEGIN
    v_result_1 := public.rpc_create_purchase_operation(
      v_idem_key, CURRENT_DATE, 'Compra gate G1 idem',
      jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
      v_branch_a, NULL
    );
    v_op_1 := (v_result_1->>'operation_id')::uuid;

    v_result_2 := public.rpc_create_purchase_operation(
      v_idem_key, CURRENT_DATE, 'Compra gate G1 idem',
      jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
      v_branch_a, NULL
    );

    IF (v_result_2->>'replayed') IS DISTINCT FROM 'true' THEN
      v_failures := array_append(v_failures, 'FAIL (d-purchase): la segunda llamada con la misma idempotency_key debería devolver replayed=true');
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.purchases WHERE operation_id = v_op_1;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (d-purchase): debería existir exactamente 1 compra para operation_id, hay %s', v_count));
    END IF;

    SELECT COUNT(*) INTO v_count FROM public.purchase_items pi JOIN public.purchases p ON p.id = pi.purchase_id WHERE p.operation_id = v_op_1;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (d-purchase): debería existir exactamente 1 purchase_items para operation_id, hay %s', v_count));
    ELSE
      RAISE NOTICE 'PASS (d-purchase): idempotencia intacta — 1 compra, 1 purchase_items, replay detectado';
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor B: cuenta con fila explícita enabled=false (kill-switch).
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate G1 Kill-switch', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b
  FROM   public.account_members
  WHERE  user_id = v_user_b
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor B (kill-switch)';
  END IF;

  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account_b, 'sale_items_rpc_v2', false)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = false;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_b, v_account_b, 'Producto Gate G1 Kill-switch', 'G1-KILL-1', 10.00, 20.00)
  RETURNING id INTO v_product_b;

  PERFORM public.c21_apply_branch_stock_delta(v_account_b, v_product_b, v_branch_b, 50);

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_b, v_account_b, 'Cliente Gate G1 Kill-switch')
  RETURNING id INTO v_client_b;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_b::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_b::text, true);

  -- ── Gate (b-sale): flag enabled=false → sigue sin escribir sale_items ───────
  v_sale_result := public.rpc_create_sale_operation(
    'gate-g1-killswitch-sale-' || gen_random_uuid()::text, v_client_b, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 20.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_b, NULL
  );
  v_op_id := (v_sale_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op_id AND product_id = v_product_b;

  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      format('FAIL (b-sale): flag enabled=false debería seguir sin escribir sale_items (kill-switch roto), hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (b-sale): kill-switch (enabled=false) mantiene el camino legacy para venta';
  END IF;

  -- Venta igual debe existir (header) — el kill-switch apaga la línea, no la operación.
  IF v_sale_id IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL (b-sale): la venta debería crearse igual (header plano) aunque el flag esté apagado');
  END IF;

  -- ── Gate (b-purchase): flag enabled=false → sigue sin escribir purchase_items ─
  v_purchase_result := public.rpc_create_purchase_operation(
    'gate-g1-killswitch-purchase-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate G1 kill-switch',
    jsonb_build_array(jsonb_build_object('product_id', v_product_b, 'amount', 10.00, 'quantity', 5, 'unit_id', NULL)),
    v_branch_b, NULL
  );
  v_op_id := (v_purchase_result->>'operation_id')::uuid;
  SELECT id INTO v_purchase_id FROM public.purchases WHERE operation_id = v_op_id AND product_id = v_product_b;

  SELECT COUNT(*) INTO v_count FROM public.purchase_items WHERE purchase_id = v_purchase_id;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures,
      format('FAIL (b-purchase): flag enabled=false debería seguir sin escribir purchase_items (kill-switch roto), hay %s', v_count));
  ELSE
    RAISE NOTICE 'PASS (b-purchase): kill-switch (enabled=false) mantiene el camino legacy para compra — mismo interruptor que venta';
  END IF;

  IF v_purchase_id IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL (b-purchase): la compra debería crearse igual (header plano) aunque el flag esté apagado');
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- ── Resultado ─────────────────────────────────────────────────────────────
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE SALE_ITEMS_RPC_V2_ACTIVATION FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE SALE_ITEMS_RPC_V2_ACTIVATION PASSED: opt-out por defecto (venta y compra), kill-switch explícito, línea de servicio excluida, idempotencia y stock — verificados para ambos RPCs.';

  -- ── Limpieza hijo→padre ──────────────────────────────────────────────────
  DELETE FROM public.sale_items     WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT id FROM public.purchases WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.stock_movements WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales          WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.purchases      WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.branch_stock   WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.products       WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.clients        WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.events         WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches       WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);

EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      DELETE FROM public.sale_items     WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT id FROM public.purchases WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.stock_movements WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.sales          WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.purchases      WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.branch_stock   WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.products       WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.clients        WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.events         WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches       WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
      -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
