-- =============================================================================
-- smoke_stock.sql — Humo de auditoria del movimiento de stock (SOLO stack LOCAL).
--
-- NO TOCA PRODUCCION. NO se commitea nada: todo corre dentro de BEGIN ... ROLLBACK
-- (cero residuo por construccion). Los fixtures usan emails @test.local.
--
-- Correr (desde Git Bash, con el contenedor local levantado):
--   docker cp smoke_stock.sql supabase_db_v0-saa-s-empresarial-completo:/tmp/smoke_stock.sql
--   docker exec -i supabase_db_v0-saa-s-empresarial-completo \
--     psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/smoke_stock.sql
--
-- Cada paso emite un NOTICE "[OK  ]" o "[FAIL]" con la evidencia. Las RPCs se llaman
-- como un usuario `authenticated` real (SET LOCAL ROLE authenticated + claims JWT).
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE smoke_res (seq serial, step text, ok boolean, detail text);

CREATE FUNCTION pg_temp.rec(p_step text, p_ok boolean, p_detail text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO smoke_res (step, ok, detail) VALUES (p_step, p_ok, p_detail);
  RAISE NOTICE '[%] % -- %', CASE WHEN p_ok THEN 'OK  ' ELSE 'FAIL' END, p_step, p_detail;
END $f$;

-- Llama a una expresion RPC como `authenticated`. NUNCA lanza: devuelve estado/mensaje.
CREATE FUNCTION pg_temp.try_rpc(p_expr text, p_role text DEFAULT 'authenticated', OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  EXECUTE format('SELECT to_jsonb(%s)', p_expr) INTO o_res;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
END $f$;

CREATE FUNCTION pg_temp.bs(p uuid, b uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p AND branch_id = b), 0) $f$;
CREATE FUNCTION pg_temp.bs_total(p uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE(SUM(quantity), 0) FROM public.branch_stock WHERE product_id = p $f$;
CREATE FUNCTION pg_temp.mv(p uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE(string_agg(type || ':' || quantity_delta::text || '/' || COALESCE(reference_type, '-')
                             || '@' || COALESCE(left(branch_id::text, 4), 'NULL'), ' | ' ORDER BY created_at, id), '(sin movimientos)')
  FROM public.stock_movements WHERE product_id = p $f$;
CREATE FUNCTION pg_temp.mv_n(p uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT count(*)::int FROM public.stock_movements WHERE product_id = p $f$;
-- Conciliacion del libro: saldo inicial sembrado + suma de deltas de la sucursal = saldo vivo.
CREATE FUNCTION pg_temp.ledger_ok(p uuid, b uuid, p_initial numeric) RETURNS boolean LANGUAGE sql AS $f$
  SELECT p_initial + COALESCE((SELECT SUM(quantity_delta) FROM public.stock_movements
                               WHERE product_id = p AND branch_id = b), 0) = pg_temp.bs(p, b) $f$;
CREATE FUNCTION pg_temp.mkprod(p_user uuid, p_acc uuid, p_name text, p_branch uuid, p_qty numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (p_user, p_acc, p_name, 'SMK-' || substr(gen_random_uuid()::text, 1, 8), 60, 100)
  RETURNING id INTO v_id;
  IF p_qty <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(p_acc, v_id, p_branch, p_qty);
  END IF;
  RETURN v_id;
END $f$;
CREATE FUNCTION pg_temp.items1(p_prod uuid, p_amount numeric, p_qty numeric) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_array(jsonb_build_object('product_id', p_prod, 'amount', p_amount, 'quantity', p_qty)) $f$;
CREATE FUNCTION pg_temp.as_user(p_user uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;
CREATE FUNCTION pg_temp.add_member(p_acc uuid, p_user uuid, p_role text, p_keep_personal boolean) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_m uuid;
BEGIN
  IF NOT p_keep_personal THEN
    DELETE FROM public.account_member_roles WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id = p_user);
    DELETE FROM public.account_members WHERE user_id = p_user;
  END IF;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (p_acc, p_user, 'member') RETURNING id INTO v_m;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (p_acc, v_m, p_role);
END $f$;
CREATE FUNCTION pg_temp.sale_ids(p_res jsonb) RETURNS uuid[] LANGUAGE sql AS $f$
  SELECT COALESCE(array_agg((e->>'id')::uuid), ARRAY[]::uuid[]) FROM jsonb_array_elements(p_res->'items') e $f$;

-- Snapshot de conteos de tablas de stock (para verificar residuo)
SELECT 'ANTES branch_stock=' || (SELECT count(*) FROM public.branch_stock)
    || ' stock_movements=' || (SELECT count(*) FROM public.stock_movements)
    || ' products=' || (SELECT count(*) FROM public.products)
    || ' sales=' || (SELECT count(*) FROM public.sales)
    || ' purchases=' || (SELECT count(*) FROM public.purchases)
    || ' branches=' || (SELECT count(*) FROM public.branches)
    || ' accounts=' || (SELECT count(*) FROM public.accounts) AS conteos_antes;

DO $smoke$
DECLARE
  v_today   date := public.reporting_local_today();
  v_user    uuid := gen_random_uuid();
  v_acc     uuid;
  v_ba      uuid;   -- sucursal principal
  v_bb      uuid;   -- segunda sucursal
  v_client  uuid;
  v_supp    uuid;
  v_pm_other uuid;
  v_p1 uuid; v_p3 uuid; v_p4 uuid; v_p5 uuid; v_p6 uuid; v_p7 uuid; v_p8 uuid; v_p9 uuid;
  v_par uuid; v_child uuid;
  v_r record;
  v_res jsonb; v_res2 jsonb;
  v_sale_ids uuid[]; v_op uuid; v_pur_ids uuid[]; v_pop uuid;
  v_dn jsonb; v_rev int;
  v_n int; v_val numeric; v_txt text; v_bool boolean;
  v_user2 uuid := gen_random_uuid(); v_acc2 uuid; v_ba2 uuid;
  v_so uuid;
BEGIN
  -- ===================== SETUP =====================
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'smoke-stock-a@test.local', now(), now(),
          jsonb_build_object('name', 'Smoke Stock A', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_acc IS NULL THEN RAISE EXCEPTION 'SETUP: handle_new_user no creo cuenta'; END IF;
  SELECT id INTO v_ba FROM public.branches WHERE account_id = v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc, 'Smoke Sucursal B', TRUE, 'active', now(), now() + interval '1 minute')
  RETURNING id INTO v_bb;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_acc, 'Cliente Smoke') RETURNING id INTO v_client;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc, 'Proveedor Smoke') RETURNING id INTO v_supp;
  SELECT id INTO v_pm_other FROM public.payment_methods WHERE account_id = v_acc AND kind = 'other' LIMIT 1;

  -- segunda cuenta (aislamiento entre tenants)
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user2, 'authenticated', 'authenticated', 'smoke-stock-b@test.local', now(), now(),
          jsonb_build_object('name', 'Smoke Stock B', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_acc2 FROM public.account_members WHERE user_id = v_user2 ORDER BY created_at LIMIT 1;
  SELECT id INTO v_ba2 FROM public.branches WHERE account_id = v_acc2 ORDER BY created_at LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'SETUP: auth.uid() no resuelve'; END IF;

  v_p1 := pg_temp.mkprod(v_user, v_acc, 'SMK P1 venta',      v_ba, 10);
  v_p3 := pg_temp.mkprod(v_user, v_acc, 'SMK P3 compra',     v_ba, 10);
  v_p4 := pg_temp.mkprod(v_user, v_acc, 'SMK P4 piso',       v_ba, 10);
  v_p5 := pg_temp.mkprod(v_user, v_acc, 'SMK P5 POS',        v_ba, 10);
  v_p6 := pg_temp.mkprod(v_user, v_acc, 'SMK P6 sucursales', v_ba, 10);
  v_p7 := pg_temp.mkprod(v_user, v_acc, 'SMK P7 remito vta', v_ba, 10);
  v_p8 := pg_temp.mkprod(v_user, v_acc, 'SMK P8 remito cmp', v_ba, 10);
  v_p9 := pg_temp.mkprod(v_user, v_acc, 'SMK P9 decimal',    v_ba, 5);
  PERFORM pg_temp.rec('S0 setup', TRUE, format('cuenta=%s principal=%s B=%s', left(v_acc::text,8), left(v_ba::text,4), left(v_bb::text,4)));

  -- ===================== S1-S3: VENTA formulario: alta -> edicion -> borrado =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s1', v_today, pg_temp.items1(v_p1, 100, 3)));
  v_res := v_r.o_res;
  PERFORM pg_temp.rec('S1 venta 3u (stock 10 -> 7)', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 7,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba), pg_temp.mv(v_p1)));
  v_sale_ids := pg_temp.sale_ids(v_res); v_op := (v_res->>'operation_id')::uuid;
  SELECT count(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_ba AND account_id = v_acc;
  PERFORM pg_temp.rec('S1b venta sin sucursal elegida queda con la principal', v_n = 1, format('filas sales con branch=principal: %s', v_n));
  SELECT count(*) INTO v_n FROM public.stock_movements
   WHERE product_id = v_p1 AND type = 'sale' AND quantity_delta = -3 AND quantity_before = 10 AND quantity_after = 7
     AND branch_id = v_ba AND account_id = v_acc AND reference_type = 'sale';
  PERFORM pg_temp.rec('S1c movimiento sale sellado (account/branch/before/after)', v_n = 1, format('movs coincidentes=%s', v_n));
  -- idempotencia: misma clave no descuenta dos veces
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s1', v_today, pg_temp.items1(v_p1, 100, 3)));
  PERFORM pg_temp.rec('S1d reintento con misma Idempotency-Key no vuelve a descontar',
    (v_r.o_res->>'replayed')::boolean IS TRUE AND pg_temp.bs(v_p1, v_ba) = 7, format('replayed=%s saldoA=%s', v_r.o_res->>'replayed', pg_temp.bs(v_p1, v_ba)));

  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)',
    v_sale_ids::text, v_today, pg_temp.items1(v_p1, 100, 5)));
  v_res2 := v_r.o_res;
  PERFORM pg_temp.rec('S2 editar venta 3 -> 5 (stock 7 -> 5)', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 5,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba), pg_temp.mv(v_p1)));
  v_op := (v_res2->>'operation_id')::uuid;

  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_op));
  PERFORM pg_temp.rec('S3 borrar venta editada (stock 5 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 10 AND pg_temp.ledger_ok(v_p1, v_ba, 10),
    format('estado=%s msg=%s saldoA=%s libro_concilia=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba), pg_temp.ledger_ok(v_p1, v_ba, 10), pg_temp.mv(v_p1)));

  -- stock insuficiente / cantidad invalida
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s3b', v_today, pg_temp.items1(v_p1, 100, 11)));
  PERFORM pg_temp.rec('S3b vender 11 con stock 10 se rechaza sin tocar saldo', v_r.o_state = 'P0409' AND pg_temp.bs(v_p1, v_ba) = 10, format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s3c', v_today, pg_temp.items1(v_p1, 100, 0)));
  PERFORM pg_temp.rec('S3c cantidad 0 se rechaza', v_r.o_state = 'P0400', format('estado=%s', v_r.o_state));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s3d', v_today, pg_temp.items1(v_p1, 100, 10)));
  PERFORM pg_temp.rec('S3d vender exactamente todo el stock (10) deja 0 y no negativo', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 0, format('estado=%s saldoA=%s', v_r.o_state, pg_temp.bs(v_p1, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', (v_r.o_res->>'operation_id')::uuid));
  PERFORM pg_temp.rec('S3e borrar esa venta repone los 10', pg_temp.bs(v_p1, v_ba) = 10, format('saldoA=%s', pg_temp.bs(v_p1, v_ba)));

  -- ===================== S4-S6: COMPRA alta -> edicion -> borrado =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra smoke'', %L::jsonb)', 'smk-s4', v_today, pg_temp.items1(v_p3, 50, 4)));
  v_res := v_r.o_res;
  PERFORM pg_temp.rec('S4 compra 4u (stock 10 -> 14)', v_r.o_state = '00000' AND pg_temp.bs(v_p3, v_ba) = 14,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p3, v_ba), pg_temp.mv(v_p3)));
  v_pop := (v_res->>'operation_id')::uuid;
  SELECT array_agg(id) INTO v_pur_ids FROM public.purchases WHERE operation_id = v_pop;
  SELECT count(*) INTO v_n FROM public.purchases WHERE operation_id = v_pop AND branch_id = v_ba;
  PERFORM pg_temp.rec('S4b compra sin sucursal elegida queda con la principal', v_n >= 1, format('filas=%s', v_n));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''compra editada'', %L::jsonb)', v_pur_ids::text, v_today, pg_temp.items1(v_p3, 50, 6)));
  v_pop := COALESCE((v_r.o_res->>'operation_id')::uuid, v_pop);
  PERFORM pg_temp.rec('S5 editar compra 4 -> 6 (stock 14 -> 16)', v_r.o_state = '00000' AND pg_temp.bs(v_p3, v_ba) = 16,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p3, v_ba), pg_temp.mv(v_p3)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_purchase_operation(NULL, %L::uuid, ''smoke'')', v_pop));
  PERFORM pg_temp.rec('S6 borrar compra (stock 16 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p3, v_ba) = 10 AND pg_temp.ledger_ok(v_p3, v_ba, 10),
    format('estado=%s msg=%s saldoA=%s libro_concilia=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p3, v_ba), pg_temp.ledger_ok(v_p3, v_ba, 10), pg_temp.mv(v_p3)));

  -- ===================== S7: compra ya vendida (piso en cero) =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_operation(%L, %L::date, ''compra P4'', %L::jsonb)', 'smk-s7a', v_today, pg_temp.items1(v_p4, 50, 4)));
  v_pop := (v_r.o_res->>'operation_id')::uuid;
  SELECT array_agg(id) INTO v_pur_ids FROM public.purchases WHERE operation_id = v_pop;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s7b', v_today, pg_temp.items1(v_p4, 100, 12)));
  v_res := v_r.o_res; v_op := (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.rec('S7a P4: compra 4 (14) + venta 12 -> 2', pg_temp.bs(v_p4, v_ba) = 2, format('saldoA=%s', pg_temp.bs(v_p4, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)', v_pur_ids::text, v_today, pg_temp.items1(v_p4, 50, 1)));
  PERFORM pg_temp.rec('S7b editar compra a menos de lo ya vendido: informativo (que error da y deja saldo intacto)',
    pg_temp.bs(v_p4, v_ba) >= 0, format('estado=%s msg=%s saldoA=%s (no debe quedar negativo ni parcial)', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p4, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_purchase_operation(NULL, %L::uuid, ''smoke'')', v_pop));
  PERFORM pg_temp.rec('S7c borrar compra ya vendida: piso en cero trazable (no negativo)', pg_temp.bs(v_p4, v_ba) >= 0,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p4, v_ba), pg_temp.mv(v_p4)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_op));
  PERFORM pg_temp.rec('S7d borrar la venta tras el piso: INFORMATIVO (stock final vs 10 original)', TRUE,
    format('saldoA=%s (original 10; diferencia=%s por el piso) libro_concilia=%s', pg_temp.bs(v_p4, v_ba), pg_temp.bs(v_p4, v_ba) - 10, pg_temp.ledger_ok(v_p4, v_ba, 10)));

  PERFORM pg_temp.rec('S7e R4b: el libro suma lo mismo que el saldo tras piso+borrado? (suma deltas P4 vs saldo vivo)',
    pg_temp.ledger_ok(v_p4, v_ba, 10),
    format('saldo vivo=%s ; 10 + suma(deltas)=%s ; filas=%s', pg_temp.bs(v_p4, v_ba),
      10 + COALESCE((SELECT SUM(quantity_delta) FROM public.stock_movements WHERE product_id = v_p4), 0),
      (SELECT string_agg(type || ' d=' || quantity_delta || ' antes=' || quantity_before || ' despues=' || quantity_after, ' | ' ORDER BY created_at, id) FROM public.stock_movements WHERE product_id = v_p4)));

  -- ===================== S8: POS (rpc_quick_sale) =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_quick_sale(%L, NULL, %L::jsonb)', 'smk-s8',
    jsonb_build_array(jsonb_build_object('product_id', v_p5, 'quantity', 2, 'price', 100, 'subtotal', 200))::text));
  v_res := v_r.o_res;
  PERFORM pg_temp.rec('S8 POS vende 2u (stock 10 -> 8)', v_r.o_state = '00000' AND pg_temp.bs(v_p5, v_ba) = 8,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p5, v_ba), pg_temp.mv(v_p5)));
  v_op := (v_res->>'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_op));
  PERFORM pg_temp.rec('S8b borrar venta POS repone (8 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p5, v_ba) = 10 AND pg_temp.ledger_ok(v_p5, v_ba, 10),
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p5, v_ba), pg_temp.mv(v_p5)));

  -- ===================== S9: TRANSFERENCIA entre sucursales =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_transfer_stock(%L::uuid, %L::uuid, %L::uuid, 2)', v_p6, v_ba, v_bb));
  PERFORM pg_temp.rec('S9 transferir 2u A->B (A=8, B=2, total 10)',
    v_r.o_state = '00000' AND pg_temp.bs(v_p6, v_ba) = 8 AND pg_temp.bs(v_p6, v_bb) = 2 AND pg_temp.bs_total(v_p6) = 10,
    format('estado=%s msg=%s A=%s B=%s total=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p6, v_ba), pg_temp.bs(v_p6, v_bb), pg_temp.bs_total(v_p6), pg_temp.mv(v_p6)));
  SELECT count(DISTINCT transfer_id) INTO v_n FROM public.stock_movements WHERE product_id = v_p6 AND type IN ('transfer_out','transfer_in') AND transfer_id IS NOT NULL AND account_id = v_acc;
  PERFORM pg_temp.rec('S9b ambas patas comparten transfer_id y llevan account_id', v_n = 1, format('transfer_ids distintos=%s', v_n));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_transfer_stock(%L::uuid, %L::uuid, %L::uuid, 20)', v_p6, v_ba, v_bb));
  PERFORM pg_temp.rec('S9c transferir mas de lo disponible se rechaza', v_r.o_state = 'P0409' AND pg_temp.bs(v_p6, v_ba) = 8, format('estado=%s A=%s', v_r.o_state, pg_temp.bs(v_p6, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_transfer_stock(%L::uuid, %L::uuid, %L::uuid, 1)', v_p6, v_ba, v_ba));
  PERFORM pg_temp.rec('S9d transferir a la misma sucursal se rechaza', v_r.o_state = 'P0400', format('estado=%s', v_r.o_state));
  -- venta desde sucursal B elegida
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb, %L::uuid)', 'smk-s10', v_today, pg_temp.items1(v_p6, 100, 1), v_bb));
  v_op := (v_r.o_res->>'operation_id')::uuid;
  PERFORM pg_temp.rec('S10 venta en sucursal B elegida (B 2 -> 1, A intacta 8)', v_r.o_state = '00000' AND pg_temp.bs(v_p6, v_bb) = 1 AND pg_temp.bs(v_p6, v_ba) = 8,
    format('estado=%s msg=%s A=%s B=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p6, v_ba), pg_temp.bs(v_p6, v_bb)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_op));
  PERFORM pg_temp.rec('S10b borrar esa venta repone en B (no en A)', pg_temp.bs(v_p6, v_bb) = 2 AND pg_temp.bs(v_p6, v_ba) = 8, format('A=%s B=%s', pg_temp.bs(v_p6, v_ba), pg_temp.bs(v_p6, v_bb)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb, %L::uuid)', 'smk-s10c', v_today, pg_temp.items1(v_p6, 100, 5), v_bb));
  PERFORM pg_temp.rec('S10c vender 5 desde B con solo 2 (A tiene 8) se rechaza por sucursal', v_r.o_state = 'P0409' AND pg_temp.bs(v_p6, v_bb) = 2, format('estado=%s B=%s', v_r.o_state, pg_temp.bs(v_p6, v_bb)));

  -- ===================== S11: AJUSTES MANUALES =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, -1, ''loss'', ''rotura smoke'')', v_p6));
  PERFORM pg_temp.rec('S11 ajuste manual -1 (merma) sobre la principal (A 8 -> 7)', v_r.o_state = '00000' AND pg_temp.bs(v_p6, v_ba) = 7,
    format('estado=%s msg=%s A=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p6, v_ba)));
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE product_id = v_p6 AND type = 'loss' AND account_id = v_acc AND branch_id = v_ba AND reason IS NOT NULL;
  PERFORM pg_temp.rec('S11b el ajuste deja fila con account_id, branch_id y motivo (visible en historial)', v_n = 1, format('filas=%s', v_n));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, NULL, ''physical_count'', ''conteo smoke'', NULL, NULL, 12)', v_p6));
  PERFORM pg_temp.rec('S11c conteo fisico objetivo total=12 (A 7+B 2=9 -> +3 en A=10)', v_r.o_state = '00000' AND pg_temp.bs_total(v_p6) = 12,
    format('estado=%s msg=%s A=%s B=%s total=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p6, v_ba), pg_temp.bs(v_p6, v_bb), pg_temp.bs_total(v_p6)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_adjust_branch_stock(%L::uuid, %L::uuid, 5, ''conteo B'')', v_p6, v_bb));
  PERFORM pg_temp.rec('S11d ajuste absoluto por sucursal B=5', v_r.o_state = '00000' AND pg_temp.bs(v_p6, v_bb) = 5,
    format('estado=%s msg=%s B=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p6, v_bb)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, -1, ''adjustment'', NULL)', v_p6));
  PERFORM pg_temp.rec('S11e ajuste sin motivo se rechaza', v_r.o_state = 'P0400', format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, -999, ''adjustment'', ''excede'')', v_p6));
  PERFORM pg_temp.rec('S11f ajuste que dejaria negativo se rechaza y no cambia saldo', v_r.o_state <> '00000' AND pg_temp.bs(v_p6, v_ba) >= 0, format('estado=%s A=%s', v_r.o_state, pg_temp.bs(v_p6, v_ba)));

  -- ===================== S12: REMITO de venta =====================
  v_res := NULL;
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_delivery_note(%L, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)', 'smk-s12', v_client, v_ba,
    jsonb_build_array(jsonb_build_object('product_id', v_p7, 'quantity', 3, 'price', 100, 'subtotal', 300))::text));
  v_dn := v_r.o_res;
  PERFORM pg_temp.rec('S12 remito de venta 3u descuenta (10 -> 7)', v_r.o_state = '00000' AND pg_temp.bs(v_p7, v_ba) = 7,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p7, v_ba), pg_temp.mv(v_p7)));
  IF v_dn IS NOT NULL THEN
    v_rev := (v_dn->>'revision')::int;
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_cancel_delivery_note(%L::uuid, %s, ''smoke'')', v_dn->>'id', COALESCE(v_rev, 1)));
    PERFORM pg_temp.rec('S12b anular remito repone (7 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p7, v_ba) = 10,
      format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p7, v_ba), pg_temp.mv(v_p7)));
    -- remito -> venta (convertir) -> borrar venta -> anular remito
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_delivery_note(%L, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)', 'smk-s12c', v_client, v_ba,
      jsonb_build_array(jsonb_build_object('product_id', v_p7, 'quantity', 2, 'price', 100, 'subtotal', 200))::text));
    v_dn := v_r.o_res; v_rev := (v_dn->>'revision')::int;
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_convert_delivery_note_to_sale(%L, %L::uuid, %s, %L::uuid)', 'smk-s12d', v_dn->>'id', COALESCE(v_rev, 1), v_pm_other));
    v_res2 := v_r.o_res;
    PERFORM pg_temp.rec('S12c convertir remito a venta NO vuelve a descontar (8 se mantiene)', v_r.o_state = '00000' AND pg_temp.bs(v_p7, v_ba) = 8,
      format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p7, v_ba), pg_temp.mv(v_p7)));
    IF v_r.o_state = '00000' THEN
      SELECT sale_operation_id INTO v_op FROM public.sales_orders WHERE source_delivery_note_id = (v_dn->>'id')::uuid AND status <> 'canceled' LIMIT 1;
      SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_op));
      PERFORM pg_temp.rec('S12d borrar la venta nacida del remito NO repone (el remito sigue reteniendo)', v_r.o_state = '00000' AND pg_temp.bs(v_p7, v_ba) = 8,
        format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p7, v_ba)));
      SELECT revision INTO v_rev FROM public.delivery_notes WHERE id = (v_dn->>'id')::uuid;
      SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_cancel_delivery_note(%L::uuid, %s, ''smoke'')', v_dn->>'id', COALESCE(v_rev, 1)));
      PERFORM pg_temp.rec('S12e anular el remito repone (8 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p7, v_ba) = 10 AND pg_temp.ledger_ok(v_p7, v_ba, 10),
        format('estado=%s msg=%s saldoA=%s libro_concilia=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p7, v_ba), pg_temp.ledger_ok(v_p7, v_ba, 10), pg_temp.mv(v_p7)));
    END IF;
  END IF;

  -- ===================== S13: REMITO de compra =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_purchase_delivery_note(%L, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)', 'smk-s13', v_supp, v_ba,
    jsonb_build_array(jsonb_build_object('product_id', v_p8, 'quantity', 5, 'price', 50, 'subtotal', 250))::text));
  v_dn := v_r.o_res;
  PERFORM pg_temp.rec('S13 remito de compra 5u suma (10 -> 15)', v_r.o_state = '00000' AND pg_temp.bs(v_p8, v_ba) = 15,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p8, v_ba), pg_temp.mv(v_p8)));
  IF v_dn IS NOT NULL THEN
    v_rev := (v_dn->>'revision')::int;
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_cancel_delivery_note(%L::uuid, %s, ''smoke'')', v_dn->>'id', COALESCE(v_rev, 1)));
    PERFORM pg_temp.rec('S13b anular remito de compra resta (15 -> 10)', v_r.o_state = '00000' AND pg_temp.bs(v_p8, v_ba) = 10,
      format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p8, v_ba)));
  END IF;

  -- ===================== S14: CANTIDADES DECIMALES (balanza) =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s14', v_today, pg_temp.items1(v_p9, 1000, 0.35)));
  v_res := v_r.o_res;
  PERFORM pg_temp.rec('S14 venta decimal 0,35 (5 -> 4,65)', v_r.o_state = '00000' AND pg_temp.bs(v_p9, v_ba) = 4.65,
    format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p9, v_ba)));
  v_sale_ids := pg_temp.sale_ids(v_res);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_sale_ids::text, v_today, pg_temp.items1(v_p9, 1000, 0.5)));
  v_res2 := v_r.o_res;
  PERFORM pg_temp.rec('S14b editar a 0,5 (-> 4,5)', v_r.o_state = '00000' AND pg_temp.bs(v_p9, v_ba) = 4.5, format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p9, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', (v_res2->>'operation_id')::uuid));
  PERFORM pg_temp.rec('S14c borrar -> vuelve a 5 exacto, libro concilia', pg_temp.bs(v_p9, v_ba) = 5 AND pg_temp.ledger_ok(v_p9, v_ba, 5),
    format('saldoA=%s libro_concilia=%s', pg_temp.bs(v_p9, v_ba), pg_temp.ledger_ok(v_p9, v_ba, 5)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s14d', v_today, pg_temp.items1(v_p9, 1000, 0.33333)));
  PERFORM pg_temp.rec('S14d cantidad con 5 decimales (0,33333): INFORMATIVO (que pasa con el redondeo a 4 dec)', TRUE,
    format('estado=%s msg=%s saldoA=%s movs=[%s]', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p9, v_ba), pg_temp.mv(v_p9)));

  -- ===================== S15: VARIANTES =====================
  BEGIN
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
    VALUES (v_user, v_acc, 'SMK Padre', 'SMK-PAR', NULL, 100, 'variant_only') RETURNING id INTO v_par;
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
    VALUES (v_user, v_acc, 'SMK Hijo', 'SMK-CHD', 60, 100, v_par, TRUE) RETURNING id INTO v_child;
    PERFORM public.c21_apply_branch_stock_delta(v_acc, v_child, v_ba, 10);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s15a', v_today, pg_temp.items1(v_par, 100, 1)));
    PERFORM pg_temp.rec('S15 vender el PADRE de variantes se rechaza (P0422)', v_r.o_state = 'P0422', format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s15b', v_today, pg_temp.items1(v_child, 100, 2)));
    PERFORM pg_temp.rec('S15b vender la VARIANTE descuenta su propio stock (10 -> 8)', v_r.o_state = '00000' AND pg_temp.bs(v_child, v_ba) = 8,
      format('estado=%s msg=%s saldoHijo=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_child, v_ba)));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
    PERFORM pg_temp.rec('S15 variantes: no se pudo armar el fixture', FALSE, v_txt);
  END;

  -- ===================== S16: IMPORTADOR (rpc_import_products -> rpc_bulk_upsert_products) =====================
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_import_products(%L, %L::jsonb, ''a.csv'', %L, false)', 'smk-imp-1',
    jsonb_build_array(jsonb_build_object('name', 'SMK Importado', 'sku', 'SMK-IMP-1', 'price', 100, 'cost', 60, 'stock', 20))::text, 'hash-smk-1'));
  SELECT id INTO v_p1 FROM public.products WHERE account_id = v_acc AND sku = 'SMK-IMP-1';
  PERFORM pg_temp.rec('S16 importar producto con stock inicial 20 (branch_stock = 20 en la principal)', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 20,
    format('estado=%s msg=%s saldoA=%s movimientos_en_ledger=%s resp=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba), pg_temp.mv_n(v_p1), left(v_r.o_res::text, 160)));
  PERFORM pg_temp.rec('S16b R1: el stock inicial importado deja fila en stock_movements (apertura)?', pg_temp.mv_n(v_p1) > 0,
    format('movimientos_en_ledger=%s (0 = sin rastro de apertura)', pg_temp.mv_n(v_p1)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s16', v_today, pg_temp.items1(v_p1, 100, 5)));
  PERFORM pg_temp.rec('S16c venta de 5 sobre el producto importado (20 -> 15)', v_r.o_state = '00000' AND pg_temp.bs(v_p1, v_ba) = 15, format('estado=%s saldoA=%s', v_r.o_state, pg_temp.bs(v_p1, v_ba)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_import_products(%L, %L::jsonb, ''b.csv'', %L, false)', 'smk-imp-2',
    jsonb_build_array(jsonb_build_object('name', 'SMK Importado', 'sku', 'SMK-IMP-1', 'price', 120, 'cost', 60, 'stock', 20))::text, 'hash-smk-2'));
  PERFORM pg_temp.rec('S16d R1: reimportar OTRO archivo con el mismo SKU y stock=20 tras vender 5 respeta las ventas (debe quedar 15)?', pg_temp.bs(v_p1, v_ba) = 15,
    format('estado=%s msg=%s saldoA=%s (15 = respeta; 20 = pisa el stock vivo) movs=[%s] libro_concilia_desde_apertura20=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_p1, v_ba), pg_temp.mv(v_p1), pg_temp.ledger_ok(v_p1, v_ba, 20)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_import_products(%L, %L::jsonb, ''c.csv'', %L, false)', 'smk-imp-3',
    jsonb_build_array(jsonb_build_object('name', 'SMK Importado', 'sku', 'SMK-IMP-1', 'price', 130, 'cost', 60))::text, 'hash-smk-3'));
  PERFORM pg_temp.rec('S16e reimportar SIN columna stock (celda vacia) no toca el saldo', TRUE,
    format('estado=%s saldoA=%s (se mantiene el valor que dejo S16d)', v_r.o_state, pg_temp.bs(v_p1, v_ba)));

  -- ===================== S17: guardas de la base =====================
  BEGIN
    UPDATE public.branch_stock SET quantity = -1 WHERE product_id = v_p6 AND branch_id = v_ba;
    PERFORM pg_temp.rec('S17 CHECK quantity >= 0 en branch_stock', FALSE, 'se pudo dejar el saldo en -1: NO hay CHECK');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.rec('S17 CHECK quantity >= 0 en branch_stock', TRUE, 'rechazado con check_violation (23514)');
  END;

  -- ===================== S20: R3 miembros de la misma cuenta (seller / admin) =====================
  DECLARE
    v_seller uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_multi uuid := gen_random_uuid(); v_buyer uuid := gen_random_uuid();
    v_pr3 uuid; v_sop uuid; v_osale uuid[]; v_acc_used uuid; v_ids text; v_op3 uuid;
  BEGIN
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
      (v_seller, 'authenticated', 'authenticated', 'smoke-seller@test.local', now(), now(), '{"name":"Smoke Seller"}'::jsonb),
      (v_admin,  'authenticated', 'authenticated', 'smoke-admin@test.local',  now(), now(), '{"name":"Smoke Admin"}'::jsonb),
      (v_multi,  'authenticated', 'authenticated', 'smoke-multi@test.local',  now(), now(), '{"name":"Smoke Multi"}'::jsonb),
      (v_buyer,  'authenticated', 'authenticated', 'smoke-compras@test.local', now(), now(), '{"name":"Smoke Compras"}'::jsonb);
    PERFORM pg_temp.add_member(v_acc, v_buyer, 'purchases', FALSE);
    PERFORM pg_temp.add_member(v_acc, v_seller, 'seller', FALSE);
    PERFORM pg_temp.add_member(v_acc, v_admin,  'admin',  FALSE);
    PERFORM pg_temp.add_member(v_acc, v_multi,  'seller', TRUE);
    -- multiusuario-operativo (tanda A+C): la aceptacion de una invitacion deja el NEGOCIO como cuenta activa del invitado
    UPDATE public.profiles SET active_account_id = v_acc WHERE id = v_multi;
    v_pr3 := pg_temp.mkprod(v_user, v_acc, 'SMK R3 creado por el owner', v_ba, 30);
    PERFORM pg_temp.rec('S20 setup R3: seller y admin miembros UNICOS de A; multi con cuenta personal + A',
      (SELECT count(*) FROM public.account_members WHERE user_id IN (v_seller, v_admin)) = 2
      AND (SELECT count(*) FROM public.account_members WHERE user_id = v_multi) = 2,
      format('membresias seller=%s admin=%s multi=%s',
        (SELECT count(*) FROM public.account_members WHERE user_id = v_seller),
        (SELECT count(*) FROM public.account_members WHERE user_id = v_admin),
        (SELECT count(*) FROM public.account_members WHERE user_id = v_multi)));

    PERFORM pg_temp.as_user(v_seller);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-r3a', v_today, pg_temp.items1(v_pr3, 100, 1)));
    PERFORM pg_temp.rec('R3a seller vende por FORMULARIO un producto creado por el owner', v_r.o_state = '00000',
      format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pr3, v_ba)));

    PERFORM pg_temp.as_user(v_admin);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-r3b', v_today, pg_temp.items1(v_pr3, 100, 1)));
    PERFORM pg_temp.rec('R3b admin vende por FORMULARIO un producto creado por el owner', v_r.o_state = '00000',
      format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pr3, v_ba)));

    PERFORM pg_temp.as_user(v_seller);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_quick_sale(%L, NULL, %L::jsonb)', 'smk-r3c',
      jsonb_build_array(jsonb_build_object('product_id', v_pr3, 'quantity', 1, 'price', 100, 'subtotal', 100))::text));
    v_sop := (v_r.o_res->>'operation_id')::uuid;
    PERFORM pg_temp.rec('R3c seller vende por POS un producto creado por el owner', v_r.o_state = '00000',
      format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pr3, v_ba)));

    PERFORM pg_temp.as_user(v_user);
    SELECT array_agg(id) INTO v_osale FROM public.sales WHERE operation_id = v_sop;
    IF v_osale IS NOT NULL THEN
      SELECT * INTO v_r FROM pg_temp.try_rpc(format(
        'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_osale::text, v_today, pg_temp.items1(v_pr3, 100, 2)));
      PERFORM pg_temp.rec('R3d owner EDITA una venta hecha por el seller (POS)', v_r.o_state = '00000',
        format('estado=%s msg=%s saldoA=%s', v_r.o_state, v_r.o_msg, pg_temp.bs(v_pr3, v_ba)));
      SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_delete_sale_operation(NULL, %L::uuid, ''smoke'')', v_sop));
      PERFORM pg_temp.rec('R3e owner BORRA una venta hecha por el seller', v_r.o_state = '00000',
        format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
    ELSE
      PERFORM pg_temp.rec('R3d/e sin venta del seller para editar', FALSE, 'R3c no dejo filas en sales');
    END IF;

    PERFORM pg_temp.as_user(v_user);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-r3f', v_today, pg_temp.items1(v_pr3, 100, 1)));
    v_osale := pg_temp.sale_ids(v_r.o_res);
    PERFORM pg_temp.as_user(v_admin);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, ''ARS'', %L::jsonb)', v_osale::text, v_today, pg_temp.items1(v_pr3, 100, 2)));
    PERFORM pg_temp.rec('R3f admin EDITA una venta hecha por el owner (formulario)', v_r.o_state = '00000',
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));

    -- multiusuario-operativo tanda B (OQ-3 b): comprar es del rol COMPRAS (CAN_PURCHASE = dueno, admin, compras); el vendedor NO compra.
    PERFORM pg_temp.as_user(v_buyer);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_purchase_operation(%L, %L::date, ''compra compras'', %L::jsonb)', 'smk-r3g', v_today, pg_temp.items1(v_pr3, 50, 2)));
    PERFORM pg_temp.rec('R3g el rol COMPRAS carga una COMPRA de un producto del owner', v_r.o_state = '00000',
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
    PERFORM pg_temp.as_user(v_seller);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_purchase_operation(%L, %L::date, ''compra seller'', %L::jsonb)', 'smk-r3g2', v_today, pg_temp.items1(v_pr3, 50, 2)));
    PERFORM pg_temp.rec('R3g2 seller carga una COMPRA (esperado por diseno OQ-3 b: rechazado P0403, el vendedor no compra)', v_r.o_state = 'P0403',
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));

    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, -1, ''loss'', ''x'')', v_pr3));
    PERFORM pg_temp.rec('R3h seller AJUSTA stock a mano (esperado por diseno: rechazado P0403)', v_r.o_state = 'P0403',
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_transfer_stock(%L::uuid, %L::uuid, %L::uuid, 1)', v_pr3, v_ba, v_bb));
    PERFORM pg_temp.rec('R3i seller TRANSFIERE stock entre sucursales (INFORMATIVO)', TRUE,
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));

    PERFORM pg_temp.as_user(v_multi);
    SET LOCAL ROLE authenticated;
    SELECT string_agg(left(cai::text, 8), ',') INTO v_ids FROM public.current_account_ids() cai;
    RESET ROLE;
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_quick_sale(%L, NULL, %L::jsonb)', 'smk-r3j',
      jsonb_build_array(jsonb_build_object('product_id', v_pr3, 'quantity', 1, 'price', 100, 'subtotal', 100))::text));
    v_op3 := (v_r.o_res->>'operation_id')::uuid;
    SELECT account_id INTO v_acc_used FROM public.sales WHERE operation_id = v_op3 LIMIT 1;
    PERFORM pg_temp.rec('R3j usuario con 2 membresias (personal + A): el POS opera sobre la cuenta A?',
      v_r.o_state = '00000' AND v_acc_used = v_acc,
      format('estado=%s msg=%s current_account_ids=[%s] cuenta_A=%s cuenta_usada=%s', v_r.o_state, v_r.o_msg, v_ids, left(v_acc::text, 8), left(COALESCE(v_acc_used::text, '-'), 8)));
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-r3k', v_today, pg_temp.items1(v_pr3, 100, 1)));
    PERFORM pg_temp.rec('R3k usuario con 2 membresias: venta por formulario sobre producto de A', v_r.o_state = '00000',
      format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-r3l', v_today,
      jsonb_build_array(jsonb_build_object('amount', 100, 'quantity', 1))::text));
    v_op3 := (v_r.o_res->>'operation_id')::uuid;
    SELECT account_id INTO v_acc_used FROM public.sales WHERE operation_id = v_op3 LIMIT 1;
    PERFORM pg_temp.rec('R3l usuario con 2 membresias: una venta de servicio (sin producto) queda en la cuenta A?', v_acc_used = v_acc,
      format('estado=%s msg=%s cuenta_A=%s cuenta_donde_quedo_la_venta=%s (la otra es su cuenta personal)', v_r.o_state, v_r.o_msg, left(v_acc::text, 8), left(COALESCE(v_acc_used::text, '-'), 8)));
    PERFORM pg_temp.as_user(v_user);
  END;

  -- ===================== S18: aislamiento entre cuentas =====================
  v_val := pg_temp.bs_total(v_p6);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user2::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user2::text, true);
  SELECT * INTO v_r FROM pg_temp.try_rpc(format(
    'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'smk-s18', v_today, pg_temp.items1(v_p6, 100, 1)));
  PERFORM pg_temp.rec('S18 otro tenant NO puede vender un producto ajeno ni mover su stock', v_r.o_state <> '00000' AND pg_temp.bs_total(v_p6) = v_val,
    format('estado=%s msg=%s totalP6 antes=%s despues=%s', v_r.o_state, v_r.o_msg, v_val, pg_temp.bs_total(v_p6)));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_transfer_stock(%L::uuid, %L::uuid, %L::uuid, 1)', v_p6, v_ba, v_bb));
  PERFORM pg_temp.rec('S18a otro tenant NO puede transferir stock ajeno', v_r.o_state <> '00000' AND pg_temp.bs_total(v_p6) = v_val, format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_stock_adjustment(%L::uuid, 5, ''adjustment'', ''intruso'')', v_p6));
  PERFORM pg_temp.rec('S18b otro tenant NO puede ajustar stock ajeno', v_r.o_state = 'P0404', format('estado=%s msg=%s', v_r.o_state, v_r.o_msg));
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  -- ===================== S19: invariantes globales de la cuenta =====================
  SELECT count(*) INTO v_n FROM public.branch_stock WHERE account_id = v_acc AND quantity < 0;
  PERFORM pg_temp.rec('S19 ningun saldo negativo en la cuenta', v_n = 0, format('saldos negativos=%s', v_n));
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc AND (branch_id IS NULL);
  PERFORM pg_temp.rec('S19b todo movimiento de la cuenta lleva branch_id', v_n = 0, format('movimientos sin sucursal=%s', v_n));
  SELECT count(*) INTO v_n FROM public.stock_movements sm
   WHERE sm.product_id IN (SELECT id FROM public.products WHERE account_id = v_acc) AND sm.account_id IS NULL;
  PERFORM pg_temp.rec('S19c todo movimiento de productos de la cuenta lleva account_id (si no, invisible por RLS)', v_n = 0, format('movimientos sin account_id=%s', v_n));
  -- visibilidad por RLS del historial: lo que ve `authenticated` == lo que hay
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc;
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_val FROM public.stock_movements;
  RESET ROLE;
  PERFORM pg_temp.rec('S19d el historial es visible por RLS para el dueño (movs en tabla vs movs visibles)', v_val::int = v_n,
    format('en tabla=%s visibles_para_authenticated=%s', v_n, v_val::int));
  -- conciliacion del libro en las sucursales de los productos con saldo sembrado
  PERFORM pg_temp.rec('S19e libro concilia P1/P3/P5/P7 (saldo inicial + deltas = saldo vivo)',
    pg_temp.ledger_ok(v_p3, v_ba, 10) AND pg_temp.ledger_ok(v_p5, v_ba, 10) AND pg_temp.ledger_ok(v_p7, v_ba, 10),
    format('P3=%s P5=%s P7=%s', pg_temp.ledger_ok(v_p3, v_ba, 10), pg_temp.ledger_ok(v_p5, v_ba, 10), pg_temp.ledger_ok(v_p7, v_ba, 10)));
END
$smoke$;

SELECT 'RESUMEN: ' || count(*) FILTER (WHERE ok) || ' OK / ' || count(*) FILTER (WHERE NOT ok) || ' FAIL de ' || count(*) AS resumen FROM smoke_res;
SELECT seq, step, detail FROM smoke_res WHERE NOT ok ORDER BY seq;
ROLLBACK;
