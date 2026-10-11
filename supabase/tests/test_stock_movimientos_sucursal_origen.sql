-- =============================================================================
-- test_stock_movimientos_sucursal_origen.sql — Gate de comportamiento del change
-- `stock-movimientos-sucursal-origen` (governance ALTA).
--
-- Decisión del PO (2026-10-11, «vamos con todo lo recomendado»): OQ-A (a), OQ-B (a),
-- OQ-C (a), OQ-D (a). El change hace dos cosas, cada una en su migración:
--
--   20261077000001  rpc_reverse_stock_movement: si la sucursal del movimiento
--                   original está DESACTIVADA, la reversa se aplica en la
--                   principal operativa y el contramovimiento registra esa
--                   sucursal (más la original en metadata). Una sucursal
--                   CERRADA sigue rechazando con P0422; un movimiento sin
--                   sucursal sigue como hoy.
--   20261077000002  migración de DATOS: completa stock_movements.branch_id de los
--                   movimientos 'sale' de ventas vivas con la sucursal de la que
--                   salió el stock cuando se registraron (reglas pre_sucursal /
--                   unica / reconstruida, con veto por caja y banco). Segunda y
--                   última extensión de la excepción auditada a RN-21.
--
-- Este gate EJECUTA las RPCs y la migración de datos (no sólo lee sus cuerpos)
-- contra Postgres real, como el backend, y se divide en dos partes:
--
--   PARTE A (un solo bloque DO, la reversa):
--     (A0) Introspección del cuerpo VIVO: una sola firma, SECURITY DEFINER, sin
--          EXECUTE para anon/authenticated/PUBLIC, COMMENT con la frase del
--          fallback y md5(prosrc sin \r) = el `v_rewritten` del preflight de
--          20261077000001. Falla explícito si una reaplicación posterior de CI
--          pisa el cuerpo.
--     (A1) Venta con el movimiento en una sucursal vaciada por transferencia y
--          dada de baja: rpc_delete_sale_operation EJECUTADA repone en la
--          principal operativa; el contramovimiento registra la principal y trae
--          reverses_movement_id, fallback_from_branch_id y fallback_reason; la
--          desactivada queda en 0.
--     (A2) Lo mismo para una compra con rpc_delete_purchase_operation, con el
--          piso en cero trazable cuando la principal no alcanza.
--     (A3) Sucursal CERRADA y activa: P0422 branch_closed, sin cambios en saldo
--          ni en el ledger. Triangulación: desactivada Y cerrada manda la baja
--          (respaldo, no P0422).
--     (A3c) Cuenta sin ninguna sucursal operativa: cae donde ya cae un movimiento
--          nulo, sin error nuevo y sin fallback_*.
--     (A4) Movimiento sin sucursal: la principal vigente y contramovimiento nulo,
--          como hoy; movimiento con sucursal operativa: ahí, sin fallback_*.
--     (A5) Operación con dos líneas, una en sucursal desactivada y otra en una
--          operativa: cada una se revierte según su caso.
--
--   PARTE B (varios DO + `\i` de la migración de datos, dos veces): ver más abajo.
--
-- Patrón del proyecto (test_ventas_sucursal_por_defecto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía handle_new_user;
-- sesión simulada con set_config LOCAL a la transacción — NUNCA usar este patrón
-- contra prod.
--
-- 🛑 created_at EXPLÍCITO y estrictamente POSTERIOR en las sucursales sintéticas:
-- c26_default_branch() ordena por created_at SIN desempate y branches.created_at
-- = now() es el timestamp de la TRANSACCIÓN, así que la sucursal que
-- handle_new_user auto-provisiona y las de este fixture nacerían con el MISMO
-- created_at al microsegundo y la "principal" saldría a suerte: el gate sería
-- flaky. Se fuerza y se ASSERTA (sso_assert_oldest).
--
-- Corre desde la raíz del repo (el `\i` de la parte B es relativo). CI:
-- KPI_Validation.yml (paso propio agregado en el mismo PR).
-- =============================================================================

-- ─── Ayudantes (pg_temp: desaparecen con la sesión) ───────────────────────────
CREATE FUNCTION pg_temp.sso_as(p_user uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;

-- Cuenta sintética vía handle_new_user: devuelve {user, account, branch} con la
-- sucursal "Casa Central" que handle_new_user auto-provisiona.
CREATE FUNCTION pg_temp.sso_mk_account(p_email text, p_name text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', p_email, now(), now(),
          jsonb_build_object('name', p_name, 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver la cuenta de % — handle_new_user no corrió', p_email;
  END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  RETURN jsonb_build_object('user', v_user, 'account', v_account, 'branch', v_branch);
END $f$;

-- Sucursal sintética con created_at = now() + p_minutes (estrictamente posterior
-- a la auto-provisionada).
CREATE FUNCTION pg_temp.sso_mk_branch(p_account uuid, p_name text, p_minutes integer,
                                      p_status text DEFAULT 'active', p_active boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (p_account, p_name, p_active, p_status, now(),
          CASE WHEN p_status = 'closed' THEN now() ELSE NULL END,
          now() + make_interval(mins => p_minutes))
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

-- Candado del determinismo: la auto-provisionada tiene que ser ESTRICTAMENTE la
-- más vieja de la cuenta (no se compara contra c26_default_branch: con un
-- empate esa comparación resuelve la ambigüedad según el plan de ESA llamada).
CREATE FUNCTION pg_temp.sso_assert_oldest(p_account uuid, p_branch uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT COUNT(*)::integer FROM public.branches b
  WHERE b.account_id = p_account AND b.id <> p_branch
    AND b.created_at <= (SELECT created_at FROM public.branches WHERE id = p_branch)
$f$;

CREATE FUNCTION pg_temp.sso_mk_product(p_user uuid, p_account uuid, p_sku text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (p_user, p_account, 'Producto ' || p_sku, p_sku, 60.00, 100.00)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.sso_qty(p_branch uuid, p_product uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE branch_id = p_branch AND product_id = p_product), 0)
$f$;

-- Alta de venta (v2) capturando el error: {ok, operation_id} | {ok:false, state, msg}.
CREATE FUNCTION pg_temp.sso_create(p_key text, p_items jsonb, p_branch uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_create_sale_operation_v2(p_key, NULL, public.reporting_local_today(), 'ARS', p_items,
                                           p_branch, NULL, NULL, NULL, NULL, NULL);
  RETURN jsonb_build_object('ok', true, 'operation_id', r->>'operation_id');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Borrado de venta / compra capturando el error: {ok:true} | {ok:false, state, msg}.
CREATE FUNCTION pg_temp.sso_del_sale(p_sale uuid, p_op uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM public.rpc_delete_sale_operation(p_sale, p_op, 'gate sso');
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

CREATE FUNCTION pg_temp.sso_del_purchase(p_op uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM public.rpc_delete_purchase_operation(NULL, p_op, 'gate sso');
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Fila de venta insertada directo (la forma en que quedaron las históricas). op
-- NULL = fila legacy sin operation_id.
CREATE FUNCTION pg_temp.sso_sale(p_user uuid, p_account uuid, p_product uuid, p_op uuid, p_branch uuid)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (p_user, p_account, p_product, 100, 1, 100, 'ARS', public.reporting_local_today(), p_op, p_branch)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

-- Movimiento de stock insertado directo, con created_at EXPLÍCITO.
CREATE FUNCTION pg_temp.sso_mov(p_user uuid, p_account uuid, p_product uuid, p_sale uuid, p_op uuid,
                                p_branch uuid, p_created timestamptz,
                                p_type text DEFAULT 'sale', p_ref text DEFAULT 'sale',
                                p_delta numeric DEFAULT -1)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type, quantity_delta,
                                      quantity_before, quantity_after, reference_id, reference_type,
                                      performed_by, operation_group_id, branch_id, created_at)
  VALUES (p_user, p_account, p_product, 'Producto gate', p_type,
          p_delta, 10, 10 + p_delta,
          p_sale, p_ref, p_user, p_op, p_branch, p_created)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

-- Limpieza completa de cuentas y usuarios sintéticos. Se borra TODA fila con
-- account_id de los anchors (incluidas las que siembra handle_new_user:
-- catálogo de formas de pago, categorías, flags...). Con
-- session_replication_role = replica los DELETE no cascadean ni validan FKs, así
-- que un `DELETE FROM accounts` solo dejaría huérfanas las tablas hijas, y las
-- dependencias SIN account_id (cajas, sesiones y movimientos de caja de las
-- sucursales) se borran explícitamente primero. branches prohíbe el borrado
-- físico SIEMPRE (trg_guard_branch_decommission, P0428); session_replication_role
-- sólo lo puede fijar un rol con privilegio de superusuario (postgres en CI) y no
-- abre ningún camino para authenticated/anon vía PostgREST.
CREATE FUNCTION pg_temp.sso_purge(p_accounts uuid[], p_users uuid[]) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_table text;
BEGIN
  SET session_replication_role = replica;
  DELETE FROM public.cash_movements WHERE session_id IN (SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY(p_accounts));
  DELETE FROM public.cash_sessions  WHERE cashbox_id IN (SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY(p_accounts));
  DELETE FROM public.cashboxes      WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY(p_accounts));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY($1)', v_table) USING p_accounts;
  END LOOP;
  -- Filas del fixture sin account_id (una venta sin cuenta, un movimiento sin
  -- cuenta): con replica no hay cascada desde auth.users, se borran por usuario.
  DELETE FROM public.sales                 WHERE user_id = ANY(p_users);
  DELETE FROM public.stock_movements       WHERE user_id = ANY(p_users);
  DELETE FROM public.accounts              WHERE id = ANY(p_accounts);
  DELETE FROM public.profiles              WHERE id = ANY(p_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY(p_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY(p_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY(p_users);
  DELETE FROM auth.users                   WHERE id = ANY(p_users);
  SET session_replication_role = DEFAULT;
END $f$;

-- ═════════════════════════════════════════════════════════════════════════════
-- PARTE A — la reversa de stock
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures    text[] := '{}';
  v_fail_before integer;

  -- Cuerpo que deja 20261077000001: md5(replace(prosrc, E'\r', '')), medido en el
  -- stack local después de aplicarla. Es el `v_rewritten` de su preflight.
  v_md5_reverse constant text := 'ae1ec5de1a6faedf3246013b6dc7f2fd';

  r jsonb;
  -- X1 (A1): venta, sucursal desactivada.
  v_u1 uuid; v_a1 uuid; v_a1b0 uuid; v_a1b1 uuid; v_p1 uuid;
  -- X2 (A2): compra.
  v_u2 uuid; v_a2 uuid; v_a2b0 uuid; v_a2b1 uuid; v_p2 uuid;
  -- X3 (A3, A3b): cerrada y desactivada+cerrada.
  v_u3 uuid; v_a3 uuid; v_a3b0 uuid; v_a3b1 uuid; v_a3b2 uuid; v_p3 uuid;
  -- X4 (A3c): sin sucursal operativa.
  v_u4 uuid; v_a4 uuid; v_a4b0 uuid; v_a4b1 uuid; v_p4 uuid;
  -- X5 (A4): movimiento nulo y movimiento operativo.
  v_u5 uuid; v_a5 uuid; v_a5b0 uuid; v_a5b1 uuid; v_p5 uuid;
  -- X6 (A5): dos líneas.
  v_u6 uuid; v_a6 uuid; v_a6b0 uuid; v_a6b1 uuid; v_p6a uuid; v_p6b uuid;

  v_res   jsonb;
  v_op    uuid;
  v_sale  uuid;
  v_sale2 uuid;
  v_mov   uuid;
  v_mov2  uuid;
  v_mv    RECORD;
  v_mv2   RECORD;
  v_n     integer;
  v_val   numeric;
  v_oid   oid;
  v_md5   text;
  v_cm    text;
  v_acl_public boolean;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup: seis cuentas sintéticas
  -- ═══════════════════════════════════════════════════════════════════════
  r := pg_temp.sso_mk_account('sso-a1@test.local', 'Gate SSO A1');
  v_u1 := (r->>'user')::uuid; v_a1 := (r->>'account')::uuid; v_a1b0 := (r->>'branch')::uuid;
  v_a1b1 := pg_temp.sso_mk_branch(v_a1, 'SSO A1 B1', 1);
  v_p1 := pg_temp.sso_mk_product(v_u1, v_a1, 'SSO-A1');

  r := pg_temp.sso_mk_account('sso-a2@test.local', 'Gate SSO A2');
  v_u2 := (r->>'user')::uuid; v_a2 := (r->>'account')::uuid; v_a2b0 := (r->>'branch')::uuid;
  v_a2b1 := pg_temp.sso_mk_branch(v_a2, 'SSO A2 B1', 1);
  v_p2 := pg_temp.sso_mk_product(v_u2, v_a2, 'SSO-A2');

  r := pg_temp.sso_mk_account('sso-a3@test.local', 'Gate SSO A3');
  v_u3 := (r->>'user')::uuid; v_a3 := (r->>'account')::uuid; v_a3b0 := (r->>'branch')::uuid;
  v_a3b1 := pg_temp.sso_mk_branch(v_a3, 'SSO A3 B1', 1);
  v_a3b2 := pg_temp.sso_mk_branch(v_a3, 'SSO A3 B2', 2);
  v_p3 := pg_temp.sso_mk_product(v_u3, v_a3, 'SSO-A3');

  r := pg_temp.sso_mk_account('sso-a4@test.local', 'Gate SSO A4');
  v_u4 := (r->>'user')::uuid; v_a4 := (r->>'account')::uuid; v_a4b0 := (r->>'branch')::uuid;
  v_a4b1 := pg_temp.sso_mk_branch(v_a4, 'SSO A4 B1', 1);
  v_p4 := pg_temp.sso_mk_product(v_u4, v_a4, 'SSO-A4');

  r := pg_temp.sso_mk_account('sso-a5@test.local', 'Gate SSO A5');
  v_u5 := (r->>'user')::uuid; v_a5 := (r->>'account')::uuid; v_a5b0 := (r->>'branch')::uuid;
  v_a5b1 := pg_temp.sso_mk_branch(v_a5, 'SSO A5 B1', 1);
  v_p5 := pg_temp.sso_mk_product(v_u5, v_a5, 'SSO-A5');

  r := pg_temp.sso_mk_account('sso-a6@test.local', 'Gate SSO A6');
  v_u6 := (r->>'user')::uuid; v_a6 := (r->>'account')::uuid; v_a6b0 := (r->>'branch')::uuid;
  v_a6b1 := pg_temp.sso_mk_branch(v_a6, 'SSO A6 B1', 1);
  v_p6a := pg_temp.sso_mk_product(v_u6, v_a6, 'SSO-A6A');
  v_p6b := pg_temp.sso_mk_product(v_u6, v_a6, 'SSO-A6B');

  IF pg_temp.sso_assert_oldest(v_a1, v_a1b0) + pg_temp.sso_assert_oldest(v_a2, v_a2b0) + pg_temp.sso_assert_oldest(v_a3, v_a3b0)
     + pg_temp.sso_assert_oldest(v_a4, v_a4b0) + pg_temp.sso_assert_oldest(v_a5, v_a5b0) + pg_temp.sso_assert_oldest(v_a6, v_a6b0) > 0 THEN
    RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (setup): sucursales que empatan o preceden a la auto-provisionada en created_at — c26_default_branch no desempata, el gate sería flaky';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A0) Introspección del cuerpo VIVO
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT COUNT(*), md5(replace(MIN(p.prosrc), E'\r', '')), MIN(p.oid)::oid
    INTO v_n, v_md5, v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_reverse_stock_movement';
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, format('FAIL (A0): rpc_reverse_stock_movement tiene %s firmas (debía haber una)', v_n));
  ELSE
    IF v_md5 IS DISTINCT FROM v_md5_reverse THEN
      v_failures := array_append(v_failures, format('FAIL (A0): el md5 vivo de rpc_reverse_stock_movement es %s y debía ser %s (el `v_rewritten` de 20261077000001): ¿una migración posterior o una reaplicación pisó el cuerpo?', v_md5, v_md5_reverse));
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_failures := array_append(v_failures, 'FAIL (A0): rpc_reverse_stock_movement dejó de ser SECURITY DEFINER');
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_failures := array_append(v_failures, 'FAIL (A0): anon o authenticated tienen EXECUTE sobre rpc_reverse_stock_movement (es interna)');
    END IF;
    SELECT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = v_oid AND a.grantee = 0)
      INTO v_acl_public;
    IF v_acl_public THEN
      v_failures := array_append(v_failures, 'FAIL (A0): PUBLIC tiene EXECUTE sobre rpc_reverse_stock_movement (es interna)');
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') OR NOT has_function_privilege('postgres', v_oid, 'EXECUTE') THEN
      v_failures := array_append(v_failures, 'FAIL (A0): postgres o service_role perdieron EXECUTE (rompe rpc_delete_sale_operation y rpc_delete_purchase_operation)');
    END IF;
    v_cm := COALESCE(obj_description(v_oid, 'pg_proc'), '');
    IF position('stock-movimientos-sucursal-origen (D6)' IN v_cm) = 0 OR position('branch_inactive' IN v_cm) = 0
       OR position('P0422 branch_closed' IN v_cm) = 0 OR position('reverses_movement_id' IN v_cm) = 0 THEN
      v_failures := array_append(v_failures, 'FAIL (A0): el COMMENT de rpc_reverse_stock_movement no conserva el vivo ni suma la frase del fallback (stock-movimientos-sucursal-origen (D6), branch_inactive, P0422 branch_closed)');
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A0): rpc_reverse_stock_movement — una firma, SECURITY DEFINER, ACL interna, COMMENT con el fallback y md5 = el del preflight';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A1) Venta con el movimiento en una sucursal vaciada por transferencia y
  --      dada de baja: el borrado repone en la principal operativa
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u1);
  PERFORM public.c21_apply_branch_stock_delta(v_a1, v_p1, v_a1b0, 10);
  v_res := pg_temp.sso_create('sso-a1-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)), v_a1b0);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (A1 setup): la venta en la sucursal explícita debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op;
    SELECT id INTO v_mov FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale';
    -- Se vacía la sucursal de la venta (queda 8) por transferencia a la otra y se da de baja.
    PERFORM public.c21_apply_branch_stock_delta(v_a1, v_p1, v_a1b0, -8);
    PERFORM public.c21_apply_branch_stock_delta(v_a1, v_p1, v_a1b1, 8);
    UPDATE public.branches SET is_active = FALSE WHERE id = v_a1b0;
    v_res := pg_temp.sso_del_sale(NULL, v_op);
    SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale_reversal';
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (A1): borrar una venta con el movimiento en una sucursal desactivada debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
    ELSIF pg_temp.sso_qty(v_a1b0, v_p1) IS DISTINCT FROM 0 OR pg_temp.sso_qty(v_a1b1, v_p1) IS DISTINCT FROM 10 THEN
      v_failures := array_append(v_failures, format('FAIL (A1): el stock debía volver a la principal operativa (B1 = 10) y la sucursal desactivada debía seguir en 0; quedó desactivada = %s, principal = %s', pg_temp.sso_qty(v_a1b0, v_p1), pg_temp.sso_qty(v_a1b1, v_p1)));
    ELSIF v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_a1b1 OR v_mv.quantity_delta IS DISTINCT FROM 2
          OR v_mv.quantity_before IS DISTINCT FROM 8 OR v_mv.quantity_after IS DISTINCT FROM 10
          OR (v_mv.metadata->>'reverses_movement_id')::uuid IS DISTINCT FROM v_mov
          OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM v_a1b0
          OR (v_mv.metadata->>'fallback_reason') IS DISTINCT FROM 'branch_inactive' THEN
      v_failures := array_append(v_failures, format('FAIL (A1): el contramovimiento debía registrar la principal operativa (branch_id = B1, +2, 8 -> 10) y traer reverses_movement_id, fallback_from_branch_id = la desactivada y fallback_reason = branch_inactive; es branch=%s delta=%s before=%s after=%s metadata=%s (B1=%s, desactivada=%s)', v_mv.branch_id, v_mv.quantity_delta, v_mv.quantity_before, v_mv.quantity_after, v_mv.metadata, v_a1b1, v_a1b0));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A1): el borrado de una venta con el movimiento en una sucursal desactivada repone en la principal operativa y el contramovimiento lo deja anotado';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A2) Compra con el movimiento en una sucursal desactivada: descuenta de la
  --      principal operativa, con piso en cero trazable
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u2);
  v_res := NULL;
  BEGIN
    v_res := public.rpc_create_purchase_operation('sso-a2-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate SSO',
      jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 50.00, 'quantity', 5, 'unit_id', NULL)), v_a2b0, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failures := array_append(v_failures, format('FAIL (A2 setup): la compra en la sucursal explícita debía pasar, falló con %s / %s', SQLSTATE, SQLERRM));
  END;
  IF v_res IS NOT NULL THEN
    v_op := (v_res->>'operation_id')::uuid;
    SELECT id INTO v_sale FROM public.purchases WHERE operation_id = v_op;
    SELECT id INTO v_mov FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'purchase';
    -- La mercadería comprada se vendió (la sucursal queda en 0) y la principal tiene 3 unidades.
    PERFORM public.c21_apply_branch_stock_delta(v_a2, v_p2, v_a2b0, -5);
    PERFORM public.c21_apply_branch_stock_delta(v_a2, v_p2, v_a2b1, 3);
    UPDATE public.branches SET is_active = FALSE WHERE id = v_a2b0;
    v_res := pg_temp.sso_del_purchase(v_op);
    SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'purchase_reversal';
    SELECT * INTO v_mv2 FROM public.stock_movements
     WHERE account_id = v_a2 AND product_id = v_p2 AND type = 'adjustment' AND reason = 'floor_on_purchase_delete';
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (A2): borrar una compra con el movimiento en una sucursal desactivada debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
    ELSIF pg_temp.sso_qty(v_a2b0, v_p2) IS DISTINCT FROM 0 OR pg_temp.sso_qty(v_a2b1, v_p2) IS DISTINCT FROM 0 THEN
      v_failures := array_append(v_failures, format('FAIL (A2): el descuento debía salir de la principal operativa (3 -> 0, piso) y la desactivada debía seguir en 0; quedó desactivada = %s, principal = %s', pg_temp.sso_qty(v_a2b0, v_p2), pg_temp.sso_qty(v_a2b1, v_p2)));
    ELSIF v_mv2.id IS NULL OR v_mv2.branch_id IS DISTINCT FROM v_a2b1 OR v_mv2.quantity_delta IS DISTINCT FROM -3
          OR v_mv2.quantity_before IS DISTINCT FROM 3 OR v_mv2.quantity_after IS DISTINCT FROM 0 THEN
      v_failures := array_append(v_failures, format('FAIL (A2): el ajuste de piso floor_on_purchase_delete debía caer en la principal (-3, 3 -> 0); es branch=%s delta=%s before=%s after=%s', v_mv2.branch_id, v_mv2.quantity_delta, v_mv2.quantity_before, v_mv2.quantity_after));
    ELSIF v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_a2b1 OR v_mv.quantity_delta IS DISTINCT FROM -3
          OR (v_mv.metadata->>'reverses_movement_id')::uuid IS DISTINCT FROM v_mov
          OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM v_a2b0
          OR (v_mv.metadata->>'fallback_reason') IS DISTINCT FROM 'branch_inactive' THEN
      v_failures := array_append(v_failures, format('FAIL (A2): el contramovimiento purchase_return debía registrar la principal (-3) con la sucursal original y el motivo en metadata; es branch=%s delta=%s metadata=%s', v_mv.branch_id, v_mv.quantity_delta, v_mv.metadata));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A2): el borrado de una compra con el movimiento en una sucursal desactivada descuenta de la principal operativa, con piso trazable';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A3) Sucursal CERRADA y activa: P0422. (A3b) Desactivada Y cerrada: manda la baja.
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u3);
  PERFORM public.c21_apply_branch_stock_delta(v_a3, v_p3, v_a3b0, 2);
  PERFORM public.c21_apply_branch_stock_delta(v_a3, v_p3, v_a3b1, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_a3, v_p3, v_a3b2, 2);
  v_res := pg_temp.sso_create('sso-a3-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 2)), v_a3b0);
  v_op := (v_res->>'operation_id')::uuid;
  v_res := pg_temp.sso_create('sso-a3b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 2)), v_a3b2);
  IF v_op IS NULL OR (v_res->>'operation_id') IS NULL THEN
    v_failures := array_append(v_failures, format('FAIL (A3 setup): las dos ventas en sucursal explícita debían pasar (%s)', v_res));
  ELSE
    SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op;
    SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
    -- B0 cerrada y activa (vacía); B2 desactivada Y cerrada (vacía).
    UPDATE public.branches SET status = 'closed', closed_at = now() WHERE id = v_a3b0;
    UPDATE public.branches SET is_active = FALSE, status = 'closed', closed_at = now() WHERE id = v_a3b2;

    -- (A3) cerrada y activa: P0422 y nada cambia.
    v_res := pg_temp.sso_del_sale(v_sale, NULL);
    IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('branch_closed' IN COALESCE(v_res->>'msg', '')) = 0 THEN
      v_failures := array_append(v_failures, format('FAIL (A3): borrar una venta cuyo movimiento está en una sucursal CERRADA y activa debía rechazarse con P0422 branch_closed (se reabre), dio %s', v_res));
    ELSE
      IF pg_temp.sso_qty(v_a3b0, v_p3) IS DISTINCT FROM 0 OR pg_temp.sso_qty(v_a3b1, v_p3) IS DISTINCT FROM 5
         OR NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale)
         OR EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale_reversal') THEN
        v_failures := array_append(v_failures, 'FAIL (A3): el rechazo por sucursal cerrada debía dejar el saldo, la venta y el ledger sin cambios');
      END IF;
    END IF;

    -- (A3b) desactivada Y cerrada: respaldo, no P0422.
    v_res := pg_temp.sso_del_sale(v_sale2, NULL);
    SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale2 AND reference_type = 'sale_reversal';
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (A3b): una sucursal desactivada Y cerrada manda la baja: debía respaldarse en la principal sin P0422, levantó %s / %s', v_res->>'state', v_res->>'msg'));
    ELSIF pg_temp.sso_qty(v_a3b2, v_p3) IS DISTINCT FROM 0 OR pg_temp.sso_qty(v_a3b1, v_p3) IS DISTINCT FROM 7
          OR v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_a3b1
          OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM v_a3b2
          OR (v_mv.metadata->>'fallback_reason') IS DISTINCT FROM 'branch_inactive' THEN
      v_failures := array_append(v_failures, format('FAIL (A3b): la reversa debía entrar en la principal (5 -> 7) con el respaldo anotado; B1=%s, B2=%s, branch del contramovimiento=%s, metadata=%s', pg_temp.sso_qty(v_a3b1, v_p3), pg_temp.sso_qty(v_a3b2, v_p3), v_mv.branch_id, v_mv.metadata));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A3): cerrada y activa -> P0422 sin cambios; desactivada y cerrada -> respaldo en la principal';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A3c) Cuenta sin ninguna sucursal operativa: cae donde ya cae un movimiento
  --       nulo, sin error nuevo y sin fallback_*
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u4);
  PERFORM public.c21_apply_branch_stock_delta(v_a4, v_p4, v_a4b0, 2);
  v_res := pg_temp.sso_create('sso-a4-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p4, 'amount', 100.00, 'quantity', 2)), v_a4b0);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (A3c setup): la venta en la sucursal explícita debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op;
    UPDATE public.branches SET is_active = FALSE WHERE id IN (v_a4b0, v_a4b1);
    v_res := pg_temp.sso_del_sale(v_sale, NULL);
    SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale_reversal';
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (A3c): sin ninguna sucursal operativa el borrado debía pasar como hoy (cae en la más antigua), levantó %s / %s', v_res->>'state', v_res->>'msg'));
    ELSIF pg_temp.sso_qty(v_a4b0, v_p4) IS DISTINCT FROM 2 OR v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_a4b0
          OR (v_mv.metadata ? 'fallback_from_branch_id') OR (v_mv.metadata ? 'fallback_reason') THEN
      v_failures := array_append(v_failures, format('FAIL (A3c): el stock debía entrar donde ya entra un movimiento nulo (la más antigua, B0 = 2) y el contramovimiento conservar la sucursal original SIN fallback_*; B0=%s branch=%s metadata=%s', pg_temp.sso_qty(v_a4b0, v_p4), v_mv.branch_id, v_mv.metadata));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A3c): sin ninguna sucursal operativa el borrado cae donde ya caía, sin error nuevo y sin fallback_*';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A4) Movimiento sin sucursal: la principal vigente y contramovimiento nulo
  --      (como hoy); movimiento con sucursal operativa: ahí, sin fallback_*
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u5);
  PERFORM public.c21_apply_branch_stock_delta(v_a5, v_p5, v_a5b0, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_a5, v_p5, v_a5b1, 4);
  v_op := gen_random_uuid();
  v_sale := pg_temp.sso_sale(v_u5, v_a5, v_p5, v_op, NULL);
  v_mov := pg_temp.sso_mov(v_u5, v_a5, v_p5, v_sale, v_op, NULL, now() - interval '1 hour', 'sale', 'sale', -2);
  v_res := pg_temp.sso_del_sale(v_sale, NULL);
  SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale_reversal';
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (A4): borrar una venta con el movimiento sin sucursal debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF pg_temp.sso_qty(v_a5b0, v_p5) IS DISTINCT FROM 12 OR v_mv.id IS NULL OR v_mv.branch_id IS NOT NULL
        OR (v_mv.metadata ? 'fallback_from_branch_id') THEN
    v_failures := array_append(v_failures, format('FAIL (A4): el movimiento sin sucursal debía reponer en la principal vigente (B0 = 12) y dejar el contramovimiento SIN sucursal y sin fallback_*; B0=%s branch=%s metadata=%s', pg_temp.sso_qty(v_a5b0, v_p5), v_mv.branch_id, v_mv.metadata));
  END IF;
  v_op := gen_random_uuid();
  v_sale2 := pg_temp.sso_sale(v_u5, v_a5, v_p5, v_op, v_a5b1);
  v_mov2 := pg_temp.sso_mov(v_u5, v_a5, v_p5, v_sale2, v_op, v_a5b1, now() - interval '1 hour', 'sale', 'sale', -1);
  v_res := pg_temp.sso_del_sale(v_sale2, NULL);
  SELECT * INTO v_mv2 FROM public.stock_movements WHERE reference_id = v_sale2 AND reference_type = 'sale_reversal';
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (A4): borrar una venta con el movimiento en una sucursal operativa debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF pg_temp.sso_qty(v_a5b1, v_p5) IS DISTINCT FROM 5 OR v_mv2.id IS NULL OR v_mv2.branch_id IS DISTINCT FROM v_a5b1
        OR (v_mv2.metadata ? 'fallback_from_branch_id') OR (v_mv2.metadata ? 'fallback_reason')
        OR (v_mv2.metadata->>'reverses_movement_id')::uuid IS DISTINCT FROM v_mov2 THEN
    v_failures := array_append(v_failures, format('FAIL (A4): el movimiento en una sucursal operativa debía reponer ahí (B1 = 5) y el contramovimiento conservar la sucursal sin fallback_*; B1=%s branch=%s metadata=%s', pg_temp.sso_qty(v_a5b1, v_p5), v_mv2.branch_id, v_mv2.metadata));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A4): sin sucursal -> la principal vigente y contramovimiento nulo; con sucursal operativa -> ahí, sin fallback_*';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (A5) Operación con dos líneas: una en sucursal desactivada, otra en una operativa
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.sso_as(v_u6);
  PERFORM public.c21_apply_branch_stock_delta(v_a6, v_p6a, v_a6b1, 1);
  PERFORM public.c21_apply_branch_stock_delta(v_a6, v_p6b, v_a6b1, 7);
  v_op := gen_random_uuid();
  v_sale := pg_temp.sso_sale(v_u6, v_a6, v_p6a, v_op, v_a6b0);
  v_mov := pg_temp.sso_mov(v_u6, v_a6, v_p6a, v_sale, v_op, v_a6b0, now() - interval '1 hour', 'sale', 'sale', -2);
  v_sale2 := pg_temp.sso_sale(v_u6, v_a6, v_p6b, v_op, v_a6b1);
  v_mov2 := pg_temp.sso_mov(v_u6, v_a6, v_p6b, v_sale2, v_op, v_a6b1, now() - interval '1 hour', 'sale', 'sale', -3);
  UPDATE public.branches SET is_active = FALSE WHERE id = v_a6b0;
  v_res := pg_temp.sso_del_sale(NULL, v_op);
  SELECT * INTO v_mv FROM public.stock_movements WHERE reference_id = v_sale AND reference_type = 'sale_reversal';
  SELECT * INTO v_mv2 FROM public.stock_movements WHERE reference_id = v_sale2 AND reference_type = 'sale_reversal';
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (A5): borrar la operación de dos líneas debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF pg_temp.sso_qty(v_a6b0, v_p6a) IS DISTINCT FROM 0 OR pg_temp.sso_qty(v_a6b1, v_p6a) IS DISTINCT FROM 3
        OR pg_temp.sso_qty(v_a6b1, v_p6b) IS DISTINCT FROM 10 THEN
    v_failures := array_append(v_failures, format('FAIL (A5): la línea de la sucursal desactivada debía reponer en la principal (A: 1 -> 3) y la de la operativa en la suya (B: 7 -> 10), la desactivada en 0; quedó A@desactivada=%s A@principal=%s B@principal=%s', pg_temp.sso_qty(v_a6b0, v_p6a), pg_temp.sso_qty(v_a6b1, v_p6a), pg_temp.sso_qty(v_a6b1, v_p6b)));
  ELSIF v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM v_a6b1 OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM v_a6b0
        OR v_mv2.id IS NULL OR v_mv2.branch_id IS DISTINCT FROM v_a6b1 OR (v_mv2.metadata ? 'fallback_from_branch_id') THEN
    v_failures := array_append(v_failures, format('FAIL (A5): contramovimiento de la línea desactivada = branch %s metadata %s; de la operativa = branch %s metadata %s', v_mv.branch_id, v_mv.metadata, v_mv2.branch_id, v_mv2.metadata));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (A5): una operación con una línea en sucursal desactivada y otra en una operativa revierte cada una según su caso';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado y limpieza
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.sso_purge(
    ARRAY[v_a1, v_a2, v_a3, v_a4, v_a5, v_a6],
    ARRAY[v_u1, v_u2, v_u3, v_u4, v_u5, v_u6]);

  -- Residuo cero: las cajas y el stock de las sucursales sintéticas (dependencias
  -- sin account_id propio que sólo la limpieza explícita alcanza).
  SELECT COUNT(*) INTO v_n FROM public.cashboxes
   WHERE branch_id IN (v_a1b0, v_a1b1, v_a2b0, v_a2b1, v_a3b0, v_a3b1, v_a3b2, v_a4b0, v_a4b1, v_a5b0, v_a5b1, v_a6b0, v_a6b1);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s cajas de las sucursales sintéticas', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.branch_stock
   WHERE branch_id IN (v_a1b0, v_a1b1, v_a2b0, v_a2b1, v_a3b0, v_a3b1, v_a3b2, v_a4b0, v_a4b1, v_a5b0, v_a5b1, v_a6b0, v_a6b1);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s filas de branch_stock de las sucursales sintéticas', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements
   WHERE account_id IN (v_a1, v_a2, v_a3, v_a4, v_a5, v_a6);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s movimientos de stock de las cuentas sintéticas', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte A) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte A) PASSED: la reversa de un movimiento en una sucursal desactivada se aplica en la principal operativa (venta y compra, con piso trazable) y lo deja anotado; una cerrada sigue pidiendo reabrirse; un movimiento sin sucursal o con una operativa no cambia.';
