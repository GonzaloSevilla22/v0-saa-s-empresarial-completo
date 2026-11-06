-- =============================================================================
-- test_productos_padre_variantes.sql — Gate de comportamiento e introspección:
-- productos-padre-variantes, TANDA A (DB), migración
-- 20261093000001_productos_padre_variantes.sql.
--
-- Qué EJECUTA (nada se verifica sólo por existencia):
--   (A) product_round_price: la tabla de casos COMPARTIDA con el vitest de la
--       tanda B (supabase/tests/fixtures/product_round_price_cases.json, la
--       lee psql con \set + backtick: una sola fuente de verdad del redondeo).
--   (B) Padre sin precio/costo: 0 padres variant_only con precio/costo; el CHECK
--       products_variant_only_no_price_cost existe y está VALIDADO; un
--       `authenticated` que le pone precio o costo a un padre es rechazado por el
--       CHECK; la variante conserva su precio propio.
--   (C) Backfill auditado: se QUITA el CHECK dentro de la transacción, se arman
--       padres con precio/costo (uno borrado) y se REAPLICA el archivo de la
--       migración con \i — una fila product.parent_price_cleared por padre con
--       los valores anteriores, la línea de venta histórica intacta y una
--       segunda reaplicación sin filas nuevas (idempotencia).
--   (D) rpc_relabel_product_unit (D5/D6, tramo ALTO): relabel con historia sin
--       convertir nada, variantes con unidad propia pasan a heredar,
--       unit_relabel_conflict (y aceptado hacia la unidad de la línea), dry-run,
--       idempotencia, roles, tenencia, validaciones, auditoría, ACL, y el corte
--       del guard: el UPDATE directo como `authenticated` sigue dando P0409
--       base_unit_locked (también con el GUC apuntando a OTRA raíz y con
--       re-parent).
--   (E) rpc_bulk_adjust_prices (D8): redondeo, piso 0, expansión padre ->
--       variantes, normalización a raíz, sin cambio, tenencia, dry-run, rangos,
--       roles, auditoría, ACL.
--   (F) Introspección del cuerpo vivo del guard, ACLs y COMMENT de las tres
--       funciones nuevas.
--   (G) rpc_bulk_upsert_products: la rama Padre del importador nunca deja un
--       variant_only con precio/costo (D3, checkpoint 1.3).
--
-- Patrón: acumular fallos en una tabla temporal y UN solo RAISE EXCEPTION al
-- final; todo dentro de BEGIN … ROLLBACK (no deja residuo). Los usuarios nacen
-- por handle_new_user. Sesión simulada con set_config LOCAL — NUNCA contra prod.
-- Se corre desde la raíz del repo (el \i y el \set con backtick usan rutas
-- relativas): scripts/ci/run_gate_strict.py no cambia el cwd de psql.
-- =============================================================================

\set ON_ERROR_STOP on
\set round_cases `cat supabase/tests/fixtures/product_round_price_cases.json`

BEGIN;

SELECT set_config('gate.round_cases', :'round_cases', false);

CREATE TEMP TABLE gate_fails (msg text);
CREATE TEMP TABLE fx (k text PRIMARY KEY, v uuid);

CREATE FUNCTION pg_temp.fx(p_k text) RETURNS uuid LANGUAGE sql AS $f$ SELECT v FROM pg_temp.fx WHERE k = p_k $f$;

-- Registra un fallo si la condición no es VERDADERA (NULL cuenta como fallo).
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_msg text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN INSERT INTO gate_fails VALUES (p_msg); END IF;
END $f$;

-- Sesión de un usuario (claims). p_account = claim app_metadata.account_id.
CREATE FUNCTION pg_temp.as_user(p_user uuid, p_account uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v jsonb := jsonb_build_object('sub', p_user::text, 'role', 'authenticated');
BEGIN
  IF p_account IS NOT NULL THEN
    v := v || jsonb_build_object('app_metadata', jsonb_build_object('account_id', p_account::text));
  END IF;
  PERFORM set_config('request.jwt.claims', v::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;

-- Corre una sentencia o expresión como `authenticated`. NUNCA lanza.
--   p_sql = una sentencia (UPDATE/INSERT) cuando p_expr es false; una expresión
--   de RPC (se envuelve en SELECT to_jsonb(...)) cuando p_expr es true.
CREATE FUNCTION pg_temp.try_as_auth(p_sql text, p_expr boolean, OUT o_state text, OUT o_msg text, OUT o_constraint text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE authenticated';
  IF p_expr THEN
    EXECUTE format('SELECT to_jsonb(%s)', p_sql) INTO o_res;
  ELSE
    EXECUTE p_sql;
  END IF;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT, o_constraint = CONSTRAINT_NAME;
  o_res := NULL;
  RESET ROLE;
END $f$;

CREATE FUNCTION pg_temp.run_rpc(p_user uuid, p_account uuid, p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account);
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try_as_auth(p_expr, true) t;
END $f$;

CREATE FUNCTION pg_temp.run_stmt(p_user uuid, p_account uuid, p_sql text, OUT o_state text, OUT o_msg text, OUT o_constraint text)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account);
  SELECT t.o_state, t.o_msg, t.o_constraint INTO o_state, o_msg, o_constraint FROM pg_temp.try_as_auth(p_sql, false) t;
END $f$;

-- ── Fixtures ────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_ow uuid := gen_random_uuid();   -- dueño de A
  v_ad uuid := gen_random_uuid();   -- administrador de A
  v_st uuid := gen_random_uuid();   -- depósito (rol stock) de A
  v_ca uuid := gen_random_uuid();   -- cajero de A
  v_ob uuid := gen_random_uuid();   -- dueño de B (otra cuenta)
  v_a uuid;  v_b uuid;  v_member uuid;  v_uid uuid;  v_role text;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_ow, 'authenticated', 'authenticated', 'ppv-owner@test.local',   now(), now(), '{"name":"PPV Dueno"}'::jsonb),
    (v_ad, 'authenticated', 'authenticated', 'ppv-admin@test.local',   now(), now(), '{"name":"PPV Admin"}'::jsonb),
    (v_st, 'authenticated', 'authenticated', 'ppv-stock@test.local',   now(), now(), '{"name":"PPV Stock"}'::jsonb),
    (v_ca, 'authenticated', 'authenticated', 'ppv-cashier@test.local', now(), now(), '{"name":"PPV Cajero"}'::jsonb),
    (v_ob, 'authenticated', 'authenticated', 'ppv-ownerb@test.local',  now(), now(), '{"name":"PPV Dueno B"}'::jsonb);
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_ow;
  SELECT account_id INTO v_b FROM public.account_members WHERE user_id = v_ob;
  IF v_a IS NULL OR v_b IS NULL THEN
    RAISE EXCEPTION 'GATE PPV (fixture): handle_new_user no creó la cuenta (a=%, b=%)', v_a, v_b;
  END IF;
  FOR v_uid, v_role IN VALUES (v_ad, 'admin'), (v_st, 'stock'), (v_ca, 'cashier') LOOP
    INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_a, v_uid, 'member') RETURNING id INTO v_member;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_member, v_role);
  END LOOP;
  INSERT INTO fx VALUES ('ow', v_ow), ('ad', v_ad), ('st', v_st), ('ca', v_ca), ('ob', v_ob), ('a', v_a), ('b', v_b),
                        ('br_a', public.c26_default_branch(v_a)), ('br_b', public.c26_default_branch(v_b));
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (A) product_round_price contra la tabla compartida
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_case jsonb;
  v_got  numeric;
  v_n    integer := 0;
