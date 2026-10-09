-- =============================================================================
-- GATE: test_stock_ledger_solo_rpc.sql
-- CHANGE: stock-ledger-solo-rpc — TANDA A (migración
--         20261073000001_stock_ledger_cierre_escritura_directa.sql)
--         y TANDA B (migración
--         20261074000001_stock_ledger_nucleo_ajuste_manual.sql)
--         (governance ALTA: ledger de stock + revocación de privilegios;
--          PO 2026-10-08: "arrancá la tanda A"; tanda B firmada con las
--          mismas decisiones y las tres OQ por su recomendación)
-- =============================================================================
--
-- QUÉ PRUEBA. Que NINGÚN rol de aplicación (`authenticated`, `anon`) puede
-- escribir directamente `public.stock_movements` ni `public.branch_stock`, y que
-- `public.rpc_reverse_stock_movement` ya no es invocable por PostgREST. Toda
-- escritura del inventario entra por una función SECURITY DEFINER que ya
-- validó al usuario. Antes de la migración, `authenticated` conservaba
-- INSERT/UPDATE/DELETE/TRUNCATE a nivel tabla y tres policies permisivas de
-- escritura: un `viewer` podía forjar una fila `reference_type='sale'` y
-- reponer con ella stock inexistente (control ejecutado, evidence/logs/01_*),
-- un `seller` pisaba un saldo sin dejar rastro en el ledger, y un escritor de
-- la cuenta A podía ocupar la fila de saldo de un producto de la cuenta B.
--
-- Bloques de la TANDA A:
--   (a) metadata de privilegios: ni `authenticated` ni `anon` conservan
--       INSERT/UPDATE/DELETE/TRUNCATE a nivel tabla NI a nivel columna sobre
--       las dos tablas. CONTROL POSITIVO: `authenticated` conserva SELECT (un
--       REVOKE ALL pasaría los negativos y rompería el historial y /stock).
--   (b) forma EXACTA de las policies: sólo las dos de lectura por cuenta y las
--       dos `qual = false` de stock_movements (segunda red ante un re-GRANT),
--       ninguna policy permisiva de INSERT/UPDATE/DELETE/ALL. RLS sigue activa.
--   (c) ACL de la reversa: sin EXECUTE para anon/authenticated/PUBLIC, un solo
--       overload, sigue SECURITY DEFINER. CONTROL POSITIVO: las RPCs públicas
--       de ajuste/transferencia conservan EXECUTE para authenticated.
--   (d) MATRIZ DE EVASIÓN bajo SET LOCAL ROLE authenticated con un owner, un
--       seller y un viewer (más anon): INSERT (forja y ocupación cross-tenant),
--       UPDATE, UPDATE ... RETURNING, INSERT ... ON CONFLICT DO UPDATE, DELETE,
--       TRUNCATE sobre las dos tablas y la llamada a la reversa. Cada intento
--       exige SQLSTATE 42501 Y texto "permission denied" —NO el de RLS—, con la
--       huella de las dos tablas idéntica antes y después.
--   (e) CONTROL POSITIVO de los caminos legítimos con el mismo owner: ajuste,
--       alta y borrado de una venta y de una compra (incluida la compra ya
--       vendida: piso en cero trazable), transferencia, borrado de un producto
--       con historial (las acciones referenciales de las FKs siguen
--       corriendo), lectura propia sí / ajena no.
--
-- POR QUÉ NO ALCANZA CON MIRAR EL SQLSTATE. El 42501 lo comparten tres capas:
-- falta el privilegio ("permission denied for table ..."), la RLS rechazó la fila
-- ("new row violates row-level security policy ...") y un trigger/guard que lo
-- reutiliza. Hoy la capa de RLS ya frena a un viewer o una fila de otra cuenta;
-- un gate que sólo mirara el SQLSTATE habría estado en verde antes de la
-- migración. Cada chequeo negativo exige entonces el texto de la capa de
-- PRIVILEGIO. (Mismo razonamiento y molde que test_accounts_privilege_columns.sql.)
--
-- Aislamiento. Todo corre dentro de BEGIN ... ROLLBACK: cada intento de la
-- matriz va en su propia subtransacción que se REVIERTE siempre (aun si el
-- intento prosperó), así que este gate puede correr contra una base SIN la
-- migración —el RED— sin destruir nada (un TRUNCATE que prospere se deshace).
-- Las fallas se acumulan en una tabla temporal y un único RAISE al final las
-- lista todas (RED completo en una sola corrida). Usuarios sintéticos
-- `@test.local` vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod). Degrade-don't-fail SÓLO en la fixture (base sin esquema
-- auth); metadata y negativos nunca degradan.
--
-- Bloques de la TANDA B (núcleo único de ajuste manual, ver el cabezal de la
-- sección "TANDA B" más abajo): (f) rol × envoltorio, (g) motivo + CHECK
-- NOT VALID, (h) flags internos, (i) tenencia, (j) sello e invariante, (k)
-- semántica del movimiento, (l) reversa tras la reescritura, (m) ACL de las
-- internas y de los envoltorios.
--
-- Corre en CI: KPI_Validation.yml ("Run stock ledger solo RPC gate").
-- =============================================================================

BEGIN;

CREATE TEMP TABLE slr_fail (id serial, msg text);

