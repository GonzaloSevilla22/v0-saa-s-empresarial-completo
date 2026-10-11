-- =============================================================================
-- test_compras_gastos_sucursal_por_defecto.sql — Gate de comportamiento del
-- change `compras-gastos-sucursal-por-defecto` (governance MEDIA con tramo ALTO).
--
-- Decisión del PO (2026-10-11, «vamos con todo lo recomendado»): las compras y
-- los gastos sin sucursal elegida se guardan con la sucursal PRINCIPAL, como ya
-- hace la venta (`ventas-sucursal-por-defecto`). Hasta este change el alta de
-- compra resolvía la principal por DENTRO de c21_apply_branch_stock_delta para
-- mover el stock, pero guardaba el p_branch_id CRUDO (NULL) en purchases,
-- stock_movements y bank_movements, y comparaba la sesión de caja contra ese NULL:
-- el opt-in de caja que el formulario ofrece PRE-MARCADO se rechazaba SIEMPRE con
-- P0422 cash_optin_requires_open_session. Y la edición de compra y de gasto
-- podía dejar (o conservar) una fila sin sucursal.
--
-- La migración 20261076000001 hace que tres funciones persistan la sucursal YA
-- RESUELTA (design D1-D5):
--   rpc_create_purchase_operation        v_gate_branch en los dos INSERT de
--       purchases, en el delta de stock, en el movimiento de stock, en la
--       condición de caja y en el banco; guard P0422 no_branch_found si no hay
--       sucursal operativa; P0422 branch_closed para una elegida cerrada (OQ-2).
--   rpc_atomic_update_purchase_operation NULL (informado o vigente) = la principal,
--       con el mismo guard, ANTES de la pata REVERSE.
--   rpc_update_expense                   NULL (informado o vigente) = la principal
--       (la regla literal del alta del gasto, OQ-3 (a): sin guard).
-- Las compras y los gastos históricos NO se rellenan (OQ-1 (a)): toman la
-- principal cuando alguien los edita.
--
-- Este gate EJECUTA las RPCs (no sólo lee sus cuerpos) contra Postgres real,
-- como el backend. Un solo bloque DO (cuatro cuentas sintéticas):
--
--   (0)  Introspección de los cuerpos VIVOS: persisten la sucursal resuelta, su
--        md5(prosrc sin \r) es el `v_rewritten` del preflight de 20261076000001,
--        los COMMENT (el de la edición de compra se conserva; el de la edición de
--        gasto suma la excepción), una firma por función y ACLs intactas. Falla
--        explícito si una reaplicación posterior de CI pisa un cuerpo.
--   (1)  Alta sin sucursal, con una línea de producto y una de servicio: las dos
--        filas de purchases, el movimiento de stock y el branch_stock en la
--        principal; la otra sucursal intacta; el ledger reconstruye por
--        (producto, sucursal); un reintento con la misma clave no duplica nada.
--        (1b) elegida B: todo en B.
--   (2)  Con la principal CERRADA la compra y el stock van a la siguiente operativa.
--   (3)  Cuenta con TODAS las sucursales sin operar: P0422 no_branch_found con
--        producto y sin producto, sin filas, sin idempotencia y sin tocar stock.
--   (4)  Cuenta SIN ninguna sucursal: P0422 no_branch_found y NINGUNA sucursal
--        creada (c21 ya no llega a crear "Casa Central" por una compra).
--   (5)  Sucursal ELEGIDA cerrada: P0422 branch_closed (OQ-2 (a)); inactiva o
--        ajena: P0404, sin cambios.
--   (6)  Caja: compra en efectivo de hoy SIN sucursal con la sesión de la
--        principal -> se registra, con su movimiento en esa sesión (el defecto de
--        hoy); con la sesión de OTRA sucursal -> cash_optin_requires_open_session.
--   (7)  Banco: el movimiento bancario lleva la MISMA sucursal que la compra.
--   (8)  Edición de compra: (a) en B informada NULL -> la principal (REVERSE en B,
--        APPLY en la principal); (b) fila residual NULL sin informar -> la
--        principal, neto cero; (c) la reimputación explícita no cambia; (d) sin
--        sucursal operativa -> no_branch_found SIN reversa ni reaplicación;
--        (e) proveedor y centro de costo se preservan.
--   (9)  Edición de gasto: (a) en B informada NULL -> la principal; (b) residual
--        NULL sin informar -> la principal; (c) histórico con sólo el importe
--        cambiado -> la principal; (d) reimputación explícita; (e) sin sucursal
--        operativa persiste lo que devuelve c26_default_branch (OQ-3 (a)); (f)
--        forma de pago y centro de costo siguen desimputándose con NULL.
--   (10) Borrado EJECUTADO de una compra nueva sin sucursal elegida: repone en
--        la sucursal del movimiento (la principal).
--   (11) Remito -> compra: sólo si existe rpc_convert_delivery_note_to_purchase
--        (remitos-compra tanda B); mientras no exista, no aplica.
--
-- Mutaciones (se corren a mano, cada una en BEGIN ... ROLLBACK sobre el cuerpo
-- local, y cada una tiene que ser detectada por este gate con su mensaje):
--   M1 el alta con p_branch_id crudo en purchases        -> (1)
--   M2 crudo en stock_movements                          -> (1)
--   M3 la caja comparada contra el crudo                 -> (6)
--   M4 el banco con el crudo                             -> (7)
--   M5 la edición de compra sin el COALESCE              -> (8a)(8b)
--   M6 el guard que sólo mira NULL (deja pasar la principal no operativa) -> (3)
--   M7 la edición de gasto sin el COALESCE               -> (9)
--   M8 el alta sin el chequeo de branch_closed           -> (5)
--   M9 c21 con el crudo                                  -> sólo la introspección (0)
--
-- Patrón del proyecto (test_ventas_sucursal_por_defecto.sql): acumular fallos en
-- text[], un solo RAISE EXCEPTION al final. Anchors sintéticos vía
-- handle_new_user; sesión simulada con set_config LOCAL a la transacción —
-- NUNCA usar este patrón contra prod.
--
-- 🛑 created_at EXPLÍCITO y estrictamente POSTERIOR en las sucursales sintéticas:
-- c26_default_branch() ordena por created_at SIN desempate y branches.created_at
-- = now() es el timestamp de la TRANSACCIÓN, así que la sucursal que
-- handle_new_user auto-provisiona y las de este fixture nacerían con el MISMO
-- created_at al microsegundo y la "principal" saldría a suerte: el gate sería
-- flaky. Se fuerza y se ASSERTA (cgsd_assert_oldest).
--
-- REGLA PARA EL PR SIGUIENTE: una migración posterior que redefina cualquiera de
-- las tres funciones (p. ej. `remitos-compra` tanda B, que extrae
-- _purchase_operation_core desde rpc_create_purchase_operation) tiene que retirar
-- el bloque de reaplicación de 20261076000001 en KPI_Validation.yml en el mismo PR
-- (su preflight abortaría) y apuntar el bloque (0) de este gate al cuerpo que
-- contenga la lógica (el núcleo), actualizando los md5.
--
-- CI: KPI_Validation.yml (paso propio agregado en el mismo PR).
-- =============================================================================