BEGIN
  IF to_regprocedure('public.product_round_price(numeric)') IS NULL THEN
    PERFORM pg_temp.chk(false, '(A) falta public.product_round_price(numeric)');
    RETURN;
  END IF;
  FOR v_case IN SELECT * FROM jsonb_array_elements(current_setting('gate.round_cases')::jsonb) LOOP
    v_n := v_n + 1;
    v_got := public.product_round_price((v_case->>'input')::numeric);
    PERFORM pg_temp.chk(v_got = (v_case->>'expected')::numeric,
      format('(A) product_round_price(%s) = %s, esperado %s', v_case->>'input', v_got, v_case->>'expected'));
  END LOOP;
  PERFORM pg_temp.chk(v_n >= 10, format('(A) la tabla compartida trae %s casos (esperado >= 10)', v_n));
  PERFORM pg_temp.chk((SELECT provolatile = 'i' FROM pg_proc WHERE oid = 'public.product_round_price(numeric)'::regprocedure),
    '(A) product_round_price debe ser IMMUTABLE');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (B) Padre sin precio/costo: estado, CHECK y escritor directo
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_ow uuid := pg_temp.fx('ow');
  v_parent uuid;  v_child uuid;  v_r record;  v_validated boolean;
BEGIN
  PERFORM pg_temp.chk((SELECT count(*) FROM public.products
                        WHERE stock_control_type = 'variant_only' AND (price IS DISTINCT FROM 0 OR cost IS NOT NULL)) = 0,
    '(B) quedan padres variant_only con precio o costo');

  SELECT convalidated INTO v_validated FROM pg_constraint
   WHERE conrelid = 'public.products'::regclass AND conname = 'products_variant_only_no_price_cost';
  PERFORM pg_temp.chk(v_validated IS TRUE, '(B) el CHECK products_variant_only_no_price_cost no existe o no está validado');
  PERFORM pg_temp.chk((SELECT pg_get_constraintdef(oid) ILIKE '%variant_only%price%cost IS NULL%' FROM pg_constraint
                        WHERE conrelid = 'public.products'::regclass AND conname = 'products_variant_only_no_price_cost'),
    '(B) la definición del CHECK no es (variant_only -> price = 0 AND cost IS NULL)');

  -- Padre sano (price 0, cost NULL) + variante con precio propio.
  INSERT INTO public.products (user_id, account_id, name, price, cost, stock_control_type)
  VALUES (v_ow, v_a, 'PPV Padre B', 0, NULL, 'variant_only') RETURNING id INTO v_parent;
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant)
  VALUES (v_ow, v_a, 'PPV Variante B', 1200, 700, v_parent, true) RETURNING id INTO v_child;
  INSERT INTO fx VALUES ('parent_b', v_parent), ('child_b', v_child);

  -- Escritor directo (PostgREST) con precio -> el CHECK lo frena.
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format('UPDATE public.products SET price = 100 WHERE id = %L', v_parent));
  PERFORM pg_temp.chk(v_r.o_state = '23514' AND v_r.o_constraint = 'products_variant_only_no_price_cost',
    format('(B) UPDATE de precio a un padre como authenticated: esperado 23514/products_variant_only_no_price_cost, got %s/%s', v_r.o_state, v_r.o_constraint));
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format('UPDATE public.products SET cost = 5 WHERE id = %L', v_parent));
  PERFORM pg_temp.chk(v_r.o_state = '23514', format('(B) UPDATE de costo a un padre: esperado 23514, got %s', v_r.o_state));
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format(
    $q$INSERT INTO public.products (user_id, account_id, name, price, stock_control_type) VALUES (%L, %L, 'PPV Padre con precio', 10, 'variant_only')$q$, v_ow, v_a));
  PERFORM pg_temp.chk(v_r.o_state = '23514', format('(B) INSERT de un padre con precio: esperado 23514, got %s', v_r.o_state));

  -- El neutro sí se acepta y la variante conserva su precio propio.
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format('UPDATE public.products SET name = ''PPV Padre B2'', price = 0, cost = NULL WHERE id = %L', v_parent));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(B) UPDATE neutro de un padre debía pasar; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = v_child) = 1200
                      AND (SELECT cost FROM public.products WHERE id = v_child) = 700,
    '(B) la variante perdió su precio/costo propio (no hay herencia)');
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = v_parent) = 0, '(B) el padre quedó con precio');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (C) Backfill auditado: se quita el CHECK, se arma el estado viejo y se
--     REAPLICA el archivo de la migración
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_variant_only_no_price_cost;

DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_ow uuid := pg_temp.fx('ow');
  v_p1 uuid;  v_p2 uuid;  v_p3 uuid;  v_c1 uuid;  v_sale uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, price, cost, stock_control_type)
  VALUES (v_ow, v_a, 'PPV Padre viejo 1', 1500, 800, 'variant_only') RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, price, cost, stock_control_type)
  VALUES (v_ow, v_a, 'PPV Padre viejo 2 (sólo costo)', 0, 50, 'variant_only') RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, price, cost, stock_control_type, deleted_at)
  VALUES (v_ow, v_a, 'PPV Padre viejo 3 (borrado)', 99, NULL, 'variant_only', now()) RETURNING id INTO v_p3;
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant)
  VALUES (v_ow, v_a, 'PPV Hija del viejo 1', 1800, 900, v_p1, true) RETURNING id INTO v_c1;
  -- Línea de venta histórica del padre: la migración NO la reescribe.
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity) VALUES (v_ow, v_a, v_p1, 1500, 1) RETURNING id INTO v_sale;
  INSERT INTO fx VALUES ('old1', v_p1), ('old2', v_p2), ('old3', v_p3), ('old_child', v_c1), ('old_sale', v_sale);
END $$;

\i supabase/migrations/20261093000001_productos_padre_variantes.sql

DO $$
DECLARE
  v_p1 uuid := pg_temp.fx('old1');  v_p2 uuid := pg_temp.fx('old2');  v_p3 uuid := pg_temp.fx('old3');
  v_n1 integer;  v_meta jsonb;  v_total_before integer;  v_total_after integer;  v_validated boolean;