END $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- PARTE B — la migración de DATOS 20261077000002, ejecutada con `\i` DOS veces
-- sobre fixtures con la historia de sucursales armada a mano. Todo dentro de UNA
-- transacción que termina en ROLLBACK: si algo falla, psql sale y la base no conserva
-- ninguna fila del fixture; si pasa, la limpieza final ya borró todo (con residuo cero
-- asertado) y el ROLLBACK deshace además lo que el archivo de datos, que es GLOBAL
-- (también completa los movimientos nulos que haya fuera del fixture), haya tocado en
-- filas ajenas: ninguna aserción mira filas fuera del fixture.
--
-- La historia de sucursales se arma así (design D9): `created_at` explícitos
-- (antes y después de X = 2026-08-26 00:00 -03 y de cada movimiento); los
-- cambios de estado de las sucursales con session_replication_role = replica
-- (sin disparador de auditoría: simulan las bajas anteriores a X, que no dejaron
-- rastro); los eventos de ciclo de vida insertados en audit_logs con created_at
-- EXPLÍCITO (el disparador real los escribiría todos con now(), el instante de la
-- transacción). Los movimientos 'sale' se insertan con created_at explícito.
--
--   (B1)  pre_sucursal con la más antigua desactivada -> la más antigua
--   (B2)  unica con la única desactivada y la venta en otra sucursal -> la única
--         (discrepancia_venta)
--   (B3)  reconstruida, T >= X, la más antigua dada de baja DESPUÉS de T -> la más antigua
--   (B4)  reconstruida, T >= X, la más antigua dada de baja ANTES de T -> la siguiente
--   (B4b) reconstruida, la más antigua reactivada después de T (evento): T >= X
--         no operaba -> la siguiente; T < X -> nulo
--   (B5)  reconstruida, T < X, la más antigua inactiva sin fecha -> nulo (no_fechable)
--   (B6)  reconstruida, T < X, la más antigua activa -> la más antigua
--   (B7)  reconstruida, T < X, la más antigua con closed_at -> nulo
--   (B8)  reconstruida sin ninguna operativa conocida -> la más antigua de las existentes
--   (B9)  veto por caja y (B10) veto por banco -> nulo (contradiccion)
--   (B11) controles intactos
--   (B12) ninguna otra columna cambia
--   (B13) auditoría por cuenta con ids por regla y contadores
--   (B14) la segunda corrida no cambia nada ni escribe auditoría
--   (B15) sin efectos laterales
--   (B16) rpc_delete_sale_operation EJECUTADA sobre una venta de (B1)
--   (B17) empate de created_at -> nulo; (B18) evento en el mismo instante; (B19)
--         eventos contradictorios en el mismo instante; (B20) destino cerrado
-- ═════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE _sso_k (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE _sso_t (k text PRIMARY KEY, v text);

CREATE FUNCTION pg_temp.sso_put(p_k text, p_v uuid) RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO _sso_k (k, v) VALUES (p_k, p_v);
  RETURN p_v;
END $f$;
CREATE FUNCTION pg_temp.sso_get(p_k text) RETURNS uuid LANGUAGE sql AS $f$ SELECT v FROM _sso_k WHERE k = p_k $f$;
-- sucursal que quedó escrita en el movimiento con esa clave
CREATE FUNCTION pg_temp.sso_mbr(p_k text) RETURNS uuid LANGUAGE sql AS $f$
  SELECT branch_id FROM public.stock_movements WHERE id = pg_temp.sso_get(p_k)
$f$;
-- nombre de clave de una sucursal del fixture (para los mensajes)
CREATE FUNCTION pg_temp.sso_bn(p_id uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT k FROM _sso_k WHERE v = p_id AND k ~ '^[A-Z][0-9]$' LIMIT 1), COALESCE(p_id::text, 'NULL'))
$f$;
-- X: el fin del día en que se desplegó el registro del ciclo de vida de las sucursales
CREATE FUNCTION pg_temp.sso_x() RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $f$
  SELECT '2026-08-26 00:00:00-03'::timestamptz