-- ─── Ayudantes (pg_temp: desaparecen con la sesión) ───────────────────────────
CREATE FUNCTION pg_temp.cgsd_as(p_user uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;

-- Cuenta sintética vía handle_new_user: devuelve {user, account, branch} con la
-- sucursal "Casa Central" que handle_new_user auto-provisiona.
CREATE FUNCTION pg_temp.cgsd_mk_account(p_email text, p_name text) RETURNS jsonb LANGUAGE plpgsql AS $f$
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
CREATE FUNCTION pg_temp.cgsd_mk_branch(p_account uuid, p_name text, p_minutes integer,
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
-- más vieja de la cuenta.
CREATE FUNCTION pg_temp.cgsd_assert_oldest(p_account uuid, p_branch uuid) RETURNS integer LANGUAGE sql AS $f$
  SELECT COUNT(*)::integer FROM public.branches b
  WHERE b.account_id = p_account AND b.id <> p_branch
    AND b.created_at <= (SELECT created_at FROM public.branches WHERE id = p_branch)
$f$;

CREATE FUNCTION pg_temp.cgsd_mk_product(p_user uuid, p_account uuid, p_sku text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (p_user, p_account, 'Producto ' || p_sku, p_sku, 60.00, 100.00)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.cgsd_qty(p_branch uuid, p_product uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE branch_id = p_branch AND product_id = p_product), 0)
$f$;

-- Alta de compra capturando el error: {ok, operation_id, replayed} | {ok:false, state, msg}.
CREATE FUNCTION pg_temp.cgsd_buy(p_key text, p_items jsonb,
                                 p_branch uuid DEFAULT NULL, p_pm uuid DEFAULT NULL,
                                 p_cash_session uuid DEFAULT NULL, p_supplier uuid DEFAULT NULL,
                                 p_cc uuid DEFAULT NULL, p_desc text DEFAULT 'gate cgsd',
                                 p_bank uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_create_purchase_operation(
         p_idempotency_key => p_key, p_date => public.reporting_local_today(),
         p_description => p_desc, p_items => p_items,
         p_branch_id => p_branch, p_cost_center_id => p_cc,
         p_payment_method_id => p_pm, p_bank_account_id => p_bank,
         p_supplier_id => p_supplier, p_cash_session_id => p_cash_session, p_due_date => NULL);
  RETURN jsonb_build_object('ok', true, 'operation_id', r->>'operation_id', 'replayed', COALESCE((r->>'replayed')::boolean, false));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Edición de compra capturando el error. Sólo sucursal informable; proveedor,
-- centro de costo y forma de pago NO se informan (se preservan).
CREATE FUNCTION pg_temp.cgsd_edit_purchase(p_ids uuid[], p_items jsonb, p_branch uuid, p_provided boolean)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_atomic_update_purchase_operation(
         p_purchase_ids => p_ids, p_date => public.reporting_local_today(),
         p_description => 'gate cgsd edit', p_items => p_items,
         p_payment_method_id => NULL, p_payment_method_provided => false,
         p_branch_id => p_branch, p_branch_provided => p_provided,
         p_supplier_id => NULL, p_supplier_provided => false,
         p_cost_center_id => NULL, p_cost_center_provided => false);
  RETURN jsonb_build_object('ok', true, 'operation_id', r->>'operation_id');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Edición de gasto capturando el error. Sólo importe y sucursal.
CREATE FUNCTION pg_temp.cgsd_edit_expense(p_id uuid, p_amount numeric, p_branch uuid, p_provided boolean)
RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := public.rpc_update_expense(p_expense_id => p_id, p_amount => p_amount,
                                 p_branch_id => p_branch, p_branch_provided => p_provided);
  RETURN jsonb_build_object('ok', true, 'branch_id', r->>'branch_id');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'state', SQLSTATE, 'msg', SQLERRM);
END $f$;

-- Limpieza completa de cuentas y usuarios sintéticos (mismo mecanismo que
-- test_ventas_sucursal_por_defecto.sql): se borra TODA fila con account_id de los
-- anchors; con session_replication_role = replica los DELETE no cascadean, así que
-- las dependencias SIN account_id (cajas, sesiones y movimientos de caja de las
-- sucursales) se borran explícitamente primero.
CREATE FUNCTION pg_temp.cgsd_purge(p_accounts uuid[], p_users uuid[]) RETURNS void LANGUAGE plpgsql AS $f$
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
DO $$
DECLARE
  v_failures    text[] := '{}';
  v_fail_before integer;

  -- Cuerpos que deja 20261076000001: md5(replace(prosrc, E'\r', '')), medidos en
  -- el stack local después de aplicarla. Son el `v_rewritten` de su preflight.
  v_md5_create        constant text := '__MD5_CREATE__';
  v_md5_edit_purchase constant text := '__MD5_EDIT_PURCHASE__';
  v_md5_edit_expense  constant text := '__MD5_EDIT_EXPENSE__';

  -- Cuenta A (principal A0 + B): bloques (1), (6), (7), (8), (9), (10).
  r_a jsonb; v_user_a uuid; v_acc_a uuid; v_a0 uuid; v_b uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_pm_cash uuid; v_pm_transfer uuid; v_pm_other uuid; v_bank_a uuid;
  v_cbx_a uuid; v_cbx_b uuid; v_ses_a uuid; v_ses_b uuid;
  v_supplier uuid; v_cc uuid;
  -- Cuenta C (principal cerrada): bloques (2) y (5).
  r_c jsonb; v_user_c uuid; v_acc_c uuid; v_c0 uuid; v_c1 uuid; v_pc uuid;
  -- Cuenta D (ninguna operativa): bloques (3), (5), (8d), (9e).
  r_d jsonb; v_user_d uuid; v_acc_d uuid; v_d0 uuid; v_d1 uuid; v_pd uuid;
  -- Cuenta E (sin sucursales): bloque (4).
  r_e jsonb; v_user_e uuid; v_acc_e uuid; v_e0 uuid; v_pe uuid;

  v_res   jsonb;
  v_op    uuid;
  v_ids   uuid[];
  v_n     integer;
  v_val   numeric;
  v_uuid  uuid;
  v_uuid2 uuid;
  v_text  text;
  v_oid   oid;
  v_a_before numeric;
  v_b_before numeric;
  v_d_before numeric;
  v_md5   text;
  v_src   text;
  v_cm    text;
  v_today date := public.reporting_local_today();
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup: cuatro cuentas sintéticas
  -- ═══════════════════════════════════════════════════════════════════════
  r_a := pg_temp.cgsd_mk_account('cgsd-a@test.local', 'Gate CGSD A');
  v_user_a := (r_a->>'user')::uuid; v_acc_a := (r_a->>'account')::uuid; v_a0 := (r_a->>'branch')::uuid;
  v_b := pg_temp.cgsd_mk_branch(v_acc_a, 'Sucursal CGSD B', 1);
  IF pg_temp.cgsd_assert_oldest(v_acc_a, v_a0) > 0 THEN
    RAISE EXCEPTION 'GATE COMPRAS-GASTOS-SUCURSAL-POR-DEFECTO (setup A): sucursales de A empatan o preceden a la auto-provisionada en created_at — c26_default_branch no desempata, el gate sería flaky';
  END IF;
  v_p1 := pg_temp.cgsd_mk_product(v_user_a, v_acc_a, 'CGSD-P1');
  v_p2 := pg_temp.cgsd_mk_product(v_user_a, v_acc_a, 'CGSD-P2');
  v_p3 := pg_temp.cgsd_mk_product(v_user_a, v_acc_a, 'CGSD-P3');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p1, v_a0, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p1, v_b, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p2, v_a0, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p2, v_b, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p3, v_a0, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p3, v_b, 10);

  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_acc_a AND kind = 'cash'     AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_acc_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_other    FROM public.payment_methods WHERE account_id = v_acc_a AND kind = 'other'    AND is_active AND deleted_at IS NULL LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_transfer IS NULL OR v_pm_other IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: el catálogo de formas de pago no trae cash/transfer/other para la cuenta A';
  END IF;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance, is_active)
  VALUES (v_acc_a, '__gate_cgsd_bank_a__', 'ARS', 0, TRUE) RETURNING id INTO v_bank_a;
  UPDATE public.payment_methods SET bank_account_id = v_bank_a WHERE id = v_pm_transfer;

  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc_a, '__gate_cgsd_supplier__') RETURNING id INTO v_supplier;
  INSERT INTO public.cost_centers (account_id, name, is_active) VALUES (v_acc_a, '__gate_cgsd_cc__', TRUE) RETURNING id INTO v_cc;

  SELECT id INTO v_cbx_a FROM public.cashboxes WHERE branch_id = v_a0 ORDER BY created_at LIMIT 1;
  IF v_cbx_a IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_a0, '__gate_cgsd_cashbox_a__', 'ARS') RETURNING id INTO v_cbx_a;
  END IF;
  SELECT id INTO v_cbx_b FROM public.cashboxes WHERE branch_id = v_b ORDER BY created_at LIMIT 1;
  IF v_cbx_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name, currency) VALUES (v_b, '__gate_cgsd_cashbox_b__', 'ARS') RETURNING id INTO v_cbx_b;
  END IF;

  -- C: la principal (la más antigua) CERRADA — vacía, así que el guard de baja la deja pasar.
  r_c := pg_temp.cgsd_mk_account('cgsd-c@test.local', 'Gate CGSD C');
  v_user_c := (r_c->>'user')::uuid; v_acc_c := (r_c->>'account')::uuid; v_c0 := (r_c->>'branch')::uuid;
  UPDATE public.branches SET status = 'closed', closed_at = now() WHERE id = v_c0;
  v_c1 := pg_temp.cgsd_mk_branch(v_acc_c, 'Sucursal CGSD C1 (la siguiente operativa)', 1);
  IF pg_temp.cgsd_assert_oldest(v_acc_c, v_c0) > 0 THEN
    RAISE EXCEPTION 'GATE COMPRAS-GASTOS-SUCURSAL-POR-DEFECTO (setup C): empate de created_at';
  END IF;
  v_pc := pg_temp.cgsd_mk_product(v_user_c, v_acc_c, 'CGSD-PC');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_c, v_pc, v_c1, 50);

  -- D: NINGUNA sucursal operativa. D0 (auto) desactivada estando vacía; D1 cerrada.
  -- Después se le carga stock a D0 directo (el estado posterior al incidente del
  -- 22-08: una sucursal dada de baja que volvió a recibir stock).
  r_d := pg_temp.cgsd_mk_account('cgsd-d@test.local', 'Gate CGSD D');
  v_user_d := (r_d->>'user')::uuid; v_acc_d := (r_d->>'account')::uuid; v_d0 := (r_d->>'branch')::uuid;
  UPDATE public.branches SET is_active = FALSE WHERE id = v_d0;
  v_d1 := pg_temp.cgsd_mk_branch(v_acc_d, 'Sucursal CGSD D1 (cerrada)', 1, 'closed', TRUE);
  IF pg_temp.cgsd_assert_oldest(v_acc_d, v_d0) > 0 THEN
    RAISE EXCEPTION 'GATE COMPRAS-GASTOS-SUCURSAL-POR-DEFECTO (setup D): empate de created_at';
  END IF;
  v_pd := pg_temp.cgsd_mk_product(v_user_d, v_acc_d, 'CGSD-PD');
  PERFORM public.c21_apply_branch_stock_delta(v_acc_d, v_pd, v_d0, 20);

  -- E: SIN ninguna sucursal. El borrado de la sembrada exige session_replication_role
  -- = replica (esquiva trg_guard_branch_decommission) y en ese modo NO corren las
  -- acciones de FK: antes del DELETE se borran explícitamente sus cajas (que
  -- handle_new_user siembra y no tienen account_id) y su stock.
  r_e := pg_temp.cgsd_mk_account('cgsd-e@test.local', 'Gate CGSD E');
  v_user_e := (r_e->>'user')::uuid; v_acc_e := (r_e->>'account')::uuid; v_e0 := (r_e->>'branch')::uuid;
  v_pe := pg_temp.cgsd_mk_product(v_user_e, v_acc_e, 'CGSD-PE');
  SET session_replication_role = replica;
  DELETE FROM public.cashboxes    WHERE branch_id = v_e0;
  DELETE FROM public.branch_stock WHERE branch_id = v_e0;
  DELETE FROM public.branches     WHERE id = v_e0;
  SET session_replication_role = DEFAULT;
  IF EXISTS (SELECT 1 FROM public.branches WHERE account_id = v_acc_e) THEN
    RAISE EXCEPTION 'SETUP FAILED (E): la cuenta E conserva sucursales';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (0) Introspección de los cuerpos VIVOS
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  FOR v_text IN SELECT unnest(ARRAY['rpc_create_purchase_operation', 'rpc_atomic_update_purchase_operation', 'rpc_update_expense']) LOOP
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

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_create_purchase_operation' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_create THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 alta): el cuerpo vivo de rpc_create_purchase_operation mide %s y el de la migración es %s (¿un reapply posterior de CI lo pisó, o persiste p_branch_id crudo?)', v_md5, v_md5_create));
  END IF;
  IF v_src ~ 'p_branch_id,\s*p_cost_center_id,\s*p_payment_method_id' THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta INSERT): un INSERT en purchases todavía persiste p_branch_id CRUDO (tiene que ser v_gate_branch)');
  END IF;
  IF v_src ~ 'v_new_op_id,\s*p_branch_id' THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta stock_movements): el movimiento de stock todavía persiste p_branch_id CRUDO');
  END IF;
  IF v_src ~ 'IS DISTINCT FROM p_branch_id' THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta caja): la condición de caja todavía compara la sesión contra p_branch_id CRUDO');
  END IF;
  IF v_src ~ 'p_date,\s*p_branch_id,\s*NULL' THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta banco): el movimiento bancario todavía recibe p_branch_id CRUDO');
  END IF;
  IF v_src !~ 'c21_apply_branch_stock_delta\(\s*v_account_id,\s*v_item\.product_id,\s*v_gate_branch,' THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta c21): c21_apply_branch_stock_delta tiene que recibir v_gate_branch explícita (la misma lectura de la principal que usa la fila)');
  END IF;
  IF position('no_branch_found' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta guard): el alta no tiene el guard P0422 no_branch_found');
  END IF;
  IF position('branch_closed' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 alta cerrada): el alta no rechaza una sucursal elegida cerrada (P0422 branch_closed, OQ-2 (a))');
  END IF;
  IF obj_description('public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)'::regprocedure, 'pg_proc') IS NOT NULL THEN
    v_failures := array_append(v_failures, 'FAIL (0 COMMENT): el alta de compra no tenía COMMENT y la migración no debe agregarle uno');
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_atomic_update_purchase_operation' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_edit_purchase THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 edición compra): el cuerpo vivo de rpc_atomic_update_purchase_operation mide %s y el de la migración es %s', v_md5, v_md5_edit_purchase));
  END IF;
  IF position('no_branch_found' IN v_src) = 0 OR position('c26_default_branch(v_account_id)' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 edición compra): la edición no resuelve la principal ni tiene el guard P0422 no_branch_found');
  END IF;
  SELECT obj_description('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc') INTO v_cm;
  IF v_cm IS NULL OR position('caja-compras-cobranzas (D8)' IN v_cm) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 COMMENT): el COMMENT de la edición de compra tiene que conservarse idéntico (el de caja-compras-cobranzas D8)');
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'rpc_update_expense' AND pronamespace = 'public'::regnamespace;
  v_md5 := md5(replace(v_src, E'\r', ''));
  IF v_md5 IS DISTINCT FROM v_md5_edit_expense THEN
    v_failures := array_append(v_failures, format('FAIL (0 md5 edición gasto): el cuerpo vivo de rpc_update_expense mide %s y el de la migración es %s', v_md5, v_md5_edit_expense));
  END IF;
  IF position('c26_default_branch(v_account_id)' IN v_src) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 edición gasto): la edición de gasto no resuelve un nulo a la principal');
  END IF;
  IF position('no_branch_found' IN v_src) > 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 edición gasto): la edición de gasto NO lleva guard de sucursal operativa (OQ-3 (a): es la regla literal del alta del gasto)');
  END IF;
  SELECT obj_description('public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean)'::regprocedure, 'pg_proc') INTO v_cm;
  IF v_cm IS NULL OR position('gastos-forma-pago: edición atómica del gasto' IN v_cm) = 0 OR position('compras-gastos-sucursal-por-defecto' IN v_cm) = 0 THEN
    v_failures := array_append(v_failures, 'FAIL (0 COMMENT): el COMMENT de la edición de gasto tiene que conservar su texto vivo y sumar la excepción de compras-gastos-sucursal-por-defecto');
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (0): cuerpos vivos con la sucursal resuelta en los seis puntos de la compra y en las dos ediciones, md5 = el del preflight, COMMENT conservado/ampliado, una firma por función, ACLs intactas';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (1) Alta sin sucursal: producto + servicio; ledger; reintento idempotente
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_a);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE EXCEPTION 'SETUP FAILED: auth.uid() no resuelve a la cuenta A con request.jwt.claims local — el gate no puede invocar las RPCs';
  END IF;

  v_a_before := pg_temp.cgsd_qty(v_a0, v_p1);
  v_b_before := pg_temp.cgsd_qty(v_b, v_p1);
  v_res := pg_temp.cgsd_buy('cgsd-1-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2),
      jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)),
    NULL, NULL, NULL, NULL, NULL, 'cgsd-1');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (1 alta): la compra sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 líneas): la operación debía tener 2 filas en purchases, tiene %s', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_a0;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 purchases.branch_id): las 2 líneas (producto y servicio) debían quedar con la PRINCIPAL %s, %s la tienen — purchases.branch_id NULL es lo que este change elimina', v_a0, v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm
    WHERE sm.operation_group_id = v_op AND sm.reference_type = 'purchase' AND sm.branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock_movements.branch_id): el movimiento de stock debía llevar la principal, %s lo llevan', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.branch_id IS NULL;
    IF v_n <> 0 THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock_movements NULL): ningún movimiento de la compra podía quedar sin sucursal, %s lo están', v_n));
    END IF;
    IF pg_temp.cgsd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before + 2 THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock principal): branch_stock de la principal debía subir de %s a %s, quedó %s', v_a_before, v_a_before + 2, pg_temp.cgsd_qty(v_a0, v_p1)));
    END IF;
    IF pg_temp.cgsd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before THEN
      v_failures := array_append(v_failures, format('FAIL (1 stock B): la otra sucursal no debía tocarse (era %s), quedó %s', v_b_before, pg_temp.cgsd_qty(v_b, v_p1)));
    END IF;
    -- Invariante de reconstrucción (inventory-single-ledger): la suma del ledger por
    -- (producto, sucursal) de ESTA operación coincide con el cambio de branch_stock.
    SELECT COALESCE(SUM(quantity_delta), 0) INTO v_val FROM public.stock_movements
    WHERE operation_group_id = v_op AND product_id = v_p1 AND branch_id = v_a0;
    IF v_val IS DISTINCT FROM (pg_temp.cgsd_qty(v_a0, v_p1) - v_a_before) THEN
      v_failures := array_append(v_failures, format('FAIL (1 ledger): Σ quantity_delta por (producto, sucursal) = %s y branch_stock cambió %s: el ledger no reconstruye', v_val, pg_temp.cgsd_qty(v_a0, v_p1) - v_a_before));
    END IF;

    -- (1c) reintento con la MISMA clave: replay, sin duplicar filas ni stock
    v_a_before := pg_temp.cgsd_qty(v_a0, v_p1);
    v_res := pg_temp.cgsd_buy((SELECT idempotency_key FROM public.operation_idempotency WHERE operation_id = v_op AND operation_kind = 'purchase'),
      jsonb_build_array(
        jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2),
        jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)),
      NULL, NULL, NULL, NULL, NULL, 'cgsd-1');
    IF NOT (v_res->>'ok')::boolean OR NOT (v_res->>'replayed')::boolean OR (v_res->>'operation_id')::uuid IS DISTINCT FROM v_op THEN
      v_failures := array_append(v_failures, format('FAIL (1c replay): el reintento con la misma clave debía devolver la misma operación como replayed, obtuvo %s', v_res::text));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op;
    IF v_n <> 2 OR pg_temp.cgsd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before THEN
      v_failures := array_append(v_failures, format('FAIL (1c replay efectos): el replay duplicó filas (%s) o stock (%s -> %s)', v_n, v_a_before, pg_temp.cgsd_qty(v_a0, v_p1)));
    END IF;
  END IF;

  -- (1b) sucursal elegida B: todo en B, la principal intacta
  v_a_before := pg_temp.cgsd_qty(v_a0, v_p1);
  v_b_before := pg_temp.cgsd_qty(v_b, v_p1);
  v_res := pg_temp.cgsd_buy('cgsd-1b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3)),
    v_b, NULL, NULL, NULL, NULL, 'cgsd-1b');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (1b alta): la compra en B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_b;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (1b purchases.branch_id): la compra con B elegida debía quedar en B, %s filas', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.reference_type = 'purchase' AND sm.branch_id = v_b;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (1b stock_movements.branch_id): el movimiento debía llevar B, %s lo llevan', v_n));
    END IF;
    IF pg_temp.cgsd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before + 3 OR pg_temp.cgsd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before THEN
      v_failures := array_append(v_failures, format('FAIL (1b stock): B debía subir 3 (%s -> %s) y la principal no tocarse (%s), quedó B=%s A=%s', v_b_before, v_b_before + 3, v_a_before, pg_temp.cgsd_qty(v_b, v_p1), pg_temp.cgsd_qty(v_a0, v_p1)));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (1): alta sin sucursal — purchases.branch_id y stock_movements.branch_id = la principal en producto y servicio; el stock sube en la principal, el ledger reconstruye y el replay no duplica; con B elegida todo queda en B';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (2) Principal CERRADA: la compra y el stock van a la siguiente operativa
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_c);
  v_res := pg_temp.cgsd_buy('cgsd-2-' || gen_random_uuid()::text,
    jsonb_build_array(
      jsonb_build_object('product_id', v_pc, 'amount', 100.00, 'quantity', 2),
      jsonb_build_object('product_id', NULL, 'amount', 50.00, 'quantity', 1)));
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (2 alta): con la más antigua cerrada la compra debía resolverse a la siguiente operativa, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_c1;
    IF v_n <> 2 THEN
      v_failures := array_append(v_failures, format('FAIL (2 purchases.branch_id): con la más antigua cerrada la compra debía quedar en la siguiente operativa %s, %s filas', v_c1, v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.reference_type = 'purchase' AND sm.branch_id = v_c1;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (2 stock_movements.branch_id): el movimiento debía llevar la siguiente operativa, %s lo llevan', v_n));
    END IF;
    IF pg_temp.cgsd_qty(v_c1, v_pc) IS DISTINCT FROM 52 THEN
      v_failures := array_append(v_failures, format('FAIL (2 stock): la siguiente operativa debía quedar en 52, quedó %s', pg_temp.cgsd_qty(v_c1, v_pc)));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_c0;
    IF v_n <> 0 THEN
      v_failures := array_append(v_failures, 'FAIL (2 cerrada): ninguna fila de la compra podía quedar en la sucursal cerrada');
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2): con la más antigua cerrada la compra, su movimiento y el stock van a la siguiente operativa';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (3) Ninguna sucursal operativa: P0422 no_branch_found, sin nada escrito
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_d);
  v_d_before := pg_temp.cgsd_qty(v_d0, v_pd);

  v_res := pg_temp.cgsd_buy('cgsd-3-prod', jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 1)), NULL, NULL, NULL, NULL, NULL, 'cgsd-3');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 producto): sin ninguna sucursal operativa la compra con producto debía rechazarse con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  v_res := pg_temp.cgsd_buy('cgsd-3-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)), NULL, NULL, NULL, NULL, NULL, 'cgsd-3');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 servicio): una compra sólo de servicios sin ninguna sucursal operativa debía rechazarse con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.purchases WHERE account_id = v_acc_d;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 purchases): el rechazo no debía dejar filas en purchases (hay %s)', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE user_id = v_user_d AND idempotency_key IN ('cgsd-3-prod', 'cgsd-3-serv');
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (3 idempotencia): el rechazo no debía dejar una clave en operation_idempotency (hay %s)', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_d;
  IF v_n <> 0 OR pg_temp.cgsd_qty(v_d0, v_pd) IS DISTINCT FROM v_d_before THEN
    v_failures := array_append(v_failures, format('FAIL (3 stock): el rechazo no debía tocar el stock (movimientos %s; D0 %s -> %s)', v_n, v_d_before, pg_temp.cgsd_qty(v_d0, v_pd)));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (3): sin ninguna sucursal operativa la compra se rechaza con P0422 no_branch_found (producto y servicio) sin filas, sin idempotencia y sin tocar stock';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (4) Cuenta SIN sucursales: P0422 y ninguna sucursal creada
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_e);
  v_res := pg_temp.cgsd_buy('cgsd-4-prod', jsonb_build_array(jsonb_build_object('product_id', v_pe, 'amount', 100.00, 'quantity', 1)), NULL, NULL, NULL, NULL, NULL, 'cgsd-4');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 producto): una cuenta sin sucursales debía rechazar la compra con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  v_res := pg_temp.cgsd_buy('cgsd-4-serv', jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 100.00, 'quantity', 1)), NULL, NULL, NULL, NULL, NULL, 'cgsd-4');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 servicio): una cuenta sin sucursales debía rechazar la compra de servicios con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.branches WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 sucursal creada): la compra no debe crear "Casa Central" al vuelo (hay %s sucursales)', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.purchases WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 purchases): el rechazo no debía dejar filas (hay %s)', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.operation_idempotency WHERE user_id = v_user_e AND idempotency_key IN ('cgsd-4-prod', 'cgsd-4-serv');
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 idempotencia): el rechazo no debía dejar claves (hay %s)', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_e;
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (4 stock_movements): el rechazo no debía dejar movimientos (hay %s)', v_n));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (4): cuenta sin sucursales — P0422 no_branch_found, ninguna sucursal creada, sin filas';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (5) Sucursal ELEGIDA cerrada (OQ-2 (a)); inactiva y ajena sin cambios
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_c);
  v_a_before := pg_temp.cgsd_qty(v_c0, v_pc);
  v_res := pg_temp.cgsd_buy('cgsd-5-closed', jsonb_build_array(jsonb_build_object('product_id', v_pc, 'amount', 100.00, 'quantity', 1)), v_c0, NULL, NULL, NULL, NULL, 'cgsd-5');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('branch_closed' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (5 cerrada): una compra con una sucursal ELEGIDA cerrada debía rechazarse con P0422 branch_closed, obtuvo %s', v_res::text));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.purchases WHERE account_id = v_acc_c AND description = 'cgsd-5';
  IF v_n <> 0 OR pg_temp.cgsd_qty(v_c0, v_pc) IS DISTINCT FROM v_a_before THEN
    v_failures := array_append(v_failures, format('FAIL (5 efectos): el rechazo no debía dejar filas (%s) ni mover el stock de la cerrada (%s -> %s)', v_n, v_a_before, pg_temp.cgsd_qty(v_c0, v_pc)));
  END IF;
  -- inactiva (D0): P0404, el comportamiento de siempre
  PERFORM pg_temp.cgsd_as(v_user_d);
  v_res := pg_temp.cgsd_buy('cgsd-5-inactive', jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 1)), v_d0, NULL, NULL, NULL, NULL, 'cgsd-5');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0404' THEN
    v_failures := array_append(v_failures, format('FAIL (5 inactiva): una sucursal elegida inactiva debía seguir dando P0404, obtuvo %s', v_res::text));
  END IF;
  -- ajena (de la cuenta A): P0404
  v_res := pg_temp.cgsd_buy('cgsd-5-foreign', jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 1)), v_a0, NULL, NULL, NULL, NULL, 'cgsd-5');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0404' THEN
    v_failures := array_append(v_failures, format('FAIL (5 ajena): una sucursal de otra cuenta debía seguir dando P0404, obtuvo %s', v_res::text));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (5): sucursal elegida cerrada -> P0422 branch_closed; inactiva y ajena -> P0404 como siempre';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (6) Caja: el opt-in de una compra SIN sucursal elegida
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_a);
  SELECT public.rpc_open_cash_session(v_cbx_a, 500) INTO v_res;
  v_ses_a := COALESCE((v_res->>'session_id')::uuid, (v_res->>'id')::uuid);
  IF v_ses_a IS NULL THEN
    SELECT id INTO v_ses_a FROM public.cash_sessions WHERE cashbox_id = v_cbx_a AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;
  SELECT public.rpc_open_cash_session(v_cbx_b, 500) INTO v_res;
  v_ses_b := COALESCE((v_res->>'session_id')::uuid, (v_res->>'id')::uuid);
  IF v_ses_b IS NULL THEN
    SELECT id INTO v_ses_b FROM public.cash_sessions WHERE cashbox_id = v_cbx_b AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  END IF;
  IF v_ses_a IS NULL OR v_ses_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED (6): no se pudo abrir la sesión de caja de la principal o de B';
  END IF;

  -- (6a) efectivo de hoy SIN sucursal, con la sesión de la principal: el caso que HOY falla
  v_res := pg_temp.cgsd_buy('cgsd-6a-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 2)),
    NULL, v_pm_cash, v_ses_a, NULL, NULL, 'cgsd-6a');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (6a): la compra en efectivo sin sucursal elegida con la sesión de la principal debía pasar (es el opt-in pre-marcado que hoy se rechaza con cash_optin_requires_open_session), falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_ses_a AND reference_id = v_op AND movement_type = 'purchase_payment' AND amount = -200;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (6a caja): el movimiento de caja (purchase_payment, -200) debía quedar en la sesión de la principal, hay %s', v_n));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, 'FAIL (6a purchases.branch_id): la compra en efectivo con caja de la principal debía llevar la principal en purchases');
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE operation_group_id = v_op AND reference_type = 'purchase' AND branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, 'FAIL (6a stock_movements.branch_id): el movimiento de stock debía llevar la MISMA sucursal que la caja (la principal)');
    END IF;
  END IF;

  -- (6b) la MISMA compra informando la sesión de B (no es la de la principal): rechazo y nada escrito
  v_a_before := pg_temp.cgsd_qty(v_a0, v_p2);
  v_res := pg_temp.cgsd_buy('cgsd-6b-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 2)),
    NULL, v_pm_cash, v_ses_b, NULL, NULL, 'cgsd-6b');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('cash_optin_requires_open_session' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (6b): informar la sesión de B para una compra sin sucursal (efectiva = la principal) debía rechazarse con cash_optin_requires_open_session, obtuvo %s', v_res::text));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.purchases WHERE account_id = v_acc_a AND description = 'cgsd-6b';
  IF v_n <> 0 OR pg_temp.cgsd_qty(v_a0, v_p2) IS DISTINCT FROM v_a_before THEN
    v_failures := array_append(v_failures, format('FAIL (6b efectos): el rechazo no debía dejar filas (%s) ni mover el stock (%s -> %s)', v_n, v_a_before, pg_temp.cgsd_qty(v_a0, v_p2)));
  END IF;

  -- (6c) sucursal B elegida con la sesión de B: la caja y la compra en B
  v_res := pg_temp.cgsd_buy('cgsd-6c-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
    v_b, v_pm_cash, v_ses_b, NULL, NULL, 'cgsd-6c');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (6c): la compra en efectivo con B elegida y la sesión de B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_ses_b AND reference_id = v_op AND movement_type = 'purchase_payment';
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (6c caja): el movimiento de caja debía quedar en la sesión de B, hay %s', v_n));
    END IF;
  END IF;

  -- (6d) B elegida con la sesión de la principal: rechazo (la sucursal efectiva es B)
  v_res := pg_temp.cgsd_buy('cgsd-6d-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
    v_b, v_pm_cash, v_ses_a, NULL, NULL, 'cgsd-6d');
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('cash_optin_requires_open_session' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (6d): B elegida con la sesión de la principal debía rechazarse con cash_optin_requires_open_session, obtuvo %s', v_res::text));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (6): caja — la compra en efectivo sin sucursal elegida se registra con la sesión de la principal (el defecto de hoy); con la sesión de otra sucursal se rechaza; con B elegida valen las reglas de B';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (7) Banco: compra, movimiento de stock y movimiento bancario en la MISMA sucursal
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_res := pg_temp.cgsd_buy('cgsd-7-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 1)),
    NULL, v_pm_transfer, NULL, NULL, NULL, 'cgsd-7');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (7): la compra por transferencia sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT branch_id INTO v_uuid FROM public.bank_movements WHERE source_doc_type = 'purchase' AND source_doc_ref = v_op;
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (7 banco): el movimiento bancario debía llevar la principal %s, lleva %s', v_a0, v_uuid));
    END IF;
    SELECT branch_id INTO v_uuid FROM public.purchases WHERE operation_id = v_op;
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (7 purchases.branch_id): la compra debía llevar la MISMA sucursal que el banco (la principal %s), lleva %s', v_a0, v_uuid));
    END IF;
    SELECT branch_id INTO v_uuid FROM public.stock_movements WHERE operation_group_id = v_op AND reference_type = 'purchase';
    IF v_uuid IS DISTINCT FROM v_a0 THEN
      v_failures := array_append(v_failures, format('FAIL (7 stock_movements.branch_id): el movimiento de stock debía llevar la MISMA sucursal que el banco (%s), lleva %s', v_a0, v_uuid));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (7): banco — compra, movimiento de stock y movimiento bancario llevan la MISMA sucursal (la principal)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (8) Edición de compra
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_a);

  -- (8a) compra en B (con proveedor y centro de costo) editada con branch_provided = true y NULL -> la principal
  v_res := pg_temp.cgsd_buy('cgsd-8a-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 2)),
    v_b, NULL, NULL, v_supplier, v_cc, 'cgsd-8a');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (8a setup): la compra en B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op;
    v_a_before := pg_temp.cgsd_qty(v_a0, v_p3);
    v_b_before := pg_temp.cgsd_qty(v_b, v_p3);
    v_res := pg_temp.cgsd_edit_purchase(v_ids, jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 2)), NULL, TRUE);
    IF NOT (v_res->>'ok')::boolean THEN
      v_failures := array_append(v_failures, format('FAIL (8a edición): la edición con sucursal informada NULL debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
    ELSE
      v_op := (v_res->>'operation_id')::uuid;
      SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND branch_id = v_a0;
      IF v_n <> 1 THEN
        v_failures := array_append(v_failures, format('FAIL (8a purchases.branch_id): informar branch_id NULL al editar una compra debía asignar la PRINCIPAL %s (BREAKING declarado, D5), %s filas la tienen', v_a0, v_n));
      END IF;
      IF pg_temp.cgsd_qty(v_b, v_p3) IS DISTINCT FROM v_b_before - 2 OR pg_temp.cgsd_qty(v_a0, v_p3) IS DISTINCT FROM v_a_before + 2 THEN
        v_failures := array_append(v_failures, format('FAIL (8a stock): el REVERSE descuenta 2 de B (%s -> %s) y el APPLY suma 2 en la principal (%s -> %s); quedó B=%s A=%s', v_b_before, v_b_before - 2, v_a_before, v_a_before + 2, pg_temp.cgsd_qty(v_b, v_p3), pg_temp.cgsd_qty(v_a0, v_p3)));
      END IF;
      SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = v_op AND sm.reference_type = 'purchase' AND sm.branch_id = v_a0;
      IF v_n <> 1 THEN
        v_failures := array_append(v_failures, format('FAIL (8a movimiento): el movimiento de la pata APPLY debía llevar la principal, %s lo llevan', v_n));
      END IF;
      -- (8e) el proveedor y el centro de costo se preservan
      SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op AND supplier_id = v_supplier AND cost_center_id = v_cc;
      IF v_n <> 1 THEN
        v_failures := array_append(v_failures, format('FAIL (8e): la edición de sucursal debía preservar el proveedor y el centro de costo, %s filas los conservan', v_n));
      END IF;
      v_ids := ARRAY(SELECT id FROM public.purchases WHERE operation_id = v_op);

      -- (8c) reimputación explícita a B: sin cambios de comportamiento
      v_res := pg_temp.cgsd_edit_purchase(v_ids, jsonb_build_array(jsonb_build_object('product_id', v_p3, 'amount', 100.00, 'quantity', 2)), v_b, TRUE);
      IF NOT (v_res->>'ok')::boolean THEN
        v_failures := array_append(v_failures, format('FAIL (8c reimputación): reimputar a B debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
      ELSE
        SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid AND branch_id = v_b;
        IF v_n <> 1 THEN
          v_failures := array_append(v_failures, format('FAIL (8c purchases.branch_id): la reimputación explícita a B debía quedar en B, %s filas', v_n));
        END IF;
      END IF;
    END IF;
  END IF;

  -- (8b) fila residual NULL (compra histórica: stock en la principal, movimiento NULL) editada SIN informar sucursal -> la principal
  v_op := gen_random_uuid();
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user_a, v_acc_a, v_p1, 100, 3, 300, 'cgsd-8b residual', v_today, v_op, NULL)
  RETURNING id INTO v_uuid;
  PERFORM public.c21_apply_branch_stock_delta(v_acc_a, v_p1, v_a0, 3);
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type, quantity_delta, quantity_before, quantity_after,
                                      reference_id, reference_type, performed_by, operation_group_id, branch_id)
  VALUES (v_user_a, v_acc_a, v_p1, 'Producto CGSD-P1', 'purchase', 3, 0, 3, v_uuid, 'purchase', v_user_a, v_op, NULL);
  v_a_before := pg_temp.cgsd_qty(v_a0, v_p1);
  v_b_before := pg_temp.cgsd_qty(v_b, v_p1);
  v_res := pg_temp.cgsd_edit_purchase(ARRAY[v_uuid], jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3)), NULL, FALSE);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (8b edición): editar la fila residual sin informar sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid AND branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (8b purchases.branch_id): una fila vigente sin sucursal, editada sin informar sucursal, debía quedar en la PRINCIPAL (hoy conserva NULL), %s filas', v_n));
    END IF;
    IF pg_temp.cgsd_qty(v_a0, v_p1) IS DISTINCT FROM v_a_before OR pg_temp.cgsd_qty(v_b, v_p1) IS DISTINCT FROM v_b_before THEN
      v_failures := array_append(v_failures, format('FAIL (8b stock): el REVERSE de una fila NULL cae en la principal y el APPLY suma en la misma: el neto es cero (A era %s, B %s), quedó A=%s B=%s', v_a_before, v_b_before, pg_temp.cgsd_qty(v_a0, v_p1), pg_temp.cgsd_qty(v_b, v_p1)));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.stock_movements sm WHERE sm.operation_group_id = (v_res->>'operation_id')::uuid AND sm.reference_type = 'purchase' AND sm.branch_id = v_a0;
    IF v_n <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (8b movimiento): el movimiento de la pata APPLY debía llevar la principal, %s lo llevan', v_n));
    END IF;
  END IF;

  -- (8d) cuenta SIN sucursal operativa: no_branch_found SIN reversa ni reaplicación
  PERFORM pg_temp.cgsd_as(v_user_d);
  v_op := gen_random_uuid();
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user_d, v_acc_d, v_pd, 100, 2, 200, 'cgsd-8d residual', v_today, v_op, NULL)
  RETURNING id INTO v_uuid;
  v_d_before := pg_temp.cgsd_qty(v_d0, v_pd);
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id = v_acc_d;
  v_res := pg_temp.cgsd_edit_purchase(ARRAY[v_uuid], jsonb_build_array(jsonb_build_object('product_id', v_pd, 'amount', 100.00, 'quantity', 2)), NULL, FALSE);
  IF (v_res->>'ok')::boolean OR v_res->>'state' IS DISTINCT FROM 'P0422' OR position('no_branch_found' IN COALESCE(v_res->>'msg', '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (8d): sin sucursal operativa la edición debía rechazarse con P0422 no_branch_found, obtuvo %s', v_res::text));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_uuid) THEN
    v_failures := array_append(v_failures, 'FAIL (8d fila): el rechazo borró la fila original — el guard tiene que correr ANTES de la pata REVERSE');
  END IF;
  IF pg_temp.cgsd_qty(v_d0, v_pd) IS DISTINCT FROM v_d_before OR (SELECT COUNT(*) FROM public.stock_movements WHERE account_id = v_acc_d) <> v_n THEN
    v_failures := array_append(v_failures, format('FAIL (8d stock): el rechazo no debía revertir ni reaplicar stock (D0 era %s, quedó %s; movimientos %s -> %s)', v_d_before, pg_temp.cgsd_qty(v_d0, v_pd), v_n, (SELECT COUNT(*) FROM public.stock_movements WHERE account_id = v_acc_d)));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (8): edición de compra — NULL informado o vigente se resuelve a la principal (REVERSE y APPLY netos), proveedor y centro de costo se preservan, la reimputación explícita no cambia, y sin sucursal operativa se rechaza antes de tocar stock';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (9) Edición de gasto
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_a);

  -- (9a) gasto en B editado con branch_provided = true y NULL -> la principal
  v_uuid := (public.rpc_create_expense(p_category => 'Gate CGSD', p_amount => 100, p_date => v_today, p_branch_id => v_b)->>'expense_id')::uuid;
  IF (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'SETUP FAILED (9a): el gasto de B no quedó en B';
  END IF;
  v_res := pg_temp.cgsd_edit_expense(v_uuid, NULL, NULL, TRUE);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (9a edición): la edición con sucursal informada NULL debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_a0 THEN
    v_failures := array_append(v_failures, format('FAIL (9a): informar branch_id NULL al editar un gasto debía asignar la PRINCIPAL %s (la regla del alta, BREAKING declarado), quedó %s', v_a0, (SELECT branch_id FROM public.expenses WHERE id = v_uuid)));
  END IF;

  -- (9d) reimputación explícita a B desde la principal: sin cambios de comportamiento
  v_res := pg_temp.cgsd_edit_expense(v_uuid, NULL, v_b, TRUE);
  IF NOT (v_res->>'ok')::boolean OR (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_b THEN
    v_failures := array_append(v_failures, format('FAIL (9d): la reimputación explícita a B debía quedar en B, obtuvo %s (branch=%s)', v_res::text, (SELECT branch_id FROM public.expenses WHERE id = v_uuid)));
  END IF;
  -- sin informar la sucursal: se conserva
  v_res := pg_temp.cgsd_edit_expense(v_uuid, 120, NULL, FALSE);
  IF NOT (v_res->>'ok')::boolean OR (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_b THEN
    v_failures := array_append(v_failures, format('FAIL (9d conserva): editar sólo el importe debía conservar la sucursal B, obtuvo %s (branch=%s)', v_res::text, (SELECT branch_id FROM public.expenses WHERE id = v_uuid)));
  END IF;

  -- (9b) gasto residual con branch_id NULL (anterior a gastos-forma-pago) editado SIN informar sucursal -> la principal
  INSERT INTO public.expenses (user_id, account_id, category, amount, date)
  VALUES (v_user_a, v_acc_a, 'Residual', 200, v_today - 40) RETURNING id INTO v_uuid;
  v_res := pg_temp.cgsd_edit_expense(v_uuid, NULL, NULL, FALSE);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (9b edición): editar el gasto residual sin tocar la sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_a0 THEN
    v_failures := array_append(v_failures, format('FAIL (9b): una fila vigente sin sucursal, editada sin informar sucursal, debía quedar en la PRINCIPAL %s (hoy conserva NULL), quedó %s', v_a0, (SELECT branch_id FROM public.expenses WHERE id = v_uuid)));
  END IF;

  -- (9c) gasto histórico con SÓLO el importe cambiado -> la principal
  INSERT INTO public.expenses (user_id, account_id, category, amount, date)
  VALUES (v_user_a, v_acc_a, 'Historico', 300, v_today - 90) RETURNING id INTO v_uuid;
  v_res := pg_temp.cgsd_edit_expense(v_uuid, 350, NULL, FALSE);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (9c edición): editar sólo el importe del histórico debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSIF (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_a0
     OR (SELECT amount FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM 350::numeric THEN
    v_failures := array_append(v_failures, format('FAIL (9c): el histórico editado sólo en el importe debía tomar la PRINCIPAL %s y quedar en 350, quedó branch=%s amount=%s', v_a0, (SELECT branch_id FROM public.expenses WHERE id = v_uuid), (SELECT amount FROM public.expenses WHERE id = v_uuid)));
  END IF;

  -- (9f) forma de pago y centro de costo SIGUEN desimputándose con NULL explícito
  v_uuid := (public.rpc_create_expense(p_category => 'Gate CGSD 9f', p_amount => 100, p_date => v_today,
              p_branch_id => v_b, p_cost_center_id => v_cc, p_payment_method_id => v_pm_other)->>'expense_id')::uuid;
  PERFORM public.rpc_update_expense(p_expense_id => v_uuid,
    p_payment_method_id => NULL, p_payment_method_provided => TRUE,
    p_cost_center_id => NULL, p_cost_center_provided => TRUE,
    p_branch_id => NULL, p_branch_provided => TRUE);
  IF (SELECT payment_method_id FROM public.expenses WHERE id = v_uuid) IS NOT NULL
     OR (SELECT cost_center_id FROM public.expenses WHERE id = v_uuid) IS NOT NULL THEN
    v_failures := array_append(v_failures, 'FAIL (9f): el nulo explícito debía seguir desimputando la forma de pago y el centro de costo (sólo la sucursal cambió de contrato)');
  END IF;
  IF (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_a0 THEN
    v_failures := array_append(v_failures, 'FAIL (9f sucursal): el nulo explícito de sucursal debía registrar la principal');
  END IF;

  -- (9e) cuenta SIN sucursal operativa (OQ-3 (a)): la edición del gasto persiste lo que devuelve
  -- c26_default_branch (la regla literal del alta), sin guard y sin error
  PERFORM pg_temp.cgsd_as(v_user_d);
  INSERT INTO public.expenses (user_id, account_id, category, amount, date)
  VALUES (v_user_d, v_acc_d, 'Residual D', 200, v_today - 40) RETURNING id INTO v_uuid;
  v_res := pg_temp.cgsd_edit_expense(v_uuid, 250, NULL, FALSE);
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (9e): sin sucursal operativa la edición del gasto debía pasar (OQ-3 (a): sin guard, como el alta), falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_uuid2 := public.c26_default_branch(v_acc_d);
    IF v_uuid2 IS NULL OR (SELECT branch_id FROM public.expenses WHERE id = v_uuid) IS DISTINCT FROM v_uuid2 THEN
      v_failures := array_append(v_failures, format('FAIL (9e): sin sucursal operativa el gasto debía persistir lo que devuelve c26_default_branch (%s), quedó %s', v_uuid2, (SELECT branch_id FROM public.expenses WHERE id = v_uuid)));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (9): edición de gasto — NULL informado o vigente (residual o histórico) se resuelve a la principal, la reimputación explícita y la conservación no cambian, forma de pago y centro de costo siguen desimputándose, y sin sucursal operativa persiste el resultado de c26_default_branch';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (10) Borrado EJECUTADO de una compra nueva sin sucursal elegida
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.cgsd_as(v_user_a);
  v_a_before := pg_temp.cgsd_qty(v_a0, v_p2);
  v_b_before := pg_temp.cgsd_qty(v_b, v_p2);
  v_res := pg_temp.cgsd_buy('cgsd-10-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 100.00, 'quantity', 4)),
    NULL, NULL, NULL, NULL, NULL, 'cgsd-10');
  IF NOT (v_res->>'ok')::boolean THEN
    v_failures := array_append(v_failures, format('FAIL (10 setup): la compra sin sucursal debía pasar, falló con %s / %s', v_res->>'state', v_res->>'msg'));
  ELSE
    v_op := (v_res->>'operation_id')::uuid;
    IF pg_temp.cgsd_qty(v_a0, v_p2) IS DISTINCT FROM v_a_before + 4 THEN
      v_failures := array_append(v_failures, format('FAIL (10 setup stock): la compra debía subir la principal a %s, quedó %s', v_a_before + 4, pg_temp.cgsd_qty(v_a0, v_p2)));
    END IF;
    BEGIN
      PERFORM public.rpc_delete_purchase_operation(NULL, v_op, 'gate cgsd 10');
    EXCEPTION WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (10 borrado): el borrado de la compra debía pasar, levantó %s / %s', SQLSTATE, SQLERRM));
    END;
    IF pg_temp.cgsd_qty(v_a0, v_p2) IS DISTINCT FROM v_a_before OR pg_temp.cgsd_qty(v_b, v_p2) IS DISTINCT FROM v_b_before THEN
      v_failures := array_append(v_failures, format('FAIL (10 stock): el borrado debía reponer en la sucursal del movimiento (la principal): A %s -> %s (esperado %s), B %s -> %s (esperado intacto)', v_a_before + 4, pg_temp.cgsd_qty(v_a0, v_p2), v_a_before, v_b_before, pg_temp.cgsd_qty(v_b, v_p2)));
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.purchases WHERE operation_id = v_op;
    IF v_n <> 0 THEN
      v_failures := array_append(v_failures, format('FAIL (10 filas): el borrado debía quitar las filas de la compra, quedan %s', v_n));
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (10): borrado ejecutado — el stock de una compra sin sucursal elegida vuelve a la sucursal del movimiento (la principal)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (11) Remito -> compra (remitos-compra tanda B)
  -- ═══════════════════════════════════════════════════════════════════════
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'rpc_convert_delivery_note_to_purchase' AND pronamespace = 'public'::regnamespace) THEN
    -- Existe la conversión remito -> compra: este gate TODAVÍA no la ejercita. Quien
    -- la agregó (remitos-compra tanda B) tiene que completar este bloque: la compra
    -- convertida queda en la sucursal del remito y no se dispara ningún guard nuevo.
    v_failures := array_append(v_failures, 'FAIL (11): existe rpc_convert_delivery_note_to_purchase y este gate no la ejecuta — completar el bloque (11): la compra convertida queda en la sucursal del remito (obligatoria) y no dispara no_branch_found ni branch_closed');
  ELSE
    RAISE NOTICE 'SKIP (11): rpc_convert_delivery_note_to_purchase no existe (remitos-compra tanda B pendiente) — no aplica';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado y limpieza
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.cgsd_purge(
    ARRAY[v_acc_a, v_acc_c, v_acc_d, v_acc_e],
    ARRAY[v_user_a, v_user_c, v_user_d, v_user_e]);

  -- Residuo cero: las cajas y el stock de las sucursales sintéticas (dependencias
  -- sin account_id propio que sólo la limpieza explícita alcanza) y lo escrito por
  -- las RPCs.
  SELECT COUNT(*) INTO v_n FROM public.cashboxes WHERE branch_id IN (v_a0, v_b, v_c0, v_c1, v_d0, v_d1, v_e0);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s cajas de las sucursales sintéticas', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.branch_stock WHERE branch_id IN (v_a0, v_b, v_c0, v_c1, v_d0, v_d1, v_e0);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s filas de branch_stock de las sucursales sintéticas', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.purchases WHERE account_id IN (v_acc_a, v_acc_c, v_acc_d, v_acc_e);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s compras del fixture', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.expenses WHERE account_id IN (v_acc_a, v_acc_c, v_acc_d, v_acc_e);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s gastos del fixture', v_n));
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.stock_movements WHERE account_id IN (v_acc_a, v_acc_c, v_acc_d, v_acc_e);
  IF v_n <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (limpieza): quedaron %s movimientos de stock del fixture', v_n));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE COMPRAS-GASTOS-SUCURSAL-POR-DEFECTO FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE COMPRAS-GASTOS-SUCURSAL-POR-DEFECTO PASSED: el alta de compra persiste la sucursal resuelta (la elegida o la principal operativa) en purchases, stock_movements, caja y banco; sin sucursal operativa rechaza con P0422 no_branch_found y una elegida cerrada con branch_closed; la edición de compra y de gasto resuelven NULL a la principal; y el opt-in de caja de una compra sin sucursal elegida deja de fallar.';
END $$;