BEGIN
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL FROM public.products WHERE id = v_p1), '(C) el padre 1 no quedó en price 0 / cost NULL');
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL FROM public.products WHERE id = v_p2), '(C) el padre 2 (sólo costo) no se limpió');
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL FROM public.products WHERE id = v_p3), '(C) el padre BORRADO no se limpió (el CHECK no valida sin él)');
  SELECT convalidated INTO v_validated FROM pg_constraint WHERE conrelid = 'public.products'::regclass AND conname = 'products_variant_only_no_price_cost';
  PERFORM pg_temp.chk(v_validated IS TRUE, '(C) tras la reaplicación el CHECK no está validado');

  -- Una fila de auditoría por padre limpiado, con los valores anteriores.
  SELECT count(*) INTO v_n1 FROM public.audit_logs WHERE action = 'product.parent_price_cleared' AND entity_id IN (v_p1, v_p2, v_p3);
  PERFORM pg_temp.chk(v_n1 = 3, format('(C) filas product.parent_price_cleared de los 3 padres: %s (esperado 3)', v_n1));
  SELECT metadata INTO v_meta FROM public.audit_logs WHERE action = 'product.parent_price_cleared' AND entity_id = v_p1;
  PERFORM pg_temp.chk((v_meta->>'price_before')::numeric = 1500 AND (v_meta->>'cost_before')::numeric = 800,
    format('(C) metadata del padre 1 sin los valores anteriores: %s', v_meta));
  PERFORM pg_temp.chk((SELECT user_id IS NULL AND account_id = pg_temp.fx('a') AND entity_type = 'product'
                         FROM public.audit_logs WHERE action = 'product.parent_price_cleared' AND entity_id = v_p1),
    '(C) la auditoría del backfill debe llevar la cuenta, entity_type product y user_id NULL (migración)');

  -- Las variantes y la línea de venta histórica no se tocan.
  PERFORM pg_temp.chk((SELECT price = 1800 AND cost = 900 FROM public.products WHERE id = pg_temp.fx('old_child')),
    '(C) la hija del padre viejo perdió su precio/costo');
  PERFORM pg_temp.chk((SELECT amount = 1500 FROM public.sales WHERE id = pg_temp.fx('old_sale')),
    '(C) la línea de venta histórica del padre fue reescrita');

  -- Idempotencia: reaplicar de nuevo no agrega filas de auditoría.
  SELECT count(*) INTO v_total_before FROM public.audit_logs WHERE action = 'product.parent_price_cleared';
  PERFORM set_config('gate.audit_before', v_total_before::text, false);
END $$;

\i supabase/migrations/20261093000001_productos_padre_variantes.sql

DO $$
DECLARE
  v_before integer := current_setting('gate.audit_before')::integer;
  v_after  integer;
BEGIN
  SELECT count(*) INTO v_after FROM public.audit_logs WHERE action = 'product.parent_price_cleared';
  PERFORM pg_temp.chk(v_after = v_before, format('(C) la segunda reaplicación agregó auditoría: %s -> %s', v_before, v_after));
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.products'::regclass AND conname = 'products_variant_only_no_price_cost'),
    '(C) la reaplicación debe dejar el CHECK');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (D) rpc_relabel_product_unit + corte del guard (D5/D6, tramo ALTO)
-- ═══════════════════════════════════════════════════════════════════════════
-- Fixtures: unidades de la cuenta A (kg base, g -> kg, u base) y una unidad de B.
DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_b uuid := pg_temp.fx('b');  v_ow uuid := pg_temp.fx('ow');  v_ob uuid := pg_temp.fx('ob');
  v_br uuid := pg_temp.fx('br_a');
  v_kg uuid;  v_g uuid;  v_u uuid;  v_ub uuid;
  v_p uuid;  v_v uuid;