$f$;

-- Sucursal con estado y created_at explícitos (el disparador de auditoría escribe un
-- branch.created sin estado previo, que la migración ignora).
CREATE FUNCTION pg_temp.sso_brx(p_account uuid, p_name text, p_created timestamptz,
                                p_active boolean DEFAULT true, p_status text DEFAULT 'active',
                                p_closed_at timestamptz DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (p_account, p_name, p_active, p_status, p_created, p_closed_at, p_created)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

-- Cambia created_at y el estado de una sucursal SIN disparar el guard de baja ni la
-- auditoría: simula las bajas que no dejaron rastro.
CREATE FUNCTION pg_temp.sso_setb(p_branch uuid, p_created timestamptz, p_active boolean,
                                 p_status text DEFAULT 'active', p_closed_at timestamptz DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  SET session_replication_role = replica;
  UPDATE public.branches
  SET created_at = p_created, is_active = p_active, status = p_status, closed_at = p_closed_at
  WHERE id = p_branch;
  SET session_replication_role = DEFAULT;
END $f$;

-- Evento de ciclo de vida con created_at EXPLÍCITO (la forma de los que escribe
-- fn_audit_branch_lifecycle).
CREATE FUNCTION pg_temp.sso_ev(p_account uuid, p_branch uuid, p_action text,
                               p_ab boolean, p_sb text, p_aa boolean, p_sa text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO public.audit_logs (user_id, action, account_id, entity_type, entity_id, metadata, created_at)
  VALUES (NULL, p_action, p_account, 'branch', p_branch,
          jsonb_build_object('is_active_before', p_ab, 'is_active_after', p_aa,
                             'status_before', p_sb, 'status_after', p_sa), p_at);
END $f$;

-- Cuenta del fixture con su producto: registra u_L, a_L, p_L y la sucursal
-- auto-provisionada como L1.
CREATE FUNCTION pg_temp.sso_acct(p_label text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sso_mk_account('sso-b-' || lower(p_label) || '@test.local', 'Gate SSO B ' || p_label);
  PERFORM pg_temp.sso_put('u_' || p_label, (r->>'user')::uuid);
  PERFORM pg_temp.sso_put('a_' || p_label, (r->>'account')::uuid);
  PERFORM pg_temp.sso_put(p_label || '1', (r->>'branch')::uuid);
  PERFORM pg_temp.sso_put('p_' || p_label, pg_temp.sso_mk_product((r->>'user')::uuid, (r->>'account')::uuid, 'SSOB-' || p_label));
  RETURN r;
END $f$;

-- Venta VIVA (con la sucursal que se pida) y su movimiento 'sale' SIN sucursal, con
-- created_at explícito. Registra s<k> (la venta), o<k> (su operación) y <k> (el movimiento).
CREATE FUNCTION pg_temp.sso_case(p_key text, p_label text, p_sale_branch uuid, p_created timestamptz)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_u uuid := pg_temp.sso_get('u_' || p_label);
  v_a uuid := pg_temp.sso_get('a_' || p_label);
  v_p uuid := pg_temp.sso_get('p_' || p_label);
  v_op uuid := gen_random_uuid();
  v_s uuid;
BEGIN
  v_s := pg_temp.sso_put('s' || p_key, pg_temp.sso_sale(v_u, v_a, v_p, v_op, p_sale_branch));
  PERFORM pg_temp.sso_put('o' || p_key, v_op);
  PERFORM pg_temp.sso_put(p_key, pg_temp.sso_mov(v_u, v_a, v_p, v_s, v_op, NULL, p_created));
END $f$;

-- Efectos laterales que la migración NO puede tocar, contados SÓLO sobre las cuentas
-- del fixture: pg_cron corre relay-process-outbox y relay-process-pending-cae cada
-- minuto en el stack local y en CI, y un conteo global puede cambiar por el relay
-- sin ningún defecto.
CREATE FUNCTION pg_temp.sso_effects(p_accounts uuid[]) RETURNS text LANGUAGE sql AS $f$
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.events WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.notifications WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.analytics_events WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id
      WHERE b.account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.bank_movements WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.customer_account_movements WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.journal_entries WHERE account_id = ANY(p_accounts)),
    (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.sales_orders WHERE account_id = ANY(p_accounts)),
    (SELECT count(*) FROM public.sale_items WHERE account_id = ANY(p_accounts)),
    (SELECT md5(COALESCE(string_agg(to_jsonb(s)::text, ',' ORDER BY s.id), '')) FROM public.sales s WHERE s.user_id = ANY(
       ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'u\_%'))),
    (SELECT md5(COALESCE(string_agg(to_jsonb(b)::text, ',' ORDER BY b.id), '')) FROM public.branches b WHERE b.account_id = ANY(p_accounts)))
$f$;

-- md5 de TODAS las columnas de los movimientos del fixture salvo branch_id.
CREATE FUNCTION pg_temp.sso_hash_other() RETURNS text LANGUAGE sql AS $f$
  SELECT md5(COALESCE(string_agg((to_jsonb(sm) - 'branch_id')::text, ',' ORDER BY sm.id), ''))
  FROM public.stock_movements sm WHERE sm.user_id = ANY(ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'u\_%'))
