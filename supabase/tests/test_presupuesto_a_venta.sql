-- =============================================================================
-- test_presupuesto_a_venta.sql — Gate de comportamiento de la TANDA B de
-- `presupuestos-modulo` (migración 20261068000001_presupuestos_conversion_venta.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de verdad.
-- Este archivo ejecuta, contra Postgres real y con usuarios reales (owner y
-- seller y cashier de la cuenta A con membresía en account_members y roles en
-- account_member_roles, más un owner de la cuenta B), la RPC nueva
-- rpc_convert_quote_to_sale, el núcleo _quote_accept_core (a través de las dos
-- RPCs que lo usan) y el wrapper rpc_accept_quote.
--
-- Matriz (tasks.md 6.1 / design.md D6 y D14):
--   (a) feliz cash: stock -, caja, SaleConfirmed, QuoteAccepted, quote
--       accepted, orden confirmed con source_quote_id y sale_operation_id,
--       historial de los dos documentos, resultado {quote_id, quote_number,
--       sales_order_id, operation_id, total, replayed=false};
--   (a') precio y snapshots: el catálogo se remarca, se renombra y cambia el
--       costo DESPUÉS de cotizar -> la venta cobra el precio del presupuesto,
--       sales_order_items conserva los snapshots del presupuesto y
--       sale_items / stock_movements congelan el costo vigente al convertir;
--   (b) credit (ejecutada como `authenticated` por el vendedor, el camino de
--       PostgREST/FastAPI): cargo en cuenta corriente con vencimiento por
--       cascada (plazo del cliente), sin caja;
--   (c) transfer con cuenta bancaria y sucursal elegida (no la default) ->
--       bank_movements y stock de la sucursal elegida; versión vieja antes ->
--       P0409 quote_changed sin efectos;
--   (d) stock insuficiente -> P0409 stock_insuficiente y CERO efectos
--       (conteo tabla por tabla);
--   (e) vencido -> P0409 quote_expired; vencido con producto dado de baja ->
--       quote_expired (estado antes que convertibilidad);
--   (f) producto dado de baja -> P0404 quote_product_unavailable con el nombre;
--   (g) producto que pasó a padre -> P0400 product_is_parent;
--   (h) cliente dado de baja -> P0404 quote_client_unavailable sin cargo;
--   (i) presupuesto ajeno -> P0404 quote_not_found; id inexistente -> igual;
--   (j) caja de otra cuenta -> P0422 (núcleo de venta) y cero efectos;
--   (k) sin payment_method_id -> P0400 payment_method_required; sin clave ->
--       P0400; sin versión -> P0400 quote_revision_required;
--   (l) cash sin sesión -> P0400 cash_requires_session y cero efectos;
--   (m) cashier -> P0403 insufficient_role;
--   (n) replay con la misma clave -> replayed = true, misma venta, sin efectos;
--   (o) la misma clave contra otro presupuesto -> P0409
--       idempotency_key_conflict, el otro intacto;
--   (p) segunda conversión con otra clave -> P0409 quote_invalid_state;
--       ya convertido + producto dado de baja después -> quote_invalid_state
--       (no quote_product_unavailable);
--   (q) línea de servicio: se convierte y la orden conserva la descripción;
--   (r) sucursal de la conversión ajena -> P0404, cerrada -> P0422;
--   (s) regresión rpc_accept_quote (como postgres con claims): misma orden
--       draft, mismas líneas, mismo historial y mismo resultado que antes;
--   (t) SET ROLE authenticated -> rpc_accept_quote rechazada (42501) sin orden
--       nueva; candado de su firma para el chequeo (3) de test_function_acl_gate.
--   (u) introspección (bloque DO aparte, sin fixtures): ACLs, una sola
--       definición, wrapper que delega, orden lock -> idempotencia -> núcleos
--       dentro de rpc_convert_quote_to_sale.
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila de las cuentas del gate (incluidas
-- las sesiones y movimientos de caja, que no tienen account_id) y residuo cero
-- ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run presupuesto a venta gate").
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.pv_as(p_uid uuid) RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.pv_line(p_product uuid, p_qty numeric, p_price numeric, p_subtotal numeric)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', NULL, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal, 'description', NULL);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.pv_service(p_description text, p_qty numeric, p_price numeric, p_subtotal numeric)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', NULL, 'unit_id', NULL, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal, 'description', p_description);
$f$;

-- Alta de un presupuesto (como el usuario de la sesión), opcionalmente enviado.
CREATE OR REPLACE FUNCTION pg_temp.pv_quote(p_client uuid, p_items jsonb, p_send boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  v_id := (public.rpc_create_quote(p_client, NULL, NULL, NULL, p_items)->>'id')::uuid;
  IF p_send THEN
    PERFORM public.rpc_transition_quote(v_id, 'sent', NULL);
  END IF;
  RETURN v_id;
END;
$f$;

-- Conversión: devuelve 'OK|<json>' o 'ERR|<sqlstate>|<mensaje>'. El bloque
-- EXCEPTION revierte la subtransacción, que es exactamente lo que ve el
-- backend: la RPC aborta y no queda nada.
CREATE OR REPLACE FUNCTION pg_temp.pv_convert(p_key text, p_quote uuid, p_rev integer, p_pm uuid,
                                              p_branch uuid DEFAULT NULL, p_session uuid DEFAULT NULL,
                                              p_bank uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v       jsonb;
  v_state text;
  v_msg   text;
BEGIN
  v := public.rpc_convert_quote_to_sale(
         p_idempotency_key   => p_key,
         p_quote_id          => p_quote,
         p_expected_revision => p_rev,
         p_payment_method_id => p_pm,
         p_branch_id         => p_branch,
         p_cash_session_id   => p_session,
         p_bank_account_id   => p_bank,
         p_canal             => NULL);
  RETURN 'OK|' || v::text;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END;
$f$;

-- Huella de efectos de una cuenta: una fila por tabla que una venta toca.
CREATE OR REPLACE FUNCTION pg_temp.pv_effects(p_account uuid)
RETURNS text LANGUAGE sql AS $f$
  SELECT concat_ws(' ',
    'sales_orders=' || (SELECT COUNT(*) FROM public.sales_orders WHERE account_id = p_account),
    'sales_order_items=' || (SELECT COUNT(*) FROM public.sales_order_items WHERE account_id = p_account),
    'sales=' || (SELECT COUNT(*) FROM public.sales WHERE account_id = p_account),
    'sale_items=' || (SELECT COUNT(*) FROM public.sale_items WHERE account_id = p_account),
    'stock_movements=' || (SELECT COUNT(*) FROM public.stock_movements WHERE account_id = p_account),
    'branch_stock=' || (SELECT COALESCE(SUM(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    'cash_movements=' || (SELECT COUNT(*) FROM public.cash_movements cm
                          JOIN public.cash_sessions cs ON cs.id = cm.session_id
                          JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
                          JOIN public.branches b ON b.id = cb.branch_id
                          WHERE b.account_id = p_account),
    'customer_account_movements=' || (SELECT COUNT(*) FROM public.customer_account_movements WHERE account_id = p_account),
    'bank_movements=' || (SELECT COUNT(*) FROM public.bank_movements WHERE account_id = p_account),
    'events=' || (SELECT COUNT(*) FROM public.events WHERE account_id = p_account),
    'history=' || (SELECT COUNT(*) FROM public.document_status_history WHERE account_id = p_account),
    'quotes=' || COALESCE((SELECT string_agg(status || ':' || n, ',' ORDER BY status)
                           FROM (SELECT status, COUNT(*) AS n FROM public.quotes WHERE account_id = p_account GROUP BY status) s), ''));
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';
  v_fail_before   integer;

  v_owner_a       uuid := gen_random_uuid();
  v_owner_b       uuid := gen_random_uuid();
  v_seller        uuid := gen_random_uuid();
  v_cashier       uuid := gen_random_uuid();
  v_users         uuid[];
  v_accounts      uuid[];
  v_account_a     uuid;
  v_account_b     uuid;
  v_member        uuid;
  v_tag           text := 'pv-' || substr(gen_random_uuid()::text, 1, 8) || '-';

  v_branch_a      uuid;
  v_branch_a2     uuid;
  v_branch_closed uuid;
  v_branch_b      uuid;
  v_cashbox_a     uuid;
  v_cashbox_b     uuid;
  v_session_a     uuid;
  v_session_b     uuid;
  v_bank_a        uuid;
  v_pm_cash       uuid;
  v_pm_credit     uuid;
  v_pm_transfer   uuid;

  v_client_a      uuid;
  v_client_gone   uuid;
  v_client_b      uuid;
  v_p1            uuid;
  v_p2            uuid;
  v_p3            uuid;
  v_p_dead        uuid;
  v_p_par         uuid;
  v_p_w           uuid;
  v_product_b     uuid;

  v_q_cash        uuid;
  v_q_credit      uuid;
  v_q_transfer    uuid;
  v_q_stock       uuid;
  v_q_exp         uuid;
  v_q_dead        uuid;
  v_q_par         uuid;
  v_q_gone        uuid;
  v_q_other       uuid;
  v_q_w           uuid;
  v_q_svc         uuid;
  v_q_acc         uuid;
  v_q_branch      uuid;
  v_q_b           uuid;

  v_today         date := public.reporting_local_today();
  v_out           text;
  v_result        jsonb;
  v_items         jsonb;
  v_order         public.sales_orders%ROWTYPE;
  v_order_id      uuid;
  v_op_id         uuid;
  v_before        text;
  v_after         text;
  v_n             bigint;
  v_n2            bigint;
  v_val           numeric;
  v_date          date;
  v_text          text;
  v_state         text;
  v_msg           text;
  v_table         text;
  v_rev           integer;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_seller, v_cashier];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'presupuesto-a-venta-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate PV ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_seller, 'seller'), (v_cashier, 'cashier')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  -- seller / cashier: empleados de A con UNA sola membresía (molde de
  -- test_presupuestos_modulo.sql) para que current_account_ids() sea determinista.
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
  WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id IN (v_seller, v_cashier));
  DELETE FROM public.account_members WHERE user_id IN (v_seller, v_cashier);
  SET session_replication_role = DEFAULT;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'cashier');

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Sucursal Gate PV 2', TRUE, 'active', now(), now() + interval '1 minute')
  RETURNING id INTO v_branch_a2;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (v_account_a, 'Sucursal Gate PV Cerrada', TRUE, 'closed', now(), now(), now() + interval '2 minutes')
  RETURNING id INTO v_branch_closed;
  IF public.c26_default_branch(v_account_a) IS DISTINCT FROM v_branch_a THEN
    RAISE EXCEPTION 'SETUP FAILED: la sucursal por defecto de A no es la provisionada';
  END IF;

  SELECT id INTO v_cashbox_a FROM public.cashboxes WHERE branch_id = v_branch_a ORDER BY created_at LIMIT 1;
  IF v_cashbox_a IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a, 'Caja Gate PV A') RETURNING id INTO v_cashbox_a;
  END IF;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id = v_branch_b ORDER BY created_at LIMIT 1;
  IF v_cashbox_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_b, 'Caja Gate PV B') RETURNING id INTO v_cashbox_b;
  END IF;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a, 'open', 0, v_owner_a) RETURNING id INTO v_session_a;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_owner_b) RETURNING id INTO v_session_b;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, 'Banco Gate PV', 'ARS', 0) RETURNING id INTO v_bank_a;

  SELECT id INTO v_pm_cash FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'credit' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_credit IS NULL OR v_pm_transfer IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta A no tiene sembradas las formas de pago cash/credit/transfer';
  END IF;

  INSERT INTO public.clients (user_id, account_id, name, phone, payment_terms_days)
  VALUES (v_owner_a, v_account_a, 'Cliente Gate PV', '2615550303', 30) RETURNING id INTO v_client_a;
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_owner_a, v_account_a, 'Cliente Gate PV Se Va') RETURNING id INTO v_client_gone;
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_owner_b, v_account_b, 'Cliente Gate PV B') RETURNING id INTO v_client_b;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Producto 1', 'GPV-P1', 500, 1000) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Producto 2', 'GPV-P2', 40, 100) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Producto 3', 'GPV-P3', 150, 300) RETURNING id INTO v_p3;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Se Discontinua', 'GPV-DEAD', 10, 20) RETURNING id INTO v_p_dead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Pasa a Padre', 'GPV-PAR', 10, 20) RETURNING id INTO v_p_par;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate PV Ultima Unidad', 'GPV-W', 10, 20) RETURNING id INTO v_p_w;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'Gate PV Producto B', 'GPV-B', 10, 20) RETURNING id INTO v_product_b;

  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 6);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_a, 3);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p3, v_branch_a2, 4);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p_w, v_branch_a, 1);
  PERFORM public.c21_apply_branch_stock_delta(v_account_b, v_product_b, v_branch_b, 5);

  -- Presupuestos (todos creados ANTES de las bajas de catálogo y de cliente).
  PERFORM pg_temp.pv_as(v_owner_a);
  v_q_cash     := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p1, 2, 1000, 2000)));
  v_q_credit   := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p2, 1, 100, 100)));
  v_q_transfer := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p3, 1, 300, 300)), false);
  v_q_stock    := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p2, 10, 100, 1000)));
  v_q_exp      := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p_dead, 1, 20, 20)));
  v_q_dead     := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p_dead, 1, 20, 20)));
  v_q_par      := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p_par, 1, 20, 20)));
  v_q_gone     := pg_temp.pv_quote(v_client_gone, jsonb_build_array(pg_temp.pv_line(v_p1, 1, 1000, 1000)));
  v_q_other    := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p1, 1, 1000, 1000)));
  v_q_w        := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p_w, 1, 20, 20)));
  v_q_svc      := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p2, 1, 100, 100),
                                                                 pg_temp.pv_service('Instalación', 1, 500, 500)));
  v_q_acc      := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p1, 1, 950, 950),
                                                                 pg_temp.pv_service('Flete', 1, 80, 80)));
  v_q_branch   := pg_temp.pv_quote(v_client_a, jsonb_build_array(pg_temp.pv_line(v_p1, 1, 1000, 1000)));
  PERFORM pg_temp.pv_as(v_owner_b);
  v_q_b        := pg_temp.pv_quote(v_client_b, jsonb_build_array(pg_temp.pv_line(v_product_b, 1, 20, 20)));
  PERFORM pg_temp.pv_as(v_owner_a);

  -- El catálogo cambia DESPUÉS de cotizar (a'): precio, costo y nombre.
  UPDATE public.products SET price = 1200, cost = 600, name = 'Gate PV Producto 1 (renombrado)' WHERE id = v_p1;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) + (a') Feliz en efectivo, precio del presupuesto y snapshots
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_out := pg_temp.pv_convert(v_tag || 'cash', v_q_cash, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (a): la conversión en efectivo falló: %s', v_out);
  ELSE
    v_result   := substr(v_out, 4)::jsonb;
    v_order_id := (v_result->>'sales_order_id')::uuid;
    v_op_id    := (v_result->>'operation_id')::uuid;
    SELECT * INTO v_order FROM public.sales_orders WHERE id = v_order_id;
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_result) k)
       IS DISTINCT FROM ARRAY['operation_id', 'quote_id', 'quote_number', 'replayed', 'sales_order_id', 'total'] THEN
      v_failures := v_failures || format('FAIL (a): claves del resultado inesperadas: %s', v_result);
    END IF;
    IF (v_result->>'replayed')::boolean IS DISTINCT FROM false
       OR (v_result->>'quote_id')::uuid IS DISTINCT FROM v_q_cash
       OR (v_result->>'quote_number')::bigint IS DISTINCT FROM (SELECT number FROM public.quotes WHERE id = v_q_cash)
       OR (v_result->>'total')::numeric IS DISTINCT FROM 2000 THEN
      v_failures := v_failures || format('FAIL (a): resultado %s', v_result);
    END IF;
    IF (SELECT status FROM public.quotes WHERE id = v_q_cash) IS DISTINCT FROM 'accepted' THEN
      v_failures := v_failures || 'FAIL (a): el presupuesto no quedó accepted'::text;
    END IF;
    IF v_order.status IS DISTINCT FROM 'confirmed' OR v_order.source_quote_id IS DISTINCT FROM v_q_cash
       OR v_order.sale_operation_id IS DISTINCT FROM v_op_id OR v_order.branch_id IS DISTINCT FROM v_branch_a
       OR v_order.payment_method_id IS DISTINCT FROM v_pm_cash OR v_order.total IS DISTINCT FROM 2000
       OR v_order.client_id IS DISTINCT FROM v_client_a THEN
      v_failures := v_failures || format('FAIL (a): orden %s / %s / op %s / sucursal %s / pm %s / total %s',
        v_order.status, v_order.source_quote_id, v_order.sale_operation_id, v_order.branch_id, v_order.payment_method_id, v_order.total);
    END IF;
    IF (SELECT quantity FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a) IS DISTINCT FROM 4 THEN
      v_failures := v_failures || 'FAIL (a): el stock de la sucursal no bajó de 6 a 4'::text;
    END IF;
    SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_n, v_val FROM public.cash_movements
    WHERE session_id = v_session_a AND reference_id = v_order_id AND movement_type = 'sale';
    IF v_n <> 1 OR v_val <> 2000 THEN
      v_failures := v_failures || format('FAIL (a): caja %s movimientos por %s (se esperaba 1 por 2000)', v_n, v_val);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleConfirmed' AND aggregate_id = v_order_id
                     AND payload->>'payment_method' = 'cash' AND (payload->>'operation_id')::uuid = v_op_id)
       OR NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'QuoteAccepted' AND aggregate_id = v_q_cash) THEN
      v_failures := v_failures || 'FAIL (a): faltan SaleConfirmed y/o QuoteAccepted'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'quote' AND document_id = v_q_cash
                     AND from_status = 'sent' AND to_status = 'accepted' AND performed_by = v_owner_a)
       OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'sales_order' AND document_id = v_order_id
                        AND from_status IS NULL AND to_status = 'draft')
       OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'sales_order' AND document_id = v_order_id
                        AND from_status = 'draft' AND to_status = 'confirmed') THEN
      v_failures := v_failures || 'FAIL (a): falta historial del presupuesto (sent->accepted) o de la orden (NULL->draft, draft->confirmed)'::text;
    END IF;
    -- (a') precio del presupuesto y snapshots
    IF NOT EXISTS (SELECT 1 FROM public.sales_order_items WHERE sales_order_id = v_order_id
                     AND product_id = v_p1 AND quantity = 2 AND price = 1000 AND subtotal = 2000
                     AND name_snapshot = 'Gate PV Producto 1' AND sku_snapshot = 'GPV-P1' AND unit_cost_snapshot = 500) THEN
      v_failures := v_failures || 'FAIL (a''): sales_order_items no conserva precio y snapshots del presupuesto'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales s JOIN public.sale_items si ON si.sale_id = s.id
                   WHERE s.operation_id = v_op_id AND s.product_id = v_p1 AND s.amount = 1000 AND s.total = 2000
                     AND si.price = 1000 AND si.unit_cost_snapshot = 600
                     AND si.name_snapshot = 'Gate PV Producto 1 (renombrado)') THEN
      v_failures := v_failures || 'FAIL (a''): sales/sale_items no cobran el precio del presupuesto con el costo vigente'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE operation_group_id = v_op_id AND product_id = v_p1
                     AND quantity_delta = -2 AND unit_cost_snapshot = 600 AND branch_id = v_branch_a) THEN
      v_failures := v_failures || 'FAIL (a''): stock_movements no congeló el costo vigente al convertir'::text;
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (a): conversión en efectivo — presupuesto accepted, orden confirmed con source_quote_id, stock -2, caja, SaleConfirmed + QuoteAccepted, historial de los dos documentos; precio del presupuesto con el catálogo remarcado y costo del día en la venta.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (n) Replay con la misma clave
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.pv_effects(v_account_a);
  v_out := pg_temp.pv_convert(v_tag || 'cash', v_q_cash, 1, v_pm_cash, NULL, v_session_a, NULL);
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_out NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (n): el replay falló: %s', v_out);
  ELSE
    v_result := substr(v_out, 4)::jsonb;
    IF (v_result->>'replayed')::boolean IS DISTINCT FROM true
       OR (v_result->>'sales_order_id')::uuid IS DISTINCT FROM v_order_id
       OR (v_result->>'operation_id')::uuid IS DISTINCT FROM v_op_id
       OR (v_result->>'total')::numeric IS DISTINCT FROM 2000 THEN
      v_failures := v_failures || format('FAIL (n): el replay devolvió %s', v_result);
    END IF;
  END IF;
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (n): el replay escribió: %s -> %s', v_before, v_after);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (n): la misma clave sobre el mismo presupuesto devuelve la venta original con replayed = true y no escribe nada.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (o) Clave reutilizada contra otro presupuesto · (p) segunda conversión
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.pv_effects(v_account_a);
  v_out := pg_temp.pv_convert(v_tag || 'cash', v_q_other, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0409|idempotency_key_conflict%' THEN
    v_failures := v_failures || format('FAIL (o): clave de otro presupuesto: se esperaba P0409 idempotency_key_conflict, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'cash-2', v_q_cash, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0409|quote_invalid_state%' THEN
    v_failures := v_failures || format('FAIL (p): segunda conversión: se esperaba P0409 quote_invalid_state, vino %s', v_out);
  END IF;
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (o/p): quedaron efectos: %s -> %s', v_before, v_after);
  END IF;
  IF (SELECT status FROM public.quotes WHERE id = v_q_other) IS DISTINCT FROM 'sent' THEN
    v_failures := v_failures || 'FAIL (o): el otro presupuesto cambió de estado'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (o/p): una clave usada contra otro presupuesto -> P0409 idempotency_key_conflict (el otro intacto); una segunda conversión con otra clave -> P0409 quote_invalid_state; cero efectos.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) Crédito, ejecutada como `authenticated` por el vendedor
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.pv_as(v_seller);
  SELECT COUNT(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_a;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_result := public.rpc_convert_quote_to_sale(v_tag || 'credit', v_q_credit, 1, v_pm_credit, NULL, NULL, NULL, NULL);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    EXECUTE 'RESET ROLE';
    v_result := NULL;
    v_failures := v_failures || format('FAIL (b): la conversión a crédito como authenticated falló: %s / %s', v_state, v_msg);
  END;
  IF v_result IS NOT NULL THEN
    v_order_id := (v_result->>'sales_order_id')::uuid;
    SELECT COUNT(*), MAX(cam.amount), MAX(cam.due_date) INTO v_n2, v_val, v_date
    FROM public.customer_account_movements cam
    JOIN public.customer_accounts ca ON ca.id = cam.customer_account_id
    WHERE ca.client_id = v_client_a AND cam.reference_id = v_order_id;
    IF v_n2 <> 1 OR v_val IS DISTINCT FROM 100 OR v_date IS DISTINCT FROM v_today + 30 THEN
      v_failures := v_failures || format('FAIL (b): cargo en cuenta corriente %s por %s vence %s (se esperaba 1 por 100 al %s)', v_n2, v_val, v_date, v_today + 30);
    END IF;
    IF (SELECT COUNT(*) FROM public.cash_movements WHERE session_id = v_session_a) <> v_n
       OR EXISTS (SELECT 1 FROM public.cash_movements WHERE reference_id = v_order_id) THEN
      v_failures := v_failures || 'FAIL (b): la conversión a crédito movió la caja'::text;
    END IF;
    IF (SELECT status FROM public.quotes WHERE id = v_q_credit) IS DISTINCT FROM 'accepted'
       OR (SELECT status FROM public.sales_orders WHERE id = v_order_id) IS DISTINCT FROM 'confirmed'
       OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'quote'
                        AND document_id = v_q_credit AND to_status = 'accepted' AND performed_by = v_seller) THEN
      v_failures := v_failures || 'FAIL (b): estados o historial (actor vendedor) de la conversión a crédito'::text;
    END IF;
  END IF;
  PERFORM pg_temp.pv_as(v_owner_a);
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (b): conversión a crédito por el vendedor como authenticated — cargo de 100 en la cuenta corriente con vencimiento hoy + 30 (plazo del cliente), sin caja.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) Versión vieja -> quote_changed; luego transferencia con sucursal elegida
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_items := jsonb_build_array(pg_temp.pv_line(v_p3, 2, 300, 600));
  PERFORM public.rpc_update_quote(v_q_transfer, 1, v_client_a, NULL, v_today + 10, 'Editado después de abrir el diálogo', v_items);
  SELECT revision INTO v_rev FROM public.quotes WHERE id = v_q_transfer;
  v_before := pg_temp.pv_effects(v_account_a);
  v_out := pg_temp.pv_convert(v_tag || 'transfer-old', v_q_transfer, 1, v_pm_transfer, v_branch_a2, NULL, v_bank_a);
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_out NOT LIKE 'ERR|P0409|quote_changed%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (c): versión vieja: se esperaba P0409 quote_changed sin efectos, vino %s (%s -> %s)', v_out, v_before, v_after);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'transfer', v_q_transfer, v_rev, v_pm_transfer, v_branch_a2, NULL, v_bank_a);
  IF v_out NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (c): la transferencia con la versión vigente falló: %s', v_out);
  ELSE
    v_result   := substr(v_out, 4)::jsonb;
    v_order_id := (v_result->>'sales_order_id')::uuid;
    IF (v_result->>'total')::numeric IS DISTINCT FROM 600
       OR (SELECT branch_id FROM public.sales_orders WHERE id = v_order_id) IS DISTINCT FROM v_branch_a2 THEN
      v_failures := v_failures || format('FAIL (c): total o sucursal de la orden: %s', v_result);
    END IF;
    SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_n, v_val FROM public.bank_movements
    WHERE bank_account_id = v_bank_a AND source_doc_ref = v_order_id;
    IF v_n <> 1 OR v_val <> 600 THEN
      v_failures := v_failures || format('FAIL (c): banco %s movimientos por %s (se esperaba 1 por 600)', v_n, v_val);
    END IF;
    IF (SELECT quantity FROM public.branch_stock WHERE product_id = v_p3 AND branch_id = v_branch_a2) IS DISTINCT FROM 2 THEN
      v_failures := v_failures || 'FAIL (c): el stock de la sucursal elegida no bajó de 4 a 2'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.cash_movements WHERE reference_id = v_order_id) THEN
      v_failures := v_failures || 'FAIL (c): la transferencia movió la caja'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'quote'
                     AND document_id = v_q_transfer AND from_status = 'draft' AND to_status = 'accepted') THEN
      v_failures := v_failures || 'FAIL (c): falta el historial draft -> accepted'::text;
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (c): una versión vieja -> P0409 quote_changed sin efectos; con la vigente, transferencia desde draft con sucursal elegida (no la default): banco por 600 y stock de esa sucursal.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (d) Stock insuficiente: P0409 y CERO efectos
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.pv_effects(v_account_a);
  v_out := pg_temp.pv_convert(v_tag || 'stock', v_q_stock, 1, v_pm_cash, NULL, v_session_a, NULL);
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_out NOT LIKE 'ERR|P0409|stock_insuficiente para producto ' || v_p2 || '%' THEN
    v_failures := v_failures || format('FAIL (d): se esperaba P0409 stock_insuficiente del producto 2, vino %s', v_out);
  END IF;
  IF v_before IS DISTINCT FROM v_after OR (SELECT status FROM public.quotes WHERE id = v_q_stock) IS DISTINCT FROM 'sent'
     OR EXISTS (SELECT 1 FROM public.sales_orders WHERE source_quote_id = v_q_stock) THEN
    v_failures := v_failures || format('FAIL (d): quedaron efectos: %s -> %s', v_before, v_after);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (d): stock insuficiente -> P0409 stock_insuficiente y cero efectos (órdenes, líneas, ventas, stock, caja, cuenta corriente, banco, eventos, historial y estado).';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (f) producto dado de baja · (g) pasó a padre · (h) cliente dado de baja
  -- (e) vencido (con un producto dado de baja: el vencimiento manda)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  UPDATE public.products SET deleted_at = now() WHERE id = v_p_dead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_owner_a, v_account_a, 'Gate PV Variante Nueva', 'GPV-PAR-V1', 10, 20, v_p_par, true);
  UPDATE public.clients SET deleted_at = now() WHERE id = v_client_gone;
  UPDATE public.quotes SET valid_until = v_today - 1 WHERE id = v_q_exp;

  v_before := pg_temp.pv_effects(v_account_a);
  v_out := pg_temp.pv_convert(v_tag || 'dead', v_q_dead, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0404|quote_product_unavailable%Gate PV Se Discontinua%' THEN
    v_failures := v_failures || format('FAIL (f): producto dado de baja: se esperaba P0404 quote_product_unavailable con el nombre, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'par', v_q_par, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0400|product_is_parent%' THEN
    v_failures := v_failures || format('FAIL (g): producto que pasó a padre: se esperaba P0400 product_is_parent, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'gone', v_q_gone, 1, v_pm_credit, NULL, NULL, NULL);
  IF v_out NOT LIKE 'ERR|P0404|quote_client_unavailable%' THEN
    v_failures := v_failures || format('FAIL (h): cliente dado de baja: se esperaba P0404 quote_client_unavailable, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'exp', v_q_exp, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0409|quote_expired%' THEN
    v_failures := v_failures || format('FAIL (e): vencido con producto dado de baja: se esperaba P0409 quote_expired, vino %s', v_out);
  END IF;
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (e-h): quedaron efectos: %s -> %s', v_before, v_after);
  END IF;
  IF EXISTS (SELECT 1 FROM public.customer_account_movements cam JOIN public.customer_accounts ca ON ca.id = cam.customer_account_id
             WHERE ca.client_id = v_client_gone) THEN
    v_failures := v_failures || 'FAIL (h): se posteó un cargo contra el cliente dado de baja'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (e-h): producto dado de baja -> P0404 quote_product_unavailable con el nombre; pasó a padre -> P0400 product_is_parent; cliente dado de baja -> P0404 quote_client_unavailable sin cargo; vencido (aunque tenga un producto dado de baja) -> P0409 quote_expired; cero efectos.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (i) ajeno / inexistente · (j) caja de otra cuenta · (k) parámetros
  -- (l) cash sin sesión · (m) cajero · (r) sucursal ajena / cerrada
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.pv_effects(v_account_a);
  v_text := pg_temp.pv_effects(v_account_b);
  v_out := pg_temp.pv_convert(v_tag || 'ajeno', v_q_b, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0404|quote_not_found%' THEN
    v_failures := v_failures || format('FAIL (i): presupuesto ajeno: se esperaba P0404 quote_not_found, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'inexistente', gen_random_uuid(), 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0404|quote_not_found%' THEN
    v_failures := v_failures || format('FAIL (i): presupuesto inexistente: se esperaba P0404 quote_not_found, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'caja-b', v_q_other, 1, v_pm_cash, NULL, v_session_b, NULL);
  IF v_out NOT LIKE 'ERR|P0422|%' THEN
    v_failures := v_failures || format('FAIL (j): caja de otra cuenta: se esperaba P0422, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'sin-pm', v_q_other, 1, NULL, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0400|payment_method_required%' THEN
    v_failures := v_failures || format('FAIL (k): sin forma de pago: se esperaba P0400 payment_method_required, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert('   ', v_q_other, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0400|%' THEN
    v_failures := v_failures || format('FAIL (k): clave vacía: se esperaba P0400, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'sin-rev', v_q_other, NULL, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0400|quote_revision_required%' THEN
    v_failures := v_failures || format('FAIL (k): sin versión: se esperaba P0400 quote_revision_required, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'sin-sesion', v_q_other, 1, v_pm_cash, NULL, NULL, NULL);
  IF v_out NOT LIKE 'ERR|P0400|cash_requires_session%' THEN
    v_failures := v_failures || format('FAIL (l): efectivo sin sesión: se esperaba P0400 cash_requires_session, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'suc-b', v_q_branch, 1, v_pm_credit, v_branch_b, NULL, NULL);
  IF v_out NOT LIKE 'ERR|P0404|branch_not_found%' THEN
    v_failures := v_failures || format('FAIL (r): sucursal de otra cuenta: se esperaba P0404 branch_not_found, vino %s', v_out);
  END IF;
  v_out := pg_temp.pv_convert(v_tag || 'suc-cerrada', v_q_branch, 1, v_pm_credit, v_branch_closed, NULL, NULL);
  IF v_out NOT LIKE 'ERR|P0422|branch_closed%' THEN
    v_failures := v_failures || format('FAIL (r): sucursal cerrada: se esperaba P0422 branch_closed, vino %s', v_out);
  END IF;
  PERFORM pg_temp.pv_as(v_cashier);
  v_out := pg_temp.pv_convert(v_tag || 'cajero', v_q_other, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'ERR|P0403|insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (m): cajero: se esperaba P0403 insufficient_role, vino %s', v_out);
  END IF;
  PERFORM pg_temp.pv_as(v_owner_a);
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after OR v_text IS DISTINCT FROM pg_temp.pv_effects(v_account_b) THEN
    v_failures := v_failures || format('FAIL (i-m): quedaron efectos: %s -> %s', v_before, v_after);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (i-m, r): ajeno e inexistente -> P0404 quote_not_found; caja de otra cuenta -> P0422; sin forma de pago / clave / versión -> P0400; efectivo sin sesión -> P0400 cash_requires_session; sucursal ajena -> P0404, cerrada -> P0422; cajero -> P0403; cero efectos en A y en B.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (p') ya convertido + producto dado de baja después -> quote_invalid_state
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_out := pg_temp.pv_convert(v_tag || 'w', v_q_w, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (p''): la conversión de la última unidad falló: %s', v_out);
  ELSE
    -- Sin stock y con el presupuesto accepted, el guard de baja lo permite.
    UPDATE public.products SET deleted_at = now() WHERE id = v_p_w;
    v_out := pg_temp.pv_convert(v_tag || 'w-2', v_q_w, 1, v_pm_cash, NULL, v_session_a, NULL);
    IF v_out NOT LIKE 'ERR|P0409|quote_invalid_state%' THEN
      v_failures := v_failures || format('FAIL (p''): ya convertido con producto dado de baja: se esperaba P0409 quote_invalid_state, vino %s', v_out);
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (p''): un presupuesto ya convertido cuyo producto se dio de baja después responde por su estado (quote_invalid_state), no por el producto.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (q) Línea de servicio
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_out := pg_temp.pv_convert(v_tag || 'svc', v_q_svc, 1, v_pm_cash, NULL, v_session_a, NULL);
  IF v_out NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (q): la conversión con línea de servicio falló: %s', v_out);
  ELSE
    v_result   := substr(v_out, 4)::jsonb;
    v_order_id := (v_result->>'sales_order_id')::uuid;
    v_op_id    := (v_result->>'operation_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.sales_order_items WHERE sales_order_id = v_order_id AND product_id IS NULL
                     AND name_snapshot = 'Instalación' AND price = 500 AND subtotal = 500)
       OR NOT EXISTS (SELECT 1 FROM public.sales WHERE operation_id = v_op_id AND product_id IS NULL AND total = 500)
       OR (v_result->>'total')::numeric IS DISTINCT FROM 600 THEN
      v_failures := v_failures || format('FAIL (q): la línea de servicio no llegó a la venta con su descripción: %s', v_result);
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_val FROM public.cash_movements WHERE reference_id = v_order_id;
    IF v_val <> 600 THEN
      v_failures := v_failures || format('FAIL (q): la caja registró %s, se esperaba 600', v_val);
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (q): un presupuesto con una línea de servicio se convierte; la orden conserva "Instalación" en name_snapshot y la caja cobra el total.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (t) rpc_accept_quote por la API de datos -> 42501 · candado de firma
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF to_regprocedure('public.rpc_accept_quote(uuid)') IS NULL THEN
    v_failures := v_failures || 'FAIL (t): no existe public.rpc_accept_quote(uuid) (el chequeo (3) del gate de ACLs la nombra)'::text;
  END IF;
  v_before := pg_temp.pv_effects(v_account_a);
  v_state := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.rpc_accept_quote(v_q_other);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    EXECUTE 'RESET ROLE';
  END;
  v_after := pg_temp.pv_effects(v_account_a);
  IF v_state IS DISTINCT FROM '42501' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (t): rpc_accept_quote como authenticated: se esperaba 42501 sin efectos, vino %s (%s -> %s)', v_state, v_before, v_after);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (t): rpc_accept_quote(uuid) existe con esa firma y la API de datos la rechaza por permisos (42501) sin orden nueva.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (s) Regresión de rpc_accept_quote (postgres con claims)
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT COUNT(*) INTO v_n FROM public.events WHERE account_id = v_account_a AND event_type = 'SaleConfirmed';
  SELECT COALESCE(SUM(quantity), 0) INTO v_val FROM public.branch_stock WHERE account_id = v_account_a;
  v_result := public.rpc_accept_quote(v_q_acc);
  v_order_id := (v_result->>'sales_order_id')::uuid;
  SELECT * INTO v_order FROM public.sales_orders WHERE id = v_order_id;
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_result) k) IS DISTINCT FROM ARRAY['quote_id', 'sales_order_id', 'status']
     OR v_result->>'status' IS DISTINCT FROM 'accepted' OR (v_result->>'quote_id')::uuid IS DISTINCT FROM v_q_acc THEN
    v_failures := v_failures || format('FAIL (s): resultado de rpc_accept_quote: %s', v_result);
  END IF;
  IF v_order.status IS DISTINCT FROM 'draft' OR v_order.source_quote_id IS DISTINCT FROM v_q_acc
     OR v_order.branch_id IS DISTINCT FROM v_branch_a OR v_order.client_id IS DISTINCT FROM v_client_a
     OR v_order.total IS DISTINCT FROM 1030 OR v_order.created_by IS DISTINCT FROM v_owner_a
     OR v_order.payment_method_id IS NOT NULL OR v_order.sale_operation_id IS NOT NULL OR v_order.fiscal_document_id IS NOT NULL THEN
    v_failures := v_failures || format('FAIL (s): la orden draft cambió: %s', row_to_json(v_order));
  END IF;
  SELECT COUNT(*) INTO v_n2 FROM (
    (SELECT product_id, unit_id, quantity, price, subtotal, name_snapshot, sku_snapshot, unit_cost_snapshot,
            iva_rate_snapshot, snapshot_backfilled FROM public.quote_items WHERE quote_id = v_q_acc
     EXCEPT ALL
     SELECT product_id, unit_id, quantity, price, subtotal, name_snapshot, sku_snapshot, unit_cost_snapshot,
            iva_rate_snapshot, snapshot_backfilled FROM public.sales_order_items WHERE sales_order_id = v_order_id)
    UNION ALL
    (SELECT product_id, unit_id, quantity, price, subtotal, name_snapshot, sku_snapshot, unit_cost_snapshot,
            iva_rate_snapshot, snapshot_backfilled FROM public.sales_order_items WHERE sales_order_id = v_order_id
     EXCEPT ALL
     SELECT product_id, unit_id, quantity, price, subtotal, name_snapshot, sku_snapshot, unit_cost_snapshot,
            iva_rate_snapshot, snapshot_backfilled FROM public.quote_items WHERE quote_id = v_q_acc)) d;
  IF v_n2 <> 0 OR (SELECT COUNT(*) FROM public.sales_order_items WHERE sales_order_id = v_order_id) <> 2 THEN
    v_failures := v_failures || 'FAIL (s): las líneas de la orden no son copia exacta de las del presupuesto'::text;
  END IF;
  IF (SELECT status FROM public.quotes WHERE id = v_q_acc) IS DISTINCT FROM 'accepted'
     OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'quote' AND document_id = v_q_acc
                      AND from_status = 'sent' AND to_status = 'accepted' AND performed_by = v_owner_a)
     OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'sales_order' AND document_id = v_order_id
                      AND from_status IS NULL AND to_status = 'draft' AND performed_by = v_owner_a)
     OR EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'sales_order' AND document_id = v_order_id
                  AND to_status = 'confirmed') THEN
    v_failures := v_failures || 'FAIL (s): estado o historial de rpc_accept_quote'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'QuoteAccepted' AND aggregate_id = v_q_acc
                   AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload) k) = ARRAY['branch_id', 'quote_id', 'seller_id', 'total']
                   AND (payload->>'total')::numeric = 1030 AND (payload->>'branch_id')::uuid = v_branch_a
                   AND (payload->>'seller_id')::uuid = v_owner_a)
     OR (SELECT COUNT(*) FROM public.events WHERE account_id = v_account_a AND event_type = 'SaleConfirmed') <> v_n
     OR (SELECT COALESCE(SUM(quantity), 0) FROM public.branch_stock WHERE account_id = v_account_a) <> v_val THEN
    v_failures := v_failures || 'FAIL (s): rpc_accept_quote cambió el evento QuoteAccepted, confirmó la venta o tocó stock'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (s): rpc_accept_quote conserva su contrato — {sales_order_id, quote_id, status}, orden draft con source_quote_id, sucursal por defecto, líneas copia exacta (con servicio), historial NULL->draft y sent->accepted, QuoteAccepted con el mismo payload, sin stock ni SaleConfirmed.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.pv_as(NULL);
  SET session_replication_role = replica;
  DELETE FROM public.cash_movements WHERE session_id IN (
    SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
  DELETE FROM public.cash_sessions WHERE cashbox_id IN (
    SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
  END LOOP;
  DELETE FROM public.accounts              WHERE id = ANY (v_accounts);
  DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
  DELETE FROM public.profiles              WHERE id = ANY (v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
  DELETE FROM auth.users                   WHERE id = ANY (v_users);
  SET session_replication_role = DEFAULT;

  IF EXISTS (SELECT 1 FROM public.quotes WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.sales_orders WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.sales WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.events WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.cash_sessions WHERE id IN (v_session_a, v_session_b))
     OR EXISTS (SELECT 1 FROM public.cashboxes WHERE id IN (v_cashbox_a, v_cashbox_b))
     OR EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = ANY (v_users))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE PRESUPUESTO-A-VENTA FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE PRESUPUESTO-A-VENTA PASSED: conversión cash/credit/transfer, precio y snapshots, rollback total, guards, idempotencia, línea de servicio y regresión de rpc_accept_quote — residuo cero.';

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      EXECUTE 'RESET ROLE';
      SET session_replication_role = replica;
      IF v_accounts IS NOT NULL THEN
        DELETE FROM public.cash_movements WHERE session_id IN (
          SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
          JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
        DELETE FROM public.cash_sessions WHERE cashbox_id IN (
          SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
        DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
        FOR v_table IN
          SELECT c.table_name
          FROM   information_schema.columns c
          JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
          WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
            AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
        LOOP
          EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
        END LOOP;
        DELETE FROM public.accounts WHERE id = ANY (v_accounts);
      END IF;
      DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
      DELETE FROM public.profiles              WHERE id = ANY (v_users);
      DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
      DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
      DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
      DELETE FROM auth.users                   WHERE id = ANY (v_users);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE EXCEPTION 'GATE PRESUPUESTO-A-VENTA FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (u) Introspección: ACLs, una sola definición y forma de los cuerpos ─────
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_def  text;
  v_fn   text;
  v_n    integer;
  v_lock integer;
  v_idem integer;
  v_core integer;
  v_conf integer;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['_quote_accept_core', 'rpc_accept_quote', 'rpc_convert_quote_to_sale'] LOOP
    SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN v_bad := v_bad || format('%s tiene %s definiciones', v_fn, v_n); END IF;
  END LOOP;

  IF to_regprocedure('public._quote_accept_core(uuid, uuid)') IS NULL
     OR to_regprocedure('public.rpc_accept_quote(uuid)') IS NULL
     OR to_regprocedure('public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text)') IS NULL THEN
    v_bad := v_bad || 'falta alguna de las firmas _quote_accept_core(uuid, uuid) / rpc_accept_quote(uuid) / rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text)'::text;
  ELSE
    FOREACH v_fn IN ARRAY ARRAY['public._quote_accept_core(uuid, uuid)', 'public.rpc_accept_quote(uuid)'] LOOP
      IF has_function_privilege('authenticated', v_fn, 'EXECUTE') OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
        v_bad := v_bad || format('%s es ejecutable por un rol de aplicación', v_fn);
      END IF;
    END LOOP;
    v_fn := 'public.rpc_convert_quote_to_sale(text, uuid, integer, uuid, uuid, uuid, uuid, text)';
    IF has_function_privilege('anon', v_fn, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || 'ACL de rpc_convert_quote_to_sale (sin anon, con authenticated)'::text;
    END IF;
    IF NOT (SELECT bool_and(prosecdef) FROM pg_proc WHERE oid IN (
              to_regprocedure('public._quote_accept_core(uuid, uuid)'),
              to_regprocedure('public.rpc_accept_quote(uuid)'),
              to_regprocedure(v_fn))) THEN
      v_bad := v_bad || 'alguna de las tres funciones no es SECURITY DEFINER'::text;
    END IF;

    -- El wrapper delega en el núcleo y no escribe nada por sí mismo.
    v_def := pg_get_functiondef('public.rpc_accept_quote(uuid)'::regprocedure);
    IF position('_quote_accept_core(' in v_def) = 0 OR v_def ~* 'INSERT\s+INTO|UPDATE\s+public' THEN
      v_bad := v_bad || 'rpc_accept_quote no es un wrapper del núcleo'::text;
    END IF;
    IF obj_description('public.rpc_accept_quote(uuid)'::regprocedure, 'pg_proc') IS DISTINCT FROM
       'C-29 (D3) + v3-snapshot-pattern + v3-document-status-history + v3-notifications-realtime: acepta un Quote (draft|sent + no expirado) y crea un SalesOrder en draft con los mismos ítems, propagando los snapshots congelados. Registra en document_status_history la creación de la SalesOrder (RN-A2) y la transición del quote a accepted (RN-A1). Emite QuoteAccepted al outbox (5.3; seller_id=created_by como proxy). No toca stock ni caja — eso es SalesOrder.confirm(). Atómico.' THEN
      v_bad := v_bad || 'rpc_accept_quote perdió su COMMENT vivo'::text;
    END IF;

    -- El núcleo bloquea el presupuesto y conserva el guard de cliente antes de escribir.
    v_def := pg_get_functiondef('public._quote_accept_core(uuid, uuid)'::regprocedure);
    IF v_def !~* 'FROM\s+public\.quotes\s+WHERE\s+id\s*=\s*p_quote_id\s+FOR\s+UPDATE' THEN
      v_bad := v_bad || '_quote_accept_core no toma FOR UPDATE sobre el presupuesto'::text;
    END IF;
    IF position('client_not_found' in v_def) = 0
       OR position('client_not_found' in v_def) > position('INSERT INTO public.sales_orders' in v_def) THEN
      v_bad := v_bad || '_quote_accept_core perdió el guard de cliente antes del INSERT'::text;
    END IF;

    -- Orden dentro de la conversión: lock -> idempotencia -> aceptación -> confirmación.
    v_def  := pg_get_functiondef(v_fn::regprocedure);
    v_lock := position('FOR UPDATE' in v_def);
    v_idem := position('operation_idempotency' in v_def);
    v_core := position('_quote_accept_core(' in v_def);
    v_conf := position('_c29_confirm_order_core(' in v_def);
    IF v_lock = 0 OR v_idem = 0 OR v_core = 0 OR v_conf = 0
       OR NOT (v_lock < v_idem AND v_idem < v_core AND v_core < v_conf) THEN
      v_bad := v_bad || format('rpc_convert_quote_to_sale: orden lock(%s) < idempotencia(%s) < aceptación(%s) < confirmación(%s) roto',
                               v_lock, v_idem, v_core, v_conf);
    END IF;
    IF position('idempotency_key_conflict' in v_def) = 0 OR position('replayed' in v_def) = 0 THEN
      v_bad := v_bad || 'rpc_convert_quote_to_sale no convierte un replay del núcleo en idempotency_key_conflict'::text;
    END IF;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE PRESUPUESTO-A-VENTA FAILED (u):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (u): una definición de cada función, núcleo y rpc_accept_quote sin EXECUTE para la API, conversión sin anon; el wrapper delega con su COMMENT vivo; el núcleo bloquea el presupuesto; la conversión toma el lock antes de la idempotencia y acepta antes de confirmar.';
END $$;