-- Registra una falla (visible al instante como NOTICE; el RAISE final las suma).
-- Se llama SIEMPRE con rol postgres: la tabla temporal es del dueño de sesión.
CREATE OR REPLACE FUNCTION pg_temp.slr_fail(p_msg text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO pg_temp.slr_fail (msg) VALUES (p_msg);
  RAISE NOTICE 'FAIL %', p_msg;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.slr_as(p_uid uuid) RETURNS void
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

-- Huella de las filas del gate en las dos tablas (idéntica antes/después de un
-- intento rechazado). Acotada a las cuentas/productos/usuarios de la fixture
-- para no depender de datos ajenos que otra sesión pudiera commitear.
CREATE OR REPLACE FUNCTION pg_temp.slr_fp(p_acc uuid[], p_prod uuid[], p_users uuid[]) RETURNS text
LANGUAGE sql AS $f$
  SELECT md5(
    COALESCE((SELECT string_agg(b::text, '|' ORDER BY b.id) FROM public.branch_stock b
               WHERE b.account_id = ANY (p_acc) OR b.product_id = ANY (p_prod)), '')
    || '#' ||
    COALESCE((SELECT string_agg(m::text, '|' ORDER BY m.id) FROM public.stock_movements m
               WHERE m.account_id = ANY (p_acc) OR m.product_id = ANY (p_prod) OR m.user_id = ANY (p_users)), '')
  );
$f$;

-- Un intento de la matriz de evasión. Corre p_sql con el rol y los claims
-- indicados dentro de una subtransacción que SIEMPRE se revierte. Devuelve:
--   'DENIED|<msg>'            42501 con texto "permission denied..." (capa de privilegio)
--   'OTRA-CAPA-42501|<msg>'   42501 pero de la RLS o de un guard (no cuenta)
--   'NOT-REJECTED rows=N huella=igual|CAMBIÓ'   el intento prosperó
--   'ERROR <sqlstate> <msg>'  otro error
-- y 'DENIED' sólo si la huella antes/después es idéntica.
CREATE OR REPLACE FUNCTION pg_temp.slr_try(p_uid uuid, p_role text, p_sql text,
                                           p_acc uuid[], p_prod uuid[], p_users uuid[])
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_fp0    text;
  v_fp1    text;
  v_state  text;
  v_msg    text;
  v_detail text;
  v_n      bigint := 0;
  v_res    text;
BEGIN
  PERFORM pg_temp.slr_as(p_uid);
  v_fp0 := pg_temp.slr_fp(p_acc, p_prod, p_users);
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RESET ROLE;
    v_fp1 := pg_temp.slr_fp(p_acc, p_prod, p_users);
    RAISE EXCEPTION 'slr: el intento no fue rechazado' USING ERRCODE = 'SLR01',
      DETAIL = v_n::text || '|' || (v_fp0 = v_fp1)::text;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_state = 'SLR01' THEN
      v_res := format('NOT-REJECTED rows=%s huella=%s', split_part(v_detail, '|', 1),
                      CASE split_part(v_detail, '|', 2) WHEN 'true' THEN 'igual' ELSE 'CAMBIÓ' END);
    ELSIF v_state = '42501' AND v_msg LIKE 'permission denied%' THEN
      v_res := 'DENIED|' || v_msg;
    ELSIF v_state = '42501' THEN
      v_res := 'OTRA-CAPA-42501|' || v_msg;
    ELSE
      v_res := format('ERROR %s %s', v_state, v_msg);
    END IF;
  END;
  -- Fuera del handler el rol volvió a postgres y el intento está revertido.
  IF v_res LIKE 'DENIED|%' AND pg_temp.slr_fp(p_acc, p_prod, p_users) IS DISTINCT FROM v_fp0 THEN
    v_res := 'DENIED-pero-la-huella-CAMBIÓ';
  END IF;
  PERFORM pg_temp.slr_as(NULL);
  RETURN v_res;
END;
$f$;

-- Llama a una RPC EXACTAMENTE como la llama el navegador (rol authenticated +
-- claims del usuario) y devuelve su resultado como jsonb; si falla, devuelve
-- {"error": "<sqlstate> <mensaje>"} en vez de abortar. p_sql es un SELECT que
-- devuelve UN jsonb. El efecto SÍ persiste (a diferencia de slr_try).
CREATE OR REPLACE FUNCTION pg_temp.slr_rpc(p_uid uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE
  v_r     jsonb;
  v_state text;
  v_msg   text;
BEGIN
  PERFORM pg_temp.slr_as(p_uid);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v_r;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.slr_as(NULL);
    RETURN v_r;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM pg_temp.slr_as(NULL);
    RETURN jsonb_build_object('error', v_state || ' ' || v_msg);
  END;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.slr_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock
  WHERE product_id = p_product AND branch_id = p_branch;
$f$;


-- ── (a) Metadata: privilegios de las dos tablas ─────────────────────────────
DO $$
DECLARE
  v_role text;
  v_tbl  text;
  v_priv text;
  v_bad  text[] := '{}';
BEGIN
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    FOREACH v_tbl IN ARRAY ARRAY['public.stock_movements', 'public.branch_stock'] LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF has_table_privilege(v_role, v_tbl, v_priv) THEN
          v_bad := v_bad || format('%s conserva %s de TABLA sobre %s', v_role, v_priv, v_tbl);
        END IF;
      END LOOP;
      -- Los grants por COLUMNA no los ve has_table_privilege.
      IF has_any_column_privilege(v_role, v_tbl, 'INSERT') THEN
        v_bad := v_bad || format('%s conserva INSERT por columna sobre %s', v_role, v_tbl);
      END IF;
      IF has_any_column_privilege(v_role, v_tbl, 'UPDATE') THEN
        v_bad := v_bad || format('%s conserva UPDATE por columna sobre %s', v_role, v_tbl);
      END IF;
    END LOOP;
  END LOOP;

  -- Control positivo: la lectura (historial de /stock, panel de movimientos) sigue.
  FOREACH v_tbl IN ARRAY ARRAY['public.stock_movements', 'public.branch_stock'] LOOP
    IF NOT has_table_privilege('authenticated', v_tbl, 'SELECT') THEN
      v_bad := v_bad || format('control positivo: authenticated PERDIÓ SELECT sobre %s (un REVOKE ALL rompe la lectura)', v_tbl);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    PERFORM pg_temp.slr_fail('(a) ' || array_to_string(v_bad, '; '));
  ELSE
    RAISE NOTICE 'PASS (a): authenticated y anon sin INSERT/UPDATE/DELETE/TRUNCATE (tabla ni columna) sobre stock_movements y branch_stock; authenticated conserva SELECT.';
  END IF;
END $$;


-- ── (b) Policies: forma EXACTA ───────────────────────────────────────────────
DO $$
DECLARE
  v_expected CONSTANT text[] := ARRAY[
    'branch_stock|branch_stock_member_select|SELECT',
    'stock_movements|stock_movements_account_select|SELECT',
    'stock_movements|stock_movements_no_delete|DELETE',
    'stock_movements|stock_movements_no_update|UPDATE'
  ];
  v_actual text[];
  v_bad    text[] := '{}';
  r        RECORD;
BEGIN
  SELECT COALESCE(array_agg(tablename || '|' || policyname || '|' || cmd ORDER BY tablename, policyname), '{}')
    INTO v_actual
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename IN ('stock_movements', 'branch_stock');

  IF v_actual IS DISTINCT FROM v_expected THEN
    v_bad := v_bad || format('el conjunto de policies debía ser exactamente {%s} y es {%s}',
                             array_to_string(v_expected, ', '), array_to_string(v_actual, ', '));
  END IF;

  -- Ninguna policy permisiva de escritura (red por si un futuro GRANT amplio reabre el privilegio).
  FOR r IN SELECT tablename, policyname, cmd FROM pg_policies
            WHERE schemaname = 'public' AND tablename IN ('stock_movements', 'branch_stock')
              AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
              AND NOT (tablename = 'stock_movements' AND policyname IN ('stock_movements_no_update', 'stock_movements_no_delete'))
  LOOP
    v_bad := v_bad || format('policy de escritura que debía desaparecer: %s.%s (%s)', r.tablename, r.policyname, r.cmd);
  END LOOP;

  -- Las dos que se conservan siguen siendo `qual = false` (defensa en profundidad).
  FOR r IN SELECT policyname, qual FROM pg_policies
            WHERE schemaname = 'public' AND tablename = 'stock_movements'
              AND policyname IN ('stock_movements_no_update', 'stock_movements_no_delete')
  LOOP
    IF r.qual IS DISTINCT FROM 'false' THEN
      v_bad := v_bad || format('%s debía seguir con qual = false y tiene %s', r.policyname, COALESCE(r.qual, 'NULL'));
    END IF;
  END LOOP;

  -- Las de lectura siguen acotadas por cuenta.
  FOR r IN SELECT policyname, qual FROM pg_policies
            WHERE schemaname = 'public' AND tablename IN ('stock_movements', 'branch_stock') AND cmd = 'SELECT'
  LOOP
    IF r.qual IS NULL OR r.qual NOT LIKE '%current_account_ids%' THEN
      v_bad := v_bad || format('%s debía seguir acotada por current_account_ids() y tiene %s', r.policyname, COALESCE(r.qual, 'NULL'));
    END IF;
  END LOOP;

  -- La RLS sigue activa en las dos.
  FOR r IN SELECT c.relname, c.relrowsecurity FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relname IN ('stock_movements', 'branch_stock')
  LOOP
    IF NOT r.relrowsecurity THEN
      v_bad := v_bad || format('RLS DESACTIVADA en %s', r.relname);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    PERFORM pg_temp.slr_fail('(b) ' || array_to_string(v_bad, '; '));
  ELSE
    RAISE NOTICE 'PASS (b): policies = {lectura por cuenta x2, no_update/no_delete qual=false}; ninguna permisiva de escritura; RLS activa.';
  END IF;
END $$;


-- ── (c) ACL de la reversa + control positivo de las RPCs públicas ───────────
DO $$
DECLARE
  v_fn     constant text := 'public.rpc_reverse_stock_movement(uuid,text,text)';
  v_oid    oid := to_regprocedure(v_fn);
  v_bad    text[] := '{}';
  v_pub    text;
BEGIN
  IF v_oid IS NULL THEN
    v_bad := v_bad || format('%s no existe con esa firma', v_fn);
  ELSE
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'anon tiene EXECUTE sobre la reversa'::text;
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'authenticated tiene EXECUTE sobre la reversa (invocable por PostgREST)'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) a WHERE p.oid = v_oid AND a.grantee = 0) THEN
      v_bad := v_bad || 'PUBLIC tiene EXECUTE sobre la reversa'::text;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_bad := v_bad || 'la reversa dejó de ser SECURITY DEFINER (la tanda A no toca su cuerpo)'::text;
    END IF;
    IF NOT has_function_privilege('postgres', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || 'postgres perdió EXECUTE de la reversa (rompe rpc_delete_sale_operation y rpc_delete_purchase_operation)'::text;
    END IF;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_reverse_stock_movement' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    v_bad := v_bad || 'rpc_reverse_stock_movement tiene un overload (o ninguna definición)'::text;
  END IF;

  -- Control positivo: las RPCs públicas que mueven stock por el camino legítimo
  -- conservan su EXECUTE (la tanda A NO las toca; las endurece la tanda B).
  FOREACH v_pub IN ARRAY ARRAY[
    'public.rpc_stock_adjustment(uuid,numeric,text,text,text,uuid,numeric)',
    'public.rpc_apply_product_stock_delta(uuid,numeric,uuid,text,boolean,boolean)',
    'public.rpc_adjust_branch_stock(uuid,uuid,numeric,text)',
    'public.rpc_transfer_stock(uuid,uuid,uuid,numeric)',
    'public.rpc_delete_sale_operation(uuid,uuid,text)',
    'public.rpc_delete_purchase_operation(uuid,uuid,text)'
  ] LOOP
    IF to_regprocedure(v_pub) IS NULL THEN
      v_bad := v_bad || format('control positivo: %s no existe', v_pub);
    ELSIF NOT has_function_privilege('authenticated', to_regprocedure(v_pub), 'EXECUTE') THEN
      v_bad := v_bad || format('control positivo: authenticated PERDIÓ EXECUTE de %s', v_pub);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    PERFORM pg_temp.slr_fail('(c) ' || array_to_string(v_bad, '; '));
  ELSE
    RAISE NOTICE 'PASS (c): rpc_reverse_stock_movement sin EXECUTE para anon/authenticated/PUBLIC, un solo overload, SECURITY DEFINER; las RPCs públicas de ajuste, transferencia y borrado conservan EXECUTE.';
  END IF;
END $$;


-- ── (d) Matriz de evasión + (e) control positivo de los caminos legítimos ───
DO $$
DECLARE
  v_owner_a   uuid := gen_random_uuid();
  v_seller    uuid := gen_random_uuid();
  v_viewer    uuid := gen_random_uuid();
  v_owner_b   uuid := gen_random_uuid();
  v_users     uuid[];
  v_acc_a     uuid;
  v_acc_b     uuid;
  v_accs      uuid[];
  v_member    uuid;
  v_xa        uuid;     -- sucursal default de A
  v_xa2       uuid;     -- segunda sucursal de A (transferencia)
  v_xb        uuid;     -- sucursal default de B
  v_client    uuid;
  v_pa        uuid;     -- producto de A con stock (matriz y transferencia)
  v_pa2       uuid;     -- producto de A sin fila de saldo
  v_pb        uuid;     -- producto de B (ocupación cross-tenant)
  v_ps        uuid;     -- venta
  v_pp        uuid;     -- compra
  v_pq        uuid;     -- compra ya vendida
  v_pdel      uuid;     -- borrado con historial
  v_prods     uuid[];
  v_fake_sale uuid := gen_random_uuid();
  v_mv_seed   uuid;

  v_f0        integer;
  v_nfail     integer := 0;
  v_tag       text;
  v_uid       uuid;
  v_label     text;
  v_sql       text;
  v_res       text;
  v_n_try     integer := 0;
  v_n_role    integer;
  v_n_denied  integer;
  v_r         jsonb;
  v_r2        jsonb;
  v_op        uuid;
  v_n         bigint;
  v_n2        bigint;
  v_val       numeric;
  v_val2      numeric;
  v_txt       text;
  c           RECORD;
  q           RECORD;
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no hay esquema auth para anclar la fixture — se omiten (d) y (e).';
    RETURN;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Fixture
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_seller, v_viewer, v_owner_b];
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'slr-gate-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate SLR ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_seller, 'seller'), (v_viewer, 'viewer'), (v_owner_b, 'owner-b')) AS u(id, tag);

  SELECT account_id INTO v_acc_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_acc_a IS NULL OR v_acc_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accs FROM public.account_members WHERE user_id = ANY (v_users);

  -- seller y viewer pertenecen a la cuenta A con su rol del pivot (se descarta la
  -- cuenta propia que les creó handle_new_user para que current_account_ids() = {A}).
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
   WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id IN (v_seller, v_viewer));
  DELETE FROM public.account_members WHERE user_id IN (v_seller, v_viewer);
  SET session_replication_role = DEFAULT;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc_a, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc_a, v_member, 'viewer');

  SELECT id INTO v_xa FROM public.branches WHERE account_id = v_acc_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_xb FROM public.branches WHERE account_id = v_acc_b ORDER BY created_at LIMIT 1;
  IF v_xa IS NULL OR v_xb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc_a, 'Gate SLR Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_xa2;

  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_acc_a, 'Cliente Gate SLR') RETURNING id INTO v_client;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PA', 'SLR-PA', 10, 20) RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PA2', 'SLR-PA2', 10, 20) RETURNING id INTO v_pa2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_acc_b, 'Gate SLR PB', 'SLR-PB', 10, 20) RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PS', 'SLR-PS', 10, 20) RETURNING id INTO v_ps;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PP', 'SLR-PP', 10, 20) RETURNING id INTO v_pp;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PQ', 'SLR-PQ', 10, 20) RETURNING id INTO v_pq;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR PDel', 'SLR-PDEL', 10, 20) RETURNING id INTO v_pdel;
  v_prods := ARRAY[v_pa, v_pa2, v_pb, v_ps, v_pp, v_pq, v_pdel];

  -- Stock legítimo de PA y una "venta" sembrada (como postgres, la forma legítima de
  -- escribir) para que la reversa de f1 tenga algo que revertir si prosperara.
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pa, v_xa, 10);
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                      quantity_delta, quantity_before, quantity_after,
                                      reference_id, reference_type, branch_id, performed_by)
  VALUES (v_owner_a, v_acc_a, v_pa, 'Gate SLR PA', 'sale', -1, 11, 10, v_fake_sale, 'sale', v_xa, v_owner_a);
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                      quantity_delta, quantity_before, quantity_after,
                                      reason, branch_id, performed_by)
  VALUES (v_owner_a, v_acc_a, v_pa, 'Gate SLR PA', 'adjustment', 0, 10, 10, 'seed gate slr', v_xa, v_owner_a)
  RETURNING id INTO v_mv_seed;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (d) Matriz de evasión
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);

  FOR c IN
    SELECT * FROM (VALUES
      ('owner',  v_owner_a, 'authenticated'),
      ('seller', v_seller,  'authenticated'),
      ('viewer', v_viewer,  'authenticated'),
      ('anon',   NULL::uuid, 'anon')
    ) AS t(tag, uid, role_name)
  LOOP
    v_n_role := 0;
    v_n_denied := 0;
    FOR q IN
      SELECT * FROM (VALUES
        ('m1 INSERT forja venta (cuenta propia)',
         format($q$INSERT INTO public.stock_movements (account_id, product_id, product_name, type, quantity_delta, reference_id, reference_type, branch_id)
                   VALUES (%L, %L, 'Gate SLR', 'sale', -1, %L, 'sale', %L)$q$, v_acc_a, v_pa, v_fake_sale, v_xa)),
        ('m2 INSERT forja cuenta ajena',
         format($q$INSERT INTO public.stock_movements (account_id, product_id, product_name, type, quantity_delta, reference_id, reference_type, branch_id)
                   VALUES (%L, %L, 'Gate SLR', 'sale', -1, %L, 'sale', %L)$q$, v_acc_b, v_pb, v_fake_sale, v_xb)),
        ('m3 UPDATE movimiento',
         format('UPDATE public.stock_movements SET quantity_delta = 0 WHERE id = %L', v_mv_seed)),
        ('m4 UPDATE movimiento RETURNING',
         format('UPDATE public.stock_movements SET notes = ''x'' WHERE id = %L RETURNING id', v_mv_seed)),
        ('m5 DELETE movimiento',
         format('DELETE FROM public.stock_movements WHERE id = %L', v_mv_seed)),
        ('m6 TRUNCATE stock_movements',
         'TRUNCATE public.stock_movements'),
        ('b1 INSERT saldo (cuenta y producto propios)',
         format('INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity) VALUES (%L, %L, %L, 5)', v_acc_a, v_pa2, v_xa)),
        ('b2 INSERT ocupación cross-tenant (A, producto de B, sucursal de B)',
         format('INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity) VALUES (%L, %L, %L, 0)', v_acc_a, v_pb, v_xb)),
        ('b3 UPDATE saldo a un valor distinto',
         format('UPDATE public.branch_stock SET quantity = quantity + 1 WHERE product_id = %L AND branch_id = %L', v_pa, v_xa)),
        ('b4 UPDATE saldo RETURNING',
         format('UPDATE public.branch_stock SET quantity = quantity + 1 WHERE product_id = %L AND branch_id = %L RETURNING quantity', v_pa, v_xa)),
        ('b5 INSERT ... ON CONFLICT DO UPDATE (upsert)',
         format($q$INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity) VALUES (%L, %L, %L, 99)
                   ON CONFLICT (product_id, branch_id) DO UPDATE SET quantity = EXCLUDED.quantity$q$, v_acc_a, v_pa, v_xa)),
        ('b6 DELETE saldo',
         format('DELETE FROM public.branch_stock WHERE product_id = %L', v_pa)),
        ('b7 TRUNCATE branch_stock',
         'TRUNCATE public.branch_stock'),
        ('f1 rpc_reverse_stock_movement (reversa pública)',
         format($q$SELECT public.rpc_reverse_stock_movement(%L, 'sale', 'gate slr')$q$, v_fake_sale))
      ) AS m(label, sql)
    LOOP
      v_n_try := v_n_try + 1;
      v_n_role := v_n_role + 1;
      v_res := pg_temp.slr_try(c.uid, c.role_name, q.sql, v_accs, v_prods, v_users);
      IF v_res LIKE 'DENIED|%' THEN
        v_n_denied := v_n_denied + 1;
      ELSE
        PERFORM pg_temp.slr_fail(format('(d) [%s] %s: se esperaba 42501 "permission denied" y salió: %s', c.tag, q.label, v_res));
      END IF;
    END LOOP;
    RAISE NOTICE 'info (d) [%]: % de % intentos rechazados con 42501 "permission denied"', c.tag, v_n_denied, v_n_role;
  END LOOP;

  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (d): % intentos (owner, seller, viewer y anon x 14 variantes) rechazados con 42501 "permission denied" y la huella de las dos tablas idéntica.', v_n_try;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) Control positivo: los caminos legítimos siguen escribiendo
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);

  -- e1: ajuste manual del owner (rpc_stock_adjustment, DEFINER).
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, 10, 'adjustment', 'gate slr e1', NULL, NULL, NULL)$q$, v_pa2));
  IF v_r ? 'error' OR (v_r->>'movement_id') IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(e1) el ajuste manual del owner falló o no dejó movimiento: %s', v_r));
  ELSIF pg_temp.slr_stock(v_pa2, v_xa) <> 10 THEN
    PERFORM pg_temp.slr_fail(format('(e1) branch_stock de PA2 debía ser 10 y es %s', pg_temp.slr_stock(v_pa2, v_xa)));
  END IF;

  -- e2: venta y borrado de la venta (la reversa interna repone).
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_ps, v_xa, 20);
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_sale_operation(%L, %L, CURRENT_DATE, 'ARS',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-sale-' || gen_random_uuid()::text, v_client, v_ps, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(e2) el alta de la venta falló: %s', v_r));
  ELSE
    IF pg_temp.slr_stock(v_ps, v_xa) <> 18 THEN
      PERFORM pg_temp.slr_fail(format('(e2) tras la venta de 2, el saldo de PS debía ser 18 y es %s', pg_temp.slr_stock(v_ps, v_xa)));
    END IF;
    v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_sale_operation(NULL, %L, %L))', v_op, 'gate slr e2'));
    IF v_r2 IS DISTINCT FROM 'true'::jsonb THEN
      PERFORM pg_temp.slr_fail(format('(e2) el borrado de la venta no devolvió true: %s', v_r2));
    END IF;
    IF pg_temp.slr_stock(v_ps, v_xa) <> 20 THEN
      PERFORM pg_temp.slr_fail(format('(e2) tras borrar la venta el saldo de PS debía volver a 20 y es %s (la reversa interna dejó de escribir)', pg_temp.slr_stock(v_ps, v_xa)));
    END IF;
    SELECT count(*) INTO v_n FROM public.stock_movements
     WHERE product_id = v_ps AND type = 'sale_return' AND reference_type = 'sale_reversal' AND quantity_delta = 2;
    IF v_n <> 1 THEN
      PERFORM pg_temp.slr_fail(format('(e2) debía quedar 1 contramovimiento sale_return/sale_reversal de +2 y hay %s', v_n));
    END IF;
  END IF;

  -- e3: compra y borrado de la compra.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_purchase_operation(%L, CURRENT_DATE, 'Compra gate SLR',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 50.00, 'quantity', 5, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-purch-' || gen_random_uuid()::text, v_pp, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(e3) el alta de la compra falló: %s', v_r));
  ELSE
    IF pg_temp.slr_stock(v_pp, v_xa) <> 5 THEN
      PERFORM pg_temp.slr_fail(format('(e3) tras comprar 5, el saldo de PP debía ser 5 y es %s', pg_temp.slr_stock(v_pp, v_xa)));
    END IF;
    v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_purchase_operation(NULL, %L, %L))', v_op, 'gate slr e3'));
    IF v_r2 IS DISTINCT FROM 'true'::jsonb THEN
      PERFORM pg_temp.slr_fail(format('(e3) el borrado de la compra no devolvió true: %s', v_r2));
    END IF;
    IF pg_temp.slr_stock(v_pp, v_xa) <> 0 THEN
      PERFORM pg_temp.slr_fail(format('(e3) tras borrar la compra el saldo de PP debía volver a 0 y es %s', pg_temp.slr_stock(v_pp, v_xa)));
    END IF;
    SELECT count(*) INTO v_n FROM public.stock_movements
     WHERE product_id = v_pp AND type = 'purchase_return' AND reference_type = 'purchase_reversal' AND quantity_delta = -5;
    IF v_n <> 1 THEN
      PERFORM pg_temp.slr_fail(format('(e3) debía quedar 1 contramovimiento purchase_return/purchase_reversal de -5 y hay %s', v_n));
    END IF;
  END IF;

  -- e4: compra YA VENDIDA — el borrado aplica el piso en cero trazable.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_purchase_operation(%L, CURRENT_DATE, 'Compra gate SLR (vendida)',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 50.00, 'quantity', 5, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-purch2-' || gen_random_uuid()::text, v_pq, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(e4) el alta de la compra falló: %s', v_r));
  ELSE
    v_r2 := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_sale_operation(%L, %L, CURRENT_DATE, 'ARS',
              jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 90.00, 'quantity', 3, 'unit_id', NULL)), %L, NULL)$q$,
              'slr-sale2-' || gen_random_uuid()::text, v_client, v_pq, v_xa));
    IF (v_r2->>'operation_id') IS NULL THEN
      PERFORM pg_temp.slr_fail(format('(e4) la venta de 3 sobre la compra falló: %s', v_r2));
    ELSE
      IF pg_temp.slr_stock(v_pq, v_xa) <> 2 THEN
        PERFORM pg_temp.slr_fail(format('(e4) tras comprar 5 y vender 3, el saldo de PQ debía ser 2 y es %s', pg_temp.slr_stock(v_pq, v_xa)));
      END IF;
      v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_purchase_operation(NULL, %L, %L))', v_op, 'gate slr e4'));
      IF v_r2 IS DISTINCT FROM 'true'::jsonb THEN
        PERFORM pg_temp.slr_fail(format('(e4) el borrado de la compra ya vendida no devolvió true: %s', v_r2));
      END IF;
      IF pg_temp.slr_stock(v_pq, v_xa) <> 0 THEN
        PERFORM pg_temp.slr_fail(format('(e4) el borrado de la compra ya vendida debía dejar el saldo en 0 (piso) y es %s', pg_temp.slr_stock(v_pq, v_xa)));
      END IF;
      SELECT count(*) INTO v_n FROM public.stock_movements
       WHERE product_id = v_pq AND type = 'adjustment' AND reason = 'floor_on_purchase_delete' AND quantity_delta = -2;
      IF v_n <> 1 THEN
        PERFORM pg_temp.slr_fail(format('(e4) debía quedar 1 ajuste trazable floor_on_purchase_delete de -2 y hay %s', v_n));
      END IF;
    END IF;
  END IF;

  -- e5: transferencia entre sucursales.
  v_r := pg_temp.slr_rpc(v_owner_a, format('SELECT public.rpc_transfer_stock(%L, %L, %L, 3)', v_pa, v_xa, v_xa2));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(e5) la transferencia falló: %s', v_r));
  ELSE
    IF pg_temp.slr_stock(v_pa, v_xa) <> 7 OR pg_temp.slr_stock(v_pa, v_xa2) <> 3 THEN
      PERFORM pg_temp.slr_fail(format('(e5) tras transferir 3 de PA, origen/destino debían ser 7/3 y son %s/%s',
                                      pg_temp.slr_stock(v_pa, v_xa), pg_temp.slr_stock(v_pa, v_xa2)));
    END IF;
    SELECT count(*) INTO v_n FROM public.stock_movements
     WHERE product_id = v_pa AND reference_type = 'transfer' AND type IN ('transfer_out', 'transfer_in');
    IF v_n <> 2 THEN
      PERFORM pg_temp.slr_fail(format('(e5) la transferencia debía dejar 2 movimientos (transfer_out + transfer_in) y dejó %s', v_n));
    END IF;
  END IF;

  -- e6: borrar un producto CON historial. Las acciones referenciales de las FKs
  -- (branch_stock ON DELETE CASCADE, stock_movements.product_id ON DELETE SET NULL)
  -- corren como dueño de la tabla, no como el rol que borra.
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pdel, v_xa, 3);
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, -3, 'adjustment', 'gate slr e6', NULL, NULL, NULL)$q$, v_pdel));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(e6) el ajuste -3 previo al borrado falló: %s', v_r));
  ELSE
    PERFORM pg_temp.slr_as(v_owner_a);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      DELETE FROM public.products WHERE id = v_pdel;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      EXECUTE 'RESET ROLE';
      IF v_n <> 1 THEN
        PERFORM pg_temp.slr_fail(format('(e6) el dueño debía poder borrar su producto sin stock (filas %s)', v_n));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
      PERFORM pg_temp.slr_fail(format('(e6) borrar un producto con historial falló bajo authenticated: %s', v_txt));
    END;
    PERFORM pg_temp.slr_as(NULL);
    SELECT count(*) INTO v_n FROM public.branch_stock WHERE product_id = v_pdel;
    SELECT count(*) INTO v_n2 FROM public.stock_movements WHERE product_name = 'Gate SLR PDel' AND product_id IS NULL;
    IF v_n <> 0 OR v_n2 < 1 THEN
      PERFORM pg_temp.slr_fail(format('(e6) tras borrar el producto debían cascadear sus saldos (hay %s) y quedar su historial huérfano con product_id NULL (hay %s)', v_n, v_n2));
    END IF;
  END IF;

  -- e7: lectura propia sí / ajena no (bajo RLS).
  v_r := pg_temp.slr_rpc(v_owner_b, format($q$SELECT public.rpc_stock_adjustment(%L, 4, 'adjustment', 'gate slr e7', NULL, NULL, NULL)$q$, v_pb));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(e7) el ajuste del owner de B falló: %s', v_r));
  END IF;
  PERFORM pg_temp.slr_as(v_owner_a);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_a;
  SELECT count(*) INTO v_n2 FROM public.branch_stock WHERE account_id = v_acc_a;
  SELECT count(*) INTO v_val FROM public.stock_movements WHERE account_id = v_acc_b;
  SELECT count(*) INTO v_val2 FROM public.branch_stock WHERE account_id = v_acc_b;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.slr_as(NULL);
  IF v_n < 1 OR v_n2 < 1 THEN
    PERFORM pg_temp.slr_fail(format('(e7) el owner de A debía leer sus movimientos y saldos (leyó %s / %s)', v_n, v_n2));
  END IF;
  IF v_val <> 0 OR v_val2 <> 0 THEN
    PERFORM pg_temp.slr_fail(format('(e7) el owner de A NO debía leer movimientos ni saldos de B (leyó %s / %s)', v_val, v_val2));
  END IF;
  PERFORM pg_temp.slr_as(v_owner_b);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_b;
  SELECT count(*) INTO v_n2 FROM public.stock_movements WHERE account_id = v_acc_a;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.slr_as(NULL);
  IF v_n < 1 OR v_n2 <> 0 THEN
    PERFORM pg_temp.slr_fail(format('(e7) el owner de B debía leer su movimiento (leyó %s) y ninguno de A (leyó %s)', v_n, v_n2));
  END IF;

  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (e): ajuste, venta y compra (alta y borrado, incl. compra ya vendida con piso trazable), transferencia, borrado de producto con historial y lectura propia/ajena funcionan con la escritura directa cerrada.';
  END IF;
