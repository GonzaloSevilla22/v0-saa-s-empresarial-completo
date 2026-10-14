-- =============================================================================
-- GATE: test_importador_stock_apertura.sql
-- FIX AD-HOC: importador-productos-stock-apertura (2026-10-14)
--
-- El stock del archivo de importación de productos es un stock de APERTURA:
-- se aplica sólo a los productos que el lote CREA, en la sucursal principal
-- operativa (c26_default_branch), y deja UN movimiento en stock_movements.
-- Reimportar un archivo con un SKU que ya existe NUNCA toca el saldo vivo (antes
-- `ON CONFLICT DO UPDATE SET quantity = EXCLUDED.quantity` pisaba las ventas
-- hechas desde el primer import: vendí 5 de 20, reimporto 20, vuelve a 20), y las
-- celdas vacías de Precio, Stock y Stock mínimo CONSERVAN el valor vigente.
--
-- Qué EJECUTA (rpc_import_products como `authenticated`, con claims reales):
--   (1)  alta con stock: el saldo cae en la principal operativa — NO en la sucursal
--        más antigua (que en el fixture está desactivada) — con UN movimiento de
--        apertura sellado (cuenta, sucursal, autor, antes/después, motivo).
--   (2)  el libro reconcilia: saldo inicial 0 + Σ deltas = saldo vivo.
--   (3)  venta de 5 sobre el producto importado y reimport con OTRO archivo (mismo
--        SKU, stock 20): el saldo queda en 15, no hay movimiento nuevo, el resto de
--        los campos SÍ se actualiza.
--   (4)  celdas vacías al ACTUALIZAR: precio, costo, mínimo y stock conservan; un
--        mínimo informado se actualiza en products y en la sucursal principal.
--   (5)  celdas vacías al CREAR: precio 0, sin movimiento, sin fila de saldo si no
--        hay stock ni mínimo; fila de saldo en 0 con mínimo si lo hay; stock 0
--        explícito no deja movimiento.
--   (6)  un stock negativo es error de fila: el lote se revierte y no queda ni el
--        producto ni un movimiento huérfano.
--   (7)  simulación (p_dry_run): cero escrituras, ni movimiento ni saldo.
--   (8)  SKU repetido dentro del mismo archivo: la primera fila crea con su stock,
--        la segunda actualiza y NO lo pisa; un solo movimiento.
--   (9)  jerarquía: el padre (sin stock) no deja movimiento; cada variante deja el
--        suyo.
--   (10) cuenta sin sucursales: la principal se crea perezosamente (activa) y el
--        movimiento queda sellado con ella.
--   (11) la ACL/firma/COMMENT de rpc_bulk_upsert_products NO cambian (sin EXECUTE
--        para authenticated/anon, service_role sí, una sola firma, DEFINER).
--
-- Regla: se asserta el EFECTO (saldo, filas del libro, SQLSTATE), nunca "no hubo
-- error". Corre dentro de BEGIN..ROLLBACK: residuo cero por construcción.
-- =============================================================================
BEGIN;

