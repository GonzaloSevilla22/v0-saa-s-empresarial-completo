-- =============================================================================
-- test_remito_a_venta.sql — Gate de comportamiento de la TANDA B de
-- `remitos-venta` (migración 20261070000001_remitos_venta_conversion.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de
-- verdad. Este archivo ejecuta, contra Postgres real y con usuarios reales
-- (owner, admin, seller, stock y cashier de la cuenta A con membresía en
-- account_members y roles en account_member_roles, más un owner de la cuenta
-- B), la RPC nueva rpc_convert_delivery_note_to_sale y las tres funciones que
-- esta tanda reescribe desde su cuerpo vivo: _c29_confirm_order_core (rama
-- v_from_delivery_note), rpc_delete_sale_operation (salto de la reversa de
-- stock, guard de sucursal y reapertura del remito) y
-- rpc_atomic_update_sale_operation (P0423 delivery_note_sale_locked).
--
-- Matriz (tasks.md 6.2 / 6.8, design.md §D7, §D9, §D16):
--   (z) CONTROL NEGATIVO — núcleo invocado directo con una orden cuyo origen
--       es un remito válido (mismas líneas, cliente, sucursal, issued): NO
--       descuenta stock ni escribe movimientos, y sale_items toma los cuatro
--       snapshots de la línea de la orden. Con la columna pero sin la rama del
--       núcleo, este bloque FALLA (el núcleo vivo descuenta igual): es la
--       prueba de que el gate detecta el doble descuento.
--   (n) núcleo con un origen inválido (orden armada como postgres): remito de
--       otra cuenta, anulado, convertido, de otro cliente, de otra sucursal, y
--       líneas distintas en producto, unidad, cantidad o con una línea de más
--       -> P0409 delivery_note_order_mismatch, sin stock, venta ni evento.
--   (a) conversión cash: stock idéntico, 0 movimientos de las filas sales,
--       caja, SaleConfirmed, orden confirmed con source_delivery_note_id,
--       remito converted (revisión intacta), historial de los dos documentos,
--       resultado {delivery_note_id, delivery_note_number, sales_order_id,
--       operation_id, total, replayed=false}; los cuatro snapshots del remito
--       (producto renombrado y costo remarcado DESPUÉS de emitir); payload del
--       remito con converted_sales_order_id / converted_operation_id.
--   (b) credit como `authenticated` por el vendedor: cargo con vencimiento por
--       cascada, sin caja, stock idéntico.
--   (c) transfer con cuenta bancaria en otra sucursal: bank_movements.
--   (d) producto dado de baja después de emitir: convierte.
--   (e) cliente dado de baja: P0404 delivery_note_client_unavailable, cero
--       efectos.
--   (f) sucursal desactivada / cerrada (armada como postgres, evadiendo el
--       guard de baja): P0422 branch_closed, cero efectos.
--   (g) replay -> replayed=true, misma venta, sin efectos; (h) misma clave
--       sobre otro remito -> P0409 idempotency_key_conflict; (i) segunda
--       conversión -> P0409 delivery_note_invalid_state; (j) versión vieja ->
--       P0409 delivery_note_changed; parámetros faltantes -> P0400.
--   (k) roles: el cashier convierte; el stock -> P0403; remito ajeno -> P0404.
--   (l) cash sin sesión -> P0400 cash_requires_session, cero efectos.
--   (m) regresiones: rpc_quick_sale y rpc_convert_quote_to_sale siguen
--       descontando con su movimiento sale/sale; P0423 de dinero de una venta
--       POS común intacto.
--   (q) editar la venta nacida del remito -> P0423 delivery_note_sale_locked y
--       cero efectos: comprobante pendiente NO anulado, branch_stock y
--       stock_movements sin cambios.
--   (r) anular un remito convertido -> P0423 delivery_note_locked_converted.
--   (o) borrar la venta: dinero compensado, stock idéntico, orden canceled,
--       remito issued con historial converted -> issued y motivo; reconvertir
--       funciona (índice parcial); borrar una venta a crédito compensa la
--       cuenta corriente; el vendedor no borra (P0403, sin efectos).
--   (p) borrar la venta con la sucursal del remito desactivada / cerrada ->
--       P0422 delivery_note_branch_inactive y cero efectos.
--   (s) invariante: ninguna fila sales de una venta nacida de remito tiene
--       movimiento de stock.
--   (u) introspección (bloque DO aparte, sin fixtures).
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila de las cuentas del gate y residuo
-- cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run remito a venta gate").
-- =============================================================================

-- Los helpers nombran objetos de la migración: sin validar el cuerpo al
-- crearlos, el RED falla por la RPC inexistente (42883).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION pg_temp.rc_as(p_uid uuid) RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.rc_line(p_product uuid, p_qty numeric, p_price numeric,
                                           p_subtotal numeric, p_unit uuid)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal);
$f$;

