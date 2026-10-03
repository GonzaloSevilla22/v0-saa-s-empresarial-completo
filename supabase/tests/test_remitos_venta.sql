-- =============================================================================
-- test_remitos_venta.sql — Gate de comportamiento de la TANDA A de
-- `remitos-venta` (migración 20261069000001_remitos_venta.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de
-- verdad. Este archivo ejecuta, contra Postgres real y con usuarios reales
-- (owner, admin, seller, stock, cashier y viewer con membresía en
-- account_members y roles en account_member_roles), las RPCs nuevas
-- rpc_create_sale_delivery_note, rpc_update_delivery_note,
-- rpc_cancel_delivery_note y rpc_get_delivery_note, los guards de unidad
-- reescritos (fn_product_base_unit_guard / fn_uom_in_use_guard), el guard de
-- baja de sucursal (_branch_assert_empty) y la regresión de
-- _quote_validate_items (que pasa a llamar a _assert_document_product).
--
-- Bloques (design.md §D16, tasks.md 1.1 / 1.7 / 1.8 / 1.9):
--   (a) emisión: stock − por par producto-sucursal, movimiento
--       sale/delivery_note con quantity_before/after y costo congelado,
--       normalización 450 g -> 0,45 kg, total del servidor, número R
--       correlativo e independiente del P de presupuestos y de otra cuenta,
--       historial NULL -> issued con el creador, payload.
--   (b) rechazos con su código y cero efectos (sin remito, número no
--       consumido, stock intacto, sin fila de idempotencia); faltante P0409
--       (también dos líneas del mismo producto controladas juntas).
--   (c) idempotencia: misma clave -> un remito, un descuento, replayed;
--       otra persona con la misma clave -> remito propio; clave ya usada por
--       otro operation_kind no choca; fila cuyo operation_id no es un remito
--       de sus cuentas -> P0409 idempotency_key_conflict.
--   (d) roles: cashier P0403, viewer P0401; stock emite y edita, no anula.
--   (e) edición: sólo precio sin movimientos; A=2/B=1 -> A=2/B=3 con un solo
--       par espejo sobre B y cero sobre A; aumento; faltante sobre el neto;
--       reducción con la sucursal en 0; cambio de producto; cambio de
--       sucursal; snapshot acarreado (4 columnas, iva incluido); producto
--       dado de baja conservado / aumentado / reducido / trasladado de
--       sucursal; producto dado de baja nuevo -> P0404; sucursal vigente
--       desactivada o cerrada -> P0422; versión vieja; anulado.
--   (f) fila forjada en stock_movements por PostgREST: la edición y la
--       anulación devuelven sólo lo que retienen las líneas.
--   (g) anulación: motivo, roles, versión, reposición, historial, segunda
--       anulación, edición de un anulado.
--   (h) invariante Σ quantity_delta por par = Δ branch_stock = -held, neto 0.
--   (i) PostgREST: sin INSERT/UPDATE/DELETE directo ni EXECUTE de helpers;
--       la RPC funciona como authenticated.
--   (j) guards de unidad con líneas creadas por la RPC real.
--   (k) baja de sucursal con remito pendiente -> P0428
--       branch_has_pending_delivery_notes (disparador, rpc_deactivate_branch,
--       rpc_close_branch); un remito de compra pendiente también bloquea;
--       anulado y vaciado, la baja procede.
--   (l) regresión de _quote_validate_items.
--   (m) nada de caja, banco, cuenta corriente ni eventos.
--   (n) numeración sin huecos.
--   (o) ACLs y catálogo, en bloques DO aparte sin fixtures.
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila con account_id de las cuentas del
-- gate y residuo cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run remitos venta gate").
-- =============================================================================

-- Los helpers de abajo nombran tablas de la migración: sin validar el cuerpo al
-- crearlos, el RED de la tanda A falla por la RPC inexistente (42883).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION pg_temp.rv_as(p_uid uuid) RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.rv_line(p_product uuid, p_qty numeric, p_price numeric,
                                           p_subtotal numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_subtotal);
$f$;

-- Ejecuta una sentencia y devuelve 'OK' o 'SQLSTATE mensaje'. El bloque
-- interno es un subtransacción: un error revierte todo lo que la sentencia
-- escribió.
CREATE OR REPLACE FUNCTION pg_temp.rv_err(p_sql text) RETURNS text
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

-- Huella de todo lo que una escritura del remito puede tocar en la cuenta:
-- comparar antes/después de un rechazo prueba "cero efectos".
CREATE OR REPLACE FUNCTION pg_temp.rv_footprint(p_account uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.delivery_notes WHERE account_id = p_account),
    (SELECT count(*) FROM public.delivery_note_items WHERE account_id = p_account),
    (SELECT count(*) FROM public.stock_movements WHERE account_id = p_account),
    (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    (SELECT COALESCE(max(last_number), 0) FROM public.internal_document_sequences
      WHERE account_id = p_account AND document_type = 'delivery_note_sale'),
    (SELECT count(*) FROM public.operation_idempotency oi
      WHERE oi.operation_kind = 'delivery_note_sale'
        AND oi.user_id IN (SELECT am.user_id FROM public.account_members am WHERE am.account_id = p_account)),
    (SELECT count(*) FROM public.document_status_history WHERE account_id = p_account),
    (SELECT COALESCE(sum(revision), 0) FROM public.delivery_notes WHERE account_id = p_account));
$f$;

-- Emite y devuelve el payload (camino feliz).
CREATE OR REPLACE FUNCTION pg_temp.rv_issue(p_key text, p_client uuid, p_branch uuid, p_items jsonb,
                                            p_address text DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  RETURN public.rpc_create_sale_delivery_note(p_key, p_client, p_branch, p_address, p_notes, p_items);
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_issue_sql(p_key text, p_client uuid, p_branch uuid, p_items jsonb)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_create_sale_delivery_note(%L, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
                p_key, p_client, p_branch, p_items);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_update_sql(p_dn uuid, p_rev integer, p_client uuid, p_branch uuid, p_items jsonb)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_update_delivery_note(%L::uuid, %s, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
                p_dn, COALESCE(p_rev::text, 'NULL'), p_client, p_branch, p_items);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_cancel_sql(p_dn uuid, p_rev integer, p_reason text)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_cancel_delivery_note(%L::uuid, %s, %L)',
                p_dn, COALESCE(p_rev::text, 'NULL'), p_reason);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_rev(p_dn uuid) RETURNS integer
LANGUAGE sql AS $f$ SELECT revision FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p_product AND branch_id = p_branch), 0);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rv_moves(p_dn uuid, p_product uuid DEFAULT NULL) RETURNS bigint
LANGUAGE sql AS $f$
  SELECT count(*) FROM public.stock_movements
  WHERE reference_id = p_dn AND (p_product IS NULL OR product_id = p_product);
$f$;

