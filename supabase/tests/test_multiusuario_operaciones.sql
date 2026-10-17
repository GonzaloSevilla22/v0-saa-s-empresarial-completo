-- =============================================================================
-- GATE: test_multiusuario_operaciones.sql
-- CHANGE: multiusuario-operativo — TANDA B (tasks 8.1-8.4, 9.3, 9.4)
--
-- Ejercita de verdad, como `authenticated` con `request.jwt.claims` armado a
-- mano (el mismo mecanismo que PostgREST y que `get_db_conn` de FastAPI), que
-- las OCHO RPCs del camino del dinero de ventas y compras autorizan por
-- PERTENENCIA A LA CUENTA ACTIVA Y ROL, nunca por el autor del producto ni del
-- documento:
--
--   rpc_create_sale_operation / _v2              alta de venta por formulario
--   rpc_create_purchase_operation / _v2          alta de compra (el núcleo
--                                                _purchase_operation_core lleva el guard de producto)
--   rpc_atomic_update_sale_operation             edición de venta
--   rpc_atomic_update_purchase_operation         edición de compra
--   rpc_delete_sale_operation                    borrado de venta
--   rpc_delete_purchase_operation                borrado de compra
--
--   EL HUECO (auditoría de stock del 2026-10-14, humo S20, R3a-R3l). Seis de las
--   ocho comparaban `products.user_id` / `sales.user_id` / `purchases.user_id`
--   contra `auth.uid()`: era el ÚNICO guard de tenencia del producto, y un
--   invitado (vendedor, administrador, compras) no podía vender ni comprar un
--   producto que cargó el dueño (R3a, R3b, R3g), ni el dueño corregir una venta
--   del vendedor (R3d, R3f). Y las ocho NO tenían ningún guard de rol en SQL: un
--   observador (`viewer`) que tuviera un producto propio vendía igual. Hoy nada
--   de eso pasa porque no existe ningún miembro además del dueño.
--
--   EL ARREGLO (design.md D8, D9). El producto se toma con
--   `AND account_id = v_account_id` dentro del MISMO `SELECT … FOR UPDATE` (P0404
--   indistinguible de un id inexistente); el documento se verifica contra la
--   cuenta; el rol lo decide `_account_assert_capability` (alta: CAN_SELL /
--   CAN_PURCHASE; viewer = P0401, rol sin la capacidad = P0403); y sobre un
--   documento AJENO sólo puede dueño o administrador (OQ-4 b).
--
-- Fixtures (todos @test.local, dentro de BEGIN..ROLLBACK: residuo cero). Cada
-- usuario tiene además su cuenta personal (la crea `handle_new_user`): el claim
-- `app_metadata.account_id` declara la cuenta A, como hace el hook en producción.
--   O  dueño de A                      AD administrador      S  vendedor
--   C  cajero                          ST depósito           PU compras
--   AC contador                        V  observador         M  vendedor + compras
--   X  ex-miembro de A (token vigente) Z  dueño de B (cuenta ajena)
--
-- Estructura: cada bloque corre en su sub-bloque con EXCEPTION y registra su
-- falla en vez de abortar (el RED 8.4 muestra de una vez QUÉ bloques fallan); al
-- final, si hubo alguna, el gate aborta listándolas.
--
--   (a) alta de venta, matriz de roles, por las DOS firmas públicas
--   (b) alta de compra, matriz de roles (el depósito NO compra: OQ-3)
--   (a2) el observador no vende, no compra, no edita ni borra (el hueco del patrón F)
--   (c) tenencia en el alta: producto de otra cuenta / de la cuenta no activa,
--       claim revocado, servicio sin producto (R3l), idempotencia
--   (d) edición de venta: dueño y admin sobre lo ajeno; el resto sólo lo propio;
--       la autoría se CONSERVA; otra cuenta = P0404
--   (e) borrado de venta, misma matriz
--   (f) edición de compra
--   (g) borrado de compra
--   (h) rama legacy (kill-switch sale_items_rpc_v2 = false) de rpc_create_sale_operation
--   (i) rpc_create_purchase_operation_v2 (sin EXECUTE para authenticated)
--   (j) CANDADO DE CUERPO de las 9 funciones (sin guard por autor; el guard de rol
--       antes de la primera escritura; el filtro de cuenta DENTRO del FOR UPDATE)
--   (k) ESTRUCTURAL: helpers sin EXECUTE para los roles de aplicación, ACLs de las
--       8 intactas, una definición viva por función, COMMENT
-- =============================================================================

BEGIN;

-- ── Helpers (sesión; viven en pg_temp) ───────────────────────────────────────

CREATE FUNCTION pg_temp.as_user(p_user uuid, p_account text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
  v jsonb := jsonb_build_object('sub', p_user::text, 'role', 'authenticated');
BEGIN
  IF p_account IS NOT NULL THEN
    v := v || jsonb_build_object('app_metadata', jsonb_build_object('account_id', p_account));
  END IF;
  PERFORM set_config('request.jwt.claims', v::text, true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $f$;

-- Corre una expresión de RPC como `authenticated`. NUNCA lanza: devuelve estado/mensaje.
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
  RESET ROLE;
END $f$;

-- Lo mismo pero como el dueño de las funciones (para las que no tienen EXECUTE
-- para `authenticated`): las funciones DEFINER leen auth.uid() de los claims.
CREATE FUNCTION pg_temp.try_rpc_priv(p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE format('SELECT to_jsonb(%s)', p_expr) INTO o_res;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
END $f$;

-- Impersona y corre.
CREATE FUNCTION pg_temp.run(p_user uuid, p_account uuid, p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account::text);
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try_rpc(p_expr) t;
END $f$;

CREATE FUNCTION pg_temp.items(p_prod uuid, p_qty numeric, p_amount numeric DEFAULT 100) RETURNS jsonb
LANGUAGE sql AS $f$
  SELECT jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('product_id', p_prod, 'amount', p_amount, 'quantity', p_qty)))
$f$;

-- Expresiones de RPC (texto). Las firmas son las vivas de producción.
CREATE FUNCTION pg_temp.e_sale(p_fn text, p_key text, p_items jsonb, p_date date) RETURNS text
LANGUAGE sql AS $f$
  SELECT format('public.%I(%L, NULL::uuid, %L::date, ''ARS'', %L::jsonb)', p_fn, p_key, p_date, p_items::text)
$f$;
CREATE FUNCTION pg_temp.e_purchase(p_fn text, p_key text, p_items jsonb, p_date date) RETURNS text
LANGUAGE sql AS $f$
  SELECT format('public.%I(%L, %L::date, ''gate'', %L::jsonb)', p_fn, p_key, p_date, p_items::text)
$f$;
CREATE FUNCTION pg_temp.e_edit_sale(p_ids uuid[], p_items jsonb, p_date date) RETURNS text
LANGUAGE sql AS $f$
  SELECT format('public.rpc_atomic_update_sale_operation(%L::uuid[], NULL::uuid, %L::date, ''ARS'', %L::jsonb)', p_ids::text, p_date, p_items::text)
$f$;
CREATE FUNCTION pg_temp.e_edit_purchase(p_ids uuid[], p_items jsonb, p_date date) RETURNS text
LANGUAGE sql AS $f$
  SELECT format('public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''gate'', %L::jsonb)', p_ids::text, p_date, p_items::text)
$f$;
CREATE FUNCTION pg_temp.e_del_sale(p_op uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_delete_sale_operation(NULL::uuid, %L::uuid, NULL::text)', p_op) $f$;
CREATE FUNCTION pg_temp.e_del_purchase(p_op uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_delete_purchase_operation(NULL::uuid, %L::uuid, NULL::text)', p_op) $f$;

CREATE FUNCTION pg_temp.stock(p_prod uuid) RETURNS numeric
LANGUAGE sql AS $f$ SELECT COALESCE(SUM(quantity), 0) FROM public.branch_stock WHERE product_id = p_prod $f$;

CREATE FUNCTION pg_temp.sale_ids(p_op uuid) RETURNS uuid[]
LANGUAGE sql AS $f$ SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::uuid[]) FROM public.sales WHERE operation_id = p_op $f$;
CREATE FUNCTION pg_temp.purchase_ids(p_op uuid) RETURNS uuid[]
LANGUAGE sql AS $f$ SELECT COALESCE(array_agg(id ORDER BY id), ARRAY[]::uuid[]) FROM public.purchases WHERE operation_id = p_op $f$;

-- Huella de los efectos de las dos cuentas del gate: si un rechazo deja una fila, un
-- movimiento, una clave de idempotencia o mueve el stock, la huella cambia.
CREATE FUNCTION pg_temp.eff(p_a uuid, p_b uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.sales WHERE account_id IN (p_a, p_b)),
    (SELECT count(*) FROM public.purchases WHERE account_id IN (p_a, p_b)),
    (SELECT count(*) FROM public.stock_movements WHERE account_id IN (p_a, p_b)),
    (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id IN (p_a, p_b)),
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches br ON br.id = cb.branch_id
      WHERE br.account_id IN (p_a, p_b)),
    (SELECT count(*) FROM public.events WHERE account_id IN (p_a, p_b)),
    (SELECT count(*) FROM public.operation_idempotency WHERE operation_id IN (SELECT operation_id FROM public.sales WHERE account_id IN (p_a, p_b) UNION SELECT operation_id FROM public.purchases WHERE account_id IN (p_a, p_b))))