END $$;


-- ═════════════════════════════════════════════════════════════════════════════
-- TANDA B (20261074000001) — bloques (f)-(m): núcleo único de ajuste manual
--   (f) rol × envoltorio   (g) motivo + CHECK   (h) flags internos
--   (i) tenencia           (j) sello e invariante   (k) semántica del movimiento
--   (l) reversa tras la reescritura   (m) ACL de internas y envoltorios
-- ═════════════════════════════════════════════════════════════════════════════

-- Da de alta un miembro de la cuenta p_acc con roles ACTIVOS (p_roles) y/o
-- VENCIDOS (p_expired), descartando la cuenta propia que le creó handle_new_user
-- (así current_account_ids() = {p_acc}).
CREATE OR REPLACE FUNCTION pg_temp.slr_member(p_acc uuid, p_user uuid, p_roles text[],
                                              p_expired text[] DEFAULT ARRAY[]::text[])
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_m uuid;
  v_r text;
BEGIN
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
   WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id = p_user);
  DELETE FROM public.account_members WHERE user_id = p_user;
  SET session_replication_role = DEFAULT;
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (p_acc, p_user, 'member') RETURNING id INTO v_m;
  FOREACH v_r IN ARRAY p_roles LOOP
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (p_acc, v_m, v_r);
  END LOOP;
  FOREACH v_r IN ARRAY p_expired LOOP
    INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at, expires_at)
    VALUES (p_acc, v_m, v_r, now() - interval '3 days', now() - interval '1 day');
  END LOOP;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.slr_nmov(p_product uuid) RETURNS bigint
