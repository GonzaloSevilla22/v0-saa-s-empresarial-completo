-- =============================================================================
-- test_remitos_compra.sql — Gate de comportamiento de la TANDA A de
-- `remitos-compra` (migración 20261071000001_remitos_compra.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de
-- verdad. Este archivo ejecuta, contra Postgres real y con usuarios reales
-- (owner, admin, stock, purchases, seller y cashier con membresía en
-- account_members y roles en account_member_roles), las RPCs nuevas
-- rpc_create_purchase_delivery_note y rpc_update_purchase_delivery_note,
-- rpc_cancel_delivery_note (reescrita para los dos sentidos), los helpers
-- por sentido (_delivery_note_apply_stock / _delivery_note_reverse_held leen
-- direction del remito), el núcleo de edición _delivery_note_replace_content
-- (también desde rpc_update_delivery_note, regresión de venta), el guard de
-- baja de sucursal y los guards de unidad.
--
-- Bloques (design.md §D16, tasks.md 1.1 / 1.3 / 1.4 / 1.6):
--   (0) helpers por sentido llamados directo: con un remito de compra, la
--       aplicación SUMA (purchase) y la reversa RESTA con gate
--       (P0409 delivery_note_stock_consumed, sin 23514).
--   (a) emisión: stock + por par, movimiento purchase/delivery_note con
--       quantity_before/after y costo de catálogo, 450 g -> 0,45 kg, número
--       RC correlativo e independiente del R de venta y de otra cuenta,
--       historial NULL -> issued (delivery_note_purchase), subtotal del
--       servidor (subtotal falso ignorado), precio 0 admitido, 2 x 0,333 kg a
--       $999 -> subtotales 332,67 y total 665,33, payload con supplier_name /
--       supplier_phone / supplier_deleted / missing_price_count; recibir no
--       mueve dinero ni el costo del producto.
--   (b) rechazos con su código y cero efectos (número no consumido).
--   (c) idempotencia.
--   (d) roles por sentido: seller / cashier / purchases no emiten; stock
--       emite y edita, no anula.
--   (e) edición: sólo precio sin movimientos; A=10/B=2 -> A=10/B=5 con un par
--       espejo sobre B; bajar con mercadería vendida por el POS (a 5 ->
--       P0409 con el texto exacto, a 8 funciona); el mismo texto con otra
--       compra de A en el medio; cambio de producto; cambio de sucursal con
--       cantidades iguales (compra Y venta) y con la vieja sin toda la
--       mercadería; snapshot acarreado; producto dado de baja; sucursal
--       desactivada; versión vieja; anulado; convertido (P0423 por sentido);
--       remito del otro sentido por cada RPC -> P0404.
--   (f) fila forjada en el ledger: la anulación resta sólo lo aportado.
--   (g) anulación: motivo, roles, con mercadería, con parte vendida (P0409
--       sin efectos), segunda anulación, sucursal desactivada.
--   (h) invariante Σ quantity_delta por par = Δ branch_stock = +aportado,
--       0 tras anular.
--   (i) PostgREST: sin escritura directa ni EXECUTE de helpers; la RPC sí.
--   (j) guards de unidad con líneas de remito de compra.
--   (k) baja de sucursal con un remito de compra pendiente -> P0428.
--   (l) numeración RC 1..N sin huecos; la R de venta intacta.
--   (o) ACLs y catálogo, en bloques DO aparte sin fixtures.
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila con account_id de las cuentas del
-- gate y residuo cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run remitos compra gate").
-- =============================================================================

-- Sin validar los cuerpos al crearlos: el RED falla por la RPC inexistente (42883).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION pg_temp.rcp_as(p_uid uuid) RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.rcp_line(p_product uuid, p_qty numeric, p_price numeric,
                                            p_subtotal numeric DEFAULT NULL, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', COALESCE(p_subtotal, p_qty * p_price));
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_err(p_sql text) RETURNS text
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

-- Huella de todo lo que una escritura del remito de compra puede tocar.
CREATE OR REPLACE FUNCTION pg_temp.rcp_footprint(p_account uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.delivery_notes WHERE account_id = p_account),
    (SELECT count(*) FROM public.delivery_note_items WHERE account_id = p_account),
    (SELECT count(*) FROM public.stock_movements WHERE account_id = p_account),
    (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    (SELECT COALESCE(max(last_number), 0) FROM public.internal_document_sequences
      WHERE account_id = p_account AND document_type = 'delivery_note_purchase'),
    (SELECT count(*) FROM public.operation_idempotency oi
      WHERE oi.operation_kind = 'delivery_note_purchase'
        AND oi.user_id IN (SELECT am.user_id FROM public.account_members am WHERE am.account_id = p_account)),
    (SELECT count(*) FROM public.document_status_history WHERE account_id = p_account),
    (SELECT COALESCE(sum(revision), 0) FROM public.delivery_notes WHERE account_id = p_account),
    (SELECT string_agg(id::text || ':' || status || ':' || branch_id::text || ':' || total::text, ',' ORDER BY id)
       FROM public.delivery_notes WHERE account_id = p_account));
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_issue(p_key text, p_supplier uuid, p_branch uuid, p_items jsonb,
                                             p_ref text DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  RETURN public.rpc_create_purchase_delivery_note(p_key, p_supplier, p_branch, p_ref, p_notes, p_items);
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_issue_sql(p_key text, p_supplier uuid, p_branch uuid, p_items jsonb,
                                                 p_ref text DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_create_purchase_delivery_note(%L, %L::uuid, %L::uuid, %L, %L, %L::jsonb)',
                p_key, p_supplier, p_branch, p_ref, p_notes, p_items);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_update_sql(p_dn uuid, p_rev integer, p_supplier uuid, p_branch uuid,
                                                  p_items jsonb, p_ref text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_update_purchase_delivery_note(%L::uuid, %s, %L::uuid, %L::uuid, %L, NULL, %L::jsonb)',
                p_dn, COALESCE(p_rev::text, 'NULL'), p_supplier, p_branch, p_ref, p_items);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_cancel_sql(p_dn uuid, p_rev integer, p_reason text)
RETURNS text LANGUAGE sql AS $f$
  SELECT format('SELECT public.rpc_cancel_delivery_note(%L::uuid, %s, %L)',
                p_dn, COALESCE(p_rev::text, 'NULL'), p_reason);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_rev(p_dn uuid) RETURNS integer
LANGUAGE sql AS $f$ SELECT revision FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p_product AND branch_id = p_branch), 0);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcp_moves(p_dn uuid, p_product uuid DEFAULT NULL) RETURNS bigint
LANGUAGE sql AS $f$
  SELECT count(*) FROM public.stock_movements
  WHERE reference_id = p_dn AND (p_product IS NULL OR product_id = p_product);
$f$;

-- Venta por el POS (la mercadería recibida "sale" del depósito).
CREATE OR REPLACE FUNCTION pg_temp.rcp_sell(p_key text, p_product uuid, p_qty numeric, p_branch uuid, p_pm uuid)
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM public.rpc_quick_sale(p_key, NULL, jsonb_build_array(jsonb_build_object(
            'product_id', p_product, 'unit_id', NULL, 'quantity', p_qty, 'price', 1, 'subtotal', p_qty)),
          'other', NULL, NULL, NULL, p_branch, NULL, p_pm, NULL);
END;
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';

  v_owner_a   uuid := gen_random_uuid();
  v_owner_b   uuid := gen_random_uuid();
  v_admin     uuid := gen_random_uuid();
  v_stocker   uuid := gen_random_uuid();
  v_purchaser uuid := gen_random_uuid();
  v_seller    uuid := gen_random_uuid();
  v_cashier   uuid := gen_random_uuid();
  v_users     uuid[];
  v_accounts  uuid[];
  v_account_a uuid;
  v_account_b uuid;
  v_member    uuid;

  v_x uuid; v_y uuid; v_w uuid; v_q uuid; v_z uuid; v_v uuid; v_closed uuid; v_inactive uuid; v_branch_b uuid;
  v_sup uuid; v_sup2 uuid; v_sup_dead uuid; v_sup_b uuid; v_client uuid;
  v_u uuid; v_kg uuid; v_g uuid; v_bulto uuid; v_unit_b uuid;
  v_pa uuid; v_pb uuid; v_pkg uuid; v_pk3 uuid; v_pc uuid; v_pd uuid; v_pe uuid; v_pf uuid;
  v_pq uuid; v_pr uuid; v_pw uuid; v_pw2 uuid; v_psnap uuid; v_pdel uuid; v_pz uuid; v_pi uuid;
  v_pforge uuid; v_pcan uuid; v_ppart uuid; v_pnobase uuid; v_pbulto uuid; v_pv uuid; v_pidem uuid;
  v_ph uuid; v_parent uuid; v_variant uuid; v_pdead uuid; v_pother uuid;
  v_pm_other uuid;

  v_today   date := public.reporting_local_today();
  v_r       jsonb;
  v_r2      jsonb;
  v_txt     text;
  v_fp      text;
  v_fp2     text;
  v_n       bigint;
  v_val     numeric;
  v_val2    numeric;
  v_dn      uuid;
  v_dn1 uuid; v_dn2 uuid; v_dn3 uuid; v_dn4 uuid; v_dn5 uuid; v_dn6 uuid; v_dn7 uuid; v_dn8 uuid;
  v_dn9 uuid; v_dn10 uuid; v_dn11 uuid; v_dn12 uuid; v_dn13 uuid; v_dnsale uuid; v_dnb uuid; v_dnk uuid;
  v_rec     RECORD;
  v_state   text;
  v_msg     text;
  v_table   text;
  v_money_before text;
  v_money_after  text;
  v_items   jsonb;
  v_rc_expected bigint := 0;
  v_r_expected  bigint := 0;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_admin, v_stocker, v_purchaser, v_seller, v_cashier];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'remitos-compra-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate Remitos Compra ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_owner_b, 'owner-b'), (v_admin, 'admin'), (v_stocker, 'stock'),
               (v_purchaser, 'purchases'), (v_seller, 'seller'), (v_cashier, 'cashier')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
  WHERE member_id IN (SELECT id FROM public.account_members
                      WHERE user_id IN (v_admin, v_stocker, v_purchaser, v_seller, v_cashier));
  DELETE FROM public.account_members WHERE user_id IN (v_admin, v_stocker, v_purchaser, v_seller, v_cashier);
  SET session_replication_role = DEFAULT;

  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_admin, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'admin');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_stocker, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'stock');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_purchaser, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'purchases');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_cashier, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'cashier');

  SELECT id INTO v_x FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  IF v_x IS NULL OR v_branch_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal por defecto';
  END IF;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC W', TRUE, 'active', now(), now() + interval '2 minutes') RETURNING id INTO v_w;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC Q', TRUE, 'active', now(), now() + interval '3 minutes') RETURNING id INTO v_q;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC Z', TRUE, 'active', now(), now() + interval '4 minutes') RETURNING id INTO v_z;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC V', TRUE, 'active', now(), now() + interval '5 minutes') RETURNING id INTO v_v;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at, created_at)
  VALUES (v_account_a, 'Gate RC Cerrada', TRUE, 'closed', now(), now(), now() + interval '6 minutes') RETURNING id INTO v_closed;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RC Inactiva', FALSE, 'active', now(), now() + interval '7 minutes') RETURNING id INTO v_inactive;

  INSERT INTO public.suppliers (account_id, name, phone) VALUES (v_account_a, 'Proveedor Gate RC', '2615550404') RETURNING id INTO v_sup;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, 'Proveedor Gate RC 2') RETURNING id INTO v_sup2;
  INSERT INTO public.suppliers (account_id, name, deleted_at) VALUES (v_account_a, 'Proveedor Gate RC Baja', now()) RETURNING id INTO v_sup_dead;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_b, 'Proveedor Gate RC B') RETURNING id INTO v_sup_b;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate RC') RETURNING id INTO v_client;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad RC', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo RC', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo RC', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Bulto RC', 'bto', 'unit', 1, false) RETURNING id INTO v_bulto;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_b, 'Unidad RC B', 'u', 'unit', 1, false) RETURNING id INTO v_unit_b;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC A', 'GRC-A', 100, 150, v_u) RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC B', 'GRC-B', 50, 80, v_u) RETURNING id INTO v_pb;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Kg', 'GRC-KG', 1000, 2000, v_kg) RETURNING id INTO v_pkg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Kg3', 'GRC-KG3', 500, 999, v_kg) RETURNING id INTO v_pk3;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC C', 'GRC-C', 10, 20, v_u) RETURNING id INTO v_pc;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC D', 'GRC-D', 10, 20, v_u) RETURNING id INTO v_pd;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC E', 'GRC-E', 10, 20, v_u) RETURNING id INTO v_pe;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC F', 'GRC-F', 10, 20, v_u) RETURNING id INTO v_pf;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Q', 'GRC-Q', 10, 20, v_u) RETURNING id INTO v_pq;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC R', 'GRC-R', 10, 20, v_u) RETURNING id INTO v_pr;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC W', 'GRC-W', 10, 20, v_u) RETURNING id INTO v_pw;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC W2', 'GRC-W2', 10, 20, v_u) RETURNING id INTO v_pw2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Snap', 'GRC-SNAP', 30, 60, v_u) RETURNING id INTO v_psnap;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Del', 'GRC-DEL', 7, 14, v_u) RETURNING id INTO v_pdel;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Z', 'GRC-Z', 1, 2, v_u) RETURNING id INTO v_pz;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Invariante', 'GRC-I', 5, 10, v_u) RETURNING id INTO v_pi;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Forja', 'GRC-FORGE', 5, 10, v_u) RETURNING id INTO v_pforge;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Anula', 'GRC-CAN', 5, 10, v_u) RETURNING id INTO v_pcan;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Parte', 'GRC-PART', 5, 10, v_u) RETURNING id INTO v_ppart;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate RC Sin Base', 'GRC-NB', 1, 2) RETURNING id INTO v_pnobase;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Gate RC Bulto', 'GRC-BTO', 1, 2) RETURNING id INTO v_pbulto;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC V', 'GRC-V', 1, 2, v_u) RETURNING id INTO v_pv;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Idem', 'GRC-IDEM', 1, 2, v_u) RETURNING id INTO v_pidem;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RC Helper', 'GRC-H', 3, 6, v_u) RETURNING id INTO v_ph;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type)
  VALUES (v_owner_a, v_account_a, 'Gate RC Padre', 'GRC-PADRE', 0, 0, 'variant_only') RETURNING id INTO v_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_owner_a, v_account_a, 'Gate RC Variante', 'GRC-VAR', 10, 20, v_parent, true) RETURNING id INTO v_variant;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id, deleted_at)
  VALUES (v_owner_a, v_account_a, 'Gate RC Muerto', 'GRC-DEAD', 1, 2, v_u, now()) RETURNING id INTO v_pdead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'GRC SECRETO DE B', 'GRC-SECRETO-B', 777, 999) RETURNING id INTO v_pother;

  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pa,  v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pb,  v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pkg, v_x, 1);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pa,  v_y, 5);

  SELECT id INTO v_pm_other FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'other' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  IF v_pm_other IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta no tiene la forma de pago sembrada de tipo other';
  END IF;

  -- Dinero / eventos / compras / costo al empezar (recibir no los toca).
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a),
    (SELECT count(*) FROM public.bank_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.supplier_account_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.events WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.purchases WHERE account_id = v_account_a),
    (SELECT sum(cost) FROM public.products WHERE account_id = v_account_a))
  INTO v_money_before;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (0) Helpers por sentido, llamados directo (el sentido sale del remito)
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_owner_a);
  INSERT INTO public.delivery_notes (account_id, direction, branch_id, supplier_id, status, issued_on, total, created_by)
  VALUES (v_account_a, 'purchase', v_x, v_sup, 'issued', v_today, 0, v_owner_a) RETURNING id INTO v_dn;
  v_rc_expected := v_rc_expected + 1;  -- el disparador gemelo también numera esta fila
  INSERT INTO public.delivery_note_items (delivery_note_id, account_id, line_no, product_id, quantity, price, subtotal,
                                          name_snapshot, unit_cost_snapshot, quantity_base)
  VALUES (v_dn, v_account_a, 1, v_ph, 4, 0, 0, 'Gate RC Helper', 3, 4);
  PERFORM public._delivery_note_apply_stock(v_account_a, v_dn, gen_random_uuid(), public._delivery_note_held_pairs(v_dn));
  IF pg_temp.rcp_stock(v_ph, v_x) <> 4
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn AND type = 'purchase'
                    AND reference_type = 'delivery_note' AND quantity_delta = 4 AND quantity_before = 0 AND quantity_after = 4) THEN
    v_failures := v_failures || format('FAIL (0): con un remito de compra, _delivery_note_apply_stock debía SUMAR 4 (purchase/delivery_note), stock %s',
      pg_temp.rcp_stock(v_ph, v_x));
  END IF;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_ph, v_x, -3);  -- quedan 1
  v_txt := pg_temp.rcp_err(format(
    'SELECT public._delivery_note_reverse_held(%L::uuid, %L::uuid, gen_random_uuid(), public._delivery_note_held_pairs(%L::uuid), ''delivery_note_reversal'', ''x'')',
    v_account_a, v_dn, v_dn));
  IF v_txt <> 'P0409 delivery_note_stock_consumed: de Gate RC Helper en la sucursal quedan 1, el remito necesita restar 4' THEN
    v_failures := v_failures || format('FAIL (0): la reversa de compra sin stock debía dar P0409 delivery_note_stock_consumed (nunca 23514), salió %s', v_txt);
  END IF;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_ph, v_x, 3);   -- vuelve a 4
  PERFORM public._delivery_note_reverse_held(v_account_a, v_dn, gen_random_uuid(), public._delivery_note_held_pairs(v_dn),
                                             'delivery_note_reversal', 'x');
  IF pg_temp.rcp_stock(v_ph, v_x) <> 0
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn AND type = 'purchase_return'
                    AND reference_type = 'delivery_note_reversal' AND quantity_delta = -4) THEN
    v_failures := v_failures || format('FAIL (0): la reversa de compra debía RESTAR 4 (purchase_return), stock %s', pg_temp.rcp_stock(v_ph, v_x));
  END IF;
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'canceled' WHERE id = v_dn;
  SET session_replication_role = DEFAULT;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) Emisión feliz (rol stock)
  -- ═══════════════════════════════════════════════════════════════════════
  -- Un remito de VENTA antes: la secuencia R es independiente de la RC.
  PERFORM pg_temp.rcp_as(v_seller);
  v_r := public.rpc_create_sale_delivery_note('rc-a-venta-1', v_client, v_x, NULL, NULL,
           jsonb_build_array(pg_temp.rcp_line(v_pb, 1, 80)));
  v_dnsale := (v_r->>'id')::uuid;
  v_r_expected := v_r_expected + 1;

  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-a-1', v_sup, v_x,
    jsonb_build_array(pg_temp.rcp_line(v_pa, 3, 500, 1),                -- subtotal falso: se ignora
                      pg_temp.rcp_line(v_pb, 2, 0),                     -- precio pendiente
                      pg_temp.rcp_line(v_pkg, 450, 2, 1, v_g)),         -- 450 g -> 0,45 kg
    '0001-00004567', 'Llegó con la factura pendiente');
  v_dn1 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  IF v_dn1 IS NULL THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (a): la emisión no devolvió id: %', v_r;
  END IF;
  IF (v_r->>'number')::bigint IS DISTINCT FROM v_rc_expected OR v_r->>'status' <> 'issued' OR v_r->>'direction' <> 'purchase'
     OR (v_r->>'replayed')::boolean IS DISTINCT FROM false OR (v_r->>'total')::numeric IS DISTINCT FROM 2400.00
     OR (v_r->>'issued_on')::date IS DISTINCT FROM v_today OR (v_r->>'revision')::int IS DISTINCT FROM 1
     OR v_r->>'document_type' IS DISTINCT FROM 'delivery_note_purchase'
     OR v_r->>'supplier_name' IS DISTINCT FROM 'Proveedor Gate RC' OR v_r->>'supplier_phone' IS DISTINCT FROM '2615550404'
     OR (v_r->>'supplier_deleted')::boolean IS DISTINCT FROM false OR (v_r->>'missing_price_count')::int IS DISTINCT FROM 1
     OR v_r->>'supplier_reference' IS DISTINCT FROM '0001-00004567' OR v_r->>'client_id' IS NOT NULL
     OR v_r->>'delivery_address' IS NOT NULL OR v_r->>'branch_name' IS NULL
     OR jsonb_array_length(COALESCE(v_r->'items', '[]')) <> 3 THEN
    v_failures := v_failures || format('FAIL (a): payload de la emisión inesperado: %s', v_r);
  END IF;
  IF pg_temp.rcp_stock(v_pa, v_x) <> 13 OR pg_temp.rcp_stock(v_pb, v_x) <> 11 OR pg_temp.rcp_stock(v_pkg, v_x) <> 1.45 THEN
    v_failures := v_failures || format('FAIL (a): stock tras recibir A/B/Kg = %s/%s/%s (esperado 13/11/1.45)',
      pg_temp.rcp_stock(v_pa, v_x), pg_temp.rcp_stock(v_pb, v_x), pg_temp.rcp_stock(v_pkg, v_x));
  END IF;
  SELECT count(*) INTO v_n FROM public.stock_movements
  WHERE reference_id = v_dn1 AND type = 'purchase' AND reference_type = 'delivery_note' AND branch_id = v_x
    AND performed_by = v_stocker AND account_id = v_account_a
    AND jsonb_array_length(metadata->'delivery_note_item_ids') = 1
    AND ((product_id = v_pa AND quantity_delta = 3 AND quantity_before = 10 AND quantity_after = 13 AND unit_cost_snapshot = 100 AND product_name = 'Gate RC A')
      OR (product_id = v_pb AND quantity_delta = 2 AND quantity_before = 9 AND quantity_after = 11 AND unit_cost_snapshot = 50)
      OR (product_id = v_pkg AND quantity_delta = 0.45 AND quantity_before = 1 AND quantity_after = 1.45 AND unit_cost_snapshot = 1000));
  IF v_n <> 3 OR pg_temp.rcp_moves(v_dn1) <> 3 THEN
    v_failures := v_failures || format('FAIL (a): se esperaban 3 movimientos purchase/delivery_note exactos por par, hay %s de %s', v_n, pg_temp.rcp_moves(v_dn1));
  END IF;
  SELECT count(*) INTO v_n FROM public.delivery_note_items
  WHERE delivery_note_id = v_dn1 AND account_id = v_account_a
    AND ((product_id = v_pa AND quantity_base = 3 AND price = 500 AND subtotal = 1500 AND unit_cost_snapshot = 100 AND line_no = 1)
      OR (product_id = v_pb AND quantity_base = 2 AND price = 0 AND subtotal = 0 AND line_no = 2)
      OR (product_id = v_pkg AND quantity = 450 AND unit_id = v_g AND quantity_base = 0.45 AND price = 2 AND subtotal = 900 AND line_no = 3));
  IF v_n <> 3 THEN
    v_failures := v_failures || 'FAIL (a): las líneas no guardaron subtotal del servidor / quantity_base / costo de catálogo'::text;
  END IF;
  SELECT count(*) INTO v_n FROM public.document_status_history
  WHERE document_type = 'delivery_note_purchase' AND document_id = v_dn1 AND from_status IS NULL
    AND to_status = 'issued' AND performed_by = v_stocker;
  IF v_n <> 1 THEN
    v_failures := v_failures || 'FAIL (a): la emisión debía registrar NULL -> issued (delivery_note_purchase) con el creador'::text;
  END IF;
  IF (SELECT cost FROM public.products WHERE id = v_pa) <> 100 THEN
    v_failures := v_failures || 'FAIL (a): recibir a $500 no debía cambiar el costo de catálogo ($100)'::text;
  END IF;
  -- rpc_get_delivery_note devuelve el mismo payload, con el historial de compra.
  v_r2 := public.rpc_get_delivery_note(v_dn1);
  IF (v_r2->>'id')::uuid IS DISTINCT FROM v_dn1 OR jsonb_array_length(COALESCE(v_r2->'history', '[]')) <> 1
     OR v_r2->>'supplier_name' IS DISTINCT FROM 'Proveedor Gate RC' THEN
    v_failures := v_failures || format('FAIL (a): rpc_get_delivery_note inesperado: %s', v_r2);
  END IF;
  -- Trade-off de D1: 2 x 0,333 kg a $999 -> subtotales 332,67 y total 665,33.
  v_r := pg_temp.rcp_issue('rc-a-2', v_sup2, v_x,
    jsonb_build_array(pg_temp.rcp_line(v_pk3, 0.333, 999, 0), pg_temp.rcp_line(v_pk3, 0.333, 999, 0)));
  v_dn2 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  IF (v_r->>'total')::numeric IS DISTINCT FROM 665.33
     OR (SELECT count(*) FROM public.delivery_note_items WHERE delivery_note_id = v_dn2 AND subtotal = 332.67) <> 2
     OR (v_r->>'missing_price_count')::int IS DISTINCT FROM 0 OR v_r->>'supplier_phone' IS NOT NULL
     OR (v_r->>'number')::bigint IS DISTINCT FROM v_rc_expected THEN
    v_failures := v_failures || format('FAIL (a): 2 x 0,333 kg a $999 -> subtotales 332,67 y total 665,33, número %s; salió %s', v_rc_expected, v_r);
  END IF;
  IF pg_temp.rcp_stock(v_pk3, v_x) <> 0.666 THEN
    v_failures := v_failures || format('FAIL (a): el par Kg3 debía sumar 0,666 (dos líneas del mismo producto juntas), stock %s', pg_temp.rcp_stock(v_pk3, v_x));
  END IF;
  -- La secuencia R siguió por su lado.
  PERFORM pg_temp.rcp_as(v_seller);
  v_r := public.rpc_create_sale_delivery_note('rc-a-venta-2', v_client, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pb, 1, 80)));
  v_r_expected := v_r_expected + 1;
  IF (v_r->>'number')::bigint IS DISTINCT FROM v_r_expected THEN
    v_failures := v_failures || format('FAIL (a): el siguiente remito de venta debía ser el R %s, es %s', v_r_expected, v_r->>'number');
  END IF;
  -- Otra cuenta numera RC desde 1.
  PERFORM pg_temp.rcp_as(v_owner_b);
  v_r2 := pg_temp.rcp_issue('rc-b-1', v_sup_b, v_branch_b, jsonb_build_array(pg_temp.rcp_line(v_pother, 1, 10)));
  v_dnb := (v_r2->>'id')::uuid;
  IF (v_r2->>'number')::bigint IS DISTINCT FROM 1 THEN
    v_failures := v_failures || format('FAIL (a): el primer remito de compra de B debía ser el 1, es %s', v_r2->>'number');
  END IF;

  -- Recibir no movió dinero, compras, eventos ni el costo.
  SELECT concat_ws('|',
    (SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id
       JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a),
    (SELECT count(*) FROM public.bank_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.supplier_account_movements WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.events WHERE account_id = v_account_a),
    (SELECT count(*) FROM public.purchases WHERE account_id = v_account_a),
    (SELECT sum(cost) FROM public.products WHERE account_id = v_account_a))
  INTO v_money_after;
  IF v_money_before IS DISTINCT FROM v_money_after THEN
    v_failures := v_failures || format('FAIL (a): recibir tocó caja/banco/cuenta corriente/eventos/compras/costo (%s -> %s)', v_money_before, v_money_after);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) Rechazos con su código y cero efectos
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  v_items := jsonb_build_array(pg_temp.rcp_line(v_pa, 1, 10));
  v_fp := pg_temp.rcp_footprint(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('sin clave',            pg_temp.rcp_issue_sql('', v_sup, v_x, v_items),                     'P0400 idempotency_key_required%'),
      ('sin proveedor',        pg_temp.rcp_issue_sql('rc-b-1', NULL, v_x, v_items),                'P0400 delivery_note_supplier_required%'),
      ('proveedor ajeno',      pg_temp.rcp_issue_sql('rc-b-2', v_sup_b, v_x, v_items),             'P0404 supplier_not_found%'),
      ('proveedor de baja',    pg_temp.rcp_issue_sql('rc-b-3', v_sup_dead, v_x, v_items),          'P0404 supplier_not_found%'),
      ('sin sucursal',         pg_temp.rcp_issue_sql('rc-b-4', v_sup, NULL, v_items),              'P0400 delivery_note_branch_required%'),
      ('sucursal ajena',       pg_temp.rcp_issue_sql('rc-b-5', v_sup, v_branch_b, v_items),        'P0404 branch_not_found%'),
      ('sucursal cerrada',     pg_temp.rcp_issue_sql('rc-b-6', v_sup, v_closed, v_items),          'P0422 branch_closed%'),
      ('sucursal inactiva',    pg_temp.rcp_issue_sql('rc-b-7', v_sup, v_inactive, v_items),        'P0422 delivery_note_branch_inactive%'),
      ('sin líneas',           pg_temp.rcp_issue_sql('rc-b-8', v_sup, v_x, '[]'::jsonb),           'P0400 delivery_note_items_required%'),
      ('línea sin producto',   pg_temp.rcp_issue_sql('rc-b-9', v_sup, v_x,
                                 jsonb_build_array(jsonb_build_object('product_id', NULL, 'quantity', 1, 'price', 1, 'subtotal', 1))),
                                                                                                   'P0400 delivery_note_product_required%'),
      ('producto ajeno',       pg_temp.rcp_issue_sql('rc-b-10', v_sup, v_x,
                                 jsonb_build_array(pg_temp.rcp_line(v_pa, 1, 1), pg_temp.rcp_line(v_pother, 1, 1))),
                                                                                                   'P0404 product_not_found%'),
      ('producto de baja',     pg_temp.rcp_issue_sql('rc-b-11', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pdead, 1, 1))),
                                                                                                   'P0404 product_not_found%'),
      ('producto padre',       pg_temp.rcp_issue_sql('rc-b-12', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_parent, 1, 1))),
                                                                                                   'P0400 product_is_parent%'),
      ('unidad incompatible',  pg_temp.rcp_issue_sql('rc-b-13', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pa, 1, 1, NULL, v_kg))),
                                                                                                   'P0400 unit_type_mismatch%'),
      ('unidad de otra cuenta', pg_temp.rcp_issue_sql('rc-b-14', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pa, 1, 1, NULL, v_unit_b))),
                                                                                                   'P0404 Unit of measure not found%'),
      ('cantidad cero',        pg_temp.rcp_issue_sql('rc-b-15', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pa, 0, 1))),
                                                                                                   'P0400 delivery_note_line_invalid_quantity%'),
      ('precio negativo',      pg_temp.rcp_issue_sql('rc-b-16', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pa, 1, -1, 0))),
                                                                                                   'P0400 delivery_note_line_invalid_price%'),
      ('referencia larga',     pg_temp.rcp_issue_sql('rc-b-17', v_sup, v_x, v_items, repeat('9', 101)),
                                                                                                   'P0400 delivery_note_supplier_reference_too_long%'),
      ('notas largas',         pg_temp.rcp_issue_sql('rc-b-18', v_sup, v_x, v_items, NULL, repeat('n', 2001)),
                                                                                                   'P0400 delivery_note_notes_too_long%')
    ) AS t(label, sql, expected)
  LOOP
    v_txt := pg_temp.rcp_err(v_rec.sql);
    IF v_txt NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (b) %s: se esperaba %s, salió %s', v_rec.label, v_rec.expected, v_txt);
    END IF;
  END LOOP;
  v_fp2 := pg_temp.rcp_footprint(v_account_a);
  IF v_fp IS DISTINCT FROM v_fp2 THEN
    v_failures := v_failures || format('FAIL (b): un rechazo dejó efectos (huella %s -> %s)', v_fp, v_fp2);
  END IF;
  -- Alta revertida no consume número: la siguiente recibe el que seguía.
  v_r := pg_temp.rcp_issue('rc-b-ok', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_variant, 1, 5)));
  v_rc_expected := v_rc_expected + 1;
  IF (v_r->>'number')::bigint IS DISTINCT FROM v_rc_expected OR pg_temp.rcp_stock(v_variant, v_x) <> 1 THEN
    v_failures := v_failures || format('FAIL (b): tras los rechazos, la siguiente recepción (variante) debía ser el RC %s y sumar 1; salió %s', v_rc_expected, v_r);
  END IF;
  v_dn3 := (v_r->>'id')::uuid;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) Idempotencia
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-c-1', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pidem, 2, 10)));
  v_rc_expected := v_rc_expected + 1;
  v_r2 := pg_temp.rcp_issue('rc-c-1', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pidem, 2, 10)));
  IF (v_r2->>'id') IS DISTINCT FROM (v_r->>'id') OR (v_r2->>'replayed')::boolean IS DISTINCT FROM true
     OR pg_temp.rcp_stock(v_pidem, v_x) <> 2
     OR (SELECT count(*) FROM public.delivery_note_items WHERE product_id = v_pidem) <> 1 THEN
    v_failures := v_failures || format('FAIL (c): misma clave -> mismo remito con replayed y una sola suma (stock %s): %s',
      pg_temp.rcp_stock(v_pidem, v_x), v_r2);
  END IF;
  -- La misma clave usada para un remito de VENTA no choca (otro operation_kind).
  v_txt := pg_temp.rcp_err(pg_temp.rcp_issue_sql('rc-a-venta-1', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pidem, 1, 10))));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (c): una clave de venta no debía chocar con la emisión de compra, salió %s', v_txt);
  ELSE
    v_rc_expected := v_rc_expected + 1;
  END IF;
  -- Fila delivery_note_purchase cuyo operation_id no es un remito de compra de sus cuentas.
  INSERT INTO public.operation_idempotency (user_id, operation_kind, idempotency_key, operation_id)
  VALUES (v_stocker, 'delivery_note_purchase', 'rc-c-forjada', v_dnsale);
  v_fp := pg_temp.rcp_footprint(v_account_a);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_issue_sql('rc-c-forjada', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pidem, 1, 10))));
  IF v_txt NOT LIKE 'P0409 idempotency_key_conflict%' OR pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp THEN
    v_failures := v_failures || format('FAIL (c): clave que apunta a un remito de VENTA -> P0409 idempotency_key_conflict sin efectos, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (d) Roles por sentido
  -- ═══════════════════════════════════════════════════════════════════════
  v_fp := pg_temp.rcp_footprint(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES ('seller', v_seller), ('cashier', v_cashier), ('purchases', v_purchaser)) AS t(label, uid)
  LOOP
    PERFORM pg_temp.rcp_as(v_rec.uid);
    v_txt := pg_temp.rcp_err(pg_temp.rcp_issue_sql('rc-d-' || v_rec.label, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pa, 1, 1))));
    IF v_txt NOT LIKE 'P0403 insufficient_role: tu rol no permite emitir o editar remitos de compra (requiere depósito, administrador o dueño)%' THEN
      v_failures := v_failures || format('FAIL (d): %s no debía recibir mercadería (P0403 con el rótulo de compra), salió %s', v_rec.label, v_txt);
    END IF;
  END LOOP;
  IF pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp THEN
    v_failures := v_failures || 'FAIL (d): un rechazo por rol dejó efectos'::text;
  END IF;
  -- El vendedor sigue emitiendo remitos de VENTA (el rol de venta no cambió).
  PERFORM pg_temp.rcp_as(v_seller);
  v_txt := pg_temp.rcp_err(format('SELECT public.rpc_create_sale_delivery_note(%L, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
                                  'rc-d-venta', v_client, v_x, jsonb_build_array(pg_temp.rcp_line(v_pb, 1, 80))));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (d): el vendedor debía seguir emitiendo remitos de venta, salió %s', v_txt);
  ELSE
    v_r_expected := v_r_expected + 1;
  END IF;
  -- Owner de otra cuenta con el proveedor de A -> no encontrado.
  PERFORM pg_temp.rcp_as(v_owner_b);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_issue_sql('rc-d-b', v_sup, v_branch_b, jsonb_build_array(pg_temp.rcp_line(v_pother, 1, 1))));
  IF v_txt NOT LIKE 'P0404 supplier_not_found%' THEN
    v_failures := v_failures || format('FAIL (d): el proveedor de otra cuenta debía dar P0404 supplier_not_found, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) Edición
  -- ═══════════════════════════════════════════════════════════════════════
  -- (e1) sólo precio: 0 movimientos, total y versión cambian.
  PERFORM pg_temp.rcp_as(v_stocker);
  v_n := pg_temp.rcp_moves(v_dn1);
  v_r := public.rpc_update_purchase_delivery_note(v_dn1, 1, v_sup, v_x, '0001-00004567', 'Precios cargados',
           jsonb_build_array(pg_temp.rcp_line(v_pa, 3, 500), pg_temp.rcp_line(v_pb, 2, 450), pg_temp.rcp_line(v_pkg, 450, 2, NULL, v_g)));
  IF pg_temp.rcp_moves(v_dn1) <> v_n OR (v_r->>'revision')::int <> 2 OR (v_r->>'total')::numeric <> 3300
     OR (v_r->>'missing_price_count')::int <> 0 OR v_r->>'notes' IS DISTINCT FROM 'Precios cargados' THEN
    v_failures := v_failures || format('FAIL (e1): cargar el precio no debía mover el ledger y sí subir la versión y el total: %s', v_r);
  END IF;

  -- (e2) A=10/B=2 -> A=10/B=5: un solo par espejo, sobre B.
  v_r := pg_temp.rcp_issue('rc-e2', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pc, 10, 1), pg_temp.rcp_line(v_pd, 2, 1)));
  v_dn4 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.rpc_update_purchase_delivery_note(v_dn4, 1, v_sup, v_x, NULL, NULL,
            jsonb_build_array(pg_temp.rcp_line(v_pc, 10, 1), pg_temp.rcp_line(v_pd, 5, 1)));
  IF pg_temp.rcp_moves(v_dn4, v_pc) <> 1 OR pg_temp.rcp_moves(v_dn4, v_pd) <> 3
     OR pg_temp.rcp_stock(v_pc, v_x) <> 10 OR pg_temp.rcp_stock(v_pd, v_x) <> 5
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn4 AND product_id = v_pd
                    AND type = 'purchase' AND reference_type = 'delivery_note' AND quantity_delta = 5 AND quantity_before = 2 AND quantity_after = 7)
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn4 AND product_id = v_pd
                    AND type = 'purchase_return' AND reference_type = 'delivery_note_update' AND quantity_delta = -2
                    AND quantity_before = 7 AND quantity_after = 5 AND metadata->>'reverses' = 'delivery_note_edit') THEN
    v_failures := v_failures || format('FAIL (e2): subir B de 2 a 5 debía escribir +5 (primero) y -2 sólo sobre B (A %s mov, B %s mov, stock B %s)',
      pg_temp.rcp_moves(v_dn4, v_pc), pg_temp.rcp_moves(v_dn4, v_pd), pg_temp.rcp_stock(v_pd, v_x));
  END IF;

  -- (e3) bajar con mercadería vendida por el POS.
  v_r := pg_temp.rcp_issue('rc-e3', v_sup, v_q, jsonb_build_array(pg_temp.rcp_line(v_pq, 10, 1)));
  v_dn5 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_as(v_owner_a);
  PERFORM pg_temp.rcp_sell('rc-e3-pos', v_pq, 7, v_q, v_pm_other);
  IF pg_temp.rcp_stock(v_pq, v_q) <> 3 THEN
    v_failures := v_failures || format('FAIL (e3) setup: tras vender 7 de 10 el stock debía ser 3, es %s', pg_temp.rcp_stock(v_pq, v_q));
  END IF;
  PERFORM pg_temp.rcp_as(v_stocker);
  v_fp := pg_temp.rcp_footprint(v_account_a);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn5, 1, v_sup, v_q, jsonb_build_array(pg_temp.rcp_line(v_pq, 5, 1))));
  IF v_txt <> 'P0409 delivery_note_stock_consumed: de Gate RC Q en la sucursal quedan 3, el remito necesita restar 5' THEN
    v_failures := v_failures || format('FAIL (e3): bajar a 5 con 3 en la sucursal debía dar el texto exacto del faltante sobre el neto, salió %s', v_txt);
  END IF;
  IF pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp
     OR (SELECT quantity FROM public.delivery_note_items WHERE delivery_note_id = v_dn5) <> 10 THEN
    v_failures := v_failures || 'FAIL (e3): el rechazo por faltante debía dejar cero efectos y el remito con sus 10'::text;
  END IF;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn5, 1, v_sup, v_q, jsonb_build_array(pg_temp.rcp_line(v_pq, 8, 1))));
  IF v_txt <> 'OK' OR pg_temp.rcp_stock(v_pq, v_q) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn5 AND type = 'purchase'
                    AND reference_type = 'delivery_note' AND quantity_delta = 8 AND quantity_before = 3 AND quantity_after = 11)
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn5 AND type = 'purchase_return'
                    AND reference_type = 'delivery_note_update' AND quantity_delta = -10 AND quantity_before = 11 AND quantity_after = 1) THEN
    v_failures := v_failures || format('FAIL (e3): bajar a 8 debía funcionar (+8 y después -10, stock 1); salió %s, stock %s', v_txt, pg_temp.rcp_stock(v_pq, v_q));
  END IF;

  -- (e3b) el mismo texto, sin atribución de origen, con otra compra en el medio.
  v_r := pg_temp.rcp_issue('rc-e3b', v_sup, v_q, jsonb_build_array(pg_temp.rcp_line(v_pr, 10, 1)));
  v_dn6 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_as(v_owner_a);
  PERFORM public.rpc_create_purchase_operation('rc-e3b-compra', v_today, 'otra compra',
            jsonb_build_array(jsonb_build_object('product_id', v_pr, 'amount', 1, 'quantity', 5)), v_q);
  PERFORM pg_temp.rcp_sell('rc-e3b-pos', v_pr, 13, v_q, v_pm_other);
  IF pg_temp.rcp_stock(v_pr, v_q) <> 2 THEN
    v_failures := v_failures || format('FAIL (e3b) setup: 10 + 5 - 13 debía dejar 2, quedó %s', pg_temp.rcp_stock(v_pr, v_q));
  END IF;
  PERFORM pg_temp.rcp_as(v_stocker);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn6, 1, v_sup, v_q, jsonb_build_array(pg_temp.rcp_line(v_pr, 4, 1))));
  IF v_txt <> 'P0409 delivery_note_stock_consumed: de Gate RC R en la sucursal quedan 2, el remito necesita restar 6' THEN
    v_failures := v_failures || format('FAIL (e3b): con otra compra en el medio el texto debía seguir siendo el del stock y el neto, salió %s', v_txt);
  END IF;

  -- (e4) cambio de producto: reversa del viejo, aplicación del nuevo.
  v_r := pg_temp.rcp_issue('rc-e4', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pe, 2, 1)));
  v_dn7 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.rpc_update_purchase_delivery_note(v_dn7, 1, v_sup, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pf, 3, 1)));
  IF pg_temp.rcp_stock(v_pe, v_x) <> 0 OR pg_temp.rcp_stock(v_pf, v_x) <> 3
     OR (SELECT count(*) FROM public.delivery_note_items WHERE delivery_note_id = v_dn7 AND product_id = v_pf AND quantity = 3) <> 1 THEN
    v_failures := v_failures || format('FAIL (e4): cambiar E por F debía restar E y sumar F (E %s, F %s)', pg_temp.rcp_stock(v_pe, v_x), pg_temp.rcp_stock(v_pf, v_x));
  END IF;

  -- (e5) cambio de sucursal con cantidades iguales (compra): W -> Y.
  v_r := pg_temp.rcp_issue('rc-e5', v_sup, v_w, jsonb_build_array(pg_temp.rcp_line(v_pw, 4, 1)));
  v_dn8 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn8, 1, v_sup, v_y, jsonb_build_array(pg_temp.rcp_line(v_pw, 4, 1))));
  IF v_txt <> 'OK' OR pg_temp.rcp_stock(v_pw, v_w) <> 0 OR pg_temp.rcp_stock(v_pw, v_y) <> 4
     OR (SELECT branch_id FROM public.delivery_notes WHERE id = v_dn8) IS DISTINCT FROM v_y
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn8 AND branch_id = v_y AND type = 'purchase' AND quantity_delta = 4)
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn8 AND branch_id = v_w AND type = 'purchase_return'
                    AND reference_type = 'delivery_note_update' AND quantity_delta = -4) THEN
    v_failures := v_failures || format('FAIL (e5): mover el remito de compra de W a Y debía restar 4 en W, sumar 4 en Y y dejarlo en Y; salió %s (W %s, Y %s)',
      v_txt, pg_temp.rcp_stock(v_pw, v_w), pg_temp.rcp_stock(v_pw, v_y));
  END IF;

  -- (e6) cambio de sucursal con la vieja sin toda la mercadería.
  v_r := pg_temp.rcp_issue('rc-e6', v_sup, v_w, jsonb_build_array(pg_temp.rcp_line(v_pw2, 4, 1)));
  v_dn9 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_as(v_owner_a);
  PERFORM pg_temp.rcp_sell('rc-e6-pos', v_pw2, 3, v_w, v_pm_other);
  PERFORM pg_temp.rcp_as(v_stocker);
  v_fp := pg_temp.rcp_footprint(v_account_a);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn9, 1, v_sup, v_y, jsonb_build_array(pg_temp.rcp_line(v_pw2, 4, 1))));
  IF v_txt <> 'P0409 delivery_note_stock_consumed: de Gate RC W2 en la sucursal quedan 1, el remito necesita restar 4'
     OR pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp
     OR (SELECT branch_id FROM public.delivery_notes WHERE id = v_dn9) IS DISTINCT FROM v_w THEN
    v_failures := v_failures || format('FAIL (e6): mover sin toda la mercadería en la vieja -> P0409 sin efectos y el remito en W, salió %s', v_txt);
  END IF;

  -- (e7) el mismo cambio de sucursal sobre un remito de VENTA (núcleo extraído).
  PERFORM pg_temp.rcp_as(v_seller);
  v_r := public.rpc_create_sale_delivery_note('rc-e7-venta', v_client, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pa, 2, 150)));
  v_dn10 := (v_r->>'id')::uuid;
  v_r_expected := v_r_expected + 1;
  v_val := pg_temp.rcp_stock(v_pa, v_x);
  v_val2 := pg_temp.rcp_stock(v_pa, v_y);
  v_txt := pg_temp.rcp_err(format('SELECT public.rpc_update_delivery_note(%L::uuid, 1, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
                                  v_dn10, v_client, v_y, jsonb_build_array(pg_temp.rcp_line(v_pa, 2, 150))));
  IF v_txt <> 'OK' OR pg_temp.rcp_stock(v_pa, v_x) <> v_val + 2 OR pg_temp.rcp_stock(v_pa, v_y) <> v_val2 - 2
     OR (SELECT branch_id FROM public.delivery_notes WHERE id = v_dn10) IS DISTINCT FROM v_y
     OR (SELECT revision FROM public.delivery_notes WHERE id = v_dn10) <> 2 THEN
    v_failures := v_failures || format('FAIL (e7): mover un remito de VENTA de X a Y debía reponer 2 en X y retener 2 en Y; salió %s', v_txt);
  END IF;

  -- (e8) snapshot acarreado: renombrar y re-costear no cambia la línea ni el costo del movimiento.
  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-e8', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_psnap, 2, 1)));
  v_dn11 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  UPDATE public.products SET name = 'Gate RC Renombrado', cost = 99 WHERE id = v_psnap;
  PERFORM public.rpc_update_purchase_delivery_note(v_dn11, 1, v_sup, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_psnap, 3, 1)));
  IF (SELECT count(*) FROM public.delivery_note_items WHERE delivery_note_id = v_dn11
      AND name_snapshot = 'Gate RC Snap' AND unit_cost_snapshot = 30) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn11 AND quantity_delta = 3 AND unit_cost_snapshot = 30) THEN
    v_failures := v_failures || 'FAIL (e8): la edición debía acarrear el nombre y el costo congelados (Gate RC Snap / 30)'::text;
  END IF;

  -- (e9) producto dado de baja después de recibir: conservar / reducir sí, aumentar no.
  v_r := pg_temp.rcp_issue('rc-e9', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pdel, 3, 1)));
  v_dn12 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  UPDATE public.products SET deleted_at = now() WHERE id = v_pdel;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn12, 1, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pdel, 3, 9))));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (e9): conservar un producto dado de baja debía funcionar, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn12, 2, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pdel, 2, 9))));
  IF v_txt <> 'OK' OR pg_temp.rcp_stock(v_pdel, v_x) <> 2 THEN
    v_failures := v_failures || format('FAIL (e9): reducir un producto dado de baja debía funcionar (stock 2), salió %s / %s', v_txt, pg_temp.rcp_stock(v_pdel, v_x));
  END IF;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn12, 3, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pdel, 5, 9))));
  IF v_txt NOT LIKE 'P0400 delivery_note_product_unavailable%' THEN
    v_failures := v_failures || format('FAIL (e9): aumentar un producto dado de baja -> P0400 delivery_note_product_unavailable, salió %s', v_txt);
  END IF;

  -- (e10) rechazos de la edición, cada uno sin efectos.
  v_r := pg_temp.rcp_issue('rc-e10', v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1)));
  v_dn13 := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  v_fp := pg_temp.rcp_footprint(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('versión vieja',        pg_temp.rcp_update_sql(v_dn13, 9, v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0409 delivery_note_changed%'),
      ('sin versión',          pg_temp.rcp_update_sql(v_dn13, NULL, v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0400 delivery_note_revision_required%'),
      ('proveedor de baja',    pg_temp.rcp_update_sql(v_dn13, 1, v_sup_dead, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0404 supplier_not_found%'),
      ('proveedor ajeno',      pg_temp.rcp_update_sql(v_dn13, 1, v_sup_b, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0404 supplier_not_found%'),
      ('sin proveedor',        pg_temp.rcp_update_sql(v_dn13, 1, NULL, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0400 delivery_note_supplier_required%'),
      ('sucursal nueva ajena', pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_branch_b, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0404 branch_not_found%'),
      ('sucursal nueva cerrada', pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_closed, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0422 branch_closed%'),
      ('sucursal nueva inactiva', pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_inactive, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))), 'P0422 delivery_note_branch_inactive%'),
      ('referencia larga',     pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1)), repeat('9', 101)), 'P0400 delivery_note_supplier_reference_too_long%'),
      ('remito de venta',      pg_temp.rcp_update_sql(v_dnsale, 1, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1))), 'P0404 delivery_note_not_found%'),
      ('remito de otra cuenta', pg_temp.rcp_update_sql(v_dnb, 1, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1))), 'P0404 delivery_note_not_found%'),
      ('compra por la RPC de venta', format('SELECT public.rpc_update_delivery_note(%L::uuid, 1, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
                                       v_dn13, v_client, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1))), 'P0404 delivery_note_not_found%')
    ) AS t(label, sql, expected)
  LOOP
    v_txt := pg_temp.rcp_err(v_rec.sql);
    IF v_txt NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (e10) %s: se esperaba %s, salió %s', v_rec.label, v_rec.expected, v_txt);
    END IF;
  END LOOP;
  -- Roles: el vendedor y compras no editan remitos de compra.
  FOR v_rec IN SELECT * FROM (VALUES ('seller', v_seller), ('purchases', v_purchaser)) AS t(label, uid) LOOP
    PERFORM pg_temp.rcp_as(v_rec.uid);
    v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 2, 1))));
    IF v_txt NOT LIKE 'P0403 insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (e10): %s no debía editar un remito de compra, salió %s', v_rec.label, v_txt);
    END IF;
  END LOOP;
  PERFORM pg_temp.rcp_as(v_stocker);
  -- Sucursal vigente desactivada (forzado como postgres): edición y anulación -> P0422.
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = false WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1))));
  IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' THEN
    v_failures := v_failures || format('FAIL (e10): sucursal vigente desactivada -> P0422 delivery_note_branch_inactive, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rcp_as(v_admin);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn13, 1, 'sucursal muerta'));
  IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' THEN
    v_failures := v_failures || format('FAIL (e10): anular en una sucursal desactivada -> P0422, salió %s', v_txt);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = true WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  IF pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp THEN
    v_failures := v_failures || 'FAIL (e10): un rechazo de la edición dejó efectos'::text;
  END IF;
  -- Convertido (forzado como postgres): edición y anulación -> P0423 con el texto de compra.
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'converted' WHERE id = v_dn13;
  SET session_replication_role = DEFAULT;
  PERFORM pg_temp.rcp_as(v_stocker);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn13, 1, v_sup, v_z, jsonb_build_array(pg_temp.rcp_line(v_pz, 1, 1))));
  IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted: el remito ya se convirtió en compra%eliminá la compra%' THEN
    v_failures := v_failures || format('FAIL (e10): editar un convertido -> P0423 con el texto de compra, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rcp_as(v_admin);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn13, 1, 'convertido'));
  IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted: el remito ya se convirtió en compra: para anularlo, primero eliminá la compra%' THEN
    v_failures := v_failures || format('FAIL (e10): anular un convertido -> P0423 con el texto de compra, salió %s', v_txt);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'issued' WHERE id = v_dn13;
  SET session_replication_role = DEFAULT;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (f) Fila forjada en el ledger por PostgREST
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-f', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pforge, 3, 1)));
  v_dn := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pforge, v_x, 10);  -- stock 13
  PERFORM pg_temp.rcp_as(v_seller);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.stock_movements (account_id, product_id, type, quantity_delta, reference_id, reference_type, branch_id)
    VALUES (v_account_a, v_pforge, 'purchase', 1000, v_dn, 'delivery_note', v_x);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_failures := v_failures || format('FAIL (f) control positivo: la fila forjada debía poder insertarse (política preexistente), salió %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.rcp_as(v_admin);
  PERFORM public.rpc_cancel_delivery_note(v_dn, 1, 'fila forjada');
  IF pg_temp.rcp_stock(v_pforge, v_x) <> 10 THEN
    v_failures := v_failures || format('FAIL (f): la anulación debía restar exactamente 3 (lo aportado por las líneas), stock %s', pg_temp.rcp_stock(v_pforge, v_x));
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) Anulación
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-g-1', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pcan, 3, 1)));
  v_dn := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pcan, v_x, 2);  -- stock 5
  v_fp := pg_temp.rcp_footprint(v_account_a);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn, 1, 'el depósito no anula'));
  IF v_txt NOT LIKE 'P0403 insufficient_role: tu rol no permite anular remitos de compra (requiere administrador o dueño)%' THEN
    v_failures := v_failures || format('FAIL (g): stock no anula -> P0403 con el rótulo de compra, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rcp_as(v_purchaser);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn, 1, 'compras no anula'));
  IF v_txt NOT LIKE 'P0403 insufficient_role%' THEN
    v_failures := v_failures || format('FAIL (g): compras no anula -> P0403, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rcp_as(v_admin);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('sin motivo',     pg_temp.rcp_cancel_sql(v_dn, 1, '   '),                'P0400 delivery_note_cancel_reason_required%'),
      ('versión vieja',  pg_temp.rcp_cancel_sql(v_dn, 7, 'motivo'),             'P0409 delivery_note_changed%'),
      ('motivo largo',   pg_temp.rcp_cancel_sql(v_dn, 1, repeat('m', 501)),     'P0400 delivery_note_cancel_reason_too_long%')
    ) AS t(label, sql, expected)
  LOOP
    v_txt := pg_temp.rcp_err(v_rec.sql);
    IF v_txt NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (g) %s: se esperaba %s, salió %s', v_rec.label, v_rec.expected, v_txt);
    END IF;
  END LOOP;
  IF pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp THEN
    v_failures := v_failures || 'FAIL (g): un rechazo de la anulación dejó efectos'::text;
  END IF;
  v_r := public.rpc_cancel_delivery_note(v_dn, 1, 'el proveedor se llevó la mercadería');
  IF v_r->>'status' <> 'canceled' OR pg_temp.rcp_stock(v_pcan, v_x) <> 2
     OR NOT EXISTS (SELECT 1 FROM public.stock_movements WHERE reference_id = v_dn AND type = 'purchase_return'
                    AND reference_type = 'delivery_note_reversal' AND quantity_delta = -3 AND quantity_before = 5 AND quantity_after = 2
                    AND metadata->>'reverses' = 'delivery_note_cancel')
     OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'delivery_note_purchase'
                    AND document_id = v_dn AND from_status = 'issued' AND to_status = 'canceled'
                    AND reason = 'el proveedor se llevó la mercadería' AND performed_by = v_admin) THEN
    v_failures := v_failures || format('FAIL (g): anular con la mercadería en el depósito debía restar 3 (stock 2), purchase_return/delivery_note_reversal e historial con motivo; stock %s', pg_temp.rcp_stock(v_pcan, v_x));
  END IF;
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn, 1, 'otra vez'));
  IF v_txt NOT LIKE 'P0409 delivery_note_invalid_state%' THEN
    v_failures := v_failures || format('FAIL (g): segunda anulación -> P0409 delivery_note_invalid_state, salió %s', v_txt);
  END IF;
  PERFORM pg_temp.rcp_as(v_stocker);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_update_sql(v_dn, 2, v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pcan, 1, 1))));
  IF v_txt NOT LIKE 'P0409 delivery_note_invalid_state%' THEN
    v_failures := v_failures || format('FAIL (g): editar un anulado -> P0409 delivery_note_invalid_state, salió %s', v_txt);
  END IF;
  -- Transición fuera del catálogo (canceled -> issued), por cualquier camino: la base la rechaza.
  v_txt := pg_temp.rcp_err(format('UPDATE public.delivery_notes SET status = ''issued'' WHERE id = %L', v_dn));
  IF v_txt NOT LIKE 'P0409 fsm_violation%delivery_note_purchase%'
     OR (SELECT status FROM public.delivery_notes WHERE id = v_dn) <> 'canceled' THEN
    v_failures := v_failures || format('FAIL (g): canceled -> issued de un remito de compra debía rechazarse (fsm_violation, delivery_note_purchase), salió %s', v_txt);
  END IF;
  -- Con parte vendida: P0409 sin efectos, sigue issued.
  v_r := pg_temp.rcp_issue('rc-g-2', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_ppart, 10, 1), pg_temp.rcp_line(v_pcan, 1, 1)));
  v_dn := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_as(v_owner_a);
  PERFORM pg_temp.rcp_sell('rc-g-2-pos', v_ppart, 6, v_x, v_pm_other);
  PERFORM pg_temp.rcp_as(v_admin);
  v_fp := pg_temp.rcp_footprint(v_account_a);
  v_txt := pg_temp.rcp_err(pg_temp.rcp_cancel_sql(v_dn, 1, 'con parte vendida'));
  IF v_txt <> 'P0409 delivery_note_stock_consumed: de Gate RC Parte en la sucursal quedan 4, el remito necesita restar 10'
     OR pg_temp.rcp_footprint(v_account_a) IS DISTINCT FROM v_fp
     OR pg_temp.rcp_stock(v_ppart, v_x) <> 4 OR pg_temp.rcp_stock(v_pcan, v_x) <> 3
     OR (SELECT status FROM public.delivery_notes WHERE id = v_dn) <> 'issued' THEN
    v_failures := v_failures || format('FAIL (g): anular con parte vendida -> P0409 delivery_note_stock_consumed sin efectos (ningún par restado), salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (h) Invariante del ledger: Σ delta = Δ stock = +aportado; 0 tras anular
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pi, v_x, 20);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pi, v_y, 20);
  v_r := pg_temp.rcp_issue('rc-h', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pi, 6, 1)));
  v_dn := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.rpc_update_purchase_delivery_note(v_dn, 1, v_sup, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pi, 9, 1)));
  PERFORM public.rpc_update_purchase_delivery_note(v_dn, 2, v_sup, v_y, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pi, 4, 1)));
  FOR v_rec IN SELECT * FROM (VALUES (v_x, 0::numeric, 20::numeric), (v_y, 4::numeric, 24::numeric)) AS t(bid, held, stock) LOOP
    SELECT COALESCE(sum(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE reference_id = v_dn AND branch_id = v_rec.bid;
    IF v_val <> v_rec.held OR pg_temp.rcp_stock(v_pi, v_rec.bid) <> v_rec.stock THEN
      v_failures := v_failures || format('FAIL (h): Σ delta en %s = %s (esperado %s), stock %s (esperado %s)',
        v_rec.bid, v_val, v_rec.held, pg_temp.rcp_stock(v_pi, v_rec.bid), v_rec.stock);
    END IF;
  END LOOP;
  PERFORM pg_temp.rcp_as(v_owner_a);
  PERFORM public.rpc_cancel_delivery_note(v_dn, 3, 'invariante');
  SELECT COALESCE(sum(quantity_delta), 0) INTO v_val FROM public.stock_movements WHERE reference_id = v_dn;
  IF v_val <> 0 OR pg_temp.rcp_stock(v_pi, v_x) <> 20 OR pg_temp.rcp_stock(v_pi, v_y) <> 20 THEN
    v_failures := v_failures || format('FAIL (h): tras anular, el ledger del remito debía cerrar en 0 y el stock volver a 20/20 (Σ %s, X %s, Y %s)',
      v_val, pg_temp.rcp_stock(v_pi, v_x), pg_temp.rcp_stock(v_pi, v_y));
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (i) PostgREST: sin escritura directa ni helpers; la RPC sí
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  EXECUTE 'SET LOCAL ROLE authenticated';
  FOR v_txt IN
    SELECT unnest(ARRAY[
      format('INSERT INTO public.delivery_notes (account_id, direction, branch_id, supplier_id, status, issued_on) VALUES (%L, ''purchase'', %L, %L, ''issued'', current_date)', v_account_a, v_x, v_sup),
      format('UPDATE public.delivery_notes SET total = 0 WHERE id = %L', v_dn1),
      format('DELETE FROM public.delivery_note_items WHERE delivery_note_id = %L', v_dn1),
      format('SELECT public._delivery_note_assert_role_dir(%L::uuid, ''issue'', ''purchase'')', v_account_a),
      format('SELECT public._delivery_note_replace_content(%L::uuid, %L::uuid, ''[]''::jsonb)', v_dn1, v_x),
      format('SELECT public._delivery_note_apply_stock(%L::uuid, %L::uuid, gen_random_uuid(), ''[]''::jsonb)', v_account_a, v_dn1),
      format('SELECT public._delivery_note_reverse_held(%L::uuid, %L::uuid, gen_random_uuid(), ''[]''::jsonb, ''delivery_note_reversal'', ''x'')', v_account_a, v_dn1),
      format('SELECT public._delivery_note_payload(%L::uuid)', v_dn1)
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
  BEGIN
    v_r := public.rpc_create_purchase_delivery_note('rc-i-1', v_sup, v_x, NULL, NULL, jsonb_build_array(pg_temp.rcp_line(v_pb, 1, 1)));
    v_rc_expected := v_rc_expected + 1;
    SELECT count(*) INTO v_n FROM public.delivery_notes WHERE id = (v_r->>'id')::uuid;
    IF v_n <> 1 THEN
      v_failures := v_failures || 'FAIL (i): el miembro debía leer su remito de compra por la RLS de SELECT'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_failures := v_failures || format('FAIL (i): la RPC como authenticated debía funcionar, salió %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  IF (SELECT total FROM public.delivery_notes WHERE id = v_dn1) = 0
     OR NOT EXISTS (SELECT 1 FROM public.delivery_note_items WHERE delivery_note_id = v_dn1) THEN
    v_failures := v_failures || 'FAIL (i): una escritura directa cambió el remito de compra'::text;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) Guards de unidad con líneas de remito de compra
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  PERFORM pg_temp.rcp_issue('rc-j-1', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pnobase, 1, 2, NULL, v_u)));
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_issue('rc-j-2', v_sup, v_x, jsonb_build_array(pg_temp.rcp_line(v_pbulto, 1, 2, NULL, v_bulto)));
  v_rc_expected := v_rc_expected + 1;
  PERFORM pg_temp.rcp_as(v_owner_a);
  v_txt := pg_temp.rcp_err(format('UPDATE public.products SET base_unit_id = %L WHERE id = %L', v_kg, v_pnobase));
  IF v_txt NOT LIKE 'P0409 base_unit_locked%' THEN
    v_failures := v_failures || format('FAIL (j): asignar Kilogramo a un producto con una línea de remito de compra en Unidad -> P0409 base_unit_locked, salió %s', v_txt);
  END IF;
  v_txt := pg_temp.rcp_err(format('UPDATE public.units_of_measure SET factor = 2 WHERE id = %L', v_bulto));
  IF v_txt NOT LIKE 'P0409 unit_in_use%' THEN
    v_failures := v_failures || format('FAIL (j): cambiar el factor de una unidad usada sólo en un remito de compra -> P0409 unit_in_use, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (k) Baja de sucursal con un remito de compra pendiente
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(v_stocker);
  v_r := pg_temp.rcp_issue('rc-k-1', v_sup, v_v, jsonb_build_array(pg_temp.rcp_line(v_pv, 2, 1)));
  v_dnk := (v_r->>'id')::uuid;
  v_rc_expected := v_rc_expected + 1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pv, v_v, -2);  -- sin existencias: sólo bloquea el remito
  PERFORM pg_temp.rcp_as(v_owner_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('disparador',            format('UPDATE public.branches SET is_active = false WHERE id = %L', v_v)),
      ('rpc_deactivate_branch', format('SELECT public.rpc_deactivate_branch(%L::uuid)', v_v)),
      ('rpc_close_branch',      format('SELECT public.rpc_close_branch(%L::uuid)', v_v))
    ) AS t(label, sql)
  LOOP
    v_txt := pg_temp.rcp_err(v_rec.sql);
    IF v_txt NOT LIKE 'P0428 branch_has_pending_delivery_notes%' THEN
      v_failures := v_failures || format('FAIL (k) %s: baja con un remito de compra pendiente -> P0428 branch_has_pending_delivery_notes, salió %s', v_rec.label, v_txt);
    END IF;
  END LOOP;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pv, v_v, 2);
  PERFORM public.rpc_cancel_delivery_note(v_dnk, 1, 'cierre de sucursal');
  v_txt := pg_temp.rcp_err(format('SELECT public.rpc_deactivate_branch(%L::uuid)', v_v));
  IF v_txt <> 'OK' THEN
    v_failures := v_failures || format('FAIL (k): anulado el remito (stock en 0), la baja debía proceder, salió %s', v_txt);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (l) Numeración RC 1..N sin huecos; la R de venta intacta
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT count(*) AS c, count(DISTINCT number) AS d, COALESCE(min(number), 0) AS mn, COALESCE(max(number), 0) AS mx
  INTO v_rec FROM public.delivery_notes WHERE account_id = v_account_a AND direction = 'purchase';
  SELECT last_number INTO v_n FROM public.internal_document_sequences
  WHERE account_id = v_account_a AND document_type = 'delivery_note_purchase';
  IF v_rec.c <> v_rc_expected OR v_rec.d <> v_rec.c OR v_rec.c <> v_rec.mx OR v_rec.mn <> 1 OR v_n <> v_rc_expected THEN
    v_failures := v_failures || format('FAIL (l): numeración RC: %s remitos, %s distintos, min %s, max %s, secuencia %s (esperado 1..%s)',
      v_rec.c, v_rec.d, v_rec.mn, v_rec.mx, v_n, v_rc_expected);
  END IF;
  SELECT count(*) AS c, COALESCE(max(number), 0) AS mx INTO v_rec
  FROM public.delivery_notes WHERE account_id = v_account_a AND direction = 'sale';
  SELECT last_number INTO v_n FROM public.internal_document_sequences
  WHERE account_id = v_account_a AND document_type = 'delivery_note_sale';
  IF v_rec.c <> v_r_expected OR v_rec.mx <> v_r_expected OR v_n <> v_r_expected THEN
    v_failures := v_failures || format('FAIL (l): la numeración R de venta debía quedar en 1..%s, quedó %s remitos / max %s / secuencia %s',
      v_r_expected, v_rec.c, v_rec.mx, v_n);
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza (toda fila con account_id de las cuentas del gate) y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcp_as(NULL);
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
     OR EXISTS (SELECT 1 FROM public.purchases WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.sales WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.internal_document_sequences WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.document_status_history WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = ANY (v_users))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE REMITOS-COMPRA FAILED (% fallas):\n  %', array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE REMITOS-COMPRA PASSED: helpers por sentido, recepción que suma, rechazos sin efectos, idempotencia, roles por sentido, edición con faltante sobre el neto (patas que suman primero, cambio de sucursal en los dos sentidos), fila forjada, anulación bloqueada si se consumió, invariante del ledger, PostgREST, guards de unidad, baja de sucursal y numeración RC — residuo cero.';

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
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- ── (o1) ACLs (sin fixtures) ────────────────────────────────────────────────
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   text;
  v_internal text[] := ARRAY[
    'public._delivery_note_assert_role_dir(uuid, text, text)',
    'public._delivery_note_assert_role(uuid, text)',
    'public._delivery_note_replace_content(uuid, uuid, jsonb)',
    'public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)',
    'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)',
    'public._delivery_note_payload(uuid)',
    'public._branch_pending_delivery_notes(uuid)'
  ];
  v_public text[] := ARRAY[
    'public.rpc_create_purchase_delivery_note(text, uuid, uuid, text, text, jsonb)',
    'public.rpc_update_purchase_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)',
    'public.rpc_cancel_delivery_note(uuid, integer, text)',
    'public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)'
  ];
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
  -- Sin overload: el núcleo de rol de compra tiene nombre propio (D7).
  IF (SELECT count(*) FROM pg_proc WHERE proname = '_delivery_note_assert_role' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    v_bad := v_bad || '_delivery_note_assert_role tiene un overload'::text;
  END IF;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE REMITOS-COMPRA FAILED (o1):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (o1): helpers sin EXECUTE para authenticated/anon; las RPCs de compra y las dos reescritas SECURITY DEFINER, con COMMENT, sin anon y con authenticated; _delivery_note_assert_role sin overload.';
END $$;

-- ── (o2) Catálogo de transiciones de delivery_note_purchase (sin fixtures) ───
DO $$
DECLARE
  v_n int;
BEGIN
  -- Presencia por clave y atributos, nunca conteo exacto: la tanda B suma
  -- issued -> converted y converted -> issued (D3).
  SELECT count(*) INTO v_n
  FROM   public.document_status_transitions
  WHERE  document_type = 'delivery_note_purchase'
    AND  (from_status, to_status) IS DISTINCT FROM (NULL::text, 'issued'::text)
    AND  (from_status, to_status) NOT IN (('issued', 'canceled'), ('issued', 'converted'), ('converted', 'issued'));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (o2): delivery_note_purchase tiene % fila(s) fuera del conjunto declarado', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status IS NULL AND to_status = 'issued'
                   AND allowed_role @> ARRAY['stock', 'admin', 'owner'] AND cardinality(allowed_role) = 3
                   AND NOT requires_reason AND NOT is_terminal_to) THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (o2): falta NULL -> issued con {stock,admin,owner}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'issued' AND to_status = 'canceled'
                   AND allowed_role @> ARRAY['admin', 'owner'] AND cardinality(allowed_role) = 2
                   AND requires_reason AND is_terminal_to) THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (o2): falta issued -> canceled con {admin,owner}, motivo y terminal';
  END IF;
  RAISE NOTICE 'PASS (o2): catálogo delivery_note_purchase con NULL -> issued {stock,admin,owner} e issued -> canceled {admin,owner} (motivo, terminal).';
END $$;

-- ── (o3) Una transición fuera del catálogo la rechaza la base ────────────────
DO $$
DECLARE
  v_state text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.delivery_notes'::regclass
                 AND tgname = 'delivery_notes_enforce_status_transition_purchase') THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (o3): falta delivery_notes_enforce_status_transition_purchase';
  END IF;
  IF NOT public.is_valid_transition('delivery_note_purchase', 'issued', 'canceled')
     OR public.is_valid_transition('delivery_note_purchase', 'canceled', 'issued') THEN
    RAISE EXCEPTION 'GATE REMITOS-COMPRA FAILED (o3): is_valid_transition no refleja el catálogo de compra (canceled -> issued debía ser inválida)';
  END IF;
  RAISE NOTICE 'PASS (o3): el disparador de enforcement de compra existe y canceled -> issued no es una transición válida.';
END $$;
