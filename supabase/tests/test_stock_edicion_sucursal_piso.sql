-- =============================================================================
-- GATE: test_stock_edicion_sucursal_piso.sql
-- FIX AD-HOC: stock-edicion-sucursal-piso (2026-10-14)
--
-- Tres defectos de la edición y del borrado de operaciones, hallados por la auditoría
-- del movimiento de stock del 2026-10-13 y reproducidos en el stack local:
--
--   R2  rpc_atomic_update_sale_operation validaba el stock con Σ branch_stock de TODAS las
--       sucursales y descontaba de UNA: con el total alcanzando y la sucursal no, pasaba el
--       gate y explotaba con 23514 (branch_stock_quantity_non_negative → un 422 genérico).
--       Ahora rechaza con el P0409 de stock insuficiente del alta (por sucursal).
--       rpc_atomic_update_purchase_operation: editar una compra cuya mercadería ya se vendió
--       también terminaba en 23514; ahora es un P0409 legible (purchase_edit_stock_consumed).
--   R4  Borrar una compra ya vendida aplica el piso en cero, pero lo registraba DOS veces
--       (un ajuste floor_on_purchase_delete Y el contramovimiento purchase_return, los dos
--       con el mismo delta) para un único cambio de saldo: el libro dejaba de reconciliar con
--       branch_stock. Ahora es UN movimiento, con la traza del piso en su metadata y su nota.
--   R5  Editar una venta cuya sucursal fue DESACTIVADA devolvía el stock a esa sucursal
--       desactivada (invisible, no se vende) y volvía a descontar de ella; el borrado ya caía a
--       la principal operativa, la edición no. Ahora aplica el mismo respaldo.
--
-- EJECUTA como `authenticated` (claims reales): rpc_create_sale_operation,
-- rpc_atomic_update_sale_operation, rpc_create_purchase_operation,
-- rpc_atomic_update_purchase_operation y rpc_delete_purchase_operation / _sale_operation.
-- Se asserta el EFECTO (SQLSTATE, saldo por sucursal, filas del libro, metadata), nunca «no
-- hubo error». Corre dentro de BEGIN..ROLLBACK: residuo cero por construcción.
-- =============================================================================
BEGIN;

