-- =============================================================================
-- test_ventas_formulario_sucursal.sql — Gate de comportamiento del fix ad-hoc
-- `ventas-formulario-sucursal`.
--
-- Contexto. El alta de una venta desde el formulario descartaba la sucursal
-- elegida en CUATRO eslabones de la capa de aplicación (hook, esquema Pydantic,
-- servicio, repositorio): la RPC rpc_create_sale_operation ya aceptaba
-- p_branch_id, pero nadie se lo pasaba, así que la venta quedaba con
-- sales.branch_id = NULL y el stock/caja/banco se resolvían contra la sucursal
-- POR DEFECTO. El fix es 100% de aplicación (SIN migración, SIN cambios de
-- función), así que ESTE gate fija el contrato de base que el fix empieza a
-- usar de verdad — hasta hoy ningún gate lo EJECUTABA: los bloques de runtime de
-- test_branch_stock.sql están comentados, y los gates que pasan p_branch_id
-- (test_pagos_cableados_restantes, test_ventas_unidades_conversion,
-- test_pos_banco_movimientos, ...) lo hacen con una sola sucursal activa o sin
-- mirar sales.branch_id / stock_movements.branch_id, así que no distinguen "la
-- elegida" de "la default".
--
-- Qué verifica (todo contra Postgres real, llamando a la RPC como el backend):
--   (1) Alta con sucursal elegida (NO default), operación de 2 líneas:
--       sales.branch_id = la elegida en TODAS las líneas; stock_movements.
--       branch_id = la elegida; branch_stock se descuenta en la elegida y la
--       default NO se toca.
--   (2) Sin sucursal (NULL) — contrato VIGENTE que el fix NO cambia: la venta
--       sigue con branch_id NULL (lo dice la spec `branches`, asociación
--       opcional) y el stock sale de la default.
--   (3) Stock insuficiente EN LA ELEGIDA aunque la default tenga de sobra:
--       P0409 insufficient_branch_stock, nada persistido; la misma venta sin
--       sucursal SÍ pasa (el gate es por sucursal elegida).
--   (4) Sucursal ajena, inactiva → P0404; cerrada → P0422.
--   (5) Caja: el opt-in exige la sesión de la sucursal ELEGIDA (la de la default
--       se rechaza con P0422) y el movimiento aterriza en esa sesión.
--   (6) Banco: el movimiento bancario lleva la sucursal elegida.
--
-- Hallazgo que este gate deja ASERTADO (no corregido: es decisión del PO, ver
-- CHANGES.md): con la sucursal NULL la venta queda con branch_id NULL pero el
-- movimiento bancario nace con la sucursal por defecto (la RPC usa
-- v_gate_branch = COALESCE(elegida, default) para el banco y el stock, y la
-- CRUDA para la fila de la venta). El bloque (2) lo fija: si el PO decide
-- persistir la default cuando no se elige ninguna, ese bloque cambia a propósito.
--
-- Patrón del proyecto (test_edicion_preserva_contexto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user; sesión simulada con set_config LOCAL a la transacción de este
-- archivo — NUNCA usar este patrón contra prod.
--
-- 🛑 created_at EXPLÍCITO y estrictamente POSTERIOR en las sucursales sintéticas
-- (mismo motivo que test_gastos_forma_pago.sql): c26_default_branch() ordena por
-- created_at SIN desempate, y branches.created_at = now() es el timestamp de la
-- TRANSACCIÓN, así que la sucursal que handle_new_user auto-provisiona y las de
-- este fixture nacerían con el MISMO created_at al microsegundo y la "default"
-- saldría a suerte — el gate sería flaky. Se fuerza y se ASSERTA.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';
  v_fail_before     integer;

  -- Anchor A: cuenta principal.
  v_email_a         text := 'ventas-formulario-sucursal-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_def      uuid;  -- default (auto-provisionada, la más vieja)
  v_branch_b        uuid;  -- la ELEGIDA: activa, no default
  v_branch_closed   uuid;  -- activa pero status = 'closed'
  v_branch_inactive uuid;  -- is_active = false
  v_client_a        uuid;
  v_p1              uuid;  -- stock en default (100) y en B (10)
  v_p2              uuid;  -- stock en default (100) y en B (10)
  v_p3              uuid;  -- stock SÓLO en default (100): B nunca lo tuvo
  v_pm_cash         uuid;
  v_pm_transfer     uuid;
  v_bank_a          uuid;
  v_cashbox_def     uuid;
  v_cashbox_b       uuid;
  v_session_def     uuid;
  v_session_b       uuid;

  -- Anchor B: cuenta ajena, sólo para la sucursal "de otra cuenta".
  v_email_b         text := 'ventas-formulario-sucursal-b@test.local';
  v_user_b          uuid := gen_random_uuid();
  v_account_b       uuid;
  v_branch_foreign  uuid;

  v_today           date := public.reporting_local_today();
  v_result          jsonb;
  v_op              uuid;
  v_n               integer;
  v_val             numeric;
  v_uuid            uuid;
  v_state           text;
  v_msg             text;
  v_def_before      numeric;
  v_b_before        numeric;
  v_table           text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor A
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Ventas Formulario Sucursal A', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor A — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_def FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Sucursal VFS B (elegida)', TRUE, 'active', now(), now() + interval '1 minute')
  RETURNING id INTO v_branch_b;

  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (v_account_a, 'Sucursal VFS Cerrada', TRUE, 'closed', now(), now(), now() + interval '2 minutes')
  RETURNING id INTO v_branch_closed;

  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Sucursal VFS Inactiva', FALSE, 'active', now(), now() + interval '3 minutes')
  RETURNING id INTO v_branch_inactive;

  -- Candado del determinismo de arriba. NO se escribe como
  -- `c26_default_branch(A) = v_branch_def` (con un empate esa comparación
  -- resuelve la ambigüedad según el plan de ESA llamada y puede dar verde
  -- mientras la llamada de adentro de la RPC devuelve otra fila): se asserta la
  -- AMBIGÜEDAD misma — la auto-provisionada tiene que ser ESTRICTAMENTE la más
  -- vieja de A.
  SELECT COUNT(*) INTO v_n
  FROM public.branches b
  WHERE b.account_id = v_account_a
    AND b.id <> v_branch_def
    AND b.created_at <= (SELECT created_at FROM public.branches WHERE id = v_branch_def);
  IF v_n > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-FORMULARIO-SUCURSAL (setup): % sucursal(es) de A empatan o preceden a la auto-provisionada en created_at. c26_default_branch() ordena por created_at SIN desempate: la "default" saldría a suerte y el gate sería flaky.', v_n;
  END IF;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate VFS')
  RETURNING id INTO v_client_a;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto VFS P1', 'VFS-P1', 60.00, 100.00)
  RETURNING id INTO v_p1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_def, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_b, 10);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto VFS P2', 'VFS-P2', 60.00, 100.00)
  RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_def, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_b, 10);

  -- P3: stock SÓLO en la default. Es el producto del caso "la elegida no
  -- alcanza aunque la default tenga de sobra" — el que el defecto ocultaba.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto VFS P3 (sólo default)', 'VFS-P3', 60.00, 100.00)
  RETURNING id INTO v_p3;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p3, v_branch_def, 100);

  -- Formas de pago sembradas por handle_new_user (cash / transfer / ...).
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'     LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_transfer IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: el catálogo de formas de pago no trae cash/transfer para el anchor A';
  END IF;

  -- Banco: transfer imputa a esta cuenta por default (sin override).
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_account_a, '__gate_vfs_bank_a__', 'ARS', 0, TRUE)
  RETURNING id INTO v_bank_a;
  UPDATE public.payment_methods SET bank_account_id = v_bank_a WHERE id = v_pm_transfer;

  -- Cajas: una por sucursal (la default puede traer la suya auto-provisionada).
  SELECT id INTO v_cashbox_def FROM public.cashboxes WHERE branch_id = v_branch_def ORDER BY created_at LIMIT 1;
  IF v_cashbox_def IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_branch_def, '__gate_vfs_cashbox_def__', 'ARS')
    RETURNING id INTO v_cashbox_def;
  END IF;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id = v_branch_b ORDER BY created_at LIMIT 1;
  IF v_cashbox_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_branch_b, '__gate_vfs_cashbox_b__', 'ARS')
    RETURNING id INTO v_cashbox_b;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor B (cuenta ajena)
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Ventas Formulario Sucursal B', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b
  FROM   public.account_members
  WHERE  user_id = v_user_b
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor B';
  END IF;

  SELECT id INTO v_branch_foreign FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  -- ── Sesión sintética del anchor A ──────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION 'SETUP FAILED: auth.uid() no resuelve al anchor A con request.jwt.claims local — el gate no puede invocar las RPCs';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (1) Alta con sucursal ELEGIDA (no default), operación de dos líneas
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT quantity INTO v_def_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_def;
  SELECT quantity INTO v_b_before   FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_b;

  v_result := public.rpc_create_sale_operation(
    p_idempotency_key => 'vfs-1-' || gen_random_uuid()::text,
    p_client_id       => v_client_a,
    p_date            => v_today,
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(
                           jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2),
                           jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
    p_branch_id       => v_branch_b
  );
  v_op := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op;
  IF v_n <> 2 THEN
    v_failures := array_append(v_failures, format('FAIL (1 líneas): la operación debía tener 2 filas en sales, tiene %s', v_n));
  END IF;

  SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_branch_b;
  IF v_n <> 2 THEN
    v_failures := array_append(v_failures, format('FAIL (1 sales.branch_id): las 2 líneas debían quedar con la sucursal ELEGIDA %s, %s la tienen', v_branch_b, v_n));
  END IF;

  SELECT COUNT(*) INTO v_n
  FROM public.stock_movements sm
  WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id = v_branch_b;
  IF v_n <> 2 THEN
    v_failures := array_append(v_failures, format('FAIL (1 stock_movements.branch_id): los 2 movimientos de venta debían llevar la sucursal elegida, %s la llevan', v_n));
  END IF;

  SELECT sm.quantity_delta INTO v_val
  FROM public.stock_movements sm
  WHERE sm.operation_group_id = v_op AND sm.product_id = v_p1;
  IF v_val IS DISTINCT FROM -2 THEN
    v_failures := array_append(v_failures, format('FAIL (1 quantity_delta): esperaba -2 para P1, obtuvo %s', v_val));
  END IF;

  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_b;
  IF v_val IS DISTINCT FROM v_b_before - 2 THEN
    v_failures := array_append(v_failures, format('FAIL (1 stock elegida): branch_stock de la ELEGIDA debía bajar de %s a %s, quedó %s', v_b_before, v_b_before - 2, v_val));
  END IF;

  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_def;
  IF v_val IS DISTINCT FROM v_def_before THEN
    v_failures := array_append(v_failures, format('FAIL (1 stock default): la sucursal por DEFECTO no debía tocarse (era %s), quedó %s — el stock se descontó de la sucursal equivocada', v_def_before, v_val));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (1): alta con sucursal elegida — sales.branch_id y stock_movements.branch_id = la elegida en las 2 líneas; branch_stock baja en la elegida y la default queda intacta';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (2) Sin sucursal (NULL): contrato VIGENTE, el fix NO lo cambia
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT quantity INTO v_def_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_def;
  SELECT quantity INTO v_b_before   FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_b;

  v_result := public.rpc_create_sale_operation(
    p_idempotency_key => 'vfs-2-' || gen_random_uuid()::text,
    p_client_id       => v_client_a,
    p_date            => v_today,
    p_currency        => 'ARS',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1))
  );
  v_op := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id IS NULL;
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (2 sales.branch_id NULL): sin sucursal elegida la venta debía quedar con branch_id NULL (spec `branches`: asociación opcional), %s filas lo tienen NULL', v_n));
  END IF;

  SELECT COUNT(*) INTO v_n
  FROM public.stock_movements sm
  WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id IS NULL;
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (2 stock_movements.branch_id NULL): el movimiento de stock sin sucursal elegida debía llevar branch_id NULL, %s lo llevan NULL', v_n));
  END IF;

  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_def;
  IF v_val IS DISTINCT FROM v_def_before - 1 THEN
    v_failures := array_append(v_failures, format('FAIL (2 stock default): sin sucursal el stock sale de la DEFAULT: esperaba %s, quedó %s', v_def_before - 1, v_val));
  END IF;

  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_b;
  IF v_val IS DISTINCT FROM v_b_before THEN
    v_failures := array_append(v_failures, format('FAIL (2 stock B): la sucursal B no debía tocarse (era %s), quedó %s', v_b_before, v_val));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2): sin sucursal elegida la venta queda con branch_id NULL y el stock sale de la default (contrato vigente, sin cambios)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (3) Stock insuficiente EN LA ELEGIDA aunque la default tenga de sobra
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT quantity INTO v_def_before FROM public.branch_stock WHERE product_id = v_p3 AND branch_id = v_branch_def;

  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-3-sin-stock',
      p_client_id       => v_client_a,
      p_date            => v_today,
      p_currency        => 'ARS',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 5)),
      p_branch_id       => v_branch_b
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0409' OR position('insufficient_branch_stock' IN COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 P0409): vender 5 de P3 desde B (que no tiene) debía fallar con P0409 insufficient_branch_stock; obtuvo %s / %s', v_state, v_msg));
  END IF;

  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE idempotency_key = 'vfs-3-sin-stock';
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 rollback): el alta rechazada dejó %s fila(s) de idempotencia — la transacción no revirtió', v_n));
  END IF;

  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p3 AND branch_id = v_branch_def;
  IF v_val IS DISTINCT FROM v_def_before THEN
    v_failures := array_append(v_failures, format('FAIL (3 stock default): el alta rechazada tocó el stock de la default (era %s, quedó %s)', v_def_before, v_val));
  END IF;

  -- Contrapunto: la MISMA venta sin sucursal SÍ pasa (la default tiene 100) —
  -- prueba que el rechazo de arriba es por la sucursal ELEGIDA y no por el
  -- producto o la cantidad.
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-3-sin-sucursal-' || gen_random_uuid()::text,
      p_client_id       => v_client_a,
      p_date            => v_today,
      p_currency        => 'ARS',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 5))
    );
  EXCEPTION WHEN OTHERS THEN
    v_failures := array_append(v_failures, format('FAIL (3 contrapunto): la misma venta sin sucursal debía pasar, falló con %s / %s', SQLSTATE, SQLERRM));
  END;
  SELECT quantity INTO v_val FROM public.branch_stock WHERE product_id = v_p3 AND branch_id = v_branch_def;
  IF v_val IS DISTINCT FROM v_def_before - 5 THEN
    v_failures := array_append(v_failures, format('FAIL (3 contrapunto): la misma venta sin sucursal debía descontar 5 de la default (%s -> %s), quedó %s', v_def_before, v_def_before - 5, v_val));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (3): la elegida sin stock rechaza con P0409 aunque la default alcance (nada persistido); la misma venta sin sucursal pasa';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (4) Sucursal ajena / inactiva → P0404; cerrada → P0422
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-4-ajena', p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1)),
      p_branch_id => v_branch_foreign
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0404' THEN
    v_failures := array_append(v_failures, format('FAIL (4 ajena): una sucursal de OTRA cuenta debía rechazarse con P0404, obtuvo %s / %s', v_state, v_msg));
  END IF;

  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-4-inactiva', p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1)),
      p_branch_id => v_branch_inactive
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0404' THEN
    v_failures := array_append(v_failures, format('FAIL (4 inactiva): una sucursal inactiva debía rechazarse con P0404, obtuvo %s / %s', v_state, v_msg));
  END IF;

  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-4-cerrada', p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1)),
      p_branch_id => v_branch_closed
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0422' OR position('branch_closed' IN COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 cerrada): una sucursal cerrada debía rechazarse con P0422 branch_closed, obtuvo %s / %s', v_state, v_msg));
  END IF;

  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE idempotency_key IN ('vfs-4-ajena', 'vfs-4-inactiva', 'vfs-4-cerrada');
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 rollback): los rechazos de sucursal dejaron %s fila(s) de idempotencia', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (4): sucursal ajena e inactiva -> P0404, cerrada -> P0422, sin nada persistido';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (5) Caja: el opt-in exige la sesión de la sucursal ELEGIDA
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  SELECT public.rpc_open_cash_session(v_cashbox_def, 500) INTO v_result;
  v_session_def := COALESCE((v_result->>'session_id')::uuid, (v_result->>'id')::uuid);
  IF v_session_def IS NULL THEN
    SELECT id INTO v_session_def FROM public.cash_sessions WHERE cashbox_id = v_cashbox_def AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;
  SELECT public.rpc_open_cash_session(v_cashbox_b, 300) INTO v_result;
  v_session_b := COALESCE((v_result->>'session_id')::uuid, (v_result->>'id')::uuid);
  IF v_session_b IS NULL THEN
    SELECT id INTO v_session_b FROM public.cash_sessions WHERE cashbox_id = v_cashbox_b AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;
  IF v_session_def IS NULL OR v_session_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (5): no se pudieron abrir las sesiones de caja de la default (%) y de B (%)', v_session_def, v_session_b;
  END IF;

  -- (5a) Venta en B con la sesión de la DEFAULT → rechazada. Antes del fix el
  -- formulario nunca mandaba la sucursal, así que esta combinación pasaba (la
  -- venta caía en la default sin que el usuario lo supiera).
  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-5a', p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1)),
      p_branch_id => v_branch_b, p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_def
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0422' OR position('cash_optin_requires_open_session' IN COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (5a): venta en B con la sesión de caja de la DEFAULT debía rechazarse con P0422 cash_optin_requires_open_session, obtuvo %s / %s', v_state, v_msg));
  END IF;

  -- (5b) Venta en B con la sesión de B → el movimiento aterriza en la sesión de B.
  v_op := NULL;
  BEGIN
    v_result := public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-5b-' || gen_random_uuid()::text, p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)),
      p_branch_id => v_branch_b, p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_b
    );
    v_op := (v_result->>'operation_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_failures := array_append(v_failures, format('FAIL (5b): venta en B con la sesión de B debía pasar, falló con %s / %s', SQLSTATE, SQLERRM));
  END;

  SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_b AND reference_id = v_op AND movement_type = 'sale' AND amount = 200;
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (5b): el movimiento de caja (sale, 200) debía quedar en la sesión de B, hay %s', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_def AND reference_id = v_op;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (5b): la sesión de la default no debía recibir el movimiento, recibió %s', v_n));
  END IF;

  -- (5c) Sin sucursal + sesión de B → rechazada (la efectiva es la default): el
  -- opt-in sigue atado a la sucursal EFECTIVA, que sin elegir ninguna es la default.
  v_state := NULL; v_msg := NULL;
  BEGIN
    PERFORM public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-5c', p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1)),
      p_payment_method_id => v_pm_cash, p_cash_session_id => v_session_b
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  IF v_state IS DISTINCT FROM 'P0422' OR position('cash_optin_requires_open_session' IN COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (5c): sin sucursal elegida la sucursal efectiva es la default: la sesión de B debía rechazarse con P0422, obtuvo %s / %s', v_state, v_msg));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (5): caja — el opt-in exige la sesión de la sucursal elegida y el movimiento aterriza ahí; sin sucursal rige la default';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (6) Banco: el movimiento bancario lleva la sucursal elegida
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_op := NULL;
  BEGIN
    v_result := public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-6b-' || gen_random_uuid()::text, p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
      p_branch_id => v_branch_b, p_payment_method_id => v_pm_transfer
    );
    v_op := (v_result->>'operation_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_failures := array_append(v_failures, format('FAIL (6 banco, elegida): la venta por transferencia en B debía pasar, falló con %s / %s', SQLSTATE, SQLERRM));
  END;
  SELECT branch_id INTO v_uuid FROM public.bank_movements WHERE source_doc_type = 'sale' AND source_doc_ref = v_op;
  IF v_uuid IS DISTINCT FROM v_branch_b THEN
    v_failures := array_append(v_failures, format('FAIL (6 banco, elegida): el movimiento bancario debía llevar la sucursal ELEGIDA %s, lleva %s', v_branch_b, v_uuid));
  END IF;

  -- Contrato vigente que este gate deja a la vista (decisión del PO, ver el
  -- encabezado): sin sucursal elegida la venta queda NULL pero el movimiento
  -- bancario nace con la sucursal por defecto.
  v_op := NULL;
  BEGIN
    v_result := public.rpc_create_sale_operation(
      p_idempotency_key => 'vfs-6c-' || gen_random_uuid()::text, p_client_id => v_client_a, p_date => v_today, p_currency => 'ARS',
      p_items => jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
      p_payment_method_id => v_pm_transfer
    );
    v_op := (v_result->>'operation_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_failures := array_append(v_failures, format('FAIL (6 banco, sin sucursal): la venta por transferencia sin sucursal debía pasar, falló con %s / %s', SQLSTATE, SQLERRM));
  END;
  SELECT branch_id INTO v_uuid FROM public.bank_movements WHERE source_doc_type = 'sale' AND source_doc_ref = v_op;
  IF v_uuid IS DISTINCT FROM v_branch_def THEN
    v_failures := array_append(v_failures, format('FAIL (6 banco, sin sucursal): sin elegir ninguna el movimiento bancario nace con la DEFAULT %s, lleva %s', v_branch_def, v_uuid));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id IS NULL;
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (6 banco, sin sucursal): la fila de venta de esa operación debía quedar con branch_id NULL, %s lo tienen NULL', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (6): banco — el movimiento lleva la sucursal elegida (y la default si no se eligió ninguna)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado
  -- ═══════════════════════════════════════════════════════════════════════
  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE VENTAS-FORMULARIO-SUCURSAL FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE VENTAS-FORMULARIO-SUCURSAL PASSED: la sucursal elegida en el alta queda en sales.branch_id y stock_movements.branch_id, el stock/caja/banco se resuelven contra ELLA (P0409 si no alcanza, P0404/P0422 si es ajena/inactiva/cerrada) y sin elegir ninguna se mantiene el contrato vigente (branch_id NULL, stock de la default).';

  -- ── Limpieza ────────────────────────────────────────────────────────────
  -- Se borra TODA fila con account_id de los dos anchors (incluidas las que
  -- siembra handle_new_user: catálogo de formas de pago, categorías, flags...),
  -- no sólo las que este gate creó. Con session_replication_role = replica los
  -- DELETE no cascadean ni validan FKs, así que un `DELETE FROM accounts` solo
  -- dejaría huérfanas todas las tablas hijas (la fuga de filas por corrida que
  -- ya se midió en otros gates).
  -- sucursal-guard-vaciado-auditoria: branches prohíbe el borrado físico SIEMPRE
  -- (trg_guard_branch_decommission, P0428); session_replication_role sólo lo
  -- puede fijar un rol con privilegio de superusuario (postgres en CI) y no abre
  -- ningún camino para authenticated/anon vía PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.cash_movements WHERE session_id IN (SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id IN (v_account_a, v_account_b));
  DELETE FROM public.cash_sessions  WHERE cashbox_id IN (SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id IN (v_account_a, v_account_b));
  DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id IN ($1, $2)', v_table) USING v_account_a, v_account_b;
  END LOOP;
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.analytics_events      WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;

EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    SET session_replication_role = DEFAULT;
    BEGIN
      SET session_replication_role = replica;
      DELETE FROM public.cash_movements WHERE session_id IN (SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id IN (v_account_a, v_account_b));
      DELETE FROM public.cash_sessions  WHERE cashbox_id IN (SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id IN (v_account_a, v_account_b));
      DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      FOR v_table IN
        SELECT c.table_name
        FROM   information_schema.columns c
        JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
          AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
      LOOP
        EXECUTE format('DELETE FROM public.%I WHERE account_id IN ($1, $2)', v_table) USING v_account_a, v_account_b;
      END LOOP;
      DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
      DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.analytics_events      WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