$f$;

-- Expectativa: lanza si el estado/mensaje no es el esperado. p_state = 'ok' => sin error.
CREATE FUNCTION pg_temp.expect(p_label text, p_state text, p_msg text, p_exp text, p_like text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_exp = 'ok' THEN
    IF p_state <> '00000' THEN
      RAISE EXCEPTION '% debía funcionar, dio % %', p_label, p_state, p_msg;
    END IF;
  ELSE
    IF p_state <> p_exp THEN
      RAISE EXCEPTION '% debía dar %, dio % %', p_label, p_exp, p_state, COALESCE(p_msg, '(sin error)');
    END IF;
    IF p_like IS NOT NULL AND COALESCE(p_msg, '') NOT ILIKE '%' || p_like || '%' THEN
      RAISE EXCEPTION '% dio % pero el mensaje % no contiene %', p_label, p_state, p_msg, p_like;
    END IF;
  END IF;
END $f$;

-- Quita los uuid del mensaje, para comparar "producto ajeno" con "producto inexistente".
CREATE FUNCTION pg_temp.noid(p_msg text) RETURNS text
LANGUAGE sql IMMUTABLE AS $f$
  SELECT regexp_replace(COALESCE(p_msg, ''), '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<id>', 'g')
$f$;

-- ═════════════════════════════════════════════════════════════════════════════
DO $gate$
DECLARE
  v_fail   text[] := ARRAY[]::text[];
  v_blk    text;
  v_today  date := public.reporting_local_today();

  -- Usuarios
  v_o  uuid := gen_random_uuid();  v_ad uuid := gen_random_uuid();  v_s  uuid := gen_random_uuid();
  v_c  uuid := gen_random_uuid();  v_st uuid := gen_random_uuid();  v_pu uuid := gen_random_uuid();
  v_ac uuid := gen_random_uuid();  v_v  uuid := gen_random_uuid();  v_m  uuid := gen_random_uuid();
  v_x  uuid := gen_random_uuid();  v_z  uuid := gen_random_uuid();
  -- Cuentas
  v_a  uuid;  v_b uuid;  v_ps uuid;   -- A (negocio), B (ajena), personal de S

  v_member uuid;
  -- Productos
  v_pa1 uuid;  v_pa_v uuid;  v_pa_s uuid;  v_pb uuid;
  v_branch_a uuid;  v_branch_b uuid;

  -- Matriz
  v_actors uuid[];  v_labels text[];
  v_exp_sale text[] := ARRAY['ok','ok','ok','ok','P0403','P0403','P0401'];
  v_exp_purch text[] := ARRAY['ok','ok','P0403','P0403','P0403','P0403','P0401'];
  v_fns text[] := ARRAY['rpc_create_sale_operation','rpc_create_sale_operation_v2'];
  v_fn  text;
  i integer;

  v_r record;  v_r2 record;
  v_op uuid;  v_op2 uuid;
  v_ids uuid[];
  v_s0 numeric;  v_s1 numeric;
  v_eff0 text;  v_eff1 text;
  v_n integer;
  v_txt text;
  v_acc uuid;
  v_uid uuid;
  v_ghost uuid := gen_random_uuid();
  v_msg_b text;  v_msg_ghost text;

  -- Operaciones de partida (creadas por las RPCs, como las crearía la aplicación)
  v_sop_o uuid;  v_sop_s uuid;  v_sop_c uuid;  v_sop_b uuid;
  v_pop_o uuid;  v_pop_pu uuid;  v_pop_b uuid;
BEGIN
  -- ── Fixtures ───────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_o,  'authenticated', 'authenticated', 'mu-b-owner@test.local',      now(), now(), '{"name":"MUB Dueno"}'::jsonb),
    (v_ad, 'authenticated', 'authenticated', 'mu-b-admin@test.local',      now(), now(), '{"name":"MUB Admin"}'::jsonb),
    (v_s,  'authenticated', 'authenticated', 'mu-b-seller@test.local',     now(), now(), '{"name":"MUB Vendedor"}'::jsonb),
    (v_c,  'authenticated', 'authenticated', 'mu-b-cashier@test.local',    now(), now(), '{"name":"MUB Cajero"}'::jsonb),
    (v_st, 'authenticated', 'authenticated', 'mu-b-stock@test.local',      now(), now(), '{"name":"MUB Deposito"}'::jsonb),
    (v_pu, 'authenticated', 'authenticated', 'mu-b-purchases@test.local',  now(), now(), '{"name":"MUB Compras"}'::jsonb),
    (v_ac, 'authenticated', 'authenticated', 'mu-b-accountant@test.local', now(), now(), '{"name":"MUB Contador"}'::jsonb),
    (v_v,  'authenticated', 'authenticated', 'mu-b-viewer@test.local',     now(), now(), '{"name":"MUB Observador"}'::jsonb),
    (v_m,  'authenticated', 'authenticated', 'mu-b-multirol@test.local',   now(), now(), '{"name":"MUB Multirol"}'::jsonb),
    (v_x,  'authenticated', 'authenticated', 'mu-b-exmember@test.local',   now(), now(), '{"name":"MUB Ex"}'::jsonb),
    (v_z,  'authenticated', 'authenticated', 'mu-b-zeta@test.local',       now(), now(), '{"name":"MUB Zeta"}'::jsonb);

  SELECT account_id INTO v_a  FROM public.account_members WHERE user_id = v_o;
  SELECT account_id INTO v_b  FROM public.account_members WHERE user_id = v_z;
  SELECT account_id INTO v_ps FROM public.account_members WHERE user_id = v_s;
  IF v_a IS NULL OR v_b IS NULL OR v_ps IS NULL THEN
    RAISE EXCEPTION 'GATE MULTIUSUARIO-OPERACIONES (fixture): handle_new_user no creó la cuenta de algún usuario sintético (a=%, b=%, ps=%).', v_a, v_b, v_ps;
  END IF;

  -- Miembros de A, cada uno con su rol en el pivot (el singular lo deriva el trigger).
  FOR v_uid, v_txt IN VALUES (v_ad, 'admin'), (v_s, 'seller'), (v_c, 'cashier'), (v_st, 'stock'),
                             (v_pu, 'purchases'), (v_ac, 'accountant'), (v_v, 'viewer'), (v_x, 'seller')
  LOOP
    INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_a, v_uid, 'member') RETURNING id INTO v_member;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_member, v_txt);
  END LOOP;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_a, v_m, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_member, 'seller'), (v_a, v_member, 'purchases');
  -- X fue miembro y lo quitaron: su token (claim = A) sigue vigente.
  DELETE FROM public.account_members WHERE account_id = v_a AND user_id = v_x;

  v_actors := ARRAY[v_o, v_ad, v_s, v_c, v_st, v_ac, v_v];
  v_labels := ARRAY['dueño','admin','vendedor','cajero','depósito','contador','observador'];
  -- Para la matriz de compra el orden es el mismo; el vendedor y el cajero NO compran.

  v_branch_a := public.c26_default_branch(v_a);
  v_branch_b := public.c26_default_branch(v_b);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_o, v_a, 'GATE-MUB-A1', 'GATE-MUB-A1', 40, 100) RETURNING id INTO v_pa1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_v, v_a, 'GATE-MUB-AV', 'GATE-MUB-AV', 40, 100) RETURNING id INTO v_pa_v;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_s, v_a, 'GATE-MUB-AS', 'GATE-MUB-AS', 40, 100) RETURNING id INTO v_pa_s;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_z, v_b, 'GATE-MUB-B1', 'GATE-MUB-B1', 40, 100) RETURNING id INTO v_pb;
  PERFORM public.c21_apply_branch_stock_delta(v_a, v_pa1,  v_branch_a, 500);
  PERFORM public.c21_apply_branch_stock_delta(v_a, v_pa_v, v_branch_a, 500);
  PERFORM public.c21_apply_branch_stock_delta(v_a, v_pa_s, v_branch_a, 500);
  PERFORM public.c21_apply_branch_stock_delta(v_b, v_pb,   v_branch_b, 500);

  -- ── (a) Alta de venta por formulario: matriz de roles, por las DOS firmas ───
  v_blk := '(a) alta de venta';
  BEGIN
    FOREACH v_fn IN ARRAY v_fns LOOP
      FOR i IN 1..array_length(v_actors, 1) LOOP
        v_s0 := pg_temp.stock(v_pa1);
        v_eff0 := pg_temp.eff(v_a, v_b);
        SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a,
          pg_temp.e_sale(v_fn, format('gate-mub-a-%s-%s', v_fn, i), pg_temp.items(v_pa1, 2), v_today));
        PERFORM pg_temp.expect(format('%s (%s) vende un producto DEL DUEÑO por %s', v_labels[i], v_actors[i], v_fn),
                               v_r.o_state, v_r.o_msg, v_exp_sale[i],
                               CASE v_exp_sale[i] WHEN 'P0403' THEN 'insufficient_role' WHEN 'P0401' THEN 'unauthorized' END);
        IF v_exp_sale[i] = 'ok' THEN
          v_op := (v_r.o_res ->> 'operation_id')::uuid;
          SELECT account_id, user_id INTO v_acc, v_uid FROM public.sales WHERE operation_id = v_op LIMIT 1;
          IF v_acc IS DISTINCT FROM v_a OR v_uid IS DISTINCT FROM v_actors[i] THEN
            RAISE EXCEPTION '% (%): la venta debía quedar en A (%) con el actor como autor (%); quedó en % con autor %', v_labels[i], v_fn, v_a, v_actors[i], v_acc, v_uid;
          END IF;
          IF pg_temp.stock(v_pa1) <> v_s0 - 2 THEN
            RAISE EXCEPTION '% (%): el stock debía bajar 2 (era %, es %)', v_labels[i], v_fn, v_s0, pg_temp.stock(v_pa1);
          END IF;
        ELSE
          IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN
            RAISE EXCEPTION '% (%): un rechazo dejó efectos (antes %, después %)', v_labels[i], v_fn, v_eff0, pg_temp.eff(v_a, v_b);
          END IF;
        END IF;
      END LOOP;
    END LOOP;

    -- El multirol (vendedor + compras) vende; el vendedor vende un producto cargado por OTRO miembro que no es el dueño.
    SELECT * INTO v_r FROM pg_temp.run(v_m, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-a-m', pg_temp.items(v_pa_s, 1), v_today));
    PERFORM pg_temp.expect('el multirol vende un producto del vendedor', v_r.o_state, v_r.o_msg, 'ok');
    -- CONTROL de no regresión: el vendedor vende su PROPIO producto.
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-a-own', pg_temp.items(v_pa_s, 1), v_today));
    PERFORM pg_temp.expect('el vendedor vende su propio producto', v_r.o_state, v_r.o_msg, 'ok');
    -- EL HUECO (patrón F): el observador con un producto PROPIO (la fila existe por un alta directa) NO vende.
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-a-viewer-own', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador vende un producto PROPIO', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    RAISE NOTICE 'PASS (a): vender un producto del dueño lo logran dueño/admin/vendedor/cajero/multirol; depósito y contador P0403; observador P0401 (aun con producto propio), sin efectos.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (b) Alta de compra: matriz de roles ─────────────────────────────────────
  v_blk := '(b) alta de compra';
  BEGIN
    FOR i IN 1..array_length(v_actors, 1) LOOP
      v_s0 := pg_temp.stock(v_pa1);
      v_eff0 := pg_temp.eff(v_a, v_b);
      SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a,
        pg_temp.e_purchase('rpc_create_purchase_operation', format('gate-mub-b-%s', i), pg_temp.items(v_pa1, 3), v_today));
      PERFORM pg_temp.expect(format('%s (%s) compra un producto DEL DUEÑO', v_labels[i], v_actors[i]),
                             v_r.o_state, v_r.o_msg, v_exp_purch[i],
                             CASE v_exp_purch[i] WHEN 'P0403' THEN 'insufficient_role' WHEN 'P0401' THEN 'unauthorized' END);
      IF v_exp_purch[i] = 'ok' THEN
        v_op := (v_r.o_res ->> 'operation_id')::uuid;
        SELECT account_id, user_id INTO v_acc, v_uid FROM public.purchases WHERE operation_id = v_op LIMIT 1;
        IF v_acc IS DISTINCT FROM v_a OR v_uid IS DISTINCT FROM v_actors[i] THEN
          RAISE EXCEPTION '% : la compra debía quedar en A con el actor como autor; quedó en % con autor %', v_labels[i], v_acc, v_uid;
        END IF;
        IF pg_temp.stock(v_pa1) <> v_s0 + 3 THEN
          RAISE EXCEPTION '%: el stock debía subir 3 (era %, es %)', v_labels[i], v_s0, pg_temp.stock(v_pa1);
        END IF;
      ELSIF pg_temp.eff(v_a, v_b) <> v_eff0 THEN
        RAISE EXCEPTION '%: un rechazo dejó efectos (antes %, después %)', v_labels[i], v_eff0, pg_temp.eff(v_a, v_b);
      END IF;
    END LOOP;
    -- Compras (y el multirol) compran un producto cargado por OTRO miembro.
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-b-pu-s', pg_temp.items(v_pa_s, 1), v_today));
    PERFORM pg_temp.expect('compras compra un producto del vendedor', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r FROM pg_temp.run(v_m, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-b-m', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('el multirol (vendedor + compras) compra', v_r.o_state, v_r.o_msg, 'ok');
    -- EL HUECO: el observador con un producto propio no compra.
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-b-viewer-own', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador compra un producto PROPIO', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    RAISE NOTICE 'PASS (b): comprar un producto del dueño lo logran dueño/admin/compras/multirol; vendedor, cajero, depósito y contador P0403 (el depósito NO compra: OQ-3); observador P0401, sin efectos.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (c) Tenencia en el alta ─────────────────────────────────────────────────
  v_blk := '(c) tenencia en el alta';
  BEGIN
    -- Producto de OTRA cuenta (B) vendido / comprado desde A: P0404, el MISMO texto que un id inexistente.
    FOREACH v_fn IN ARRAY v_fns LOOP
      v_eff0 := pg_temp.eff(v_a, v_b);
      SELECT * INTO v_r  FROM pg_temp.run(v_s, v_a, pg_temp.e_sale(v_fn, 'gate-mub-c-b-' || v_fn, pg_temp.items(v_pb, 1), v_today));
      SELECT * INTO v_r2 FROM pg_temp.run(v_s, v_a, pg_temp.e_sale(v_fn, 'gate-mub-c-g-' || v_fn, pg_temp.items(v_ghost, 1), v_today));
      PERFORM pg_temp.expect('vender un producto de OTRA cuenta (' || v_fn || ')', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
      PERFORM pg_temp.expect('vender un producto inexistente (' || v_fn || ')',   v_r2.o_state, v_r2.o_msg, 'P0404', 'Product not found');
      IF pg_temp.noid(v_r.o_msg) IS DISTINCT FROM pg_temp.noid(v_r2.o_msg) THEN
        RAISE EXCEPTION '% : el rechazo de un producto ajeno (%) es DISTINGUIBLE del de uno inexistente (%)', v_fn, v_r.o_msg, v_r2.o_msg;
      END IF;
      IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN
        RAISE EXCEPTION '%: el rechazo del producto ajeno dejó efectos en alguna cuenta', v_fn;
      END IF;
    END LOOP;
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r  FROM pg_temp.run(v_pu, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-c-pb', pg_temp.items(v_pb, 1), v_today));
    SELECT * INTO v_r2 FROM pg_temp.run(v_pu, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-c-pg', pg_temp.items(v_ghost, 1), v_today));
    PERFORM pg_temp.expect('comprar un producto de OTRA cuenta', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    PERFORM pg_temp.expect('comprar un producto inexistente',    v_r2.o_state, v_r2.o_msg, 'P0404', 'Product not found');
    IF pg_temp.noid(v_r.o_msg) IS DISTINCT FROM pg_temp.noid(v_r2.o_msg) OR pg_temp.eff(v_a, v_b) <> v_eff0 THEN
      RAISE EXCEPTION 'comprar un producto ajeno: el rechazo es distinguible del de uno inexistente, o dejó efectos';
    END IF;

    -- El usuario de DOS cuentas (S) con su PERSONAL activa y un producto de la cuenta NO activa (A): P0404.
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_ps, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-c-na', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('vender con la personal activa un producto de la cuenta NO activa', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_ps, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-c-na2', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('comprar con la personal activa un producto de la cuenta NO activa', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    -- …y en la personal el usuario es dueño: el alta de un servicio funciona y queda en la personal.
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_ps, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-c-ps', jsonb_build_array(jsonb_build_object('amount', 50, 'quantity', 1)), v_today));
    PERFORM pg_temp.expect('el vendedor vende un servicio en su cuenta personal', v_r.o_state, v_r.o_msg, 'ok');
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = (v_r.o_res ->> 'operation_id')::uuid LIMIT 1;
    IF v_acc IS DISTINCT FROM v_ps THEN RAISE EXCEPTION 'la venta con la personal activa debía quedar en la personal (%), quedó en %', v_ps, v_acc; END IF;

    -- R3l: venta de SERVICIO (sin producto) con A activa: queda en A, no en la personal.
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-c-svc', jsonb_build_array(jsonb_build_object('amount', 50, 'quantity', 1)), v_today));
    PERFORM pg_temp.expect('R3l: venta de servicio con A activa', v_r.o_state, v_r.o_msg, 'ok');
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = (v_r.o_res ->> 'operation_id')::uuid LIMIT 1;
    IF v_acc IS DISTINCT FROM v_a THEN RAISE EXCEPTION 'R3l: la venta de servicio debía quedar en A (%), quedó en %', v_a, v_acc; END IF;

    -- Claim revocado (X fue quitado de A y su token sigue vigente) y cuenta nunca miembro (Z con claim A): sin cuenta activa.
    FOR v_uid IN SELECT unnest(ARRAY[v_x, v_z]) LOOP
      v_eff0 := pg_temp.eff(v_a, v_b);
      SELECT * INTO v_r FROM pg_temp.run(v_uid, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-c-rev-' || v_uid, pg_temp.items(v_pa1, 1), v_today));
      PERFORM pg_temp.expect('venta con un claim de una cuenta de la que NO es miembro', v_r.o_state, v_r.o_msg, 'P0403', 'sin cuenta activa');
      SELECT * INTO v_r FROM pg_temp.run(v_uid, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-c-revp-' || v_uid, pg_temp.items(v_pa1, 1), v_today));
      PERFORM pg_temp.expect('compra con un claim de una cuenta de la que NO es miembro', v_r.o_state, v_r.o_msg, 'P0403', 'sin cuenta activa');
      IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'el rechazo por claim revocado dejó efectos'; END IF;
    END LOOP;

    -- Idempotencia (CONTROL): el vendedor repite SU clave y recibe el replay, sin segunda venta ni segundo descuento.
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-c-idem', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('alta con clave nueva', v_r.o_state, v_r.o_msg, 'ok');
    v_s0 := pg_temp.stock(v_pa1);
    SELECT * INTO v_r2 FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-c-idem', pg_temp.items(v_pa1, 1), v_today));
    IF v_r2.o_state <> '00000' OR (v_r2.o_res ->> 'replayed')::boolean IS NOT TRUE
       OR v_r2.o_res ->> 'operation_id' <> v_r.o_res ->> 'operation_id' OR pg_temp.stock(v_pa1) <> v_s0 THEN
      RAISE EXCEPTION 'la repetición de la clave debía ser un replay sin efectos: % % %', v_r2.o_state, v_r2.o_msg, v_r2.o_res;
    END IF;
    RAISE NOTICE 'PASS (c): producto ajeno / de la cuenta no activa = P0404 indistinguible de un id inexistente; claim revocado = sin cuenta activa; R3l en A; replay intacto.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- Operaciones de partida para edición y borrado (creadas por las RPCs de alta, ya autorizadas por (a)/(b)).
  -- Si el alta falla acá, el bloque (a)/(b) ya lo dijo; estos IDs quedan NULL y los bloques siguientes lo reportan.
  SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-seed-so', pg_temp.items(v_pa1, 1), v_today));
  v_sop_o := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-seed-ss', pg_temp.items(v_pa_s, 1), v_today));
  v_sop_s := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_c, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-seed-sc', jsonb_build_array(jsonb_build_object('amount', 50, 'quantity', 1)), v_today));
  v_sop_c := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-seed-sb', pg_temp.items(v_pb, 1), v_today));
  v_sop_b := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-seed-po', pg_temp.items(v_pa1, 2), v_today));
  v_pop_o := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-seed-pp', jsonb_build_array(jsonb_build_object('amount', 50, 'quantity', 1)), v_today));
  v_pop_pu := (v_r.o_res ->> 'operation_id')::uuid;
  SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-seed-pb', pg_temp.items(v_pb, 2), v_today));
  v_pop_b := (v_r.o_res ->> 'operation_id')::uuid;

  -- ── (a2) EL HUECO DEL PATRÓN F: el observador no opera NADA ────────────────
  -- Aislado de (a)/(b) a propósito: antes de este change las ocho RPCs no tenían NINGÚN guard de
  -- rol en SQL, así que un observador con un producto propio vendía, compraba y borraba. El RED
  -- tiene que mostrarlo aunque los otros bloques ya fallen antes por el guard de autor.
  v_blk := '(a2) observador';
  BEGIN
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_sale('rpc_create_sale_operation_v2', 'gate-mub-a2-sv', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador vende un producto PROPIO', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-a2-pv', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador compra un producto PROPIO', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_del_sale(v_sop_o));
    PERFORM pg_temp.expect('el observador borra una venta', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_del_purchase(v_pop_o));
    PERFORM pg_temp.expect('el observador borra una compra', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_o), pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador edita una venta', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_o), pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('el observador edita una compra', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'los rechazos del observador dejaron efectos'; END IF;
    RAISE NOTICE 'PASS (a2): el observador no vende, no compra, no edita ni borra (P0401), aun con un producto propio, sin efectos.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (d) Edición de venta ────────────────────────────────────────────────────
  v_blk := '(d) edición de venta';
  BEGIN
    IF v_sop_o IS NULL OR v_sop_s IS NULL OR v_sop_c IS NULL OR v_sop_b IS NULL THEN
      RAISE EXCEPTION 'no se pudieron crear las ventas de partida (o=%, s=%, c=%, b=%)', v_sop_o, v_sop_s, v_sop_c, v_sop_b;
    END IF;

    -- R3d: el DUEÑO corrige la venta del VENDEDOR. La autoría se CONSERVA (el vendedor sigue siendo su autor).
    v_s0 := pg_temp.stock(v_pa_s);
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_s), pg_temp.items(v_pa_s, 4), v_today));
    PERFORM pg_temp.expect('R3d: el dueño edita la venta del vendedor', v_r.o_state, v_r.o_msg, 'ok');
    IF pg_temp.stock(v_pa_s) <> v_s0 - 3 THEN
      RAISE EXCEPTION 'R3d: el stock debía bajar 3 más (de 1 a 4 unidades): era %, es %', v_s0, pg_temp.stock(v_pa_s);
    END IF;
    v_sop_s := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT s.user_id INTO v_uid FROM public.sales s WHERE s.operation_id = v_sop_s LIMIT 1;
    IF v_uid IS DISTINCT FROM v_s THEN
      RAISE EXCEPTION 'la edición del dueño debía CONSERVAR al vendedor como autor (%), quedó %', v_s, v_uid;
    END IF;

    -- R3f: el ADMIN corrige la venta del DUEÑO.
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_o), pg_temp.items(v_pa1, 2), v_today));
    PERFORM pg_temp.expect('R3f: el admin edita la venta del dueño', v_r.o_state, v_r.o_msg, 'ok');
    v_sop_o := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT s.user_id INTO v_uid FROM public.sales s WHERE s.operation_id = v_sop_o LIMIT 1;
    IF v_uid IS DISTINCT FROM v_o THEN
      RAISE EXCEPTION 'la edición del admin debía CONSERVAR al dueño como autor (%), quedó %', v_o, v_uid;
    END IF;

    -- El vendedor corrige lo PROPIO (también tras la edición del dueño: sigue siendo su autor)…
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_s), pg_temp.items(v_pa_s, 2), v_today));
    PERFORM pg_temp.expect('el vendedor edita SU venta', v_r.o_state, v_r.o_msg, 'ok');
    v_sop_s := (v_r.o_res ->> 'operation_id')::uuid;

    -- …pero NO la del dueño ni la de un compañero: P0403, y la operación queda intacta.
    v_eff0 := pg_temp.eff(v_a, v_b);
    v_ids := pg_temp.sale_ids(v_sop_o);
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_edit_sale(v_ids, pg_temp.items(v_pa1, 9), v_today));
    PERFORM pg_temp.expect('el vendedor edita la venta del DUEÑO', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    SELECT * INTO v_r FROM pg_temp.run(v_c, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_s), pg_temp.items(v_pa_s, 9), v_today));
    PERFORM pg_temp.expect('el cajero edita la venta del VENDEDOR', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 OR pg_temp.sale_ids(v_sop_o) <> v_ids THEN
      RAISE EXCEPTION 'un rechazo por rol dejó efectos o cambió la operación';
    END IF;
    -- El cajero corrige LA SUYA.
    SELECT * INTO v_r FROM pg_temp.run(v_c, v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_c), pg_temp.items(v_pa1, 2), v_today));
    PERFORM pg_temp.expect('el cajero edita SU venta', v_r.o_state, v_r.o_msg, 'ok');
    v_sop_c := (v_r.o_res ->> 'operation_id')::uuid;

    -- Sin la capacidad de VENTA: el depósito y el contador (P0403); el observador (P0401).
    FOR i IN 5..7 LOOP
      SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_o), pg_temp.items(v_pa1, 1), v_today));
      PERFORM pg_temp.expect(v_labels[i] || ' edita una venta', v_r.o_state, v_r.o_msg, CASE i WHEN 7 THEN 'P0401' ELSE 'P0403' END);
    END LOOP;

    -- Documento de OTRA cuenta (B): P0404, el mismo error que un id inexistente, y B no cambia.
    v_eff0 := pg_temp.eff(v_a, v_b);
    v_ids := pg_temp.sale_ids(v_sop_b);
    SELECT * INTO v_r  FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_sale(v_ids, pg_temp.items(v_pa1, 1), v_today));
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_sale(ARRAY[v_ghost], pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('el DUEÑO de A edita una venta de B', v_r.o_state, v_r.o_msg, 'P0404');
    PERFORM pg_temp.expect('editar una venta inexistente', v_r2.o_state, v_r2.o_msg, 'P0404');
    IF v_r.o_msg IS DISTINCT FROM v_r2.o_msg THEN
      RAISE EXCEPTION 'editar una venta de otra cuenta (%) es DISTINGUIBLE de editar una inexistente (%)', v_r.o_msg, v_r2.o_msg;
    END IF;
    IF pg_temp.eff(v_a, v_b) <> v_eff0 OR pg_temp.sale_ids(v_sop_b) <> v_ids THEN RAISE EXCEPTION 'el rechazo por documento ajeno dejó efectos'; END IF;
    -- El usuario de dos cuentas con la PERSONAL activa tampoco edita una venta de A (la cuenta no activa).
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_ps, pg_temp.e_edit_sale(pg_temp.sale_ids(v_sop_s), pg_temp.items(v_pa_s, 1), v_today));
    PERFORM pg_temp.expect('editar una venta de la cuenta NO activa', v_r.o_state, v_r.o_msg, 'P0404');
    -- Un producto de B dentro de la edición de una venta de A: P0404 y A no cambia.
    v_ids := pg_temp.sale_ids(v_sop_o);
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_sale(v_ids, pg_temp.items(v_pb, 1), v_today));
    PERFORM pg_temp.expect('editar con un producto de OTRA cuenta', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 OR pg_temp.sale_ids(v_sop_o) <> v_ids THEN RAISE EXCEPTION 'editar con un producto ajeno dejó efectos'; END IF;
    RAISE NOTICE 'PASS (d): dueño y admin editan lo ajeno (la autoría se conserva); vendedor y cajero sólo lo propio (P0403); depósito/contador P0403; observador P0401; documento y producto de otra cuenta P0404.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (e) Borrado de venta ────────────────────────────────────────────────────
  v_blk := '(e) borrado de venta';
  BEGIN
    IF v_sop_o IS NULL OR v_sop_s IS NULL OR v_sop_c IS NULL THEN
      RAISE EXCEPTION 'faltan las ventas de partida (o=%, s=%, c=%)', v_sop_o, v_sop_s, v_sop_c;
    END IF;
    -- El vendedor NO borra la del dueño ni la del cajero: P0403, intactas.
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_del_sale(v_sop_o));
    PERFORM pg_temp.expect('el vendedor borra la venta del DUEÑO', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_del_sale(v_sop_c));
    PERFORM pg_temp.expect('el vendedor borra la venta del CAJERO', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'el rechazo por rol dejó efectos'; END IF;
    -- Sin capacidad de venta: depósito/contador P0403, observador P0401.
    FOR i IN 5..7 LOOP
      SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a, pg_temp.e_del_sale(v_sop_o));
      PERFORM pg_temp.expect(v_labels[i] || ' borra una venta', v_r.o_state, v_r.o_msg, CASE i WHEN 7 THEN 'P0401' ELSE 'P0403' END);
    END LOOP;
    IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'un rechazo por rol dejó efectos'; END IF;

    -- Documento de OTRA cuenta: se comporta como uno inexistente (false) y B queda intacta.
    v_ids := pg_temp.sale_ids(v_sop_b);
    SELECT * INTO v_r  FROM pg_temp.run(v_o, v_a, pg_temp.e_del_sale(v_sop_b));
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_del_sale(v_ghost));
    IF v_r.o_state <> '00000' OR v_r2.o_state <> '00000' OR v_r.o_res IS DISTINCT FROM v_r2.o_res OR v_r.o_res <> 'false'::jsonb THEN
      RAISE EXCEPTION 'borrar una venta de OTRA cuenta debía responder igual que una inexistente (false): % % / % %', v_r.o_state, v_r.o_res, v_r2.o_state, v_r2.o_res;
    END IF;
    IF pg_temp.sale_ids(v_sop_b) <> v_ids THEN RAISE EXCEPTION 'la venta de B fue tocada desde A'; END IF;

    -- El vendedor borra la PROPIA: repone el stock.
    v_s0 := pg_temp.stock(v_pa_s);
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_del_sale(v_sop_s));
    PERFORM pg_temp.expect('el vendedor borra SU venta', v_r.o_state, v_r.o_msg, 'ok');
    IF cardinality(pg_temp.sale_ids(v_sop_s)) <> 0 OR pg_temp.stock(v_pa_s) <> v_s0 + 2 THEN
      RAISE EXCEPTION 'el borrado propio debía quitar la venta y reponer 2 (stock era %, es %)', v_s0, pg_temp.stock(v_pa_s);
    END IF;
    -- R3e: el DUEÑO borra la del cajero; el ADMIN borra la del dueño.
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_del_sale(v_sop_c));
    PERFORM pg_temp.expect('R3e: el dueño borra la venta del cajero', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_del_sale(v_sop_o));
    PERFORM pg_temp.expect('el admin borra la venta del dueño', v_r.o_state, v_r.o_msg, 'ok');
    IF cardinality(pg_temp.sale_ids(v_sop_c)) <> 0 OR cardinality(pg_temp.sale_ids(v_sop_o)) <> 0 THEN
      RAISE EXCEPTION 'las ventas borradas por dueño/admin siguen existiendo';
    END IF;
    RAISE NOTICE 'PASS (e): dueño y admin borran lo ajeno; vendedor sólo lo propio (P0403 sobre lo ajeno); sin capacidad P0403/P0401; otra cuenta = false como un inexistente.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (f) Edición de compra ───────────────────────────────────────────────────
  v_blk := '(f) edición de compra';
  BEGIN
    IF v_pop_o IS NULL OR v_pop_pu IS NULL OR v_pop_b IS NULL THEN
      RAISE EXCEPTION 'no se pudieron crear las compras de partida (o=%, pu=%, b=%)', v_pop_o, v_pop_pu, v_pop_b;
    END IF;
    -- R3g/R3f: compras corrige la suya; el dueño y el admin corrigen la de compras; compras NO corrige la del dueño.
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_pu), pg_temp.items(v_pa_s, 5), v_today));
    PERFORM pg_temp.expect('el dueño edita la compra de compras', v_r.o_state, v_r.o_msg, 'ok');
    v_pop_pu := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT p.user_id INTO v_uid FROM public.purchases p WHERE p.operation_id = v_pop_pu LIMIT 1;
    IF v_uid IS DISTINCT FROM v_pu THEN RAISE EXCEPTION 'la edición del dueño debía CONSERVAR a compras como autor (%), quedó %', v_pu, v_uid; END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_o), pg_temp.items(v_pa1, 4), v_today));
    PERFORM pg_temp.expect('el admin edita la compra del dueño', v_r.o_state, v_r.o_msg, 'ok');
    v_pop_o := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_pu), pg_temp.items(v_pa_s, 3), v_today));
    PERFORM pg_temp.expect('compras edita LA SUYA', v_r.o_state, v_r.o_msg, 'ok');
    v_pop_pu := (v_r.o_res ->> 'operation_id')::uuid;

    v_eff0 := pg_temp.eff(v_a, v_b);
    v_ids := pg_temp.purchase_ids(v_pop_o);
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_edit_purchase(v_ids, pg_temp.items(v_pa1, 9), v_today));
    PERFORM pg_temp.expect('compras edita la compra del DUEÑO', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 OR pg_temp.purchase_ids(v_pop_o) <> v_ids THEN RAISE EXCEPTION 'un rechazo por rol dejó efectos'; END IF;
    -- Sin la capacidad de COMPRA: vendedor, cajero, depósito, contador P0403; observador P0401.
    FOR i IN 3..7 LOOP
      SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_o), pg_temp.items(v_pa1, 1), v_today));
      PERFORM pg_temp.expect(v_labels[i] || ' edita una compra', v_r.o_state, v_r.o_msg, CASE i WHEN 7 THEN 'P0401' ELSE 'P0403' END);
    END LOOP;
    -- Otra cuenta / cuenta no activa / producto ajeno.
    v_ids := pg_temp.purchase_ids(v_pop_b);
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r  FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_purchase(v_ids, pg_temp.items(v_pa1, 1), v_today));
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_purchase(ARRAY[v_ghost], pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('el dueño de A edita una compra de B', v_r.o_state, v_r.o_msg, 'P0404');
    PERFORM pg_temp.expect('editar una compra inexistente', v_r2.o_state, v_r2.o_msg, 'P0404');
    IF v_r.o_msg IS DISTINCT FROM v_r2.o_msg OR pg_temp.eff(v_a, v_b) <> v_eff0 OR pg_temp.purchase_ids(v_pop_b) <> v_ids THEN
      RAISE EXCEPTION 'editar una compra de otra cuenta es distinguible de editar una inexistente, o dejó efectos';
    END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_ps, pg_temp.e_edit_purchase(pg_temp.purchase_ids(v_pop_o), pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('editar una compra de la cuenta NO activa', v_r.o_state, v_r.o_msg, 'P0404');
    v_ids := pg_temp.purchase_ids(v_pop_o);
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_edit_purchase(v_ids, pg_temp.items(v_pb, 1), v_today));
    PERFORM pg_temp.expect('editar una compra con un producto de OTRA cuenta', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    IF pg_temp.purchase_ids(v_pop_o) <> v_ids THEN RAISE EXCEPTION 'editar con un producto ajeno cambió la compra'; END IF;
    RAISE NOTICE 'PASS (f): compras edita lo propio; dueño y admin lo ajeno (autoría conservada); sin CAN_PURCHASE P0403/P0401; otra cuenta P0404.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (g) Borrado de compra ───────────────────────────────────────────────────
  v_blk := '(g) borrado de compra';
  BEGIN
    IF v_pop_o IS NULL OR v_pop_pu IS NULL THEN RAISE EXCEPTION 'faltan las compras de partida (o=%, pu=%)', v_pop_o, v_pop_pu; END IF;
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_del_purchase(v_pop_o));
    PERFORM pg_temp.expect('compras borra la compra del DUEÑO', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    FOR i IN 3..7 LOOP
      SELECT * INTO v_r FROM pg_temp.run(v_actors[i], v_a, pg_temp.e_del_purchase(v_pop_o));
      PERFORM pg_temp.expect(v_labels[i] || ' borra una compra', v_r.o_state, v_r.o_msg, CASE i WHEN 7 THEN 'P0401' ELSE 'P0403' END);
    END LOOP;
    IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'un rechazo por rol dejó efectos'; END IF;
    -- Otra cuenta: como un inexistente (false).
    v_ids := pg_temp.purchase_ids(v_pop_b);
    SELECT * INTO v_r  FROM pg_temp.run(v_o, v_a, pg_temp.e_del_purchase(v_pop_b));
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_del_purchase(v_ghost));
    IF v_r.o_state <> '00000' OR v_r.o_res <> 'false'::jsonb OR v_r2.o_res <> 'false'::jsonb OR pg_temp.purchase_ids(v_pop_b) <> v_ids THEN
      RAISE EXCEPTION 'borrar una compra de OTRA cuenta debía responder false y no tocarla: % % / %', v_r.o_state, v_r.o_res, v_r2.o_res;
    END IF;
    -- Compras borra la PROPIA (repone/quita stock); dueño borra la de compras; admin borra la del dueño.
    v_s0 := pg_temp.stock(v_pa_s);
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_del_purchase(v_pop_pu));
    PERFORM pg_temp.expect('compras borra SU compra', v_r.o_state, v_r.o_msg, 'ok');
    IF cardinality(pg_temp.purchase_ids(v_pop_pu)) <> 0 OR pg_temp.stock(v_pa_s) <> v_s0 - 3 THEN
      RAISE EXCEPTION 'el borrado propio debía quitar la compra y restar 3 al stock (era %, es %)', v_s0, pg_temp.stock(v_pa_s);
    END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_del_purchase(v_pop_o));
    PERFORM pg_temp.expect('el admin borra la compra del dueño', v_r.o_state, v_r.o_msg, 'ok');
    IF cardinality(pg_temp.purchase_ids(v_pop_o)) <> 0 THEN RAISE EXCEPTION 'la compra borrada por el admin sigue existiendo'; END IF;
    -- El dueño borra la de compras (alta nueva para tener qué borrar).
    SELECT * INTO v_r FROM pg_temp.run(v_pu, v_a, pg_temp.e_purchase('rpc_create_purchase_operation', 'gate-mub-g-pu2', pg_temp.items(v_pa_s, 1), v_today));
    v_op := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_del_purchase(v_op));
    PERFORM pg_temp.expect('el dueño borra la compra de compras', v_r.o_state, v_r.o_msg, 'ok');
    RAISE NOTICE 'PASS (g): dueño y admin borran lo ajeno; compras sólo lo propio (P0403 sobre lo ajeno); sin CAN_PURCHASE P0403/P0401; otra cuenta = false.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (h) Rama legacy del kill-switch (sale_items_rpc_v2 = false) ────────────
  v_blk := '(h) rama legacy';
  BEGIN
    INSERT INTO public.account_feature_flags (account_id, flag_key, enabled) VALUES (v_a, 'sale_items_rpc_v2', false)
    ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = false;
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-h-s', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('rama legacy: el vendedor vende un producto del dueño', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-h-ad', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('rama legacy: el admin vende un producto del dueño', v_r.o_state, v_r.o_msg, 'ok');
    v_eff0 := pg_temp.eff(v_a, v_b);
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-h-v', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('rama legacy: el observador vende un producto PROPIO', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    SELECT * INTO v_r FROM pg_temp.run(v_st, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-h-st', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('rama legacy: el depósito vende', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_sale('rpc_create_sale_operation', 'gate-mub-h-pb', pg_temp.items(v_pb, 1), v_today));
    PERFORM pg_temp.expect('rama legacy: un producto de OTRA cuenta', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    IF pg_temp.eff(v_a, v_b) <> v_eff0 THEN RAISE EXCEPTION 'un rechazo en la rama legacy dejó efectos'; END IF;
    DELETE FROM public.account_feature_flags WHERE account_id = v_a AND flag_key = 'sale_items_rpc_v2';
    RAISE NOTICE 'PASS (h): la rama legacy de rpc_create_sale_operation tiene los mismos guards (producto por cuenta, rol).';
  EXCEPTION WHEN OTHERS THEN
    DELETE FROM public.account_feature_flags WHERE account_id = v_a AND flag_key = 'sale_items_rpc_v2';
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (i) rpc_create_purchase_operation_v2 (sin EXECUTE para authenticated) ───
  v_blk := '(i) compra v2';
  BEGIN
    PERFORM pg_temp.as_user(v_s, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc_priv(pg_temp.e_purchase('rpc_create_purchase_operation_v2', 'gate-mub-i-s', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('compra v2: el vendedor', v_r.o_state, v_r.o_msg, 'P0403', 'insufficient_role');
    PERFORM pg_temp.as_user(v_v, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc_priv(pg_temp.e_purchase('rpc_create_purchase_operation_v2', 'gate-mub-i-v', pg_temp.items(v_pa_v, 1), v_today));
    PERFORM pg_temp.expect('compra v2: el observador con producto propio', v_r.o_state, v_r.o_msg, 'P0401', 'unauthorized');
    PERFORM pg_temp.as_user(v_pu, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc_priv(pg_temp.e_purchase('rpc_create_purchase_operation_v2', 'gate-mub-i-pb', pg_temp.items(v_pb, 1), v_today));
    PERFORM pg_temp.expect('compra v2: producto de OTRA cuenta', v_r.o_state, v_r.o_msg, 'P0404', 'Product not found');
    SELECT * INTO v_r FROM pg_temp.try_rpc_priv(pg_temp.e_purchase('rpc_create_purchase_operation_v2', 'gate-mub-i-ok', pg_temp.items(v_pa1, 1), v_today));
    PERFORM pg_temp.expect('compra v2: compras compra un producto del dueño', v_r.o_state, v_r.o_msg, 'ok');
    RAISE NOTICE 'PASS (i): rpc_create_purchase_operation_v2 (sólo service_role) lleva los mismos guards.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (j) CANDADO DE CUERPO ───────────────────────────────────────────────────
  v_blk := '(j) candado de cuerpo';
  BEGIN
    -- Sin comentarios ni espacios, para que un comentario no cuente como código.
    FOR v_r IN
      SELECT p.proname, regexp_replace(regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g'), '\s+', ' ', 'g') AS src
      FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('rpc_create_sale_operation','rpc_create_sale_operation_v2','rpc_create_purchase_operation',
                          'rpc_create_purchase_operation_v2','rpc_atomic_update_sale_operation','rpc_atomic_update_purchase_operation',
                          'rpc_delete_sale_operation','rpc_delete_purchase_operation','_purchase_operation_core')
      ORDER BY p.proname
    LOOP
      -- 1) Ninguna autorización por AUTOR del producto ni del documento.
      IF v_r.src ~* 'v_product\.user_id' OR v_r.src ~* 'user_id\s*(<>|!=)\s*v_uid' OR v_r.src ~* 'user_id\s*=\s*v_uid\s+(ORDER|FOR UPDATE)' THEN
        RAISE EXCEPTION '% todavía autoriza por el AUTOR (v_product.user_id / user_id <> v_uid / lock por user_id)', v_r.proname;
      END IF;
      -- 2) Todo SELECT … FOR UPDATE sobre products filtra por la cuenta, dentro del mismo statement.
      IF v_r.src ~* 'FROM\s+(public\.)?products\s+WHERE\s+id\s*=\s*v_item\.product_id\s+FOR UPDATE' THEN
        RAISE EXCEPTION '% toma el producto FOR UPDATE SIN filtrar por la cuenta', v_r.proname;
      END IF;
      IF v_r.proname NOT IN ('rpc_delete_sale_operation', 'rpc_delete_purchase_operation', 'rpc_create_purchase_operation')
         AND v_r.src !~* 'FROM\s+(public\.)?products\s+WHERE\s+id\s*=\s*v_item\.product_id\s+AND\s+account_id\s*=\s*v_account_id\s+FOR UPDATE' THEN
        RAISE EXCEPTION '% no tiene el filtro de cuenta DENTRO del SELECT … FOR UPDATE del producto', v_r.proname;
      END IF;
    END LOOP;

    -- 3) El guard de rol va ANTES de la primera escritura / lock, en las 8 (en el núcleo no: lo decide el wrapper).
    FOR v_r IN
      SELECT p.proname, regexp_replace(regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g'), '\s+', ' ', 'g') AS src
      FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('rpc_create_sale_operation_v2','rpc_create_purchase_operation','rpc_create_purchase_operation_v2',
                          'rpc_atomic_update_sale_operation','rpc_atomic_update_purchase_operation',
                          'rpc_delete_sale_operation','rpc_delete_purchase_operation')
    LOOP
      IF position('_account_assert_capability' IN v_r.src) = 0 THEN
        RAISE EXCEPTION '% no llama a _account_assert_capability', v_r.proname;
      END IF;
      IF position('_account_assert_capability' IN v_r.src) >
         LEAST(NULLIF(position('INSERT INTO' IN v_r.src), 0), NULLIF(position('FOR UPDATE' IN v_r.src), 0),
               NULLIF(position('DELETE FROM' IN v_r.src), 0), NULLIF(position('UPDATE public' IN v_r.src), 0), 999999) THEN
        RAISE EXCEPTION '% llama a _account_assert_capability DESPUÉS de la primera escritura o lock', v_r.proname;
      END IF;
    END LOOP;
    -- La rama legacy del wrapper de venta: el guard antes de su primera escritura.
    SELECT regexp_replace(regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g'), '\s+', ' ', 'g') INTO v_txt
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_create_sale_operation';
    IF position('_account_assert_capability' IN v_txt) = 0
       OR position('_account_assert_capability' IN v_txt) > position('INSERT INTO' IN v_txt) THEN
      RAISE EXCEPTION 'rpc_create_sale_operation: la rama legacy no tiene el guard de rol antes de su primera escritura';
    END IF;
    -- La compra: el guard de capacidad lo lleva el wrapper público (el núcleo lo reusa la conversión de remitos, que decide con su propio rol).
    SELECT prosrc INTO v_txt FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = '_purchase_operation_core';
    IF v_txt LIKE '%_account_assert_capability%' THEN
      RAISE EXCEPTION '_purchase_operation_core NO debe exigir CAN_PURCHASE: la conversión de un remito la usa con el rol de remitos (incluye depósito)';
    END IF;
    RAISE NOTICE 'PASS (j): sin guard por autor, filtro de cuenta dentro del FOR UPDATE, guard de rol antes de la primera escritura.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (k) ESTRUCTURAL ─────────────────────────────────────────────────────────
  v_blk := '(k) estructural';
  BEGIN
    -- Los helpers existen, son internos (sin EXECUTE para los roles de aplicación) y tienen COMMENT.
    FOR v_txt IN SELECT unnest(ARRAY['_account_assert_capability(uuid, text[], text)', '_account_assert_document_authority(uuid, uuid[], text)']) LOOP
      IF to_regprocedure('public.' || v_txt) IS NULL THEN
        RAISE EXCEPTION 'no existe el helper public.%', v_txt;
      END IF;
      IF has_function_privilege('anon', to_regprocedure('public.' || v_txt), 'EXECUTE')
         OR has_function_privilege('authenticated', to_regprocedure('public.' || v_txt), 'EXECUTE') THEN
        RAISE EXCEPTION 'el helper public.% es ejecutable por anon/authenticated', v_txt;
      END IF;
      IF obj_description(to_regprocedure('public.' || v_txt), 'pg_proc') IS NULL THEN
        RAISE EXCEPTION 'el helper public.% no tiene COMMENT', v_txt;
      END IF;
    END LOOP;
    -- Una sola definición viva por función (sin overload nuevo, sin 42725).
    FOR v_r IN
      SELECT p.proname, count(*) AS n FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('rpc_create_sale_operation','rpc_create_sale_operation_v2','rpc_create_purchase_operation',
                          'rpc_create_purchase_operation_v2','rpc_atomic_update_sale_operation','rpc_atomic_update_purchase_operation',
                          'rpc_delete_sale_operation','rpc_delete_purchase_operation','_purchase_operation_core',
                          '_account_assert_capability','_account_assert_document_authority')
      GROUP BY p.proname HAVING count(*) <> 1
    LOOP
      RAISE EXCEPTION '% tiene % definiciones vivas', v_r.proname, v_r.n;
    END LOOP;
    -- ACLs de las 8: authenticated SÍ (salvo la v2 de compra y el núcleo), anon NUNCA.
    FOR v_r IN
      SELECT p.oid, p.proname FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('rpc_create_sale_operation','rpc_create_sale_operation_v2','rpc_create_purchase_operation',
                          'rpc_atomic_update_sale_operation','rpc_atomic_update_purchase_operation',
                          'rpc_delete_sale_operation','rpc_delete_purchase_operation')
    LOOP
      IF has_function_privilege('anon', v_r.oid, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_r.oid, 'EXECUTE') THEN
        RAISE EXCEPTION '% perdió su ACL (anon=%, authenticated=%)', v_r.proname,
          has_function_privilege('anon', v_r.oid, 'EXECUTE'), has_function_privilege('authenticated', v_r.oid, 'EXECUTE');
      END IF;
    END LOOP;
    FOR v_r IN
      SELECT p.oid, p.proname FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('rpc_create_purchase_operation_v2', '_purchase_operation_core')
    LOOP
      IF has_function_privilege('anon', v_r.oid, 'EXECUTE') OR has_function_privilege('authenticated', v_r.oid, 'EXECUTE') THEN
        RAISE EXCEPTION '% debía seguir SIN EXECUTE para anon ni authenticated', v_r.proname;
      END IF;
    END LOOP;
    RAISE NOTICE 'PASS (k): helpers internos con COMMENT, una definición viva por función, ACLs de las ocho intactas.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── Veredicto ──────────────────────────────────────────────────────────────
  IF array_length(v_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION E'GATE MULTIUSUARIO-OPERACIONES FAILED en % bloque(s):\n  - %', array_length(v_fail, 1), array_to_string(v_fail, E'\n  - ');
  END IF;
  RAISE NOTICE 'GATE MULTIUSUARIO-OPERACIONES OK: las ocho RPCs autorizan por cuenta activa y rol, nunca por autor (a-k).';
END
$gate$;

ROLLBACK;
