-- =============================================================================
-- test_ventas_unidades_conversion.sql — Gate de comportamiento e introspección:
-- ventas-unidades-conversion (2026-09-24).
--
-- Verifica 20261061000001_ventas_unidades_conversion.sql:
--
--   (A) _uom_normalize_quantity es la ÚNICA definición de "cantidad de una línea
--       en la unidad en que se lleva el stock del producto": relativa a la
--       unidad base del PRODUCTO (D1), mismo type obligatorio (P0400
--       unit_type_mismatch), producto sin unidad base sólo admite unidades base
--       (P0400 unit_requires_base_unit, D3), línea sin unidad = factor 1.
--   (B) Los CINCO caminos que escriben stock desde una operación la consumen y
--       descuentan/suman lo mismo para la misma línea: alta de venta
--       (formulario), POS (quickSale → _c29_confirm_order_core), edición de
--       venta (REVERSE por quantity_delta guardado + APPLY normalizada, D6),
--       alta de compra y edición de compra. Antes de este change el POS y las
--       dos ediciones movían la cantidad CRUDA (450 g descontaban 450 kg).
--   (C) Tipo cruzado rechazado en cada camino SIN rastro parcial; el borrado
--       revierte lo normalizado; invariante SUM(quantity_delta) = branch_stock
--       con unidades mixtas.
--   (D) branch_stock.min_stock numeric(15,4): un umbral de 0,5 kg se propaga y
--       dispara la alerta de stock bajo; un mínimo entero no cambia.
--   (E) Introspección de cuerpos vivos, ACLs y firmas (mismas aserciones que el
--       gate embebido de la migración, para que una migración POSTERIOR que
--       redefina una de las funciones no pase por al lado).
--
-- Patrón del proyecto (test_edicion_preserva_contexto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchor sintético vía
-- handle_new_user. Sesión simulada con set_config, LOCAL a la transacción de
-- este archivo — NUNCA usar este patrón contra prod. Las unidades se crean por
-- cuenta (el stack local no tiene las 10 de sistema: se sembraron vía MCP).
--
-- Control negativo documentado (ejecutado el 2026-09-24 sobre el stack local):
-- con `v_qty_norm := v_item.quantity;` restaurado en _c29_confirm_order_core,
-- el bloque B.2 falla ("POS: delta esperado -0.45, obtuvo -450"), y con
-- `-v_item.quantity` restaurado en la pata APPLY de la edición, falla B.3.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';
  v_fail_before     integer;

  v_email_a         text := 'ventas-unidades-conversion-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_a        uuid;
  v_client_a        uuid;

  -- Unidades por cuenta (espejo de las 10 de sistema que sólo viven en prod).
  v_u_kg            uuid;   -- weight, base (factor 1, base_unit_id NULL)
  v_u_g             uuid;   -- weight, factor 0.001 → kg
  v_u_tn            uuid;   -- weight, factor 1000 → kg
  v_u_l             uuid;   -- volume, base
  v_u_ml            uuid;   -- volume, factor 0.001 → L
  v_u_u             uuid;   -- unit, base
  v_u_doc           uuid;   -- unit, factor 12 → u

  -- Productos.
  v_p_kg            uuid;   -- base kg
  v_p_g             uuid;   -- base g (unidad base DERIVADA: la conversión es relativa al producto, D1)
  v_p_none          uuid;   -- sin unidad base
  v_p_u             uuid;   -- base u (entero, control de no-regresión)

  v_result          jsonb;
  v_op              uuid;
  v_op2             uuid;
  v_sale_id         uuid;
  v_purch_id        uuid;
  v_so_id           uuid;
  v_before          numeric;
  v_after           numeric;
  v_val             numeric;
  v_cnt             integer;
  v_cnt2            integer;
  v_txt             text;
  v_src             text;
  v_fn              text;
  v_bs_id           uuid;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Ventas Unidades Conversion', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;
  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta no tiene sucursal default';
  END IF;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate VUC')
  RETURNING id INTO v_client_a;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo VUC', 'kg', 'weight', 1.0, false) RETURNING id INTO v_u_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo VUC', 'g', 'weight', 0.001, v_u_kg, false) RETURNING id INTO v_u_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Tonelada VUC', 'tn', 'weight', 1000, v_u_kg, false) RETURNING id INTO v_u_tn;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Litro VUC', 'L', 'volume', 1.0, false) RETURNING id INTO v_u_l;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Mililitro VUC', 'mL', 'volume', 0.001, v_u_l, false) RETURNING id INTO v_u_ml;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad VUC', 'u', 'unit', 1.0, false) RETURNING id INTO v_u_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Docena VUC', 'doc', 'unit', 12, v_u_u, false) RETURNING id INTO v_u_doc;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Tomate VUC (kg)', 'VUC-KG', 600.00, 1000.00, v_u_kg) RETURNING id INTO v_p_kg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Azafrán VUC (g)', 'VUC-G', 10.00, 20.00, v_u_g) RETURNING id INTO v_p_g;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Papa VUC (sin unidad)', 'VUC-NONE', 100.00, 200.00) RETURNING id INTO v_p_none;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Huevo VUC (u)', 'VUC-U', 50.00, 100.00, v_u_u) RETURNING id INTO v_p_u;

  -- Sesión sintética del anchor (owner por handle_new_user).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- Stock inicial vía rpc_adjust_branch_stock: deja movimiento 'adjustment',
  -- así el invariante SUM(quantity_delta) = branch_stock.quantity (C.3) es exacto.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg,   v_branch_a, 10,    'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_g,    v_branch_a, 1000,  'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_none, v_branch_a, 10,    'seed gate VUC');
  PERFORM public.rpc_adjust_branch_stock(v_p_u,    v_branch_a, 30,    'seed gate VUC');

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A) La definición única, caso por caso
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_g, 450);
  IF v_val <> 0.45 THEN v_failures := v_failures || format('A.1 base kg + 450 g: esperaba 0.45, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_kg, 0.45);
  IF v_val <> 0.45 THEN v_failures := v_failures || format('A.2 misma unidad que la base: esperaba 0.45, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_g, v_u_kg, 0.5);
  IF v_val <> 500 THEN v_failures := v_failures || format('A.3 base g + 0.5 kg (relativa al PRODUCTO, no al tipo): esperaba 500, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, v_u_tn, 0.002);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.4 base kg + 0.002 tn: esperaba 2, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_kg, NULL, 3);
  IF v_val <> 3 THEN v_failures := v_failures || format('A.5 línea sin unidad: esperaba 3, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_none, v_u_kg, 2);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.6 sin base + unidad base (kg): esperaba 2, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(NULL, v_u_doc, 2);
  IF v_val <> 2 THEN v_failures := v_failures || format('A.7 línea de servicio (sin producto): esperaba 2 tal cual, obtuvo %s', v_val); END IF;

  v_val := public._uom_normalize_quantity(v_p_u, v_u_doc, 2);
  IF v_val <> 24 THEN v_failures := v_failures || format('A.8 base u + 2 docenas: esperaba 24, obtuvo %s', v_val); END IF;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_none, v_u_ml, 0.381);
    v_failures := v_failures || 'A.9 sin base + mL (factor 0.001): no rechazó — es el accidente real del 2026-09-22';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_requires_base_unit' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.9 sin base + mL: esperaba P0400 unit_requires_base_unit, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_l, 1);
    v_failures := v_failures || 'A.10 tipo cruzado (kg vs L): no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.10 tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, v_u_g, 0.00004);
    v_failures := v_failures || format('A.11 cantidad que se anula al redondear: no rechazó (obtuvo %s)', v_val);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('quantity_below_precision' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('A.11 bajo precisión: esperaba P0400 quantity_below_precision, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  BEGIN
    v_val := public._uom_normalize_quantity(v_p_kg, gen_random_uuid(), 1);
    v_failures := v_failures || 'A.12 unidad inexistente: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN
      v_failures := v_failures || format('A.12 unidad inexistente: esperaba P0404, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (A) definición única: 12/12'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (B) Los cinco caminos, misma línea (450 g sobre un producto en kg)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  -- B.1 alta de venta (formulario) — ya convertía; sigue convirtiendo por la
  -- definición única (P0404 de unidad inexistente lo emite el helper).
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 450, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.1 formulario: stock bajó %s, esperaba 0.45', v_before - v_after);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.45 THEN v_failures := v_failures || format('B.1 formulario: quantity_delta %s, esperaba -0.45', v_val); END IF;
  SELECT quantity INTO v_val FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_val IS DISTINCT FROM 450 THEN v_failures := v_failures || format('B.1 formulario: la línea debe conservar 450 (g), tiene %s', v_val); END IF;
  SELECT count(*) INTO v_cnt FROM public.sale_items WHERE sale_id = v_sale_id AND unit_id = v_u_g;
  IF v_cnt <> 1 THEN v_failures := v_failures || 'B.1 formulario: la línea perdió su unit_id (g)'; END IF;

  -- B.2 POS (quickSale → _c29_confirm_order_core) — antes descontaba 450.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_quick_sale(
    p_idempotency_key => 'vuc-b2-' || gen_random_uuid()::text,
    p_client_id       => NULL,
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'quantity', 450, 'price', 1.00, 'subtotal', 450.00, 'unit_id', v_u_g)),
    p_payment_method  => 'other',
    p_branch_id       => v_branch_a
  );
  v_so_id := (v_result->>'sales_order_id')::uuid;
  v_op2   := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_before - v_after <> 0.45 THEN
    v_failures := v_failures || format('B.2 POS: stock bajó %s, esperaba 0.45 (antes del change: 450)', v_before - v_after);
  END IF;
  SELECT quantity INTO v_val FROM public.sales_order_items WHERE sales_order_id = v_so_id;
  IF v_val IS DISTINCT FROM 450 THEN v_failures := v_failures || format('B.2 POS: la línea de la orden debe conservar 450, tiene %s', v_val); END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements sm JOIN public.sales s ON s.id = sm.reference_id
  WHERE s.operation_id = v_op2 AND sm.reference_type = 'sale' AND sm.product_id = v_p_kg ORDER BY sm.created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.45 THEN v_failures := v_failures || format('B.2 POS: quantity_delta %s, esperaba -0.45', v_val); END IF;

  -- B.3 edición de venta (la de B.1): 450 g → 300 g. REVERSE +0.45 por delta
  -- guardado (D6), APPLY -0.3 normalizada. Antes: +450 y -300.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 300, 'unit_id', v_u_g))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 0.15 THEN
    v_failures := v_failures || format('B.3 edición venta: stock cambió %s, esperaba +0.15 (= +0.45 - 0.30)', v_after - v_before);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 0.45 THEN v_failures := v_failures || format('B.3 edición venta: pata REVERSE %s, esperaba +0.45', v_val); END IF;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -0.3 THEN v_failures := v_failures || format('B.3 edición venta: pata APPLY %s, esperaba -0.3', v_val); END IF;
  SELECT quantity INTO v_val FROM public.sale_items WHERE sale_id = v_sale_id;
  IF v_val IS DISTINCT FROM 300 THEN v_failures := v_failures || format('B.3 edición venta: la línea nueva debe tener 300 (g), tiene %s', v_val); END IF;

  -- B.4 alta de compra: 2000 g → +2.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_create_purchase_operation(
    'vuc-b4-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate VUC',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 2000, 'unit_id', v_u_g)),
    v_branch_a
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 2 THEN
    v_failures := v_failures || format('B.4 compra: stock subió %s, esperaba 2', v_after - v_before);
  END IF;
  SELECT quantity INTO v_val FROM public.purchases WHERE id = v_purch_id;
  IF v_val IS DISTINCT FROM 2000 THEN v_failures := v_failures || format('B.4 compra: la línea debe conservar 2000 (g), tiene %s', v_val); END IF;

  -- B.5 edición de compra: 2000 g → 1500 g. REVERSE -2 (delta guardado), APPLY +1.5.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  v_result := public.rpc_atomic_update_purchase_operation(
    ARRAY[v_purch_id], CURRENT_DATE, 'Compra gate VUC editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1500, 'unit_id', v_u_g))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> -0.5 THEN
    v_failures := v_failures || format('B.5 edición compra: stock cambió %s, esperaba -0.5 (= -2 + 1.5)', v_after - v_before);
  END IF;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_purch_id AND reference_type = 'purchase_update' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM -2 THEN v_failures := v_failures || format('B.5 edición compra: pata REVERSE %s, esperaba -2', v_val); END IF;
  SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = v_op AND product_id = v_p_kg;
  SELECT quantity_delta INTO v_val FROM public.stock_movements WHERE reference_id = v_purch_id AND reference_type = 'purchase' ORDER BY created_at DESC LIMIT 1;
  IF v_val IS DISTINCT FROM 1.5 THEN v_failures := v_failures || format('B.5 edición compra: pata APPLY %s, esperaba +1.5', v_val); END IF;

  -- B.6 producto con base g vende 0.5 kg → -500 (relativa al producto, D1).
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b6-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_g, 'amount', 20.00, 'quantity', 0.5, 'unit_id', v_u_kg)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  IF v_before - v_after <> 500 THEN
    v_failures := v_failures || format('B.6 base g + 0.5 kg: stock bajó %s, esperaba 500', v_before - v_after);
  END IF;

  -- B.7 producto sin unidad base: kg (factor 1) se acepta tal cual; mL se rechaza.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_none AND branch_id = v_branch_a;
  v_result := public.rpc_create_sale_operation(
    'vuc-b7-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_none, 'amount', 200.00, 'quantity', 2, 'unit_id', v_u_kg)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_none AND branch_id = v_branch_a;
  IF v_before - v_after <> 2 THEN
    v_failures := v_failures || format('B.7 sin base + kg: stock bajó %s, esperaba 2', v_before - v_after);
  END IF;
  SELECT count(*) INTO v_cnt FROM public.stock_movements WHERE product_id = v_p_none;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-b7b-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_none, 'amount', 200.00, 'quantity', 0.381, 'unit_id', v_u_ml)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'B.7 sin base + mL: la venta no se rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_requires_base_unit' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('B.7 sin base + mL: esperaba P0400 unit_requires_base_unit, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE product_id = v_p_none;
  IF v_cnt2 <> v_cnt THEN v_failures := v_failures || 'B.7 sin base + mL: dejó movimiento de stock pese al rechazo'; END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (B) cinco caminos: 7/7'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (C) Tipo cruzado sin rastro en cada camino · borrado · invariante
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT count(*) INTO v_cnt  FROM public.stock_movements WHERE product_id = v_p_kg;
  SELECT count(*) INTO v_cnt2 FROM public.sales WHERE product_id = v_p_kg;

  -- C.1 formulario
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      'vuc-c1-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 1, 'unit_id', v_u_l)),
      v_branch_a, NULL
    );
    v_failures := v_failures || 'C.1 formulario tipo cruzado: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.1 formulario tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- C.2 POS
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key => 'vuc-c2-' || gen_random_uuid()::text,
      p_client_id       => NULL,
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'quantity', 1, 'price', 1.00, 'subtotal', 1.00, 'unit_id', v_u_l)),
      p_payment_method  => 'other',
      p_branch_id       => v_branch_a
    );
    v_failures := v_failures || 'C.2 POS tipo cruzado: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.2 POS tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_val FROM public.sales_orders so JOIN public.sales_order_items soi ON soi.sales_order_id = so.id
  WHERE so.account_id = v_account_a AND soi.product_id = v_p_kg AND soi.unit_id = v_u_l;
  IF v_val <> 0 THEN v_failures := v_failures || 'C.2 POS tipo cruzado: quedó una orden con la línea rechazada'; END IF;

  -- C.3 edición de venta (la venta vigente de B.3, 300 g): reemplazo por L.
  SELECT count(*) INTO v_val FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update';
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 1, 'unit_id', v_u_l))
    );
    v_failures := v_failures || 'C.3 edición venta tipo cruzado: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.3 edición venta tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE reference_id = v_sale_id AND reference_type = 'sale_update';
  IF v_cnt2 <> v_val THEN v_failures := v_failures || 'C.3 edición venta tipo cruzado: dejó una pata REVERSE pese al rechazo'; END IF;
  SELECT count(*) INTO v_cnt2 FROM public.sales WHERE id = v_sale_id;
  IF v_cnt2 <> 1 THEN v_failures := v_failures || 'C.3 edición venta tipo cruzado: la venta vieja no quedó intacta'; END IF;

  -- C.4 alta de compra
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      'vuc-c4-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra cruzada VUC',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1, 'unit_id', v_u_l)),
      v_branch_a
    );
    v_failures := v_failures || 'C.4 compra tipo cruzado: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.4 compra tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- C.5 edición de compra (la compra vigente de B.5, 1500 g)
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      ARRAY[v_purch_id], CURRENT_DATE, 'Compra cruzada VUC editada',
      jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 0.50, 'quantity', 1, 'unit_id', v_u_l))
    );
    v_failures := v_failures || 'C.5 edición compra tipo cruzado: no rechazó';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' OR position('unit_type_mismatch' IN SQLERRM) = 0 THEN
      v_failures := v_failures || format('C.5 edición compra tipo cruzado: esperaba P0400 unit_type_mismatch, obtuvo %s %s', SQLSTATE, SQLERRM);
    END IF;
  END;
  SELECT count(*) INTO v_cnt2 FROM public.purchases WHERE id = v_purch_id;
  IF v_cnt2 <> 1 THEN v_failures := v_failures || 'C.5 edición compra tipo cruzado: la compra vieja no quedó intacta'; END IF;

  -- Cero rastro global sobre el producto en kg: ni movimientos ni ventas nuevas.
  SELECT count(*) INTO v_cnt2 FROM public.stock_movements WHERE product_id = v_p_kg;
  IF v_cnt2 <> v_cnt THEN v_failures := v_failures || format('C tipo cruzado: los rechazos dejaron %s movimientos de stock', v_cnt2 - v_cnt); END IF;

  -- C.6 borrado de la venta del POS (B.2, -0.45): la reversa devuelve lo normalizado.
  SELECT quantity INTO v_before FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_delete_sale_operation(p_operation_id => v_op2);
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after - v_before <> 0.45 THEN
    v_failures := v_failures || format('C.6 borrado: stock cambió %s, esperaba +0.45', v_after - v_before);
  END IF;

  -- C.7 invariante SUM(quantity_delta) = branch_stock.quantity con unidades mixtas.
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_val <> v_after THEN v_failures := v_failures || format('C.7 invariante (kg): SUM(delta)=%s ≠ branch_stock=%s', v_val, v_after); END IF;
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE product_id = v_p_g AND branch_id = v_branch_a;
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_g AND branch_id = v_branch_a;
  IF v_val <> v_after THEN v_failures := v_failures || format('C.7 invariante (g): SUM(delta)=%s ≠ branch_stock=%s', v_val, v_after); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (C) rechazos sin rastro, borrado e invariante: 7/7'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (D) Umbral de stock mínimo fraccionario
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_result := public.rpc_set_product_min_stock(v_p_kg, 0.5);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 0.5 THEN v_failures := v_failures || format('D.1 min_stock 0.5 no se propagó: branch_stock.min_stock = %s', v_val); END IF;
  IF (v_result->>'min_stock')::numeric <> 0.5 THEN v_failures := v_failures || format('D.1 la RPC devolvió min_stock = %s', v_result->>'min_stock'); END IF;

  -- Dejar el stock en 0.6 y vender 200 g → 0.4 ≤ 0.5 dispara la alerta.
  PERFORM public.rpc_adjust_branch_stock(v_p_kg, v_branch_a, 0.6, 'ajuste gate VUC D');
  SELECT id INTO v_bs_id FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  PERFORM public.rpc_create_sale_operation(
    'vuc-d2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p_kg, 'amount', 1.00, 'quantity', 200, 'unit_id', v_u_g)),
    v_branch_a, NULL
  );
  SELECT quantity INTO v_after FROM public.branch_stock WHERE product_id = v_p_kg AND branch_id = v_branch_a;
  IF v_after <> 0.4 THEN v_failures := v_failures || format('D.2 stock tras la venta = %s, esperaba 0.4', v_after); END IF;
  SELECT count(*) INTO v_cnt FROM public.email_logs
  WHERE event_type = 'low_branch_stock_alert' AND metadata::text LIKE '%' || v_p_kg::text || '%';
  IF v_cnt < 1 THEN v_failures := v_failures || 'D.2 la alerta low_branch_stock_alert no se disparó con umbral 0.5 y stock 0.4'; END IF;
  SELECT count(*) INTO v_cnt FROM public.events
  WHERE account_id = v_account_a AND event_type = 'StockBelowMinimum' AND aggregate_id = v_bs_id;
  IF v_cnt < 1 THEN v_failures := v_failures || 'D.2 el evento StockBelowMinimum no se emitió'; END IF;
  SELECT public.get_dashboard_critical_stock(v_branch_a) INTO v_val;
  IF v_val < 1 THEN v_failures := v_failures || format('D.2 get_dashboard_critical_stock no cuenta el producto (%s)', v_val); END IF;
  SELECT count(*) INTO v_cnt FROM public.get_dashboard_critical_stock_items(v_branch_a, 50) i WHERE i.product_id = v_p_kg AND i.min_stock = 0.5;
  IF v_cnt <> 1 THEN v_failures := v_failures || 'D.2 get_dashboard_critical_stock_items no devuelve el producto con min_stock 0.5'; END IF;

  -- D.3 mínimo entero de un producto por unidad: intacto.
  PERFORM public.rpc_set_product_min_stock(v_p_u, 5);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 5 THEN v_failures := v_failures || format('D.3 min_stock entero cambió: %s', v_val); END IF;

  -- D.4 negativo → 0 (red del servidor; el 422 lo pone Pydantic).
  PERFORM public.rpc_set_product_min_stock(v_p_u, -1);
  SELECT min_stock INTO v_val FROM public.branch_stock WHERE product_id = v_p_u AND branch_id = v_branch_a;
  IF v_val IS DISTINCT FROM 0 THEN v_failures := v_failures || format('D.4 min_stock negativo no se saturó en 0: %s', v_val); END IF;

  -- D.5 la vista de compatibilidad expone el mínimo fraccionario.
  SELECT min_stock INTO v_val FROM public.v_products_with_stock WHERE id = v_p_kg;
  IF v_val IS DISTINCT FROM 0.5 THEN v_failures := v_failures || format('D.5 v_products_with_stock.min_stock = %s, esperaba 0.5', v_val); END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (D) umbral fraccionario: 5/5'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (E) Introspección (espejo del gate embebido, para migraciones posteriores)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  FOREACH v_fn IN ARRAY ARRAY[
    '_c29_confirm_order_core', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
    'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation'
  ] LOOP
    SELECT replace(p.prosrc, E'\r', '') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_src IS NULL THEN v_failures := v_failures || ('E ' || v_fn || ': no existe'); CONTINUE; END IF;
    IF position('public._uom_normalize_quantity(' IN v_src) = 0 THEN v_failures := v_failures || ('E ' || v_fn || ': no invoca _uom_normalize_quantity'); END IF;
    IF v_src ~ '\*\s*v_unit_factor' THEN v_failures := v_failures || ('E ' || v_fn || ': conserva la multiplicación inline'); END IF;
    IF position('v_qty_norm := v_item.quantity;' IN v_src) > 0 THEN v_failures := v_failures || ('E ' || v_fn || ': descuenta la cantidad cruda'); END IF;
  END LOOP;

  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_sale_operation';
  IF v_src ~ '-v_item\.quantity,\s*''sale''' OR v_src ~ 'v_old_sale\.quantity,\s*''sale_return''' THEN
    v_failures := v_failures || 'E rpc_atomic_update_sale_operation: alguna pata usa la cantidad cruda';
  END IF;
  SELECT replace(p.prosrc, E'\r', '') INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_atomic_update_purchase_operation';
  IF v_src ~ 'v_item\.quantity,\s*''purchase''' OR v_src ~ '-v_old_purchase\.quantity,\s*''purchase_return''' THEN
    v_failures := v_failures || 'E rpc_atomic_update_purchase_operation: alguna pata usa la cantidad cruda';
  END IF;

  SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity';
  IF v_cnt <> 1 THEN v_failures := v_failures || format('E _uom_normalize_quantity: %s definiciones', v_cnt); END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = '_uom_normalize_quantity' AND p.prosecdef) THEN
    v_failures := v_failures || 'E _uom_normalize_quantity: es SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._uom_normalize_quantity(uuid, uuid, numeric)', 'EXECUTE') THEN
    v_failures := v_failures || 'E _uom_normalize_quantity: ejecutable por anon/authenticated';
  END IF;

  SELECT count(*), max(pg_get_function_identity_arguments(p.oid)) INTO v_cnt, v_txt
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_set_product_min_stock';
  IF v_cnt <> 1 OR v_txt IS DISTINCT FROM 'p_product_id uuid, p_min_stock numeric' THEN
    v_failures := v_failures || format('E rpc_set_product_min_stock: %s firmas, "%s"', v_cnt, v_txt);
  END IF;
  IF has_function_privilege('anon', 'public.rpc_set_product_min_stock(uuid, numeric)', 'EXECUTE') THEN
    v_failures := v_failures || 'E rpc_set_product_min_stock: ejecutable por anon';
  END IF;

  SELECT data_type || '/' || numeric_scale::text INTO v_txt FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'branch_stock' AND column_name = 'min_stock';
  IF v_txt IS DISTINCT FROM 'numeric/4' THEN v_failures := v_failures || format('E branch_stock.min_stock: %s', v_txt); END IF;

  SELECT count(*), max(pg_get_function_result(p.oid)) INTO v_cnt, v_txt
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_dashboard_critical_stock_items';
  IF v_cnt <> 1 OR v_txt !~ 'min_stock numeric' THEN v_failures := v_failures || format('E get_dashboard_critical_stock_items: %s firmas, "%s"', v_cnt, v_txt); END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public' AND c.relname = 'v_products_with_stock' AND c.relkind = 'v'
                   AND c.reloptions::text LIKE '%security_invoker=true%') THEN
    v_failures := v_failures || 'E v_products_with_stock: falta o sin security_invoker';
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN RAISE NOTICE 'PASS (E) introspección'; END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Cleanup (DELETE FROM accounts cascadea; branches/accounts con guard →
  -- replica; events/email_logs/idempotency no cascadean por cuenta).
  -- ═══════════════════════════════════════════════════════════════════════
  DELETE FROM public.events                WHERE account_id = v_account_a;
  DELETE FROM public.email_logs            WHERE user_id = v_user_a OR metadata::text LIKE '%' || v_account_a::text || '%';
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_a;
  SET session_replication_role = replica;
  -- sales_orders.created_by → auth.users sin cascade: las órdenes del POS
  -- (incluida la cancelada por el borrado de C.6) hay que retirarlas antes
  -- del usuario. El resto cascadea desde accounts.
  DELETE FROM public.document_status_history WHERE account_id = v_account_a;
  DELETE FROM public.sales_order_items     WHERE account_id = v_account_a;
  DELETE FROM public.sales_orders          WHERE account_id = v_account_a;
  DELETE FROM public.branches              WHERE account_id = v_account_a;
  DELETE FROM public.accounts              WHERE id = v_account_a;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id = v_account_a;
  DELETE FROM public.account_members       WHERE user_id = v_user_a;
  DELETE FROM public.profiles              WHERE id = v_user_a;
  DELETE FROM auth.users                   WHERE id = v_user_a;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ventas-unidades-conversion FAILED (% fallos):\n  %',
      array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE ventas-unidades-conversion: PASS';

EXCEPTION WHEN OTHERS THEN
  BEGIN
    DELETE FROM public.events                WHERE account_id = v_account_a;
    DELETE FROM public.email_logs            WHERE user_id = v_user_a OR metadata::text LIKE '%' || v_account_a::text || '%';
    DELETE FROM public.operation_idempotency WHERE user_id = v_user_a;
    SET session_replication_role = replica;
    DELETE FROM public.document_status_history WHERE account_id = v_account_a;
    DELETE FROM public.sales_order_items     WHERE account_id = v_account_a;
    DELETE FROM public.sales_orders          WHERE account_id = v_account_a;
    DELETE FROM public.branches              WHERE account_id = v_account_a;
    DELETE FROM public.accounts              WHERE id = v_account_a;
    SET session_replication_role = DEFAULT;
    DELETE FROM public.account_feature_flags WHERE account_id = v_account_a;
    DELETE FROM public.account_members       WHERE user_id = v_user_a;
    DELETE FROM public.profiles              WHERE id = v_user_a;
    DELETE FROM auth.users                   WHERE id = v_user_a;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RAISE;
END $$;
