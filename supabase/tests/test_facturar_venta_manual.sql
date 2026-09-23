-- =============================================================================
-- GATE: test_facturar_venta_manual.sql
-- CHANGE: venta-editable-vs-promocion-legacy (20261061000001) — governance CRÍTICO
--
-- Este gate EJECUTA rpc_promote_legacy_sale_to_order de verdad. Es la razón
-- por la que existe: la RPC abortó con 42883 ("function min(uuid) does not
-- exist") en CADA llamada desde que nació (20260804000001, PR #242) y nadie lo
-- vio durante tres meses porque ningún gate SQL la llamaba y el único test de
-- backend mockea asyncpg (sólo asserta que el query string nombra la RPC).
--
--   (1) N2 — la promoción corre: orden confirmada con total, cliente, sucursal
--       y líneas de la venta, sin tocar stock, caja, cuenta corriente, outbox
--       ni historial (side-effect-free, D1). Triangulado con una venta legacy
--       sin sucursal (→ c26_default_branch) y una sin cliente.
--
-- Los bloques son independientes: cada DO crea su propio anchor sintético y
-- lo limpia (verificado) al final. Un RAISE revierte el bloque entero, así que
-- un fallo nunca deja fixtures commiteados.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── Helpers de sesión (pg_temp: mueren con la conexión) ─────────────────────

-- Anchor sintético: auth.users → handle_new_user crea cuenta + sucursal.
CREATE FUNCTION pg_temp.fvm_anchor(p_email text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_account uuid;
  v_branch  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', p_email, now(), now(),
          jsonb_build_object('name', 'Gate Facturar Venta Manual', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_account
  FROM   public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    -- ABORTA, no degrada: sin cuenta el gate no probaría nada y quedaría verde.
    RAISE EXCEPTION 'GATE FACTURAR-VENTA-MANUAL: SETUP FAILED — handle_new_user no creó la cuenta de %', p_email;
  END IF;

  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'GATE FACTURAR-VENTA-MANUAL: SETUP FAILED — la cuenta de % nació sin sucursal', p_email;
  END IF;

  RETURN jsonb_build_object('user', v_user, 'account', v_account, 'branch', v_branch);
END $f$;

-- Claims del JWT con alcance de transacción (auth.uid() los lee).
CREATE FUNCTION pg_temp.fvm_login(p_user uuid) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_user::text, true);
END $f$;

-- Ejecuta una sentencia y devuelve el SQLSTATE (NULL si no levantó) + mensaje.
-- La sentencia corre en un subbloque: si levanta, sus efectos se revierten.
CREATE FUNCTION pg_temp.fvm_try(p_sql text, OUT o_state text, OUT o_msg text)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := NULL; o_msg := NULL;
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  END;
END $f$;

-- Huella de los libros que la promoción NO debe tocar (D1).
CREATE FUNCTION pg_temp.fvm_ledgers(p_account uuid) RETURNS jsonb
LANGUAGE sql AS $f$
  SELECT jsonb_build_object(
    'branch_stock',   (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    'stock_movements',(SELECT count(*) FROM public.stock_movements WHERE account_id = p_account),
    'cash_movements', (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
                         JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id
                        WHERE b.account_id = p_account),
    'events',         (SELECT count(*) FROM public.events WHERE account_id = p_account),
    'cam',            (SELECT count(*) FROM public.customer_account_movements WHERE account_id = p_account),
    'bank',           (SELECT count(*) FROM public.bank_movements WHERE account_id = p_account),
    'status_history', (SELECT count(*) FROM public.document_status_history WHERE account_id = p_account),
    'fiscal_docs',    (SELECT count(*) FROM public.fiscal_documents WHERE account_id = p_account)
  );
$f$;

-- Limpieza de UN anchor + verificación genérica: ninguna tabla de public con
-- columna account_id conserva filas de la cuenta, y el usuario no quedó.
CREATE FUNCTION pg_temp.fvm_cleanup(p_user uuid, p_account uuid) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
  r       record;
  v_count bigint;
  v_left  text[] := '{}';
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  DELETE FROM public.sales_orders            WHERE account_id = p_account;
  DELETE FROM public.document_status_history WHERE account_id = p_account;
  DELETE FROM public.fiscal_documents        WHERE account_id = p_account;
  DELETE FROM public.document_sequences      WHERE point_of_sale_id IN (SELECT id FROM public.points_of_sale WHERE account_id = p_account);
  DELETE FROM public.points_of_sale          WHERE account_id = p_account;
  DELETE FROM public.fiscal_profiles         WHERE account_id = p_account;
  DELETE FROM public.sale_items              WHERE account_id = p_account;
  DELETE FROM public.stock_movements         WHERE account_id = p_account;
  DELETE FROM public.sales                   WHERE account_id = p_account;
  DELETE FROM public.events                  WHERE account_id = p_account;
  DELETE FROM public.notifications           WHERE account_id = p_account;
  DELETE FROM public.branch_stock            WHERE account_id = p_account;
  DELETE FROM public.products                WHERE account_id = p_account;
  DELETE FROM public.clients                 WHERE account_id = p_account;
  DELETE FROM public.analytics_events        WHERE user_id = p_user;
  DELETE FROM public.payment_methods         WHERE account_id = p_account;
  DELETE FROM public.product_categories      WHERE account_id = p_account;
  DELETE FROM public.account_member_roles    WHERE account_id = p_account;
  DELETE FROM public.cashboxes               WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = p_account);
  -- branches prohíbe el borrado físico (trg_guard_branch_decommission, P0428)
  -- y audit_logs es append-only: bypass explícito para el fixture sintético.
  -- session_replication_role sólo lo fija un rol con privilegio de superusuario
  -- (postgres en CI); no abre ningún camino para authenticated/anon.
  SET LOCAL session_replication_role = replica;
  DELETE FROM public.audit_logs              WHERE account_id = p_account;
  DELETE FROM public.branches                WHERE account_id = p_account;
  DELETE FROM public.account_members         WHERE account_id = p_account OR user_id = p_user;
  DELETE FROM public.accounts                WHERE id = p_account;
  SET LOCAL session_replication_role = DEFAULT;
  DELETE FROM public.profiles                WHERE id = p_user;
  DELETE FROM public.email_logs              WHERE user_id = p_user;
  DELETE FROM public.operation_idempotency   WHERE user_id = p_user;
  DELETE FROM auth.users                     WHERE id = p_user;

  -- Verificación genérica (una tabla nueva con account_id queda cubierta sola).
  FOR r IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables t USING (table_schema, table_name)
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id' AND t.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE account_id = $1', r.table_name)
      INTO v_count USING p_account;
    IF v_count > 0 THEN
      v_left := v_left || format('%s=%s', r.table_name, v_count);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.accounts WHERE id = p_account) THEN
    v_left := v_left || 'accounts=1'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE id = p_user) THEN
    v_left := v_left || 'auth.users=1'::text;
  END IF;
  IF array_length(v_left, 1) > 0 THEN
    RAISE EXCEPTION 'GATE FACTURAR-VENTA-MANUAL: la limpieza dejó filas del fixture: %', array_to_string(v_left, ', ');
  END IF;
