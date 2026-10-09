-- =============================================================================
-- test_stock_adjustment_account_branch.sql — Gate de comportamiento del hotfix
-- `stock-adjustment-historial-invisible`
-- (migración 20261072000001_stock_adjustment_account_branch.sql).
--
-- EL BUG. public.rpc_stock_adjustment (el ajuste manual del modal de /stock y de
-- su importador CSV, llamada por el navegador vía PostgREST) insertaba en
-- public.stock_movements SIN account_id ni branch_id, aunque ya tenía calculados
-- v_account_id y v_target_branch. La policy de lectura
-- stock_movements_account_select exige account_id IN (SELECT
-- current_account_ids()), así que esas filas eran INVISIBLES en el historial de
-- movimientos (stock-movements-panel.tsx lee la tabla por supabase-js sin
-- filtros propios). El saldo sí se movía: sólo faltaba el sello.
--
-- Lo que este gate EJECUTA de verdad (regla del proyecto: una RPC que escribe
-- dinero/stock necesita un gate que la corra, no uno que la nombre):
--   (a) la RPC como `authenticated` con un owner real, por TRES caminos del
--       cálculo (adjustment con delta positivo, physical_count con
--       p_target_quantity, loss con delta negativo): cada fila nueva lleva
--       account_id = la cuenta y branch_id = c26_default_branch(cuenta), y
--       branch_stock se movió lo esperado. Triangulación: una cuenta con DOS
--       sucursales (el sello es la default operativa, la más antigua, no la
--       última creada) y una segunda cuenta (el sello es el de SU cuenta).
--   (b) visibilidad bajo RLS: con SET LOCAL ROLE authenticated y los claims del
--       owner, las filas nuevas se ven (count = 1 cada una). CONTROL NEGATIVO
--       obligatorio: una fila gemela con account_id NULL (la forma del bug)
--       insertada como postgres NO se ve bajo el mismo rol y claims — eso
--       prueba que el gate mide la RLS de verdad y que el rojo de (a)/(b) sin
--       la migración no es un artefacto. Y el aislamiento: el owner de la otra
--       cuenta no ve ninguna de las filas.
--   (c) ACL: la RPC conserva EXECUTE para authenticated/service_role, sin
--       anon ni PUBLIC, SECURITY DEFINER con search_path fijo, y UN solo
--       overload (candado contra un futuro DROP FUNCTION, que resetea la ACL y
--       deja la RPC sin EXECUTE).
--
-- El backfill de la migración (las 29 filas históricas de prod) se verifica
-- aparte, contra el archivo real de la migración; este gate prueba el
-- comportamiento de la RPC y su visibilidad.
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila de las cuentas del gate y residuo
-- cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run stock adjustment account/branch gate").
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.sab_as(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  END IF;
END;
$f$;

-- Llama a la RPC EXACTAMENTE como la llama el navegador: rol authenticated y
-- claims del usuario. Si falla, devuelve {"error": "<sqlstate> <mensaje>"} en
-- vez de abortar (el gate acumula fallas y las reporta todas juntas).
CREATE OR REPLACE FUNCTION pg_temp.sab_adjust(p_uid uuid, p_product uuid, p_delta numeric,
                                              p_type text, p_target numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE
  v_r     jsonb;
  v_state text;
  v_msg   text;
BEGIN
  PERFORM pg_temp.sab_as(p_uid);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.rpc_stock_adjustment(p_product, p_delta, p_type, 'gate sab', NULL, NULL, p_target);
    EXECUTE 'RESET ROLE';
    RETURN v_r;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RETURN jsonb_build_object('error', v_state || ' ' || v_msg);
  END;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.sab_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock
  WHERE product_id = p_product AND branch_id = p_branch;
$f$;

-- Diferencias entre la fila del ledger y lo esperado; NULL si coincide todo.
CREATE OR REPLACE FUNCTION pg_temp.sab_diff(p_mov uuid, p_account uuid, p_branch uuid, p_user uuid,
                                            p_type text, p_delta numeric, p_before numeric, p_after numeric)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  r public.stock_movements%ROWTYPE;
  d text[] := '{}';
BEGIN
  SELECT * INTO r FROM public.stock_movements WHERE id = p_mov;
  IF NOT FOUND THEN
    RETURN 'la fila del movimiento no existe';
  END IF;
  IF r.account_id IS DISTINCT FROM p_account THEN
    d := d || format('account_id=%s (esperado %s)', COALESCE(r.account_id::text, 'NULL'), p_account);
  END IF;
  IF r.branch_id IS DISTINCT FROM p_branch THEN
    d := d || format('branch_id=%s (esperado %s)', COALESCE(r.branch_id::text, 'NULL'), p_branch);
  END IF;
  IF r.user_id IS DISTINCT FROM p_user OR r.performed_by IS DISTINCT FROM p_user THEN
    d := d || format('user_id/performed_by=%s/%s (esperado %s)',
                     COALESCE(r.user_id::text, 'NULL'), COALESCE(r.performed_by::text, 'NULL'), p_user);
  END IF;
  IF r.type IS DISTINCT FROM p_type THEN
    d := d || format('type=%s (esperado %s)', COALESCE(r.type, 'NULL'), p_type);
  END IF;
  IF r.quantity_delta IS DISTINCT FROM p_delta
     OR r.quantity_before IS DISTINCT FROM p_before
     OR r.quantity_after IS DISTINCT FROM p_after THEN
    d := d || format('delta/before/after=%s/%s/%s (esperado %s/%s/%s)',
                     COALESCE(r.quantity_delta::text, 'NULL'), COALESCE(r.quantity_before::text, 'NULL'),
                     COALESCE(r.quantity_after::text, 'NULL'), p_delta, p_before, p_after);
  END IF;
  RETURN NULLIF(array_to_string(d, '; '), '');
END;
$f$;

DO $$
DECLARE
  v_failures  text[] := '{}';
  v_f0        integer;

  v_owner_a   uuid := gen_random_uuid();
  v_owner_b   uuid := gen_random_uuid();
  v_users     uuid[];
  v_accounts  uuid[];
  v_account_a uuid;
  v_account_b uuid;
  v_x         uuid;   -- sucursal default operativa de A (la más antigua)
  v_y         uuid;   -- segunda sucursal de A, creada DESPUÉS
  v_xb        uuid;   -- sucursal default de B
  v_p1        uuid;
  v_p2        uuid;
  v_pb        uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid; v_m6 uuid; v_mb uuid; v_twin uuid;

  v_r         jsonb;
  v_txt       text;
  v_n1 bigint; v_n2 bigint; v_n3 bigint; v_n4 bigint; v_nt bigint; v_nb bigint; v_na bigint;
  v_state     text;
  v_msg       text;
  v_table     text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'stock-adjustment-sab-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate SAB ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  SELECT id INTO v_x  FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_xb FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  IF v_x IS NULL OR v_xb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  -- Segunda sucursal de A, posterior: el sello tiene que ser la default operativa
  -- (la más antigua activa), no "la última creada" ni una sucursal arbitraria.
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate SAB Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  IF public.c26_default_branch(v_account_a) IS DISTINCT FROM v_x
     OR public.c26_default_branch(v_account_b) IS DISTINCT FROM v_xb THEN
    RAISE EXCEPTION 'SETUP FAILED: c26_default_branch no devuelve la sucursal más antigua de cada cuenta';
  END IF;

  -- El guard legacy de la RPC exige products.user_id = auth.uid(): el producto
  -- pertenece al owner (no es un hueco de este gate, es el contrato vigente).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate SAB P1', 'SAB-P1', 10, 20) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate SAB P2', 'SAB-P2', 10, 20) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'Gate SAB PB', 'SAB-PB', 10, 20) RETURNING id INTO v_pb;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) El ajuste sella account_id y branch_id — tres caminos del cálculo
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := COALESCE(array_length(v_failures, 1), 0);

  -- (a1) adjustment, delta positivo, desde stock 0.
  v_r := pg_temp.sab_adjust(v_owner_a, v_p1, 10, 'adjustment');
  v_m1 := (v_r->>'movement_id')::uuid;
  IF v_m1 IS NULL THEN
    v_failures := v_failures || format('FAIL (a1): el ajuste +10 no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_m1, v_account_a, public.c26_default_branch(v_account_a), v_owner_a, 'adjustment', 10, 0, 10);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a1): adjustment +10 -> %s', v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_p1, v_x) <> 10 THEN
    v_failures := v_failures || format('FAIL (a1): branch_stock de P1 en la default debía ser 10, es %s', pg_temp.sab_stock(v_p1, v_x));
  END IF;

  -- (a2) physical_count con p_target_quantity: el delta lo calcula la RPC (7 - 10 = -3).
  v_r := pg_temp.sab_adjust(v_owner_a, v_p1, NULL, 'physical_count', 7);
  v_m2 := (v_r->>'movement_id')::uuid;
  IF v_m2 IS NULL THEN
    v_failures := v_failures || format('FAIL (a2): el conteo físico a 7 no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_m2, v_account_a, public.c26_default_branch(v_account_a), v_owner_a, 'physical_count', -3, 10, 7);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a2): physical_count a 7 -> %s', v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_p1, v_x) <> 7 THEN
    v_failures := v_failures || format('FAIL (a2): branch_stock de P1 en la default debía ser 7, es %s', pg_temp.sab_stock(v_p1, v_x));
  END IF;

  -- (a3) loss, delta negativo.
  v_r := pg_temp.sab_adjust(v_owner_a, v_p1, -2, 'loss');
  v_m3 := (v_r->>'movement_id')::uuid;
  IF v_m3 IS NULL THEN
    v_failures := v_failures || format('FAIL (a3): la pérdida -2 no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_m3, v_account_a, public.c26_default_branch(v_account_a), v_owner_a, 'loss', -2, 7, 5);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a3): loss -2 -> %s', v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_p1, v_x) <> 5 THEN
    v_failures := v_failures || format('FAIL (a3): branch_stock de P1 en la default debía ser 5, es %s', pg_temp.sab_stock(v_p1, v_x));
  END IF;

  -- (a4) cuenta con DOS sucursales: el sello (y el stock) van a la default
  -- operativa (la más antigua), no a la segunda.
  v_r := pg_temp.sab_adjust(v_owner_a, v_p2, 4, 'adjustment');
  v_m4 := (v_r->>'movement_id')::uuid;
  IF v_m4 IS NULL THEN
    v_failures := v_failures || format('FAIL (a4): el ajuste +4 de P2 no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_m4, v_account_a, v_x, v_owner_a, 'adjustment', 4, 0, 4);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a4): con dos sucursales el sello debía ser la default (%s), no la segunda (%s): %s', v_x, v_y, v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_p2, v_x) <> 4 OR pg_temp.sab_stock(v_p2, v_y) <> 0 THEN
    v_failures := v_failures || format('FAIL (a4): P2 debía tener 4 en la default y 0 en la segunda, tiene %s / %s',
                                       pg_temp.sab_stock(v_p2, v_x), pg_temp.sab_stock(v_p2, v_y));
  END IF;

  -- (a5) otra cuenta: el sello es el de SU cuenta y SU sucursal.
  v_r := pg_temp.sab_adjust(v_owner_b, v_pb, 3, 'adjustment');
  v_mb := (v_r->>'movement_id')::uuid;
  IF v_mb IS NULL THEN
    v_failures := v_failures || format('FAIL (a5): el ajuste +3 de la cuenta B no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_mb, v_account_b, v_xb, v_owner_b, 'adjustment', 3, 0, 3);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a5): el movimiento de la cuenta B -> %s', v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_pb, v_xb) <> 3 THEN
    v_failures := v_failures || format('FAIL (a5): branch_stock de PB en su default debía ser 3, es %s', pg_temp.sab_stock(v_pb, v_xb));
  END IF;

  -- (a6) stock-ledger-solo-rpc (tanda B, D8): el antes/después del movimiento es
  -- a nivel SUCURSAL, como el de todos los demás escritores. Con P2 repartido
  -- (4 en la default, 6 en la segunda) un +1 sobre la default deja 4 -> 5; antes
  -- de la tanda B esta RPC grababa el TOTAL del producto (10 -> 11).
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_y, 6);
  v_r := pg_temp.sab_adjust(v_owner_a, v_p2, 1, 'adjustment');
  v_m6 := (v_r->>'movement_id')::uuid;
  IF v_m6 IS NULL THEN
    v_failures := v_failures || format('FAIL (a6): el ajuste +1 de P2 repartido no devolvió movimiento: %s', v_r);
  ELSE
    v_txt := pg_temp.sab_diff(v_m6, v_account_a, v_x, v_owner_a, 'adjustment', 1, 4, 5);
    IF v_txt IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a6): con stock en dos sucursales el antes/después debía ser el de la sucursal afectada (4 -> 5, no el total 10 -> 11): %s', v_txt);
    END IF;
  END IF;
  IF pg_temp.sab_stock(v_p2, v_x) <> 5 OR pg_temp.sab_stock(v_p2, v_y) <> 6 THEN
    v_failures := v_failures || format('FAIL (a6): P2 debía quedar 5 en la default y 6 en la segunda, tiene %s / %s',
                                       pg_temp.sab_stock(v_p2, v_x), pg_temp.sab_stock(v_p2, v_y));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_f0 THEN
    RAISE NOTICE 'PASS (a): adjustment / physical_count / loss, cuenta con dos sucursales (antes/después a nivel sucursal) y segunda cuenta sellan account_id y branch_id y mueven branch_stock';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) Visibilidad bajo RLS (la consecuencia real del bug) + control negativo
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := COALESCE(array_length(v_failures, 1), 0);

  -- Control negativo: una fila gemela con la FORMA DEL BUG (account_id NULL),
  -- insertada como postgres (sin RLS). Bajo RLS NO debe verse jamás.
  -- stock-ledger-solo-rpc (tanda B, task 9.2): el gemelo lleva MOTIVO —desde la
  -- tanda B el CHECK stock_movements_manual_needs_reason rechaza cualquier
  -- movimiento de ajuste manual sin motivo, aun insertado como postgres—. Lo que
  -- lo hace "la forma del bug" es el account_id NULL, no la falta de motivo:
  -- el control negativo mide lo mismo que antes (fixture corregida, no el núcleo).
  INSERT INTO public.stock_movements (user_id, product_id, product_name, type, quantity_delta,
                                      quantity_before, quantity_after, reason, performed_by)
  VALUES (v_owner_a, v_p1, 'Gate SAB P1', 'adjustment', 1, 5, 6, 'gate sab gemelo (account_id NULL)', v_owner_a)
  RETURNING id INTO v_twin;

  PERFORM pg_temp.sab_as(v_owner_a);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) FILTER (WHERE id = v_m1), count(*) FILTER (WHERE id = v_m2),
         count(*) FILTER (WHERE id = v_m3), count(*) FILTER (WHERE id = v_m4),
         count(*) FILTER (WHERE id = v_twin), count(*) FILTER (WHERE id = v_mb)
    INTO v_n1, v_n2, v_n3, v_n4, v_nt, v_nb
    FROM public.stock_movements;
  EXECUTE 'RESET ROLE';
  IF v_n1 <> 1 OR v_n2 <> 1 OR v_n3 <> 1 OR v_n4 <> 1 THEN
    v_failures := v_failures || format('FAIL (b): el owner de A debía ver sus 4 movimientos nuevos en el historial (RLS), vio %s/%s/%s/%s',
                                       v_n1, v_n2, v_n3, v_n4);
  END IF;
  IF v_nt <> 0 THEN
    v_failures := v_failures || format('FAIL (b) control negativo: la fila gemela con account_id NULL NO debía verse bajo RLS (vio %s): el gate no estaría midiendo la RLS', v_nt);
  END IF;
  IF v_nb <> 0 THEN
    v_failures := v_failures || format('FAIL (b): el owner de A no debía ver el movimiento de la cuenta B (vio %s)', v_nb);
  END IF;

  PERFORM pg_temp.sab_as(v_owner_b);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) FILTER (WHERE id = v_mb),
         count(*) FILTER (WHERE id = ANY (ARRAY[v_m1, v_m2, v_m3, v_m4, v_twin]))
    INTO v_nb, v_na
    FROM public.stock_movements;
  EXECUTE 'RESET ROLE';
  IF v_nb <> 1 THEN
    v_failures := v_failures || format('FAIL (b): el owner de B debía ver su propio movimiento (RLS), vio %s', v_nb);
  END IF;
  IF v_na <> 0 THEN
    v_failures := v_failures || format('FAIL (b): el owner de B no debía ver ningún movimiento de la cuenta A (vio %s)', v_na);
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_f0 THEN
    RAISE NOTICE 'PASS (b): los movimientos nuevos se ven bajo RLS, la fila con account_id NULL (control negativo) no, y la otra cuenta no ve ninguno';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza (toda fila de las cuentas/usuarios del gate) y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.sab_as(NULL);
  SET session_replication_role = replica;
  -- Las filas con la forma del bug (account_id NULL) no las alcanza el barrido
  -- por account_id: se borran por usuario y por producto del gate.
  DELETE FROM public.stock_movements
   WHERE user_id = ANY (v_users) OR account_id = ANY (v_accounts)
      OR product_id IN (v_p1, v_p2, v_pb) OR id = v_twin;
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
  END LOOP;
  DELETE FROM public.accounts              WHERE id = ANY (v_accounts);
  DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
  DELETE FROM public.profiles              WHERE id = ANY (v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
  DELETE FROM auth.users                   WHERE id = ANY (v_users);
  SET session_replication_role = DEFAULT;

  IF EXISTS (SELECT 1 FROM public.stock_movements
              WHERE user_id = ANY (v_users) OR account_id = ANY (v_accounts)
                 OR product_id IN (v_p1, v_p2, v_pb) OR id = v_twin)
     OR EXISTS (SELECT 1 FROM public.branch_stock WHERE account_id = ANY (v_accounts)
                 OR product_id IN (v_p1, v_p2, v_pb))
     OR EXISTS (SELECT 1 FROM public.products WHERE id IN (v_p1, v_p2, v_pb))
     OR EXISTS (SELECT 1 FROM public.branches WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-ADJUSTMENT-ACCOUNT-BRANCH FAILED (% fallas):\n  %', array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (a)+(b): rpc_stock_adjustment sella account_id y branch_id (default operativa), los movimientos se ven bajo RLS y el control negativo (account_id NULL) no — residuo cero.';

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      EXECUTE 'RESET ROLE';
      SET session_replication_role = replica;
      IF v_users IS NOT NULL THEN
        DELETE FROM public.stock_movements WHERE user_id = ANY (v_users);
      END IF;
      IF v_accounts IS NOT NULL THEN
        DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
        FOR v_table IN
          SELECT c.table_name
          FROM   information_schema.columns c
          JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
          WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
            AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
        LOOP
          EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
        END LOOP;
        DELETE FROM public.accounts WHERE id = ANY (v_accounts);
      END IF;
      DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
      DELETE FROM public.profiles              WHERE id = ANY (v_users);
      DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
      DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
      DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
      DELETE FROM auth.users                   WHERE id = ANY (v_users);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    -- La falla acumulada del final del bloque pasa tal cual; sólo un error
    -- inesperado (SQL roto, setup) se rotula como "abortó".
    IF v_msg LIKE 'GATE STOCK-ADJUSTMENT-ACCOUNT-BRANCH FAILED (%' THEN
      RAISE EXCEPTION '%', v_msg;
    END IF;
    RAISE EXCEPTION 'GATE STOCK-ADJUSTMENT-ACCOUNT-BRANCH FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (c) ACL y forma de la RPC (sin fixtures) ────────────────────────────────
-- CREATE OR REPLACE conserva la ACL viva; un DROP FUNCTION + CREATE la resetea
-- y deja la RPC sin EXECUTE para authenticated (rompe el modal de /stock y su
-- importador). Este bloque es el candado contra eso.
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   constant text := 'public.rpc_stock_adjustment(uuid,numeric,text,text,text,uuid,numeric)';
  v_oid  oid := to_regprocedure(v_fn);
BEGIN
  IF v_oid IS NULL THEN
    v_bad := v_bad || format('%s no existe con la firma de 7 argumentos', v_fn);
  ELSE
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'authenticated NO tiene EXECUTE (¿un DROP FUNCTION reseteó la ACL?)';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'service_role NO tiene EXECUTE';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'anon tiene EXECUTE';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) a WHERE p.oid = v_oid AND a.grantee = 0) THEN
      v_bad := v_bad || 'PUBLIC tiene EXECUTE';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_bad := v_bad || 'ya no es SECURITY DEFINER';
    END IF;
    IF NOT COALESCE((SELECT 'search_path=public' = ANY (proconfig) OR 'search_path="public"' = ANY (proconfig)
                       FROM pg_proc WHERE oid = v_oid), false) THEN
      v_bad := v_bad || 'perdió su search_path fijo a public';
    END IF;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_stock_adjustment' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    v_bad := v_bad || 'rpc_stock_adjustment tiene un overload (o ninguna definición)';
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-ADJUSTMENT-ACCOUNT-BRANCH FAILED (c):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (c): rpc_stock_adjustment de 7 argumentos, un solo overload, SECURITY DEFINER con search_path fijo; EXECUTE para authenticated y service_role, sin anon ni PUBLIC.';
END $$;
