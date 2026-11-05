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