$f$;

-- Foto de lo que la segunda corrida no puede cambiar: la sucursal de cada movimiento y la auditoría.
CREATE FUNCTION pg_temp.sso_snapshot() RETURNS text LANGUAGE sql AS $f$
  SELECT concat_ws('#',
    (SELECT md5(COALESCE(string_agg(sm.id::text || ':' || COALESCE(sm.branch_id::text, '-'), ',' ORDER BY sm.id), ''))
       FROM public.stock_movements sm WHERE sm.user_id = ANY(ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'u\_%'))),
    (SELECT count(*) FROM public.audit_logs
      WHERE action = 'stock_movements_branch_backfill' AND account_id = ANY(ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'a\_%'))))
$f$;

-- Ids de movimientos por clave, ordenados (la forma en que los guarda la auditoría).
CREATE FUNCTION pg_temp.sso_ids(p_keys text[]) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb)
  FROM (SELECT pg_temp.sso_get(k)::text AS x FROM unnest(p_keys) k) s
$f$;
CREATE FUNCTION pg_temp.sso_sorted(p_arr jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM jsonb_array_elements_text(COALESCE(p_arr, '[]'::jsonb)) x
$f$;

-- ── B.1 Fixtures ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  x timestamptz := pg_temp.sso_x();
  r jsonb;
  a uuid; u uuid; b1 uuid; b2 uuid;
  v_cbx uuid; v_ses uuid; v_bank uuid; v_op uuid; v_s uuid; v_dead uuid;
  v_n integer;
BEGIN
  -- ── P: reconstruida con eventos (B3, B4, B6) + unica (B7') + pre_sucursal ─────
  -- P1 (X-60d) hoy desactivada, dada de baja por evento en X+10d. P2 (X-30d) activa.
  r := pg_temp.sso_acct('P'); u := pg_temp.sso_get('u_P'); a := pg_temp.sso_get('a_P'); b1 := pg_temp.sso_get('P1');
  PERFORM pg_temp.sso_setb(b1, x - interval '60 days', false);
  b2 := pg_temp.sso_put('P2', pg_temp.sso_brx(a, 'SSO P2', x - interval '30 days'));
  PERFORM pg_temp.sso_ev(a, b1, 'branch.deactivated', true, 'active', false, 'active', x + interval '10 days');
  PERFORM pg_temp.sso_case('mP3', 'P', b2, x + interval '5 days');    -- B3: P1 operaba (baja posterior)
  PERFORM pg_temp.sso_case('mP4', 'P', b2, x + interval '15 days');   -- B4: P1 ya dada de baja -> P2
  PERFORM pg_temp.sso_case('mP6', 'P', b2, x - interval '10 days');   -- B6: T < X, activa -> P1
  PERFORM pg_temp.sso_case('mP7', 'P', b2, x - interval '40 days');   -- unica (sólo existía P1)
  PERFORM pg_temp.sso_case('mP8', 'P', b2, x - interval '90 days');   -- pre_sucursal -> la más antigua

  -- ── Q: reactivación registrada después de T (B4b) ────────────────────────────
  -- Q1 (X-60d) estuvo inactiva sin fecha y se reactivó en X+20d (evento); hoy activa.
  r := pg_temp.sso_acct('Q'); u := pg_temp.sso_get('u_Q'); a := pg_temp.sso_get('a_Q'); b1 := pg_temp.sso_get('Q1');
  PERFORM pg_temp.sso_setb(b1, x - interval '60 days', true);
  b2 := pg_temp.sso_put('Q2', pg_temp.sso_brx(a, 'SSO Q2', x - interval '20 days'));
  PERFORM pg_temp.sso_ev(a, b1, 'branch.reactivated', false, 'active', true, 'active', x + interval '20 days');
  PERFORM pg_temp.sso_case('mQa', 'Q', b2, x + interval '10 days');   -- T >= X: en T no operaba -> Q2
  PERFORM pg_temp.sso_case('mQb', 'Q', b2, x - interval '5 days');    -- T < X: no fechable -> nulo

  -- ── R: la más antigua inactiva sin fecha (B5) ────────────────────────────────
  r := pg_temp.sso_acct('R'); u := pg_temp.sso_get('u_R'); a := pg_temp.sso_get('a_R'); b1 := pg_temp.sso_get('R1');
  PERFORM pg_temp.sso_setb(b1, x - interval '60 days', false);
  b2 := pg_temp.sso_put('R2', pg_temp.sso_brx(a, 'SSO R2', x - interval '20 days'));
  PERFORM pg_temp.sso_case('mRa', 'R', b2, x - interval '3 days');    -- B5: T < X, inactiva sin fecha -> nulo
  PERFORM pg_temp.sso_case('mRb', 'R', b2, x + interval '3 days');    -- T >= X: R1 consta inactiva -> R2
  PERFORM pg_temp.sso_case('mRc', 'R', b2, x - interval '40 days');   -- unica: sólo R1 (inactiva) -> R1

  -- ── S: la más antigua con closed_at (B7) ─────────────────────────────────────
  r := pg_temp.sso_acct('S'); u := pg_temp.sso_get('u_S'); a := pg_temp.sso_get('a_S'); b1 := pg_temp.sso_get('S1');
  PERFORM pg_temp.sso_setb(b1, x - interval '60 days', true, 'active', x - interval '50 days');
  b2 := pg_temp.sso_put('S2', pg_temp.sso_brx(a, 'SSO S2', x - interval '20 days'));
  PERFORM pg_temp.sso_case('mSa', 'S', b2, x - interval '5 days');    -- B7: T < X y closed_at -> nulo
  PERFORM pg_temp.sso_case('mSb', 'S', b2, x + interval '5 days');    -- T >= X: S1 activa -> S1

  -- ── U: ninguna operativa conocida (B8) ───────────────────────────────────────
  r := pg_temp.sso_acct('U'); u := pg_temp.sso_get('u_U'); a := pg_temp.sso_get('a_U'); b1 := pg_temp.sso_get('U1');
  PERFORM pg_temp.sso_setb(b1, x - interval '60 days', false);
  b2 := pg_temp.sso_put('U2', pg_temp.sso_brx(a, 'SSO U2', x - interval '20 days', false));
  PERFORM pg_temp.sso_case('mUa', 'U', b2, x + interval '2 days');    -- B8: ninguna operaba -> la más antigua (U1)
  PERFORM pg_temp.sso_case('mUb', 'U', b2, x - interval '10 days');   -- T < X: U1 desconocida -> nulo

  -- ── W: pre_sucursal con la más antigua desactivada (B1) ──────────────────────
  r := pg_temp.sso_acct('W'); u := pg_temp.sso_get('u_W'); a := pg_temp.sso_get('a_W'); b1 := pg_temp.sso_get('W1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', false);
  b2 := pg_temp.sso_put('W2', pg_temp.sso_brx(a, 'SSO W2', x - interval '45 days'));
  PERFORM pg_temp.sso_case('mWa', 'W', b2, x - interval '60 days');   -- B1: sin sucursales -> la más antigua (W1, desactivada)

  -- ── Y: unica con la única desactivada y la venta en otra sucursal (B2) ───────
  r := pg_temp.sso_acct('Y'); u := pg_temp.sso_get('u_Y'); a := pg_temp.sso_get('a_Y'); b1 := pg_temp.sso_get('Y1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', false);
  b2 := pg_temp.sso_put('Y2', pg_temp.sso_brx(a, 'SSO Y2', x - interval '10 days'));
  PERFORM pg_temp.sso_case('mYa', 'Y', b2, x - interval '30 days');   -- B2: sólo Y1 (desactivada) -> Y1; venta en Y2

  -- ── Z: veto por caja y por banco (B9, B10) ───────────────────────────────────
  r := pg_temp.sso_acct('Z'); u := pg_temp.sso_get('u_Z'); a := pg_temp.sso_get('a_Z'); b1 := pg_temp.sso_get('Z1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', false);
  b2 := pg_temp.sso_put('Z2', pg_temp.sso_brx(a, 'SSO Z2', x - interval '10 days'));
  PERFORM pg_temp.sso_case('mZc', 'Z', b2, x - interval '30 days');   -- caja en Z2 -> veto
  PERFORM pg_temp.sso_case('mZb', 'Z', b2, x - interval '29 days');   -- banco en Z2 -> veto
  PERFORM pg_temp.sso_case('mZok', 'Z', b2, x - interval '28 days');  -- caja en Z1 (la misma) -> sin veto
  INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (b2, '__gate_sso_cbx_z2__', 'ARS') RETURNING id INTO v_cbx;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cbx, 'open', 0, u) RETURNING id INTO v_ses;
  INSERT INTO public.cash_movements (session_id, amount, movement_type, reference_id, balance_after, created_by)
  VALUES (v_ses, 100, 'sale', pg_temp.sso_get('omZc'), 100, u);
  SELECT id INTO v_cbx FROM public.cashboxes WHERE branch_id = b1 ORDER BY created_at LIMIT 1;
  IF v_cbx IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (b1, '__gate_sso_cbx_z1__', 'ARS') RETURNING id INTO v_cbx;
  END IF;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cbx, 'open', 0, u) RETURNING id INTO v_ses;
  INSERT INTO public.cash_movements (session_id, amount, movement_type, reference_id, balance_after, created_by)
  VALUES (v_ses, 100, 'sale', pg_temp.sso_get('omZok'), 100, u);
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (a, '__gate_sso_bank_z__', 'ARS', 0, TRUE) RETURNING id INTO v_bank;
  INSERT INTO public.bank_movements (bank_account_id, account_id, amount, balance_after, movement_type, source_doc_type, source_doc_ref, branch_id)
  VALUES (v_bank, a, 100, 100, 'transfer_in', 'sale', pg_temp.sso_get('omZb'), b2);

  -- ── G: destino hoy cerrado (B20) ─────────────────────────────────────────────
  r := pg_temp.sso_acct('G'); u := pg_temp.sso_get('u_G'); a := pg_temp.sso_get('a_G'); b1 := pg_temp.sso_get('G1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', true, 'closed', x - interval '2 days');
  b2 := pg_temp.sso_put('G2', pg_temp.sso_brx(a, 'SSO G2', x - interval '10 days'));
  PERFORM pg_temp.sso_case('mGa', 'G', b2, x - interval '40 days');   -- unica: sólo G1 (cerrada y activa)

  -- ── V: empate de created_at (B17) ────────────────────────────────────────────
  r := pg_temp.sso_acct('V'); u := pg_temp.sso_get('u_V'); a := pg_temp.sso_get('a_V'); b1 := pg_temp.sso_get('V1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', true);
  b2 := pg_temp.sso_put('V2', pg_temp.sso_brx(a, 'SSO V2', x - interval '50 days'));
  PERFORM pg_temp.sso_case('mVa', 'V', b2, x + interval '1 day');     -- reconstruida con la elegida empatada -> nulo
  PERFORM pg_temp.sso_case('mVb', 'V', b2, x - interval '60 days');   -- pre_sucursal con la más antigua empatada -> nulo

  -- ── E: evento en el mismo instante que el movimiento (B18) ───────────────────
  r := pg_temp.sso_acct('E'); u := pg_temp.sso_get('u_E'); a := pg_temp.sso_get('a_E'); b1 := pg_temp.sso_get('E1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', false);
  b2 := pg_temp.sso_put('E2', pg_temp.sso_brx(a, 'SSO E2', x - interval '20 days'));
  PERFORM pg_temp.sso_ev(a, b1, 'branch.deactivated', true, 'active', false, 'active', x + interval '4 days');
  PERFORM pg_temp.sso_case('mEa', 'E', b2, x + interval '4 days');                           -- mismo instante -> nulo
  PERFORM pg_temp.sso_case('mEb', 'E', b2, x + interval '4 days' + interval '1 minute');     -- después de la baja -> E2
  PERFORM pg_temp.sso_case('mEc', 'E', b2, x + interval '4 days' - interval '1 minute');     -- antes de la baja -> E1

  -- ── C: eventos contradictorios en el mismo instante (B19) ────────────────────
  r := pg_temp.sso_acct('C'); u := pg_temp.sso_get('u_C'); a := pg_temp.sso_get('a_C'); b1 := pg_temp.sso_get('C1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', false, 'closed', x + interval '10 days');
  b2 := pg_temp.sso_put('C2', pg_temp.sso_brx(a, 'SSO C2', x - interval '20 days'));
  PERFORM pg_temp.sso_ev(a, b1, 'branch.deactivated', true, 'active', false, 'active', x + interval '10 days');
  PERFORM pg_temp.sso_ev(a, b1, 'branch.closed', false, 'active', false, 'closed', x + interval '10 days');
  PERFORM pg_temp.sso_case('mCa', 'C', b2, x + interval '5 days');    -- dos orígenes posibles en el mismo instante -> nulo

  -- ── K: controles intactos (B11) y un movimiento sin cuenta (completa) ────────
  r := pg_temp.sso_acct('K'); u := pg_temp.sso_get('u_K'); a := pg_temp.sso_get('a_K'); b1 := pg_temp.sso_get('K1');
  PERFORM pg_temp.sso_setb(b1, x - interval '50 days', true);
  -- con sucursal ya escrita
  v_s := pg_temp.sso_put('smK_set', pg_temp.sso_sale(u, a, pg_temp.sso_get('p_K'), gen_random_uuid(), b1));
  PERFORM pg_temp.sso_put('mK_set', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), v_s, NULL, b1, x - interval '20 days'));
  -- de otros tipos sobre una venta viva
  v_s := pg_temp.sso_put('smK_ret', pg_temp.sso_sale(u, a, pg_temp.sso_get('p_K'), gen_random_uuid(), b1));
  PERFORM pg_temp.sso_put('mK_ret', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), v_s, NULL, NULL, x - interval '20 days', 'sale_return', 'sale_reversal', 1));
  PERFORM pg_temp.sso_put('mK_pur', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), gen_random_uuid(), NULL, NULL, x - interval '20 days', 'purchase', 'purchase', 1));
  -- de una venta BORRADA: el original y su contramovimiento
  v_dead := gen_random_uuid();
  PERFORM pg_temp.sso_put('mK_dead', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), v_dead, NULL, NULL, x - interval '20 days'));
  PERFORM pg_temp.sso_put('mK_dead_ret', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), v_dead, NULL, NULL, x - interval '20 days', 'sale_return', 'sale_reversal', 1));
  -- con created_at nulo
  PERFORM pg_temp.sso_case('mK_nocreated', 'K', b1, NULL);
  -- el movimiento declara otra cuenta distinta de la de la venta
  v_s := pg_temp.sso_put('smK_other', pg_temp.sso_sale(u, a, pg_temp.sso_get('p_K'), gen_random_uuid(), b1));
  PERFORM pg_temp.sso_put('mK_other', pg_temp.sso_mov(u, pg_temp.sso_get('a_P'), pg_temp.sso_get('p_K'), v_s, NULL, NULL, x - interval '20 days'));
  -- la venta no tiene cuenta
  v_s := pg_temp.sso_put('smK_noacc', pg_temp.sso_sale(u, NULL, pg_temp.sso_get('p_K'), gen_random_uuid(), NULL));
  PERFORM pg_temp.sso_put('mK_noacc', pg_temp.sso_mov(u, a, pg_temp.sso_get('p_K'), v_s, NULL, NULL, x - interval '20 days'));
  -- el movimiento no tiene cuenta (la venta sí): se completa
  v_s := pg_temp.sso_put('smK_noacctmov', pg_temp.sso_sale(u, a, pg_temp.sso_get('p_K'), gen_random_uuid(), b1));
  PERFORM pg_temp.sso_put('mK_noacctmov', pg_temp.sso_mov(u, NULL, pg_temp.sso_get('p_K'), v_s, NULL, NULL, x - interval '20 days'));

  -- ── N: cuenta SIN sucursales ─────────────────────────────────────────────────
  r := pg_temp.sso_acct('N'); u := pg_temp.sso_get('u_N'); a := pg_temp.sso_get('a_N'); b1 := pg_temp.sso_get('N1');
  PERFORM pg_temp.sso_case('mN', 'N', NULL, x - interval '20 days');
  SET session_replication_role = replica;
  DELETE FROM public.cashboxes    WHERE branch_id = b1;
  DELETE FROM public.branch_stock WHERE branch_id = b1;
  DELETE FROM public.branches     WHERE id = b1;
  SET session_replication_role = DEFAULT;
  IF EXISTS (SELECT 1 FROM public.branches WHERE account_id = a) THEN
    RAISE EXCEPTION 'SETUP FAILED (N): la cuenta N conserva sucursales';
  END IF;

  -- Control de la siembra: todos los movimientos 'sale' sin sucursal del fixture que debían quedar.
  SELECT COUNT(*) INTO v_n FROM public.stock_movements sm
  WHERE sm.user_id = ANY(ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'u\_%')) AND sm.type = 'sale' AND sm.reference_type = 'sale' AND sm.branch_id IS NULL;
  IF v_n <> 32 THEN
    RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (setup B): esperaba 32 movimientos sale sin sucursal en el fixture, hay %', v_n;
  END IF;

  INSERT INTO _sso_t (k, v) VALUES
    ('effects_before', pg_temp.sso_effects(ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'a\_%'))),
    ('hash_before',    pg_temp.sso_hash_other());