-- Línea vigente de un producto en el remito, para los items del payload de edición.
CREATE OR REPLACE FUNCTION pg_temp.rv_items(p_dn uuid) RETURNS jsonb
LANGUAGE sql AS $f$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', product_id, 'unit_id', unit_id, 'quantity', quantity,
                                               'price', price, 'subtotal', subtotal) ORDER BY line_no), '[]'::jsonb)
  FROM public.delivery_note_items WHERE delivery_note_id = p_dn;
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';

  -- Usuarios
  v_owner_a       uuid := gen_random_uuid();
  v_owner_b       uuid := gen_random_uuid();
  v_admin         uuid := gen_random_uuid();
  v_seller        uuid := gen_random_uuid();
  v_stocker       uuid := gen_random_uuid();
  v_cashier       uuid := gen_random_uuid();
  v_viewer        uuid := gen_random_uuid();
  v_users         uuid[];
  v_accounts      uuid[];
  v_account_a     uuid;
  v_account_b     uuid;
  v_member        uuid;

  -- Sucursales
  v_x uuid; v_y uuid; v_w uuid; v_q uuid; v_v uuid; v_v2 uuid; v_closed uuid; v_branch_b uuid;
  -- Clientes / proveedor
  v_client uuid; v_client2 uuid; v_client_dead uuid; v_client_b uuid; v_supplier uuid;
  -- Unidades
  v_u uuid; v_kg uuid; v_g uuid; v_bulto uuid; v_unit_b uuid;
  -- Productos
  v_pa uuid; v_pb uuid; v_pkg uuid; v_pc uuid; v_pdel uuid; v_pi uuid; v_pnobase uuid; v_pbulto uuid;
  v_pv uuid; v_pw uuid; v_pq uuid; v_parent uuid; v_variant uuid; v_pdead uuid; v_pother uuid;

  v_today   date := public.reporting_local_today();
  v_r       jsonb;
  v_r2      jsonb;
  v_txt     text;
  v_fp      text;
  v_fp2     text;
  v_n       bigint;
  v_n2      bigint;
  v_val     numeric;
  v_val2    numeric;
  v_dn1 uuid; v_dn2 uuid; v_dn3 uuid; v_dn4 uuid; v_dn5 uuid; v_dn6 uuid; v_dn7 uuid; v_dnv uuid; v_dnb uuid;
  v_dn_idem uuid; v_dn_tmp uuid;
  v_rec     RECORD;
  v_state   text;
  v_msg     text;
  v_table   text;
  v_counts_before text;
  v_counts_after  text;
  v_items   jsonb;
  v_number_expected bigint := 0;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_admin, v_seller, v_stocker, v_cashier, v_viewer];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'remitos-venta-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate Remitos ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_admin, 'admin'), (v_seller, 'seller'),
               (v_stocker, 'stock'), (v_cashier, 'cashier'), (v_viewer, 'viewer')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  -- Empleados de A con UNA sola membresía (current_account_ids determinista).
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
  WHERE member_id IN (SELECT id FROM public.account_members
                      WHERE user_id IN (v_admin, v_seller, v_stocker, v_cashier, v_viewer));
  DELETE FROM public.account_members WHERE user_id IN (v_admin, v_seller, v_stocker, v_cashier, v_viewer);
  SET session_replication_role = DEFAULT;

  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_admin, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'admin');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_stocker, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'stock');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'cashier');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'viewer');

  SELECT id INTO v_x FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  IF v_x IS NULL OR v_branch_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RV Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RV W', TRUE, 'active', now(), now() + interval '2 minutes') RETURNING id INTO v_w;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RV Q', TRUE, 'active', now(), now() + interval '3 minutes') RETURNING id INTO v_q;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RV V', TRUE, 'active', now(), now() + interval '4 minutes') RETURNING id INTO v_v;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RV V2', TRUE, 'active', now(), now() + interval '5 minutes') RETURNING id INTO v_v2;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (v_account_a, 'Gate RV Cerrada', TRUE, 'closed', now(), now(), now() + interval '6 minutes') RETURNING id INTO v_closed;

  INSERT INTO public.clients (user_id, account_id, name, phone) VALUES (v_owner_a, v_account_a, 'Cliente Gate RV', '2615550303') RETURNING id INTO v_client;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate RV 2') RETURNING id INTO v_client2;
  INSERT INTO public.clients (user_id, account_id, name, deleted_at) VALUES (v_owner_a, v_account_a, 'Cliente Gate RV Baja', now()) RETURNING id INTO v_client_dead;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_b, v_account_b, 'Cliente Gate RV B') RETURNING id INTO v_client_b;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, 'Proveedor Gate RV') RETURNING id INTO v_supplier;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad RV', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo RV', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo RV', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Bulto RV', 'bto', 'unit', 1, false) RETURNING id INTO v_bulto;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_b, 'Unidad RV B', 'u', 'unit', 1, false) RETURNING id INTO v_unit_b;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV A', 'GRV-A', 100, 150, v_u) RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV B', 'GRV-B', 50, 80, v_u) RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV Kg', 'GRV-KG', 1000, 2000, v_kg) RETURNING id INTO v_pkg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV C', 'GRV-C', 10, 20, v_u) RETURNING id INTO v_pc;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV Del', 'GRV-DEL', 7, 14, v_u) RETURNING id INTO v_pdel;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV Invariante', 'GRV-I', 5, 10, v_u) RETURNING id INTO v_pi;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate RV Sin Base', 'GRV-NB', 1, 2) RETURNING id INTO v_pnobase;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate RV Bulto', 'GRV-BTO', 1, 2) RETURNING id INTO v_pbulto;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV V', 'GRV-V', 1, 2, v_u) RETURNING id INTO v_pv;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV W', 'GRV-W', 1, 2, v_u) RETURNING id INTO v_pw;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RV Q', 'GRV-Q', 1, 2, v_u) RETURNING id INTO v_pq;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_owner_a, v_account_a, 'Gate RV Padre', 'GRV-PADRE', 0, 0, 'variant_only') RETURNING id INTO v_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_owner_a, v_account_a, 'Gate RV Variante', 'GRV-VAR', 10, 20, v_parent, true) RETURNING id INTO v_variant;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, deleted_at)
  VALUES (v_owner_a, v_account_a, 'Gate RV Muerto', 'GRV-DEAD', 1, 2, v_u, now()) RETURNING id INTO v_pdead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'GRV SECRETO DE B', 'GRV-SECRETO-B', 777, 999) RETURNING id INTO v_pother;

  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pa,      v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pa,      v_y, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pb,      v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pkg,     v_x, 1);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pc,      v_x, 3);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pdel,    v_x, 2);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pi,      v_x, 20);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pi,      v_y, 20);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pnobase, v_x, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pbulto,  v_x, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pv,      v_v, 2);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pw,      v_w, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pq,      v_q, 5);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_variant, v_x, 5);

  -- (m) contadores de caja / banco / cuenta corriente / eventos al empezar.
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a),
    (SELECT count(*) FROM public.bank_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.customer_account_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.events WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.sales WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.sales_orders WHERE account_id = v_account_a))
  INTO v_counts_before;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) Emisión feliz (vendedor)
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  v_r := pg_temp.rv_issue('rv-a-1', v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pa, 2, 150, 300), pg_temp.rv_line(v_pb, 1, 80, 80),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g)),
    'Av. Siempre Viva 742', 'Entregar por la tarde');
  v_dn1 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  IF v_dn1 IS NULL THEN
    RAISE EXCEPTION 'GATE REMITOS-VENTA FAILED (a): la emisión no devolvió id: %', v_r;
  END IF;
  IF (v_r->>'number')::bigint IS DISTINCT FROM 1 OR v_r->>'status' <> 'issued' OR v_r->>'direction' <> 'sale'
     OR (v_r->>'replayed')::boolean IS DISTINCT FROM false OR (v_r->>'total')::numeric IS DISTINCT FROM 1280.00
     OR (v_r->>'issued_on')::date IS DISTINCT FROM v_today OR (v_r->>'revision')::int IS DISTINCT FROM 1
     OR v_r->>'client_name' IS DISTINCT FROM 'Cliente Gate RV' OR v_r->>'branch_name' IS NULL
     OR v_r->>'delivery_address' IS DISTINCT FROM 'Av. Siempre Viva 742'
     OR jsonb_array_length(COALESCE(v_r->'items', '[]')) <> 3 THEN
    v_failures := v_failures || format('FAIL (a): payload de la emisión inesperado: %s', v_r);
  END IF;
  IF pg_temp.rv_stock(v_pa, v_x) <> 8 OR pg_temp.rv_stock(v_pb, v_x) <> 9 OR pg_temp.rv_stock(v_pkg, v_x) <> 0.55 THEN
    v_failures := v_failures || format('FAIL (a): stock tras emitir A/B/Kg = %s/%s/%s (esperado 8/9/0.55)',
      pg_temp.rv_stock(v_pa, v_x), pg_temp.rv_stock(v_pb, v_x), pg_temp.rv_stock(v_pkg, v_x));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND type = 'sale' AND reference_type = 'delivery_note' AND branch_id = v_x
    AND performed_by = v_seller AND account_id = v_account_a
    AND ((product_id = v_pa AND quantity_delta = -2 AND quantity_before = 10 AND quantity_after = 8 AND unit_cost_snapshot = 100 AND product_name = 'Gate RV A')
      OR (product_id = v_pb AND quantity_delta = -1 AND quantity_before = 10 AND quantity_after = 9 AND unit_cost_snapshot = 50)
      OR (product_id = v_pkg AND quantity_delta = -0.45 AND quantity_before = 1 AND quantity_after = 0.55 AND unit_cost_snapshot = 1000));
  IF v_n <> 3 OR pg_temp.rv_moves(v_dn1) <> 3 THEN
    v_failures := v_failures || format('FAIL (a): se esperaban 3 movimientos sale/delivery_note exactos por par, hay %s de %s', v_n, pg_temp.rv_moves(v_dn1));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND jsonb_array_length(metadata->'delivery_note_item_ids') = 1;
  IF v_n <> 3 THEN
    v_failures := v_failures || 'FAIL (a): cada movimiento debía llevar metadata.delivery_note_item_ids'::text;
  END IF;
  SELECT count(*) INTO v_n FROM public.delivery_note_items
  WHERE delivery_note_id = v_dn1 AND account_id = v_account_a
    AND ((product_id = v_pa AND quantity_base = 2 AND name_snapshot = 'Gate RV A' AND sku_snapshot = 'GRV-A' AND unit_cost_snapshot = 100 AND line_no = 1)
      OR (product_id = v_pb AND quantity_base = 1 AND line_no = 2)
      OR (product_id = v_pkg AND quantity = 450 AND unit_id = v_g AND quantity_base = 0.45 AND price = 2 AND subtotal = 900 AND line_no = 3));
  IF v_n <> 3 THEN
    v_failures := v_failures || 'FAIL (a): las líneas no guardaron quantity_base/snapshots/line_no esperados'::text;
  END IF;
  SELECT count(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'delivery_note_sale' AND document_id = v_dn1 AND from_status IS NULL
    AND to_status = 'issued' AND performed_by = v_seller;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (a): la emisión debía registrar NULL -> issued (delivery_note_sale) con el creador'::text;
  END IF;
  -- rpc_get_delivery_note: el mismo payload, historial incluido.
  v_r2 := public.rpc_get_delivery_note(v_dn1);
  IF (v_r2->>'id')::uuid IS DISTINCT FROM v_dn1 OR jsonb_array_length(COALESCE(v_r2->'history', '[]')) <> 1
     OR jsonb_array_length(COALESCE(v_r2->'items', '[]')) <> 3 THEN
    v_failures := v_failures || format('FAIL (a): rpc_get_delivery_note inesperado: %s', v_r2);
  END IF;
  -- Número independiente del P de presupuestos: el primer presupuesto de A es el 1.
  v_r2 := public.rpc_create_quote(v_client, NULL, NULL, NULL, jsonb_build_array(
    jsonb_build_object('product_id', v_pa, 'unit_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1, 'description', NULL)));
  IF (v_r2->>'number')::bigint IS DISTINCT FROM 1 THEN
    v_failures := v_failures || format('FAIL (a): el primer presupuesto de A debía ser el 1 (secuencia propia), es %s', v_r2->>'number');
  END IF;
  -- Otra cuenta numera desde 1.
  PERFORM public.c21_apply_branch_stock_delta(v_account_b, v_pother, v_branch_b, 3);
  PERFORM pg_temp.rv_as(v_owner_b);
  v_r2 := pg_temp.rv_issue('rv-b-1', v_client_b, v_branch_b, jsonb_build_array(pg_temp.rv_line(v_pother, 1, 10, 10)));
  v_dnb := (v_r2->>'id')::uuid;
  IF (v_r2->>'number')::bigint IS DISTINCT FROM 1 THEN
    v_failures := v_failures || format('FAIL (a): el primer remito de B debía ser el 1, es %s', v_r2->>'number');
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) Rechazos con su código y cero efectos
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  v_items := jsonb_build_array(pg_temp.rv_line(v_pa, 1, 10, 10));
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('sin clave',            pg_temp.rv_issue_sql('', v_client, v_x, v_items),                          'P0400 idempotency_key_required%'),
      ('sin cliente',          pg_temp.rv_issue_sql('rv-b-1', NULL, v_x, v_items),                        'P0400 delivery_note_client_required%'),
      ('cliente ajeno',        pg_temp.rv_issue_sql('rv-b-2', v_client_b, v_x, v_items),                  'P0404 client_not_found%'),
      ('cliente de baja',      pg_temp.rv_issue_sql('rv-b-3', v_client_dead, v_x, v_items),               'P0404 client_not_found%'),
      ('sin sucursal',         pg_temp.rv_issue_sql('rv-b-4', v_client, NULL, v_items),                   'P0400 delivery_note_branch_required%'),
      ('sucursal ajena',       pg_temp.rv_issue_sql('rv-b-5', v_client, v_branch_b, v_items),             'P0404 branch_not_found%'),
      ('sucursal cerrada',     pg_temp.rv_issue_sql('rv-b-6', v_client, v_closed, v_items),               'P0422 branch_closed%'),
      ('sin líneas',           pg_temp.rv_issue_sql('rv-b-7', v_client, v_x, '[]'::jsonb),                'P0400 delivery_note_items_required%'),
      ('línea sin producto',   pg_temp.rv_issue_sql('rv-b-8', v_client, v_x,
                                 jsonb_build_array(jsonb_build_object('product_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1))),
                                                                                                          'P0400 delivery_note_product_required%'),
      ('producto ajeno',       pg_temp.rv_issue_sql('rv-b-9', v_client, v_x,
                                 jsonb_build_array(pg_temp.rv_line(v_pa, 1, 1, 1), pg_temp.rv_line(v_pother, 1, 1, 1))),
                                                                                                          'P0404 product_not_found%'),
      ('producto de baja',     pg_temp.rv_issue_sql('rv-b-10', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pdead, 1, 1, 1))),
                                                                                                          'P0404 product_not_found%'),
      ('producto padre',       pg_temp.rv_issue_sql('rv-b-11', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_parent, 1, 1, 1))),
                                                                                                          'P0400 product_is_parent%'),
      ('unidad incompatible',  pg_temp.rv_issue_sql('rv-b-12', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 1, 1, v_kg))),
                                                                                                          'P0400 unit_type_mismatch%'),
      ('unidad de otra cuenta', pg_temp.rv_issue_sql('rv-b-13', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 1, 1, v_unit_b))),
                                                                                                          'P0404 Unit of measure not found%'),
      ('cantidad cero',        pg_temp.rv_issue_sql('rv-b-14', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 0, 1, 0))),
                                                                                                          'P0400 delivery_note_line_invalid_quantity%'),
      ('precio negativo',      pg_temp.rv_issue_sql('rv-b-15', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 1, -1, 0))),
                                                                                                          'P0400 delivery_note_line_invalid_price%'),
      ('faltante',             pg_temp.rv_issue_sql('rv-b-16', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 100, 1, 100))),
                                                                                                          'P0409 stock_insuficiente%'),
      ('dos líneas juntas',    pg_temp.rv_issue_sql('rv-b-17', v_client, v_x,
                                 jsonb_build_array(pg_temp.rv_line(v_pb, 5, 1, 5), pg_temp.rv_line(v_pb, 5, 1, 5))),
                                                                                                          'P0409 stock_insuficiente%')
    ) AS t(label, sql, expected)
  LOOP
    v_fp := pg_temp.rv_footprint(v_account_a);
    v_txt := pg_temp.rv_err(v_rec.sql);
    v_fp2 := pg_temp.rv_footprint(v_account_a);
    IF v_txt NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (b) %s: se esperaba %s, salió %s', v_rec.label, v_rec.expected, v_txt);
    END IF;
    IF v_fp IS DISTINCT FROM v_fp2 THEN
      v_failures := v_failures || format('FAIL (b) %s: dejó efectos (%s -> %s)', v_rec.label, v_fp, v_fp2);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = v_seller AND idempotency_key LIKE 'rv-b-%') THEN
    v_failures := v_failures || 'FAIL (b): un rechazo dejó su fila de idempotencia'::text;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) Idempotencia de la emisión
  -- ═══════════════════════════════════════════════════════════════════════
  v_val := pg_temp.rv_stock(v_pb, v_x);
  v_r := pg_temp.rv_issue('rv-idem-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 80, 80)));
  v_dn_idem := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  v_r2 := pg_temp.rv_issue('rv-idem-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 80, 80)));
  IF (v_r2->>'id')::uuid IS DISTINCT FROM v_dn_idem OR (v_r2->>'replayed')::boolean IS DISTINCT FROM true
     OR (v_r->>'replayed')::boolean IS DISTINCT FROM false THEN
    v_failures := v_failures || format('FAIL (c): la misma clave debía devolver el mismo remito con replayed=true: %s / %s', v_r, v_r2);
  END IF;
  IF pg_temp.rv_stock(v_pb, v_x) <> v_val - 1 OR pg_temp.rv_moves(v_dn_idem) <> 1 THEN
    v_failures := v_failures || format('FAIL (c): el replay volvió a descontar (stock %s -> %s, movimientos %s)',
      v_val, pg_temp.rv_stock(v_pb, v_x), pg_temp.rv_moves(v_dn_idem));
  END IF;
  -- Otra persona con la misma clave: remito propio (la clave es por usuario).
  PERFORM pg_temp.rv_as(v_admin);
  v_r2 := pg_temp.rv_issue('rv-idem-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 80, 80)));
  v_number_expected := v_number_expected + 1;
  IF (v_r2->>'id')::uuid = v_dn_idem OR (v_r2->>'replayed')::boolean IS DISTINCT FROM false THEN
    v_failures := v_failures || 'FAIL (c): la misma clave de OTRO usuario debía crear un remito propio'::text;
  END IF;
  -- Clave ya usada por otro operation_kind: no choca.
  INSERT INTO public.operation_idempotency (user_id, operation_kind, idempotency_key, operation_id)
  VALUES (v_seller, 'sale', 'rv-idem-shared', gen_random_uuid());
  PERFORM pg_temp.rv_as(v_seller);
  v_txt := pg_temp.rv_err(pg_temp.rv_issue_sql('rv-idem-shared', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 1, 1))));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (c): una clave usada por otro operation_kind debía emitir, salió %s', v_txt);
  ELSE
    v_number_expected := v_number_expected + 1;
  END IF;
  -- Fila delivery_note_sale cuyo operation_id no es un remito de sus cuentas.
  INSERT INTO public.operation_idempotency (user_id, operation_kind, idempotency_key, operation_id)
  VALUES (v_seller, 'delivery_note_sale', 'rv-idem-forged', v_dnb);
  v_fp := pg_temp.rv_footprint(v_account_a);
  v_txt := pg_temp.rv_err(pg_temp.rv_issue_sql('rv-idem-forged', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 1, 1))));
  IF v_txt NOT LIKE 'P0409 idempotency_key_conflict%' OR v_fp IS DISTINCT FROM pg_temp.rv_footprint(v_account_a) THEN
    v_failures := v_failures || format('FAIL (c): clave apuntando a un remito ajeno -> P0409 idempotency_key_conflict sin efectos, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (d) Roles en la emisión
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_cashier);
  v_txt := pg_temp.rv_err(pg_temp.rv_issue_sql('rv-d-1', v_client, v_x, v_items));
  IF v_txt NOT LIKE 'P0403 insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (d): el cajero no emite (P0403), salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rv_as(v_viewer);
  v_txt := pg_temp.rv_err(pg_temp.rv_issue_sql('rv-d-2', v_client, v_x, v_items));
  IF v_txt NOT LIKE 'P0401 %' THEN
    v_failures := v_failures || format('FAIL (d): el viewer no escribe (P0401), salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) Edición
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  -- e1: sólo el precio de B -> versión +1, total nuevo, ningún movimiento.
  v_r := public.rpc_update_delivery_note(v_dn1, 1, v_client, v_x, 'Av. Siempre Viva 742', NULL,
    jsonb_build_array(pg_temp.rv_line(v_pa, 2, 150, 300), pg_temp.rv_line(v_pb, 1, 90, 90),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g)));
  IF (v_r->>'revision')::int <> 2 OR (v_r->>'total')::numeric <> 1290 OR pg_temp.rv_moves(v_dn1) <> 3
     OR v_r->>'status' <> 'issued' OR v_r->>'notes' IS NOT NULL THEN
    v_failures := v_failures || format('FAIL (e1): editar sólo el precio debía dar revisión 2, total 1290, 3 movimientos y notas vacías: %s (mov %s)', v_r, pg_temp.rv_moves(v_dn1));
  END IF;
  IF EXISTS (SELECT 1 FROM public.document_status_history WHERE document_id = v_dn1 AND from_status IS NOT NULL) THEN
    v_failures := v_failures || 'FAIL (e1): editar no debía escribir historial de estados'::text;
  END IF;
  -- e2: A=2/B=1 -> A=2/B=3: un solo par espejo, sobre B.
  v_val := pg_temp.rv_stock(v_pa, v_x);
  v_val2 := pg_temp.rv_stock(v_pb, v_x);
  PERFORM public.rpc_update_delivery_note(v_dn1, 2, v_client, v_x, NULL, NULL,
    jsonb_build_array(pg_temp.rv_line(v_pa, 2, 150, 300), pg_temp.rv_line(v_pb, 3, 90, 270),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g)));
  IF pg_temp.rv_moves(v_dn1, v_pa) <> 1 OR pg_temp.rv_moves(v_dn1, v_pkg) <> 1 OR pg_temp.rv_moves(v_dn1, v_pb) <> 3
     OR pg_temp.rv_stock(v_pa, v_x) <> v_val OR pg_temp.rv_stock(v_pb, v_x) <> v_val2 - 2 THEN
    v_failures := v_failures || format('FAIL (e2): A=2/B=1 -> A=2/B=3 debía mover sólo B (mov A/B/Kg %s/%s/%s, stock A %s->%s, B %s->%s)',
      pg_temp.rv_moves(v_dn1, v_pa), pg_temp.rv_moves(v_dn1, v_pb), pg_temp.rv_moves(v_dn1, v_pkg),
      v_val, pg_temp.rv_stock(v_pa, v_x), v_val2, pg_temp.rv_stock(v_pb, v_x));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND product_id = v_pb
    AND ((type = 'sale_return' AND reference_type = 'delivery_note_update' AND quantity_delta = 1 AND metadata->>'reverses' = 'delivery_note_edit')
      OR (type = 'sale' AND reference_type = 'delivery_note' AND quantity_delta = -3 AND quantity_before = v_val2 + 1));
  IF v_n <> 2 THEN
    v_failures := v_failures || 'FAIL (e2): el par espejo de B debía ser sale_return/delivery_note_update +1 y sale/delivery_note -3 (reversa antes de aplicar)'::text;
  END IF;
  -- e3: aumento con stock -> par espejo en A.
  v_val := pg_temp.rv_stock(v_pa, v_x);
  PERFORM public.rpc_update_delivery_note(v_dn1, 3, v_client, v_x, NULL, NULL,
    jsonb_build_array(pg_temp.rv_line(v_pa, 4, 150, 600), pg_temp.rv_line(v_pb, 3, 90, 270),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g)));
  IF pg_temp.rv_stock(v_pa, v_x) <> v_val - 2 OR pg_temp.rv_moves(v_dn1, v_pa) <> 3 THEN
    v_failures := v_failures || format('FAIL (e3): aumentar A 2 -> 4 debía descontar 2 más con un par espejo (stock %s -> %s, mov %s)',
      v_val, pg_temp.rv_stock(v_pa, v_x), pg_temp.rv_moves(v_dn1, v_pa));
  END IF;
  -- e4: aumento sin stock -> P0409, cero efectos.
  v_fp := pg_temp.rv_footprint(v_account_a);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn1, 4, v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pa, 1000, 1, 1000), pg_temp.rv_line(v_pb, 3, 90, 270),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g))));
  IF v_txt NOT LIKE 'P0409 stock_insuficiente%' OR v_fp IS DISTINCT FROM pg_temp.rv_footprint(v_account_a) THEN
    v_failures := v_failures || format('FAIL (e4): aumento sin stock -> P0409 sin efectos, salió %s', v_txt);
  END IF;
  -- e5: snapshot acarreado (las 4 columnas) para el producto que sigue.
  UPDATE public.products SET name = 'Gate RV A renombrado', sku = 'GRV-A2', cost = 999 WHERE id = v_pa;
  UPDATE public.delivery_note_items SET iva_rate_snapshot = 21 WHERE delivery_note_id = v_dn1 AND product_id = v_pa;
  PERFORM public.rpc_update_delivery_note(v_dn1, 4, v_client2, v_x, NULL, 'nota nueva',
    jsonb_build_array(pg_temp.rv_line(v_pa, 4, 151, 604), pg_temp.rv_line(v_pb, 3, 90, 270),
                      pg_temp.rv_line(v_pkg, 450, 2, 900, v_g), pg_temp.rv_line(v_pc, 1, 20, 20)));
  SELECT count(*) INTO v_n FROM public.delivery_note_items
  WHERE delivery_note_id = v_dn1 AND product_id = v_pa AND name_snapshot = 'Gate RV A' AND sku_snapshot = 'GRV-A'
    AND unit_cost_snapshot = 100 AND iva_rate_snapshot = 21 AND price = 151;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (e5): la línea de A debía acarrear nombre, SKU, costo e IVA de la línea vieja'::text;
  END IF;
  SELECT count(*) INTO v_n FROM public.delivery_note_items
  WHERE delivery_note_id = v_dn1 AND product_id = v_pc AND name_snapshot = 'Gate RV C' AND unit_cost_snapshot = 10;
  IF v_n <> 1 OR (SELECT client_id FROM public.delivery_notes WHERE id = v_dn1) <> v_client2 THEN
    v_failures := v_failures || 'FAIL (e5): el producto nuevo debía tomar el snapshot del maestro y el cliente cambiar'::text;
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND product_id = v_pa AND unit_cost_snapshot = 999;
  IF v_n <> 0 THEN
    v_failures := v_failures || 'FAIL (e5): ningún movimiento de A debía tomar el costo nuevo del catálogo'::text;
  END IF;
  -- e6: versión vieja.
  v_fp := pg_temp.rv_footprint(v_account_a);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn1, 4, v_client, v_x, pg_temp.rv_items(v_dn1)));
  IF v_txt NOT LIKE 'P0409 delivery_note_changed%' OR v_fp IS DISTINCT FROM pg_temp.rv_footprint(v_account_a) THEN
    v_failures := v_failures || format('FAIL (e6): versión vieja -> P0409 delivery_note_changed, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn1, NULL, v_client, v_x, pg_temp.rv_items(v_dn1)));
  IF v_txt NOT LIKE 'P0400 delivery_note_revision_required%' THEN
    v_failures := v_failures || format('FAIL (e6): sin versión -> P0400 delivery_note_revision_required, salió %s', v_txt);
  END IF;
  -- e6b: remito de otra cuenta = inexistente.
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dnb, 1, v_client, v_x, v_items));
  v_msg := pg_temp.rv_err(pg_temp.rv_update_sql(gen_random_uuid(), 1, v_client, v_x, v_items));
  IF v_txt NOT LIKE 'P0404 delivery_note_not_found%' OR v_msg NOT LIKE 'P0404 delivery_note_not_found%'
     OR split_part(v_txt, ':', 1) <> split_part(v_msg, ':', 1) THEN
    v_failures := v_failures || format('FAIL (e6b): ajeno e inexistente -> P0404 delivery_note_not_found idénticos, salió %s / %s', v_txt, v_msg);
  END IF;
  v_txt := pg_temp.rv_err(format('SELECT public.rpc_get_delivery_note(%L::uuid)', v_dnb));
  IF v_txt NOT LIKE 'P0404 delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (e6b): rpc_get_delivery_note de otra cuenta -> P0404, salió %s', v_txt);
  END IF;

  -- e7..e9 con el rol stock: reducción con 0, cambio de producto y de sucursal.
  PERFORM pg_temp.rv_as(v_stocker);
  v_r := pg_temp.rv_issue('rv-e-2', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pc, 2, 20, 40)));
  v_dn2 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  IF pg_temp.rv_stock(v_pc, v_x) <> 0 THEN
    v_failures := v_failures || format('FAIL (e7): el stock de C debía quedar en 0 tras emitir, es %s', pg_temp.rv_stock(v_pc, v_x));
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn2, 1, v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pc, 1, 20, 20))));
  IF v_txt <> 'OK' OR pg_temp.rv_stock(v_pc, v_x) <> 1 THEN
    v_failures := v_failures || format('FAIL (e7): reducir con la sucursal en 0 debía funcionar (salió %s, stock C %s)', v_txt, pg_temp.rv_stock(v_pc, v_x));
  END IF;
  v_val := pg_temp.rv_stock(v_pa, v_x);
  PERFORM public.rpc_update_delivery_note(v_dn2, 2, v_client, v_x, NULL, NULL, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 150, 150)));
  IF pg_temp.rv_stock(v_pc, v_x) <> 2 OR pg_temp.rv_stock(v_pa, v_x) <> v_val - 1 THEN
    v_failures := v_failures || format('FAIL (e8): cambiar C por A debía reponer C y descontar A (C %s, A %s -> %s)',
      pg_temp.rv_stock(v_pc, v_x), v_val, pg_temp.rv_stock(v_pa, v_x));
  END IF;
  v_val2 := pg_temp.rv_stock(v_pa, v_y);
  PERFORM public.rpc_update_delivery_note(v_dn2, 3, v_client, v_y, NULL, NULL, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 150, 150)));
  IF pg_temp.rv_stock(v_pa, v_x) <> v_val OR pg_temp.rv_stock(v_pa, v_y) <> v_val2 - 1 THEN
    v_failures := v_failures || format('FAIL (e9): cambiar de sucursal debía trasladar el stock (X %s, Y %s -> %s)',
      pg_temp.rv_stock(v_pa, v_x), v_val2, pg_temp.rv_stock(v_pa, v_y));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn2 AND product_id = v_pa
    AND ((branch_id = v_x AND type = 'sale_return' AND reference_type = 'delivery_note_update' AND quantity_delta = 1)
      OR (branch_id = v_y AND type = 'sale' AND reference_type = 'delivery_note' AND quantity_delta = -1));
  IF v_n <> 2 THEN
    v_failures := v_failures || 'FAIL (e9): el traslado debía dejar la reversa en X y la aplicación en Y'::text;
  END IF;
  -- El rol stock tampoco anula.
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn2, 4, 'no corresponde'));
  IF v_txt NOT LIKE 'P0403 insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (d): el rol stock no anula (P0403), salió %s', v_txt);
  END IF;

  -- e10..e14: producto dado de baja después de emitir.
  PERFORM pg_temp.rv_as(v_seller);
  v_r := pg_temp.rv_issue('rv-e-3', v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 2, 14, 28), pg_temp.rv_line(v_pb, 1, 80, 80)));
  v_dn3 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  UPDATE public.products SET deleted_at = now() WHERE id = v_pdel;   -- stock 0: el guard de baja lo admite
  v_n := pg_temp.rv_moves(v_dn3, v_pdel);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 1, v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 2, 14, 28), pg_temp.rv_line(v_pb, 1, 85, 85))));
  IF v_txt <> 'OK' OR pg_temp.rv_moves(v_dn3, v_pdel) <> v_n
     OR NOT EXISTS (SELECT 1 FROM public.delivery_note_items WHERE delivery_note_id = v_dn3 AND product_id = v_pdel AND name_snapshot = 'Gate RV Del') THEN
    v_failures := v_failures || format('FAIL (e10): editar otra línea con un producto dado de baja debía conservarlo sin movimientos, salió %s', v_txt);
  END IF;
  v_fp := pg_temp.rv_footprint(v_account_a);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 2, v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 3, 14, 42), pg_temp.rv_line(v_pb, 1, 85, 85))));
  IF v_txt NOT LIKE 'P0400 delivery_note_product_unavailable%' OR v_fp IS DISTINCT FROM pg_temp.rv_footprint(v_account_a) THEN
    v_failures := v_failures || format('FAIL (e11): aumentar un producto dado de baja -> P0400 delivery_note_product_unavailable, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 2, v_client, v_x,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 1, 14, 14), pg_temp.rv_line(v_pb, 1, 85, 85))));
  IF v_txt <> 'OK' OR pg_temp.rv_stock(v_pdel, v_x) <> 1 THEN
    v_failures := v_failures || format('FAIL (e12): reducir un producto dado de baja debía funcionar (salió %s, stock %s)', v_txt, pg_temp.rv_stock(v_pdel, v_x));
  END IF;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pdel, v_y, 1);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pb, v_y, 1);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 3, v_client, v_y,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 1, 14, 14), pg_temp.rv_line(v_pb, 1, 85, 85))));
  IF v_txt <> 'OK' OR pg_temp.rv_stock(v_pdel, v_x) <> 2 OR pg_temp.rv_stock(v_pdel, v_y) <> 0 THEN
    v_failures := v_failures || format('FAIL (e13): trasladar un producto dado de baja conservando la cantidad debía funcionar (salió %s, X %s, Y %s)',
      v_txt, pg_temp.rv_stock(v_pdel, v_x), pg_temp.rv_stock(v_pdel, v_y));
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 4, v_client, v_y,
    jsonb_build_array(pg_temp.rv_line(v_pdel, 1, 14, 14), pg_temp.rv_line(v_pb, 1, 85, 85), pg_temp.rv_line(v_pdead, 1, 1, 1))));
  IF v_txt NOT LIKE 'P0404 product_not_found%' THEN
    v_failures := v_failures || format('FAIL (e14): un producto dado de baja NUEVO en el remito -> P0404 product_not_found, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 4, v_client_dead, v_y, pg_temp.rv_items(v_dn3)));
  IF v_txt NOT LIKE 'P0404 client_not_found%' THEN
    v_failures := v_failures || format('FAIL (e14): editar con un cliente dado de baja -> P0404 client_not_found, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn3, 4, v_client, v_closed, pg_temp.rv_items(v_dn3)));
  IF v_txt NOT LIKE 'P0422 branch_closed%' THEN
    v_failures := v_failures || format('FAIL (e14): mover a una sucursal cerrada -> P0422 branch_closed, salió %s', v_txt);
  END IF;

  -- e15: sucursal vigente desactivada / cerrada (armado como postgres, evadiendo el guard de baja).
  v_r := pg_temp.rv_issue('rv-e-4', v_client, v_w, jsonb_build_array(pg_temp.rv_line(v_pw, 1, 2, 2)));
  v_dn4 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  v_r := pg_temp.rv_issue('rv-e-6', v_client, v_q, jsonb_build_array(pg_temp.rv_line(v_pq, 1, 2, 2)));
  v_dn6 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = false WHERE id = v_w;
  UPDATE public.branches SET status = 'closed', closed_at = now() WHERE id = v_q;
  SET session_replication_role = DEFAULT;
  v_fp := pg_temp.rv_footprint(v_account_a);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn4, 1, v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 1, 1))));
  IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' THEN
    v_failures := v_failures || format('FAIL (e15): editar con la sucursal vigente desactivada -> P0422 delivery_note_branch_inactive, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn6, 1, v_client, v_q, jsonb_build_array(pg_temp.rv_line(v_pq, 1, 2, 2))));
  IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' THEN
    v_failures := v_failures || format('FAIL (e15): editar con la sucursal vigente cerrada -> P0422 delivery_note_branch_inactive, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rv_as(v_admin);
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn4, 1, 'sucursal muerta'));
  v_msg := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn6, 1, 'sucursal cerrada'));
  IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' OR v_msg NOT LIKE 'P0422 delivery_note_branch_inactive%'
     OR v_fp IS DISTINCT FROM pg_temp.rv_footprint(v_account_a) THEN
    v_failures := v_failures || format('FAIL (g): anular con la sucursal desactivada/cerrada -> P0422 sin reponer stock, salió %s / %s', v_txt, v_msg);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = true WHERE id = v_w;
  UPDATE public.branches SET status = 'active', closed_at = NULL WHERE id = v_q;
  SET session_replication_role = DEFAULT;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (f) Fila forjada en el ledger por PostgREST
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  v_r := pg_temp.rv_issue('rv-f-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pb, 3, 80, 240)));
  v_dn5 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  PERFORM pg_temp.rv_as(v_viewer);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.stock_movements (account_id, product_id, type, quantity_delta, reference_id, reference_type, branch_id)
    VALUES (v_account_a, v_pb, 'sale', -1000, v_dn5, 'delivery_note', v_x);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_failures := v_failures || format('FAIL (f) control positivo: la fila forjada debía poder insertarse por PostgREST (política preexistente), salió %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  IF NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn5 AND quantity_delta = -1000) THEN
    v_failures := v_failures || 'FAIL (f) control positivo: la fila forjada no existe'::text;
  END IF;
  PERFORM pg_temp.rv_as(v_seller);
  v_val := pg_temp.rv_stock(v_pb, v_x);
  PERFORM public.rpc_update_delivery_note(v_dn5, 1, v_client, v_x, NULL, NULL, jsonb_build_array(pg_temp.rv_line(v_pb, 1, 80, 80)));
  IF pg_temp.rv_stock(v_pb, v_x) <> v_val + 2 THEN
    v_failures := v_failures || format('FAIL (f): la edición debía devolver exactamente 2 (lo retenido 3 - 1), devolvió %s', pg_temp.rv_stock(v_pb, v_x) - v_val);
  END IF;
  PERFORM pg_temp.rv_as(v_admin);
  v_val := pg_temp.rv_stock(v_pb, v_x);
  PERFORM public.rpc_cancel_delivery_note(v_dn5, 2, 'fila forjada');
  IF pg_temp.rv_stock(v_pb, v_x) <> v_val + 1 THEN
    v_failures := v_failures || format('FAIL (f): la anulación debía devolver exactamente 1, devolvió %s', pg_temp.rv_stock(v_pb, v_x) - v_val);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) Anulación
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_admin);
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn1, 5, '   '));
  IF v_txt NOT LIKE 'P0400 delivery_note_cancel_reason_required%' THEN
    v_failures := v_failures || format('FAIL (g): anular sin motivo -> P0400 delivery_note_cancel_reason_required, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn1, 4, 'versión vieja'));
  IF v_txt NOT LIKE 'P0409 delivery_note_changed%' THEN
    v_failures := v_failures || format('FAIL (g): anular con versión vieja -> P0409 delivery_note_changed, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rv_as(v_seller);
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn1, 5, 'el vendedor no anula'));
  IF v_txt NOT LIKE 'P0403 insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (g): el vendedor no anula (P0403), salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rv_as(v_admin);
  v_val := pg_temp.rv_stock(v_pa, v_x);
  v_val2 := pg_temp.rv_stock(v_pkg, v_x);
  v_r := public.rpc_cancel_delivery_note(v_dn1, 5, 'cliente rechazó la entrega');
  IF v_r->>'status' <> 'canceled' OR pg_temp.rv_stock(v_pa, v_x) <> v_val + 4 OR pg_temp.rv_stock(v_pkg, v_x) <> v_val2 + 0.45 THEN
    v_failures := v_failures || format('FAIL (g): anular debía reponer A +4 y Kg +0.45 y dejar canceled (%s, A %s -> %s, Kg %s -> %s)',
      v_r->>'status', v_val, pg_temp.rv_stock(v_pa, v_x), v_val2, pg_temp.rv_stock(v_pkg, v_x));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND type = 'sale_return' AND reference_type = 'delivery_note_reversal'
    AND metadata->>'reverses' = 'delivery_note_cancel';
  IF v_n <> 4 THEN
    v_failures := v_failures || format('FAIL (g): anular debía dejar un sale_return/delivery_note_reversal por cada par (4), hay %s', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'delivery_note_sale' AND document_id = v_dn1 AND from_status = 'issued' AND to_status = 'canceled'
    AND performed_by = v_admin AND reason = 'cliente rechazó la entrega';
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (g): el historial debía registrar issued -> canceled con motivo y administrador'::text;
  END IF;
  v_txt := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn1, 5, 'otra vez'));
  IF v_txt NOT LIKE 'P0409 delivery_note_invalid_state%' THEN
    v_failures := v_failures || format('FAIL (g): segunda anulación -> P0409 delivery_note_invalid_state, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rv_as(v_seller);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn1, 5, v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pa, 1, 1, 1))));
  IF v_txt NOT LIKE 'P0409 delivery_note_invalid_state%' THEN
    v_failures := v_failures || format('FAIL (e): editar un anulado -> P0409 delivery_note_invalid_state, salió %s', v_txt);
  END IF;
  -- Convertido: inmutable (la conversión es de la tanda B; el estado se arma como postgres).
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'converted' WHERE id = v_dn2;
  SET session_replication_role = DEFAULT;
  PERFORM pg_temp.rv_as(v_stocker);
  v_txt := pg_temp.rv_err(pg_temp.rv_update_sql(v_dn2, 4, v_client, v_y, pg_temp.rv_items(v_dn2)));
  PERFORM pg_temp.rv_as(v_admin);
  v_msg := pg_temp.rv_err(pg_temp.rv_cancel_sql(v_dn2, 4, 'convertido'));
  IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted%' OR v_msg NOT LIKE 'P0423 delivery_note_locked_converted%' THEN
    v_failures := v_failures || format('FAIL (e/g): un remito convertido no se edita ni se anula (P0423), salió %s / %s', v_txt, v_msg);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'issued' WHERE id = v_dn2;
  SET session_replication_role = DEFAULT;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (h) Invariante: Σ quantity_delta por par = Δ branch_stock = -held; neto 0
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  v_r := pg_temp.rv_issue('rv-h-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pi, 3, 10, 30)));
  v_dn7 := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  PERFORM public.rpc_update_delivery_note(v_dn7, 1, v_client, v_x, NULL, NULL, jsonb_build_array(pg_temp.rv_line(v_pi, 5, 10, 50)));
  PERFORM public.rpc_update_delivery_note(v_dn7, 2, v_client, v_y, NULL, NULL,
    jsonb_build_array(pg_temp.rv_line(v_pi, 1, 10, 10), pg_temp.rv_line(v_pi, 1, 10, 10)));
  FOR v_rec IN
    SELECT b.id AS branch_id,
           COALESCE((SELECT sum(sm.quantity_delta) FROM public.stock_movements sm
                     WHERE sm.reference_id = v_dn7 AND sm.product_id = v_pi AND sm.branch_id = b.id), 0) AS sum_delta,
           pg_temp.rv_stock(v_pi, b.id) - 20 AS stock_delta,
           CASE WHEN b.id = v_y THEN -2 ELSE 0 END AS expected
    FROM public.branches b WHERE b.id IN (v_x, v_y)
  LOOP
    IF v_rec.sum_delta <> v_rec.stock_delta OR v_rec.sum_delta <> v_rec.expected THEN
      v_failures := v_failures || format('FAIL (h): sucursal %s: Σ delta %s, Δ stock %s, -held esperado %s',
        v_rec.branch_id, v_rec.sum_delta, v_rec.stock_delta, v_rec.expected);
    END IF;
  END LOOP;
  PERFORM pg_temp.rv_as(v_owner_a);
  PERFORM public.rpc_cancel_delivery_note(v_dn7, 3, 'invariante');
  SELECT COALESCE(sum(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE reference_id = v_dn7;
  IF v_val <> 0 OR pg_temp.rv_stock(v_pi, v_x) <> 20 OR pg_temp.rv_stock(v_pi, v_y) <> 20 THEN
    v_failures := v_failures || format('FAIL (h): tras anular, el ledger del remito debía cerrar en 0 y el stock volver a 20/20 (Σ %s, X %s, Y %s)',
      v_val, pg_temp.rv_stock(v_pi, v_x), pg_temp.rv_stock(v_pi, v_y));
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (i) PostgREST: sin escritura directa ni helpers; la RPC sí
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  EXECUTE 'SET LOCAL ROLE authenticated';
  FOR v_txt IN
    SELECT unnest(ARRAY[
      format('INSERT INTO public.delivery_notes (account_id, direction, branch_id, client_id, status, issued_on) VALUES (%L, ''sale'', %L, %L, ''issued'', current_date)', v_account_a, v_x, v_client),
      format('UPDATE public.delivery_notes SET total = 0 WHERE id = %L', v_dn3),
      format('DELETE FROM public.delivery_notes WHERE id = %L', v_dn3),
      format('INSERT INTO public.delivery_note_items (delivery_note_id, account_id, line_no, product_id, quantity, price, subtotal, quantity_base) VALUES (%L, %L, 9, %L, 1, 1, 1, 1)', v_dn3, v_account_a, v_pa),
      format('UPDATE public.delivery_note_items SET quantity_base = 1000 WHERE delivery_note_id = %L', v_dn3),
      format('DELETE FROM public.delivery_note_items WHERE delivery_note_id = %L', v_dn3),
      format('SELECT public._delivery_note_held_pairs(%L::uuid)', v_dn3),
      format('SELECT public._delivery_note_apply_stock(%L::uuid, %L::uuid, gen_random_uuid(), ''[]''::jsonb)', v_account_a, v_dn3),
      format('SELECT public._delivery_note_reverse_held(%L::uuid, %L::uuid, gen_random_uuid(), ''[]''::jsonb, ''delivery_note_reversal'', ''x'')', v_account_a, v_dn3),
      format('SELECT public._branch_pending_delivery_notes(%L::uuid)', v_x),
      format('SELECT public._assert_document_product(%L::uuid, %L::uuid)', v_account_a, v_pa)
    ])
  LOOP
    BEGIN
      EXECUTE v_txt;
      v_failures := v_failures || format('FAIL (i): como authenticated debía fallar: %s', v_txt);
    EXCEPTION WHEN insufficient_privilege THEN
      NULL;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_failures := v_failures || format('FAIL (i): %s debía dar 42501, dio %s %s', v_txt, v_state, v_msg);
    END;
  END LOOP;
  -- La RPC funciona como authenticated, y el SELECT de la cuenta también.
  BEGIN
    v_r := public.rpc_create_sale_delivery_note('rv-i-1', v_client, v_x, NULL, NULL,
             jsonb_build_array(jsonb_build_object('product_id', v_pb, 'unit_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1)));
    v_number_expected := v_number_expected + 1;
    SELECT count(*) INTO v_n FROM public.delivery_notes WHERE id = (v_r->>'id')::uuid;
    IF v_n <> 1 THEN
      v_failures := v_failures || 'FAIL (i): el miembro debía leer su remito por la RLS de SELECT'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_failures := v_failures || format('FAIL (i): la RPC como authenticated debía funcionar, salió %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  IF (SELECT total FROM public.delivery_notes WHERE id = v_dn3) = 0
     OR NOT EXISTS (SELECT 1 FROM public.delivery_note_items WHERE delivery_note_id = v_dn3) THEN
    v_failures := v_failures || 'FAIL (i): una escritura directa cambió el remito'::text;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) Guards de unidad con líneas del remito creadas por la RPC real
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  PERFORM pg_temp.rv_issue('rv-j-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pnobase, 1, 2, 2, v_u)));
  v_number_expected := v_number_expected + 1;
  PERFORM pg_temp.rv_issue('rv-j-2', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_pbulto, 1, 2, 2, v_bulto)));
  v_number_expected := v_number_expected + 1;
  PERFORM pg_temp.rv_as(v_owner_a);
  v_txt := pg_temp.rv_err(format('UPDATE public.products SET base_unit_id = %L WHERE id = %L', v_kg, v_pnobase));
  IF v_txt NOT LIKE 'P0409 base_unit_locked%' THEN
    v_failures := v_failures || format('FAIL (j): asignar Kilogramo a un producto con una línea de remito en Unidad -> P0409 base_unit_locked, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(format('UPDATE public.products SET base_unit_id = %L WHERE id = %L', v_u, v_pnobase));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (j): asignar la misma unidad de la línea (Unidad) debía funcionar, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rv_err(format('UPDATE public.units_of_measure SET factor = 2 WHERE id = %L', v_bulto));
  IF v_txt NOT LIKE 'P0409 unit_in_use%' THEN
    v_failures := v_failures || format('FAIL (j): cambiar el factor de una unidad usada sólo en un remito -> P0409 unit_in_use, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (k) Baja de sucursal con un remito pendiente
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  v_r := pg_temp.rv_issue('rv-k-1', v_client, v_v, jsonb_build_array(pg_temp.rv_line(v_pv, 2, 2, 4)));
  v_dnv := (v_r->>'id')::uuid;
  v_number_expected := v_number_expected + 1;
  IF pg_temp.rv_stock(v_pv, v_v) <> 0 THEN
    v_failures := v_failures || 'FAIL (k) setup: la sucursal V debía quedar sin existencias'::text;
  END IF;
  PERFORM pg_temp.rv_as(v_owner_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('disparador',            format('UPDATE public.branches SET is_active = false WHERE id = %L', v_v)),
      ('rpc_deactivate_branch', format('SELECT public.rpc_deactivate_branch(%L::uuid)', v_v)),
      ('rpc_close_branch',      format('SELECT public.rpc_close_branch(%L::uuid)', v_v))
    ) AS t(label, sql)
  LOOP
    v_txt := pg_temp.rv_err(v_rec.sql);
    IF v_txt NOT LIKE 'P0428 branch_has_pending_delivery_notes: la sucursal tiene 1 remito(s) pendiente(s) — anulalos (un administrador o el dueño) antes de darla de baja%' THEN
      v_failures := v_failures || format('FAIL (k) %s: baja con un remito pendiente -> P0428 branch_has_pending_delivery_notes, salió %s', v_rec.label, v_txt);
    END IF;
  END LOOP;
  -- Remito de compra pendiente (como postgres): el contador es agnóstico del sentido.
  INSERT INTO public.delivery_notes (account_id, direction, branch_id, supplier_id, status, issued_on)
  VALUES (v_account_a, 'purchase', v_v2, v_supplier, 'issued', v_today);
  v_txt := pg_temp.rv_err(format('UPDATE public.branches SET is_active = false WHERE id = %L', v_v2));
  IF v_txt NOT LIKE 'P0428 branch_has_pending_delivery_notes%' THEN
    v_failures := v_failures || format('FAIL (k): un remito de compra pendiente también debía bloquear la baja, salió %s', v_txt);
  END IF;
  -- Anulado el remito y vaciada la sucursal, la baja procede.
  PERFORM public.rpc_cancel_delivery_note(v_dnv, 1, 'cierre de sucursal');
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pv, v_v, -2);
  v_txt := pg_temp.rv_err(format('SELECT public.rpc_deactivate_branch(%L::uuid)', v_v));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (k): anulado el remito y vaciada la sucursal, la baja debía proceder, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (l) Regresión de _quote_validate_items (ahora llama a _assert_document_product)
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(v_seller);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('ajeno',  v_pother, 'P0404 product_not_found%'),
      ('baja',   v_pdead,  'P0404 product_not_found%'),
      ('padre',  v_parent, 'P0400 product_is_parent%')
    ) AS t(label, product, expected)
  LOOP
    v_txt := pg_temp.rv_err(format('SELECT public.rpc_create_quote(%L::uuid, NULL, NULL, NULL, %L::jsonb)', v_client,
      jsonb_build_array(jsonb_build_object('product_id', v_rec.product, 'unit_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1, 'description', NULL))));
    IF v_txt NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (l) presupuesto con producto %s: se esperaba %s, salió %s', v_rec.label, v_rec.expected, v_txt);
    END IF;
  END LOOP;
  v_txt := pg_temp.rv_err(format('SELECT public.rpc_create_quote(%L::uuid, NULL, NULL, NULL, %L::jsonb)', v_client,
    jsonb_build_array(jsonb_build_object('product_id', v_variant, 'unit_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1, 'description', NULL))));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (l): un presupuesto con una variante debía crearse, salió %s', v_txt);
  END IF;
  -- La variante también se remite como producto propio.
  v_txt := pg_temp.rv_err(pg_temp.rv_issue_sql('rv-l-1', v_client, v_x, jsonb_build_array(pg_temp.rv_line(v_variant, 1, 20, 20))));
  IF v_txt <> 'OK' OR pg_temp.rv_stock(v_variant, v_x) <> 4 THEN
    v_failures := v_failures || format('FAIL (l): remitir una variante debía descontarla (salió %s, stock %s)', v_txt, pg_temp.rv_stock(v_variant, v_x));
  ELSE
    v_number_expected := v_number_expected + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (m) Nada de caja, banco, cuenta corriente, eventos ni ventas
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(NULL);
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a),
    (SELECT count(*) FROM public.bank_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.customer_account_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.events WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.sales WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.sales_orders WHERE account_id = v_account_a))
  INTO v_counts_after;
  IF v_counts_before IS DISTINCT FROM v_counts_after THEN
    v_failures := v_failures || format('FAIL (m): los remitos tocaron caja/banco/cuenta corriente/eventos/ventas (%s -> %s)', v_counts_before, v_counts_after);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (n) Numeración R sin huecos ni repetidos
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT count(*) AS c, count(DISTINCT number) AS d, COALESCE(min(number), 0) AS mn, COALESCE(max(number), 0) AS mx
  INTO v_rec FROM public.delivery_notes WHERE account_id = v_account_a AND direction = 'sale';
  SELECT last_number INTO v_n FROM public.internal_document_sequences
  WHERE account_id = v_account_a AND document_type = 'delivery_note_sale';
  IF v_rec.c <> v_number_expected OR v_rec.d <> v_rec.c OR v_rec.c <> v_rec.mx OR v_rec.mn <> 1 OR v_n <> v_number_expected THEN
    v_failures := v_failures || format('FAIL (n): numeración R: %s remitos, %s distintos, min %s, max %s, secuencia %s (esperado %s, 1..%s)',
      v_rec.c, v_rec.d, v_rec.mn, v_rec.mx, v_n, v_number_expected, v_number_expected);
  END IF;
  IF EXISTS (SELECT 1 FROM public.delivery_notes WHERE account_id = v_account_a AND direction = 'purchase' AND number IS NOT NULL) THEN
    v_failures := v_failures || 'FAIL (n): el disparador de número de venta no debía numerar un remito de compra'::text;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza (toda fila con account_id de las cuentas del gate) y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rv_as(NULL);
  SET session_replication_role = replica;
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

  IF EXISTS (SELECT 1 FROM public.delivery_notes WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.delivery_note_items WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.stock_movements WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.internal_document_sequences WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.document_status_history WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = ANY (v_users))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE REMITOS-VENTA FAILED (% fallas):\n  %', array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE REMITOS-VENTA PASSED: emisión, rechazos sin efectos, idempotencia, roles, edición con espejo por par, fila forjada, anulación, invariante del ledger, PostgREST, guards de unidad, baja de sucursal, regresión de presupuestos y numeración — residuo cero.';

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      EXECUTE 'RESET ROLE';
      SET session_replication_role = replica;
      IF v_accounts IS NOT NULL THEN
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
    RAISE EXCEPTION 'GATE REMITOS-VENTA FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (o1) ACLs (sin fixtures) ────────────────────────────────────────────────
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   text;
  v_internal text[] := ARRAY[
    'public._assert_document_product(uuid, uuid)',
    'public._quote_validate_items(uuid, jsonb)',
    'public._delivery_note_assert_role(uuid, text)',
    'public._delivery_note_lock_products(uuid, uuid[])',
    'public._delivery_note_validate_items(uuid, uuid, jsonb, jsonb)',
    'public._delivery_note_insert_items(uuid, uuid, jsonb, jsonb)',
    'public._delivery_note_held_pairs(uuid)',
    'public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)',
    'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)',
    'public._delivery_note_payload(uuid)',
    'public._branch_pending_delivery_notes(uuid)',
    'public._branch_assert_empty(uuid)',
    'public.trg_delivery_note_record_creation()',
    'public.fn_product_base_unit_guard()',
    'public.fn_uom_in_use_guard()'
  ];
  v_public text[] := ARRAY[
    'public.rpc_create_sale_delivery_note(text, uuid, uuid, text, text, jsonb)',
    'public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)',
    'public.rpc_cancel_delivery_note(uuid, integer, text)',
    'public.rpc_get_delivery_note(uuid)'
  ];
  v_t text;
BEGIN
  FOREACH v_fn IN ARRAY v_internal LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('authenticated', v_fn, 'EXECUTE') OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por authenticated/anon', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY v_public LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_fn);
    ELSIF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s es ejecutable por anon', v_fn);
    ELSIF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_bad := v_bad || format('%s NO es ejecutable por authenticated', v_fn);
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn)) THEN
      v_bad := v_bad || format('%s no es SECURITY DEFINER', v_fn);
    ELSIF obj_description(to_regprocedure(v_fn), 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('%s sin COMMENT', v_fn);
    END IF;
  END LOOP;
  FOREACH v_t IN ARRAY ARRAY['public.delivery_notes', 'public.delivery_note_items'] LOOP
    IF to_regclass(v_t) IS NULL THEN
      v_bad := v_bad || format('%s no existe', v_t);
    ELSIF has_table_privilege('anon', v_t, 'SELECT')
       OR has_table_privilege('authenticated', v_t, 'INSERT')
       OR has_table_privilege('authenticated', v_t, 'UPDATE')
       OR has_table_privilege('authenticated', v_t, 'DELETE')
       OR NOT has_table_privilege('authenticated', v_t, 'SELECT') THEN
      v_bad := v_bad || format('%s: anon lee, authenticated escribe o no lee', v_t);
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid IN (to_regclass('public.delivery_notes'), to_regclass('public.delivery_note_items'))
             AND polcmd <> 'r') THEN
    v_bad := v_bad || 'delivery_notes / delivery_note_items tienen políticas de escritura'::text;
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE REMITOS-VENTA FAILED (o1):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (o1): helpers y disparadores sin EXECUTE para authenticated/anon; las 4 RPCs SECURITY DEFINER, con COMMENT, sin anon y con authenticated; tablas sólo de lectura para la API, sin políticas de escritura.';
END $$;

-- ── (o2) Catálogo de transiciones de delivery_note_sale (sin fixtures) ───────
DO $$
DECLARE
  v_n int;
BEGIN
  -- Ninguna fila fuera del conjunto declarado: las dos de la tanda A y, cuando
  -- la tanda B está aplicada, el par issued <-> converted (D3). Un conteo
  -- exacto rompería al aplicar la tanda B (y el reapply de CI de esta migración).
  SELECT count(*) INTO v_n
  FROM   public.document_status_transitions
  WHERE  document_type = 'delivery_note_sale'
    AND  (from_status, to_status) IS DISTINCT FROM (NULL::text, 'issued'::text)
    AND  (from_status, to_status) NOT IN (('issued', 'canceled'), ('issued', 'converted'), ('converted', 'issued'));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE REMITOS-VENTA FAILED (o2): delivery_note_sale tiene % fila(s) fuera del conjunto declarado', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status IS NULL AND to_status = 'issued'
                   AND allowed_role @> ARRAY['seller', 'stock', 'admin', 'owner'] AND cardinality(allowed_role) = 4
                   AND NOT requires_reason AND NOT is_terminal_to) THEN
    RAISE EXCEPTION 'GATE REMITOS-VENTA FAILED (o2): falta NULL -> issued con {seller,stock,admin,owner}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_sale' AND from_status = 'issued' AND to_status = 'canceled'
                   AND allowed_role @> ARRAY['admin', 'owner'] AND cardinality(allowed_role) = 2
                   AND requires_reason AND is_terminal_to) THEN
    RAISE EXCEPTION 'GATE REMITOS-VENTA FAILED (o2): falta issued -> canceled con {admin,owner}, motivo y terminal';
  END IF;
  RAISE NOTICE 'PASS (o2): catálogo delivery_note_sale con NULL -> issued y issued -> canceled (motivo, terminal).';
END $$;