BEGIN
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) VALUES (v_a, 'Kilogramo PPV', 'kg', 'weight', 1.0, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system) VALUES (v_a, 'Gramo PPV', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) VALUES (v_a, 'Unidad PPV', 'u', 'unit', 1.0, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) VALUES (v_b, 'Kilogramo B PPV', 'kg', 'weight', 1.0, false) RETURNING id INTO v_ub;
  INSERT INTO fx VALUES ('kg', v_kg), ('g', v_g), ('u', v_u), ('ub', v_ub);

  -- F1: padre sin unidad con tres variantes: V1a con stock 12 y movimiento (hereda), V1b con unidad propia kg, V1c con propia u.
  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV F1 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('f1_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV F1 a', 10, 5, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f1_a', v_v);
  PERFORM public.op_stock_movement(v_a, v_ow, v_v, 'PPV F1 a', v_br, 12, 'adjustment', NULL, NULL, NULL, NULL, 'gate', NULL);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant, base_unit_id) VALUES (v_ow, v_a, 'PPV F1 b', 10, 5, v_p, true, v_kg) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f1_b', v_v);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant, base_unit_id) VALUES (v_ow, v_a, 'PPV F1 c', 10, 5, v_p, true, v_u) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f1_c', v_v);

  -- F3: padre + variante con stock 5 y una venta grabada en gramos (conflicto hacia cualquier otra unidad).
  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV F3 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('f3_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV F3 a', 10, 5, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f3_a', v_v);
  PERFORM public.op_stock_movement(v_a, v_ow, v_v, 'PPV F3 a', v_br, 5, 'adjustment', NULL, NULL, NULL, NULL, 'gate', NULL);
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, unit_id) VALUES (v_ow, v_a, v_v, 100, 1, v_g);

  -- F4 (dry-run), F5 (idempotencia + normalización desde una variante), F6 (roles), F7 (producto simple con stock).
  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV F4 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('f4_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV F4 a', 10, 5, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f4_a', v_v);
  PERFORM public.op_stock_movement(v_a, v_ow, v_v, 'PPV F4 a', v_br, 7, 'adjustment', NULL, NULL, NULL, NULL, 'gate', NULL);

  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV F5 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('f5_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV F5 a', 10, 5, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('f5_a', v_v);

  INSERT INTO public.products (user_id, account_id, name, stock_control_type, base_unit_id) VALUES (v_ow, v_a, 'PPV F7 simple kg', 'tracked', v_kg) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('f7', v_p);
  PERFORM public.op_stock_movement(v_a, v_ow, v_p, 'PPV F7', v_br, 3, 'adjustment', NULL, NULL, NULL, NULL, 'gate', NULL);
END $$;

DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_b uuid := pg_temp.fx('b');
  v_ow uuid := pg_temp.fx('ow');  v_ad uuid := pg_temp.fx('ad');  v_st uuid := pg_temp.fx('st');  v_ca uuid := pg_temp.fx('ca');  v_ob uuid := pg_temp.fx('ob');
  v_kg uuid := pg_temp.fx('kg');  v_g uuid := pg_temp.fx('g');  v_u uuid := pg_temp.fx('u');  v_ub uuid := pg_temp.fx('ub');
  v_r record;  v_res jsonb;  v_n1 integer;  v_n2 integer;  v_audit integer;  v_meta jsonb;
  v_stock_before numeric;  v_mov_before integer;
  v_ghost uuid := gen_random_uuid();
BEGIN
  IF to_regprocedure('public.rpc_relabel_product_unit(uuid,uuid,boolean)') IS NULL THEN
    PERFORM pg_temp.chk(false, '(D) falta public.rpc_relabel_product_unit(uuid, uuid, boolean)');
    RETURN;
  END IF;

  -- ── D1: relabel con historia (F1) ─────────────────────────────────────────
  SELECT coalesce(sum(quantity), 0) INTO v_stock_before FROM public.branch_stock WHERE product_id = pg_temp.fx('f1_a');
  SELECT count(*) INTO v_mov_before FROM public.stock_movements WHERE product_id = pg_temp.fx('f1_a');
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f1_p'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(D1) relabel con historia: %s %s', v_r.o_state, v_r.o_msg));
  v_res := v_r.o_res;
  PERFORM pg_temp.chk((v_res->>'changed')::boolean IS TRUE, format('(D1) changed debía ser true: %s', v_res));
  PERFORM pg_temp.chk((v_res->>'root_id')::uuid = pg_temp.fx('f1_p'), '(D1) root_id');
  PERFORM pg_temp.chk((v_res->>'unit_before') IS NULL AND (v_res->>'unit_after')::uuid = v_kg, format('(D1) unit_before/unit_after: %s', v_res));
  PERFORM pg_temp.chk((v_res->>'variants')::int = 3 AND (v_res->>'variants_with_own_unit')::int = 2, format('(D1) variants/variants_with_own_unit: %s', v_res));
  PERFORM pg_temp.chk((v_res->>'products_with_stock')::int = 1 AND (v_res->>'movements')::int = 1, format('(D1) products_with_stock/movements: %s', v_res));
  PERFORM pg_temp.chk((v_res->>'conflict_unit') IS NULL, '(D1) conflict_unit debía ser null');
  PERFORM pg_temp.chk((SELECT base_unit_id = v_kg FROM public.products WHERE id = pg_temp.fx('f1_p')), '(D1) la raíz no quedó en kg');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.products WHERE parent_id = pg_temp.fx('f1_p') AND base_unit_id IS NULL) = 3,
    '(D1) las tres variantes (también las que tenían unidad propia) deben quedar heredando');
  PERFORM pg_temp.chk((SELECT coalesce(sum(quantity), 0) FROM public.branch_stock WHERE product_id = pg_temp.fx('f1_a')) = v_stock_before,
    '(D1) el stock cambió: el relabel no convierte cantidades');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.stock_movements WHERE product_id = pg_temp.fx('f1_a')) = v_mov_before,
    '(D1) cambió la cantidad de movimientos');
  PERFORM pg_temp.chk((SELECT base_unit_id FROM public.v_products_with_stock WHERE id = pg_temp.fx('f1_a')) = v_kg,
    '(D1) la unidad efectiva de la variante en la vista no es kg');
  SELECT metadata INTO v_meta FROM public.audit_logs WHERE action = 'product.unit_relabel' AND entity_id = pg_temp.fx('f1_p');
  PERFORM pg_temp.chk(v_meta IS NOT NULL AND (v_meta->>'unit_after')::uuid = v_kg AND (v_meta->>'variants')::int = 3
                      AND (v_meta->>'products_with_stock')::int = 1 AND (v_meta->>'movements')::int = 1
                      AND jsonb_array_length(v_meta->'variants_with_own_unit_before') = 2,
    format('(D1) auditoría product.unit_relabel incompleta: %s', v_meta));
  PERFORM pg_temp.chk((SELECT user_id = v_ow AND account_id = v_a AND entity_type = 'product' FROM public.audit_logs
                        WHERE action = 'product.unit_relabel' AND entity_id = pg_temp.fx('f1_p')),
    '(D1) la auditoría debe llevar el usuario, la cuenta y entity_type product');

  -- ── D1b: el GUC no queda abierto — un UPDATE directo posterior vuelve a dar P0409 ──
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format('UPDATE public.products SET base_unit_id = %L WHERE id = %L', v_g, pg_temp.fx('f1_p')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409' AND v_r.o_msg LIKE 'base_unit_locked%',
    format('(D1b) el UPDATE directo tras el relabel debía dar P0409 base_unit_locked; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk(coalesce(current_setting('products.unit_relabel_root', true), '') = '', '(D1b) el GUC del relabel quedó seteado');

  -- ── D2: una línea grabada en otra unidad impide el relabel (F3) ───────────
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f3_p'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409' AND v_r.o_msg LIKE 'unit_relabel_conflict%', format('(D2) relabel hacia kg con una línea en g: esperado P0409 unit_relabel_conflict; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT base_unit_id IS NULL FROM public.products WHERE id = pg_temp.fx('f3_p')), '(D2) el conflicto escribió igual');
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, true)', pg_temp.fx('f3_p'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'conflict_unit')::uuid = v_g, format('(D2) el dry-run debía informar conflict_unit = g sin lanzar; got %s %s', v_r.o_state, v_r.o_res));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f3_p'), v_g));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::boolean IS TRUE, format('(D2) relabel hacia la unidad de la línea (g) debía aceptarse; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT base_unit_id = v_g FROM public.products WHERE id = pg_temp.fx('f3_p')), '(D2) la raíz no quedó en g');

  -- ── D3: dry-run sin escritura ni auditoría (F4) ───────────────────────────
  SELECT count(*) INTO v_audit FROM public.audit_logs WHERE action = 'product.unit_relabel';
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, true)', pg_temp.fx('f4_p'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::boolean IS TRUE AND (v_r.o_res->>'products_with_stock')::int = 1
                      AND (v_r.o_res->>'movements')::int = 1 AND (v_r.o_res->>'variants')::int = 1,
    format('(D3) resultado del dry-run: %s %s', v_r.o_state, v_r.o_res));
  PERFORM pg_temp.chk((SELECT base_unit_id IS NULL FROM public.products WHERE id = pg_temp.fx('f4_p')), '(D3) el dry-run escribió la unidad');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.audit_logs WHERE action = 'product.unit_relabel') = v_audit, '(D3) el dry-run escribió auditoría');

  -- ── D4: idempotencia (F5) y normalización desde una variante ──────────────
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f5_a'), v_u));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::boolean IS TRUE AND (v_r.o_res->>'root_id')::uuid = pg_temp.fx('f5_p'),
    format('(D4) relabel desde el id de una variante debía normalizar a la raíz; got %s %s', v_r.o_state, v_r.o_res));
  SELECT count(*) INTO v_audit FROM public.audit_logs WHERE action = 'product.unit_relabel';
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f5_p'), v_u));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::boolean IS FALSE, format('(D4) el segundo relabel idéntico debía dar changed=false; got %s %s', v_r.o_state, v_r.o_res));
  PERFORM pg_temp.chk((SELECT count(*) FROM public.audit_logs WHERE action = 'product.unit_relabel') = v_audit, '(D4) el relabel sin efecto escribió auditoría');

  -- ── D5: roles ─────────────────────────────────────────────────────────────
  -- admin SÍ; depósito y cajero NO (P0403 insufficient_role); dueño de otra cuenta -> P0404.
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_st, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f7'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = 'P0403' AND v_r.o_msg LIKE 'insufficient_role%', format('(D5) depósito: esperado P0403 insufficient_role; got %s %s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ca, v_a, format('public.rpc_relabel_product_unit(%L, %L, true)', pg_temp.fx('f7'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = 'P0403', format('(D5) cajero (también en dry-run): esperado P0403; got %s', v_r.o_state));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ad, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f7'), v_kg));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::boolean IS FALSE, format('(D5) admin sobre un simple que ya está en kg: changed=false; got %s %s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ob, v_b, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f7'), v_ub));
  PERFORM pg_temp.chk(v_r.o_state = 'P0404' AND v_r.o_msg LIKE 'product_not_found%', format('(D5) producto de otra cuenta: esperado P0404 product_not_found; got %s %s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', v_ghost, v_kg));
  PERFORM pg_temp.chk(v_r.o_state = 'P0404' AND v_r.o_msg LIKE 'product_not_found%', format('(D5) producto inexistente: esperado el MISMO P0404; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT base_unit_id = v_kg FROM public.products WHERE id = pg_temp.fx('f7')), '(D5) el producto ajeno/rechazado cambió');

  -- ── D6: validaciones ──────────────────────────────────────────────────────
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, NULL, false)', pg_temp.fx('f4_p')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0400' AND v_r.o_msg LIKE 'unit_required%', format('(D6) sin unidad: esperado P0400 unit_required; got %s %s', v_r.o_state, v_r.o_msg));
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_relabel_product_unit(%L, %L, false)', pg_temp.fx('f4_p'), v_ub));
  PERFORM pg_temp.chk(v_r.o_state = 'P0404' AND v_r.o_msg LIKE 'base_unit_not_found%', format('(D6) unidad de otra cuenta: esperado P0404 base_unit_not_found; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT base_unit_id IS NULL FROM public.products WHERE id = pg_temp.fx('f4_p')), '(D6) una validación fallida escribió');

  -- ── D7: el corte del guard no abre el camino ordinario ────────────────────
  -- Familia con unidad (F1, ya corregida a kg) y stock 12 en una variante: UPDATE directo -> P0409.
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format('UPDATE public.products SET base_unit_id = %L WHERE id = %L', v_u, pg_temp.fx('f1_p')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409' AND v_r.o_msg LIKE 'base_unit_locked%', format('(D7) UPDATE directo de la unidad del padre con stock en una variante: P0409; got %s %s', v_r.o_state, v_r.o_msg));
  -- con el GUC apuntando a OTRA raíz (la de F5), sigue P0409 (el corte está atado a la raíz).
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format(
    'SELECT set_config(''products.unit_relabel_root'', %L, true); UPDATE public.products SET base_unit_id = %L WHERE id = %L',
    pg_temp.fx('f5_p'), v_u, pg_temp.fx('f1_p')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409', format('(D7) con el GUC apuntando a otra raíz: P0409; got %s %s', v_r.o_state, v_r.o_msg));
  -- re-parent de la variante con stock (hereda kg) a un padre en g (F3), con el GUC apuntando al padre nuevo: P0409.
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format(
    'SELECT set_config(''products.unit_relabel_root'', %L, true); UPDATE public.products SET parent_id = %L WHERE id = %L',
    pg_temp.fx('f3_p'), pg_temp.fx('f3_p'), pg_temp.fx('f1_a')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409', format('(D7) re-parent con el GUC apuntando al padre nuevo: P0409; got %s %s', v_r.o_state, v_r.o_msg));
  -- desenganchar la variante con stock (parent_id NULL) con el GUC de su raíz: P0409.
  SELECT * INTO v_r FROM pg_temp.run_stmt(v_ow, v_a, format(
    'SELECT set_config(''products.unit_relabel_root'', %L, true); UPDATE public.products SET parent_id = NULL WHERE id = %L',
    pg_temp.fx('f1_p'), pg_temp.fx('f1_a')));
  PERFORM pg_temp.chk(v_r.o_state = 'P0409', format('(D7) desenganchar una variante con stock con el GUC de su raíz: P0409; got %s %s', v_r.o_state, v_r.o_msg));
  RESET ROLE;
  PERFORM set_config('products.unit_relabel_root', '', true);

  -- ── D8: ACL ───────────────────────────────────────────────────────────────
  PERFORM pg_temp.chk(NOT has_function_privilege('anon', 'public.rpc_relabel_product_unit(uuid,uuid,boolean)', 'EXECUTE'), '(D8) anon tiene EXECUTE sobre rpc_relabel_product_unit');
  PERFORM pg_temp.chk(has_function_privilege('authenticated', 'public.rpc_relabel_product_unit(uuid,uuid,boolean)', 'EXECUTE'), '(D8) authenticated no tiene EXECUTE sobre rpc_relabel_product_unit');
  PERFORM pg_temp.chk((SELECT count(*) FROM pg_proc WHERE proname = 'rpc_relabel_product_unit') = 1, '(D8) rpc_relabel_product_unit debe tener UNA sola firma');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (E) rpc_bulk_adjust_prices (D8)
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_b uuid := pg_temp.fx('b');  v_ow uuid := pg_temp.fx('ow');  v_ob uuid := pg_temp.fx('ob');
  v_p uuid;  v_v uuid;
BEGIN
  -- E1 / E2: productos simples.
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, 'PPV E1 uno', 1000, 600) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e1_a', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, 'PPV E1 dos', 2345, 1000) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e1_b', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, 'PPV E2 barato', 300, 100) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e2_a', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, 'PPV E2 caro', 1000, 100) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e2_b', v_p);
  -- E3: padre con dos variantes de 1000.
  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV E3 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e3_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV E3 v1', 1000, 500, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('e3_v1', v_v);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV E3 v2', 1000, 500, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('e3_v2', v_v);
  -- E4: otra familia, se selecciona UNA variante suelta.
  INSERT INTO public.products (user_id, account_id, name, stock_control_type) VALUES (v_ow, v_a, 'PPV E4 padre', 'variant_only') RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e4_p', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV E4 v1', 200, 100, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('e4_v1', v_v);
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant) VALUES (v_ow, v_a, 'PPV E4 v2', 400, 100, v_p, true) RETURNING id INTO v_v;
  INSERT INTO fx VALUES ('e4_v2', v_v);
  -- E5: un precio 0 (queda igual), un producto borrado, un producto de la cuenta B.
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, 'PPV E5 gratis', 0, NULL) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e5_zero', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost, deleted_at) VALUES (v_ow, v_a, 'PPV E5 borrado', 700, 300, now()) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e5_del', v_p);
  INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ob, v_b, 'PPV E5 de B', 5000, 2000) RETURNING id INTO v_p;
  INSERT INTO fx VALUES ('e5_b', v_p);
  -- E6: 12 productos para la muestra de hasta 10.
  FOR i IN 1..12 LOOP
    INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES (v_ow, v_a, format('PPV E6 %s', lpad(i::text, 2, '0')), 100 * i, 50) RETURNING id INTO v_p;
    INSERT INTO fx VALUES (format('e6_%s', i), v_p);
  END LOOP;