CREATE FUNCTION pg_temp.gate_fail(p_step text, p_detail text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'GATE IMPORT-APERTURA FAILED (%): %', p_step, p_detail;
END $f$;

-- Llama a rpc_import_products como un usuario `authenticated` real.
CREATE FUNCTION pg_temp.imp(p_user uuid, p_key text, p_rows jsonb, p_hash text, p_dry boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT public.rpc_import_products(p_key, p_rows, 'gate.csv', p_hash, p_dry) INTO v;
  RESET ROLE;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.bs(p uuid, b uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p AND branch_id = b), 0) $f$;
CREATE FUNCTION pg_temp.bs_rows(p uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::int FROM public.branch_stock WHERE product_id = p $f$;
CREATE FUNCTION pg_temp.mv_n(p uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::int FROM public.stock_movements WHERE product_id = p $f$;
CREATE FUNCTION pg_temp.pid(p_acc uuid, p_sku text) RETURNS uuid LANGUAGE sql AS $f$
  SELECT id FROM public.products WHERE account_id = p_acc AND lower(sku) = lower(p_sku) AND deleted_at IS NULL $f$;

DO $gate$
DECLARE
  v_user   uuid := gen_random_uuid();
  v_user2  uuid := gen_random_uuid();
  v_user3  uuid := gen_random_uuid();
  v_acc    uuid; v_acc2 uuid; v_acc3 uuid;
  v_b_old  uuid;   -- sucursal MÁS ANTIGUA de la cuenta A: queda desactivada
  v_b_main uuid;   -- sucursal principal operativa (c26_default_branch)
  v_r      jsonb;
  v_p      uuid; v_p2 uuid; v_par uuid; v_v1 uuid; v_v2 uuid;
  v_n      integer;
  v_num    numeric;
  v_txt    text;
  v_today  date := public.reporting_local_today();
  v_mv     public.stock_movements%ROWTYPE;
  v_oid    oid;
BEGIN
  -- ── setup: tres cuentas (handle_new_user provisiona cuenta + sucursal) ─────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'gate-imp-apertura-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Apertura A', 'phone', '', 'locality', '', 'province', ''));
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user2, 'authenticated', 'authenticated', 'gate-imp-apertura-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Apertura B', 'phone', '', 'locality', '', 'province', ''));
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user3, 'authenticated', 'authenticated', 'gate-imp-apertura-c@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Apertura C', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_acc  FROM public.account_members WHERE user_id = v_user  ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc2 FROM public.account_members WHERE user_id = v_user2 ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc3 FROM public.account_members WHERE user_id = v_user3 ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL OR v_acc2 IS NULL OR v_acc3 IS NULL THEN
    PERFORM pg_temp.gate_fail('setup', 'handle_new_user no provisionó las tres cuentas sintéticas');
  END IF;

  -- La cuenta A: la sucursal más antigua queda DESACTIVADA y hay otra activa
  -- creada después. c26_default_branch devuelve la segunda; el criterio viejo del
  -- importador (ORDER BY created_at, sin filtrar activas) devolvía la primera.
  SELECT id INTO v_b_old FROM public.branches WHERE account_id = v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc, 'Gate Principal Real', TRUE, 'active', now(), now() + interval '1 minute')
  RETURNING id INTO v_b_main;
  UPDATE public.branches SET is_active = FALSE, status = 'closed' WHERE id = v_b_old;
  IF public.c26_default_branch(v_acc) IS DISTINCT FROM v_b_main THEN
    PERFORM pg_temp.gate_fail('setup', format('c26_default_branch debía ser la sucursal activa creada después (%s) y es %s',
      v_b_main, public.c26_default_branch(v_acc)));
  END IF;

  -- ═══ (1) ALTA con stock: principal operativa + UN movimiento de apertura ════
  v_r := pg_temp.imp(v_user, 'gate-apertura-1',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'GAP-1',
      'price', 100, 'cost', 60, 'stock', 20, 'min_stock', 3)), 'gate-hash-1');
  IF (v_r->>'committed')::boolean IS NOT TRUE OR (v_r->>'inserted')::int <> 1 THEN
    PERFORM pg_temp.gate_fail('1.0', format('el alta no commiteó 1 producto: %s', v_r::text));
  END IF;
  v_p := pg_temp.pid(v_acc, 'GAP-1');
  IF v_p IS NULL THEN PERFORM pg_temp.gate_fail('1.0', 'el producto GAP-1 no se creó'); END IF;

  IF pg_temp.bs(v_p, v_b_main) <> 20 THEN
    PERFORM pg_temp.gate_fail('1.1', format('el stock inicial debía caer en la principal operativa (20) y hay %s; en la más antigua desactivada hay %s',
      pg_temp.bs(v_p, v_b_main), pg_temp.bs(v_p, v_b_old)));
  END IF;
  IF pg_temp.bs_rows(v_p) <> 1 THEN
    PERFORM pg_temp.gate_fail('1.1', format('el producto debía tener UNA fila de saldo y tiene %s', pg_temp.bs_rows(v_p)));
  END IF;
  SELECT min_stock INTO v_num FROM public.branch_stock WHERE product_id = v_p AND branch_id = v_b_main;
  IF v_num IS DISTINCT FROM 3 THEN
    PERFORM pg_temp.gate_fail('1.1b', format('branch_stock.min_stock debía ser 3 y es %s', v_num));
  END IF;

  SELECT count(*) INTO v_n FROM public.stock_movements WHERE product_id = v_p;
  IF v_n <> 1 THEN
    PERFORM pg_temp.gate_fail('1.2', format('el alta con stock debía dejar UN movimiento de apertura y dejó %s', v_n));
  END IF;
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_p;
  IF v_mv.type IS DISTINCT FROM 'adjustment' OR v_mv.quantity_delta <> 20 OR v_mv.quantity_before <> 0 OR v_mv.quantity_after <> 20 THEN
    PERFORM pg_temp.gate_fail('1.3', format('movimiento de apertura mal formado: type=%s delta=%s antes=%s despues=%s',
      v_mv.type, v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after));
  END IF;
  IF v_mv.reason IS DISTINCT FROM 'Stock inicial (importación)' THEN
    PERFORM pg_temp.gate_fail('1.3b', format('el motivo debía ser «Stock inicial (importación)» y es %L', v_mv.reason));
  END IF;
  IF v_mv.account_id IS DISTINCT FROM v_acc OR v_mv.branch_id IS DISTINCT FROM v_b_main
     OR v_mv.performed_by IS DISTINCT FROM v_user OR v_mv.user_id IS DISTINCT FROM v_user THEN
    PERFORM pg_temp.gate_fail('1.4', format('el movimiento debía estar sellado con cuenta=%s sucursal=%s autor=%s y trae cuenta=%s sucursal=%s autor=%s/%s',
      v_acc, v_b_main, v_user, v_mv.account_id, v_mv.branch_id, v_mv.performed_by, v_mv.user_id));
  END IF;
  IF v_mv.reference_id IS NOT NULL OR v_mv.reference_type IS NOT NULL THEN
    PERFORM pg_temp.gate_fail('1.5', 'el movimiento de apertura no debe referenciar ningún documento (igual que el «Stock inicial» del alta manual)');
  END IF;

  -- La visibilidad por RLS del dueño (un movimiento sin account_id sería invisible).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE product_id = v_p;
  RESET ROLE;
  IF v_n <> 1 THEN
    PERFORM pg_temp.gate_fail('1.6', format('el dueño debía VER el movimiento de apertura bajo RLS y ve %s', v_n));
  END IF;

  -- ═══ (2) el libro reconcilia ═══════════════════════════════════════════════
  SELECT COALESCE(SUM(quantity_delta), 0) INTO v_num FROM public.stock_movements
   WHERE product_id = v_p AND branch_id = v_b_main;
  IF v_num <> pg_temp.bs(v_p, v_b_main) THEN
    PERFORM pg_temp.gate_fail('2', format('el libro no reconcilia: Σ deltas=%s, saldo=%s', v_num, pg_temp.bs(v_p, v_b_main)));
  END IF;

  -- ═══ (3) venta de 5 y reimport con OTRO archivo: el saldo NO se pisa ═══════
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.rpc_create_sale_operation('gate-apertura-sale', NULL, v_today, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 100, 'quantity', 5)));
  RESET ROLE;
  IF pg_temp.bs(v_p, v_b_main) <> 15 THEN
    PERFORM pg_temp.gate_fail('3.0', format('la venta de 5 debía dejar 15 y deja %s', pg_temp.bs(v_p, v_b_main)));
  END IF;

  v_r := pg_temp.imp(v_user, 'gate-apertura-2',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'GAP-1',
      'price', 120, 'cost', 60, 'stock', 20)), 'gate-hash-2');
  IF (v_r->>'committed')::boolean IS NOT TRUE OR (v_r->>'updated')::int <> 1 OR (v_r->>'inserted')::int <> 0 THEN
    PERFORM pg_temp.gate_fail('3.1', format('el reimport debía ser una ACTUALIZACIÓN (updated=1, inserted=0): %s', v_r::text));
  END IF;
  IF pg_temp.bs(v_p, v_b_main) <> 15 THEN
    PERFORM pg_temp.gate_fail('3.2', format('reimportar stock=20 pisó el saldo vivo: debía quedar 15 (20 - 5 vendidas) y hay %s', pg_temp.bs(v_p, v_b_main)));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE product_id = v_p;
  IF v_n <> 2 THEN
    PERFORM pg_temp.gate_fail('3.3', format('el reimport no debía dejar movimientos (apertura + venta = 2) y hay %s', v_n));
  END IF;
  SELECT price INTO v_num FROM public.products WHERE id = v_p;
  IF v_num <> 120 THEN
    PERFORM pg_temp.gate_fail('3.4', format('el reimport SÍ debía actualizar el precio (120) y es %s', v_num));
  END IF;

  -- triangulación: un stock mayor, y uno de cero, tampoco tocan el saldo.
  v_r := pg_temp.imp(v_user, 'gate-apertura-3',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'gap-1', 'stock', 500)), 'gate-hash-3');
  v_r := pg_temp.imp(v_user, 'gate-apertura-3b',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'GAP-1', 'stock', 0)), 'gate-hash-3b');
  IF pg_temp.bs(v_p, v_b_main) <> 15 OR pg_temp.mv_n(v_p) <> 2 THEN
    PERFORM pg_temp.gate_fail('3.5', format('stock=500 y stock=0 sobre un SKU existente (case-insensitive) no debían tocar nada: saldo=%s movimientos=%s',
      pg_temp.bs(v_p, v_b_main), pg_temp.mv_n(v_p)));
  END IF;

  -- ═══ (4) celdas vacías al ACTUALIZAR conservan ═════════════════════════════
  v_r := pg_temp.imp(v_user, 'gate-apertura-4',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'GAP-1',
      'price', NULL, 'cost', NULL, 'stock', NULL, 'min_stock', NULL)), 'gate-hash-4');
  IF (v_r->>'committed')::boolean IS NOT TRUE THEN
    PERFORM pg_temp.gate_fail('4.0', format('el reimport con celdas vacías no commiteó: %s', v_r::text));
  END IF;
  IF (SELECT price FROM public.products WHERE id = v_p) <> 120 THEN
    PERFORM pg_temp.gate_fail('4.1', 'Precio vacío debía conservar 120 y lo pisó');
  END IF;
  IF (SELECT cost FROM public.products WHERE id = v_p) <> 60 THEN
    PERFORM pg_temp.gate_fail('4.2', 'Costo vacío debía conservar 60 y lo pisó');
  END IF;
  IF (SELECT min_stock FROM public.products WHERE id = v_p) <> 3 THEN
    PERFORM pg_temp.gate_fail('4.3', 'Stock mínimo vacío debía conservar 3 en products y lo pisó');
  END IF;
  SELECT min_stock INTO v_num FROM public.branch_stock WHERE product_id = v_p AND branch_id = v_b_main;
  IF v_num IS DISTINCT FROM 3 THEN
    PERFORM pg_temp.gate_fail('4.4', format('Stock mínimo vacío debía conservar 3 en branch_stock (alertas) y quedó %s', v_num));
  END IF;
  IF pg_temp.bs(v_p, v_b_main) <> 15 OR pg_temp.mv_n(v_p) <> 2 THEN
    PERFORM pg_temp.gate_fail('4.5', 'Stock vacío no debía tocar el saldo ni el libro');
  END IF;

  -- un mínimo informado SÍ se actualiza (products + sucursal principal).
  v_r := pg_temp.imp(v_user, 'gate-apertura-4b',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Apertura 1', 'sku', 'GAP-1', 'min_stock', 7)), 'gate-hash-4b');
  IF (SELECT min_stock FROM public.products WHERE id = v_p) <> 7 THEN
    PERFORM pg_temp.gate_fail('4.6', 'Stock mínimo informado debía actualizar products.min_stock a 7');
  END IF;
  SELECT min_stock INTO v_num FROM public.branch_stock WHERE product_id = v_p AND branch_id = v_b_main;
  IF v_num IS DISTINCT FROM 7 OR pg_temp.bs(v_p, v_b_main) <> 15 THEN
    PERFORM pg_temp.gate_fail('4.7', format('Stock mínimo informado debía quedar 7 en la principal sin tocar el saldo (15): min=%s saldo=%s',
      v_num, pg_temp.bs(v_p, v_b_main)));
  END IF;

  -- ═══ (5) celdas vacías al CREAR ════════════════════════════════════════════
  v_r := pg_temp.imp(v_user, 'gate-apertura-5',
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Vacio Total',    'sku', 'GAP-5A', 'price', NULL, 'stock', NULL, 'min_stock', NULL),
      jsonb_build_object('row_no', 2, 'name', 'Gate Vacio Con Min',  'sku', 'GAP-5B', 'price', NULL, 'stock', NULL, 'min_stock', 4),
      jsonb_build_object('row_no', 3, 'name', 'Gate Stock Cero',     'sku', 'GAP-5C', 'price', 10,   'stock', 0,    'min_stock', NULL)),
    'gate-hash-5');
  IF (v_r->>'committed')::boolean IS NOT TRUE OR (v_r->>'inserted')::int <> 3 THEN
    PERFORM pg_temp.gate_fail('5.0', format('las 3 altas con celdas vacías no commitearon: %s', v_r::text));
  END IF;
  v_p2 := pg_temp.pid(v_acc, 'GAP-5A');
  IF (SELECT price FROM public.products WHERE id = v_p2) <> 0 THEN
    PERFORM pg_temp.gate_fail('5.1', 'Precio vacío en un ALTA debía quedar 0');
  END IF;
  IF pg_temp.mv_n(v_p2) <> 0 OR pg_temp.bs_rows(v_p2) <> 0 THEN
    PERFORM pg_temp.gate_fail('5.2', format('un alta sin stock ni mínimo no debía dejar movimiento ni fila de saldo: movs=%s filas=%s',
      pg_temp.mv_n(v_p2), pg_temp.bs_rows(v_p2)));
  END IF;
  v_p2 := pg_temp.pid(v_acc, 'GAP-5B');
  SELECT quantity, min_stock INTO v_num, v_txt FROM public.branch_stock WHERE product_id = v_p2 AND branch_id = v_b_main;
  IF v_num IS DISTINCT FROM 0 OR v_txt::numeric IS DISTINCT FROM 4 OR pg_temp.mv_n(v_p2) <> 0 THEN
    PERFORM pg_temp.gate_fail('5.3', format('un alta con sólo mínimo debía dejar fila de saldo (0, mínimo 4) sin movimiento: saldo=%s min=%s movs=%s',
      v_num, v_txt, pg_temp.mv_n(v_p2)));
  END IF;
  v_p2 := pg_temp.pid(v_acc, 'GAP-5C');
  IF pg_temp.mv_n(v_p2) <> 0 OR pg_temp.bs(v_p2, v_b_main) <> 0 THEN
    PERFORM pg_temp.gate_fail('5.4', 'un alta con stock 0 explícito no debía dejar movimiento');
  END IF;

  -- ═══ (6) stock negativo: error de fila, lote revertido, sin huérfanos ══════
  v_r := pg_temp.imp(v_user, 'gate-apertura-6',
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Neg Ok',  'sku', 'GAP-6A', 'price', 1, 'stock', 5),
      jsonb_build_object('row_no', 2, 'name', 'Gate Neg Mal', 'sku', 'GAP-6B', 'price', 1, 'stock', -3)),
    'gate-hash-6');
  IF (v_r->>'committed')::boolean IS NOT FALSE OR jsonb_array_length(v_r->'errors') <> 1 THEN
    PERFORM pg_temp.gate_fail('6.0', format('un stock negativo debía ser UN error de fila con el lote sin commitear: %s', v_r::text));
  END IF;
  IF (v_r->'errors'->0->>'row')::int <> 2 THEN
    PERFORM pg_temp.gate_fail('6.1', format('el error debía ser de la fila 2: %s', v_r->'errors'->0));
  END IF;
  IF pg_temp.pid(v_acc, 'GAP-6A') IS NOT NULL OR pg_temp.pid(v_acc, 'GAP-6B') IS NOT NULL THEN
    PERFORM pg_temp.gate_fail('6.2', 'el lote rechazado dejó productos escritos');
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc AND product_name IN ('Gate Neg Ok', 'Gate Neg Mal');
  IF v_n <> 0 THEN
    PERFORM pg_temp.gate_fail('6.3', format('el lote rechazado dejó %s movimientos huérfanos', v_n));
  END IF;

  -- ═══ (7) simulación: cero escrituras ═══════════════════════════════════════
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc;
  v_r := pg_temp.imp(v_user, 'gate-apertura-7',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Dry', 'sku', 'GAP-7', 'price', 1, 'stock', 9)),
    'gate-hash-7', TRUE);
  IF (v_r->>'dry_run')::boolean IS NOT TRUE OR (v_r->>'committed')::boolean IS NOT FALSE OR (v_r->>'inserted')::int <> 1 THEN
    PERFORM pg_temp.gate_fail('7.0', format('la simulación debía informar inserted=1 sin commitear: %s', v_r::text));
  END IF;
  IF pg_temp.pid(v_acc, 'GAP-7') IS NOT NULL
     OR (SELECT count(*) FROM public.stock_movements WHERE account_id = v_acc) <> v_n
     OR EXISTS (SELECT 1 FROM public.branch_stock WHERE account_id = v_acc AND product_id IN (SELECT id FROM public.products WHERE name = 'Gate Dry')) THEN
    PERFORM pg_temp.gate_fail('7.1', 'la simulación dejó escrituras (producto, movimiento o saldo)');
  END IF;

  -- ═══ (8) SKU repetido en el MISMO archivo ══════════════════════════════════
  v_r := pg_temp.imp(v_user, 'gate-apertura-8',
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Dup', 'sku', 'GAP-8', 'price', 1, 'stock', 10),
      jsonb_build_object('row_no', 2, 'name', 'Gate Dup', 'sku', 'gap-8', 'price', 2, 'stock', 99)),
    'gate-hash-8');
  v_p2 := pg_temp.pid(v_acc, 'GAP-8');
  IF (v_r->>'inserted')::int <> 1 OR (v_r->>'updated')::int <> 1 OR pg_temp.bs(v_p2, v_b_main) <> 10 OR pg_temp.mv_n(v_p2) <> 1 THEN
    PERFORM pg_temp.gate_fail('8', format('SKU repetido: la 1ª fila crea con stock 10, la 2ª actualiza sin pisar el stock; inserted=%s updated=%s saldo=%s movs=%s',
      v_r->>'inserted', v_r->>'updated', pg_temp.bs(v_p2, v_b_main), pg_temp.mv_n(v_p2)));
  END IF;
  IF (SELECT price FROM public.products WHERE id = v_p2) <> 2 THEN
    PERFORM pg_temp.gate_fail('8b', 'la 2ª fila debía actualizar el precio a 2 (el resto de los campos sí se actualiza)');
  END IF;

  -- ═══ (9) jerarquía: el padre no deja movimiento, cada variante el suyo ═════
  v_r := pg_temp.imp(v_user, 'gate-apertura-9',
    jsonb_build_array(
      jsonb_build_object('row_no', 1, 'name', 'Gate Padre', 'sku', 'GAP-9P', 'price', NULL, 'stock', NULL,
        'stock_control_type', 'variant_only', 'is_variant', false),
      jsonb_build_object('row_no', 2, 'name', 'Gate Var 1', 'sku', 'GAP-9A', 'price', 5, 'stock', 5,
        'sku_parent', 'GAP-9P', 'is_variant', true),
      jsonb_build_object('row_no', 3, 'name', 'Gate Var 2', 'sku', 'GAP-9B', 'price', 5, 'stock', 8,
        'sku_parent', 'GAP-9P', 'is_variant', true)),
    'gate-hash-9');
  v_par := pg_temp.pid(v_acc, 'GAP-9P'); v_v1 := pg_temp.pid(v_acc, 'GAP-9A'); v_v2 := pg_temp.pid(v_acc, 'GAP-9B');
  IF (v_r->>'committed')::boolean IS NOT TRUE OR v_par IS NULL OR v_v1 IS NULL OR v_v2 IS NULL THEN
    PERFORM pg_temp.gate_fail('9.0', format('el lote padre+2 variantes no commiteó: %s', v_r::text));
  END IF;
  IF pg_temp.mv_n(v_par) <> 0 OR pg_temp.bs_rows(v_par) <> 0 THEN
    PERFORM pg_temp.gate_fail('9.1', 'el padre variant_only no debía tener saldo ni movimiento');
  END IF;
  IF pg_temp.bs(v_v1, v_b_main) <> 5 OR pg_temp.mv_n(v_v1) <> 1 OR pg_temp.bs(v_v2, v_b_main) <> 8 OR pg_temp.mv_n(v_v2) <> 1 THEN
    PERFORM pg_temp.gate_fail('9.2', 'cada variante debía tener su saldo (5 y 8) y UN movimiento de apertura');
  END IF;

  -- ═══ (10) cuenta sin sucursales: la principal nace perezosa ════════════════
  SET LOCAL session_replication_role = replica;
  DELETE FROM public.branches WHERE account_id = v_acc3;
  SET LOCAL session_replication_role = DEFAULT;
  IF EXISTS (SELECT 1 FROM public.branches WHERE account_id = v_acc3) THEN
    PERFORM pg_temp.gate_fail('10.0', 'no se pudo dejar la cuenta C sin sucursales para el fixture');
  END IF;
  v_r := pg_temp.imp(v_user3, 'gate-apertura-10',
    jsonb_build_array(jsonb_build_object('row_no', 1, 'name', 'Gate Sin Sucursal', 'sku', 'GAP-10', 'price', 1, 'stock', 7)),
    'gate-hash-10');
  v_p2 := pg_temp.pid(v_acc3, 'GAP-10');
  IF (v_r->>'committed')::boolean IS NOT TRUE OR v_p2 IS NULL THEN
    PERFORM pg_temp.gate_fail('10.1', format('el alta en una cuenta sin sucursales no commiteó: %s', v_r::text));
  END IF;
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_p2;
  IF v_mv.id IS NULL OR v_mv.branch_id IS NULL OR v_mv.quantity_delta <> 7 OR pg_temp.bs(v_p2, v_mv.branch_id) <> 7 THEN
    PERFORM pg_temp.gate_fail('10.2', 'el stock inicial debía caer en la sucursal creada perezosamente y quedar sellado en el movimiento');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_mv.branch_id AND account_id = v_acc3 AND is_active AND status = 'active') THEN
    PERFORM pg_temp.gate_fail('10.3', 'la sucursal perezosa debía quedar ACTIVA y de la cuenta');
  END IF;

  -- ═══ (11) ACL, firma y COMMENT de rpc_bulk_upsert_products intactos ════════
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpc_bulk_upsert_products';
  IF v_n <> 1 THEN
    PERFORM pg_temp.gate_fail('11.0', format('rpc_bulk_upsert_products debía tener UNA firma y tiene %s (overload)', v_n));
  END IF;
  v_oid := 'public.rpc_bulk_upsert_products(jsonb, uuid)'::regprocedure;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    PERFORM pg_temp.gate_fail('11.1', 'ACL de rpc_bulk_upsert_products: sin EXECUTE para authenticated/anon y con EXECUTE para service_role');
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    PERFORM pg_temp.gate_fail('11.2', 'rpc_bulk_upsert_products debe seguir siendo SECURITY DEFINER');
  END IF;
  IF (SELECT 'search_path=public' = ANY (proconfig) FROM pg_proc WHERE oid = v_oid) IS NOT TRUE THEN
    PERFORM pg_temp.gate_fail('11.3', 'rpc_bulk_upsert_products debe conservar SET search_path = public');
  END IF;
  v_txt := obj_description(v_oid, 'pg_proc');
  IF v_txt IS NULL OR position('apertura' in v_txt) = 0 THEN
    PERFORM pg_temp.gate_fail('11.4', format('el COMMENT de rpc_bulk_upsert_products debe documentar la regla de apertura: %L', v_txt));
  END IF;

  RAISE NOTICE 'PASS importador-stock-apertura: alta -> principal operativa + UN movimiento sellado; reimport no pisa el saldo; celdas vacías conservan; negativos, simulación, SKU repetido, jerarquía, cuenta sin sucursales y ACL verificados.';
END $gate$;

ROLLBACK;