LANGUAGE sql AS $f$ SELECT count(*) FROM public.stock_movements WHERE product_id = p_product; $f$;

CREATE OR REPLACE FUNCTION pg_temp.slr_total(p_product uuid) RETURNS numeric
LANGUAGE sql AS $f$ SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE product_id = p_product; $f$;

CREATE OR REPLACE FUNCTION pg_temp.slr_nstock_rows(p_product uuid) RETURNS bigint
LANGUAGE sql AS $f$ SELECT count(*) FROM public.branch_stock WHERE product_id = p_product; $f$;

-- ¿El resultado de slr_rpc es un error que empieza con p_prefix y (si se pide)
-- contiene p_token?
CREATE OR REPLACE FUNCTION pg_temp.slr_is_err(p_r jsonb, p_prefix text, p_token text DEFAULT NULL) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE((p_r ? 'error') AND (p_r->>'error') LIKE p_prefix || '%'
                  AND (p_token IS NULL OR (p_r->>'error') LIKE '%' || p_token || '%'), false);
$f$;

-- El último movimiento de un producto (por movement_number).
CREATE OR REPLACE FUNCTION pg_temp.slr_last_mv(p_product uuid) RETURNS public.stock_movements
LANGUAGE sql AS $f$
  SELECT m FROM public.stock_movements m WHERE m.product_id = p_product ORDER BY m.movement_number DESC LIMIT 1;
$f$;