CREATE FUNCTION pg_temp.gate_fail(p_step text, p_detail text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'GATE STOCK-EDICION-PISO FAILED (%): %', p_step, p_detail;
END $f$;

-- Llama a una expresión RPC como `authenticated`. NUNCA lanza: devuelve estado/mensaje/resultado.
CREATE FUNCTION pg_temp.try_rpc(p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT to_jsonb(%s)', p_expr) INTO o_res;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
END $f$;

CREATE FUNCTION pg_temp.bs(p uuid, b uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p AND branch_id = b), 0) $f$;
CREATE FUNCTION pg_temp.items1(p_prod uuid, p_amount numeric, p_qty numeric) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_array(jsonb_build_object('product_id', p_prod, 'amount', p_amount, 'quantity', p_qty)) $f$;
CREATE FUNCTION pg_temp.ids_of(p_res jsonb) RETURNS uuid[] LANGUAGE sql AS $f$
  SELECT COALESCE(array_agg((e->>'id')::uuid), ARRAY[]::uuid[]) FROM jsonb_array_elements(p_res->'items') e $f$;
CREATE FUNCTION pg_temp.mkprod(p_user uuid, p_acc uuid, p_name text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (p_user, p_acc, p_name, 'GSEP-' || substr(gen_random_uuid()::text, 1, 8), 60, 100)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;
-- Σ de los deltas del producto en una sucursal + el saldo sembrado = saldo vivo (libro que reconcilia).
CREATE FUNCTION pg_temp.ledger_ok(p uuid, b uuid, p_initial numeric) RETURNS boolean LANGUAGE sql AS $f$
  SELECT p_initial + COALESCE((SELECT SUM(quantity_delta) FROM public.stock_movements
                                WHERE product_id = p AND branch_id = b), 0) = pg_temp.bs(p, b) $f$;
CREATE FUNCTION pg_temp.mv_n(p uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::int FROM public.stock_movements WHERE product_id = p $f$;

DO $gate$
DECLARE
  v_today  date := public.reporting_local_today();
  v_user   uuid := gen_random_uuid();
  v_acc    uuid;
  v_bp     uuid;   -- sucursal principal operativa (la más antigua activa)
  v_bb     uuid;   -- segunda sucursal activa
  v_bc     uuid;   -- sucursal que se vacía y se desactiva (R5)
  v_ps     uuid; v_pq uuid; v_pp uuid; v_pf uuid; v_pg uuid; v_ph uuid; v_p5 uuid;
  v_r      record;
  v_sale   uuid[]; v_pur uuid[]; v_pop uuid; v_op uuid;
  v_n      integer;
  v_num    numeric;
  v_txt    text;
  v_mv     public.stock_movements%ROWTYPE;
  v_oid    oid;
BEGIN
  -- ── setup ──────────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'gate-edicion-piso@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Edicion Piso', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL THEN PERFORM pg_temp.gate_fail('setup', 'handle_new_user no provisionó la cuenta'); END IF;
  SELECT id INTO v_bp FROM public.branches WHERE account_id = v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc, 'Gate Piso B', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_bb;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc, 'Gate Piso C', TRUE, 'active', now(), now() + interval '2 minutes') RETURNING id INTO v_bc;
  IF public.c26_default_branch(v_acc) IS DISTINCT FROM v_bp THEN
    PERFORM pg_temp.gate_fail('setup', 'la principal operativa debía ser la sucursal más antigua');
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN PERFORM pg_temp.gate_fail('setup', 'auth.uid() no resuelve'); END IF;

  v_ps := pg_temp.mkprod(v_user, v_acc, 'GSEP S venta'); v_pq := pg_temp.mkprod(v_user, v_acc, 'GSEP Q compra');
  v_pp := pg_temp.mkprod(v_user, v_acc, 'GSEP P compra vendida');
  v_pf := pg_temp.mkprod(v_user, v_acc, 'GSEP F piso'); v_pg := pg_temp.mkprod(v_user, v_acc, 'GSEP G sin piso');
  v_ph := pg_temp.mkprod(v_user, v_acc, 'GSEP H todo vendido'); v_p5 := pg_temp.mkprod(v_user, v_acc, 'GSEP 5 inactiva');

  -- ═══ R2 venta: el gate de la edición es por SUCURSAL ═══════════════════════
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_ps, v_bp, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_ps, v_bb, 2);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb, %L::uuid)', 'gsep-s1', v_today, pg_temp.items1(v_ps, 100, 2), v_bb));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_ps, v_bb) <> 0 THEN
    PERFORM pg_temp.gate_fail('R2s.0', format('la venta de 2 en la sucursal B debía pasar y dejar B en 0: estado=%s msg=%s B=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_ps, v_bb)));
  END IF;
  v_sale := pg_temp.ids_of(v_r.o_res);

  -- 5 en B con B=2 (+2 de la reversa) y P=10 (Σ = 12 alcanza, la sucursal no): P0409, nada cambia.
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale::text, v_today, pg_temp.items1(v_ps, 100, 5)));
  IF v_r.o_state IS DISTINCT FROM 'P0409' OR v_r.o_msg NOT LIKE 'Insufficient stock for product %' THEN
    PERFORM pg_temp.gate_fail('R2s.1', format('editar la venta de B a 5 con B insuficiente (y el total alcanzando) debía ser P0409 «Insufficient stock for product»: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;
  IF pg_temp.bs(v_ps, v_bb) <> 0 OR pg_temp.bs(v_ps, v_bp) <> 10 THEN
    PERFORM pg_temp.gate_fail('R2s.2', format('el rechazo debía dejar el saldo intacto (B=0, P=10): B=%s P=%s', pg_temp.bs(v_ps, v_bb), pg_temp.bs(v_ps, v_bp)));
  END IF;
  SELECT count(*) INTO v_n FROM public.sales WHERE id = ANY (v_sale) AND quantity = 2 AND branch_id = v_bb;
  IF v_n <> 1 OR pg_temp.mv_n(v_ps) <> 1 THEN
    PERFORM pg_temp.gate_fail('R2s.3', format('el rechazo debía dejar la venta original y su único movimiento (filas=%s movimientos=%s)', v_n, pg_temp.mv_n(v_ps)));
  END IF;

  -- con sucursal explícita el literal es insufficient_branch_stock (el del alta).
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb, p_branch_id => %L::uuid, p_branch_provided => true)',
    v_sale::text, v_today, pg_temp.items1(v_ps, 100, 5), v_bb));
  IF v_r.o_state IS DISTINCT FROM 'P0409' OR v_r.o_msg NOT LIKE 'insufficient_branch_stock for product %' THEN
    PERFORM pg_temp.gate_fail('R2s.4', format('con la sucursal B explícita el rechazo debía ser P0409 «insufficient_branch_stock for product»: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;

  -- triangulación: bajar la cantidad prospera (B: +2 de la reversa, -1 → 1) …
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale::text, v_today, pg_temp.items1(v_ps, 100, 1)));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_ps, v_bb) <> 1 OR pg_temp.bs(v_ps, v_bp) <> 10 THEN
    PERFORM pg_temp.gate_fail('R2s.5', format('editar 2 → 1 en B debía pasar y dejar B=1, P=10: estado=%s msg=%s B=%s P=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_ps, v_bb), pg_temp.bs(v_ps, v_bp)));
  END IF;
  v_sale := pg_temp.ids_of(v_r.o_res);
  -- … subir a 3 con B=1(+1 de la reversa=2) es insuficiente por sucursal …
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale::text, v_today, pg_temp.items1(v_ps, 100, 3)));
  IF v_r.o_state IS DISTINCT FROM 'P0409' THEN
    PERFORM pg_temp.gate_fail('R2s.6', format('editar 1 → 3 en B (B tiene 1+1) debía ser P0409: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;
  -- … y reimputar a la principal (P=10) prospera: B recupera la unidad, P descuenta 4.
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb, p_branch_id => %L::uuid, p_branch_provided => true)',
    v_sale::text, v_today, pg_temp.items1(v_ps, 100, 4), v_bp));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_ps, v_bb) <> 2 OR pg_temp.bs(v_ps, v_bp) <> 6 THEN
    PERFORM pg_temp.gate_fail('R2s.7', format('reimputar la venta a la principal con 4 debía pasar y dejar B=2, P=6: estado=%s msg=%s B=%s P=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_ps, v_bb), pg_temp.bs(v_ps, v_bp)));
  END IF;

  -- ═══ R2 compra: editar una compra ya vendida es un P0409 legible ═══════════
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_pp, v_bp, 10);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra gate'', %L::jsonb)', 'gsep-p1', v_today, pg_temp.items1(v_pp, 50, 4)));
  v_pur := pg_temp.ids_of(v_r.o_res); v_pop := (v_r.o_res->>'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gsep-p1-sale', v_today, pg_temp.items1(v_pp, 100, 12)));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pp, v_bp) <> 2 THEN
    PERFORM pg_temp.gate_fail('R2p.0', format('compra 4 + venta 12 debía dejar P=2: estado=%s msg=%s saldo=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pp, v_bp)));
  END IF;
  v_op := (v_r.o_res->>'operation_id')::uuid;
  v_n := pg_temp.mv_n(v_pp);

  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)', v_pur::text, v_today, pg_temp.items1(v_pp, 50, 1)));
  IF v_r.o_state IS DISTINCT FROM 'P0409' OR v_r.o_msg NOT LIKE 'purchase_edit_stock_consumed: de GSEP P compra vendida en la sucursal quedan 2%' THEN
    PERFORM pg_temp.gate_fail('R2p.1', format('editar una compra ya vendida debía ser P0409 «purchase_edit_stock_consumed: de <producto> en la sucursal quedan 2 …»: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;
  IF v_r.o_msg NOT LIKE '%la edición necesita restar 4%' THEN
    PERFORM pg_temp.gate_fail('R2p.2', format('el mensaje debía decir cuánto restaría la edición (4): %s', v_r.o_msg));
  END IF;
  IF pg_temp.bs(v_pp, v_bp) <> 2 OR pg_temp.mv_n(v_pp) <> v_n THEN
    PERFORM pg_temp.gate_fail('R2p.3', format('el rechazo debía dejar el saldo (2) y el libro (%s) intactos: saldo=%s movimientos=%s', v_n, pg_temp.bs(v_pp, v_bp), pg_temp.mv_n(v_pp)));
  END IF;
  SELECT count(*) INTO v_n FROM public.purchases WHERE id = ANY (v_pur) AND quantity = 4;
  IF v_n <> 1 THEN PERFORM pg_temp.gate_fail('R2p.4', 'el rechazo debía dejar la compra original (cantidad 4)'); END IF;
  -- una edición que sólo cambia el precio también pide restar lo comprado: mismo rechazo legible, no 23514.
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)', v_pur::text, v_today, pg_temp.items1(v_pp, 70, 4)));
  IF v_r.o_state IS DISTINCT FROM 'P0409' THEN
    PERFORM pg_temp.gate_fail('R2p.5', format('editar el precio de una compra ya vendida debía ser P0409 (la reversa no cabe): estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;

  -- triangulación: una compra con la mercadería TODAVÍA en stock se edita normalmente.
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_pq, v_bp, 10);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra gate q'', %L::jsonb)', 'gsep-q1', v_today, pg_temp.items1(v_pq, 50, 4)));
  v_pur := pg_temp.ids_of(v_r.o_res);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gsep-q1-sale', v_today, pg_temp.items1(v_pq, 100, 1)));
  IF pg_temp.bs(v_pq, v_bp) <> 13 THEN PERFORM pg_temp.gate_fail('R2p.6', 'compra 4 + venta 1 debía dejar P=13'); END IF;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)', v_pur::text, v_today, pg_temp.items1(v_pq, 50, 6)));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pq, v_bp) <> 15 THEN
    PERFORM pg_temp.gate_fail('R2p.7', format('editar la compra de 4 a 6 con la mercadería en stock debía pasar y dejar P=15: estado=%s msg=%s saldo=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pq, v_bp)));
  END IF;
  v_pur := pg_temp.ids_of(v_r.o_res);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)', v_pur::text, v_today, pg_temp.items1(v_pq, 50, 3)));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pq, v_bp) <> 12 THEN
    PERFORM pg_temp.gate_fail('R2p.8', format('editar la compra de 6 a 3 debía pasar y dejar P=12: estado=%s msg=%s saldo=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pq, v_bp)));
  END IF;

  -- ═══ R4: el piso en cero deja UN movimiento y el libro reconcilia ═════════
  -- v_pp ya tiene compra 4 (v_pop) + venta 12 (v_op) y saldo 2: se borra la compra.
  v_n := pg_temp.mv_n(v_pp);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_purchase_operation(NULL, %L::uuid, ''gate piso'')', v_pop));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pp, v_bp) <> 0 THEN
    PERFORM pg_temp.gate_fail('R4.0', format('borrar la compra ya vendida debía pasar y dejar el piso en 0: estado=%s msg=%s saldo=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pp, v_bp)));
  END IF;
  IF pg_temp.mv_n(v_pp) <> v_n + 1 THEN
    PERFORM pg_temp.gate_fail('R4.1', format('el borrado con piso debía dejar UN movimiento nuevo (el libro tenía %s) y dejó %s', v_n, pg_temp.mv_n(v_pp) - v_n));
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE product_id = v_pp AND reason = 'floor_on_purchase_delete') THEN
    PERFORM pg_temp.gate_fail('R4.2', 'no debía quedar el ajuste floor_on_purchase_delete: duplicaba el cambio de saldo del contramovimiento');
  END IF;
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_pp AND reference_type = 'purchase_reversal';
  IF v_mv.id IS NULL OR v_mv.type IS DISTINCT FROM 'purchase_return' OR v_mv.quantity_delta <> -2
     OR v_mv.quantity_before <> 2 OR v_mv.quantity_after <> 0 OR v_mv.branch_id IS DISTINCT FROM v_bp THEN
    PERFORM pg_temp.gate_fail('R4.3', format('el contramovimiento debía ser purchase_return de -2 (2 → 0) en la principal: delta=%s antes=%s después=%s', v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after));
  END IF;
  IF (v_mv.metadata->>'floored')::boolean IS NOT TRUE OR (v_mv.metadata->>'requested_quantity_delta')::numeric IS DISTINCT FROM -4
     OR (v_mv.metadata->>'reverses_movement_id') IS NULL THEN
    PERFORM pg_temp.gate_fail('R4.4', format('el contramovimiento debía llevar floored=true y requested_quantity_delta=-4 (y reverses_movement_id) en la metadata: %s', v_mv.metadata));
  END IF;
  IF v_mv.notes NOT LIKE '%Reversa solicitada: -4%aplicada: -2.0000%' THEN
    PERFORM pg_temp.gate_fail('R4.5', format('la nota debía decir lo solicitado y lo aplicado: %s', v_mv.notes));
  END IF;
  -- el libro reconcilia: saldo sembrado (10) + Σ deltas = saldo vivo, tras el piso …
  IF NOT pg_temp.ledger_ok(v_pp, v_bp, 10) THEN
    PERFORM pg_temp.gate_fail('R4.6', format('el libro no reconcilia tras el piso: sembrado 10 + Σ deltas ≠ saldo %s', pg_temp.bs(v_pp, v_bp)));
  END IF;
  -- … y tras borrar también la venta (el stock que el piso no pudo restar se recupera: 12).
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''gate piso'')', v_op));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pp, v_bp) <> 12 OR NOT pg_temp.ledger_ok(v_pp, v_bp, 10) THEN
    PERFORM pg_temp.gate_fail('R4.7', format('borrar la venta debía dejar 12 con el libro reconciliado: estado=%s msg=%s saldo=%s libro_ok=%s',
      v_r.o_state, v_r.o_msg, pg_temp.bs(v_pp, v_bp), pg_temp.ledger_ok(v_pp, v_bp, 10)));
  END IF;

  -- control: una compra NO vendida se borra sin piso — un movimiento, sin marca ni nota de piso.
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_pg, v_bp, 10);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra gate g'', %L::jsonb)', 'gsep-g1', v_today, pg_temp.items1(v_pg, 50, 5)));
  v_pop := (v_r.o_res->>'operation_id')::uuid;
  v_n := pg_temp.mv_n(v_pg);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_purchase_operation(NULL, %L::uuid, ''gate sin piso'')', v_pop));
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_pg AND reference_type = 'purchase_reversal';
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_pg, v_bp) <> 10 OR pg_temp.mv_n(v_pg) <> v_n + 1 OR v_mv.quantity_delta <> -5
     OR v_mv.metadata ? 'floored' OR v_mv.notes LIKE '%Reversa solicitada%' OR NOT pg_temp.ledger_ok(v_pg, v_bp, 10) THEN
    PERFORM pg_temp.gate_fail('R4.8', format('borrar una compra no vendida debía dejar 10, UN movimiento de -5 sin marca de piso y el libro reconciliado: estado=%s saldo=%s delta=%s metadata=%s notas=%s',
      v_r.o_state, pg_temp.bs(v_pg, v_bp), v_mv.quantity_delta, v_mv.metadata, v_mv.notes));
  END IF;

  -- borde: todo lo comprado se vendió (saldo 0) — el piso aplica 0, deja UN movimiento de delta 0.
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra gate h'', %L::jsonb)', 'gsep-h1', v_today, pg_temp.items1(v_ph, 50, 3)));
  v_pop := (v_r.o_res->>'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gsep-h1-sale', v_today, pg_temp.items1(v_ph, 100, 3)));
  IF pg_temp.bs(v_ph, v_bp) <> 0 THEN PERFORM pg_temp.gate_fail('R4.9', 'compra 3 + venta 3 debía dejar 0'); END IF;
  v_n := pg_temp.mv_n(v_ph);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_purchase_operation(NULL, %L::uuid, ''gate h'')', v_pop));
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_ph AND reference_type = 'purchase_reversal';
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_ph, v_bp) <> 0 OR pg_temp.mv_n(v_ph) <> v_n + 1 OR v_mv.quantity_delta <> 0
     OR (v_mv.metadata->>'floored')::boolean IS NOT TRUE OR NOT pg_temp.ledger_ok(v_ph, v_bp, 0) THEN
    PERFORM pg_temp.gate_fail('R4.10', format('con todo vendido el piso debía dejar UN movimiento de delta 0 marcado floored y el libro reconciliado: estado=%s saldo=%s delta=%s metadata=%s',
      v_r.o_state, pg_temp.bs(v_ph, v_bp), v_mv.quantity_delta, v_mv.metadata));
  END IF;

  -- ═══ R5: editar una venta de una sucursal DESACTIVADA cae en la principal ══
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p5, v_bp, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p5, v_bc, 5);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb, %L::uuid)', 'gsep-r5', v_today, pg_temp.items1(v_p5, 100, 2), v_bc));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_p5, v_bc) <> 3 THEN
    PERFORM pg_temp.gate_fail('R5.0', format('la venta de 2 en C debía dejar C=3: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;
  v_sale := pg_temp.ids_of(v_r.o_res);
  -- C se vacía (su stock pasa a la principal) y se desactiva.
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p5, v_bc, -3);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p5, v_bp, 3);
  UPDATE public.branches SET is_active = FALSE WHERE id = v_bc;
  IF pg_temp.bs(v_p5, v_bc) <> 0 OR pg_temp.bs(v_p5, v_bp) <> 8 THEN
    PERFORM pg_temp.gate_fail('R5.0b', 'fixture: tras vaciar y desactivar C debía quedar C=0, P=8');
  END IF;

  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale::text, v_today, pg_temp.items1(v_p5, 100, 1)));
  IF v_r.o_state <> '00000' THEN
    PERFORM pg_temp.gate_fail('R5.1', format('editar 2 → 1 una venta de la sucursal desactivada debía pasar: estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  END IF;
  IF pg_temp.bs(v_p5, v_bc) <> 0 THEN
    PERFORM pg_temp.gate_fail('R5.2', format('la sucursal DESACTIVADA no debía recibir stock: C=%s (antes quedaba con la unidad devuelta)', pg_temp.bs(v_p5, v_bc)));
  END IF;
  IF pg_temp.bs(v_p5, v_bp) <> 9 THEN
    PERFORM pg_temp.gate_fail('R5.3', format('la principal debía recuperar 2 y descontar 1 (8 → 9): P=%s', pg_temp.bs(v_p5, v_bp)));
  END IF;
  v_sale := pg_temp.ids_of(v_r.o_res);
  SELECT count(*) INTO v_n FROM public.sales WHERE id = ANY (v_sale) AND branch_id = v_bp AND quantity = 1;
  IF v_n <> 1 THEN
    PERFORM pg_temp.gate_fail('R5.4', 'la venta editada debía quedar en la principal operativa (la desactivada no se preserva)');
  END IF;
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_p5 AND type = 'sale_return' AND reference_type = 'sale_update';
  IF v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_bp OR v_mv.quantity_delta <> 2
     OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM v_bc
     OR (v_mv.metadata->>'fallback_reason') IS DISTINCT FROM 'branch_inactive' THEN
    PERFORM pg_temp.gate_fail('R5.5', format('el movimiento de reversa debía caer en la principal con la sucursal original y el motivo en la metadata: branch=%s delta=%s metadata=%s',
      v_mv.branch_id, v_mv.quantity_delta, v_mv.metadata));
  END IF;
  SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_p5 AND type = 'sale' AND reference_type = 'sale' AND reference_id = ANY (v_sale);
  IF v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_bp OR v_mv.quantity_delta <> -1 THEN
    PERFORM pg_temp.gate_fail('R5.6', format('el descuento de la venta editada debía salir de la principal (-1): branch=%s delta=%s', v_mv.branch_id, v_mv.quantity_delta));
  END IF;
  -- con una sucursal ACTIVA explícita mientras la vieja está desactivada: la reversa cae en la principal y el descuento sale de la elegida.
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb, p_branch_id => %L::uuid, p_branch_provided => true)',
    v_sale::text, v_today, pg_temp.items1(v_p5, 100, 1), v_bp));
  IF v_r.o_state <> '00000' OR pg_temp.bs(v_p5, v_bc) <> 0 THEN
    PERFORM pg_temp.gate_fail('R5.7', format('reeditar con la principal explícita debía pasar sin tocar C: estado=%s msg=%s C=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p5, v_bc)));
  END IF;

  -- control negativo: la edición de una venta de una sucursal ACTIVA conserva su sucursal y NO marca respaldo.
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_ps, v_bb, 6);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb, %L::uuid)', 'gsep-r5c', v_today, pg_temp.items1(v_ps, 100, 2), v_bb));
  v_sale := pg_temp.ids_of(v_r.o_res);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale::text, v_today, pg_temp.items1(v_ps, 100, 1)));
  v_sale := pg_temp.ids_of(v_r.o_res);
  SELECT count(*) INTO v_n FROM public.sales WHERE id = ANY (v_sale) AND branch_id = v_bb;
  SELECT count(*) INTO v_num FROM public.stock_movements
   WHERE product_id = v_ps AND type = 'sale_return' AND reference_type = 'sale_update' AND branch_id = v_bb AND NOT (metadata ? 'fallback_reason');
  IF v_r.o_state <> '00000' OR v_n <> 1 OR v_num < 1 THEN
    PERFORM pg_temp.gate_fail('R5.8', format('una venta de una sucursal ACTIVA debía conservar su sucursal y revertir sin marca de respaldo: estado=%s msg=%s filas_en_B=%s reversas_sin_marca=%s', v_r.o_state, v_r.o_msg, v_n, v_num));
  END IF;

  -- ═══ introspección: una firma por función, ACL, flavor y COMMENT ══════════
  FOR v_txt IN SELECT unnest(ARRAY['_stock_apply_delta', 'rpc_reverse_stock_movement', 'rpc_atomic_update_sale_operation', 'rpc_atomic_update_purchase_operation']) LOOP
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = v_txt;
    IF v_n <> 1 THEN PERFORM pg_temp.gate_fail('I.1', format('%s debía tener UNA firma y tiene %s (overload)', v_txt, v_n)); END IF;
  END LOOP;
  v_oid := 'public._stock_apply_delta(uuid, uuid, numeric, uuid, boolean)'::regprocedure;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE') OR (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    PERFORM pg_temp.gate_fail('I.2', '_stock_apply_delta debe seguir interna (sin EXECUTE para authenticated/anon) y SECURITY INVOKER');
  END IF;
  v_oid := 'public.rpc_reverse_stock_movement(uuid, text, text)'::regprocedure;
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
    PERFORM pg_temp.gate_fail('I.3', 'rpc_reverse_stock_movement debe seguir interna (sin EXECUTE para authenticated/anon) y SECURITY DEFINER');
  END IF;
  FOREACH v_oid IN ARRAY ARRAY[
    'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure::oid,
    'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure::oid] LOOP
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      PERFORM pg_temp.gate_fail('I.4', format('%s: authenticated con EXECUTE, anon sin EXECUTE y SECURITY DEFINER', v_oid::regprocedure));
    END IF;
    IF position('stock-edicion-sucursal-piso' in COALESCE(obj_description(v_oid, 'pg_proc'), '')) = 0 THEN
      PERFORM pg_temp.gate_fail('I.5', format('el COMMENT de %s debe declarar stock-edicion-sucursal-piso', v_oid::regprocedure));
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS stock-edicion-sucursal-piso: R2 (edición de venta por sucursal y de compra legible), R4 (piso = un movimiento, libro reconciliado), R5 (sucursal desactivada cae en la principal) e introspección verificados.';
END $gate$;

ROLLBACK;