END $$;

-- ── B.2 Primera corrida del archivo de datos ───────────────────────────────────
\i supabase/migrations/20261077000002_stock_movimientos_sucursal_origen.sql

DO $$
DECLARE
  v_failures text[] := '{}';
  v_accs     uuid[] := ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'a\_%');
  v_rec      record;
  v_actual   uuid;
  v_expected uuid;
  v_md       jsonb;
  v_n        integer;
BEGIN
  -- (B1..B11, B17..B20) la sucursal escrita en cada movimiento del fixture
  FOR v_rec IN SELECT * FROM (VALUES
    ('mP3',  'P1', 'B3 reconstruida, T >= X, la más antigua se dio de baja DESPUÉS de T'),
    ('mP4',  'P2', 'B4 reconstruida, T >= X, la más antigua se dio de baja ANTES de T: la siguiente operativa'),
    ('mP6',  'P1', 'B6 reconstruida, T < X, la más antigua activa y nunca cerrada'),
    ('mP7',  'P1', 'unica: sólo existía P1'),
    ('mP8',  'P1', 'B1 pre_sucursal: sin sucursales todavía, la más antigua (hoy desactivada)'),
    ('mQa',  'Q2', 'B4b reconstruida, T >= X, la más antigua se reactivó después de T: en T no operaba -> la siguiente'),
    ('mQb',  NULL, 'B4b reconstruida, T < X, la más antigua inactiva en la época sin registro: no fechable -> nulo'),
    ('mRa',  NULL, 'B5 reconstruida, T < X, la más antigua inactiva sin fecha: nulo'),
    ('mRb',  'R2', 'reconstruida, T >= X, la más antigua consta inactiva: la siguiente'),
    ('mRc',  'R1', 'unica con la única desactivada'),
    ('mSa',  NULL, 'B7 reconstruida, T < X, la más antigua con closed_at: nulo'),
    ('mSb',  'S1', 'reconstruida, T >= X: closed_at no interviene (el rebobinado es exacto)'),
    ('mUa',  'U1', 'B8 reconstruida sin ninguna operativa conocida: la más antigua de las existentes'),
    ('mUb',  NULL, 'reconstruida, T < X, la más antigua inactiva: nulo'),
    ('mWa',  'W1', 'B1 pre_sucursal con la más antigua desactivada'),
    ('mYa',  'Y1', 'B2 unica con la única desactivada (la venta quedó en Y2)'),
    ('mZc',  NULL, 'B9 veto por caja: la caja de la operación registró otra sucursal'),
    ('mZb',  NULL, 'B10 veto por banco: el movimiento bancario registró otra sucursal'),
    ('mZok', 'Z1', 'caja de la misma sucursal: sin veto'),
    ('mGa',  'G1', 'B20 unica con el origen hoy cerrado'),
    ('mVa',  NULL, 'B17 reconstruida con la elegida empatada en created_at: nulo'),
    ('mVb',  NULL, 'B17 pre_sucursal con la más antigua empatada en created_at: nulo'),
    ('mEa',  NULL, 'B18 evento de ciclo de vida en el mismo instante que el movimiento: nulo'),
    ('mEb',  'E2', 'B18 después de la baja -> E2'),
    ('mEc',  'E1', 'B18 antes de la baja -> E1'),
    ('mCa',  NULL, 'B19 eventos contradictorios en el mismo instante: nulo'),
    ('mK_set',       'K1', 'B11 con sucursal ya escrita: intacto'),
    ('mK_ret',       NULL, 'B11 sale_return: intacto'),
    ('mK_pur',       NULL, 'B11 purchase: intacto'),
    ('mK_dead',      NULL, 'B11 de una venta borrada: intacto'),
    ('mK_dead_ret',  NULL, 'B11 contramovimiento de una venta borrada: intacto'),
    ('mK_nocreated', NULL, 'B11 sin created_at: nulo'),
    ('mK_other',     NULL, 'B11 el movimiento declara otra cuenta: intacto'),
    ('mK_noacc',     NULL, 'B11 venta sin cuenta: intacto'),
    ('mK_noacctmov', 'K1', 'el movimiento sin cuenta de una venta con cuenta se completa (unica)'),
    ('mN',           NULL, 'B11 cuenta sin sucursales: intacto')
  ) AS t(mk, bk, descr) LOOP
    v_actual := pg_temp.sso_mbr(v_rec.mk);
    v_expected := CASE WHEN v_rec.bk IS NULL THEN NULL ELSE pg_temp.sso_get(v_rec.bk) END;
    IF v_actual IS DISTINCT FROM v_expected THEN
      v_failures := array_append(v_failures, format('FAIL (%s) [%s]: debía quedar en %s y quedó en %s', v_rec.mk, v_rec.descr,
        COALESCE(v_rec.bk, 'NULL'), COALESCE(pg_temp.sso_bn(v_actual), 'NULL')));
    END IF;
  END LOOP;

  -- (B12) ninguna otra columna cambia
  IF pg_temp.sso_hash_other() IS DISTINCT FROM (SELECT v FROM _sso_t WHERE k = 'hash_before') THEN
    v_failures := array_append(v_failures, 'FAIL (B12): la migración cambió alguna columna de los movimientos distinta de branch_id (cantidad, cantidades antes y después, costo, tipo, referencias, grupo, cuenta, metadatos o created_at)');
  END IF;

  -- (B15) sin efectos laterales
  IF pg_temp.sso_effects(v_accs) IS DISTINCT FROM (SELECT v FROM _sso_t WHERE k = 'effects_before') THEN
    v_failures := array_append(v_failures, format('FAIL (B15): efectos laterales sobre las cuentas del fixture (events|notifications|analytics|caja|banco|ctas ctes|asientos|stock|órdenes|sale_items|ventas|sucursales): antes %s, después %s',
      (SELECT v FROM _sso_t WHERE k = 'effects_before'), pg_temp.sso_effects(v_accs)));
  END IF;

  -- (B13) una fila de auditoría por cuenta con movimientos completados, con ids por regla y contadores
  -- P
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_P');
  IF v_md IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL (B13 P): falta la fila de auditoría de la cuenta P');
  ELSE
    IF v_md->>'change' IS DISTINCT FROM 'stock-movimientos-sucursal-origen' THEN
      v_failures := array_append(v_failures, format('FAIL (B13 P): metadata.change = %s', v_md->>'change'));
    END IF;
    IF pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mP3','mP4','mP6','mP7','mP8']) THEN
      v_failures := array_append(v_failures, format('FAIL (B13 P): movement_ids = %s', v_md->'movement_ids'));
    END IF;
    IF pg_temp.sso_sorted(v_md#>'{movement_ids_por_regla,pre_sucursal}') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mP8'])
       OR pg_temp.sso_sorted(v_md#>'{movement_ids_por_regla,unica}') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mP7'])
       OR pg_temp.sso_sorted(v_md#>'{movement_ids_por_regla,reconstruida}') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mP3','mP4','mP6']) THEN
      v_failures := array_append(v_failures, format('FAIL (B13 P): movement_ids_por_regla = %s', v_md->'movement_ids_por_regla'));
    END IF;
    IF (v_md->>'no_fechable')::int IS DISTINCT FROM 0 OR (v_md->>'contradiccion')::int IS DISTINCT FROM 0 OR (v_md->>'discrepancia_venta')::int IS DISTINCT FROM 4
       OR (v_md->>'destino_desactivado')::int IS DISTINCT FROM 4 OR (v_md->>'destino_cerrado')::int IS DISTINCT FROM 0 THEN
      v_failures := array_append(v_failures, format('FAIL (B13 P): contadores = no_fechable %s, contradiccion %s, discrepancia_venta %s, destino_desactivado %s, destino_cerrado %s (esperaba 0/0/4/4/0)',
        v_md->>'no_fechable', v_md->>'contradiccion', v_md->>'discrepancia_venta', v_md->>'destino_desactivado', v_md->>'destino_cerrado'));
    END IF;
    IF pg_temp.sso_sorted(v_md->'branch_ids') IS DISTINCT FROM (SELECT jsonb_agg(x ORDER BY x) FROM (SELECT pg_temp.sso_get(k)::text x FROM unnest(ARRAY['P1','P2']) k) s) THEN
      v_failures := array_append(v_failures, format('FAIL (B13 P): branch_ids = %s', v_md->'branch_ids'));
    END IF;
  END IF;
  -- Z (veto)
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_Z');
  IF v_md IS NULL OR pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mZok'])
     OR (v_md->>'contradiccion')::int IS DISTINCT FROM 2 OR (v_md->>'discrepancia_venta')::int IS DISTINCT FROM 1 THEN
    v_failures := array_append(v_failures, format('FAIL (B13 Z): auditoría de la cuenta del veto = %s (esperaba movement_ids = [mZok], contradiccion 2, discrepancia_venta 1)', v_md));
  END IF;
  -- Q, E, G, K
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_Q');
  IF v_md IS NULL OR pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mQa']) OR (v_md->>'no_fechable')::int IS DISTINCT FROM 1 THEN
    v_failures := array_append(v_failures, format('FAIL (B13 Q): auditoría = %s (esperaba movement_ids = [mQa], no_fechable 1)', v_md));
  END IF;
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_E');
  IF v_md IS NULL OR pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mEb','mEc'])
     OR (v_md->>'no_fechable')::int IS DISTINCT FROM 1 OR (v_md->>'destino_desactivado')::int IS DISTINCT FROM 1 THEN
    v_failures := array_append(v_failures, format('FAIL (B13 E): auditoría = %s (esperaba movement_ids = [mEb, mEc], no_fechable 1, destino_desactivado 1)', v_md));
  END IF;
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_G');
  IF v_md IS NULL OR pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mGa'])
     OR (v_md->>'destino_cerrado')::int IS DISTINCT FROM 1 OR (v_md->>'destino_desactivado')::int IS DISTINCT FROM 0 THEN
    v_failures := array_append(v_failures, format('FAIL (B13 G): auditoría = %s (esperaba movement_ids = [mGa], destino_cerrado 1, destino_desactivado 0)', v_md));
  END IF;
  SELECT metadata INTO v_md FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill' AND account_id = pg_temp.sso_get('a_K');
  IF v_md IS NULL OR pg_temp.sso_sorted(v_md->'movement_ids') IS DISTINCT FROM pg_temp.sso_ids(ARRAY['mK_noacctmov']) OR (v_md->>'no_fechable')::int IS DISTINCT FROM 1 THEN
    v_failures := array_append(v_failures, format('FAIL (B13 K): auditoría = %s (esperaba movement_ids = [mK_noacctmov], no_fechable 1)', v_md));
  END IF;
  -- las cuentas sin movimientos completados no dejan fila (V, C, N, R/S/U sí completan alguno; V, C, N no)
  SELECT COUNT(*) INTO v_n FROM public.audit_logs
  WHERE action = 'stock_movements_branch_backfill'
    AND account_id IN (pg_temp.sso_get('a_V'), pg_temp.sso_get('a_C'), pg_temp.sso_get('a_N'));
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (B13): se escribieron %s filas de auditoría para cuentas sin movimientos completados', v_n));
  END IF;
  -- una fila por cuenta (sin duplicados)
  SELECT COUNT(*) INTO v_n FROM (
    SELECT account_id FROM public.audit_logs
    WHERE action = 'stock_movements_branch_backfill' AND account_id = ANY(v_accs)
    GROUP BY account_id HAVING COUNT(*) > 1) d;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (B13): %s cuentas con más de una fila de auditoría', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte B, primera corrida) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  INSERT INTO _sso_t (k, v) VALUES ('snapshot_1', pg_temp.sso_snapshot());
  RAISE NOTICE 'PASS (B1-B13, B17-B20): cada regla (pre_sucursal, unica, reconstruida), el veto, los controles intactos, ninguna otra columna cambia, sin efectos laterales y la auditoría por cuenta con ids por regla y contadores';
END $$;

-- ── B.3 Segunda corrida: ya no hay nada que completar ──────────────────────────
\i supabase/migrations/20261077000002_stock_movimientos_sucursal_origen.sql

DO $$
DECLARE
  v_failures text[] := '{}';
  v_accs     uuid[] := ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'a\_%');
BEGIN
  IF pg_temp.sso_snapshot() IS DISTINCT FROM (SELECT v FROM _sso_t WHERE k = 'snapshot_1') THEN
    v_failures := array_append(v_failures, 'FAIL (B14): la segunda corrida cambió la sucursal de algún movimiento del fixture o escribió auditoría');
  END IF;
  IF pg_temp.sso_hash_other() IS DISTINCT FROM (SELECT v FROM _sso_t WHERE k = 'hash_before') THEN
    v_failures := array_append(v_failures, 'FAIL (B14): la segunda corrida cambió alguna columna de los movimientos');
  END IF;
  IF pg_temp.sso_effects(v_accs) IS DISTINCT FROM (SELECT v FROM _sso_t WHERE k = 'effects_before') THEN
    v_failures := array_append(v_failures, 'FAIL (B14): la segunda corrida tocó algún efecto lateral');
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte B, segunda corrida) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (B14): la segunda corrida no cambia filas, no escribe auditoría ni toca ningún efecto lateral';
END $$;

-- ── B.4 El borrado sobre un movimiento completado en una sucursal desactivada ──
DO $$
DECLARE
  v_failures text[] := '{}';
  v_res   jsonb;
  w1 uuid := pg_temp.sso_get('W1'); w2 uuid := pg_temp.sso_get('W2');
  v_mv    record;
BEGIN
  -- (B16) la venta de mWa quedó con su movimiento en W1 (desactivada): borrarla repone en la principal operativa (W2)
  PERFORM pg_temp.sso_as(pg_temp.sso_get('u_W'));
  v_res := pg_temp.sso_del_sale(pg_temp.sso_get('smWa'), NULL);
  SELECT * INTO v_mv FROM public.stock_movements
  WHERE reference_id = pg_temp.sso_get('smWa') AND reference_type = 'sale_reversal';
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (B16): borrar la venta cuyo movimiento la migración completó con una sucursal desactivada debía pasar, levantó %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF pg_temp.sso_qty(w1, pg_temp.sso_get('p_W')) IS DISTINCT FROM 0 OR pg_temp.sso_qty(w2, pg_temp.sso_get('p_W')) IS DISTINCT FROM 1
        OR v_mv.id IS NULL OR v_mv.branch_id IS DISTINCT FROM w2
        OR (v_mv.metadata->>'fallback_from_branch_id')::uuid IS DISTINCT FROM w1
        OR (v_mv.metadata->>'fallback_reason') IS DISTINCT FROM 'branch_inactive' THEN
    v_failures := array_append(v_failures, format('FAIL (B16): el stock debía volver a la principal operativa (W2 = 1) y no a la desactivada (W1 = 0); W1=%s W2=%s, contramovimiento branch=%s metadata=%s',
      pg_temp.sso_qty(w1, pg_temp.sso_get('p_W')), pg_temp.sso_qty(w2, pg_temp.sso_get('p_W')), pg_temp.sso_bn(v_mv.branch_id), v_mv.metadata));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte B, borrado) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (B16): rpc_delete_sale_operation ejecutada sobre una venta cuyo movimiento quedó en una sucursal desactivada repone en la principal operativa';