END $f$;


-- ═════════════════════════════════════════════════════════════════════════════
-- (1) N2 — la promoción EJECUTA y materializa la orden de la venta.
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures text[] := '{}';
  v_fx       jsonb;
  v_user     uuid;
  v_account  uuid;
  v_branch   uuid;
  v_client   uuid;
  v_product  uuid;
  v_res      jsonb;
  v_op       uuid;
  v_so       uuid;
  v_order    record;
  v_before   jsonb;
  v_after    jsonb;
  v_count    int;
  v_sum      numeric;
BEGIN
  v_fx := pg_temp.fvm_anchor('facturar-venta-manual-1@test.local');
  v_user := (v_fx->>'user')::uuid; v_account := (v_fx->>'account')::uuid; v_branch := (v_fx->>'branch')::uuid;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user, v_account, '__gate_fvm_client__') RETURNING id INTO v_client;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_fvm_product__', 'FVM-1', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 500);

  PERFORM pg_temp.fvm_login(v_user);

  -- Venta cargada a mano con una línea de producto (500 × 2) y una línea de
  -- servicio sin producto (150 × 1): total 1150.
  v_res := public.rpc_create_sale_operation(
    'fvm-1-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(
      jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL),
      jsonb_build_object('product_id', NULL,      'amount', 150.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  IF v_op IS NULL THEN
    RAISE EXCEPTION 'GATE FACTURAR-VENTA-MANUAL (1): SETUP FAILED — rpc_create_sale_operation no devolvió operation_id';
  END IF;

  v_before := pg_temp.fvm_ledgers(v_account);

  -- La llamada de verdad. SIN capturar excepciones: si la RPC aborta (el 42883
  -- de min(uuid) que vivió tres meses), el gate tiene que caerse acá.
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  v_so  := (v_res->>'sales_order_id')::uuid;

  v_after := pg_temp.fvm_ledgers(v_account);

  IF (v_res->>'replayed')::boolean IS DISTINCT FROM false THEN
    v_failures := v_failures || format('(1) la primera promoción debía devolver replayed=false, devolvió %s', v_res);
  END IF;
  IF (v_res->>'sale_operation_id')::uuid IS DISTINCT FROM v_op THEN
    v_failures := v_failures || format('(1) sale_operation_id de la respuesta %s ≠ operación %s', v_res->>'sale_operation_id', v_op);
  END IF;

  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_so;
  IF NOT FOUND THEN
    v_failures := v_failures || format('(1) la orden %s no existe', v_so);
  ELSE
    IF v_order.status IS DISTINCT FROM 'confirmed' THEN
      v_failures := v_failures || format('(1) la orden debía nacer confirmed, nació %s', v_order.status);
    END IF;
    IF v_order.sale_operation_id IS DISTINCT FROM v_op THEN
      v_failures := v_failures || format('(1) la orden no apunta a la operación');
    END IF;
    IF v_order.account_id IS DISTINCT FROM v_account THEN
      v_failures := v_failures || format('(1) la orden nació en otra cuenta');
    END IF;
    IF v_order.total IS DISTINCT FROM 1150.00 THEN
      v_failures := v_failures || format('(1) total de la orden %s, esperaba 1150.00 (Σ sales.total)', v_order.total);
    END IF;
    IF v_order.client_id IS DISTINCT FROM v_client THEN
      v_failures := v_failures || format('(1) client_id de la orden %s ≠ cliente de la venta %s', v_order.client_id, v_client);
    END IF;
    IF v_order.branch_id IS DISTINCT FROM v_branch THEN
      v_failures := v_failures || format('(1) branch_id de la orden %s ≠ sucursal de la venta %s', v_order.branch_id, v_branch);
    END IF;
    IF v_order.payment_method_id IS NOT NULL THEN
      v_failures := v_failures || format('(1) la promoción inventó una forma de pago (%s)', v_order.payment_method_id);
    END IF;
    IF v_order.created_by IS DISTINCT FROM v_user THEN
      v_failures := v_failures || format('(1) created_by %s ≠ auth.uid() %s', v_order.created_by, v_user);
    END IF;
    IF v_order.fiscal_document_id IS NOT NULL THEN
      v_failures := v_failures || format('(1) la orden nació con comprobante: la promoción NO emite');
    END IF;
  END IF;

  SELECT count(*), COALESCE(sum(subtotal), 0) INTO v_count, v_sum
  FROM public.sales_order_items WHERE sales_order_id = v_so;
  IF v_count <> 2 THEN
    v_failures := v_failures || format('(1) esperaba 2 líneas (producto + servicio), hay %s', v_count);
  END IF;
  IF v_sum IS DISTINCT FROM 1150.00 THEN
    v_failures := v_failures || format('(1) Σ subtotal de las líneas %s ≠ total 1150.00', v_sum);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_order_items
                 WHERE sales_order_id = v_so AND product_id IS NULL AND quantity = 1 AND price = 150 AND subtotal = 150) THEN
    v_failures := v_failures || format('(1) falta la línea de servicio (product_id NULL, 150 × 1)');
  END IF;

  -- D1: side-effect-free.
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('(1) la promoción tocó libros que no debía: antes %s, después %s', v_before, v_after);
  END IF;

  -- ── (1b) venta legacy SIN sucursal (filas planas, sin sale_items — la forma
  -- de 361 operaciones de prod) → la orden toma c26_default_branch.
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user, v_account, v_client, NULL, 200.00, 1, 200.00, 'ARS', now(), v_op, NULL),
         (v_user, v_account, v_client, NULL, 50.25, 2, 100.50, 'ARS', now(), v_op, NULL);

  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  SELECT * INTO v_order FROM public.sales_orders WHERE id = (v_res->>'sales_order_id')::uuid;
  IF v_order.branch_id IS DISTINCT FROM public.c26_default_branch(v_account) THEN
    v_failures := v_failures || format('(1b) venta sin sucursal: la orden debía tomar c26_default_branch (%s), tomó %s',
                                       public.c26_default_branch(v_account), v_order.branch_id);
  END IF;
  IF v_order.total IS DISTINCT FROM 300.50 THEN
    v_failures := v_failures || format('(1b) total %s, esperaba 300.50', v_order.total);
  END IF;
  SELECT count(*) INTO v_count FROM public.sales_order_items WHERE sales_order_id = v_order.id;
  IF v_count <> 2 THEN
    v_failures := v_failures || format('(1b) esperaba una línea por fila de sales (2), hay %s', v_count);
  END IF;

  -- ── (1c) venta SIN cliente (consumidor final) → orden con client_id NULL.
  v_res := public.rpc_create_sale_operation(
    'fvm-1c-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  SELECT * INTO v_order FROM public.sales_orders WHERE id = (v_res->>'sales_order_id')::uuid;
  IF NOT FOUND OR v_order.client_id IS NOT NULL OR v_order.total IS DISTINCT FROM 500.00 THEN
    v_failures := v_failures || format('(1c) venta sin cliente: esperaba orden con client_id NULL y total 500.00, quedó client=%s total=%s',
                                       COALESCE(v_order.client_id::text, '<null>'), COALESCE(v_order.total::text, '<null>'));
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (1) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  PERFORM pg_temp.fvm_cleanup(v_user, v_account);
  RAISE NOTICE 'PASS (1): la promoción EJECUTA — orden confirmada con total 1150.00 = Σ sales.total, cliente, sucursal, 2 líneas (producto + servicio), sin forma de pago inventada y sin tocar stock/caja/cuenta corriente/banco/outbox/historial; venta sin sucursal → c26_default_branch; venta sin cliente → client_id NULL.';
END $$;


-- ═════════════════════════════════════════════════════════════════════════════
-- (2)-(6) Idempotencia, tenencia, permisos, filas heterogéneas y sale_items
-- duplicados (H2). Un solo DO con dos cuentas (A dueña, B ajena) y un miembro
-- sin rol de escritura (C) en la cuenta A.
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures  text[] := '{}';
  v_fa        jsonb;
  v_fb        jsonb;
  v_fc        jsonb;
  v_user_a    uuid; v_account_a uuid; v_branch_a uuid;
  v_user_b    uuid; v_account_b uuid; v_branch_b uuid;
  v_user_c    uuid; v_account_c uuid;
  v_member_c  uuid;
  v_client_a  uuid; v_client_a2 uuid;
  v_branch_a2 uuid;
  v_product   uuid;
  v_res       jsonb;
  v_op        uuid;
  v_so        uuid;
  v_so2       uuid;
  v_sale      uuid;
  v_try       record;
  v_count     int;
  v_order     record;
  v_line      record;
BEGIN
  v_fa := pg_temp.fvm_anchor('facturar-venta-manual-2a@test.local');
  v_user_a := (v_fa->>'user')::uuid; v_account_a := (v_fa->>'account')::uuid; v_branch_a := (v_fa->>'branch')::uuid;
  v_fb := pg_temp.fvm_anchor('facturar-venta-manual-2b@test.local');
  v_user_b := (v_fb->>'user')::uuid; v_account_b := (v_fb->>'account')::uuid; v_branch_b := (v_fb->>'branch')::uuid;
  v_fc := pg_temp.fvm_anchor('facturar-venta-manual-2c@test.local');
  v_user_c := (v_fc->>'user')::uuid; v_account_c := (v_fc->>'account')::uuid;

  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_fvm_client_a__') RETURNING id INTO v_client_a;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user_a, v_account_a, '__gate_fvm_client_a2__') RETURNING id INTO v_client_a2;
  INSERT INTO public.branches (account_id, name) VALUES (v_account_a, '__gate_fvm_branch_a2__') RETURNING id INTO v_branch_a2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, '__gate_fvm_product_2__', 'FVM-2', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_product, v_branch_a, 500);

  -- C es miembro de A SÓLO como viewer (is_writer = false).
  INSERT INTO public.account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account_a, v_user_c, 'member') RETURNING id INTO v_member_c;
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_c, 'viewer', now());

  PERFORM pg_temp.fvm_login(v_user_a);
  v_res := public.rpc_create_sale_operation(
    'fvm-2-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;

  -- ── (2) Idempotencia: tres llamadas → UNA orden, mismas líneas.
  v_so  := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  IF (v_res->>'sales_order_id')::uuid IS DISTINCT FROM v_so OR (v_res->>'replayed')::boolean IS DISTINCT FROM true THEN
    v_failures := v_failures || format('(2) la segunda promoción debía devolver la MISMA orden con replayed=true, devolvió %s', v_res);
  END IF;
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  IF (v_res->>'sales_order_id')::uuid IS DISTINCT FROM v_so OR (v_res->>'replayed')::boolean IS DISTINCT FROM true THEN
    v_failures := v_failures || format('(2) la tercera promoción debía devolver la MISMA orden con replayed=true, devolvió %s', v_res);
  END IF;
  SELECT count(*) INTO v_count FROM public.sales_orders WHERE sale_operation_id = v_op;
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(2) %s órdenes para la operación, esperaba 1', v_count);
  END IF;
  SELECT count(*) INTO v_count FROM public.sales_order_items WHERE sales_order_id = v_so;
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(2) el replay duplicó líneas: %s, esperaba 1', v_count);
  END IF;

  -- (6b) venta normal (sale_items de rpc_create_sale_operation): la línea de la
  -- orden conserva los snapshots de la venta.
  SELECT soi.name_snapshot, soi.unit_cost_snapshot INTO v_line
  FROM public.sales_order_items soi WHERE soi.sales_order_id = v_so;
  IF v_line.name_snapshot IS DISTINCT FROM '__gate_fvm_product_2__' OR v_line.unit_cost_snapshot IS DISTINCT FROM 300.00 THEN
    v_failures := v_failures || format('(6b) la línea de la orden no conservó los snapshots de sale_items (quedó %s / %s)',
      COALESCE(v_line.name_snapshot, '<null>'), COALESCE(v_line.unit_cost_snapshot::text, '<null>'));
  END IF;

  -- ── (3) Tenencia: B promueve la operación de A → P0404, nada creado.
  DELETE FROM public.sales_orders WHERE sale_operation_id = v_op;
  PERFORM pg_temp.fvm_login(v_user_b);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0404' OR position('operation_not_found' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(3) una cuenta ajena debía recibir P0404 operation_not_found, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  -- Operación inexistente y NULL: también P0404.
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', gen_random_uuid()));
  IF v_try.o_state IS DISTINCT FROM 'P0404' THEN
    v_failures := v_failures || format('(3) operación inexistente: esperaba P0404, recibió %s', COALESCE(v_try.o_state, 'ningún error'));
  END IF;
  SELECT * INTO v_try FROM pg_temp.fvm_try('SELECT public.rpc_promote_legacy_sale_to_order(NULL::uuid)');
  IF v_try.o_state IS DISTINCT FROM 'P0404' THEN
    v_failures := v_failures || format('(3) operación NULL: esperaba P0404, recibió %s', COALESCE(v_try.o_state, 'ningún error'));
  END IF;

  -- ── (4) Miembro SIN rol de escritura → P0401, nada creado.
  PERFORM pg_temp.fvm_login(v_user_c);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0401' OR position('unauthorized' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(4) un viewer debía recibir P0401 unauthorized, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  SELECT count(*) INTO v_count FROM public.sales_orders WHERE sale_operation_id = v_op;
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(3)/(4) una promoción rechazada dejó %s orden(es)', v_count);
  END IF;

  -- ── (5) Operaciones heterogéneas (filas insertadas a mano con el mismo
  -- operation_id). Nunca se agrega a ciegas: P0422 operation_inconsistent.
  PERFORM pg_temp.fvm_login(v_user_a);

  -- (5a) distinto cliente
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_client_a,  100, 1, 100, 'ARS', now(), v_op, v_branch_a),
         (v_user_a, v_account_a, v_client_a2, 100, 1, 100, 'ARS', now(), v_op, v_branch_a);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0422' OR position('operation_inconsistent' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(5a) distinto cliente: esperaba P0422 operation_inconsistent, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE sale_operation_id = v_op) THEN
    v_failures := v_failures || format('(5a) quedó una orden para una operación con clientes mezclados');
  END IF;

  -- (5b) distinta sucursal
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_client_a, 100, 1, 100, 'ARS', now(), v_op, v_branch_a),
         (v_user_a, v_account_a, v_client_a, 100, 1, 100, 'ARS', now(), v_op, v_branch_a2);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0422' OR position('operation_inconsistent' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(5b) distinta sucursal: esperaba P0422 operation_inconsistent, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE sale_operation_id = v_op) THEN
    v_failures := v_failures || format('(5b) quedó una orden para una operación con sucursales mezcladas');
  END IF;

  -- (5c) cliente y NULL mezclados (NULL cuenta como valor)
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_client_a, 100, 1, 100, 'ARS', now(), v_op, v_branch_a),
         (v_user_a, v_account_a, NULL,       100, 1, 100, 'ARS', now(), v_op, v_branch_a);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0422' OR position('operation_inconsistent' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(5c) cliente/NULL mezclados: esperaba P0422 operation_inconsistent, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE sale_operation_id = v_op) THEN
    v_failures := v_failures || format('(5c) quedó una orden para una operación con cliente y consumidor final mezclados');
  END IF;

  -- (5d) una fila de OTRA cuenta con el mismo operation_id → fail-closed P0404
  -- (la fila ajena nunca se factura ni se suma).
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, NULL, 100, 1, 100, 'ARS', now(), v_op, v_branch_a),
         (v_user_b, v_account_b, NULL, 999, 1, 999, 'ARS', now(), v_op, v_branch_b);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0404' THEN
    v_failures := v_failures || format('(5d) operación con una fila de otra cuenta: esperaba P0404, recibió %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE sale_operation_id = v_op) THEN
    v_failures := v_failures || format('(5d) quedó una orden para una operación con una fila ajena');
  END IF;

  -- ── (6) H2 — sale_items duplicados, con la forma REAL de prod (medida el
  -- 2026-09-23: 23 filas, cada una con un sale_item del producto y OTRO sin
  -- producto, mismo subtotal; el índice único (sale_id, product_id) impide dos
  -- del mismo producto). El importe canónico es la cabecera: 1000, no 2000.
  -- El sale_item sin producto se inserta con el id MENOR a propósito: un
  -- "ORDER BY id LIMIT 1" ciego elegiría ése y perdería los snapshots.
  v_op := gen_random_uuid();
  INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_a, v_account_a, v_client_a, v_product, 500, 2, 1000, 'ARS', now(), v_op, v_branch_a)
  RETURNING id INTO v_sale;
  INSERT INTO public.sale_items (id, sale_id, product_id, account_id, quantity, price, subtotal,
                                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
  VALUES ('00000000-0000-4000-8000-000000000001', v_sale, NULL,      v_account_a, 2, 500, 1000, NULL, NULL, NULL, NULL),
         ('ffffffff-ffff-4fff-bfff-ffffffffffff', v_sale, v_product, v_account_a, 2, 500, 1000,
          '__snap_fvm_producto__', 'FVM-2', 300, 21);

  v_so2 := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_so2;
  IF v_order.total IS DISTINCT FROM 1000.00 THEN
    v_failures := v_failures || format('(6) H2: total %s — con sale_items duplicados la orden se factura al DOBLE; esperaba 1000.00 (cabecera)', v_order.total);
  END IF;
  SELECT count(*) INTO v_count FROM public.sales_order_items WHERE sales_order_id = v_so2;
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(6) H2: esperaba UNA línea por fila de sales, hay %s', v_count);
  END IF;
  SELECT * INTO v_line FROM public.sales_order_items WHERE sales_order_id = v_so2 ORDER BY id LIMIT 1;
  IF v_line.product_id IS DISTINCT FROM v_product
     OR v_line.subtotal IS DISTINCT FROM 1000.00
     OR v_line.name_snapshot IS DISTINCT FROM '__snap_fvm_producto__'
     OR v_line.unit_cost_snapshot IS DISTINCT FROM 300.00
     OR v_line.iva_rate_snapshot IS DISTINCT FROM 21.00 THEN
    v_failures := v_failures || format('(6) la línea debía llevar el producto y los snapshots del sale_item DEL PRODUCTO (%s, 1000, __snap_fvm_producto__, 300, 21); quedó (%s, %s, %s, %s, %s)',
      v_product, v_line.product_id, v_line.subtotal, COALESCE(v_line.name_snapshot, '<null>'), v_line.unit_cost_snapshot, v_line.iva_rate_snapshot);
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (2)-(6) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  DELETE FROM public.sales WHERE account_id = v_account_b;
  PERFORM pg_temp.fvm_cleanup(v_user_c, v_account_c);
  PERFORM pg_temp.fvm_cleanup(v_user_b, v_account_b);
  PERFORM pg_temp.fvm_cleanup(v_user_a, v_account_a);
  RAISE NOTICE 'PASS (2)-(6): idempotente (3 llamadas → 1 orden, líneas sin duplicar, snapshots de sale_items conservados); cuenta ajena, operación inexistente y NULL → P0404; viewer → P0401; clientes/sucursales mezclados → P0422 operation_inconsistent; fila de otra cuenta → P0404; sale_items duplicados → total por cabecera (1000, no 2000) y la línea con los snapshots del sale_item del producto.';
END $$;