-- ── (f)-(l) con la fixture de la tanda B ────────────────────────────────────
DO $$
DECLARE
  v_owner_a   uuid := gen_random_uuid();
  v_admin     uuid := gen_random_uuid();
  v_stock     uuid := gen_random_uuid();
  v_seller    uuid := gen_random_uuid();
  v_cashier   uuid := gen_random_uuid();
  v_purch     uuid := gen_random_uuid();
  v_acct      uuid := gen_random_uuid();
  v_viewer    uuid := gen_random_uuid();
  v_exp_mix   uuid := gen_random_uuid();   -- seller activo + stock VENCIDO
  v_exp_only  uuid := gen_random_uuid();   -- sólo stock VENCIDO
  v_owner_b   uuid := gen_random_uuid();
  v_owner_c   uuid := gen_random_uuid();   -- cuenta sin sucursales (alta perezosa)
  v_users     uuid[];
  v_acc_a     uuid;
  v_acc_b     uuid;
  v_acc_c     uuid;
  v_accs      uuid[];
  v_xa        uuid;     -- sucursal default de A
  v_xa2       uuid;     -- segunda sucursal de A
  v_xb        uuid;
  v_client    uuid;
  v_pf        uuid;     -- producto de la matriz de rol / motivo / flags
  v_pi        uuid;     -- producto de A para tenencia (creado por owner_a)
  v_pb        uuid;     -- producto de B
  v_pj        uuid;     -- sello e invariante
  v_pj2       uuid;     -- stock inicial
  v_pk        uuid;     -- semántica
  v_pv        uuid;     -- padre variant_only
  v_pc        uuid;     -- producto de la cuenta sin sucursales
  v_pl1       uuid;     -- reversa: venta
  v_pl2       uuid;     -- reversa: compra
  v_pl3       uuid;     -- reversa: compra ya vendida
  v_prods     uuid[];
  v_f0        integer;
  v_n_ok      integer;
  v_tot0      numeric;
  v_tot1      numeric;
  v_nm0       bigint;
  v_nm1       bigint;
  v_r         jsonb;
  v_r2        jsonb;
  v_sql       text;
  v_n         bigint;
  v_n2        bigint;
  v_txt       text;
  v_op        uuid;
  v_bad       text;
  v_type      text;
  v_def       text;
  v_legacy    uuid;
  v_ref       uuid := gen_random_uuid();
  v_mv        public.stock_movements%ROWTYPE;
  w           integer;
  c           RECORD;
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no hay esquema auth para anclar la fixture — se omiten (f)-(l).';
    RETURN;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Fixture
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_admin, v_stock, v_seller, v_cashier, v_purch, v_acct, v_viewer,
                   v_exp_mix, v_exp_only, v_owner_b, v_owner_c];
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'slr-gate-b-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate SLR B ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_admin, 'admin'), (v_stock, 'stock'), (v_seller, 'seller'),
               (v_cashier, 'cashier'), (v_purch, 'purchases'), (v_acct, 'accountant'), (v_viewer, 'viewer'),
               (v_exp_mix, 'exp-mix'), (v_exp_only, 'exp-only'), (v_owner_b, 'owner-b'), (v_owner_c, 'owner-c'))
       AS u(id, tag);

  SELECT account_id INTO v_acc_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_c FROM public.account_members WHERE user_id = v_owner_c ORDER BY created_at LIMIT 1;
  IF v_acc_a IS NULL OR v_acc_b IS NULL OR v_acc_c IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  v_accs := ARRAY[v_acc_a, v_acc_b, v_acc_c];

  PERFORM pg_temp.slr_member(v_acc_a, v_admin,     ARRAY['admin']);
  PERFORM pg_temp.slr_member(v_acc_a, v_stock,     ARRAY['stock']);
  PERFORM pg_temp.slr_member(v_acc_a, v_seller,    ARRAY['seller']);
  PERFORM pg_temp.slr_member(v_acc_a, v_cashier,   ARRAY['cashier']);
  PERFORM pg_temp.slr_member(v_acc_a, v_purch,     ARRAY['purchases']);
  PERFORM pg_temp.slr_member(v_acc_a, v_acct,      ARRAY['accountant']);
  PERFORM pg_temp.slr_member(v_acc_a, v_viewer,    ARRAY['viewer']);
  PERFORM pg_temp.slr_member(v_acc_a, v_exp_mix,   ARRAY['seller'], ARRAY['stock']);
  PERFORM pg_temp.slr_member(v_acc_a, v_exp_only,  ARRAY[]::text[], ARRAY['stock']);

  v_xa := public.c26_default_branch(v_acc_a);
  v_xb := public.c26_default_branch(v_acc_b);
  IF v_xa IS NULL OR v_xb IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc_a, 'Gate SLR B Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_xa2;

  -- La cuenta C arranca SIN sucursales: la primera escritura de stock debe crear la default.
  BEGIN
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = v_acc_c;
    SET session_replication_role = DEFAULT;
  EXCEPTION WHEN OTHERS THEN
    SET session_replication_role = DEFAULT;
    GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
    RAISE NOTICE 'info: no se pudo vaciar las sucursales de la cuenta C (%) — se omite el chequeo de alta perezosa.', v_txt;
  END;

  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_acc_a, 'Cliente Gate SLR B') RETURNING id INTO v_client;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PF', 'SLRB-PF', 10, 20) RETURNING id INTO v_pf;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PI', 'SLRB-PI', 10, 20) RETURNING id INTO v_pi;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_acc_b, 'Gate SLR B PB', 'SLRB-PB', 10, 20) RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PJ', 'SLRB-PJ', 10, 20) RETURNING id INTO v_pj;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PJ2', 'SLRB-PJ2', 10, 20) RETURNING id INTO v_pj2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PK', 'SLRB-PK', 10, 20) RETURNING id INTO v_pk;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PV', 'SLRB-PV', 10, 20, 'variant_only') RETURNING id INTO v_pv;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_c, v_acc_c, 'Gate SLR B PC', 'SLRB-PC', 10, 20) RETURNING id INTO v_pc;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PL1', 'SLRB-PL1', 10, 20) RETURNING id INTO v_pl1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PL2', 'SLRB-PL2', 10, 20) RETURNING id INTO v_pl2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_acc_a, 'Gate SLR B PL3', 'SLRB-PL3', 10, 20) RETURNING id INTO v_pl3;
  v_prods := ARRAY[v_pf, v_pi, v_pb, v_pj, v_pj2, v_pk, v_pv, v_pc, v_pl1, v_pl2, v_pl3];

  -- Saldos sembrados por c21 como postgres (sin pasar por el núcleo ni por ningún envoltorio).
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pf, v_xa, 50);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pi, v_xa, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pj, v_xa, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pj, v_xa2, 3);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pk, v_xa, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pk, v_xa2, 3);

  -- ═══════════════════════════════════════════════════════════════════════
  -- (f) Rol × envoltorio — los tres ejecutados de verdad, como authenticated
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  v_n_ok := 0;
  FOR c IN
    SELECT * FROM (VALUES
      ('owner',                v_owner_a,  'OK'),
      ('admin',                v_admin,    'OK'),
      ('stock',                v_stock,    'OK'),
      ('seller',               v_seller,   'P0403'),
      ('cashier',              v_cashier,  'P0403'),
      ('purchases',            v_purch,    'P0403'),
      ('accountant',           v_acct,     'P0403'),
      ('viewer',               v_viewer,   'P0401'),
      ('seller+stock-vencido', v_exp_mix,  'P0403'),
      ('stock-vencido-solo',   v_exp_only, 'P0401')
    ) AS t(tag, uid, expected)
  LOOP
    FOR w IN 1..3 LOOP
      v_tot0 := pg_temp.slr_total(v_pf);
      v_nm0  := pg_temp.slr_nmov(v_pf);
      v_sql := CASE w
        WHEN 1 THEN format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', 'gate slr f', NULL, NULL, NULL)$q$, v_pf)
        WHEN 2 THEN format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, %s, 'gate slr f')$q$, v_pf, v_xa, pg_temp.slr_stock(v_pf, v_xa) + 1)
        ELSE        format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr f', true, false)$q$, v_pf)
      END;
      v_r := pg_temp.slr_rpc(c.uid, v_sql);
      v_tot1 := pg_temp.slr_total(v_pf);
      v_nm1  := pg_temp.slr_nmov(v_pf);
      IF c.expected = 'OK' THEN
        IF v_r ? 'error' THEN
          PERFORM pg_temp.slr_fail(format('(f) [%s] envoltorio %s: debía poder ajustar y salió %s', c.tag, w, v_r->>'error'));
        ELSIF v_tot1 <> v_tot0 + 1 OR v_nm1 <> v_nm0 + 1 THEN
          PERFORM pg_temp.slr_fail(format('(f) [%s] envoltorio %s: debía dejar +1 de saldo y +1 movimiento y dejó %s / %s', c.tag, w, v_tot1 - v_tot0, v_nm1 - v_nm0));
        ELSE
          v_n_ok := v_n_ok + 1;
        END IF;
      ELSE
        IF NOT pg_temp.slr_is_err(v_r, c.expected, CASE WHEN c.expected = 'P0403' THEN 'insufficient_role' END) THEN
          PERFORM pg_temp.slr_fail(format('(f) [%s] envoltorio %s: se esperaba %s%s y salió %s', c.tag, w, c.expected,
                                          CASE WHEN c.expected = 'P0403' THEN ' insufficient_role' ELSE '' END,
                                          COALESCE(v_r->>'error', 'el intento PROSPERÓ ' || v_r::text)));
        ELSIF v_tot1 <> v_tot0 OR v_nm1 <> v_nm0 THEN
          PERFORM pg_temp.slr_fail(format('(f) [%s] envoltorio %s: el rechazo cambió saldo (%s) o movimientos (%s)', c.tag, w, v_tot1 - v_tot0, v_nm1 - v_nm0));
        ELSE
          v_n_ok := v_n_ok + 1;
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (f): % intentos (owner/admin/stock ajustan; seller/cashier/purchases/accountant P0403; viewer y rol vencido solo P0401; mixto con rol vencido P0403) x 3 envoltorios.', v_n_ok;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) Motivo obligatorio (P0400) + CHECK de segunda capa
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  v_n_ok := 0;
  FOREACH v_bad IN ARRAY ARRAY[NULL, '', '   ', E'\t \n']::text[] LOOP
    FOR w IN 1..3 LOOP
      v_tot0 := pg_temp.slr_total(v_pf);
      v_nm0  := pg_temp.slr_nmov(v_pf);
      v_sql := CASE w
        WHEN 1 THEN format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', %L, NULL, NULL, NULL)$q$, v_pf, v_bad)
        WHEN 2 THEN format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, %s, %L)$q$, v_pf, v_xa, pg_temp.slr_stock(v_pf, v_xa) + 1, v_bad)
        ELSE        format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, %L, true, false)$q$, v_pf, v_bad)
      END;
      v_r := pg_temp.slr_rpc(v_owner_a, v_sql);
      IF NOT pg_temp.slr_is_err(v_r, 'P0400', 'stock_adjustment_reason_required') THEN
        PERFORM pg_temp.slr_fail(format('(g) envoltorio %s con motivo %L: se esperaba P0400 stock_adjustment_reason_required y salió %s',
                                        w, v_bad, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
      ELSIF pg_temp.slr_total(v_pf) <> v_tot0 OR pg_temp.slr_nmov(v_pf) <> v_nm0 THEN
        PERFORM pg_temp.slr_fail(format('(g) envoltorio %s con motivo %L: el rechazo cambió saldo o movimientos', w, v_bad));
      ELSE
        v_n_ok := v_n_ok + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- El motivo se persiste RECORTADO.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', '   motivo g   ', NULL, NULL, NULL)$q$, v_pf));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(g) el ajuste con motivo válido falló: %s', v_r->>'error'));
  ELSE
    SELECT reason INTO v_txt FROM public.stock_movements WHERE id = (v_r->>'movement_id')::uuid;
    IF v_txt IS DISTINCT FROM 'motivo g' THEN
      PERFORM pg_temp.slr_fail(format('(g) el motivo debía persistirse recortado como %L y es %L', 'motivo g', v_txt));
    END IF;
  END IF;

  -- CHECK de segunda capa: ningún escritor (ni siquiera postgres) inserta un tipo manual sin motivo.
  FOREACH v_type IN ARRAY ARRAY['adjustment', 'physical_count', 'loss', 'damage', 'expiry'] LOOP
    FOREACH v_bad IN ARRAY ARRAY[NULL, '', '  ', E'	
 ']::text[] LOOP
      BEGIN
        INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                            quantity_delta, quantity_before, quantity_after, reason, branch_id, performed_by)
        VALUES (v_owner_a, v_acc_a, v_pf, 'Gate SLR B PF', v_type, -1, 10, 9, v_bad, v_xa, v_owner_a);
        RAISE EXCEPTION 'slr: el CHECK no rechazó' USING ERRCODE = 'SLR02';
      EXCEPTION
        WHEN check_violation THEN
          GET STACKED DIAGNOSTICS v_txt = CONSTRAINT_NAME;
          IF v_txt IS DISTINCT FROM 'stock_movements_manual_needs_reason' THEN
            PERFORM pg_temp.slr_fail(format('(g) %s con motivo %L: violó el CHECK %L y debía ser stock_movements_manual_needs_reason', v_type, v_bad, v_txt));
          END IF;
        WHEN SQLSTATE 'SLR02' THEN
          PERFORM pg_temp.slr_fail(format('(g) el CHECK permitió insertar type=%s con motivo %L', v_type, v_bad));
      END;
    END LOOP;
  END LOOP;
  -- Control positivo del CHECK: con motivo pasa; un tipo no manual sin motivo pasa.
  FOREACH v_type IN ARRAY ARRAY['adjustment', 'sale', 'sale_return', 'transfer_in', 'initial'] LOOP
    BEGIN
      INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                          quantity_delta, quantity_before, quantity_after, reason, branch_id, performed_by)
      VALUES (v_owner_a, v_acc_a, v_pf, 'Gate SLR B PF', v_type, 0, 10, 10,
              CASE WHEN v_type = 'adjustment' THEN 'control positivo' ELSE NULL END, v_xa, v_owner_a);
      RAISE EXCEPTION 'slr: ok' USING ERRCODE = 'SLR03';
    EXCEPTION
      WHEN SQLSTATE 'SLR03' THEN NULL;
      WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
        PERFORM pg_temp.slr_fail(format('(g) control positivo del CHECK: type=%s debía poder insertarse y falló: %s', v_type, v_txt));
    END;
  END LOOP;

  -- El CHECK existe, es NOT VALID (las filas históricas sin motivo no se validan) y se explica en un COMMENT.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stock_movements'::regclass
                    AND conname = 'stock_movements_manual_needs_reason') THEN
    PERFORM pg_temp.slr_fail('(g) no existe el CHECK stock_movements_manual_needs_reason');
  ELSE
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stock_movements'::regclass
                      AND conname = 'stock_movements_manual_needs_reason' AND convalidated = false) THEN
      PERFORM pg_temp.slr_fail('(g) el CHECK stock_movements_manual_needs_reason debía quedar NOT VALID (convalidated = false) por las 18 filas históricas sin motivo de prod');
    END IF;
    IF (SELECT obj_description(oid, 'pg_constraint') FROM pg_constraint
         WHERE conrelid = 'public.stock_movements'::regclass AND conname = 'stock_movements_manual_needs_reason') IS NULL THEN
      PERFORM pg_temp.slr_fail('(g) el CHECK debe llevar un COMMENT que explique por qué es NOT VALID (un mantenedor futuro no debe intentar VALIDATE)');
    END IF;
  END IF;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (g): motivo nulo/vacío/espacios rechazado con P0400 en los tres envoltorios (% intentos) y persistido recortado; CHECK stock_movements_manual_needs_reason rechaza 5 tipos x 4 motivos inválidos, acepta los controles positivos, es NOT VALID y lleva COMMENT.', v_n_ok;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (h) Flags internos de rpc_apply_product_stock_delta
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  FOR c IN
    SELECT * FROM (VALUES
      ('p_log_movement = false',          'false, false'),
      ('p_allow_negative = true',         'true, true'),
      ('ambos internos',                  'false, true'),
      ('p_log_movement NULL',             'NULL, false'),
      ('p_allow_negative NULL',           'true, NULL')
    ) AS t(label, flags)
  LOOP
    v_tot0 := pg_temp.slr_total(v_pf);
    v_nm0  := pg_temp.slr_nmov(v_pf);
    v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr h', %s)$q$, v_pf, c.flags));
    IF NOT pg_temp.slr_is_err(v_r, 'P0400', 'stock_internal_flags_not_allowed') THEN
      PERFORM pg_temp.slr_fail(format('(h) %s: se esperaba P0400 stock_internal_flags_not_allowed y salió %s', c.label, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    ELSIF pg_temp.slr_total(v_pf) <> v_tot0 OR pg_temp.slr_nmov(v_pf) <> v_nm0 THEN
      PERFORM pg_temp.slr_fail(format('(h) %s: el rechazo cambió saldo o movimientos', c.label));
    END IF;
  END LOOP;
  -- El piso en cero (delta negativo con p_allow_negative = true) tampoco es alcanzable.
  v_tot0 := pg_temp.slr_total(v_pf);
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_apply_product_stock_delta(%L, -100000, NULL, 'gate slr h', true, true)$q$, v_pf));
  IF NOT pg_temp.slr_is_err(v_r, 'P0400', 'stock_internal_flags_not_allowed') THEN
    PERFORM pg_temp.slr_fail(format('(h) el piso en cero (p_allow_negative = true) debía ser inalcanzable y salió %s', COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
  ELSIF pg_temp.slr_total(v_pf) <> v_tot0 THEN
    PERFORM pg_temp.slr_fail('(h) el intento de piso en cero cambió el saldo');
  END IF;
  -- Control positivo: la combinación del backend (true, false) y los defaults funcionan con la forma de respuesta conservada.
  v_r  := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr h', true, false)$q$, v_pf));
  v_r2 := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr h')$q$, v_pf));
  IF v_r ? 'error' OR v_r2 ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(h) control positivo: (true, false) y los defaults debían funcionar: %s / %s', v_r->>'error', v_r2->>'error'));
  ELSIF NOT (v_r ?& ARRAY['product_id', 'branch_id', 'quantity_before', 'quantity_after', 'quantity_delta', 'floored'])
        OR (v_r->>'floored') IS DISTINCT FROM 'false'
        OR (v_r->>'quantity_after')::numeric <> (v_r->>'quantity_before')::numeric + 1 THEN
    PERFORM pg_temp.slr_fail(format('(h) la respuesta de rpc_apply_product_stock_delta cambió de forma: %s', v_r));
  END IF;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (h): p_log_movement <> true y p_allow_negative <> false rechazados con P0400 sin tocar saldo ni ledger; (true, false) y los defaults siguen funcionando con la misma forma de respuesta.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (i) Tenencia por products.account_id
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  FOR c IN
    SELECT * FROM (VALUES
      ('rpc_stock_adjustment',
       format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', 'gate slr i', NULL, NULL, NULL)$q$, v_pb)),
      ('rpc_adjust_branch_stock',
       format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, 5, 'gate slr i')$q$, v_pb, v_xa)),
      ('rpc_apply_product_stock_delta',
       format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr i', true, false)$q$, v_pb)),
      ('rpc_transfer_stock',
       format($q$SELECT public.rpc_transfer_stock(%L, %L, %L, 1)$q$, v_pb, v_xa, v_xa2))
    ) AS t(label, sql)
  LOOP
    v_r := pg_temp.slr_rpc(v_owner_a, c.sql);
    IF NOT pg_temp.slr_is_err(v_r, 'P0404') THEN
      PERFORM pg_temp.slr_fail(format('(i) %s sobre un producto de OTRA cuenta: se esperaba P0404 y salió %s', c.label, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    END IF;
    SELECT count(*) INTO v_n FROM public.branch_stock WHERE product_id = v_pb;
    SELECT count(*) INTO v_n2 FROM public.stock_movements WHERE product_id = v_pb;
    IF v_n <> 0 OR v_n2 <> 0 THEN
      PERFORM pg_temp.slr_fail(format('(i) %s sobre un producto ajeno dejó %s filas de saldo y %s movimientos (debían ser 0 / 0)', c.label, v_n, v_n2));
    END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM public.stock_transfers WHERE product_id = v_pb;
  IF v_n <> 0 THEN
    PERFORM pg_temp.slr_fail(format('(i) rpc_transfer_stock sobre un producto ajeno dejó %s transferencias (debían ser 0)', v_n));
  END IF;
  -- Control positivo: un segundo miembro `admin` que NO creó el producto lo ajusta por los tres envoltorios.
  FOR w IN 1..3 LOOP
    v_tot0 := pg_temp.slr_total(v_pi);
    v_nm0  := pg_temp.slr_nmov(v_pi);
    v_sql := CASE w
      WHEN 1 THEN format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', 'gate slr i', NULL, NULL, NULL)$q$, v_pi)
      WHEN 2 THEN format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, %s, 'gate slr i')$q$, v_pi, v_xa, pg_temp.slr_stock(v_pi, v_xa) + 1)
      ELSE        format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'gate slr i', true, false)$q$, v_pi)
    END;
    v_r := pg_temp.slr_rpc(v_admin, v_sql);
    IF v_r ? 'error' OR pg_temp.slr_total(v_pi) <> v_tot0 + 1 OR pg_temp.slr_nmov(v_pi) <> v_nm0 + 1 THEN
      PERFORM pg_temp.slr_fail(format('(i) el miembro admin (que no creó el producto) debía poder ajustarlo por el envoltorio %s y salió %s', w, COALESCE(v_r->>'error', 'sin error pero sin +1 de saldo / +1 movimiento')));
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (i): producto de otra cuenta P0404 en los tres envoltorios y en rpc_transfer_stock sin filas nuevas; un segundo miembro admin ajusta un producto que no creó.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) Sello e invariante
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  v_nm0 := pg_temp.slr_nmov(v_pj);
  v_r := pg_temp.slr_rpc(v_stock, format($q$SELECT public.rpc_stock_adjustment(%L, 2, 'adjustment', '  rótulo j  ', 'nota j', NULL, NULL)$q$, v_pj));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(j) el ajuste del rol stock falló: %s', v_r->>'error'));
  ELSE
    SELECT * INTO v_mv FROM public.stock_movements WHERE id = (v_r->>'movement_id')::uuid;
    IF pg_temp.slr_nmov(v_pj) <> v_nm0 + 1 THEN
      PERFORM pg_temp.slr_fail(format('(j) un ajuste debía dejar EXACTAMENTE un movimiento y dejó %s', pg_temp.slr_nmov(v_pj) - v_nm0));
    END IF;
    IF v_mv.account_id IS DISTINCT FROM v_acc_a OR v_mv.branch_id IS DISTINCT FROM v_xa
       OR v_mv.user_id IS DISTINCT FROM v_stock OR v_mv.performed_by IS DISTINCT FROM v_stock THEN
      PERFORM pg_temp.slr_fail(format('(j) sello incorrecto: account_id=%s (A=%s) branch_id=%s (default=%s) user_id=%s performed_by=%s (autor=%s)',
                                      v_mv.account_id, v_acc_a, v_mv.branch_id, v_xa, v_mv.user_id, v_mv.performed_by, v_stock));
    END IF;
    IF v_mv.reason IS DISTINCT FROM 'rótulo j' OR v_mv.notes IS DISTINCT FROM 'nota j'
       OR v_mv.type IS DISTINCT FROM 'adjustment' OR v_mv.reference_type IS NOT NULL THEN
      PERFORM pg_temp.slr_fail(format('(j) reason=%L notes=%L type=%L reference_type=%L (se esperaba rótulo j / nota j / adjustment / NULL)',
                                      v_mv.reason, v_mv.notes, v_mv.type, v_mv.reference_type));
    END IF;
    -- Antes/después a nivel SUCURSAL (la cuenta tiene dos): 10 -> 12, no 13 -> 15.
    IF v_mv.quantity_before IS DISTINCT FROM 10 OR v_mv.quantity_after IS DISTINCT FROM 12 OR v_mv.quantity_delta IS DISTINCT FROM 2 THEN
      PERFORM pg_temp.slr_fail(format('(j) antes/después a nivel sucursal: se esperaba 10 -> 12 (delta 2) y es %s -> %s (delta %s)',
                                      v_mv.quantity_before, v_mv.quantity_after, v_mv.quantity_delta));
    END IF;
    IF pg_temp.slr_stock(v_pj, v_xa) <> 12 OR pg_temp.slr_stock(v_pj, v_xa2) <> 3 THEN
      PERFORM pg_temp.slr_fail(format('(j) branch_stock debía quedar 12 / 3 y es %s / %s', pg_temp.slr_stock(v_pj, v_xa), pg_temp.slr_stock(v_pj, v_xa2)));
    END IF;
    IF NOT (v_r ?& ARRAY['movement_id', 'product_id', 'product_name', 'quantity_before', 'quantity_after', 'quantity_delta', 'type'])
       OR (v_r->>'quantity_before')::numeric <> 10 OR (v_r->>'quantity_after')::numeric <> 12 OR (v_r->>'type') <> 'adjustment' THEN
      PERFORM pg_temp.slr_fail(format('(j) la respuesta de rpc_stock_adjustment cambió de forma o de valores: %s', v_r));
    END IF;
    -- Visible bajo RLS para su cuenta y no para otra.
    PERFORM pg_temp.slr_as(v_stock);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM public.stock_movements WHERE id = v_mv.id;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.slr_as(v_owner_b);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n2 FROM public.stock_movements WHERE id = v_mv.id;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.slr_as(NULL);
    IF v_n <> 1 OR v_n2 <> 0 THEN
      PERFORM pg_temp.slr_fail(format('(j) visibilidad bajo RLS: la cuenta dueña debía verlo (vio %s) y la ajena no (vio %s)', v_n, v_n2));
    END IF;
  END IF;

  -- Stock inicial del alta (la combinación del backend): motivo fijo "Stock inicial", sellado.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_apply_product_stock_delta(%L, 12, NULL, 'Stock inicial', true, false)$q$, v_pj2));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(j) el stock inicial del owner falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pj2);
    IF pg_temp.slr_stock(v_pj2, v_xa) <> 12 OR v_mv.type IS DISTINCT FROM 'adjustment' OR v_mv.reason IS DISTINCT FROM 'Stock inicial'
       OR v_mv.account_id IS DISTINCT FROM v_acc_a OR v_mv.branch_id IS DISTINCT FROM v_xa
       OR v_mv.user_id IS DISTINCT FROM v_owner_a OR v_mv.performed_by IS DISTINCT FROM v_owner_a
       OR v_mv.quantity_before IS DISTINCT FROM 0 OR v_mv.quantity_after IS DISTINCT FROM 12 THEN
      PERFORM pg_temp.slr_fail(format('(j) stock inicial: saldo=%s type=%L reason=%L account=%s branch=%s before=%s after=%s',
                                      pg_temp.slr_stock(v_pj2, v_xa), v_mv.type, v_mv.reason, v_mv.account_id, v_mv.branch_id,
                                      v_mv.quantity_before, v_mv.quantity_after));
    END IF;
  END IF;

  -- Cuenta SIN sucursales: la sucursal que crea c21 perezosamente queda en el movimiento.
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE account_id = v_acc_c) THEN
    v_r := pg_temp.slr_rpc(v_owner_c, format($q$SELECT public.rpc_stock_adjustment(%L, 5, 'adjustment', 'alta perezosa', NULL, NULL, NULL)$q$, v_pc));
    IF v_r ? 'error' THEN
      PERFORM pg_temp.slr_fail(format('(j) el ajuste en una cuenta sin sucursales falló: %s', v_r->>'error'));
    ELSE
      v_mv := pg_temp.slr_last_mv(v_pc);
      IF v_mv.branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_mv.branch_id AND account_id = v_acc_c)
         OR pg_temp.slr_stock(v_pc, v_mv.branch_id) <> 5 THEN
        PERFORM pg_temp.slr_fail(format('(j) cuenta sin sucursales: el movimiento debía sellar la sucursal creada perezosamente y tiene branch_id=%s (saldo %s)',
                                        v_mv.branch_id, CASE WHEN v_mv.branch_id IS NULL THEN NULL ELSE pg_temp.slr_stock(v_pc, v_mv.branch_id) END));
      END IF;
    END IF;
  ELSE
    RAISE NOTICE 'info (j): la cuenta C conserva sucursales — se omite el chequeo de alta perezosa.';
  END IF;

  -- Invariante global sobre los productos del gate: todo ajuste manual deja cuenta, sucursal, autor,
  -- motivo y after = before + delta (a nivel sucursal).
  SELECT count(*) INTO v_n FROM public.stock_movements m
   WHERE m.product_id = ANY (v_prods)
     AND m.type IN ('adjustment', 'physical_count', 'loss', 'damage', 'expiry')
     AND (m.account_id IS NULL OR m.branch_id IS NULL OR m.user_id IS NULL OR m.performed_by IS NULL
          OR btrim(COALESCE(m.reason, '')) = ''
          OR m.quantity_after IS DISTINCT FROM m.quantity_before + m.quantity_delta);
  IF v_n <> 0 THEN
    PERFORM pg_temp.slr_fail(format('(j) %s movimientos manuales de la fixture sin cuenta/sucursal/autor/motivo o con after <> before + delta', v_n));
  END IF;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (j): un ajuste = exactamente un movimiento sellado (cuenta, sucursal, autor, motivo recortado), antes/después a nivel sucursal, visible bajo RLS sólo para su cuenta; stock inicial con motivo fijo; alta perezosa de la sucursal sellada; invariante after = before + delta en todos los ajustes del gate.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (k) Semántica del movimiento (cuenta de DOS sucursales: PK = 10 / 3)
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);

  -- k1: conteo físico TOTAL (el modal de /stock): objetivo 20 sobre un total de 13 => +7 en la default.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, NULL, 'physical_count', 'conteo k1', NULL, NULL, 20)$q$, v_pk));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(k1) el conteo físico total falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pk);
    IF v_mv.type IS DISTINCT FROM 'physical_count' OR v_mv.quantity_delta IS DISTINCT FROM 7
       OR v_mv.quantity_before IS DISTINCT FROM 10 OR v_mv.quantity_after IS DISTINCT FROM 17 OR v_mv.branch_id IS DISTINCT FROM v_xa
       OR pg_temp.slr_stock(v_pk, v_xa) <> 17 OR pg_temp.slr_stock(v_pk, v_xa2) <> 3 OR pg_temp.slr_total(v_pk) <> 20 THEN
      PERFORM pg_temp.slr_fail(format('(k1) conteo físico total 13 -> 20: type=%s delta=%s before=%s after=%s branch=%s saldos=%s/%s total=%s (se esperaba physical_count +7, 10 -> 17 en la default, 3 en la otra, total 20)',
                                      v_mv.type, v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after, v_mv.branch_id,
                                      pg_temp.slr_stock(v_pk, v_xa), pg_temp.slr_stock(v_pk, v_xa2), pg_temp.slr_total(v_pk)));
    END IF;
  END IF;

  -- k2: objetivo POR SUCURSAL (inventario de /sucursales): fija la cantidad absoluta de esa sucursal.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, 8, 'k2 motivo')$q$, v_pk, v_xa2));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(k2) el ajuste por sucursal falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pk);
    IF NOT (v_r ?& ARRAY['product_id', 'branch_id', 'old_quantity', 'new_quantity'])
       OR (v_r->>'old_quantity')::numeric <> 3 OR (v_r->>'new_quantity')::numeric <> 8 OR (v_r->>'branch_id')::uuid <> v_xa2 THEN
      PERFORM pg_temp.slr_fail(format('(k2) la respuesta de rpc_adjust_branch_stock cambió: %s', v_r));
    END IF;
    IF v_mv.type IS DISTINCT FROM 'adjustment' OR v_mv.branch_id IS DISTINCT FROM v_xa2 OR v_mv.quantity_before IS DISTINCT FROM 3
       OR v_mv.quantity_after IS DISTINCT FROM 8 OR v_mv.quantity_delta IS DISTINCT FROM 5
       OR v_mv.reason IS DISTINCT FROM 'k2 motivo' OR v_mv.notes IS NOT NULL
       OR pg_temp.slr_stock(v_pk, v_xa2) <> 8 OR pg_temp.slr_stock(v_pk, v_xa) <> 17 THEN
      PERFORM pg_temp.slr_fail(format('(k2) objetivo por sucursal 3 -> 8: type=%s branch=%s before=%s after=%s delta=%s reason=%L notes=%L saldos=%s/%s (el motivo va en reason, no en notes)',
                                      v_mv.type, v_mv.branch_id, v_mv.quantity_before, v_mv.quantity_after, v_mv.quantity_delta, v_mv.reason, v_mv.notes,
                                      pg_temp.slr_stock(v_pk, v_xa), pg_temp.slr_stock(v_pk, v_xa2)));
    END IF;
  END IF;

  -- k3: pérdida (resta) y notas; loss/damage/expiry POSITIVOS rechazados.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, -2, 'loss', 'rotura k3', 'nota k3', NULL, NULL)$q$, v_pk));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(k3) la pérdida de 2 falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pk);
    IF v_mv.type IS DISTINCT FROM 'loss' OR v_mv.quantity_delta IS DISTINCT FROM -2 OR v_mv.quantity_before IS DISTINCT FROM 17
       OR v_mv.quantity_after IS DISTINCT FROM 15 OR v_mv.notes IS DISTINCT FROM 'nota k3' OR pg_temp.slr_stock(v_pk, v_xa) <> 15 THEN
      PERFORM pg_temp.slr_fail(format('(k3) pérdida de 2 sobre 17: type=%s delta=%s before=%s after=%s notes=%L saldo=%s', v_mv.type, v_mv.quantity_delta,
                                      v_mv.quantity_before, v_mv.quantity_after, v_mv.notes, pg_temp.slr_stock(v_pk, v_xa)));
    END IF;
  END IF;
  FOREACH v_type IN ARRAY ARRAY['loss', 'damage', 'expiry'] LOOP
    v_tot0 := pg_temp.slr_total(v_pk);
    v_nm0  := pg_temp.slr_nmov(v_pk);
    v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, 2, %L, 'k3 positivo', NULL, NULL, NULL)$q$, v_pk, v_type));
    IF NOT pg_temp.slr_is_err(v_r, 'P0400') OR pg_temp.slr_total(v_pk) <> v_tot0 OR pg_temp.slr_nmov(v_pk) <> v_nm0 THEN
      PERFORM pg_temp.slr_fail(format('(k3) %s con delta POSITIVO: se esperaba P0400 sin cambios y salió %s', v_type, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    END IF;
  END LOOP;

  -- k4: tipos fuera del ajuste manual (OQ-1: la transferencia tiene su propia entidad).
  FOREACH v_type IN ARRAY ARRAY['transfer_in', 'transfer_out', 'sale', 'bogus'] LOOP
    v_tot0 := pg_temp.slr_total(v_pk);
    v_nm0  := pg_temp.slr_nmov(v_pk);
    v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, 1, %L, 'k4', NULL, NULL, NULL)$q$, v_pk, v_type));
    IF NOT pg_temp.slr_is_err(v_r, 'P0400', 'stock_adjustment_type_invalid') OR pg_temp.slr_total(v_pk) <> v_tot0 OR pg_temp.slr_nmov(v_pk) <> v_nm0 THEN
      PERFORM pg_temp.slr_fail(format('(k4) tipo %L: se esperaba P0400 stock_adjustment_type_invalid sin cambios y salió %s', v_type, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    END IF;
  END LOOP;

  -- k5: negativos y parámetros inválidos.
  FOR c IN
    SELECT * FROM (VALUES
      ('delta -1000 (resultado negativo en la sucursal)',
       format($q$SELECT public.rpc_stock_adjustment(%L, -1000, 'adjustment', 'k5', NULL, NULL, NULL)$q$, v_pk), 'P0409'),
      ('objetivo negativo',
       format($q$SELECT public.rpc_stock_adjustment(%L, NULL, 'physical_count', 'k5', NULL, NULL, -1)$q$, v_pk), 'P0400'),
      ('sin delta ni objetivo',
       format($q$SELECT public.rpc_stock_adjustment(%L, NULL, 'adjustment', 'k5', NULL, NULL, NULL)$q$, v_pk), 'P0400'),
      ('delta cero sin objetivo',
       format($q$SELECT public.rpc_stock_adjustment(%L, 0, 'adjustment', 'k5', NULL, NULL, NULL)$q$, v_pk), 'P0400'),
      ('adjust_branch_stock con cantidad negativa',
       format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, -3, 'k5')$q$, v_pk, v_xa), 'P0400')
    ) AS t(label, sql, expected)
  LOOP
    v_tot0 := pg_temp.slr_total(v_pk);
    v_nm0  := pg_temp.slr_nmov(v_pk);
    v_r := pg_temp.slr_rpc(v_owner_a, c.sql);
    IF NOT pg_temp.slr_is_err(v_r, c.expected) OR pg_temp.slr_total(v_pk) <> v_tot0 OR pg_temp.slr_nmov(v_pk) <> v_nm0 THEN
      PERFORM pg_temp.slr_fail(format('(k5) %s: se esperaba %s sin cambios y salió %s', c.label, c.expected, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    END IF;
  END LOOP;

  -- k6: conteo total que excede lo que hay en la default (xa = 15, xa2 = 8, total 23): objetivo 0 => -23 > 15.
  v_tot0 := pg_temp.slr_total(v_pk);
  v_nm0  := pg_temp.slr_nmov(v_pk);
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, NULL, 'physical_count', 'k6', NULL, NULL, 0)$q$, v_pk));
  IF NOT pg_temp.slr_is_err(v_r, 'P0409') OR pg_temp.slr_total(v_pk) <> v_tot0 OR pg_temp.slr_nmov(v_pk) <> v_nm0 THEN
    PERFORM pg_temp.slr_fail(format('(k6) conteo total a 0 con el stock repartido: se esperaba P0409 sin cambios y salió %s', COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
  END IF;
  -- ...y uno que SÍ cabe en la default (total 23 -> 18 => -5 sobre 15 = 10).
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, NULL, 'physical_count', 'k6b', NULL, NULL, 18)$q$, v_pk));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(k6b) el conteo total 23 -> 18 debía caber en la default y falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pk);
    IF v_mv.quantity_delta IS DISTINCT FROM -5 OR v_mv.quantity_before IS DISTINCT FROM 15 OR v_mv.quantity_after IS DISTINCT FROM 10
       OR pg_temp.slr_total(v_pk) <> 18 THEN
      PERFORM pg_temp.slr_fail(format('(k6b) conteo total 23 -> 18: delta=%s before=%s after=%s total=%s (se esperaba -5, 15 -> 10, total 18)',
                                      v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after, pg_temp.slr_total(v_pk)));
    END IF;
  END IF;

  -- k7: padre variant_only (RN-20) por los tres caminos.
  FOR w IN 1..3 LOOP
    v_sql := CASE w
      WHEN 1 THEN format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', 'k7', NULL, NULL, NULL)$q$, v_pv)
      WHEN 2 THEN format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, 5, 'k7')$q$, v_pv, v_xa)
      ELSE        format($q$SELECT public.rpc_apply_product_stock_delta(%L, 1, NULL, 'k7', true, false)$q$, v_pv)
    END;
    v_r := pg_temp.slr_rpc(v_owner_a, v_sql);
    IF NOT pg_temp.slr_is_err(v_r, 'P0400', 'stock_adjustment_product_not_adjustable')
       OR pg_temp.slr_nstock_rows(v_pv) <> 0 OR pg_temp.slr_nmov(v_pv) <> 0 THEN
      PERFORM pg_temp.slr_fail(format('(k7) padre variant_only por el envoltorio %s: se esperaba P0400 stock_adjustment_product_not_adjustable sin crear saldo y salió %s', w, COALESCE(v_r->>'error', 'el intento PROSPERÓ')));
    END IF;
  END LOOP;

  -- k8: p_reference_id => reference_type 'adjustment'.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_stock_adjustment(%L, 1, 'adjustment', 'k8', NULL, %L, NULL)$q$, v_pk, v_ref));
  IF v_r ? 'error' THEN
    PERFORM pg_temp.slr_fail(format('(k8) el ajuste con p_reference_id falló: %s', v_r->>'error'));
  ELSE
    v_mv := pg_temp.slr_last_mv(v_pk);
    IF v_mv.reference_id IS DISTINCT FROM v_ref OR v_mv.reference_type IS DISTINCT FROM 'adjustment' THEN
      PERFORM pg_temp.slr_fail(format('(k8) reference_id=%s reference_type=%L (se esperaba el id dado y adjustment)', v_mv.reference_id, v_mv.reference_type));
    END IF;
  END IF;

  -- k9: objetivo IGUAL al saldo (delta 0) deja constancia del conteo.
  v_nm0 := pg_temp.slr_nmov(v_pk);
    v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_adjust_branch_stock(%L, %L, %s, 'k9 constancia')$q$,
                                              v_pk, v_xa, pg_temp.slr_stock(v_pk, v_xa)));
    IF v_r ? 'error' THEN
      PERFORM pg_temp.slr_fail(format('(k9) el ajuste con objetivo igual al saldo falló: %s', v_r->>'error'));
    ELSE
      v_mv := pg_temp.slr_last_mv(v_pk);
      IF pg_temp.slr_nmov(v_pk) <> v_nm0 + 1 OR v_mv.quantity_delta IS DISTINCT FROM 0 OR v_mv.quantity_before IS DISTINCT FROM v_mv.quantity_after THEN
        PERFORM pg_temp.slr_fail(format('(k9) objetivo = saldo: debía registrar 1 movimiento con delta 0 y registró %s (delta %s)', pg_temp.slr_nmov(v_pk) - v_nm0, v_mv.quantity_delta));
      END IF;
    END IF;

  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (k): conteo físico total, objetivo por sucursal, pérdida, loss/damage/expiry positivos P0400, transfer_in/out y tipos ajenos P0400, negativos P0409/P0400, padre variant_only P0400, reference_id y objetivo = saldo.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (l) Reversa tras la reescritura: venta, compra y compra ya vendida
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);

  -- l1: venta y borrado.
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_pl1, v_xa, 20);
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_sale_operation(%L, %L, CURRENT_DATE, 'ARS',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-b-sale-' || gen_random_uuid()::text, v_client, v_pl1, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(l1) el alta de la venta falló: %s', v_r));
  ELSE
    v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_sale_operation(NULL, %L, %L))', v_op, 'gate slr l1'));
    SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_pl1 AND type = 'sale_return';
    IF v_r2 IS DISTINCT FROM 'true'::jsonb OR pg_temp.slr_stock(v_pl1, v_xa) <> 20 THEN
      PERFORM pg_temp.slr_fail(format('(l1) borrar la venta debía devolver true y reponer a 20 y dio %s / saldo %s', v_r2, pg_temp.slr_stock(v_pl1, v_xa)));
    ELSIF v_mv.id IS NULL OR v_mv.quantity_delta IS DISTINCT FROM 2 OR v_mv.quantity_before IS DISTINCT FROM 18 OR v_mv.quantity_after IS DISTINCT FROM 20
          OR v_mv.reference_type IS DISTINCT FROM 'sale_reversal' OR v_mv.account_id IS DISTINCT FROM v_acc_a OR v_mv.branch_id IS DISTINCT FROM v_xa
          OR v_mv.user_id IS DISTINCT FROM v_owner_a OR v_mv.performed_by IS DISTINCT FROM v_owner_a
          OR btrim(COALESCE(v_mv.reason, '')) = '' OR (v_mv.metadata->>'reverses_movement_id') IS NULL THEN
      PERFORM pg_temp.slr_fail(format('(l1) contramovimiento de la venta: delta=%s before=%s after=%s ref=%L account=%s branch=%s autor=%s/%s reason=%L reverses=%L',
                                      v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after, v_mv.reference_type, v_mv.account_id,
                                      v_mv.branch_id, v_mv.user_id, v_mv.performed_by, v_mv.reason, v_mv.metadata->>'reverses_movement_id'));
    END IF;
  END IF;

  -- l2: compra y borrado.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_purchase_operation(%L, CURRENT_DATE, 'Compra gate SLR B',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 50.00, 'quantity', 5, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-b-purch-' || gen_random_uuid()::text, v_pl2, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(l2) el alta de la compra falló: %s', v_r));
  ELSE
    v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_purchase_operation(NULL, %L, %L))', v_op, 'gate slr l2'));
    SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_pl2 AND type = 'purchase_return';
    IF v_r2 IS DISTINCT FROM 'true'::jsonb OR pg_temp.slr_stock(v_pl2, v_xa) <> 0 THEN
      PERFORM pg_temp.slr_fail(format('(l2) borrar la compra debía devolver true y dejar el saldo en 0 y dio %s / saldo %s', v_r2, pg_temp.slr_stock(v_pl2, v_xa)));
    ELSIF v_mv.id IS NULL OR v_mv.quantity_delta IS DISTINCT FROM -5 OR v_mv.reference_type IS DISTINCT FROM 'purchase_reversal'
          OR v_mv.account_id IS DISTINCT FROM v_acc_a OR v_mv.branch_id IS DISTINCT FROM v_xa
          OR btrim(COALESCE(v_mv.reason, '')) = '' OR (v_mv.metadata->>'reverses_movement_id') IS NULL THEN
      PERFORM pg_temp.slr_fail(format('(l2) contramovimiento de la compra: delta=%s ref=%L account=%s branch=%s reason=%L', v_mv.quantity_delta, v_mv.reference_type,
                                      v_mv.account_id, v_mv.branch_id, v_mv.reason));
    END IF;
  END IF;

  -- l3: compra YA VENDIDA (compra 5, vende 3, borra la compra) => piso en cero trazable con motivo.
  v_r := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_purchase_operation(%L, CURRENT_DATE, 'Compra gate SLR B (vendida)',
            jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 50.00, 'quantity', 5, 'unit_id', NULL)), %L, NULL)$q$,
            'slr-b-purch2-' || gen_random_uuid()::text, v_pl3, v_xa));
  v_op := (v_r->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    PERFORM pg_temp.slr_fail(format('(l3) el alta de la compra falló: %s', v_r));
  ELSE
    v_r2 := pg_temp.slr_rpc(v_owner_a, format($q$SELECT public.rpc_create_sale_operation(%L, %L, CURRENT_DATE, 'ARS',
              jsonb_build_array(jsonb_build_object('product_id', %L, 'amount', 90.00, 'quantity', 3, 'unit_id', NULL)), %L, NULL)$q$,
              'slr-b-sale2-' || gen_random_uuid()::text, v_client, v_pl3, v_xa));
    IF (v_r2->>'operation_id') IS NULL THEN
      PERFORM pg_temp.slr_fail(format('(l3) la venta de 3 sobre la compra falló: %s', v_r2));
    ELSE
      v_r2 := pg_temp.slr_rpc(v_owner_a, format('SELECT to_jsonb(public.rpc_delete_purchase_operation(NULL, %L, %L))', v_op, 'gate slr l3'));
      SELECT * INTO v_mv FROM public.stock_movements
       WHERE product_id = v_pl3 AND type = 'adjustment' AND reason = 'floor_on_purchase_delete';
      IF v_r2 IS DISTINCT FROM 'true'::jsonb OR pg_temp.slr_stock(v_pl3, v_xa) <> 0 THEN
        PERFORM pg_temp.slr_fail(format('(l3) borrar la compra ya vendida debía devolver true y dejar el saldo en 0 (piso) y dio %s / saldo %s', v_r2, pg_temp.slr_stock(v_pl3, v_xa)));
      ELSIF v_mv.id IS NULL OR v_mv.quantity_delta IS DISTINCT FROM -2 OR v_mv.quantity_before IS DISTINCT FROM 2 OR v_mv.quantity_after IS DISTINCT FROM 0
            OR v_mv.account_id IS DISTINCT FROM v_acc_a OR v_mv.branch_id IS DISTINCT FROM v_xa
            OR v_mv.user_id IS DISTINCT FROM v_owner_a OR v_mv.performed_by IS DISTINCT FROM v_owner_a THEN
        PERFORM pg_temp.slr_fail(format('(l3) el ajuste de piso debía ser -2 (2 -> 0) sellado con cuenta, sucursal y autor: delta=%s before=%s after=%s account=%s branch=%s autor=%s/%s',
                                        v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after, v_mv.account_id, v_mv.branch_id, v_mv.user_id, v_mv.performed_by));
      END IF;
      SELECT * INTO v_mv FROM public.stock_movements WHERE product_id = v_pl3 AND type = 'purchase_return';
      IF v_mv.id IS NULL OR v_mv.quantity_delta IS DISTINCT FROM -2 OR v_mv.quantity_before IS DISTINCT FROM 2 OR v_mv.quantity_after IS DISTINCT FROM 0
         OR v_mv.reference_type IS DISTINCT FROM 'purchase_reversal' OR (v_mv.metadata->>'reverses_movement_id') IS NULL THEN
        -- el contramovimiento registra lo EFECTIVAMENTE aplicado tras el piso (-2), no los -5 de la compra
        PERFORM pg_temp.slr_fail(format('(l3) el contramovimiento purchase_return de una compra ya vendida registra lo efectivamente aplicado: se esperaba -2 (2 -> 0) y es delta=%s before=%s after=%s', v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after));
      END IF;
    END IF;
  END IF;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (l): borrar venta y compra repone con contramovimiento sellado (cuenta, sucursal, autor, motivo, reverses_movement_id); compra ya vendida => ajuste de piso trazable con motivo.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (m, parte con fixture) Las internas NO son invocables por authenticated
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  FOR c IN
    SELECT * FROM (VALUES
      ('_stock_manual_adjustment',
       format($q$SELECT public._stock_manual_adjustment(%L, NULL, 'adjustment', 1, NULL, 'total', 'gate slr m', NULL, NULL)$q$, v_pf)),
      ('_stock_apply_delta',
       format($q$SELECT public._stock_apply_delta(%L, %L, 1, NULL, false)$q$, v_acc_a, v_pf)),
      ('_stock_assert_can_adjust',
       format($q$SELECT public._stock_assert_can_adjust(%L)$q$, v_acc_a)),
      ('rpc_reverse_stock_movement',
       format($q$SELECT public.rpc_reverse_stock_movement(%L, 'sale', 'gate slr m')$q$, gen_random_uuid()))
    ) AS t(label, sql)
  LOOP
    v_txt := pg_temp.slr_try(v_owner_a, 'authenticated', c.sql, v_accs, v_prods, v_users);
    IF v_txt NOT LIKE 'DENIED|permission denied for function%' THEN
      PERFORM pg_temp.slr_fail(format('(m) %s invocada por un owner autenticado: se esperaba 42501 "permission denied for function" y salió: %s', c.label, v_txt));
    END IF;
    v_txt := pg_temp.slr_try(NULL, 'anon', c.sql, v_accs, v_prods, v_users);
    IF v_txt NOT LIKE 'DENIED|permission denied for function%' THEN
      PERFORM pg_temp.slr_fail(format('(m) %s invocada por anon: se esperaba 42501 "permission denied for function" y salió: %s', c.label, v_txt));
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (m, ejecución): las tres internas y la reversa rechazan la llamada directa de un owner autenticado y de anon con 42501 "permission denied for function".';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g, migración) re-crear el CHECK NOT VALID con una fila histórica sin motivo presente
  --   (va AL FINAL: toca el DDL de stock_movements dentro de la transacción del gate)
  -- ═══════════════════════════════════════════════════════════════════════
  v_f0 := (SELECT count(*) FROM pg_temp.slr_fail);
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conrelid = 'public.stock_movements'::regclass AND conname = 'stock_movements_manual_needs_reason';
  IF v_def IS NOT NULL THEN
    BEGIN
      SET CONSTRAINTS ALL IMMEDIATE;
      ALTER TABLE public.stock_movements DROP CONSTRAINT stock_movements_manual_needs_reason;
      INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                          quantity_delta, quantity_before, quantity_after, reason, branch_id, performed_by)
      VALUES (v_owner_a, v_acc_a, v_pf, 'Gate SLR B PF', 'adjustment', 0, 10, 10, NULL, v_xa, v_owner_a)
      RETURNING id INTO v_legacy;
      EXECUTE 'ALTER TABLE public.stock_movements ADD CONSTRAINT stock_movements_manual_needs_reason ' || v_def;
      IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE id = v_legacy AND reason IS NULL) THEN
        PERFORM pg_temp.slr_fail('(g) la fila histórica sin motivo no se conservó tal cual');
      END IF;
      BEGIN
        INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type,
                                            quantity_delta, quantity_before, quantity_after, reason, branch_id, performed_by)
        VALUES (v_owner_a, v_acc_a, v_pf, 'Gate SLR B PF', 'adjustment', 0, 10, 10, NULL, v_xa, v_owner_a);
        RAISE EXCEPTION 'slr: el CHECK re-creado no rechazó' USING ERRCODE = 'SLR02';
      EXCEPTION
        WHEN check_violation THEN NULL;
        WHEN SQLSTATE 'SLR02' THEN
          PERFORM pg_temp.slr_fail('(g) re-creado el CHECK con una fila histórica presente, no rechazó una inserción nueva sin motivo');
      END;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
      PERFORM pg_temp.slr_fail(format('(g) re-crear el CHECK NOT VALID con una fila histórica sin motivo falló: %s', v_txt));
    END;
  END IF;
  IF v_def IS NOT NULL AND (SELECT count(*) FROM pg_temp.slr_fail) = v_f0 THEN
    RAISE NOTICE 'PASS (g, migración): el mismo DDL del CHECK NOT VALID se aplica sobre una tabla con una fila histórica sin motivo, la conserva y rechaza las nuevas.';
  END IF;