END $$;

-- ── B.5 Limpieza ───────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_accs  uuid[] := ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'a\_%');
  v_users uuid[] := ARRAY(SELECT v FROM _sso_k WHERE k LIKE 'u\_%');
  v_brs   uuid[] := ARRAY(SELECT v FROM _sso_k WHERE k ~ '^[A-Z][0-9]$');
  v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.sso_purge(v_accs, v_users);
  SELECT COUNT(*) INTO v_n FROM public.sales WHERE account_id = ANY(v_accs) OR user_id = ANY(v_users);
  IF v_n <> 0 THEN RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (limpieza B): quedaron % ventas del fixture', v_n; END IF;
  SELECT COUNT(*) INTO v_n FROM public.cashboxes WHERE branch_id = ANY(v_brs);
  IF v_n <> 0 THEN RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (limpieza B): quedaron % cajas del fixture', v_n; END IF;
  SELECT COUNT(*) INTO v_n FROM public.branch_stock WHERE branch_id = ANY(v_brs);
  IF v_n <> 0 THEN RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (limpieza B): quedaron % filas de branch_stock del fixture', v_n; END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id = ANY(v_accs) OR user_id = ANY(v_users);
  IF v_n <> 0 THEN RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (limpieza B): quedaron % movimientos de stock del fixture', v_n; END IF;
  SELECT COUNT(*) INTO v_n FROM public.audit_logs WHERE account_id = ANY(v_accs);
  IF v_n <> 0 THEN RAISE EXCEPTION 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (limpieza B): quedaron % filas de auditoría del fixture', v_n; END IF;
  RAISE NOTICE 'GATE STOCK-MOVIMIENTOS-SUCURSAL-ORIGEN (parte B) PASSED: la migración de datos completa la sucursal de origen de los movimientos de venta (pre_sucursal, unica, reconstruida con el estado registrado), veta por caja y banco, deja nulo lo no demostrable, no toca otra columna ni otra tabla salvo audit_logs, es idempotente y el borrado sobre el resultado repone en la principal operativa';
END $$;

-- ROLLBACK y no COMMIT: la migración de datos es GLOBAL (también completa los
-- movimientos nulos que haya en la base, ajenos al fixture). El gate ya verificó todo
-- lo suyo dentro de la transacción (aserciones y residuo cero), así que no deja
-- ningún efecto de la corrida sobre filas que no son del fixture.
ROLLBACK;