-- 'OK' o 'SQLSTATE mensaje'; el error revierte lo que la sentencia escribió.
CREATE OR REPLACE FUNCTION pg_temp.rc_err(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  v_state text;
  v_msg   text;
BEGIN
  EXECUTE p_sql;
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN v_state || ' ' || v_msg;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rc_issue(p_key text, p_client uuid, p_branch uuid, p_items jsonb)
RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
  RETURN (public.rpc_create_sale_delivery_note(p_key, p_client, p_branch, NULL, NULL, p_items)->>'id')::uuid;
END;
$f$;

-- Conversión: 'OK|<json>' o 'ERR|<sqlstate>|<mensaje>'. El bloque EXCEPTION
-- revierte la subtransacción, que es lo que ve el backend.
CREATE OR REPLACE FUNCTION pg_temp.rc_convert(p_key text, p_dn uuid, p_rev integer, p_pm uuid,
                                              p_session uuid DEFAULT NULL, p_bank uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v       jsonb;
  v_state text;
  v_msg   text;
BEGIN
  v := public.rpc_convert_delivery_note_to_sale(
         p_idempotency_key   => p_key,
         p_delivery_note_id  => p_dn,
         p_expected_revision => p_rev,
         p_payment_method_id => p_pm,
         p_cash_session_id   => p_session,
         p_bank_account_id   => p_bank,
         p_canal             => NULL);
  RETURN 'OK|' || v::text;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rc_rev(p_dn uuid) RETURNS integer
LANGUAGE sql AS $f$ SELECT revision FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rc_status(p_dn uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT status FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rc_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p_product AND branch_id = p_branch), 0);
$f$;

-- Movimientos de stock de las filas sales de una operación (una venta nacida
-- de un remito no tiene ninguno).
CREATE OR REPLACE FUNCTION pg_temp.rc_sale_moves(p_op uuid) RETURNS bigint
LANGUAGE sql AS $f$
  SELECT count(*) FROM public.stock_movements sm
  WHERE sm.reference_id IN (SELECT s.id FROM public.sales s WHERE s.operation_id = p_op);
$f$;

-- Huella de todo lo que una conversión, un borrado o una edición pueden tocar
-- en la cuenta: comparar antes/después de un rechazo prueba "cero efectos".
CREATE OR REPLACE FUNCTION pg_temp.rc_effects(p_account uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws(' ',
    'so=' || (SELECT count(*) FROM public.sales_orders WHERE account_id = p_account),
    'so_status=' || COALESCE((SELECT string_agg(status || ':' || n, ',' ORDER BY status)
                              FROM (SELECT status, count(*) AS n FROM public.sales_orders WHERE account_id = p_account GROUP BY status) s), ''),
    'soi=' || (SELECT count(*) FROM public.sales_order_items WHERE account_id = p_account),
    'sales=' || (SELECT count(*) FROM public.sales WHERE account_id = p_account),
    'sale_items=' || (SELECT count(*) FROM public.sale_items WHERE account_id = p_account),
    'sm=' || (SELECT count(*) FROM public.stock_movements WHERE account_id = p_account),
    'bs=' || (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    'cash=' || (SELECT count(*) FROM public.cash_movements cm
                JOIN public.cash_sessions cs ON cs.id = cm.session_id
                JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
                JOIN public.branches b ON b.id = cb.branch_id
                WHERE b.account_id = p_account),
    'cam=' || (SELECT count(*) FROM public.customer_account_movements WHERE account_id = p_account),
    'bank=' || (SELECT count(*) FROM public.bank_movements WHERE account_id = p_account),
    'events=' || (SELECT count(*) FROM public.events WHERE account_id = p_account),
    'history=' || (SELECT count(*) FROM public.document_status_history WHERE account_id = p_account),
    'fiscal=' || COALESCE((SELECT string_agg(status || ':' || n, ',' ORDER BY status)
                           FROM (SELECT status, count(*) AS n FROM public.fiscal_documents WHERE account_id = p_account GROUP BY status) f), ''),
    'idem=' || (SELECT count(*) FROM public.operation_idempotency oi
                WHERE oi.user_id IN (SELECT am.user_id FROM public.account_members am WHERE am.account_id = p_account)),
    'dn=' || COALESCE((SELECT string_agg(status || ':' || n || ':' || r, ',' ORDER BY status)
                       FROM (SELECT status, count(*) AS n, sum(revision) AS r FROM public.delivery_notes WHERE account_id = p_account GROUP BY status) d), ''));
$f$;

-- Orden FABRICADA (como postgres) con origen de remito + confirmación por el
-- núcleo, todo en una subtransacción: devuelve 'OK|<json>' o
-- 'ERR|<sqlstate>|<mensaje>'. Un error revierte también la orden.
CREATE OR REPLACE FUNCTION pg_temp.rc_core_with_origin(p_key text, p_account uuid, p_branch uuid, p_client uuid,
                                                       p_dn uuid, p_items jsonb, p_pm uuid, p_actor uuid)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_order uuid;
  v       jsonb;
  v_state text;
  v_msg   text;
BEGIN
  EXECUTE 'INSERT INTO public.sales_orders (account_id, branch_id, client_id, source_delivery_note_id, status, total, created_by)
           VALUES ($1, $2, $3, $4, ''draft'', (SELECT COALESCE(sum((e->>''subtotal'')::numeric), 0) FROM jsonb_array_elements($5) e), $6)
           RETURNING id'
    INTO v_order USING p_account, p_branch, p_client, p_dn, p_items, p_actor;
  INSERT INTO public.sales_order_items
    (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
  SELECT v_order, p_account, (e->>'product_id')::uuid, (e->>'unit_id')::uuid, (e->>'quantity')::numeric,
         (e->>'price')::numeric, (e->>'subtotal')::numeric,
         e->>'name_snapshot', e->>'sku_snapshot', (e->>'unit_cost_snapshot')::numeric, (e->>'iva_rate_snapshot')::numeric
  FROM jsonb_array_elements(p_items) e;
  v := public._c29_confirm_order_core(p_key, v_order, NULL, NULL, NULL, NULL, NULL, p_pm, NULL);
  RETURN 'OK|' || (v || jsonb_build_object('order_id', v_order))::text;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END;
$f$;

-- Líneas de un remito con sus snapshots, en el formato de rc_core_with_origin.
CREATE OR REPLACE FUNCTION pg_temp.rc_dn_items(p_dn uuid) RETURNS jsonb
LANGUAGE sql AS $f$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id', product_id, 'unit_id', unit_id, 'quantity', quantity, 'price', price, 'subtotal', subtotal,
           'name_snapshot', name_snapshot, 'sku_snapshot', sku_snapshot,
           'unit_cost_snapshot', unit_cost_snapshot, 'iva_rate_snapshot', iva_rate_snapshot) ORDER BY line_no), '[]'::jsonb)
  FROM public.delivery_note_items WHERE delivery_note_id = p_dn;
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';
  v_fail_before   integer;
  v_tag           text := 'rc-' || gen_random_uuid()::text || '-';

  v_owner_a       uuid := gen_random_uuid();
  v_owner_b       uuid := gen_random_uuid();
  v_admin         uuid := gen_random_uuid();
  v_seller        uuid := gen_random_uuid();
  v_stocker       uuid := gen_random_uuid();
  v_cashier       uuid := gen_random_uuid();
  v_users         uuid[];
  v_accounts      uuid[];
  v_account_a     uuid;
  v_account_b     uuid;
  v_member        uuid;

  v_x uuid; v_y uuid; v_z uuid; v_branch_b uuid;
  v_cashbox_x uuid; v_session_x uuid;
  v_bank_a uuid;
  v_pm_cash uuid; v_pm_credit uuid; v_pm_transfer uuid; v_pm_cash_b uuid; v_pm_other uuid;
  v_c1 uuid; v_c2 uuid; v_c_gone uuid; v_client_b uuid;
  v_u uuid; v_u2 uuid;
  v_p1 uuid; v_p2 uuid; v_pren uuid; v_pdead uuid; v_ppos uuid; v_pq uuid; v_product_b uuid;
  v_fp uuid; v_pv uuid;

  v_dn_core uuid; v_dn_mm uuid; v_dn_canc uuid; v_dn_fake uuid; v_dn_b uuid;
  v_dn_cash uuid; v_dn_credit uuid; v_dn_transfer uuid; v_dn_dead uuid; v_dn_gone uuid;
  v_dn_z uuid; v_dn_other uuid; v_dn_stk uuid; v_dn_nomoney uuid;

  v_key_cash      text;
  v_order_cash    uuid;
  v_op_cash       uuid;
  v_order_credit  uuid;
  v_op_credit     uuid;
  v_order_transfer uuid;
  v_op_transfer   uuid;
  v_order_re      uuid;
  v_op_re         uuid;
  v_fiscal_doc    uuid;
  v_quote         uuid;

  v_today   date := public.reporting_local_today();
  v_r       text;
  v_j       jsonb;
  v_txt     text;
  v_before  text;
  v_after   text;
  v_n       bigint;
  v_n2      bigint;
  v_val     numeric;
  v_val2    numeric;
  v_date    date;
  v_s1 numeric; v_s2 numeric; v_s3 numeric; v_s4 numeric;
  v_sm      bigint;
  v_items   jsonb;
  v_sale_ids uuid[];
  v_rec     RECORD;
  v_state   text;
  v_msg     text;
  v_table   text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_admin, v_seller, v_stocker, v_cashier];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'remito-a-venta-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate RaV ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_admin, 'admin'), (v_seller, 'seller'),
               (v_stocker, 'stock'), (v_cashier, 'cashier')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
  WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id IN (v_admin, v_seller, v_stocker, v_cashier));
  DELETE FROM public.account_members WHERE user_id IN (v_admin, v_seller, v_stocker, v_cashier);
  SET session_replication_role = DEFAULT;

  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_admin, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'admin');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_stocker, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'stock');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'cashier');

  SELECT id INTO v_x FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  IF v_x IS NULL OR v_branch_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RaV Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RaV Z', TRUE, 'active', now(), now() + interval '2 minutes') RETURNING id INTO v_z;

  SELECT id INTO v_cashbox_x FROM public.cashboxes WHERE branch_id = v_x ORDER BY created_at LIMIT 1;
  IF v_cashbox_x IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_x, 'Caja Gate RaV X') RETURNING id INTO v_cashbox_x;
  END IF;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_x, 'open', 0, v_owner_a) RETURNING id INTO v_session_x;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, 'Banco Gate RaV', 'ARS', 0) RETURNING id INTO v_bank_a;

  SELECT id INTO v_pm_cash FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'credit' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_other FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'other' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_cash_b FROM public.payment_methods
  WHERE account_id = v_account_b AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  IF v_pm_cash IS NULL OR v_pm_credit IS NULL OR v_pm_transfer IS NULL OR v_pm_cash_b IS NULL OR v_pm_other IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: faltan formas de pago sembradas';
  END IF;

  INSERT INTO public.clients (user_id, account_id, name, phone, payment_terms_days)
  VALUES (v_owner_a, v_account_a, 'Cliente Gate RaV', '2615550404', 30) RETURNING id INTO v_c1;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate RaV 2') RETURNING id INTO v_c2;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate RaV Se Va') RETURNING id INTO v_c_gone;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_b, v_account_b, 'Cliente Gate RaV B') RETURNING id INTO v_client_b;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad RaV', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Bulto RaV', 'bto', 'unit', 1, false) RETURNING id INTO v_u2;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV P1', 'GRAV-P1', 100, 1000, v_u) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV P2', 'GRAV-P2', 50, 500, v_u) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV Renombrado', 'GRAV-REN', 30, 300, v_u) RETURNING id INTO v_pren;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV Se Discontinua', 'GRAV-DEAD', 20, 200, v_u) RETURNING id INTO v_pdead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV POS', 'GRAV-POS', 10, 100, v_u) RETURNING id INTO v_ppos;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaV Presupuesto', 'GRAV-Q', 10, 100, v_u) RETURNING id INTO v_pq;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'Gate RaV B', 'GRAV-B', 10, 100) RETURNING id INTO v_product_b;

  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1,    v_x, 50);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1,    v_y, 20);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1,    v_z, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2,    v_x, 50);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pren,  v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pdead, v_x, 1);  -- el remito se lleva la última: la baja (RN-B4) exige stock 0
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_ppos,  v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pq,    v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_b, v_product_b, v_branch_b, 10);

  -- Perfil fiscal monotributista (para dejar un comprobante pendiente en (q)).
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account_a, '20123456786', 'monotributista', 'homologacion', true) RETURNING id INTO v_fp;
  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account_a, 9701, true) RETURNING id INTO v_pv;

  -- Remitos (todos emitidos ANTES de las bajas de catálogo y de cliente).
  PERFORM pg_temp.rc_as(v_owner_a);
  v_dn_core     := pg_temp.rc_issue(v_tag || 'dn-core', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 2, 1000, 2000, v_u)));
  v_dn_mm       := pg_temp.rc_issue(v_tag || 'dn-mm', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_canc     := pg_temp.rc_issue(v_tag || 'dn-canc', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_fake     := pg_temp.rc_issue(v_tag || 'dn-fake', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_cash     := pg_temp.rc_issue(v_tag || 'dn-cash', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 2, 1000, 2000, v_u),
                     pg_temp.rc_line(v_p2, 1, 500, 500, v_u),
                     pg_temp.rc_line(v_pren, 1, 300, 300, v_u)));
  v_dn_credit   := pg_temp.rc_issue(v_tag || 'dn-credit', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p2, 1, 500, 500, v_u)));
  v_dn_transfer := pg_temp.rc_issue(v_tag || 'dn-transfer', v_c1, v_y, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_dead     := pg_temp.rc_issue(v_tag || 'dn-dead', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_pdead, 1, 200, 200, v_u)));
  v_dn_gone     := pg_temp.rc_issue(v_tag || 'dn-gone', v_c_gone, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_z        := pg_temp.rc_issue(v_tag || 'dn-z', v_c1, v_z, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_other    := pg_temp.rc_issue(v_tag || 'dn-other', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_stk      := pg_temp.rc_issue(v_tag || 'dn-stk', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u)));
  v_dn_nomoney  := pg_temp.rc_issue(v_tag || 'dn-nomoney', v_c1, v_x, jsonb_build_array(
                     pg_temp.rc_line(v_p2, 3, 500, 1500, v_u)));
  PERFORM public.rpc_cancel_delivery_note(v_dn_canc, 1, 'Gate RaV: anulado para el origen inválido');
  PERFORM pg_temp.rc_as(v_owner_b);
  v_dn_b        := pg_temp.rc_issue(v_tag || 'dn-b', v_client_b, v_branch_b, jsonb_build_array(
                     pg_temp.rc_line(v_product_b, 1, 100, 100, NULL)));
  PERFORM pg_temp.rc_as(v_owner_a);
  -- "Convertido" sin venta, armado como postgres (sólo para el origen inválido).
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'converted' WHERE id = v_dn_fake;
  SET session_replication_role = DEFAULT;

  IF v_dn_core IS NULL OR v_dn_cash IS NULL OR v_dn_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se emitieron los remitos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (z) CONTROL NEGATIVO: orden con origen de remito válido no descuenta
  -- ═══════════════════════════════════════════════════════════════════════
  -- No usa rpc_convert_delivery_note_to_sale: arma la orden como postgres y
  -- llama al núcleo directo. Sin la rama del núcleo (6.3 aplicada, 6.4 no),
  -- este bloque FALLA porque el núcleo vivo descuenta igual.
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_s1 := pg_temp.rc_stock(v_p1, v_x);
  SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
  v_r := pg_temp.rc_core_with_origin(v_tag || 'core', v_account_a, v_x, v_c1, v_dn_core,
                                     pg_temp.rc_dn_items(v_dn_core), v_pm_credit, v_owner_a);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (z): el núcleo rechazó una orden con origen de remito VÁLIDO: %s', v_r);
  ELSE
    v_j := substr(v_r, 4)::jsonb;
    IF pg_temp.rc_stock(v_p1, v_x) IS DISTINCT FROM v_s1 THEN
      v_failures := v_failures || format('FAIL (z) DOBLE DESCUENTO: el núcleo descontó stock para una orden con origen de remito (P1 en X %s -> %s)',
                                         v_s1, pg_temp.rc_stock(v_p1, v_x));
    END IF;
    IF (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm
       OR pg_temp.rc_sale_moves((v_j->>'operation_id')::uuid) <> 0 THEN
      v_failures := v_failures || 'FAIL (z) DOBLE DESCUENTO: el núcleo escribió movimientos de stock para una orden con origen de remito'::text;
    END IF;
    IF NOT EXISTS (
         SELECT 1 FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
         JOIN public.delivery_note_items di ON di.delivery_note_id = v_dn_core AND di.product_id = si.product_id
         WHERE s.operation_id = (v_j->>'operation_id')::uuid
           AND si.name_snapshot IS NOT DISTINCT FROM di.name_snapshot
           AND si.sku_snapshot IS NOT DISTINCT FROM di.sku_snapshot
           AND si.unit_cost_snapshot IS NOT DISTINCT FROM di.unit_cost_snapshot
           AND si.iva_rate_snapshot IS NOT DISTINCT FROM di.iva_rate_snapshot) THEN
      v_failures := v_failures || 'FAIL (z): sale_items no tomó los cuatro snapshots de la línea de la orden'::text;
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (z): el núcleo, con una orden cuyo origen es un remito válido, no descuenta ni escribe movimientos y congela los snapshots de la orden.';
  ELSE
    RAISE NOTICE 'CONTROL (z): %', array_to_string(v_failures[v_fail_before + 1:], ' | ');
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (n) núcleo con un origen inválido -> P0409 delivery_note_order_mismatch
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.rc_effects(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('remito de otra cuenta', v_x, v_c1, v_dn_b, pg_temp.rc_dn_items(v_dn_mm)),
      ('remito anulado',        v_x, v_c1, v_dn_canc, pg_temp.rc_dn_items(v_dn_canc)),
      ('remito convertido',     v_x, v_c1, v_dn_fake, pg_temp.rc_dn_items(v_dn_fake)),
      ('otro cliente',          v_x, v_c2, v_dn_mm, pg_temp.rc_dn_items(v_dn_mm)),
      ('otra sucursal',         v_y, v_c1, v_dn_mm, pg_temp.rc_dn_items(v_dn_mm)),
      ('otro producto',         v_x, v_c1, v_dn_mm, jsonb_build_array(pg_temp.rc_line(v_p2, 1, 1000, 1000, v_u))),
      ('otra unidad',           v_x, v_c1, v_dn_mm, jsonb_build_array(pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u2))),
      ('otra cantidad',         v_x, v_c1, v_dn_mm, jsonb_build_array(pg_temp.rc_line(v_p1, 2, 1000, 2000, v_u))),
      ('una línea de más',      v_x, v_c1, v_dn_mm, jsonb_build_array(pg_temp.rc_line(v_p1, 1, 1000, 1000, v_u),
                                                                       pg_temp.rc_line(v_p2, 1, 500, 500, v_u))),
      ('sin líneas de producto', v_x, v_c1, v_dn_mm, '[]'::jsonb)
    ) AS t(label, branch, client, dn, items)
  LOOP
    v_r := pg_temp.rc_core_with_origin(v_tag || 'mm-' || v_rec.label, v_account_a, v_rec.branch, v_rec.client,
                                       v_rec.dn, v_rec.items, v_pm_credit, v_owner_a);
    IF v_r NOT LIKE 'ERR|P0409|delivery_note_order_mismatch%' THEN
      v_failures := v_failures || format('FAIL (n) %s: se esperaba P0409 delivery_note_order_mismatch, vino %s', v_rec.label, v_r);
    END IF;
  END LOOP;
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (n): un origen inválido dejó efectos (%s -> %s)', v_before, v_after);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (n): los 10 orígenes inválidos (otra cuenta, anulado, convertido, otro cliente, otra sucursal, producto, unidad, cantidad, línea de más, sin líneas) rebotan con P0409 delivery_note_order_mismatch sin efectos.';
  ELSE
    RAISE NOTICE 'CONTROL (n): %', array_to_string(v_failures[v_fail_before + 1:], ' | ');
  END IF;

  -- Sonda: sin la RPC de conversión el gate aborta acá con 42883 (RED de 6.2).
  -- Va DESPUÉS de (z) y (n), que no la usan, para que el control negativo
  -- (columna aplicada, núcleo sin la rama) se vea en su NOTICE antes de abortar.
  PERFORM 'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) conversión cash con snapshots del remito
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- Después de emitir: el producto se renombra y el catálogo se remarca.
  UPDATE public.products SET name = 'Gate RaV Renombrado DESPUES', sku = 'GRAV-REN-2' WHERE id = v_pren;
  UPDATE public.products SET cost = 999 WHERE id = v_p1;
  v_s1 := pg_temp.rc_stock(v_p1, v_x); v_s2 := pg_temp.rc_stock(v_p2, v_x); v_s3 := pg_temp.rc_stock(v_pren, v_x);
  SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
  SELECT count(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_x;
  v_key_cash := v_tag || 'cash';
  v_r := pg_temp.rc_convert(v_key_cash, v_dn_cash, 1, v_pm_cash, v_session_x, NULL);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (a): la conversión cash falló: %s', v_r);
  ELSE
    v_j := substr(v_r, 4)::jsonb;
    v_order_cash := (v_j->>'sales_order_id')::uuid;
    v_op_cash := (v_j->>'operation_id')::uuid;
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_j) k)
         <> ARRAY['delivery_note_id', 'delivery_note_number', 'operation_id', 'replayed', 'sales_order_id', 'total']
       OR (v_j->>'delivery_note_id')::uuid <> v_dn_cash
       OR (v_j->>'delivery_note_number')::bigint IS DISTINCT FROM (SELECT number FROM public.delivery_notes WHERE id = v_dn_cash)
       OR (v_j->>'total')::numeric <> 2800 OR (v_j->>'replayed')::boolean IS DISTINCT FROM false THEN
      v_failures := v_failures || format('FAIL (a): resultado inesperado %s', v_j);
    END IF;
    IF pg_temp.rc_stock(v_p1, v_x) <> v_s1 OR pg_temp.rc_stock(v_p2, v_x) <> v_s2 OR pg_temp.rc_stock(v_pren, v_x) <> v_s3 THEN
      v_failures := v_failures || 'FAIL (a) DOBLE DESCUENTO: convertir cambió el stock'::text;
    END IF;
    IF (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm
       OR pg_temp.rc_sale_moves(v_op_cash) <> 0 THEN
      v_failures := v_failures || 'FAIL (a): convertir escribió movimientos de stock'::text;
    END IF;
    IF (SELECT count(*) FROM public.cash_movements WHERE session_id = v_session_x) <> v_n + 1
       OR NOT EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session_x
                        AND reference_id = v_order_cash AND movement_type = 'sale' AND amount = 2800) THEN
      v_failures := v_failures || 'FAIL (a): falta el movimiento de caja de la venta'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sales_orders so
                   WHERE so.id = v_order_cash AND so.status = 'confirmed' AND so.source_delivery_note_id = v_dn_cash
                     AND so.sale_operation_id = v_op_cash AND so.branch_id = v_x AND so.client_id = v_c1
                     AND so.total = 2800 AND so.payment_method_id = v_pm_cash) THEN
      v_failures := v_failures || 'FAIL (a): la orden no quedó confirmed con origen, sucursal, cliente, total y forma de pago del remito'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'SaleConfirmed' AND aggregate_id = v_order_cash) THEN
      v_failures := v_failures || 'FAIL (a): falta SaleConfirmed'::text;
    END IF;
    IF pg_temp.rc_status(v_dn_cash) <> 'converted' OR pg_temp.rc_rev(v_dn_cash) <> 1 THEN
      v_failures := v_failures || format('FAIL (a): el remito quedó %s revisión %s (se esperaba converted, 1)',
                                         pg_temp.rc_status(v_dn_cash), pg_temp.rc_rev(v_dn_cash));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'delivery_note_sale'
                     AND document_id = v_dn_cash AND from_status = 'issued' AND to_status = 'converted' AND performed_by = v_owner_a)
       OR (SELECT count(*) FROM public.document_status_history WHERE document_type = 'sales_order' AND document_id = v_order_cash
             AND ((from_status IS NULL AND to_status = 'draft') OR (from_status = 'draft' AND to_status = 'confirmed'))) <> 2 THEN
      v_failures := v_failures || 'FAIL (a): falta el historial issued->converted del remito o NULL->draft->confirmed de la orden'::text;
    END IF;
    -- Snapshots: los del remito, aunque el catálogo cambió después de emitir.
    SELECT count(*) INTO v_n2
    FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
    JOIN public.delivery_note_items di ON di.delivery_note_id = v_dn_cash AND di.product_id = si.product_id
    WHERE s.operation_id = v_op_cash
      AND si.name_snapshot IS NOT DISTINCT FROM di.name_snapshot
      AND si.sku_snapshot IS NOT DISTINCT FROM di.sku_snapshot
      AND si.unit_cost_snapshot IS NOT DISTINCT FROM di.unit_cost_snapshot
      AND si.iva_rate_snapshot IS NOT DISTINCT FROM di.iva_rate_snapshot
      AND si.quantity = di.quantity AND si.unit_id IS NOT DISTINCT FROM di.unit_id AND si.price = di.price;
    IF v_n2 <> 3
       OR NOT EXISTS (SELECT 1 FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
                      WHERE s.operation_id = v_op_cash AND si.product_id = v_pren
                        AND si.name_snapshot = 'Gate RaV Renombrado' AND si.sku_snapshot = 'GRAV-REN')
       OR NOT EXISTS (SELECT 1 FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
                      WHERE s.operation_id = v_op_cash AND si.product_id = v_p1 AND si.unit_cost_snapshot = 100) THEN
      v_failures := v_failures || format('FAIL (a): sale_items no conserva los cuatro snapshots del remito (%s de 3 líneas)', v_n2);
    END IF;
    IF (SELECT count(*) FROM public.sales_order_items soi JOIN public.delivery_note_items di
          ON di.delivery_note_id = v_dn_cash AND di.product_id = soi.product_id
          AND di.name_snapshot IS NOT DISTINCT FROM soi.name_snapshot AND di.unit_cost_snapshot IS NOT DISTINCT FROM soi.unit_cost_snapshot
          AND di.quantity = soi.quantity AND di.price = soi.price AND di.subtotal = soi.subtotal
        WHERE soi.sales_order_id = v_order_cash) <> 3 THEN
      v_failures := v_failures || 'FAIL (a): sales_order_items no es la copia de las líneas del remito'::text;
    END IF;
    v_j := public._delivery_note_payload(v_dn_cash);
    IF (v_j->>'converted_sales_order_id')::uuid IS DISTINCT FROM v_order_cash
       OR (v_j->>'converted_operation_id')::uuid IS DISTINCT FROM v_op_cash THEN
      v_failures := v_failures || format('FAIL (a): el payload del remito no expone la venta generada (%s / %s)',
                                         v_j->>'converted_sales_order_id', v_j->>'converted_operation_id');
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (a): conversión cash — stock idéntico, 0 movimientos, caja, SaleConfirmed, orden confirmed con origen, remito converted sin subir revisión, historiales, snapshots del remito (renombrado y costo remarcado) y payload con la venta.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) replay, (h) clave sobre otro remito, (i) segunda conversión
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.rc_effects(v_account_a);
  v_r := pg_temp.rc_convert(v_key_cash, v_dn_cash, 1, v_pm_cash, v_session_x, NULL);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'OK|%' OR (substr(v_r, 4)::jsonb->>'replayed')::boolean IS DISTINCT FROM true
     OR (substr(v_r, 4)::jsonb->>'sales_order_id')::uuid IS DISTINCT FROM v_order_cash
     OR (substr(v_r, 4)::jsonb->>'operation_id')::uuid IS DISTINCT FROM v_op_cash
     OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (g): replay inesperado %s (%s -> %s)', v_r, v_before, v_after);
  END IF;
  v_r := pg_temp.rc_convert(v_key_cash, v_dn_other, 1, v_pm_credit);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|idempotency_key_conflict%' OR v_before IS DISTINCT FROM v_after
     OR pg_temp.rc_status(v_dn_other) <> 'issued' THEN
    v_failures := v_failures || format('FAIL (h): la clave de otro remito debía dar idempotency_key_conflict sin efectos: %s', v_r);
  END IF;
  v_r := pg_temp.rc_convert(v_tag || 'cash-2', v_dn_cash, 1, v_pm_credit);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|delivery_note_invalid_state%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (i): la segunda conversión debía dar delivery_note_invalid_state: %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (g/h/i): replay sin efectos, clave ajena -> idempotency_key_conflict, segunda conversión -> delivery_note_invalid_state.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) versión vieja y parámetros; (k) roles y tenencia; (l) cash sin sesión
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- La edición sube la revisión a 2.
  PERFORM public.rpc_update_delivery_note(v_dn_other, 1, v_c1, v_x, NULL, NULL,
            jsonb_build_array(pg_temp.rc_line(v_p1, 1, 900, 900, v_u)));
  v_before := pg_temp.rc_effects(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('versión vieja',  v_tag || 'old', 1::integer, v_pm_credit, 'ERR|P0409|delivery_note_changed%'),
      ('sin versión',    v_tag || 'norev', NULL::integer, v_pm_credit, 'ERR|P0400|%'),
      ('sin forma de pago', v_tag || 'nopm', 2, NULL::uuid, 'ERR|P0400|payment_method_required%'),
      ('sin clave',      '', 2, v_pm_credit, 'ERR|P0400|%'),
      ('forma de pago ajena', v_tag || 'pmb', 2, v_pm_cash_b, 'ERR|P0404|payment_method_not_found%')
    ) AS t(label, k, rev, pm, expected)
  LOOP
    v_r := pg_temp.rc_convert(v_rec.k, v_dn_other, v_rec.rev, v_rec.pm);
    IF v_r NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (j) %s: se esperaba %s, vino %s', v_rec.label, v_rec.expected, v_r);
    END IF;
  END LOOP;
  -- Roles: el stock no convierte; el remito ajeno no existe para A.
  PERFORM pg_temp.rc_as(v_stocker);
  v_r := pg_temp.rc_convert(v_tag || 'stk', v_dn_stk, 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0403|insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (k): el rol stock debía dar P0403, vino %s', v_r);
  END IF;
  PERFORM pg_temp.rc_as(v_owner_a);
  v_r := pg_temp.rc_convert(v_tag || 'ajeno', v_dn_b, 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (k): el remito de otra cuenta debía dar P0404, vino %s', v_r);
  END IF;
  v_r := pg_temp.rc_convert(v_tag || 'inexistente', gen_random_uuid(), 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (k): un id inexistente debía dar P0404, vino %s', v_r);
  END IF;
  -- (l) cash sin sesión.
  v_r := pg_temp.rc_convert(v_tag || 'nosession', v_dn_stk, 1, v_pm_cash, NULL, NULL);
  IF v_r NOT LIKE 'ERR|P0400|cash_requires_session%' THEN
    v_failures := v_failures || format('FAIL (l): cash sin sesión debía dar cash_requires_session, vino %s', v_r);
  END IF;
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (j/k/l): un rechazo dejó efectos (%s -> %s)', v_before, v_after);
  END IF;
  -- El cajero convierte (con la versión vigente).
  PERFORM pg_temp.rc_as(v_cashier);
  v_r := pg_temp.rc_convert(v_tag || 'cashier', v_dn_other, 2, v_pm_cash, v_session_x, NULL);
  IF v_r NOT LIKE 'OK|%' OR pg_temp.rc_status(v_dn_other) <> 'converted'
     OR (substr(v_r, 4)::jsonb->>'total')::numeric <> 900 THEN
    v_failures := v_failures || format('FAIL (k): el cajero debía convertir con el precio editado del remito, vino %s', v_r);
  END IF;
  PERFORM pg_temp.rc_as(v_owner_a);
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (j/k/l): versión vieja, parámetros, forma de pago ajena, rol stock, remito ajeno e inexistente y cash sin sesión rebotan sin efectos; el cajero convierte con el precio del remito.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) credit como authenticated por el vendedor
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_s2 := pg_temp.rc_stock(v_p2, v_x);
  SELECT count(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_x;
  PERFORM pg_temp.rc_as(v_seller);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_j := public.rpc_convert_delivery_note_to_sale(v_tag || 'credit', v_dn_credit, 1, v_pm_credit, NULL, NULL, NULL);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    EXECUTE 'RESET ROLE';
    v_j := NULL;
    v_failures := v_failures || format('FAIL (b): la conversión a crédito como authenticated falló: %s / %s', v_state, v_msg);
  END;
  PERFORM pg_temp.rc_as(v_owner_a);
  IF v_j IS NOT NULL THEN
    v_order_credit := (v_j->>'sales_order_id')::uuid;
    v_op_credit := (v_j->>'operation_id')::uuid;
    SELECT count(*), max(cam.amount), max(cam.due_date) INTO v_n2, v_val, v_date
    FROM public.customer_account_movements cam
    WHERE cam.reference_id = v_order_credit AND cam.movement_type = 'sale';
    IF v_n2 <> 1 OR v_val <> 500 OR v_date IS DISTINCT FROM v_today + 30 THEN
      v_failures := v_failures || format('FAIL (b): cargo en cuenta corriente inesperado (n=%s, monto=%s, vence=%s)', v_n2, v_val, v_date);
    END IF;
    IF (SELECT count(*) FROM public.cash_movements WHERE session_id = v_session_x) <> v_n
       OR pg_temp.rc_stock(v_p2, v_x) <> v_s2 OR pg_temp.rc_sale_moves(v_op_credit) <> 0
       OR pg_temp.rc_status(v_dn_credit) <> 'converted' THEN
      v_failures := v_failures || 'FAIL (b): la venta a crédito tocó caja o stock, o el remito no quedó converted'::text;
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (b): conversión a crédito como authenticated por el vendedor — cargo con vencimiento por cascada (30 días), sin caja ni stock.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) transfer con banco en otra sucursal; (d) producto dado de baja
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_s1 := pg_temp.rc_stock(v_p1, v_y);
  v_r := pg_temp.rc_convert(v_tag || 'transfer', v_dn_transfer, 1, v_pm_transfer, NULL, v_bank_a);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (c): la conversión por transferencia falló: %s', v_r);
  ELSE
    v_order_transfer := (substr(v_r, 4)::jsonb->>'sales_order_id')::uuid;
    v_op_transfer := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.bank_movements WHERE source_doc_type = 'sale' AND source_doc_ref = v_order_transfer
                     AND bank_account_id = v_bank_a AND amount = 1000 AND branch_id = v_y)
       OR (SELECT branch_id FROM public.sales_orders WHERE id = v_order_transfer) <> v_y
       OR pg_temp.rc_stock(v_p1, v_y) <> v_s1 OR pg_temp.rc_sale_moves(v_op_transfer) <> 0 THEN
      v_failures := v_failures || 'FAIL (c): falta el movimiento bancario en la sucursal del remito, o cambió el stock'::text;
    END IF;
  END IF;
  -- (d) el producto se da de baja después de emitir: convierte igual.
  UPDATE public.products SET deleted_at = now() WHERE id = v_pdead;
  v_s1 := pg_temp.rc_stock(v_pdead, v_x);
  v_r := pg_temp.rc_convert(v_tag || 'dead', v_dn_dead, 1, v_pm_credit);
  IF v_r NOT LIKE 'OK|%' OR pg_temp.rc_stock(v_pdead, v_x) <> v_s1
     OR NOT EXISTS (SELECT 1 FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
                    WHERE s.operation_id = (substr(v_r, 4)::jsonb->>'operation_id')::uuid
                      AND si.product_id = v_pdead AND si.name_snapshot = 'Gate RaV Se Discontinua') THEN
    v_failures := v_failures || format('FAIL (d): el producto dado de baja después de emitir debía convertirse con su snapshot: %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (c/d): transferencia con movimiento bancario en la sucursal del remito; producto dado de baja después de emitir convierte con su snapshot.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) cliente dado de baja; (f) sucursal desactivada / cerrada
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  UPDATE public.clients SET deleted_at = now() WHERE id = v_c_gone;
  v_before := pg_temp.rc_effects(v_account_a);
  v_r := pg_temp.rc_convert(v_tag || 'gone', v_dn_gone, 1, v_pm_credit);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_client_unavailable%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (e): cliente dado de baja debía dar P0404 delivery_note_client_unavailable sin efectos: %s (%s -> %s)', v_r, v_before, v_after);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = false WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  v_r := pg_temp.rc_convert(v_tag || 'z-off', v_dn_z, 1, v_pm_credit);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0422|branch_closed%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (f): sucursal desactivada debía dar P0422 branch_closed sin efectos: %s', v_r);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = true, status = 'closed', closed_at = now() WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  v_r := pg_temp.rc_convert(v_tag || 'z-closed', v_dn_z, 1, v_pm_credit);
  v_after := pg_temp.rc_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0422|branch_closed%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (f): sucursal cerrada debía dar P0422 branch_closed sin efectos: %s', v_r);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET status = 'active', closed_at = NULL WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (e/f): cliente dado de baja -> delivery_note_client_unavailable; sucursal desactivada o cerrada -> P0422 branch_closed; cero efectos.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (m) regresiones: POS, conversión de presupuesto, P0423 de dinero
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_s1 := pg_temp.rc_stock(v_ppos, v_x);
  v_j := public.rpc_quick_sale(v_tag || 'pos', NULL, jsonb_build_array(jsonb_build_object(
           'product_id', v_ppos, 'unit_id', v_u, 'quantity', 2, 'price', 100, 'subtotal', 200)),
         'cash', v_session_x, NULL, NULL, v_x, NULL, v_pm_cash, NULL);
  IF pg_temp.rc_stock(v_ppos, v_x) <> v_s1 - 2
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements sm JOIN public.sales s ON s.id = sm.reference_id
                    WHERE s.operation_id = (v_j->>'operation_id')::uuid AND sm.type = 'sale'
                      AND sm.reference_type = 'sale' AND sm.quantity_delta = -2) THEN
    v_failures := v_failures || format('FAIL (m): rpc_quick_sale dejó de descontar con su movimiento sale/sale (%s)', v_j);
  END IF;
  SELECT array_agg(id) INTO v_sale_ids FROM public.sales WHERE operation_id = (v_j->>'operation_id')::uuid;
  v_txt := pg_temp.rc_err(format(
    'SELECT public.rpc_atomic_update_sale_operation(%L::uuid[], NULL, %L::date, %L, %L::jsonb)',
    v_sale_ids, v_today, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_ppos, 'amount', 100, 'quantity', 1))));
  IF v_txt NOT LIKE 'P0423 operation_has_cash_movement_immutable%' THEN
    v_failures := v_failures || format('FAIL (m): editar una venta POS en efectivo debía dar el P0423 de dinero de siempre, vino %s', v_txt);
  END IF;
  v_quote := (public.rpc_create_quote(v_c1, NULL, NULL, NULL, jsonb_build_array(jsonb_build_object(
               'product_id', v_pq, 'unit_id', NULL, 'quantity', 1, 'price', 100, 'subtotal', 100, 'description', NULL)))->>'id')::uuid;
  v_s2 := pg_temp.rc_stock(v_pq, v_x);
  v_j := public.rpc_convert_quote_to_sale(v_tag || 'quote', v_quote, 1, v_pm_credit, NULL, NULL, NULL, NULL);
  IF pg_temp.rc_stock(v_pq, v_x) <> v_s2 - 1
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements sm JOIN public.sales s ON s.id = sm.reference_id
                    WHERE s.operation_id = (v_j->>'operation_id')::uuid AND sm.type = 'sale' AND sm.reference_type = 'sale')
     OR (SELECT source_delivery_note_id FROM public.sales_orders WHERE id = (v_j->>'sales_order_id')::uuid) IS NOT NULL THEN
    v_failures := v_failures || format('FAIL (m): rpc_convert_quote_to_sale dejó de descontar con su movimiento sale/sale (%s)', v_j);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (m): rpc_quick_sale y rpc_convert_quote_to_sale siguen descontando con su movimiento sale/sale; el P0423 de dinero de una venta POS no cambia.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (q) editar la venta nacida del remito; (r) anular un remito convertido
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_order_cash IS NOT NULL THEN
    -- Comprobante pendiente SIN marca (el que una edición común anularía).
    v_fiscal_doc := (public.rpc_emit_sale_invoice(v_order_cash, v_pv)->>'fiscal_document_id')::uuid;
    SELECT array_agg(id) INTO v_sale_ids FROM public.sales WHERE operation_id = v_op_cash;
    v_s1 := pg_temp.rc_stock(v_p1, v_x);
    v_before := pg_temp.rc_effects(v_account_a);
    v_txt := pg_temp.rc_err(format(
      'SELECT public.rpc_atomic_update_sale_operation(%L::uuid[], %L::uuid, %L::date, %L, %L::jsonb)',
      v_sale_ids, v_c1, v_today, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 1000, 'quantity', 1, 'unit_id', v_u))));
    v_after := pg_temp.rc_effects(v_account_a);
    IF v_txt NOT LIKE 'P0423 delivery_note_sale_locked%' THEN
      v_failures := v_failures || format('FAIL (q): editar la venta nacida del remito debía dar P0423 delivery_note_sale_locked, vino %s', v_txt);
    END IF;
    IF v_before IS DISTINCT FROM v_after OR pg_temp.rc_stock(v_p1, v_x) <> v_s1
       OR (SELECT status FROM public.fiscal_documents WHERE id = v_fiscal_doc) IS DISTINCT FROM 'pending_cae' THEN
      v_failures := v_failures || format('FAIL (q): la edición rechazada dejó efectos o anuló el comprobante pendiente (%s -> %s, comprobante %s)',
                                         v_before, v_after, (SELECT status FROM public.fiscal_documents WHERE id = v_fiscal_doc));
    END IF;
    -- Venta SIN dinero posteado (forma de pago 'other'): ningún guard de
    -- caja, cuenta corriente ni banco la frena. Sin el P0423 propio, la
    -- edición repondría las 3 unidades que el remito sigue reteniendo.
    v_r := pg_temp.rc_convert(v_tag || 'nomoney', v_dn_nomoney, 1, v_pm_other);
    IF v_r NOT LIKE 'OK|%' THEN
      v_failures := v_failures || format('FAIL (q): no se pudo convertir el remito sin dinero: %s', v_r);
    ELSE
      SELECT array_agg(id) INTO v_sale_ids FROM public.sales
      WHERE operation_id = (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
      v_s2 := pg_temp.rc_stock(v_p2, v_x);
      v_before := pg_temp.rc_effects(v_account_a);
      v_txt := pg_temp.rc_err(format(
        'SELECT public.rpc_atomic_update_sale_operation(%L::uuid[], %L::uuid, %L::date, %L, %L::jsonb)',
        v_sale_ids, v_c1, v_today, 'ARS',
        jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 500, 'quantity', 1, 'unit_id', v_u))));
      IF v_txt NOT LIKE 'P0423 delivery_note_sale_locked%' OR pg_temp.rc_stock(v_p2, v_x) <> v_s2
         OR pg_temp.rc_effects(v_account_a) IS DISTINCT FROM v_before THEN
        v_failures := v_failures || format('FAIL (q): editar una venta de remito SIN dinero posteado debía dar P0423 sin tocar stock (vino %s, stock %s -> %s)',
                                           v_txt, v_s2, pg_temp.rc_stock(v_p2, v_x));
      END IF;
    END IF;
    v_before := pg_temp.rc_effects(v_account_a);
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_cancel_delivery_note(%L::uuid, 1, %L)', v_dn_cash, 'Gate RaV: anular convertido'));
    IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted%' OR pg_temp.rc_effects(v_account_a) IS DISTINCT FROM v_before THEN
      v_failures := v_failures || format('FAIL (r): anular un remito convertido debía dar P0423 sin efectos, vino %s', v_txt);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (q/r): sin venta cash no se puede probar la edición bloqueada'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (q/r): editar la venta nacida del remito -> P0423 delivery_note_sale_locked sin efectos (comprobante pendiente intacto, stock y movimientos sin cambios); anular un convertido -> P0423.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (o) borrar la venta: el remito vuelve a pendiente sin tocar el stock
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_op_cash IS NOT NULL AND v_op_credit IS NOT NULL THEN
    -- El vendedor no borra (sales_order confirmed -> canceled es admin/owner).
    v_before := pg_temp.rc_effects(v_account_a);
    PERFORM pg_temp.rc_as(v_seller);
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_credit));
    PERFORM pg_temp.rc_as(v_owner_a);
    IF v_txt NOT LIKE 'P0403%' OR pg_temp.rc_effects(v_account_a) IS DISTINCT FROM v_before THEN
      v_failures := v_failures || format('FAIL (o): el vendedor no debía poder borrar la venta (vino %s)', v_txt);
    END IF;

    v_s1 := pg_temp.rc_stock(v_p1, v_x); v_s2 := pg_temp.rc_stock(v_p2, v_x); v_s3 := pg_temp.rc_stock(v_pren, v_x);
    SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_cash));
    IF v_txt <> 'OK' THEN
      v_failures := v_failures || format('FAIL (o): borrar la venta cash falló: %s', v_txt);
    ELSE
      IF pg_temp.rc_stock(v_p1, v_x) <> v_s1 OR pg_temp.rc_stock(v_p2, v_x) <> v_s2 OR pg_temp.rc_stock(v_pren, v_x) <> v_s3
         OR (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm THEN
        v_failures := v_failures || 'FAIL (o): borrar la venta nacida del remito tocó el stock'::text;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session_x
                       AND reference_id = v_op_cash AND movement_type = 'sale_reversal' AND amount = -2800) THEN
        v_failures := v_failures || 'FAIL (o): falta la compensación de caja'::text;
      END IF;
      IF (SELECT status FROM public.sales_orders WHERE id = v_order_cash) <> 'canceled'
         OR EXISTS (SELECT 1 FROM public.sales WHERE operation_id = v_op_cash) THEN
        v_failures := v_failures || 'FAIL (o): la orden no quedó canceled o quedaron filas sales'::text;
      END IF;
      IF pg_temp.rc_status(v_dn_cash) <> 'issued'
         OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'delivery_note_sale'
                          AND document_id = v_dn_cash AND from_status = 'converted' AND to_status = 'issued'
                          AND performed_by = v_owner_a AND reason = format('Venta eliminada (operación %s)', v_op_cash)) THEN
        v_failures := v_failures || format('FAIL (o): el remito no volvió a issued con historial converted->issued y motivo (estado %s)', pg_temp.rc_status(v_dn_cash));
      END IF;
      IF (public._delivery_note_payload(v_dn_cash)->>'converted_sales_order_id') IS NOT NULL THEN
        v_failures := v_failures || 'FAIL (o): el payload del remito reabierto sigue apuntando a la venta cancelada'::text;
      END IF;
      -- Reconvertir: el índice parcial deja crear otra orden viva.
      v_r := pg_temp.rc_convert(v_tag || 'reconvert', v_dn_cash, 1, v_pm_credit);
      IF v_r NOT LIKE 'OK|%' OR pg_temp.rc_status(v_dn_cash) <> 'converted'
         OR pg_temp.rc_stock(v_p1, v_x) <> v_s1 THEN
        v_failures := v_failures || format('FAIL (o): reconvertir el remito reabierto falló o tocó stock: %s', v_r);
      ELSE
        v_order_re := (substr(v_r, 4)::jsonb->>'sales_order_id')::uuid;
        v_op_re := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
      END IF;
    END IF;

    -- Borrar la venta a crédito compensa la cuenta corriente y reabre su remito.
    v_s2 := pg_temp.rc_stock(v_p2, v_x);
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_credit));
    IF v_txt <> 'OK' OR pg_temp.rc_status(v_dn_credit) <> 'issued' OR pg_temp.rc_stock(v_p2, v_x) <> v_s2
       OR (SELECT COALESCE(sum(amount), 0) FROM public.customer_account_movements
           WHERE account_id = v_account_a AND movement_type = 'credit_note') = 0 THEN
      v_failures := v_failures || format('FAIL (o): borrar la venta a crédito (compensación, remito issued, stock): %s', v_txt);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (o): sin ventas cash y crédito no se puede probar el borrado'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (o): borrar la venta compensa caja o cuenta corriente, cancela la orden, deja el stock idéntico y devuelve el remito a issued con historial y motivo; reconvertir funciona; el vendedor no borra.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (p) borrar la venta con la sucursal del remito desactivada / cerrada
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_op_transfer IS NOT NULL THEN
    SET session_replication_role = replica;
    UPDATE public.branches SET is_active = false WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    v_before := pg_temp.rc_effects(v_account_a);
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    v_after := pg_temp.rc_effects(v_account_a);
    IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' OR v_before IS DISTINCT FROM v_after
       OR pg_temp.rc_status(v_dn_transfer) <> 'converted'
       OR (SELECT status FROM public.sales_orders WHERE id = v_order_transfer) <> 'confirmed' THEN
      v_failures := v_failures || format('FAIL (p): sucursal desactivada debía dar P0422 delivery_note_branch_inactive sin efectos: %s (%s -> %s)', v_txt, v_before, v_after);
    END IF;
    SET session_replication_role = replica;
    UPDATE public.branches SET is_active = true, status = 'closed', closed_at = now() WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    v_after := pg_temp.rc_effects(v_account_a);
    IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' OR v_before IS DISTINCT FROM v_after THEN
      v_failures := v_failures || format('FAIL (p): sucursal cerrada debía dar P0422 delivery_note_branch_inactive sin efectos: %s', v_txt);
    END IF;
    SET session_replication_role = replica;
    UPDATE public.branches SET status = 'active', closed_at = NULL WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    -- Reactivada, el borrado procede y compensa el banco.
    SELECT count(*) INTO v_n FROM public.bank_movements WHERE account_id = v_account_a;
    v_txt := pg_temp.rc_err(format('SELECT public.rpc_delete_sale_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    IF v_txt <> 'OK' OR pg_temp.rc_status(v_dn_transfer) <> 'issued'
       OR (SELECT count(*) FROM public.bank_movements WHERE account_id = v_account_a) <> v_n + 1 THEN
      v_failures := v_failures || format('FAIL (p): con la sucursal reactivada el borrado debía proceder y compensar el banco: %s', v_txt);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (p): sin venta por transferencia no se puede probar el borrado con sucursal inactiva'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (p): borrar la venta con la sucursal del remito desactivada o cerrada -> P0422 delivery_note_branch_inactive sin efectos; reactivada, procede.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (s) invariante: ninguna fila sales de una venta nacida de remito tiene
  -- movimiento de stock, y el ledger de los remitos cuadra.
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF EXISTS (SELECT 1 FROM public.stock_movements sm
             JOIN public.sales s ON s.id = sm.reference_id
             JOIN public.sales_orders so ON so.sale_operation_id = s.operation_id
             WHERE so.account_id = v_account_a AND so.source_delivery_note_id IS NOT NULL) THEN
    v_failures := v_failures || 'FAIL (s): una venta nacida de un remito tiene movimientos de stock propios'::text;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.delivery_notes dn
    WHERE dn.account_id = v_account_a AND dn.status IN ('issued', 'converted')
      AND EXISTS (
        SELECT 1 FROM public.delivery_note_items di WHERE di.delivery_note_id = dn.id
        GROUP BY di.product_id
        HAVING sum(di.quantity_base) <> -(SELECT COALESCE(sum(sm.quantity_delta), 0) FROM public.stock_movements sm
                                           WHERE sm.reference_id = dn.id AND sm.product_id = di.product_id))) THEN
    v_failures := v_failures || 'FAIL (s): el ledger de un remito vivo no cuadra con lo que retienen sus líneas'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (s): ninguna venta nacida de remito tiene movimientos propios y el ledger de cada remito vivo cuadra con sus líneas.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rc_as(NULL);
  SET session_replication_role = replica;
  DELETE FROM public.cash_movements WHERE session_id IN (
    SELECT cs.id FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
  DELETE FROM public.cash_sessions WHERE cashbox_id IN (
    SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = ANY (v_accounts));
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
  DELETE FROM public.points_of_sale WHERE account_id = ANY (v_accounts);
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

  IF EXISTS (SELECT 1 FROM public.delivery_notes WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.sales_orders WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.sales WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.stock_movements WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.events WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.fiscal_documents WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.cash_sessions WHERE id = v_session_x)
     OR EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = ANY (v_users))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE REMITO-A-VENTA FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE REMITO-A-VENTA PASSED: núcleo con origen de remito sin doble descuento, 10 orígenes inválidos, conversión cash/credit/transfer con snapshots del remito, guards, idempotencia, roles, borrado que reabre el remito sin tocar stock, edición bloqueada y regresiones — residuo cero.';

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
        DELETE FROM public.points_of_sale WHERE account_id = ANY (v_accounts);
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
    RAISE EXCEPTION 'GATE REMITO-A-VENTA FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (u) Introspección: ACLs, una sola definición y forma de los cuerpos ─────
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_sig  text;
  v_src  text;
  v_acl  text;
BEGIN
  -- La RPC nueva: SECURITY DEFINER, authenticated sí, anon/PUBLIC no.
  IF to_regprocedure('public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)') IS NULL THEN
    v_bad := v_bad || 'rpc_convert_delivery_note_to_sale no existe con la firma de D7'::text;
  ELSE
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_convert_delivery_note_to_sale'
          AND pronamespace = 'public'::regnamespace) <> 1 THEN
      v_bad := v_bad || 'rpc_convert_delivery_note_to_sale tiene más de una definición'::text;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure) THEN
      v_bad := v_bad || 'rpc_convert_delivery_note_to_sale no es SECURITY DEFINER'::text;
    END IF;
  END IF;

  -- Las tres reescritas + la nueva: una definición, authenticated sí, anon no.
  FOREACH v_sig IN ARRAY ARRAY[
    'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)',
    'public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)',
    'public.rpc_delete_sale_operation(uuid,uuid,text)',
    'public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'
  ] LOOP
    IF to_regprocedure(v_sig) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_sig);
      CONTINUE;
    END IF;
    IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
      v_bad := v_bad || format('%s sin EXECUTE para authenticated', v_sig);
    END IF;
    IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      v_bad := v_bad || format('%s con EXECUTE para anon', v_sig);
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('_c29_confirm_order_core', 'rpc_delete_sale_operation', 'rpc_atomic_update_sale_operation')) <> 3 THEN
    v_bad := v_bad || 'alguna de las tres funciones reescritas tiene más de una definición'::text;
  END IF;

  -- Núcleo: la rama decide por la columna persistida de la orden.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure;
  IF position('v_order.source_delivery_note_id' IN v_src) = 0
     OR position('delivery_note_order_mismatch' IN v_src) = 0
     OR position('v_from_delivery_note' IN v_src) = 0
     OR position('EXCEPT ALL' IN v_src) = 0
     OR position('v_item.unit_cost_snapshot' IN v_src) = 0 THEN
    v_bad := v_bad || '_c29_confirm_order_core no tiene la rama v_from_delivery_note de D7'::text;
  END IF;
  IF position('p_skip_stock' IN v_src) > 0 THEN
    v_bad := v_bad || '_c29_confirm_order_core expone un parámetro de salto de stock (prohibido por D7)'::text;
  END IF;

  -- Borrado: guard de sucursal ANTES del guard fiscal; reversa saltada; reapertura.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_delete_sale_operation(uuid,uuid,text)'::regprocedure;
  IF position('delivery_note_branch_inactive' IN v_src) = 0
     OR position('delivery_note_branch_inactive' IN v_src) > position('_fiscal_void_pending_for_sale_edit' IN v_src)
     OR position('IF v_source_dn IS NULL THEN' IN v_src) = 0
     OR position('IF v_source_dn IS NULL THEN' IN v_src) > position('PERFORM public.rpc_reverse_stock_movement' IN v_src)
     OR position('''converted'', ''issued''' IN v_src) = 0 THEN
    v_bad := v_bad || 'rpc_delete_sale_operation no tiene el guard de sucursal antes del fiscal, el salto de la reversa o la reapertura del remito'::text;
  END IF;

  -- Edición: P0423 ANTES de la anulación fiscal.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean)'::regprocedure;
  IF position('delivery_note_sale_locked' IN v_src) = 0
     OR position('delivery_note_sale_locked' IN v_src) > position('_fiscal_void_pending_for_sale_edit' IN v_src)
     OR position('delivery_note_sale_locked' IN v_src) < position('client_not_found' IN v_src) THEN
    v_bad := v_bad || 'rpc_atomic_update_sale_operation no tiene el P0423 delivery_note_sale_locked entre el guard de cliente y la anulación fiscal'::text;
  END IF;

  -- Conversión: lock del remito -> idempotencia -> núcleo -> transición.
  IF to_regprocedure('public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)') IS NOT NULL THEN
    SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
    WHERE oid = 'public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure;
    IF NOT (position('FOR UPDATE' IN v_src) > 0
            AND position('FOR UPDATE' IN v_src) < position('operation_idempotency' IN v_src)
            AND position('operation_idempotency' IN v_src) < position('_c29_confirm_order_core' IN v_src)
            AND position('_c29_confirm_order_core' IN v_src) < position('''issued'', ''converted''' IN v_src)) THEN
      v_bad := v_bad || 'rpc_convert_delivery_note_to_sale no respeta el orden lock -> idempotencia -> núcleo -> transición'::text;
    END IF;
    IF position('FROM public.products' IN v_src) > 0 THEN
      v_bad := v_bad || 'rpc_convert_delivery_note_to_sale lee o bloquea products (la conversión no lockea productos, D7)'::text;
    END IF;
  END IF;

  -- Columna, FK diferida al final de la sentencia e índice único parcial.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                   AND table_name = 'sales_orders' AND column_name = 'source_delivery_note_id') THEN
    v_bad := v_bad || 'falta sales_orders.source_delivery_note_id'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'public.sales_orders'::regclass AND c.contype = 'f'
                   AND c.confrelid = 'public.delivery_notes'::regclass AND c.confdeltype = 'a') THEN
    v_bad := v_bad || 'falta la FK sales_orders.source_delivery_note_id -> delivery_notes ON DELETE NO ACTION'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'sales_orders'
                   AND indexdef LIKE 'CREATE UNIQUE INDEX%(source_delivery_note_id)%'
                   AND indexdef LIKE '%source_delivery_note_id IS NOT NULL%'
                   AND indexdef LIKE '%<> ''canceled''%') THEN
    v_bad := v_bad || 'falta el índice único parcial por source_delivery_note_id (no cancelado)'::text;
  END IF;

  -- Catálogo: las 4 filas de delivery_note_sale con sus roles.
  IF (SELECT count(*) FROM public.document_status_transitions WHERE document_type = 'delivery_note_sale') <> 4
     OR NOT EXISTS (SELECT 1 FROM public.document_status_transitions WHERE document_type = 'delivery_note_sale'
                      AND from_status = 'issued' AND to_status = 'converted' AND NOT requires_reason AND NOT is_terminal_to
                      AND allowed_role @> ARRAY['seller','cashier','admin','owner'] AND allowed_role <@ ARRAY['seller','cashier','admin','owner'])
     OR NOT EXISTS (SELECT 1 FROM public.document_status_transitions WHERE document_type = 'delivery_note_sale'
                      AND from_status = 'converted' AND to_status = 'issued' AND allowed_role IS NULL
                      AND NOT requires_reason AND NOT is_terminal_to) THEN
    v_bad := v_bad || 'el catálogo delivery_note_sale no tiene las filas issued->converted {seller,cashier,admin,owner} y converted->issued (sistema)'::text;
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE REMITO-A-VENTA (u) FAILED:\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (u): introspección — ACLs, una definición, rama del núcleo, guard de sucursal antes del fiscal y salto de la reversa en el borrado, P0423 antes del fiscal en la edición, orden de la conversión, columna/FK/índice y catálogo de 4 filas.';
END $$;