END $$;


-- ── (m) ACL de las internas y de los envoltorios (metadata) ─────────────────
DO $$
DECLARE
  v_internal  constant text[] := ARRAY[
    'public._stock_assert_can_adjust(uuid)',
    'public._stock_apply_delta(uuid,uuid,numeric,uuid,boolean)',
    'public._stock_manual_adjustment(uuid,uuid,text,numeric,numeric,text,text,text,uuid)',
    'public.rpc_reverse_stock_movement(uuid,text,text)'];
  v_invoker   constant text[] := ARRAY[
    'public._stock_assert_can_adjust(uuid)',
    'public._stock_apply_delta(uuid,uuid,numeric,uuid,boolean)',
    'public._stock_manual_adjustment(uuid,uuid,text,numeric,numeric,text,text,text,uuid)'];
  v_public    constant text[] := ARRAY[
    'public.rpc_stock_adjustment(uuid,numeric,text,text,text,uuid,numeric)',
    'public.rpc_adjust_branch_stock(uuid,uuid,numeric,text)',
    'public.rpc_apply_product_stock_delta(uuid,numeric,uuid,text,boolean,boolean)',
    'public.rpc_transfer_stock(uuid,uuid,uuid,numeric)'];
  v_fn        text;
  v_oid       oid;
  v_bad       text[] := '{}';
  v_cfg       text[];
