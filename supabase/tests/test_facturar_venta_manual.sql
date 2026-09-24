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


-- Perfil fiscal MONOTRIBUTISTA en homologación + un punto de venta propio
-- (rpc_emit_sale_invoice bloquea a los RI). CUIT/PV propios de este gate:
-- fn_guard_pos_cuit_cross_account (P0435) rechaza el mismo CUIT con el mismo
-- PV activo en otra cuenta, y los demás gates fiscales usan otros.
CREATE FUNCTION pg_temp.fvm_fiscal(p_account uuid) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_fp uuid; v_pv uuid;
BEGIN
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (p_account, '20999999997', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, p_account, 9801, true) RETURNING id INTO v_pv;
  RETURN v_pv;
END $f$;


-- ═════════════════════════════════════════════════════════════════════════════
-- (7), (9), (10) N3 — la edición RECALCULA la orden que re-apunta. Antes sólo
-- movía sale_operation_id: total, cliente y líneas quedaban VIEJOS, y tanto la
-- re-emisión después de anular (D5 de venta-editable-sin-cae) como el
-- "Facturar" de una venta del POS editada emitían por el importe anterior. Las
-- órdenes se insertan a mano (como las del POS): este bloque no depende de la
-- promoción.
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures text[] := '{}';
  v_fx       jsonb;
  v_user     uuid; v_account uuid; v_branch uuid;
  v_client   uuid; v_client2 uuid;
  v_product  uuid;
  v_pv       uuid;
  v_res      jsonb;
  v_op       uuid;
  v_op_new   uuid;
  v_sale     uuid;
  v_so       uuid;
  v_doc      uuid;
  v_doc2     uuid;
  v_order    record;
  v_fd       record;
  v_count    int;
  v_sum      numeric;
  v_try      record;