END $$;

DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_b uuid := pg_temp.fx('b');
  v_ow uuid := pg_temp.fx('ow');  v_ad uuid := pg_temp.fx('ad');  v_st uuid := pg_temp.fx('st');  v_ca uuid := pg_temp.fx('ca');  v_ob uuid := pg_temp.fx('ob');
  v_r record;  v_x record;  v_res jsonb;  v_audit integer;  v_meta jsonb;  v_ids text;  v_ghost uuid := gen_random_uuid();
  v_e6 text;
BEGIN
  IF to_regprocedure('public.rpc_bulk_adjust_prices(uuid[],text,text,numeric,boolean)') IS NULL THEN
    PERFORM pg_temp.chk(false, '(E) falta public.rpc_bulk_adjust_prices(uuid[], text, text, numeric, boolean)');
    RETURN;
  END IF;

  -- ── E1: aumento por porcentaje con redondeo; el costo NO cambia ───────────
  v_ids := format('%L::uuid[]', ARRAY[pg_temp.fx('e1_a'), pg_temp.fx('e1_b')]::text);
  SELECT count(*) INTO v_audit FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted';
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 10, false)', v_ids));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(E1) aumento del 10%%: %s %s', v_r.o_state, v_r.o_msg));
  v_res := v_r.o_res;
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e1_a')) = 1100, '(E1) 1000 +10% debía ser 1100');
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e1_b')) = 2580, '(E1) 2345 +10% debía ser 2580 (2579,5 redondea hacia afuera)');
  PERFORM pg_temp.chk((SELECT cost FROM public.products WHERE id = pg_temp.fx('e1_a')) = 600 AND (SELECT cost FROM public.products WHERE id = pg_temp.fx('e1_b')) = 1000,
    '(E1) el costo no puede cambiar por esta vía');
  PERFORM pg_temp.chk((v_res->>'requested')::int = 2 AND (v_res->>'eligible')::int = 2 AND (v_res->>'changed')::int = 2
                      AND (v_res->>'unchanged')::int = 0 AND (v_res->>'skipped_parents')::int = 0 AND (v_res->>'clamped')::int = 0,
    format('(E1) contadores: %s', v_res));
  PERFORM pg_temp.chk(jsonb_array_length(v_res->'sample') = 2, format('(E1) muestra: %s', v_res->'sample'));
  PERFORM pg_temp.chk((SELECT bool_or((e->>'price_before')::numeric = 1000 AND (e->>'price_after')::numeric = 1100 AND e->>'name' = 'PPV E1 uno')
                         FROM jsonb_array_elements(v_res->'sample') e),
    format('(E1) la muestra debe traer precio anterior y nuevo: %s', v_res->'sample'));
  PERFORM pg_temp.chk(v_res->'sample'->0->>'name' < v_res->'sample'->1->>'name', '(E1) la muestra va ordenada por nombre');
  SELECT metadata INTO v_meta FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted' AND entity_id IS NULL
     AND (metadata->>'mode') = 'percent' AND (metadata->>'value')::numeric = 10 AND (metadata->>'changed')::int = 2
   ORDER BY created_at DESC LIMIT 1;
  PERFORM pg_temp.chk(v_meta IS NOT NULL AND v_meta->>'direction' = 'increase' AND (v_meta->>'clamped')::int = 0 AND jsonb_array_length(v_meta->'product_ids') = 2,
    format('(E1) auditoría product.bulk_price_adjusted incompleta: %s', v_meta));
  PERFORM pg_temp.chk((SELECT user_id = v_ow AND account_id = v_a FROM public.audit_logs
                        WHERE action = 'product.bulk_price_adjusted' AND (metadata->>'mode') = 'percent' AND (metadata->>'value')::numeric = 10 ORDER BY created_at DESC LIMIT 1),
    '(E1) la auditoría debe llevar el usuario y la cuenta');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted') = v_audit + 1, '(E1) una sola fila de auditoría por llamada');

  -- ── E2: baja por importe con piso 0 y clamped ─────────────────────────────
  v_ids := format('%L::uuid[]', ARRAY[pg_temp.fx('e2_a'), pg_temp.fx('e2_b')]::text);
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ad, v_a, format('public.rpc_bulk_adjust_prices(%s, ''amount'', ''decrease'', 500, false)', v_ids));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(E2) baja por importe (administrador): %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e2_a')) = 0 AND (SELECT price FROM public.products WHERE id = pg_temp.fx('e2_b')) = 500,
    '(E2) 300-500 debía acotarse a 0 y 1000-500 = 500');
  PERFORM pg_temp.chk((v_r.o_res->>'clamped')::int = 1 AND (v_r.o_res->>'changed')::int = 2, format('(E2) clamped/changed: %s', v_r.o_res));
  -- el mismo importe sobre lo que ya está en 0: queda igual y NO cuenta como acotado.
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ad, v_a, format('public.rpc_bulk_adjust_prices(%L::uuid[], ''amount'', ''decrease'', 500, false)', ARRAY[pg_temp.fx('e2_a')]::text));
  PERFORM pg_temp.chk((v_r.o_res->>'changed')::int = 0 AND (v_r.o_res->>'unchanged')::int = 1 AND (v_r.o_res->>'clamped')::int = 0,
    format('(E2) bajar lo que ya vale 0: sin cambio ni acotado; got %s', v_r.o_res));
  -- aumento por importe fijo
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%L::uuid[], ''amount'', ''increase'', 49.6, false)', ARRAY[pg_temp.fx('e2_b')]::text));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e2_b')) = 550, format('(E2) 500 + 49,6 redondea a 550; got %s', (SELECT price FROM public.products WHERE id = pg_temp.fx('e2_b'))));

  -- ── E3: un padre seleccionado se expande a sus variantes ──────────────────
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%L::uuid[], ''percent'', ''increase'', 20, false)', ARRAY[pg_temp.fx('e3_p')]::text));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(E3) %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e3_v1')) = 1200 AND (SELECT price FROM public.products WHERE id = pg_temp.fx('e3_v2')) = 1200,
    '(E3) las dos variantes debían quedar en 1200');
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL FROM public.products WHERE id = pg_temp.fx('e3_p')), '(E3) el padre debe seguir en 0 / sin costo');
  PERFORM pg_temp.chk((v_r.o_res->>'requested')::int = 1 AND (v_r.o_res->>'eligible')::int = 2 AND (v_r.o_res->>'skipped_parents')::int = 1 AND (v_r.o_res->>'changed')::int = 2,
    format('(E3) contadores del padre expandido: %s', v_r.o_res));

  -- ── E4: una variante suelta se normaliza a su raíz ────────────────────────
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%L::uuid[], ''percent'', ''decrease'', 50, false)', ARRAY[pg_temp.fx('e4_v1')]::text));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e4_v1')) = 100 AND (SELECT price FROM public.products WHERE id = pg_temp.fx('e4_v2')) = 200,
    '(E4) seleccionar UNA variante debía ajustar toda la familia (100 y 200)');

  -- ── E5: sin cambio, borrado, otra cuenta, duplicados ──────────────────────
  v_ids := format('%L::uuid[]', ARRAY[pg_temp.fx('e5_zero'), pg_temp.fx('e5_del'), pg_temp.fx('e5_b'), v_ghost, pg_temp.fx('e5_zero')]::text);
  SELECT count(*) INTO v_audit FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted';
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 10, false)', v_ids));
  PERFORM pg_temp.chk(v_r.o_state = '00000', format('(E5) ids ajenos/borrados/fantasma no deben dar error; got %s %s', v_r.o_state, v_r.o_msg));
  PERFORM pg_temp.chk((v_r.o_res->>'requested')::int = 4 AND (v_r.o_res->>'eligible')::int = 1 AND (v_r.o_res->>'changed')::int = 0 AND (v_r.o_res->>'unchanged')::int = 1,
    format('(E5) requested cuenta ids distintos; eligible sólo lo vivo y propio: %s', v_r.o_res));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e5_b')) = 5000 AND (SELECT price FROM public.products WHERE id = pg_temp.fx('e5_del')) = 700,
    '(E5) el producto de OTRA cuenta o el borrado cambió de precio');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted') = v_audit, '(E5) sin cambios no debe haber auditoría');

  -- ── E6: muestra de hasta 10; dry-run no escribe ni audita ─────────────────
  SELECT string_agg(quote_literal(pg_temp.fx(format('e6_%s', i))), ',') INTO v_e6 FROM generate_series(1, 12) i;
  SELECT count(*) INTO v_audit FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted';
  SELECT * INTO v_r FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(ARRAY[%s]::uuid[], ''percent'', ''increase'', 10, true)', v_e6));
  PERFORM pg_temp.chk(v_r.o_state = '00000' AND (v_r.o_res->>'changed')::int = 12 AND jsonb_array_length(v_r.o_res->'sample') = 10,
    format('(E6) dry-run: 12 cambian y la muestra trae 10; got %s %s', v_r.o_state, v_r.o_res));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e6_1')) = 100 AND (SELECT price FROM public.products WHERE id = pg_temp.fx('e6_12')) = 1200,
    '(E6) el dry-run escribió precios');
  PERFORM pg_temp.chk((SELECT count(*) FROM public.audit_logs WHERE action = 'product.bulk_price_adjusted') = v_audit, '(E6) el dry-run escribió auditoría');
  PERFORM pg_temp.chk((v_r.o_res->'sample'->0->>'price_before')::numeric = 100 AND (v_r.o_res->'sample'->0->>'price_after')::numeric = 110,
    format('(E6) la muestra va ordenada por nombre: %s', v_r.o_res->'sample'->0));
  -- la aplicación real devuelve lo mismo que la vista previa
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(ARRAY[%s]::uuid[], ''percent'', ''increase'', 10, false)', v_e6));
  PERFORM pg_temp.chk(v_x.o_res = v_r.o_res, format('(E6) la vista previa y la aplicación deben devolver el mismo resultado: %s vs %s', v_r.o_res, v_x.o_res));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e6_12')) = 1320, '(E6) la aplicación real no escribió');

  -- ── E7: rangos y validaciones (todas P0400, sin escribir) ─────────────────
  v_ids := format('%L::uuid[]', ARRAY[pg_temp.fx('e1_a')]::text);
  FOR v_r IN
    SELECT label, expr FROM (VALUES
      ('baja del 95 %',        format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''decrease'', 95, false)', v_ids)),
      ('aumento del 1.500 %',  format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 1500, false)', v_ids)),
      ('valor 0',              format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 0, false)', v_ids)),
      ('valor negativo',       format('public.rpc_bulk_adjust_prices(%s, ''amount'', ''increase'', -5, false)', v_ids)),
      ('valor nulo',           format('public.rpc_bulk_adjust_prices(%s, ''amount'', ''increase'', NULL, false)', v_ids)),
      ('modo inválido',        format('public.rpc_bulk_adjust_prices(%s, ''fixed'', ''increase'', 5, false)', v_ids)),
      ('dirección inválida',   format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''up'', 5, false)', v_ids)),
      ('lista vacía',          'public.rpc_bulk_adjust_prices(ARRAY[]::uuid[], ''percent'', ''increase'', 5, false)'),
      ('lista nula',           'public.rpc_bulk_adjust_prices(NULL::uuid[], ''percent'', ''increase'', 5, false)'),
      ('501 ids',              'public.rpc_bulk_adjust_prices(ARRAY(SELECT gen_random_uuid() FROM generate_series(1, 501)), ''percent'', ''increase'', 5, false)')
    ) t(label, expr)
  LOOP
    SELECT * INTO v_x FROM pg_temp.run_rpc(v_ow, v_a, v_r.expr);
    PERFORM pg_temp.chk(v_x.o_state = 'P0400', format('(E7) %s: esperado P0400; got %s %s', v_r.label, v_x.o_state, v_x.o_msg));
  END LOOP;
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e1_a')) = 1100, '(E7) una validación fallida escribió');
  -- los bordes SÍ se aceptan: baja del 90 %, aumento del 1.000 %, exactamente 500 ids (en dry-run)
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''decrease'', 90, true)', v_ids));
  PERFORM pg_temp.chk(v_x.o_state = '00000', format('(E7) baja del 90%% debía aceptarse; got %s %s', v_x.o_state, v_x.o_msg));
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ow, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 1000, true)', v_ids));
  PERFORM pg_temp.chk(v_x.o_state = '00000', format('(E7) aumento del 1000%% debía aceptarse; got %s %s', v_x.o_state, v_x.o_msg));
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ow, v_a, 'public.rpc_bulk_adjust_prices(ARRAY(SELECT gen_random_uuid() FROM generate_series(1, 500)), ''percent'', ''increase'', 5, true)');
  PERFORM pg_temp.chk(v_x.o_state = '00000' AND (v_x.o_res->>'eligible')::int = 0, format('(E7) 500 ids debía aceptarse; got %s %s', v_x.o_state, v_x.o_msg));

  -- ── E8: roles ─────────────────────────────────────────────────────────────
  v_ids := format('%L::uuid[]', ARRAY[pg_temp.fx('e1_a')]::text);
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_st, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 10, false)', v_ids));
  PERFORM pg_temp.chk(v_x.o_state = 'P0403' AND v_x.o_msg LIKE 'insufficient_role%', format('(E8) depósito: esperado P0403 insufficient_role; got %s %s', v_x.o_state, v_x.o_msg));
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ca, v_a, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 10, true)', v_ids));
  PERFORM pg_temp.chk(v_x.o_state = 'P0403', format('(E8) cajero (también en dry-run): esperado P0403; got %s', v_x.o_state));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e1_a')) = 1100, '(E8) un rechazo por rol escribió');
  -- el dueño de OTRA cuenta no toca los productos de A: ids ajenos = sin efecto ni error.
  SELECT * INTO v_x FROM pg_temp.run_rpc(v_ob, v_b, format('public.rpc_bulk_adjust_prices(%s, ''percent'', ''increase'', 10, false)', v_ids));
  PERFORM pg_temp.chk(v_x.o_state = '00000' AND (v_x.o_res->>'eligible')::int = 0 AND (v_x.o_res->>'changed')::int = 0, format('(E8) otra cuenta: sin efecto ni error; got %s %s', v_x.o_state, v_x.o_res));
  PERFORM pg_temp.chk((SELECT price FROM public.products WHERE id = pg_temp.fx('e1_a')) = 1100, '(E8) la otra cuenta cambió el precio de A');

  -- ── E9: ACL ───────────────────────────────────────────────────────────────
  PERFORM pg_temp.chk(NOT has_function_privilege('anon', 'public.rpc_bulk_adjust_prices(uuid[],text,text,numeric,boolean)', 'EXECUTE'), '(E9) anon tiene EXECUTE sobre rpc_bulk_adjust_prices');
  PERFORM pg_temp.chk(has_function_privilege('authenticated', 'public.rpc_bulk_adjust_prices(uuid[],text,text,numeric,boolean)', 'EXECUTE'), '(E9) authenticated no tiene EXECUTE sobre rpc_bulk_adjust_prices');
  PERFORM pg_temp.chk((SELECT count(*) FROM pg_proc WHERE proname = 'rpc_bulk_adjust_prices') = 1, '(E9) rpc_bulk_adjust_prices debe tener UNA sola firma');
  PERFORM pg_temp.chk(NOT has_function_privilege('anon', 'public.product_round_price(numeric)', 'EXECUTE'), '(E9) anon tiene EXECUTE sobre product_round_price');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (F) Introspección: cuerpo vivo del guard, funciones nuevas, ACLs, COMMENT
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_def text;  v_fn text;  v_n integer;
BEGIN
  v_def := pg_get_functiondef('public.fn_product_base_unit_guard()'::regprocedure);
  PERFORM pg_temp.chk(position('products.unit_relabel_root' in v_def) > 0, '(F) el guard no contiene el corte del GUC products.unit_relabel_root');
  PERFORM pg_temp.chk(position('NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id' in v_def) > 0
                      AND position('NEW.account_id = OLD.account_id' in v_def) > 0,
    '(F) el corte del guard debe exigir mismo padre y misma cuenta');
  -- el corte va DESPUÉS del chequeo de tenencia de la unidad y ANTES de los chequeos de stock
  PERFORM pg_temp.chk(position('base_unit_not_found' in v_def) < position('products.unit_relabel_root' in v_def)
                      AND position('products.unit_relabel_root' in v_def) < position('base_unit_locked' in v_def),
    '(F) el corte debe ir después de la tenencia (P0404) y antes del P0409');
  PERFORM pg_temp.chk(position('delivery_note_items' in v_def) > 0 AND position('ventas_uom.deleted_parent_base' in v_def) > 0,
    '(F) el guard perdió partes del cuerpo previo (remitos / DELETE del padre)');
  PERFORM pg_temp.chk((SELECT count(*) FROM pg_trigger WHERE tgfoid = 'public.fn_product_base_unit_guard()'::regprocedure AND tgname = 'trg_product_base_unit_guard' AND tgenabled = 'O') = 1,
    '(F) falta el disparador trg_product_base_unit_guard habilitado');
  PERFORM pg_temp.chk(NOT has_function_privilege('authenticated', 'public.fn_product_base_unit_guard()', 'EXECUTE')
                      AND NOT has_function_privilege('anon', 'public.fn_product_base_unit_guard()', 'EXECUTE'),
    '(F) el guard no debe tener EXECUTE para authenticated ni anon');
  PERFORM pg_temp.chk((SELECT obj_description('public.fn_product_base_unit_guard()'::regprocedure, 'pg_proc') IS NOT NULL), '(F) el guard perdió su COMMENT');

  FOREACH v_fn IN ARRAY ARRAY['rpc_relabel_product_unit', 'rpc_bulk_adjust_prices', 'product_round_price'] LOOP
    SELECT count(*) INTO v_n FROM pg_proc WHERE proname = v_fn AND pronamespace = 'public'::regnamespace;
    PERFORM pg_temp.chk(v_n = 1, format('(F) %s tiene %s firmas vivas (esperado 1)', v_fn, v_n));
    PERFORM pg_temp.chk((SELECT obj_description(p.oid, 'pg_proc') IS NOT NULL FROM pg_proc p WHERE p.proname = v_fn AND p.pronamespace = 'public'::regnamespace),
      format('(F) %s no tiene COMMENT', v_fn));
  END LOOP;
  PERFORM pg_temp.chk((SELECT prosecdef FROM pg_proc WHERE proname = 'rpc_relabel_product_unit') AND (SELECT prosecdef FROM pg_proc WHERE proname = 'rpc_bulk_adjust_prices'),
    '(F) las dos RPCs deben ser SECURITY DEFINER');
  PERFORM pg_temp.chk((SELECT proconfig::text LIKE '%search_path=public%' FROM pg_proc WHERE proname = 'rpc_relabel_product_unit')
                      AND (SELECT proconfig::text LIKE '%search_path=public%' FROM pg_proc WHERE proname = 'rpc_bulk_adjust_prices'),
    '(F) las dos RPCs deben fijar search_path = public');
  -- el cuerpo del relabel toma la raíz y luego las variantes POR ORDEN DE ID, con el filtro de cuenta
  v_def := (SELECT prosrc FROM pg_proc WHERE proname = 'rpc_relabel_product_unit');
  PERFORM pg_temp.chk(position('ORDER BY v.id' in v_def) > 0 AND position('FOR UPDATE' in v_def) > 0, '(F) el relabel debe bloquear las variantes por orden de id');
  PERFORM pg_temp.chk(position('set_config(''products.unit_relabel_root'', '''', true)' in v_def) > 0, '(F) el relabel debe volver a vaciar el GUC');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- (G) rpc_bulk_upsert_products: la rama Padre nunca deja precio/costo (D3, 1.3)
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_a uuid := pg_temp.fx('a');  v_ow uuid := pg_temp.fx('ow');
  v_res jsonb;  v_id uuid;
BEGIN
  PERFORM pg_temp.as_user(v_ow, v_a);

  -- Un producto existente (tracked, con precio y costo) al que el archivo marca como Padre por SKU.
  INSERT INTO public.products (user_id, account_id, name, sku, price, cost, stock_control_type)
  VALUES (v_ow, v_a, 'PPV Import existente', 'PPV-IMP-EXIST', 100, 50, 'tracked') RETURNING id INTO v_id;
  INSERT INTO fx VALUES ('imp_exist', v_id);

  v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
    -- G1: alta de un Padre con precio y costo en el archivo
    jsonb_build_object('row_no', 1, 'name', 'PPV Import Padre nuevo', 'sku', 'PPV-IMP-NEW', 'price', '1500', 'cost', '800',
                       'stock_control_type', 'variant_only'),
    -- G2: el existente pasa a Padre con el mismo SKU
    jsonb_build_object('row_no', 2, 'name', 'PPV Import existente', 'sku', 'PPV-IMP-EXIST', 'price', '120', 'cost', '60',
                       'stock_control_type', 'variant_only'),
    -- G3: control — un producto simple conserva su precio y su costo
    jsonb_build_object('row_no', 3, 'name', 'PPV Import simple', 'sku', 'PPV-IMP-SIMPLE', 'price', '200', 'cost', '90',
                       'stock_control_type', 'tracked')
  ), v_ow);
  PERFORM pg_temp.chk(jsonb_array_length(v_res->'errors') = 0, format('(G) el import dio errores de fila: %s', v_res->'errors'));
  PERFORM pg_temp.chk((v_res->>'inserted')::int = 2 AND (v_res->>'updated')::int = 1, format('(G) contadores inesperados: %s', v_res));
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL AND stock_control_type = 'variant_only' FROM public.products
                        WHERE account_id = v_a AND sku = 'PPV-IMP-NEW'),
    '(G1) el Padre nuevo del archivo quedó con precio o costo');
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL AND stock_control_type = 'variant_only' FROM public.products WHERE id = v_id),
    '(G2) el producto que pasó a Padre conservó precio o costo');
  PERFORM pg_temp.chk((SELECT price = 200 AND cost = 90 FROM public.products WHERE account_id = v_a AND sku = 'PPV-IMP-SIMPLE'),
    '(G3) el producto simple perdió su precio/costo (el forzado sólo aplica al Padre)');

  -- G4: reimportar un Padre ya existente (sólo cambia el nombre) con un precio en el archivo: sigue en 0/NULL.
  v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', 'PPV Import Padre nuevo v2', 'sku', 'PPV-IMP-NEW', 'price', '999', 'cost', '1',
                       'stock_control_type', 'variant_only')), v_ow);
  PERFORM pg_temp.chk(jsonb_array_length(v_res->'errors') = 0, format('(G4) el reimport dio errores de fila: %s', v_res->'errors'));
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL AND name = 'PPV Import Padre nuevo v2' FROM public.products
                        WHERE account_id = v_a AND sku = 'PPV-IMP-NEW'),
    '(G4) reimportar un Padre le dejó precio/costo o no actualizó el nombre');

  -- G5: fila sin tipo sobre un Padre existente conserva el tipo (COALESCE) y sigue sin precio.
  v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
    jsonb_build_object('row_no', 1, 'name', 'PPV Import Padre nuevo v3', 'sku', 'PPV-IMP-NEW', 'price', '777')), v_ow);
  PERFORM pg_temp.chk(jsonb_array_length(v_res->'errors') = 0, format('(G5) fila sin tipo sobre un Padre dio error: %s', v_res->'errors'));
  PERFORM pg_temp.chk((SELECT price = 0 AND cost IS NULL FROM public.products WHERE account_id = v_a AND sku = 'PPV-IMP-NEW'),
    '(G5) una fila sin tipo le puso precio a un Padre existente');
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Cierre: UN solo fallo con todo el detalle
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_msg text;
BEGIN
  SELECT string_agg(msg, E'\n  - ') INTO v_msg FROM gate_fails;
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION E'GATE PRODUCTOS-PADRE-VARIANTES FAILED:\n  - %', v_msg;
  END IF;
  RAISE NOTICE 'GATE PRODUCTOS-PADRE-VARIANTES PASSED';
END $$;

ROLLBACK;