BEGIN
  FOREACH v_fn IN ARRAY v_internal LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN
      v_bad := v_bad || format('%s no existe con esa firma', v_fn);
      CONTINUE;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN v_bad := v_bad || format('anon tiene EXECUTE sobre %s', v_fn); END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN v_bad := v_bad || format('authenticated tiene EXECUTE sobre %s', v_fn); END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) a WHERE p.oid = v_oid AND a.grantee = 0) THEN
      v_bad := v_bad || format('PUBLIC tiene EXECUTE sobre %s', v_fn);
    END IF;
    IF NOT has_function_privilege('postgres', v_oid, 'EXECUTE') THEN v_bad := v_bad || format('postgres perdió EXECUTE de %s', v_fn); END IF;
  END LOOP;

  -- Las tres internas nuevas son SECURITY INVOKER con search_path fijo (si alguien les re-otorgara
  -- EXECUTE por error, igual fallarían al escribir: la tanda A le quitó la escritura a authenticated).
  FOREACH v_fn IN ARRAY v_invoker LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NOT NULL THEN
      IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        v_bad := v_bad || format('%s debía ser SECURITY INVOKER', v_fn);
      END IF;
      SELECT proconfig INTO v_cfg FROM pg_proc WHERE oid = v_oid;
      IF v_cfg IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_cfg) x WHERE x LIKE 'search_path=%') THEN
        v_bad := v_bad || format('%s sin search_path fijo', v_fn);
      END IF;
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY v_public LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN
      v_bad := v_bad || format('%s no existe con esa firma', v_fn);
      CONTINUE;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN v_bad := v_bad || format('%s dejó de ser SECURITY DEFINER', v_fn); END IF;
    SELECT proconfig INTO v_cfg FROM pg_proc WHERE oid = v_oid;
    IF v_cfg IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_cfg) x WHERE x LIKE 'search_path=%') THEN
      v_bad := v_bad || format('%s sin search_path fijo', v_fn);
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN v_bad := v_bad || format('authenticated PERDIÓ EXECUTE de %s', v_fn); END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN v_bad := v_bad || format('anon tiene EXECUTE sobre %s', v_fn); END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) a WHERE p.oid = v_oid AND a.grantee = 0) THEN
      v_bad := v_bad || format('PUBLIC tiene EXECUTE sobre %s', v_fn);
    END IF;
  END LOOP;

  -- Un solo overload de cada una (candado contra un DROP/CREATE futuro que deje dos).
  FOREACH v_fn IN ARRAY ARRAY['rpc_stock_adjustment', 'rpc_adjust_branch_stock', 'rpc_apply_product_stock_delta',
                              'rpc_transfer_stock', 'rpc_reverse_stock_movement', '_stock_assert_can_adjust',
                              '_stock_apply_delta', '_stock_manual_adjustment'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE proname = v_fn AND pronamespace = 'public'::regnamespace) <> 1 THEN
      v_bad := v_bad || format('%s no tiene exactamente una definición', v_fn);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    PERFORM pg_temp.slr_fail('(m) ' || array_to_string(v_bad, '; '));
  ELSE
    RAISE NOTICE 'PASS (m): las tres internas nuevas (INVOKER, search_path fijo) y la reversa sin EXECUTE para anon/authenticated/PUBLIC; los tres envoltorios y rpc_transfer_stock SECURITY DEFINER con EXECUTE para authenticated y sin anon; un solo overload de cada función.';
  END IF;