BEGIN
  v_fx := pg_temp.fvm_anchor('facturar-venta-manual-7@test.local');
  v_user := (v_fx->>'user')::uuid; v_account := (v_fx->>'account')::uuid; v_branch := (v_fx->>'branch')::uuid;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, '__gate_fvm_client_7__') RETURNING id INTO v_client;
  INSERT INTO public.clients (user_id, account_id, name, tax_id, iva_condition)
  VALUES (v_user, v_account, '__gate_fvm_client_7b__', '20111111113', 'monotributista') RETURNING id INTO v_client2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_fvm_product_7__', 'FVM-7', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 500);
  v_pv := pg_temp.fvm_fiscal(v_account);
  PERFORM pg_temp.fvm_login(v_user);

  -- ── (7) venta $1000 + orden (forma del POS) → editar a 500 × 5 con OTRO
  -- cliente. La orden re-apuntada tiene que quedar en 2500, con el cliente
  -- nuevo y las líneas nuevas; y lo que se emite después, también.
  v_res := public.rpc_create_sale_operation(
    'fvm-7-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op;
  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, v_client, 'confirmed', 1000, v_user, v_op) RETURNING id INTO v_so;
  INSERT INTO public.sales_order_items (sales_order_id, account_id, product_id, quantity, price, subtotal)
  VALUES (v_so, v_account, v_product, 2, 500, 1000);

  v_res := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale], v_client2, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 5)));
  v_op_new := (v_res->>'operation_id')::uuid;

  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_so;
  IF v_order.sale_operation_id IS DISTINCT FROM v_op_new THEN
    v_failures := v_failures || format('(7) la orden no se re-apuntó a la operación nueva');
  END IF;
  IF v_order.total IS DISTINCT FROM 2500.00 THEN
    v_failures := v_failures || format('(7) N3: la orden re-apuntada quedó con total %s — se facturaría el importe VIEJO; esperaba 2500.00', v_order.total);
  END IF;
  IF v_order.client_id IS DISTINCT FROM v_client2 THEN
    v_failures := v_failures || format('(7) N3: la orden re-apuntada conservó el cliente viejo');
  END IF;
  SELECT count(*), COALESCE(sum(subtotal), 0) INTO v_count, v_sum FROM public.sales_order_items WHERE sales_order_id = v_so;
  IF v_count <> 1 OR v_sum IS DISTINCT FROM 2500.00
     OR NOT EXISTS (SELECT 1 FROM public.sales_order_items WHERE sales_order_id = v_so AND quantity = 5 AND price = 500) THEN
    v_failures := v_failures || format('(7) N3: las líneas de la orden no son las de la venta editada (%s líneas, Σ %s)', v_count, v_sum);
  END IF;

  v_doc := (public.rpc_emit_sale_invoice(v_so, v_pv)->>'fiscal_document_id')::uuid;
  SELECT * INTO v_fd FROM public.fiscal_documents WHERE id = v_doc;
  IF v_fd.total IS DISTINCT FROM 2500.00 OR v_fd.client_id IS DISTINCT FROM v_client2 THEN
    v_failures := v_failures || format('(7) el comprobante emitido después de editar salió por %s / cliente %s — esperaba 2500.00 y el cliente nuevo',
      v_fd.total, COALESCE(v_fd.client_id::text, '<null>'));
  END IF;
  IF v_fd.receptor_doc_tipo IS DISTINCT FROM 96 OR v_fd.receptor_doc_nro IS DISTINCT FROM '20111111113' THEN
    v_failures := v_failures || format('(7) el receptor del comprobante no es el del cliente nuevo (%s / %s)', v_fd.receptor_doc_tipo, v_fd.receptor_doc_nro);
  END IF;

  -- ── (10) Re-emisión después de ANULAR (el caso de #582 con el total que
  -- faltaba assertar): editar la cantidad anula el pendiente; lo re-emitido
  -- tiene que salir por el importe NUEVO.
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op_new;
  v_res := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale], v_client2, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 3)));
  v_op_new := (v_res->>'operation_id')::uuid;
  SELECT status INTO v_fd FROM public.fiscal_documents WHERE id = v_doc;
  IF v_fd.status IS DISTINCT FROM 'voided' THEN
    v_failures := v_failures || format('(10) el comprobante pendiente debía quedar voided, quedó %s', v_fd.status);
  END IF;
  v_doc2 := (public.rpc_emit_sale_invoice(v_so, v_pv)->>'fiscal_document_id')::uuid;
  SELECT * INTO v_fd FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_fd.total IS DISTINCT FROM 1500.00 THEN
    v_failures := v_failures || format('(10) N3: "Volver a facturar" después de anular emitió %s — esperaba el importe NUEVO 1500.00', v_fd.total);
  END IF;

  -- TRIANGULATE: re-emisión después de un RECHAZO, con otra edición en el medio.
  PERFORM public.rpc_fiscal_document_reject(v_doc2, 'rechazo sintético del gate');
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op_new;
  v_res := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale], v_client2, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 450.00, 'quantity', 4)));
  v_doc2 := (public.rpc_emit_sale_invoice(v_so, v_pv)->>'fiscal_document_id')::uuid;
  SELECT * INTO v_fd FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_fd.total IS DISTINCT FROM 1800.00 THEN
    v_failures := v_failures || format('(10b) re-emisión después de un rechazo + edición emitió %s — esperaba 1800.00', v_fd.total);
  END IF;

  -- ── (9) Borrado después de promover: la orden se cancela y se desvincula;
  -- una emisión posterior (botón que quedó en pantalla) no tiene qué facturar.
  v_res := public.rpc_create_sale_operation(
    'fvm-9-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  v_so := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
  IF NOT public.rpc_delete_sale_operation(NULL, v_op, 'gate (9)') THEN
    v_failures := v_failures || format('(9) el borrado de la operación promovida devolvió false');
  END IF;
  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_so;
  IF v_order.status IS DISTINCT FROM 'canceled' OR v_order.sale_operation_id IS NOT NULL THEN
    v_failures := v_failures || format('(9) la orden de una venta borrada debía quedar canceled y desvinculada (quedó %s / %s)', v_order.status, v_order.sale_operation_id);
  END IF;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so, v_pv));
  IF v_try.o_state IS DISTINCT FROM 'P0400' OR position('order_not_confirmed' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(9) emitir sobre la orden de una venta borrada debía dar P0400 order_not_confirmed, dio %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (7)/(9)/(10) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  PERFORM pg_temp.fvm_cleanup(v_user, v_account);
  RAISE NOTICE 'PASS (7)/(9)/(10): la edición recalcula la orden que re-apunta (total 2500, cliente y líneas nuevas) y el comprobante sale por el importe y el receptor nuevos; re-emitir después de anular sale por el importe NUEVO (1500), también después de un rechazo + edición (1800); borrar una venta promovida cancela y desvincula la orden y la emisión posterior da P0400 order_not_confirmed.';
END $$;


-- ═════════════════════════════════════════════════════════════════════════════
-- (0) Estructura: el helper de sincronización es INVOKER y está cerrado a
-- anon/authenticated; su firma RESUELVE (meta-candado: el chequeo (3) de
-- test_function_acl_gate.sql es drift-tolerante y una firma vieja lo apaga EN
-- SILENCIO); una sola definición viva de cada función tocada (42725); los
-- COMMENT vivos de las 4 RPCs reescritas se conservan (CREATE OR REPLACE
-- mantiene el oid y su comentario — md5 medido en prod el 2026-09-23); y
-- (0L) el ORDEN GLOBAL DE LOCKS (sales id asc → sales_orders →
-- fiscal_documents) en las cuatro RPCs y el helper.
--
-- Por qué (0L) vive ACÁ y no sólo en el DO de la migración: el DO corre UNA
-- vez, al aplicar 20261061000001; una migración futura que reescriba estas
-- RPCs (la edición ya se reescribió más de 6 veces) no lo vuelve a correr y
-- quedaría verde en CI. El red team del 2026-09-24 lo midió con mutantes que
-- ESTE gate dejaba vivos y que hacen daño real:
--   n7  la edición toma sales DESPUÉS del enumerador de órdenes → N1 exacto
--       (pending_cae por 1000 vivo sobre una operación sin filas, venta en 111);
--   n6  la promoción toma la orden antes que sales → 40P01 contra la edición;
--   n10 el borrado sin recuento bajo el lock → "borra" (true) una venta que la
--       edición ya movió y encola un SaleOperationDeleted espurio.
-- Se compara sobre el cuerpo SIN comentarios y con espacios colapsados. El
-- comportamiento en dos conexiones lo cubre test_facturar_venta_manual_race.sh
-- (R7 mata n10, R8 mata n6); esto es el candado de estructura, barato y
-- determinístico, que corre en cada PR.
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures text[] := '{}';
  v_fn       text;
  v_count    int;
  v_md5      text;
  r          record;
  v_def      text;
  v_lock     int;
  v_first    int;
BEGIN
  IF to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)') IS NULL THEN
    v_failures := v_failures || format('(0) public._sales_order_sync_from_operation(uuid, uuid, uuid) NO RESUELVE: la entrada de v_internal_only_fns en test_function_acl_gate.sql quedaría apagada en silencio');
  ELSE
    IF (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)')) THEN
      v_failures := v_failures || format('(0) el helper de sincronización debe ser SECURITY INVOKER (sólo corre dentro de RPCs SECURITY DEFINER)');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND (   has_function_privilege('anon',          to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)'), 'EXECUTE')
            OR has_function_privilege('authenticated', to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)'), 'EXECUTE')) THEN
      v_failures := v_failures || format('(0) el helper de sincronización es ejecutable por anon/authenticated: sería la primitiva para reescribir por PostgREST el total de una orden ajena');
    END IF;
  END IF;

  FOREACH v_fn IN ARRAY ARRAY['rpc_promote_legacy_sale_to_order', 'rpc_atomic_update_sale_operation',
                              'rpc_delete_sale_operation', 'rpc_emit_sale_invoice',
                              '_sales_order_sync_from_operation']
  LOOP
    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_fn;
    IF v_count <> 1 THEN
      v_failures := v_failures || format('(0) %s: %s definiciones vivas (esperaba 1)', v_fn, v_count);
    END IF;
  END LOOP;

  FOR r IN
    SELECT * FROM (VALUES
      ('public.rpc_promote_legacy_sale_to_order(uuid)', 'ce7de587bb7b83e33d50436f383fcbfd'),
      ('public.rpc_emit_sale_invoice(uuid, uuid)', '9472c9d93a85a73370a10e71fbb7beb4'),
      ('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)', '1675d3824b79fccd3efba3b256adf89e'),
      ('public.rpc_delete_sale_operation(uuid, uuid, text)', 'b3bafc6d5c0a20bbd42b006af8769513')
    ) AS t(sig, md5)
  LOOP
    SELECT md5(replace(obj_description(to_regprocedure(r.sig), 'pg_proc'), chr(13), '')) INTO v_md5;
    IF v_md5 IS DISTINCT FROM r.md5 THEN
      v_failures := v_failures || format('(0) el COMMENT de %s cambió (md5 %s, el vivo de prod es %s): la reescritura no debe tocarlo', r.sig, COALESCE(v_md5, '<sin comentario>'), r.md5);
    END IF;
  END LOOP;

  -- ── (0L) Orden global de locks ─────────────────────────────────────────────
  -- Convención: v_lock = posición del lock de las filas de sales; v_first =
  -- primera mención de sales_orders o fiscal_documents (lectura O lock: leer
  -- la orden antes de tomar las filas es exactamente la ventana de N1).

  -- (0L-a) Promoción: sales (id asc, sólo filas del caller) FOR UPDATE ANTES de
  -- tocar sales_orders — ni leerla, ni lockearla, ni insertarla (mata n6, que
  -- tomaba la orden primero y abría un 40P01 contra la edición).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_promote_legacy_sale_to_order(uuid)');
  v_def   := COALESCE(v_def, '');
  v_lock  := position('where s.operation_id = p_operation_id order by s.id for update of s' in v_def);
  v_first := LEAST(NULLIF(position('sales_orders' in v_def), 0), NULLIF(position('fiscal_documents' in v_def), 0));
  IF v_lock = 0 THEN
    v_failures := v_failures || format('(0L-a) la promoción no toma las filas de sales de la operación FOR UPDATE en orden de id (ancla de exclusión de N1)');
  ELSIF v_first IS NULL OR v_first < v_lock THEN
    v_failures := v_failures || format('(0L-a) la promoción menciona sales_orders/fiscal_documents (pos %s) ANTES de tomar las filas de sales (pos %s): invierte el orden global de locks → 40P01 contra la edición (mutante n6)', v_first, v_lock);
  END IF;
  IF v_def ~ '\mmin\s*\(' THEN
    v_failures := v_failures || format('(0L-a) la promoción agrega con MIN(): min(uuid) no existe y aborta con 42883 (N2)');
  END IF;

  -- (0L-b) Edición: sales FOR UPDATE, SEGUIDO del recuento que aborta con
  -- P0404 si otra edición/borrado se llevó alguna fila, y todo ANTES de la
  -- primera mención de sales_orders/fiscal_documents y del helper de anulación
  -- (mata n7 — N1 exacto — y n9 — doble «Guardar» que duplica la operación).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)');
  v_def   := COALESCE(v_def, '');
  v_lock  := position('where s.id = any(p_sale_ids) and s.user_id = v_uid order by s.id for update ) l; if v_locked <> array_length(p_sale_ids, 1) then raise exception' in v_def);
  v_first := LEAST(NULLIF(position('sales_orders' in v_def), 0), NULLIF(position('fiscal_documents' in v_def), 0),
                   NULLIF(position('_fiscal_void_pending_for_sale_edit(' in v_def), 0));
  IF v_lock = 0 THEN
    v_failures := v_failures || format('(0L-b) la edición no toma las filas de sales FOR UPDATE en orden de id seguido del recuento bajo el lock (P0404 si otra edición o un borrado se llevó alguna)');
  ELSIF v_first IS NULL OR v_first < v_lock THEN
    v_failures := v_failures || format('(0L-b) la edición resuelve la orden (pos %s) ANTES de tomar las filas de sales (pos %s): no ve la orden que una promoción concurrente está creando y deja un pending_cae VIVO por los importes viejos (N1, mutante n7)', v_first, v_lock);
  END IF;
  IF position('_sales_order_sync_from_operation(' in v_def) = 0 THEN
    v_failures := v_failures || format('(0L-b) la edición re-apunta la orden sin recalcularla con el helper único (N3)');
  END IF;

  -- (0L-c) Borrado: sales FOR UPDATE, SEGUIDO del recuento (vacío → RETURN
  -- false), y todo ANTES de resolver la orden (mata n10 y n8).
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_delete_sale_operation(uuid, uuid, text)');
  v_def   := COALESCE(v_def, '');
  v_lock  := position('where s.id = any(v_sale_ids) and s.account_id = v_account_id order by s.id for update ) l; if v_sale_ids is null or array_length(v_sale_ids, 1) is null then return false; end if;' in v_def);
  v_first := LEAST(NULLIF(position('sales_orders' in v_def), 0), NULLIF(position('fiscal_documents' in v_def), 0),
                   NULLIF(position('_fiscal_void_pending_for_sale_edit(' in v_def), 0));
  IF v_lock = 0 THEN
    v_failures := v_failures || format('(0L-c) el borrado no toma las filas de sales FOR UPDATE en orden de id seguido del recuento bajo el lock (vacío → false): si una edición ganó, "borraría" una venta que ya no existe y encolaría un SaleOperationDeleted espurio (mutante n10)');
  ELSIF v_first IS NULL OR v_first < v_lock THEN
    v_failures := v_failures || format('(0L-c) el borrado resuelve la orden (pos %s) ANTES de tomar las filas de sales (pos %s): N1 (mutante n8)', v_first, v_lock);
  END IF;

  -- (0L-d) Emisión: NUNCA toma sales (sólo la lee): con la orden tomada, un
  -- lock sobre sales invertiría el orden global → deadlock con la edición
  -- (mutante n13). Y el guard D6 va ANTES de emitir, con la allow-list de
  -- re-emisión de venta-editable-sin-cae intacta.
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public.rpc_emit_sale_invoice(uuid, uuid)');
  v_def := COALESCE(v_def, '');
  IF v_def ~ '(from|join) (public\.)?sales\M[^;]*for (update|share|no key update|key share)' THEN
    v_failures := v_failures || format('(0L-d) la emisión toma locks sobre sales: invierte el orden global de locks y abre un deadlock contra la edición (mutante n13)');
  END IF;
  IF position('sales_order_out_of_sync' in v_def) = 0
     OR position('rpc_emit_pending_cae(' in v_def) = 0
     OR position('sales_order_out_of_sync' in v_def) > position('rpc_emit_pending_cae(' in v_def) THEN
    v_failures := v_failures || format('(0L-d) la emisión no verifica que la orden coincida con su venta ANTES de emitir (D6)');
  END IF;
  IF position('not in (''rejected'', ''voided'')' in v_def) = 0 THEN
    v_failures := v_failures || format('(0L-d) la emisión perdió la ALLOW-LIST de re-emisión de venta-editable-sin-cae');
  END IF;

  -- (0L-e) El helper de sincronización toma la orden, nunca sales (el caller
  -- ya las tiene): un lock sobre sales desde acá sería un segundo punto de
  -- entrada al orden global.
  SELECT lower(regexp_replace(regexp_replace(prosrc, '--[^' || chr(10) || ']*', '', 'g'), '\s+', ' ', 'g'))
  INTO   v_def
  FROM   pg_proc WHERE oid = to_regprocedure('public._sales_order_sync_from_operation(uuid, uuid, uuid)');
  IF COALESCE(v_def, '') ~ '(from|join) (public\.)?sales\M[^;]*for (update|share|no key update|key share)' THEN
    v_failures := v_failures || format('(0L-e) el helper de sincronización toma locks sobre sales: el caller ya las tiene y el orden global es sales → sales_orders');
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (0) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (0): helper de sincronización INVOKER, cerrado a anon/authenticated y con firma que resuelve; una sola definición viva de las 5 funciones; COMMENT vivos de las 4 RPCs intactos; (0L) orden global de locks sales → sales_orders → fiscal_documents en promoción, edición y borrado, con recuento bajo el lock en edición y borrado, y la emisión y el helper sin tomar sales.';
END $$;


