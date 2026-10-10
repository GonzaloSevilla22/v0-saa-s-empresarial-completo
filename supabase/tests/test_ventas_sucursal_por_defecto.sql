-- =============================================================================
-- test_ventas_sucursal_por_defecto.sql — Gate de comportamiento del change
-- `ventas-sucursal-por-defecto` (governance MEDIA con tramo ALTO).
--
-- Decisión del PO (2026-10-01): «sí, que las ventas sin sucursal queden con la
-- principal». Hasta este change el alta de venta resolvía
-- v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta)) y con esa
-- sucursal descontaba el stock, validaba la caja y registraba el banco, pero
-- guardaba el p_branch_id CRUDO (NULL) en sales y en stock_movements: el
-- sistema movía mercadería y plata en la principal y anotaba que la venta "no
-- tenía sucursal". La migración 20261075000001 hace que las tres funciones que
-- escriben ventas persistan la sucursal YA RESUELTA, y 20261075000002 asigna
-- las ventas históricas por reglas de coherencia (design D6).
--
-- Este gate EJECUTA las RPCs (no sólo lee sus cuerpos) contra Postgres real,
-- como el backend, y se divide en dos partes:
--
--   PARTE A (un solo bloque DO, las funciones):
--     (0)  Introspección de los cuerpos VIVOS: persisten la sucursal resuelta,
--          su md5(prosrc sin \r) es el `v_rewritten` del preflight de
--          20261075000001, el COMMENT de la edición se conserva y suma la
--          excepción de D5, una sola firma por función y ACLs intactas.
--          Falla explícito si una reaplicación posterior de CI pisa un cuerpo
--          (lección de `candidatos-db-backend`).
--     (1)  Alta sin sucursal (wrapper -> v2 y v2 directa), con una línea de
--          producto y una de servicio: sales.branch_id y
--          stock_movements.branch_id = la principal; el stock baja en la
--          principal y la otra sucursal queda intacta.
--     (2)  Lo mismo por la RAMA LEGACY del wrapper (flag sale_items_rpc_v2 =
--          false): paridad v2 / legacy.
--     (3)  Con la principal CERRADA, c26_default_branch resuelve la siguiente
--          operativa y la venta y el stock van ahí.
--     (3b) Cuenta con TODAS las sucursales sin operar (una desactivada con
--          stock y otra cerrada): P0422 no_branch_found en la v2, en la legacy
--          y en la edición, sin filas nuevas y sin tocar branch_stock.
--     (4)  Cuenta SIN ninguna sucursal: P0422 no_branch_found en la v2 y en la
--          legacy (producto y servicio), sin filas en sales, operation_
--          idempotency ni stock_movements.
--     (5)  Edición: una venta en B editada con branch_provided=true y NULL pasa
--          a la principal (el REVERSE devuelve a B y el APPLY descuenta de la
--          principal); una fila residual NULL editada sin informar sucursal
--          pasa a la principal; la reimputación explícita no cambia.
--     (6)  Caja y banco: la venta, su movimiento de stock, su movimiento de
--          caja y su movimiento bancario llevan LA MISMA sucursal.
--     (8b) Una venta con sucursal escrita B y B cerrada después:
--          rpc_promote_legacy_sale_to_order EJECUTADA. CARACTERIZACIÓN a
--          propósito (OQ-8 (a)): la orden nace en B cerrada. El candidato
--          «reversa y Facturar venta manual con la sucursal guardada no
--          operativa» lo cambia a conciencia.
--     (9b) Una venta nueva sin sucursal elegida (movimiento en A por D2);
--          después A se vacía por transferencia y se DESACTIVA, y se borra la
--          venta con rpc_delete_sale_operation EJECUTADA. CARACTERIZACIÓN a
--          propósito (OQ-8 (a)): el stock vuelve a A desactivada. El mismo
--          candidato lo cambia a conciencia.
--
--   PARTE B (varios DO + `\i` de la migración de datos, dos veces): el
--     backfill (7), (8) y (9). Se agrega en el grupo 3 del change.
--
-- Patrón del proyecto (test_ventas_formulario_sucursal.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user; sesión simulada con set_config LOCAL a la transacción —
-- NUNCA usar este patrón contra prod.
--
-- 🛑 created_at EXPLÍCITO y estrictamente POSTERIOR en las sucursales sintéticas:
-- c26_default_branch() ordena por created_at SIN desempate y branches.created_at
-- = now() es el timestamp de la TRANSACCIÓN, así que la sucursal que
-- handle_new_user auto-provisiona y las de este fixture nacerían con el MISMO
-- created_at al microsegundo y la "principal" saldría a suerte: el gate sería
-- flaky. Se fuerza y se ASSERTA (vspd_assert_oldest).
--
-- Corre desde la raíz del repo (el `\i` de la parte B es relativo). CI:
-- KPI_Validation.yml (paso propio agregado en el mismo PR).
-- =============================================================================

-- ─── Ayudantes (pg_temp: desaparecen con la sesión) ───────────────────────────
CREATE FUNCTION pg_temp.vspd_as(p_user uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;

-- Cuenta sintética vía handle_new_user: devuelve {user, account, branch} con la
-- sucursal "Casa Central" que handle_new_user auto-provisiona.
CREATE FUNCTION pg_temp.vspd_mk_account(p_email text, p_name text) RETURNS jsonb LANGUAGE plpgsql AS $f$
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
CREATE FUNCTION pg_temp.vspd_mk_branch(p_account uuid, p_name text, p_minutes integer,
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
CREATE FUNCTION pg_temp.vspd_assert_oldest(p_account uuid, p_branch uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT COUNT(*)::integer FROM public.branches b
  WHERE b.account_id = p_account AND b.id <> p_branch
    AND b.created_at <= (SELECT created_at FROM public.branches WHERE id = p_branch)
$f$;

CREATE FUNCTION pg_temp.vspd_mk_product(p_user uuid, p_account uuid, p_sku text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (p_user, p_account, 'Producto ' || p_sku, p_sku, 60.00, 100.00)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.vspd_qty(p_branch uuid, p_product uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE branch_id = p_branch AND product_id = p_product), 0)
$f$;

-- Alta (wrapper o v2) capturando el error: {ok, operation_id} | {ok:false, state, msg}.
CREATE FUNCTION pg_temp.vspd_create(p_v2 boolean, p_key text, p_items jsonb,
                                    p_branch uuid DEFAULT NULL, p_client uuid DEFAULT NULL,
                                    p_pm uuid DEFAULT NULL, p_cash_session uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  IF p_v2 THEN
    r := public.rpc_create_sale_operation_v2(p_key, p_client, public.reporting_local_today(), 'ARS', p_items,
                                             p_branch, NULL, p_pm, p_cash_session, NULL, NULL);
  ELSE
    r := public.rpc_create_sale_operation(p_key, p_client, public.reporting_local_today(), 'ARS', p_items,
                                          p_branch, NULL, p_pm, p_cash_session, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('ok', true, 'operation_id', r->>'operation_id');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Edición capturando el error: {ok, operation_id} | {ok:false, state, msg}.
CREATE FUNCTION pg_temp.vspd_edit(p_ids uuid[], p_items jsonb, p_branch uuid, p_provided boolean,
                                  p_client uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_atomic_update_sale_operation(p_ids, p_client, public.reporting_local_today(), 'ARS', p_items,
                                               NULL, false, p_branch, p_provided, NULL, false);
  RETURN jsonb_build_object('ok', true, 'operation_id', r->>'operation_id');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
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
CREATE FUNCTION pg_temp.vspd_purge(p_accounts uuid[], p_users uuid[]) RETURNS void LANGUAGE plpgsql AS $f$
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
  DELETE FROM public.accounts              WHERE id = ANY(p_accounts);
  DELETE FROM public.profiles              WHERE id = ANY(p_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY(p_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY(p_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY(p_users);
  DELETE FROM auth.users                   WHERE id = ANY(p_users);
  SET session_replication_role = DEFAULT;
END $f$;

-- ═════════════════════════════════════════════════════════════════════════════
-- PARTE A — las tres funciones
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures    text[] := '{}';
  v_fail_before integer;

  -- Cuerpos que deja 20261075000001: md5(replace(prosrc, E'\r', '')), medidos en
  -- el stack local después de aplicarla. Son el `v_rewritten` de su preflight.
  v_md5_v2      constant text := '9fde6d956bc37838e8d81402e22de8fa';
  v_md5_wrapper constant text := 'e5185557021d2f481b9e3f6679c50493';
  v_md5_edit    constant text := '52acb873d8c446c24abb19b79eb43c75';

  -- Cuenta A (principal + B): bloques (1), (2), (5), (6).
  r_a jsonb; v_user_a uuid; v_acc_a uuid; v_a0 uuid; v_b uuid;
  v_client_a uuid; v_p1 uuid; v_p2 uuid;
  v_pm_cash uuid; v_pm_transfer uuid; v_bank_a uuid;
  v_cbx_a uuid; v_cbx_b uuid; v_ses_a uuid;
  -- Cuenta C (principal cerrada): bloque (3).
  r_c jsonb; v_user_c uuid; v_acc_c uuid; v_c0 uuid; v_c1 uuid; v_pc uuid;
  -- Cuenta D (ninguna operativa): bloque (3b).
  r_d jsonb; v_user_d uuid; v_acc_d uuid; v_d0 uuid; v_d1 uuid; v_pd uuid;
  -- Cuenta E (sin sucursales): bloque (4).
  r_e jsonb; v_user_e uuid; v_acc_e uuid; v_e0 uuid; v_pe uuid;
  -- Cuenta F (8b) y cuenta G (9b).
  r_f jsonb; v_user_f uuid; v_acc_f uuid; v_f0 uuid; v_f1 uuid; v_pf uuid;
  r_g jsonb; v_user_g uuid; v_acc_g uuid; v_g0 uuid; v_g1 uuid; v_pg uuid;

  v_res   jsonb;
  v_op    uuid;
  v_ids   uuid[];
  v_n     integer;
  v_val   numeric;
  v_uuid  uuid;
  v_text  text;
  v_oid   oid;
  v_i     integer;
  v_a_before numeric;
  v_b_before numeric;
  v_so    uuid;
  v_md5   text;
  v_src   text;
  v_def   text;
  v_cm    text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup: seis cuentas sintéticas
  -- ═══════════════════════════════════════════════════════════════════════
  r_a := pg_temp.vspd_mk_account('vspd-a@test.local', 'Gate VSPD A');
  v_user_a := (r_a->>'user')::uuid; v_acc_a := (r_a->>'account')::uuid; v_a0 := (r_a->>'branch')::uuid;
  v_b := pg_temp.vspd_mk_branch(v_acc_a, 'Sucursal VSPD B', 1);
  IF pg_temp.vspd_assert_oldest(v_acc_a, v_a0) > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-SUCURSAL-POR-DEFECTO (setup A): sucursales de A empatan o preceden a la auto-provisionada en created_at — c26_default_branch no desempata, el gate sería flaky';
  END IF;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_acc_a, 'Cliente Gate VSPD') RETURNING id INTO v_client_a;
  v_p1 := pg_temp.vspd_mk_product(v_user_a, v_acc_a, 'VSPD-P1');
  v_p2 := pg_temp.vspd_mk_product(v_user_a, v_acc_a, 'VSPD-P2');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p1, v_a0, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p1, v_b, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p2, v_a0, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p2, v_b, 10);

  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_acc_a AND kind = 'cash'     LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_acc_a AND kind = 'transfer' LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_transfer IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: el catálogo de formas de pago no trae cash/transfer para la cuenta A';
  END IF;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_acc_a, '__gate_vspd_bank_a__', 'ARS', 0, TRUE) RETURNING id INTO v_bank_a;
  UPDATE public.payment_methods SET bank_account_id = v_bank_a WHERE id = v_pm_transfer;

  SELECT id INTO v_cbx_a FROM public.cashboxes WHERE branch_id = v_a0 ORDER BY created_at LIMIT 1;
  IF v_cbx_a IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_a0, '__gate_vspd_cashbox_a__', 'ARS') RETURNING id INTO v_cbx_a;
  END IF;
  SELECT id INTO v_cbx_b FROM public.cashboxes WHERE branch_id = v_b ORDER BY created_at LIMIT 1;
  IF v_cbx_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_b, '__gate_vspd_cashbox_b__', 'ARS') RETURNING id INTO v_cbx_b;
  END IF;

  -- C: la principal (la más antigua) CERRADA — vacía, así que el guard de baja la deja pasar.
  r_c := pg_temp.vspd_mk_account('vspd-c@test.local', 'Gate VSPD C');
  v_user_c := (r_c->>'user')::uuid; v_acc_c := (r_c->>'account')::uuid; v_c0 := (r_c->>'branch')::uuid;
  UPDATE public.branches SET status = 'closed', closed_at = now() WHERE id = v_c0;
  v_c1 := pg_temp.vspd_mk_branch(v_acc_c, 'Sucursal VSPD C1 (la siguiente operativa)', 1);
  IF pg_temp.vspd_assert_oldest(v_acc_c, v_c0) > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-SUCURSAL-POR-DEFECTO (setup C): empate de created_at';
  END IF;
  v_pc := pg_temp.vspd_mk_product(v_user_c, v_acc_c, 'VSPD-PC');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_c, v_pc, v_c1, 50);

  -- D: NINGUNA sucursal operativa. D0 (auto) desactivada estando vacía; D1 cerrada.
  -- Después se le carga stock a D0 directo (el estado posterior al incidente del
  -- 22-08: una sucursal dada de baja que volvió a recibir stock).
  r_d := pg_temp.vspd_mk_account('vspd-d@test.local', 'Gate VSPD D');
  v_user_d := (r_d->>'user')::uuid; v_acc_d := (r_d->>'account')::uuid; v_d0 := (r_d->>'branch')::uuid;
  UPDATE public.branches SET is_active = FALSE WHERE id = v_d0;
  v_d1 := pg_temp.vspd_mk_branch(v_acc_d, 'Sucursal VSPD D1 (cerrada)', 1, 'closed', TRUE);
  IF pg_temp.vspd_assert_oldest(v_acc_d, v_d0) > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-SUCURSAL-POR-DEFECTO (setup D): empate de created_at';
  END IF;
  v_pd := pg_temp.vspd_mk_product(v_user_d, v_acc_d, 'VSPD-PD');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_d, v_pd, v_d0, 20);

  -- E: SIN ninguna sucursal. El borrado de la sembrada exige session_replication_role
  -- = replica (esquiva trg_guard_branch_decommission) y en ese modo NO corren las
  -- acciones de FK: antes del DELETE se borran explícitamente sus cajas (que
  -- handle_new_user siembra y no tienen account_id) y su stock.
  r_e := pg_temp.vspd_mk_account('vspd-e@test.local', 'Gate VSPD E');
  v_user_e := (r_e->>'user')::uuid; v_acc_e := (r_e->>'account')::uuid; v_e0 := (r_e->>'branch')::uuid;
  v_pe := pg_temp.vspd_mk_product(v_user_e, v_acc_e, 'VSPD-PE');
  SET session_replication_role = replica;
  DELETE FROM public.cashboxes    WHERE branch_id = v_e0;
  DELETE FROM public.branch_stock WHERE branch_id = v_e0;
  DELETE FROM public.branches     WHERE id = v_e0;
  SET session_replication_role = DEFAULT;
  IF EXISTS (SELECT 1 FROM public.branches WHERE account_id = v_acc_e) THEN
    RAISE EXCEPTION 'SETUP FAILED (E): la cuenta E conserva sucursales';
  END IF;

  -- F (8b): F0 principal, F1 con stock 3 que se vende entero y después se cierra.
  r_f := pg_temp.vspd_mk_account('vspd-f@test.local', 'Gate VSPD F');
  v_user_f := (r_f->>'user')::uuid; v_acc_f := (r_f->>'account')::uuid; v_f0 := (r_f->>'branch')::uuid;
  v_f1 := pg_temp.vspd_mk_branch(v_acc_f, 'Sucursal VSPD F1', 1);
  IF pg_temp.vspd_assert_oldest(v_acc_f, v_f0) > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-SUCURSAL-POR-DEFECTO (setup F): empate de created_at';
  END IF;
  v_pf := pg_temp.vspd_mk_product(v_user_f, v_acc_f, 'VSPD-PF');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_f, v_pf, v_f1, 3);

  -- G (9b): G0 principal con stock 5; G1 recibirá lo que quede cuando G0 se vacíe.
  r_g := pg_temp.vspd_mk_account('vspd-g@test.local', 'Gate VSPD G');
  v_user_g := (r_g->>'user')::uuid; v_acc_g := (r_g->>'account')::uuid; v_g0 := (r_g->>'branch')::uuid;
  v_g1 := pg_temp.vspd_mk_branch(v_acc_g, 'Sucursal VSPD G1', 1);
  IF pg_temp.vspd_assert_oldest(v_acc_g, v_g0) > 0 THEN
    RAISE EXCEPTION 'GATE VENTAS-SUCURSAL-POR-DEFECTO (setup G): empate de created_at';
  END IF;
  v_pg := pg_temp.vspd_mk_product(v_user_g, v_acc_g, 'VSPD-PG');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_g, v_pg, v_g0, 5);

  -- ═══════════════════════════════════════════════════════════════════════
  -- (0) Introspección de los cuerpos VIVOS
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  FOR v_text IN SELECT unnest(ARRAY['rpc_create_sale_operation_v2', 'rpc_create_sale_operation', 'rpc_atomic_update_sale_operation']) LOOP
    SELECT COUNT(*) INTO v_n FROM pg_proc WHERE proname = v_text AND pronamespace = 'public'::regnamespace;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (0 firma): %s debía tener UNA sola firma (sin overload 42725), tiene %s', v_text, v_n));
    END IF;
    SELECT p.oid INTO v_oid FROM pg_proc p WHERE p.proname = v_text AND p.pronamespace = 'public'::regnamespace LIMIT 1;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      v_failures := array_append(v_failures, format('FAIL (0 ACL): %s tiene EXECUTE para anon', v_text));
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      v_failures := array_append(v_failures, format('FAIL (0 ACL): %s perdió EXECUTE para authenticated o service_role', v_text));
    END IF;
  END LOOP;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_create_sale_operation_v2' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_v2 THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 v2): el cuerpo vivo de rpc_create_sale_operation_v2 mide %s y el de la migración es %s (¿un reapply posterior de CI lo pisó, o persiste p_branch_id crudo?)', v_md5, v_md5_v2));
  END IF;
  IF v_src ~ 'p_branch_id,\s*v_canal' OR v_src ~ 'v_new_op_id,\s*p_branch_id' THEN
    v_failures := array_append(v_failures, 'FAIL (0 v2): la v2 todavía persiste p_branch_id CRUDO en sales o en stock_movements (tiene que ser v_gate_branch)');
  END IF;
  IF position('no_branch_found' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 v2): la v2 no tiene el guard P0422 no_branch_found');
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_create_sale_operation' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_wrapper THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 wrapper): el cuerpo vivo de rpc_create_sale_operation mide %s y el de la migración es %s', v_md5, v_md5_wrapper));
  END IF;
  IF v_src ~ 'p_branch_id,\s*v_canal' OR v_src ~ 'v_new_op_id,\s*p_branch_id' THEN
    v_failures := array_append(v_failures, 'FAIL (0 legacy): la rama legacy del wrapper todavía persiste p_branch_id CRUDO (paridad con la v2)');
  END IF;
  IF position('no_branch_found' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 legacy): la rama legacy no tiene el guard P0422 no_branch_found');
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_atomic_update_sale_operation' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_edit THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 edición): el cuerpo vivo de rpc_atomic_update_sale_operation mide %s y el de la migración es %s (¿un reapply de 20261070000001 lo pisó?)', v_md5, v_md5_edit));
  END IF;
  IF position('no_branch_found' IN v_src) = 0 OR position('c26_default_branch(v_account_id)' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 edición): la edición no resuelve la principal ni tiene el guard P0422 no_branch_found');
  END IF;
  SELECT obj_description('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)'::regprocedure, 'pg_proc') INTO v_cm;
  IF v_cm IS NULL OR position('preserva branch_id/canal/unit_id al editar' IN v_cm) = 0 OR position('ventas-sucursal-por-defecto' IN v_cm) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 COMMENT): el COMMENT de la edición tiene que conservar su texto vivo y sumar la excepción de ventas-sucursal-por-defecto (D5)');
  END IF;
  IF obj_description('public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)'::regprocedure, 'pg_proc') IS NOT NULL
     OR obj_description('public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)'::regprocedure, 'pg_proc') IS NOT NULL THEN
    v_failures := array_append(v_failures, 'FAIL (0 COMMENT): la v2 y el wrapper no tenían COMMENT y la migración no debe agregarles uno');
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (0): cuerpos vivos con la sucursal resuelta en los seis INSERT y el guard, md5 = el del preflight, COMMENT de la edición conservado más la excepción de D5, una firma por función, ACLs intactas';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (1) Alta sin sucursal: wrapper (-> v2) y v2 directa, producto + servicio
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_a);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION 'SETUP FAILED: auth.uid() no resuelve a la cuenta A con request.jwt.claims local — el gate no puede invocar las RPCs';
  END IF;

  FOR v_i IN 1..2 LOOP  -- 1 = wrapper (que delega en la v2), 2 = v2 directa
    v_a_before := pg_temp.vspd_qty(v_a0, v_p1);
    v_b_before := pg_temp.vspd_qty(v_b, v_p1);
    v_res := pg_temp.vspd_create(v_i = 2, 'vspd-1-' || v_i || '-' || gen_random_uuid()::text,
      jsonb_build_array(
        jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2),
        jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)),
      NULL, v_client_a);
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (1.%s alta): el alta sin sucursal debía pasar, falló con %s / %s', v_i, v_res->>'state', v_res->>'msg'));
      CONTINUE;
    END IF;
    v_op := (v_res->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 líneas): la operación debía tener 2 filas en sales, tiene %s', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_a0;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 sales.branch_id): las 2 líneas (producto y servicio) debían quedar con la PRINCIPAL %s, %s la tienen — sales.branch_id NULL es lo que este change elimina', v_a0, v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm
    WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock_movements.branch_id): el movimiento de stock debía llevar la principal, %s lo llevan', v_n));
    END IF;
    IF pg_temp.vspd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before - 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock principal): branch_stock de la principal debía bajar de %s a %s, quedó %s', v_a_before, v_a_before - 2, pg_temp.vspd_qty(v_a0, v_p1)));
    END IF;
    IF pg_temp.vspd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock B): la otra sucursal no debía tocarse (era %s), quedó %s', v_b_before, pg_temp.vspd_qty(v_b, v_p1)));
    END IF;
  END LOOP;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (1): alta sin sucursal (wrapper y v2) — sales.branch_id y stock_movements.branch_id = la principal en producto y servicio; el stock baja en la principal y la otra sucursal queda intacta';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (2) Rama LEGACY del wrapper (flag sale_items_rpc_v2 = false): paridad
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled) VALUES (v_acc_a, 'sale_items_rpc_v2', FALSE)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = FALSE;

  v_a_before := pg_temp.vspd_qty(v_a0, v_p1);
  v_b_before := pg_temp.vspd_qty(v_b, v_p1);
  v_res := pg_temp.vspd_create(FALSE, 'vspd-2-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2),
      jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)),
    NULL, v_client_a);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (2 alta): el alta legacy sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    -- Prueba de que corrió la rama LEGACY y no la delegación: la legacy no escribe sale_items.
    SELECT COUNT(*) INTO v_n FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id WHERE s.operation_id = v_op;
    IF v_n <> 0 THEN
      v_failures := array_append(v_failures, format('FAIL (2 rama): con el flag apagado no debía correr la v2 (hay %s sale_items) — el bloque no prueba la rama legacy', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_a0;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (2 sales.branch_id): la rama legacy debía guardar la PRINCIPAL en las 2 líneas, %s la tienen — paridad con la v2', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm
    WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (2 stock_movements.branch_id): la rama legacy debía guardar la principal en el movimiento, %s lo llevan', v_n));
    END IF;
    IF pg_temp.vspd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before - 2 OR pg_temp.vspd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before THEN
      v_failures := array_append(v_failures, format('FAIL (2 stock): la rama legacy debía descontar 2 de la principal (%s -> %s) y no tocar B (%s), quedó A=%s B=%s', v_a_before, v_a_before - 2, v_b_before, pg_temp.vspd_qty(v_a0, v_p1), pg_temp.vspd_qty(v_b, v_p1)));
    END IF;
  END IF;
  DELETE FROM public.account_feature_flags WHERE account_id = v_acc_a AND flag_key = 'sale_items_rpc_v2';
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2): rama legacy del wrapper — paridad con la v2: sales.branch_id y stock_movements.branch_id = la principal';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (3) Principal CERRADA: la venta y el stock van a la siguiente operativa
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_c);
  v_res := pg_temp.vspd_create(TRUE, 'vspd-3-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('product_id', v_pc, 'amount', 100.00, 'quantity', 2),
      jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)));
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (3 alta): con la más antigua cerrada la venta debía resolverse a la siguiente operativa, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_c1;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (3 sales.branch_id): con la más antigua cerrada la venta debía quedar en la siguiente operativa %s, %s filas', v_c1, v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id = v_c1;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (3 stock_movements.branch_id): el movimiento debía llevar la siguiente operativa, %s lo llevan', v_n));
    END IF;
    IF pg_temp.vspd_qty(v_c1, v_pc) IS DISTINCT FROM 48 THEN
      v_failures := array_append(v_failures, format('FAIL (3 stock): la siguiente operativa debía quedar en 48, quedó %s', pg_temp.vspd_qty(v_c1, v_pc)));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_c0;
    IF v_n <> 0 THEN
      v_failures := array_append(v_failures, 'FAIL (3 cerrada): ninguna fila de la venta podía quedar en la sucursal cerrada');
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (3): con la más antigua cerrada la venta, su movimiento y el stock van a la siguiente operativa';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (3b) Ninguna sucursal operativa: P0422 no_branch_found en v2, legacy y edición
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_d);

  -- v2: producto con stock en la sucursal desactivada (con el cuerpo viejo se descuenta de ahí)
  v_a_before := pg_temp.vspd_qty(v_d0, v_pd);
  v_res := pg_temp.vspd_create(TRUE, 'vspd-3b-v2-prod', jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b v2 producto): sin ninguna sucursal operativa la v2 debía rechazar con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  -- v2: sólo servicios (con el cuerpo viejo pasaba con branch_id NULL)
  v_res := pg_temp.vspd_create(TRUE, 'vspd-3b-v2-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b v2 servicio): una venta sólo de servicios sin ninguna sucursal operativa debía rechazarse con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;

  -- legacy (flag apagado para D)
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled) VALUES (v_acc_d, 'sale_items_rpc_v2', FALSE)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = FALSE;
  v_res := pg_temp.vspd_create(FALSE, 'vspd-3b-leg-prod', jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b legacy producto): la rama legacy debía rechazar con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  v_res := pg_temp.vspd_create(FALSE, 'vspd-3b-leg-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b legacy servicio): la rama legacy debía rechazar con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  DELETE FROM public.account_feature_flags WHERE account_id = v_acc_d AND flag_key = 'sale_items_rpc_v2';

  SELECT COUNT(*) INTO v_n FROM public.sales WHERE account_id = v_acc_d;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b sales): los rechazos no debían dejar filas en sales, quedaron %s', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE idempotency_key LIKE 'vspd-3b-%';
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b idempotencia): los rechazos dejaron %s fila(s) en operation_idempotency', v_n));
  END IF;
  IF pg_temp.vspd_qty(v_d0, v_pd) IS DISTINCT FROM v_a_before THEN
    v_failures := array_append(v_failures, format('FAIL (3b stock): los rechazos no debían tocar branch_stock de la sucursal desactivada (era %s, quedó %s)', v_a_before, pg_temp.vspd_qty(v_d0, v_pd)));
  END IF;

  -- edición: fila residual NULL, sin informar sucursal
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_d, v_acc_d, NULL, 80, 1, 80, 'ARS', public.reporting_local_today(), v_op, NULL)
  RETURNING id INTO v_uuid;
  v_res := pg_temp.vspd_edit(ARRAY[v_uuid], jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 90.00, 'quantity', 1)), NULL, FALSE);
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3b edición): sin ninguna sucursal operativa la edición de una fila sin sucursal debía rechazarse con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.sales WHERE id = v_uuid AND amount = 80;
  IF v_n <> 1 THEN
    v_failures := array_append(v_failures, 'FAIL (3b edición): el rechazo de la edición no debía tocar la fila original');
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (3b): sin ninguna sucursal operativa la v2, la legacy y la edición rechazan con P0422 no_branch_found, sin filas nuevas ni cambios en branch_stock';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (4) Cuenta SIN ninguna sucursal: P0422 no_branch_found
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_e);

  v_res := pg_temp.vspd_create(TRUE, 'vspd-4-v2-prod', jsonb_build_array(jsonb_build_object('product_id', v_pe, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 v2 producto): una cuenta sin sucursales debía rechazar con P0422 no_branch_found (hoy da P0409), obtuvo %s', v_res::text));
  END IF;
  v_res := pg_temp.vspd_create(TRUE, 'vspd-4-v2-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 v2 servicio): una venta sólo de servicios en una cuenta sin sucursales debía rechazarse (hoy pasa con branch_id NULL), obtuvo %s', v_res::text));
  END IF;
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled) VALUES (v_acc_e, 'sale_items_rpc_v2', FALSE)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = FALSE;
  v_res := pg_temp.vspd_create(FALSE, 'vspd-4-leg-prod', jsonb_build_array(jsonb_build_object('product_id', v_pe, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 legacy producto): la rama legacy debía rechazar con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  v_res := pg_temp.vspd_create(FALSE, 'vspd-4-leg-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)));
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 legacy servicio): la rama legacy debía rechazar con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  DELETE FROM public.account_feature_flags WHERE account_id = v_acc_e AND flag_key = 'sale_items_rpc_v2';

  SELECT COUNT(*) INTO v_n FROM public.sales WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 sales): los rechazos no debían dejar filas en sales, quedaron %s', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE idempotency_key LIKE 'vspd-4-%';
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 idempotencia): los rechazos dejaron %s fila(s) en operation_idempotency', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 stock_movements): los rechazos no debían dejar movimientos, quedaron %s', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.branches WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, 'FAIL (4 sucursales): el rechazo no debía crear una "Casa Central" al vuelo');
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (4): una cuenta sin sucursales rechaza con P0422 no_branch_found en la v2 y la legacy (producto y servicio), sin filas en sales, operation_idempotency ni stock_movements';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (5) Edición: NULL (informado o vigente) se resuelve a la principal
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_a);

  -- (5a) venta en B editada con branch_provided = true y NULL -> la principal
  v_res := pg_temp.vspd_create(TRUE, 'vspd-5a-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)), v_b, v_client_a);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (5a setup): la venta en B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT array_agg(id) INTO v_ids FROM public.sales WHERE operation_id = v_op;
    v_a_before := pg_temp.vspd_qty(v_a0, v_p1);
    v_b_before := pg_temp.vspd_qty(v_b, v_p1);
    v_res := pg_temp.vspd_edit(v_ids, jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)), NULL, TRUE, v_client_a);
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (5a edición): la edición con sucursal informada NULL debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
    ELSE
      v_op := (v_res->>'operation_id')::uuid;
      SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_a0;
      IF v_n <> 1 THEN
        v_failures := array_append(v_failures, format('FAIL (5a sales.branch_id): informar branch_id NULL al editar una venta debía asignar la PRINCIPAL %s (D5, BREAKING declarado), %s filas la tienen', v_a0, v_n));
      END IF;
      IF pg_temp.vspd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before + 2 OR pg_temp.vspd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before - 2 THEN
        v_failures := array_append(v_failures, format('FAIL (5a stock): el REVERSE devuelve 2 a B (%s -> %s) y el APPLY descuenta 2 de la principal (%s -> %s); quedó B=%s A=%s', v_b_before, v_b_before + 2, v_a_before, v_a_before - 2, pg_temp.vspd_qty(v_b, v_p1), pg_temp.vspd_qty(v_a0, v_p1)));
      END IF;
      SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.reference_type = 'sale' AND sm.branch_id = v_a0;
      IF v_n <> 1 THEN
        v_failures := array_append(v_failures, format('FAIL (5a movimiento): el movimiento de la pata APPLY debía llevar la principal, %s lo llevan', v_n));
      END IF;
      v_ids := ARRAY(SELECT id FROM public.sales WHERE operation_id = v_op);
    END IF;

    -- (5c) reimputación explícita a B: sin cambios de comportamiento
    IF v_ids IS NOT NULL AND (v_res->>'ok')::boolean THEN
      v_res := pg_temp.vspd_edit(v_ids, jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)), v_b, TRUE, v_client_a);
      IF NOT (v_res->>'ok')::boolean THEN
        v_failures := array_append(v_failures, format('FAIL (5c reimputación): reimputar a B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
      ELSE
        SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid AND branch_id = v_b;
        IF v_n <> 1 THEN
          v_failures := array_append(v_failures, format('FAIL (5c sales.branch_id): la reimputación explícita a B debía quedar en B, %s filas', v_n));
        END IF;
      END IF;
    END IF;
  END IF;

  -- (5b) fila residual NULL editada sin informar sucursal -> la principal
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, v_client_a, v_p2, 100, 1, 100, 'ARS', public.reporting_local_today(), v_op, NULL)
  RETURNING id INTO v_uuid;
  v_a_before := pg_temp.vspd_qty(v_a0, v_p2);
  v_res := pg_temp.vspd_edit(ARRAY[v_uuid], jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)), NULL, FALSE, v_client_a);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (5b edición): editar la fila residual sin informar sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid AND branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (5b sales.branch_id): una fila vigente sin sucursal, editada sin informar sucursal, debía quedar en la PRINCIPAL (hoy conserva NULL), %s filas', v_n));
    END IF;
    IF pg_temp.vspd_qty(v_a0, v_p2) IS DISTINCT FROM v_a_before THEN
      v_failures := array_append(v_failures, format('FAIL (5b stock): el REVERSE de una fila NULL cae en la principal y el APPLY descuenta de la misma: el neto es cero (era %s), quedó %s', v_a_before, pg_temp.vspd_qty(v_a0, v_p2)));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (5): edición — NULL informado o vigente se resuelve a la principal (REVERSE y APPLY netos); la reimputación explícita no cambia';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (6) Caja y banco: venta, stock, caja y banco en la MISMA sucursal
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT public.rpc_open_cash_session(v_cbx_a, 500) INTO v_res;
  v_ses_a := COALESCE((v_res->>'session_id')::uuid, (v_res->>'id')::uuid);
  IF v_ses_a IS NULL THEN
    SELECT id INTO v_ses_a FROM public.cash_sessions WHERE cashbox_id = v_cbx_a AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;
  IF v_ses_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (6): no se pudo abrir la sesión de caja de la principal';
  END IF;

  -- (6a) efectivo con opt-in de caja: la sesión es la de la principal (la sucursal efectiva)
  v_res := pg_temp.vspd_create(TRUE, 'vspd-6a-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 2)), NULL, v_client_a, v_pm_cash, v_ses_a);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (6a): la venta en efectivo sin sucursal elegida con la sesión de la principal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_ses_a AND reference_id = v_op AND movement_type = 'sale' AND amount = 200;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (6a caja): el movimiento de caja (sale, 200) debía quedar en la sesión de la principal, hay %s', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.sales WHERE operation_id = v_op AND branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, 'FAIL (6a sales.branch_id): la venta en efectivo con caja de la principal debía llevar la principal en sales');
    END IF;
  END IF;

  -- (6b) transferencia: venta, movimiento de stock y movimiento bancario en la MISMA sucursal
  v_res := pg_temp.vspd_create(TRUE, 'vspd-6b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)), NULL, v_client_a, v_pm_transfer);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (6b): la venta por transferencia sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT branch_id INTO v_uuid FROM public.bank_movements WHERE source_doc_type = 'sale' AND source_doc_ref = v_op;
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (6b banco): el movimiento bancario debía llevar la principal %s, lleva %s', v_a0, v_uuid));
    END IF;
    SELECT branch_id INTO v_uuid FROM public.sales WHERE operation_id = v_op;
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (6b sales.branch_id): la venta debía llevar la MISMA sucursal que el banco (la principal %s), lleva %s — venta NULL con banco en la principal es la inconsistencia que este change elimina', v_a0, v_uuid));
    END IF;
    SELECT branch_id INTO v_uuid FROM public.stock_movements WHERE operation_group_id = v_op AND reference_type = 'sale';
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (6b stock_movements.branch_id): el movimiento de stock debía llevar la MISMA sucursal que el banco (%s), lleva %s', v_a0, v_uuid));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (6): caja y banco — venta, movimiento de stock, movimiento de caja y movimiento bancario llevan la MISMA sucursal (la principal)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (8b) Venta con sucursal escrita B y B cerrada después: Facturar venta manual
  --      (CARACTERIZACIÓN a propósito — OQ-8 (a))
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_f);
  v_res := pg_temp.vspd_create(TRUE, 'vspd-8b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_pf, 'amount', 100.00, 'quantity', 3)), v_f1);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (8b setup): la venta de las 3 unidades desde F1 debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    -- F1 queda sin stock, sin caja abierta y sin transferencias: el guard de baja la deja cerrar.
    UPDATE public.branches SET status = 'closed', closed_at = now() WHERE id = v_f1;
    BEGIN
      v_so := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
      SELECT branch_id INTO v_uuid FROM public.sales_orders WHERE id = v_so;
      IF v_uuid IS DISTINCT FROM v_f1 THEN
        v_failures := array_append(v_failures, format('FAIL (8b): CARACTERIZACIÓN de OQ-8 (a): Facturar venta manual sobre una venta cuya sucursal guardada (F1) quedó CERRADA crea hoy la orden en esa sucursal cerrada, sin validar que opere. La orden nació en %s (F1=%s, principal=%s). Si esto cambió, lo cambió el candidato «reversa y Facturar venta manual con la sucursal guardada no operativa»: actualizar este bloque a propósito.', v_uuid, v_f1, v_f0));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (8b): CARACTERIZACIÓN de OQ-8 (a): la promoción sobre una venta con sucursal cerrada debía crear la orden en esa sucursal (comportamiento actual), levantó %s / %s. Si esto cambió, lo cambió el candidato «reversa y Facturar venta manual con la sucursal guardada no operativa»: actualizar este bloque a propósito.', SQLSTATE, SQLERRM));
    END;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (8b): caracterización de OQ-8 (a) — Facturar venta manual sobre una venta cuya sucursal guardada está cerrada crea la orden en esa sucursal (candidato aparte)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (9b) Venta sin sucursal elegida; A se vacía por transferencia y se DESACTIVA;
  --      se borra la venta (CARACTERIZACIÓN a propósito — OQ-8 (a))
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.vspd_as(v_user_g);
  v_res := pg_temp.vspd_create(TRUE, 'vspd-9b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_pg, 'amount', 100.00, 'quantity', 2)));
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (9b setup): la venta sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    -- Se vacía G0 (lo que queda: 3) por transferencia a G1 y se desactiva.
    PERFORM public.c21_apply_branch_stock_delta(v_acc_g, v_pg, v_g0, -3);
    PERFORM public.c21_apply_branch_stock_delta(v_acc_g, v_pg, v_g1, 3);
    UPDATE public.branches SET is_active = FALSE WHERE id = v_g0;
    BEGIN
      PERFORM public.rpc_delete_sale_operation(NULL, v_op, 'gate 9b');
      v_val := pg_temp.vspd_qty(v_g0, v_pg);
      IF v_val IS DISTINCT FROM 2 OR pg_temp.vspd_qty(v_g1, v_pg) IS DISTINCT FROM 3 THEN
        v_failures := array_append(v_failures, format('FAIL (9b): CARACTERIZACIÓN de OQ-8 (a): al borrar una venta sin sucursal elegida cuya principal se vació y se desactivó, el stock vuelve hoy a la sucursal del movimiento (G0 desactivada), que no se ve ni se puede reactivar desde la app. Esperaba G0=2 y G1=3, quedó G0=%s y G1=%s. Si esto cambió, lo cambió el candidato «reversa y Facturar venta manual con la sucursal guardada no operativa»: actualizar este bloque a propósito.', v_val, pg_temp.vspd_qty(v_g1, v_pg)));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (9b): CARACTERIZACIÓN de OQ-8 (a): el borrado debía reponer el stock en G0 desactivada (comportamiento actual), levantó %s / %s. Si esto cambió, lo cambió el candidato «reversa y Facturar venta manual con la sucursal guardada no operativa»: actualizar este bloque a propósito.', SQLSTATE, SQLERRM));
    END;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (9b): caracterización de OQ-8 (a) — el borrado repone el stock en la sucursal del movimiento aunque esté desactivada (candidato aparte)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado y limpieza
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.vspd_purge(
    ARRAY[v_acc_a, v_acc_c, v_acc_d, v_acc_e, v_acc_f, v_acc_g],
    ARRAY[v_user_a, v_user_c, v_user_d, v_user_e, v_user_f, v_user_g]);

  -- Residuo cero: las cajas y el stock de las sucursales sintéticas (dependencias
  -- sin account_id propio que sólo la limpieza explícita alcanza).
  SELECT COUNT(*) INTO v_n FROM public.cashboxes WHERE branch_id IN (v_a0, v_b, v_c0, v_c1, v_d0, v_d1, v_e0, v_f0, v_f1, v_g0, v_g1);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s cajas de las sucursales sintéticas', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.branch_stock WHERE branch_id IN (v_a0, v_b, v_c0, v_c1, v_d0, v_d1, v_e0, v_f0, v_f1, v_g0, v_g1);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s filas de branch_stock de las sucursales sintéticas', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE VENTAS-SUCURSAL-POR-DEFECTO (parte A) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE VENTAS-SUCURSAL-POR-DEFECTO (parte A) PASSED: las tres funciones persisten la sucursal resuelta (la elegida o la principal operativa) en sales y stock_movements, con paridad v2/legacy; sin sucursal operativa rechazan con P0422 no_branch_found; la edición resuelve NULL a la principal; y la caracterización de OQ-8 (a) queda fijada.';
END $$;