END $$;


-- ── Veredicto ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM pg_temp.slr_fail;
  IF v_n > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-LEDGER-SOLO-RPC FAILED (% fallas):\n  %', v_n,
      (SELECT string_agg(msg, E'\n  ' ORDER BY id) FROM pg_temp.slr_fail);
  END IF;
  RAISE NOTICE 'GATE STOCK-LEDGER-SOLO-RPC PASSED (tandas A y B): privilegios, policies, ACL, matriz de evasión, caminos legítimos, rol, motivo, flags internos, tenencia, sello, semántica del movimiento y reversa.';
END $$;

ROLLBACK;

-- Residuo cero ASERTADO fuera de la transacción: el ROLLBACK no dejó nada.
DO $$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL AND EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'slr-gate-%@test.local') THEN
    RAISE EXCEPTION 'GATE STOCK-LEDGER-SOLO-RPC FAILED (residuo): quedaron usuarios del gate';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE product_name LIKE 'Gate SLR%')
     OR EXISTS (SELECT 1 FROM public.products WHERE sku LIKE 'SLR-P%' OR sku LIKE 'SLRB-P%') THEN
    RAISE EXCEPTION 'GATE STOCK-LEDGER-SOLO-RPC FAILED (residuo): quedaron filas del gate';
  END IF;
  RAISE NOTICE 'PASS (residuo): el gate no dejó filas.';
END $$;