-- ═════════════════════════════════════════════════════════════════════════════
-- (8), (11) D6 — la emisión RECHAZA una orden que no coincide con su venta
-- (importe a 2 decimales o receptor), fail-closed, en el punto donde el daño
-- se vuelve real. La salida del usuario es volver a tocar "Facturar": la
-- promoción en replay re-sincroniza una orden sin comprobante vivo. Con un
-- comprobante vivo, el replay NO toca la orden.
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures text[] := '{}';
  v_fx       jsonb;
  v_user     uuid; v_account uuid; v_branch uuid;
  v_client   uuid; v_client2 uuid;
  v_product  uuid;
  v_pv       uuid;
  v_res      jsonb;
  v_op       uuid;
  v_so       uuid;
  v_so_ok    uuid;
  v_doc      uuid;
  v_fd       record;
  v_order    record;
  v_try      record;
  v_docs     int;
  v_count    int;
BEGIN
  v_fx := pg_temp.fvm_anchor('facturar-venta-manual-8@test.local');
  v_user := (v_fx->>'user')::uuid; v_account := (v_fx->>'account')::uuid; v_branch := (v_fx->>'branch')::uuid;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, '__gate_fvm_client_8__') RETURNING id INTO v_client;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, '__gate_fvm_client_8b__') RETURNING id INTO v_client2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_fvm_product_8__', 'FVM-8', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 500);
  v_pv := pg_temp.fvm_fiscal(v_account);
  PERFORM pg_temp.fvm_login(v_user);

  v_res := public.rpc_create_sale_operation(
    'fvm-8-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 333.335, 'quantity', 3, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  v_so := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;

  -- ── (8a) importe desincronizado a mano → P0409 sales_order_out_of_sync y
  -- NINGÚN comprobante nuevo.
  UPDATE public.sales_orders SET total = total + 1 WHERE id = v_so;
  SELECT count(*) INTO v_docs FROM public.fiscal_documents WHERE account_id = v_account;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so, v_pv));
  IF v_try.o_state IS DISTINCT FROM 'P0409' OR position('sales_order_out_of_sync' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(8a) una orden con otro importe que su venta debía dar P0409 sales_order_out_of_sync, dio %s %s', COALESCE(v_try.o_state, 'ningún error — SE FACTURÓ UN IMPORTE QUE NO ES EL DE LA VENTA'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF (SELECT count(*) FROM public.fiscal_documents WHERE account_id = v_account) <> v_docs THEN
    v_failures := v_failures || format('(8a) el rechazo dejó un comprobante creado');
  END IF;

  -- ── (8c) salida del usuario: "Facturar" de nuevo → la promoción en replay
  -- re-sincroniza y la emisión sale por el importe de la venta (1000.01 —
  -- 333.335 × 3 = 1000.005, redondeado a 2 decimales).
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  IF (v_res->>'replayed')::boolean IS DISTINCT FROM true OR (v_res->>'sales_order_id')::uuid IS DISTINCT FROM v_so THEN
    v_failures := v_failures || format('(8c) el replay debía devolver la misma orden con replayed=true, devolvió %s', v_res);
  END IF;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so, v_pv));
  IF v_try.o_state IS NOT NULL THEN
    v_failures := v_failures || format('(8c) después del replay la emisión debía funcionar, dio %s %s', v_try.o_state, COALESCE(v_try.o_msg, ''));
  ELSE
    SELECT fd.* INTO v_fd FROM public.fiscal_documents fd JOIN public.sales_orders so ON so.fiscal_document_id = fd.id WHERE so.id = v_so;
    IF v_fd.total IS DISTINCT FROM 1000.01 THEN
      v_failures := v_failures || format('(8c) el comprobante salió por %s, esperaba 1000.01 (Σ sales.total a 2 decimales)', v_fd.total);
    END IF;
    v_doc := v_fd.id;
  END IF;

  -- ── (11) replay con comprobante VIVO: no se re-sincroniza nada (ni total,
  -- ni líneas, ni fiscal_document_id); y el helper llamado directo rechaza.
  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_so;
  SELECT count(*) INTO v_count FROM public.sales_order_items WHERE sales_order_id = v_so;
  UPDATE public.sales SET total = total + 5 WHERE operation_id = v_op;   -- la venta "cambia" por fuera
  v_res := public.rpc_promote_legacy_sale_to_order(v_op);
  IF (v_res->>'replayed')::boolean IS DISTINCT FROM true THEN
    v_failures := v_failures || format('(11) el replay con comprobante vivo debía devolver replayed=true, devolvió %s', v_res);
  END IF;
  IF (SELECT total FROM public.sales_orders WHERE id = v_so) IS DISTINCT FROM v_order.total
     OR (SELECT fiscal_document_id FROM public.sales_orders WHERE id = v_so) IS DISTINCT FROM v_doc
     OR (SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = v_so) <> v_count THEN
    v_failures := v_failures || format('(11) el replay re-sincronizó una orden con comprobante VIVO (pending_cae): la orden tiene que quedar como se facturó');
  END IF;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public._sales_order_sync_from_operation(%L::uuid, %L::uuid, %L::uuid)', v_so, v_op, v_account));
  IF v_try.o_state IS DISTINCT FROM 'P0409' OR position('sales_order_has_live_invoice' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(11) el helper sobre una orden con comprobante vivo debía dar P0409 sales_order_has_live_invoice, dio %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  -- Con 'authorized' tampoco (allow-list: sólo sin comprobante, rejected, voided).
  UPDATE public.fiscal_documents SET status = 'authorized', cae = '70000000000002', cae_due_date = CURRENT_DATE + 10 WHERE id = v_doc;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public._sales_order_sync_from_operation(%L::uuid, %L::uuid, %L::uuid)', v_so, v_op, v_account));
  IF v_try.o_state IS DISTINCT FROM 'P0409' THEN
    v_failures := v_failures || format('(11) el helper sobre una orden AUTORIZADA debía dar P0409, dio %s', COALESCE(v_try.o_state, 'ningún error'));
  END IF;
  -- Y con una cuenta ajena, P0404 (tenencia en el choke point, ANTES de mirar
  -- el comprobante).
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public._sales_order_sync_from_operation(%L::uuid, %L::uuid, %L::uuid)', v_so, v_op, gen_random_uuid()));
  IF v_try.o_state IS DISTINCT FROM 'P0404' THEN
    v_failures := v_failures || format('(11) el helper con una cuenta ajena debía dar P0404, dio %s', COALESCE(v_try.o_state, 'ningún error'));
  END IF;

  -- ── (8b) TRIANGULATE: receptor desincronizado → P0409; orden confirmada sin
  -- venta vinculada → P0409; orden sana → emite (control positivo).
  v_res := public.rpc_create_sale_operation(
    'fvm-8b-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  v_so := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
  UPDATE public.sales_orders SET client_id = v_client2 WHERE id = v_so;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so, v_pv));
  IF v_try.o_state IS DISTINCT FROM 'P0409' OR position('sales_order_out_of_sync' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(8b) una orden con otro receptor que su venta debía dar P0409 sales_order_out_of_sync, dio %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, NULL, 'confirmed', 100, v_user, NULL) RETURNING id INTO v_so_ok;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so_ok, v_pv));
  IF v_try.o_state IS DISTINCT FROM 'P0409' OR position('sales_order_out_of_sync' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(8b) una orden confirmada SIN venta vinculada debía dar P0409 sales_order_out_of_sync, dio %s %s', COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;

  UPDATE public.sales_orders SET client_id = v_client WHERE id = v_so;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_emit_sale_invoice(%L::uuid, %L::uuid)', v_so, v_pv));
  IF v_try.o_state IS NOT NULL THEN
    v_failures := v_failures || format('(8b) control positivo: una orden SANA debía emitirse, dio %s %s', v_try.o_state, COALESCE(v_try.o_msg, ''));
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (8)/(11) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  PERFORM pg_temp.fvm_cleanup(v_user, v_account);
  RAISE NOTICE 'PASS (8)/(11): la emisión rechaza con P0409 sales_order_out_of_sync una orden con otro importe, otro receptor o sin venta vinculada (sin crear comprobante), y emite una sana; "Facturar" de nuevo re-sincroniza y emite por Σ sales.total a 2 decimales (1000.01); con comprobante vivo el replay no toca la orden y el helper rechaza (P0409 pending/authorized, P0404 cuenta ajena).';
END $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- (12) Tenencia del REPLAY (red team 2026-09-24, D3b). El índice único de
-- sales_orders.sale_operation_id es GLOBAL, y la RLS sales_writer_insert deja
-- que la cuenta B inserte una fila SUYA con el operation_id de A (hace falta
-- conocer el uuid). Desde ahí, la promoción de B:
--   (12a) con la orden de A facturada (pending_cae vivo) devolvía
--         replayed=true con el sales_order_id DE A — el SELECT de idempotencia
--         no filtraba por cuenta y esa rama no revisaba tenencia;
--   (12b) con la orden de A sin comprobante la resincronizaba "como B" y el
--         helper respondía P0404 nombrando el id de la orden de A.
-- Contrato: una orden de OTRA cuenta para esa operación es P0404
-- operation_not_found, sin nombrar nada de la otra cuenta y sin tocar su
-- orden. La fila inyectada se inserta como postgres para no depender de esa
-- RLS (candidato aparte: sacar las escrituras directas sobre sales).
-- ═════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_failures text[] := '{}';
  v_fa       jsonb;
  v_fb       jsonb;
  v_user_a   uuid; v_account_a uuid; v_branch_a uuid;
  v_user_b   uuid; v_account_b uuid; v_branch_b uuid;
  v_product  uuid;
  v_pv       uuid;
  v_res      jsonb;
  v_op       uuid;
  v_op2      uuid;
  v_so       uuid;
  v_so2      uuid;
  v_before   record;
  v_after    record;
  v_try      record;
BEGIN
  v_fa := pg_temp.fvm_anchor('facturar-venta-manual-12a@test.local');
  v_user_a := (v_fa->>'user')::uuid; v_account_a := (v_fa->>'account')::uuid; v_branch_a := (v_fa->>'branch')::uuid;
  v_fb := pg_temp.fvm_anchor('facturar-venta-manual-12b@test.local');
  v_user_b := (v_fb->>'user')::uuid; v_account_b := (v_fb->>'account')::uuid; v_branch_b := (v_fb->>'branch')::uuid;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, '__gate_fvm_product_12__', 'FVM-12', 300, 500) RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_product, v_branch_a, 500);
  v_pv := pg_temp.fvm_fiscal(v_account_a);

  -- A: una venta facturada (pending_cae vivo) y otra promovida sin facturar.
  PERFORM pg_temp.fvm_login(v_user_a);
  v_res := public.rpc_create_sale_operation(
    'fvm-12a-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  v_so := (public.rpc_promote_legacy_sale_to_order(v_op)->>'sales_order_id')::uuid;
  PERFORM public.rpc_emit_sale_invoice(v_so, v_pv);

  v_res := public.rpc_create_sale_operation(
    'fvm-12b-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 250.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL);
  v_op2 := (v_res->>'operation_id')::uuid;
  v_so2 := (public.rpc_promote_legacy_sale_to_order(v_op2)->>'sales_order_id')::uuid;

  -- B inyecta una fila SUYA en cada operación de A.
  INSERT INTO public.sales (user_id, account_id, client_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user_b, v_account_b, NULL, 1, 1, 1, 'ARS', now(), v_op,  v_branch_b),
         (v_user_b, v_account_b, NULL, 1, 1, 1, 'ARS', now(), v_op2, v_branch_b);

  -- ── (12a) orden de A con comprobante VIVO.
  SELECT so.total, so.fiscal_document_id, so.sale_operation_id, so.client_id,
         (SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = so.id) AS n_items
  INTO   v_before FROM public.sales_orders so WHERE so.id = v_so;
  PERFORM pg_temp.fvm_login(v_user_b);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS DISTINCT FROM 'P0404' OR position('operation_not_found' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(12a) la promoción de B sobre una operación con la orden FACTURADA de A debía dar P0404 operation_not_found, dio %s %s — devolvía el sales_order_id de A',
      COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF position(v_so::text in COALESCE(v_try.o_msg, '')) > 0 THEN
    v_failures := v_failures || format('(12a) el error de B nombra la orden de A (%s)', v_so);
  END IF;
  SELECT so.total, so.fiscal_document_id, so.sale_operation_id, so.client_id,
         (SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = so.id) AS n_items
  INTO   v_after FROM public.sales_orders so WHERE so.id = v_so;
  IF v_after IS DISTINCT FROM v_before THEN
    v_failures := v_failures || format('(12a) la promoción de B tocó la orden de A: %s → %s', v_before, v_after);
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE account_id = v_account_b) THEN
    v_failures := v_failures || format('(12a) quedó una orden de B');
  END IF;

  -- ── (12b) TRIANGULATE: orden de A SIN comprobante (la rama que resincroniza).
  SELECT so.total, so.fiscal_document_id, so.sale_operation_id, so.client_id,
         (SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = so.id) AS n_items
  INTO   v_before FROM public.sales_orders so WHERE so.id = v_so2;
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op2));
  IF v_try.o_state IS DISTINCT FROM 'P0404' OR position('operation_not_found' in COALESCE(v_try.o_msg, '')) = 0 THEN
    v_failures := v_failures || format('(12b) la promoción de B sobre una operación con la orden SIN facturar de A debía dar P0404 operation_not_found, dio %s %s',
      COALESCE(v_try.o_state, 'ningún error'), COALESCE(v_try.o_msg, ''));
  END IF;
  IF position(v_so2::text in COALESCE(v_try.o_msg, '')) > 0 THEN
    v_failures := v_failures || format('(12b) el error de B nombra la orden de A (%s)', v_so2);
  END IF;
  SELECT so.total, so.fiscal_document_id, so.sale_operation_id, so.client_id,
         (SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = so.id) AS n_items
  INTO   v_after FROM public.sales_orders so WHERE so.id = v_so2;
  IF v_after IS DISTINCT FROM v_before THEN
    v_failures := v_failures || format('(12b) la promoción de B tocó la orden de A: %s → %s', v_before, v_after);
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_orders WHERE account_id = v_account_b) THEN
    v_failures := v_failures || format('(12b) quedó una orden de B');
  END IF;

  -- ── (12c) control positivo: el replay de A sobre SU orden facturada sigue
  -- devolviéndola (replayed=true) sin tocarla.
  PERFORM pg_temp.fvm_login(v_user_a);
  SELECT * INTO v_try FROM pg_temp.fvm_try(format('SELECT public.rpc_promote_legacy_sale_to_order(%L::uuid)', v_op));
  IF v_try.o_state IS NOT NULL THEN
    v_failures := v_failures || format('(12c) el replay de A sobre su propia orden facturada debía funcionar, dio %s %s', v_try.o_state, COALESCE(v_try.o_msg, ''));
  ELSE
    v_res := public.rpc_promote_legacy_sale_to_order(v_op);
    IF (v_res->>'sales_order_id')::uuid IS DISTINCT FROM v_so OR (v_res->>'replayed')::boolean IS DISTINCT FROM true THEN
      v_failures := v_failures || format('(12c) el replay de A debía devolver SU orden con replayed=true, devolvió %s', v_res);
    END IF;
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE FACTURAR-VENTA-MANUAL (12) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  DELETE FROM public.sales WHERE account_id = v_account_b;
  PERFORM pg_temp.fvm_cleanup(v_user_b, v_account_b);
  PERFORM pg_temp.fvm_cleanup(v_user_a, v_account_a);
  RAISE NOTICE 'PASS (12): con una fila de otra cuenta inyectada en la operación, la promoción de esa cuenta da P0404 operation_not_found sin devolver ni nombrar la orden ajena (facturada o no) y sin tocarla; el replay del dueño sigue devolviendo su orden.';
END $$;
