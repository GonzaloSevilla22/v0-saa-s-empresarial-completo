-- =============================================================================
-- GATE: test_stock_ledger_solo_rpc.sql
-- CHANGE: stock-ledger-solo-rpc — TANDA A (migración
--         20261073000001_stock_ledger_cierre_escritura_directa.sql)
--         (governance ALTA: ledger de stock + revocación de privilegios;
--          PO 2026-10-08: "arrancá la tanda A")
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
-- Corre en CI: KPI_Validation.yml ("Run stock ledger solo RPC gate").
-- La TANDA B extiende este archivo con los bloques (f)-(m) (rol, motivo,
-- tenencia, núcleo de ajuste).
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
  RAISE NOTICE 'GATE STOCK-LEDGER-SOLO-RPC PASSED (tanda A): privilegios, policies, ACL de la reversa, matriz de evasión y caminos legítimos.';
END $$;

ROLLBACK;

-- Residuo cero ASERTADO fuera de la transacción: el ROLLBACK no dejó nada.
DO $$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL AND EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'slr-gate-%@test.local') THEN
    RAISE EXCEPTION 'GATE STOCK-LEDGER-SOLO-RPC FAILED (residuo): quedaron usuarios del gate';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE product_name LIKE 'Gate SLR%')
     OR EXISTS (SELECT 1 FROM public.products WHERE sku LIKE 'SLR-P%') THEN
    RAISE EXCEPTION 'GATE STOCK-LEDGER-SOLO-RPC FAILED (residuo): quedaron filas del gate';
  END IF;
  RAISE NOTICE 'PASS (residuo): el gate no dejó filas.';
END $$;
