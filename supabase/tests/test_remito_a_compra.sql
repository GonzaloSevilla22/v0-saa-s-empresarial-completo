-- =============================================================================
-- test_remito_a_compra.sql — Gate de comportamiento de la TANDA B de
-- `remitos-compra` (migración 20261081000001_remitos_compra_conversion.sql).
--
-- Regla del proyecto: toda RPC nueva necesita un gate que la EJECUTE de
-- verdad. Este archivo ejecuta, contra Postgres real y con usuarios reales
-- (owner, admin, stock, purchases, seller y cashier de la cuenta A con
-- membresía en account_members y roles en account_member_roles, más un owner
-- de la cuenta B), la RPC nueva rpc_convert_delivery_note_to_purchase, el
-- núcleo interno _purchase_operation_core y las tres funciones que esta tanda
-- reescribe desde su cuerpo vivo: rpc_create_purchase_operation (wrapper),
-- rpc_delete_purchase_operation (salto de la reversa de stock, lock del
-- remito, rol y reapertura) y rpc_atomic_update_purchase_operation (P0423
-- delivery_note_purchase_locked), más el disparador que protege el puente
-- purchases.source_delivery_note_id.
--
-- Matriz (tasks.md 6.2 / 6.9, design.md §D8, §D9, §D16):
--   (g0) GOLDEN de la compra directa: valores esperados FIJOS por caso (cash
--        con caja, credit con cargo y vencimiento, transfer con banco, línea
--        sin producto, unidad no base y replay) sobre purchases / purchase_items
--        / stock_movements / caja / banco / cuenta corriente y PurchaseCreated.
--        Se escribieron y pasaron contra el cuerpo VIVO antes de extraer el
--        núcleo; tienen que seguir pasando después.
--   (z)  CONTROL NEGATIVO — núcleo invocado directo (como postgres, con los
--        claims de un owner) con un origen válido: NO suma stock ni escribe
--        movimientos, las filas toman los cuatro snapshots del remito y el
--        remito queda `converted` con su historial. Con la columna aplicada y
--        el núcleo sin la rama de origen este bloque FALLA (la compra viva suma
--        igual): es la prueba de que el gate detecta la doble suma.
--   (n)  núcleo con un origen inválido: remito de otra cuenta, de venta,
--        anulado, convertido, de otro proveedor, de otra sucursal, con p_items
--        del request y con una compra ya existente con ese origen -> P0409
--        delivery_note_purchase_mismatch / P0400 delivery_note_items_from_source,
--        sin compra, stock, evento ni idempotencia.
--   (a)  conversión cash: stock idéntico, 0 movimientos de las filas de la
--        compra, caja, PurchaseCreated, filas con origen, remito converted
--        (revisión intacta), historial, resultado {delivery_note_id,
--        delivery_note_number, operation_id, total, replayed}, snapshots del
--        remito (producto renombrado y costo remarcado DESPUÉS de recibir),
--        total de la compra = total del remito, payload con la compra generada.
--   (b)  credit como `authenticated` por el rol purchases: cargo con vencimiento
--        por la cascada (plazo del proveedor), sin caja ni stock.
--   (c)  transfer con banco en otra sucursal; (d) producto dado de baja: convierte.
--   (e)  proveedor dado de baja: P0404 delivery_note_supplier_unavailable;
--        (f) sucursal desactivada o cerrada: P0422 branch_closed.
--   (p0) precio 0: P0400 delivery_note_price_required; fecha anterior al remito:
--        P0400 delivery_note_purchase_date_before_receipt.
--   (g/h/i) replay, clave sobre otro remito, segunda conversión.
--   (j/k/l) versión vieja y parámetros; roles (stock y purchases convierten,
--        seller y cashier no); remito ajeno; caja con sesión de otra sucursal,
--        con otra fecha o con una forma de pago que no es efectivo.
--   (q/r) editar la compra de un remito -> P0423 delivery_note_purchase_locked
--        antes del P0423 de dinero y sin efectos; anular un convertido -> P0423;
--        el P0423 de dinero de una compra directa no cambia.
--   (o)  borrar la compra: dinero compensado, stock idéntico, remito issued con
--        historial converted -> issued y motivo, reconvertir funciona; el rol
--        purchases no borra (P0403 delivery_note_purchase_delete_forbidden);
--        origen de otra cuenta o de venta -> P0409 sin reabrirlo; mezcla de
--        orígenes -> P0409; segundo borrado sin efectos.
--   (p)  borrar con la sucursal del remito desactivada / cerrada: P0422.
--   (pg) integridad del puente por PostgREST con un seller real: forjar, limpiar,
--        cambiar, INSERT con origen, partir, mezclar y borrar -> P0403
--        delivery_note_source_protected, cada uno con su control positivo sobre
--        una compra directa.
--   (s)  invariante: ninguna fila de una compra con origen tiene movimiento de stock.
--   (u)  introspección (bloques DO aparte, sin fixtures).
--
-- Patrón del proyecto: fallas acumuladas en text[], un solo RAISE al final;
-- anchors sintéticos vía handle_new_user; sesión simulada con set_config LOCAL
-- (NUNCA contra prod); limpieza de TODA fila de las cuentas del gate y residuo
-- cero ASERTADO.
--
-- Corre en CI: KPI_Validation.yml ("Run remito a compra gate").
-- =============================================================================

-- Los helpers nombran objetos de la migración: sin validar el cuerpo al
-- crearlos, el RED falla por la RPC inexistente (42883).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION pg_temp.rcb_as(p_uid uuid) RETURNS void
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

CREATE OR REPLACE FUNCTION pg_temp.rcb_line(p_product uuid, p_qty numeric, p_price numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty,
                            'price', p_price, 'subtotal', p_qty * p_price);
$f$;

-- Línea de la compra DIRECTA (p_items de rpc_create_purchase_operation).
CREATE OR REPLACE FUNCTION pg_temp.rcb_pline(p_product uuid, p_qty numeric, p_amount numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty, 'amount', p_amount);
$f$;

-- 'OK' o 'SQLSTATE mensaje'; el error revierte lo que la sentencia escribió.
CREATE OR REPLACE FUNCTION pg_temp.rcb_err(p_sql text) RETURNS text
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

CREATE OR REPLACE FUNCTION pg_temp.rcb_issue(p_key text, p_supplier uuid, p_branch uuid, p_items jsonb)
RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
  RETURN (public.rpc_create_purchase_delivery_note(p_key, p_supplier, p_branch, NULL, NULL, p_items)->>'id')::uuid;
END;
$f$;

-- Conversión: 'OK|<json>' o 'ERR|<sqlstate>|<mensaje>'. El bloque EXCEPTION
-- revierte la subtransacción, que es lo que ve el backend.
CREATE OR REPLACE FUNCTION pg_temp.rcb_convert(p_key text, p_dn uuid, p_rev integer, p_pm uuid,
                                               p_date date DEFAULT NULL, p_session uuid DEFAULT NULL,
                                               p_bank uuid DEFAULT NULL, p_due date DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v       jsonb;
  v_state text;
  v_msg   text;
BEGIN
  v := public.rpc_convert_delivery_note_to_purchase(
         p_idempotency_key   => p_key,
         p_delivery_note_id  => p_dn,
         p_expected_revision => p_rev,
         p_payment_method_id => p_pm,
         p_date              => p_date,
         p_cash_session_id   => p_session,
         p_bank_account_id   => p_bank,
         p_cost_center_id    => NULL,
         p_due_date          => p_due,
         p_description       => NULL);
  RETURN 'OK|' || v::text;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.rcb_rev(p_dn uuid) RETURNS integer
LANGUAGE sql AS $f$ SELECT revision FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rcb_status(p_dn uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT status FROM public.delivery_notes WHERE id = p_dn; $f$;

CREATE OR REPLACE FUNCTION pg_temp.rcb_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT quantity FROM public.branch_stock WHERE product_id = p_product AND branch_id = p_branch), 0);
$f$;

-- Movimientos de stock de las filas de una compra (una compra nacida de un
-- remito no tiene ninguno).
CREATE OR REPLACE FUNCTION pg_temp.rcb_purchase_moves(p_op uuid) RETURNS bigint
LANGUAGE sql AS $f$
  SELECT count(*) FROM public.stock_movements sm
  WHERE sm.reference_id IN (SELECT p.id FROM public.purchases p WHERE p.operation_id = p_op);
$f$;

-- Huella de todo lo que una conversión, un borrado o una edición pueden tocar
-- en la cuenta: comparar antes/después de un rechazo prueba "cero efectos".
CREATE OR REPLACE FUNCTION pg_temp.rcb_effects(p_account uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws(' ',
    'pu=' || (SELECT count(*) FROM public.purchases WHERE account_id = p_account),
    -- to_jsonb: la columna del puente no existe antes de la migración (RED del golden).
    'pu_src=' || (SELECT count(*) FROM public.purchases p WHERE p.account_id = p_account AND to_jsonb(p)->>'source_delivery_note_id' IS NOT NULL),
    'pi=' || (SELECT count(*) FROM public.purchase_items WHERE account_id = p_account),
    'sm=' || (SELECT count(*) FROM public.stock_movements WHERE account_id = p_account),
    'bs=' || (SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = p_account),
    'cash=' || (SELECT count(*) FROM public.cash_movements cm
                JOIN public.cash_sessions cs ON cs.id = cm.session_id
                JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
                JOIN public.branches b ON b.id = cb.branch_id
                WHERE b.account_id = p_account),
    'sam=' || (SELECT count(*) FROM public.supplier_account_movements WHERE account_id = p_account),
    'bank=' || (SELECT count(*) FROM public.bank_movements WHERE account_id = p_account),
    'events=' || (SELECT count(*) FROM public.events WHERE account_id = p_account),
    'history=' || (SELECT count(*) FROM public.document_status_history WHERE account_id = p_account),
    'idem=' || (SELECT count(*) FROM public.operation_idempotency oi
                WHERE oi.user_id IN (SELECT am.user_id FROM public.account_members am WHERE am.account_id = p_account)),
    'dn=' || COALESCE((SELECT string_agg(status || ':' || n || ':' || r, ',' ORDER BY status)
                       FROM (SELECT status, count(*) AS n, sum(revision) AS r FROM public.delivery_notes WHERE account_id = p_account GROUP BY status) d), ''));
$f$;

-- Núcleo llamado DIRECTO (como postgres, con los claims del actor) con un
-- origen de remito: 'OK|<json>' o 'ERR|<sqlstate>|<mensaje>'. Un error revierte
-- la subtransacción.
CREATE OR REPLACE FUNCTION pg_temp.rcb_core(p_key text, p_account uuid, p_branch uuid, p_supplier uuid,
                                            p_dn uuid, p_pm uuid, p_items jsonb DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v       jsonb;
  v_state text;
  v_msg   text;
BEGIN
  v := public._purchase_operation_core(
         p_account, p_key, public.reporting_local_today(), 'Gate RaC: núcleo directo', p_items,
         p_branch, NULL, p_pm, NULL, p_supplier, NULL, NULL, p_dn);
  RETURN 'OK|' || v::text;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END;
$f$;

-- Retrato canónico (sin ids ni timestamps) de todo lo que una compra escribe:
-- es el "golden" de la compra directa. Los ids se reemplazan por etiquetas.
CREATE OR REPLACE FUNCTION pg_temp.rcb_snap(p_op uuid, p_labels jsonb, p_ref date) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws(E'\n',
    (SELECT string_agg(format('PU|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_labels->>pu.product_id::text, '-'), pu.amount, pu.quantity,
         COALESCE(p_labels->>pu.unit_id::text, '-'), pu.total, COALESCE(p_labels->>pu.branch_id::text, '-'),
         COALESCE(pu.name_snapshot, '-'), COALESCE(pu.sku_snapshot, '-'), COALESCE(pu.unit_cost_snapshot::text, '-'),
         COALESCE(pu.iva_rate_snapshot::text, '-'), COALESCE(p_labels->>pu.supplier_id::text, '-'),
         COALESCE(p_labels->>pu.payment_method_id::text, '-')),
       E'\n' ORDER BY COALESCE(p_labels->>pu.product_id::text, '-'), pu.amount, pu.quantity)
     FROM public.purchases pu WHERE pu.operation_id = p_op),
    (SELECT string_agg(format('PI|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_labels->>pi.product_id::text, '-'), pi.quantity, COALESCE(p_labels->>pi.unit_id::text, '-'),
         pi.price, pi.subtotal, COALESCE(pi.name_snapshot, '-'), COALESCE(pi.sku_snapshot, '-'),
         COALESCE(pi.unit_cost_snapshot::text, '-')),
       E'\n' ORDER BY COALESCE(p_labels->>pi.product_id::text, '-'), pi.price, pi.quantity)
     FROM public.purchase_items pi WHERE pi.purchase_id IN (SELECT id FROM public.purchases WHERE operation_id = p_op)),
    (SELECT string_agg(format('SM|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_labels->>sm.product_id::text, '-'), sm.type, sm.reference_type, sm.quantity_delta,
         sm.quantity_before, sm.quantity_after, COALESCE(p_labels->>sm.branch_id::text, '-'),
         COALESCE(sm.unit_cost_snapshot::text, '-')),
       E'\n' ORDER BY COALESCE(p_labels->>sm.product_id::text, '-'), sm.quantity_delta)
     FROM public.stock_movements sm
     WHERE sm.reference_id IN (SELECT id FROM public.purchases WHERE operation_id = p_op)),
    (SELECT string_agg(format('CM|%s|%s', cm.movement_type, cm.amount), E'\n' ORDER BY cm.movement_type, cm.amount)
     FROM public.cash_movements cm WHERE cm.reference_id = p_op),
    (SELECT string_agg(format('BM|%s|%s|%s|%s', bm.movement_type, bm.amount, COALESCE(p_labels->>bm.branch_id::text, '-'),
                              bm.source_doc_type), E'\n' ORDER BY bm.movement_type, bm.amount)
     FROM public.bank_movements bm WHERE bm.source_doc_ref = p_op),
    (SELECT string_agg(format('SA|%s|%s|%s', sam.movement_type, sam.amount,
                              COALESCE((sam.due_date - p_ref)::text, '-')), E'\n' ORDER BY sam.movement_type, sam.amount)
     FROM public.supplier_account_movements sam WHERE sam.reference_id = p_op),
    (SELECT string_agg(format('EV|%s|%s|%s|%s', e.event_type, e.payload->>'total', e.payload->>'payment_method',
                              COALESCE(e.payload->>'cost_center_id', '-')), E'\n' ORDER BY e.event_type)
     FROM public.events e WHERE e.aggregate_id = p_op));
$f$;

DO $$
DECLARE
  v_failures      text[] := '{}';
  v_fail_before   integer;
  v_tag           text := 'rac-' || gen_random_uuid()::text || '-';

  v_owner_a       uuid := gen_random_uuid();
  v_owner_b       uuid := gen_random_uuid();
  v_admin         uuid := gen_random_uuid();
  v_stocker       uuid := gen_random_uuid();
  v_purchaser     uuid := gen_random_uuid();
  v_seller        uuid := gen_random_uuid();
  v_cashier       uuid := gen_random_uuid();
  v_users         uuid[];
  v_accounts      uuid[];
  v_account_a     uuid;
  v_account_b     uuid;
  v_member        uuid;

  v_x uuid; v_y uuid; v_z uuid; v_cl uuid; v_branch_b uuid;
  v_cashbox_x uuid; v_session_x uuid; v_cashbox_y uuid; v_session_y uuid;
  v_bank_a uuid;
  v_pm_cash uuid; v_pm_credit uuid; v_pm_transfer uuid; v_pm_other uuid; v_pm_cash_b uuid;
  v_s1 uuid; v_s2 uuid; v_s_gone uuid; v_sup_b uuid; v_client uuid;
  v_u uuid; v_kg uuid; v_g uuid; v_u2 uuid;
  v_p1 uuid; v_p2 uuid; v_pren uuid; v_pdead uuid; v_pkg uuid; v_pg uuid; v_pb uuid;

  v_dn_core uuid; v_dn_mm uuid; v_dn_canc uuid; v_dn_fake uuid; v_dn_b uuid; v_dn_sale uuid;
  v_dn_cash uuid; v_dn_credit uuid; v_dn_transfer uuid; v_dn_dead uuid; v_dn_gone uuid;
  v_dn_z uuid; v_dn_cl uuid; v_dn_other uuid; v_dn_stk uuid; v_dn_nomoney uuid; v_dn_noprice uuid;
  v_dn_caja uuid; v_dn_pur uuid; v_dn_delbr uuid; v_dn_clbr uuid; v_dn_sec uuid;

  v_key_cash    text;
  v_op_cash     uuid;
  v_op_credit   uuid;
  v_op_transfer uuid;
  v_op_re       uuid;
  v_op_pur      uuid;
  v_op_caja     uuid;
  v_op_nomoney  uuid;

  v_today   date := public.reporting_local_today();
  v_r       text;
  v_j       jsonb;
  v_txt     text;
  v_before  text;
  v_after   text;
  v_n       bigint;
  v_n2      bigint;
  v_val     numeric;
  v_date    date;
  v_a1 numeric; v_a2 numeric; v_a3 numeric; v_a4 numeric;
  v_sm      bigint;
  v_items   jsonb;
  v_ids     uuid[];
  v_rec     RECORD;
  v_state   text;
  v_msg     text;
  v_table   text;
  v_labels  jsonb;
  v_snap    text;
  v_uuid    uuid;
  v_op_d1   uuid; v_op_d2 uuid; v_op_d3 uuid; v_op_d4 uuid; v_op_d5 uuid; v_op_d6 uuid;
  v_gold_cash   text; v_gold_credit text; v_gold_transfer text; v_gold_service text; v_gold_unit text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup
  -- ═══════════════════════════════════════════════════════════════════════
  v_users := ARRAY[v_owner_a, v_owner_b, v_admin, v_stocker, v_purchaser, v_seller, v_cashier];

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'remito-a-compra-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Gate RaC ' || u.tag, 'phone', '', 'locality', '', 'province', '')
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
  VALUES (v_account_a, 'Gate RaC Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RaC Z', TRUE, 'active', now(), now() + interval '2 minutes') RETURNING id INTO v_z;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_account_a, 'Gate RaC Cierra', TRUE, 'active', now(), now() + interval '3 minutes') RETURNING id INTO v_cl;

  SELECT id INTO v_cashbox_x FROM public.cashboxes WHERE branch_id = v_x ORDER BY created_at LIMIT 1;
  IF v_cashbox_x IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_x, 'Caja Gate RaC X') RETURNING id INTO v_cashbox_x;
  END IF;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_x, 'open', 0, v_owner_a) RETURNING id INTO v_session_x;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_y, 'Caja Gate RaC Y') RETURNING id INTO v_cashbox_y;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_y, 'open', 0, v_owner_a) RETURNING id INTO v_session_y;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, 'Banco Gate RaC', 'ARS', 0) RETURNING id INTO v_bank_a;

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
  IF v_pm_cash IS NULL OR v_pm_credit IS NULL OR v_pm_transfer IS NULL OR v_pm_other IS NULL OR v_pm_cash_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: faltan formas de pago sembradas';
  END IF;

  INSERT INTO public.suppliers (account_id, name, phone, payment_terms_days) VALUES (v_account_a, 'Proveedor Gate RaC', '2615550404', 30) RETURNING id INTO v_s1;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, 'Proveedor Gate RaC 2') RETURNING id INTO v_s2;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_a, 'Proveedor Gate RaC Se Va') RETURNING id INTO v_s_gone;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_b, 'Proveedor Gate RaC B') RETURNING id INTO v_sup_b;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner_a, v_account_a, 'Cliente Gate RaC') RETURNING id INTO v_client;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Unidad RaC', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Bulto RaC', 'bto', 'unit', 1, false) RETURNING id INTO v_u2;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo RaC', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system)
  VALUES (v_account_a, 'Gramo RaC', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC P1', 'GRAC-P1', 100, 1000, v_u) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC P2', 'GRAC-P2', 50, 500, v_u) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC Renombrado', 'GRAC-REN', 30, 300, v_u) RETURNING id INTO v_pren;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC Se Discontinua', 'GRAC-DEAD', 20, 200, v_u) RETURNING id INTO v_pdead;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC Kg', 'GRAC-KG', 1000, 2000, v_kg) RETURNING id INTO v_pkg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_owner_a, v_account_a, 'Gate RaC Golden', 'GRAC-G', 40, 80, v_u) RETURNING id INTO v_pg;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'Gate RaC B', 'GRAC-B', 10, 100) RETURNING id INTO v_pb;

  v_labels := jsonb_build_object(v_p1::text, 'p1', v_p2::text, 'p2', v_pren::text, 'pren', v_pdead::text, 'pdead',
                                 v_pkg::text, 'pkg', v_pg::text, 'pg', v_x::text, 'X', v_y::text, 'Y', v_z::text, 'Z',
                                 v_u::text, 'u', v_kg::text, 'kg', v_g::text, 'g', v_s1::text, 's1', v_s2::text, 's2',
                                 v_pm_cash::text, 'cash', v_pm_credit::text, 'credit', v_pm_transfer::text, 'transfer');

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g0) GOLDEN de la compra directa — escrito y verde contra el cuerpo VIVO
  -- ═══════════════════════════════════════════════════════════════════════
  -- Valores esperados FIJOS (medidos una vez contra el cuerpo vivo de prod,
  -- 361a1ffc…); tienen que seguir iguales tras extraer el núcleo.
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  PERFORM pg_temp.rcb_as(v_owner_a);

  v_gold_cash := E'PU|p1|1000|2.0000|-|2000|X|Gate RaC P1|GRAC-P1|100.00|-|s1|cash\n'
              || E'PI|p1|2.0000|-|1000|2000|Gate RaC P1|GRAC-P1|100.00\n'
              || E'SM|p1|purchase|purchase|2.0000|0.0000|2.0000|X|100.00\n'
              || E'CM|purchase_payment|-2000.00\n'
              || E'EV|PurchaseCreated|2000.00|cash|-';
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-cash', v_today, 'golden cash',
           jsonb_build_array(pg_temp.rcb_pline(v_p1, 2, 1000)), v_x, NULL, v_pm_cash, NULL, v_s1, v_session_x, NULL);
  v_op_d1 := (v_j->>'operation_id')::uuid;
  v_snap := pg_temp.rcb_snap(v_op_d1, v_labels, v_today);
  IF v_snap IS DISTINCT FROM v_gold_cash THEN
    v_failures := v_failures || format('FAIL (g0 cash): retrato distinto del golden. Esperado:%s%sObservado:%s%s', E'\n', v_gold_cash, E'\n', v_snap);
  END IF;

  v_gold_credit := E'PU|p2|500|3.0000|-|1500|X|Gate RaC P2|GRAC-P2|50.00|-|s1|credit\n'
                || E'PI|p2|3.0000|-|500|1500|Gate RaC P2|GRAC-P2|50.00\n'
                || E'SM|p2|purchase|purchase|3.0000|0.0000|3.0000|X|50.00\n'
                || E'SA|purchase|1500.00|30\n'
                || E'EV|PurchaseCreated|1500.00|credit|-';
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-credit', v_today, 'golden credit',
           jsonb_build_array(pg_temp.rcb_pline(v_p2, 3, 500)), v_x, NULL, v_pm_credit, NULL, v_s1, NULL, NULL);
  v_op_d2 := (v_j->>'operation_id')::uuid;
  v_snap := pg_temp.rcb_snap(v_op_d2, v_labels, v_today);
  IF v_snap IS DISTINCT FROM v_gold_credit THEN
    v_failures := v_failures || format('FAIL (g0 credit): retrato distinto del golden. Esperado:%s%sObservado:%s%s', E'\n', v_gold_credit, E'\n', v_snap);
  END IF;

  v_gold_transfer := E'PU|pg|700|1.0000|-|700|Y|Gate RaC Golden|GRAC-G|40.00|-|s2|transfer\n'
                  || E'PI|pg|1.0000|-|700|700|Gate RaC Golden|GRAC-G|40.00\n'
                  || E'SM|pg|purchase|purchase|1.0000|0.0000|1.0000|Y|40.00\n'
                  || E'BM|transfer_out|-700.00|Y|purchase\n'
                  || E'EV|PurchaseCreated|700.00|transfer|-';
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-transfer', v_today, 'golden transfer',
           jsonb_build_array(pg_temp.rcb_pline(v_pg, 1, 700)), v_y, NULL, v_pm_transfer, v_bank_a, v_s2, NULL, NULL);
  v_op_d3 := (v_j->>'operation_id')::uuid;
  v_snap := pg_temp.rcb_snap(v_op_d3, v_labels, v_today);
  IF v_snap IS DISTINCT FROM v_gold_transfer THEN
    v_failures := v_failures || format('FAIL (g0 transfer): retrato distinto del golden. Esperado:%s%sObservado:%s%s', E'\n', v_gold_transfer, E'\n', v_snap);
  END IF;

  v_gold_service := E'PU|-|300|1.0000|-|300|X|-|-|-|-|-|-\n'
                 || E'EV|PurchaseCreated|300.00|credit|-';
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-service', v_today, 'golden servicio',
           jsonb_build_array(jsonb_build_object('product_id', NULL, 'unit_id', NULL, 'quantity', 1, 'amount', 300)),
           NULL, NULL, NULL, NULL, NULL, NULL, NULL);
  v_op_d4 := (v_j->>'operation_id')::uuid;
  v_snap := pg_temp.rcb_snap(v_op_d4, v_labels, v_today);
  IF v_snap IS DISTINCT FROM v_gold_service THEN
    v_failures := v_failures || format('FAIL (g0 servicio): retrato distinto del golden. Esperado:%s%sObservado:%s%s', E'\n', v_gold_service, E'\n', v_snap);
  END IF;

  v_gold_unit := E'PU|pkg|3000|450.0000|g|1350000|X|Gate RaC Kg|GRAC-KG|1000.00|-|-|-\n'
              || E'PI|pkg|450.0000|g|3000|1350000|Gate RaC Kg|GRAC-KG|1000.00\n'
              || E'SM|pkg|purchase|purchase|0.4500|0.0000|0.4500|X|1000.00\n'
              || E'EV|PurchaseCreated|1350000.00|credit|-';
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-unit', v_today, 'golden unidad',
           jsonb_build_array(pg_temp.rcb_pline(v_pkg, 450, 3000, v_g)), v_x, NULL, NULL, NULL, NULL, NULL, NULL);
  v_op_d5 := (v_j->>'operation_id')::uuid;
  v_snap := pg_temp.rcb_snap(v_op_d5, v_labels, v_today);
  IF v_snap IS DISTINCT FROM v_gold_unit THEN
    v_failures := v_failures || format('FAIL (g0 unidad): retrato distinto del golden. Esperado:%s%sObservado:%s%s', E'\n', v_gold_unit, E'\n', v_snap);
  END IF;

  -- Replay: misma clave -> misma operación, replayed = true, cero filas nuevas.
  v_before := pg_temp.rcb_effects(v_account_a);
  v_j := public.rpc_create_purchase_operation(v_tag || 'g-cash', v_today, 'golden cash',
           jsonb_build_array(pg_temp.rcb_pline(v_p1, 2, 1000)), v_x, NULL, v_pm_cash, NULL, v_s1, v_session_x, NULL);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF (v_j->>'replayed')::boolean IS DISTINCT FROM true OR (v_j->>'operation_id')::uuid IS DISTINCT FROM v_op_d1
     OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (g0 replay): el replay debía devolver la misma operación sin efectos (%s; %s -> %s)', v_j, v_before, v_after);
  END IF;
  -- Sin sesión: la función sigue rechazando con 42501.
  PERFORM pg_temp.rcb_as(NULL);
  v_txt := pg_temp.rcb_err(format('SELECT public.rpc_create_purchase_operation(%L, %L::date, ''x'', %L::jsonb)',
            v_tag || 'g-nosession', v_today, jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 10))));
  IF v_txt NOT LIKE '42501%' THEN
    v_failures := v_failures || format('FAIL (g0 sesión): la compra directa sin sesión debía dar 42501, vino %s', v_txt);
  END IF;
  PERFORM pg_temp.rcb_as(v_owner_a);
  -- El P0423 de dinero de una compra directa en efectivo no cambia (regresión).
  SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op_d1;
  v_txt := pg_temp.rcb_err(format('SELECT public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)',
            v_ids, v_today, jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 1000))));
  IF v_txt NOT LIKE 'P0423%' OR v_txt LIKE '%delivery_note_purchase_locked%' THEN
    v_failures := v_failures || format('FAIL (g0 P0423): editar una compra directa con caja posteada debía dar el P0423 de dinero de siempre, vino %s', v_txt);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (g0): compra directa idéntica al golden — cash con caja, credit con cargo y vencimiento a 30 días, transfer con banco, línea sin producto, 450 g -> 0,45 kg, replay sin efectos, 42501 sin sesión y el P0423 de dinero intacto.';
  ELSE
    RAISE NOTICE 'GOLDEN (g0): %', array_to_string(v_failures[v_fail_before + 1:], ' | ');
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Remitos de compra (emitidos por el owner; suman stock al recibir)
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcb_as(v_owner_a);
  v_dn_core     := pg_temp.rcb_issue(v_tag || 'dn-core', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 2, 1000, v_u)));
  v_dn_mm       := pg_temp.rcb_issue(v_tag || 'dn-mm', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_canc     := pg_temp.rcb_issue(v_tag || 'dn-canc', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_fake     := pg_temp.rcb_issue(v_tag || 'dn-fake', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_cash     := pg_temp.rcb_issue(v_tag || 'dn-cash', v_s1, v_x, jsonb_build_array(
                     pg_temp.rcb_line(v_p1, 2, 1000, v_u), pg_temp.rcb_line(v_p2, 1, 500, v_u), pg_temp.rcb_line(v_pren, 1, 300, v_u)));
  v_dn_credit   := pg_temp.rcb_issue(v_tag || 'dn-credit', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p2, 1, 500, v_u)));
  v_dn_transfer := pg_temp.rcb_issue(v_tag || 'dn-transfer', v_s1, v_y, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_dead     := pg_temp.rcb_issue(v_tag || 'dn-dead', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_pdead, 1, 200, v_u)));
  v_dn_gone     := pg_temp.rcb_issue(v_tag || 'dn-gone', v_s_gone, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_z        := pg_temp.rcb_issue(v_tag || 'dn-z', v_s1, v_z, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_cl       := pg_temp.rcb_issue(v_tag || 'dn-cl', v_s1, v_cl, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_other    := pg_temp.rcb_issue(v_tag || 'dn-other', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_stk      := pg_temp.rcb_issue(v_tag || 'dn-stk', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_nomoney  := pg_temp.rcb_issue(v_tag || 'dn-nomoney', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p2, 3, 500, v_u)));
  v_dn_noprice  := pg_temp.rcb_issue(v_tag || 'dn-noprice', v_s1, v_x, jsonb_build_array(
                     pg_temp.rcb_line(v_p2, 3, 0, v_u), pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_caja     := pg_temp.rcb_issue(v_tag || 'dn-caja', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_pur      := pg_temp.rcb_issue(v_tag || 'dn-pur', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p2, 2, 500, v_u)));
  v_dn_delbr    := pg_temp.rcb_issue(v_tag || 'dn-delbr', v_s1, v_y, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u)));
  v_dn_clbr     := pg_temp.rcb_issue(v_tag || 'dn-clbr', v_s1, v_cl, jsonb_build_array(pg_temp.rcb_line(v_p2, 1, 500, v_u)));
  v_dn_sec      := pg_temp.rcb_issue(v_tag || 'dn-sec', v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p2, 1, 500, v_u)));
  PERFORM public.rpc_cancel_delivery_note(v_dn_canc, 1, 'Gate RaC: anulado para el origen inválido');
  -- Un remito de VENTA (sentido distinto) de la misma cuenta.
  v_dn_sale     := (public.rpc_create_sale_delivery_note(v_tag || 'dn-sale', v_client, v_x, NULL, NULL,
                     jsonb_build_array(jsonb_build_object('product_id', v_p1, 'unit_id', v_u, 'quantity', 1, 'price', 1000, 'subtotal', 1000)))->>'id')::uuid;
  PERFORM pg_temp.rcb_as(v_owner_b);
  v_dn_b        := pg_temp.rcb_issue(v_tag || 'dn-b', v_sup_b, v_branch_b, jsonb_build_array(pg_temp.rcb_line(v_pb, 1, 100)));
  PERFORM pg_temp.rcb_as(v_owner_a);
  -- "Convertido" sin compra, armado como postgres (sólo para el origen inválido).
  SET session_replication_role = replica;
  UPDATE public.delivery_notes SET status = 'converted' WHERE id = v_dn_fake;
  SET session_replication_role = DEFAULT;

  IF v_dn_core IS NULL OR v_dn_cash IS NULL OR v_dn_b IS NULL OR v_dn_sale IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se emitieron los remitos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (z) CONTROL NEGATIVO: el núcleo con un origen válido no suma stock
  -- ═══════════════════════════════════════════════════════════════════════
  -- No usa rpc_convert_delivery_note_to_purchase: llama al núcleo directo (como
  -- postgres, con los claims del owner). Sin la rama del núcleo (6.3 aplicada,
  -- 6.4 no), este bloque FALLA porque el núcleo vivo suma igual.
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_a1 := pg_temp.rcb_stock(v_p1, v_x);
  SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
  v_r := pg_temp.rcb_core(v_tag || 'core', v_account_a, v_x, v_s1, v_dn_core, v_pm_credit);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (z): el núcleo rechazó un origen de remito VÁLIDO: %s', v_r);
  ELSE
    v_j := substr(v_r, 4)::jsonb;
    IF pg_temp.rcb_stock(v_p1, v_x) IS DISTINCT FROM v_a1 THEN
      v_failures := v_failures || format('FAIL (z) DOBLE SUMA: el núcleo sumó stock para una compra con origen de remito (P1 en X %s -> %s)',
                                         v_a1, pg_temp.rcb_stock(v_p1, v_x));
    END IF;
    IF (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm
       OR pg_temp.rcb_purchase_moves((v_j->>'operation_id')::uuid) <> 0 THEN
      v_failures := v_failures || 'FAIL (z) DOBLE SUMA: el núcleo escribió movimientos de stock para una compra con origen de remito'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.purchases pu
                   WHERE pu.operation_id = (v_j->>'operation_id')::uuid AND pu.source_delivery_note_id = v_dn_core
                     AND pu.account_id = v_account_a AND pu.supplier_id = v_s1 AND pu.branch_id = v_x) THEN
      v_failures := v_failures || 'FAIL (z): las filas de la compra no persisten el origen, el proveedor y la sucursal del remito'::text;
    END IF;
    IF NOT EXISTS (
         SELECT 1 FROM public.purchases pu JOIN public.delivery_note_items di
           ON di.delivery_note_id = v_dn_core AND di.product_id = pu.product_id
         WHERE pu.operation_id = (v_j->>'operation_id')::uuid
           AND pu.name_snapshot IS NOT DISTINCT FROM di.name_snapshot
           AND pu.sku_snapshot IS NOT DISTINCT FROM di.sku_snapshot
           AND pu.unit_cost_snapshot IS NOT DISTINCT FROM di.unit_cost_snapshot
           AND pu.iva_rate_snapshot IS NOT DISTINCT FROM di.iva_rate_snapshot
           AND pu.amount = di.price AND pu.quantity = di.quantity AND pu.unit_id IS NOT DISTINCT FROM di.unit_id) THEN
      v_failures := v_failures || 'FAIL (z): purchases no tomó los cuatro snapshots de la línea del remito'::text;
    END IF;
    IF NOT EXISTS (
         SELECT 1 FROM public.purchase_items pi JOIN public.purchases pu ON pu.id = pi.purchase_id
         JOIN public.delivery_note_items di ON di.delivery_note_id = v_dn_core AND di.product_id = pi.product_id
         WHERE pu.operation_id = (v_j->>'operation_id')::uuid
           AND pi.name_snapshot IS NOT DISTINCT FROM di.name_snapshot
           AND pi.unit_cost_snapshot IS NOT DISTINCT FROM di.unit_cost_snapshot
           AND pi.price = di.price AND pi.subtotal = di.subtotal) THEN
      v_failures := v_failures || 'FAIL (z): purchase_items no tomó los snapshots y el subtotal de la línea del remito'::text;
    END IF;
    -- El invariante "compra con origen => remito converted" vive en el núcleo.
    IF pg_temp.rcb_status(v_dn_core) IS DISTINCT FROM 'converted' THEN
      v_failures := v_failures || format('FAIL (z) RB-02: el remito quedó %s tras crear su compra por el núcleo (se esperaba converted)',
                                         pg_temp.rcb_status(v_dn_core));
    END IF;
    IF pg_temp.rcb_rev(v_dn_core) IS DISTINCT FROM 1 THEN
      v_failures := v_failures || format('FAIL (z): la transición del remito subió la revisión (%s)', pg_temp.rcb_rev(v_dn_core));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.document_status_history h
                   WHERE h.document_type = 'delivery_note_purchase' AND h.document_id = v_dn_core
                     AND h.from_status = 'issued' AND h.to_status = 'converted' AND h.performed_by = v_owner_a) THEN
      v_failures := v_failures || 'FAIL (z): no quedó el historial issued -> converted del remito'::text;
    END IF;
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_cancel_delivery_note(%L::uuid, 1, ''Gate RaC: anular un convertido por el núcleo'')', v_dn_core));
    IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted%' THEN
      v_failures := v_failures || format('FAIL (z): el remito de una compra creada por el núcleo seguía anulable: %s', v_txt);
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (z): el núcleo, con un origen de remito válido, no suma stock ni escribe movimientos, congela los snapshots del remito y deja el remito converted con su historial.';
  ELSE
    RAISE NOTICE 'CONTROL (z): %', array_to_string(v_failures[v_fail_before + 1:], ' | ');
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (n) núcleo con un origen inválido -> P0409 delivery_note_purchase_mismatch
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.rcb_effects(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('remito de otra cuenta', v_x, v_s1, v_dn_b),
      -- Con SU proveedor y SU sucursal: ya no lo frena la comparación de proveedor y sucursal, sólo el
      -- filtro de cuenta del núcleo (un mutante sin ese filtro sobrevivía a la fila de arriba).
      ('remito de otra cuenta con su proveedor y su sucursal', v_branch_b, v_sup_b, v_dn_b),
      ('remito de venta',       v_x, v_s1, v_dn_sale),
      -- El remito de venta no tiene proveedor y está en la sucursal v_x: con proveedor NULL sólo lo frena
      -- el filtro de sentido (sin él, el núcleo armaría una COMPRA con las líneas de un remito de venta).
      ('remito de venta sin proveedor', v_x, NULL::uuid, v_dn_sale),
      ('remito anulado',        v_x, v_s1, v_dn_canc),
      ('remito convertido',     v_x, v_s1, v_dn_fake),
      ('otro proveedor',        v_x, v_s2, v_dn_mm),
      ('otra sucursal',         v_y, v_s1, v_dn_mm)
    ) AS t(label, branch, supplier, dn)
  LOOP
    v_r := pg_temp.rcb_core(v_tag || 'mm-' || v_rec.label, v_account_a, v_rec.branch, v_rec.supplier, v_rec.dn, v_pm_credit);
    IF v_r NOT LIKE 'ERR|P0409|delivery_note_purchase_mismatch%' THEN
      v_failures := v_failures || format('FAIL (n) %s: se esperaba P0409 delivery_note_purchase_mismatch, vino %s', v_rec.label, v_r);
    END IF;
  END LOOP;
  -- Con líneas enviadas en el request: las líneas salen SIEMPRE del remito.
  v_r := pg_temp.rcb_core(v_tag || 'mm-items', v_account_a, v_x, v_s1, v_dn_mm, v_pm_credit,
                          jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 1000)));
  IF v_r NOT LIKE 'ERR|P0400|delivery_note_items_from_source%' THEN
    v_failures := v_failures || format('FAIL (n) con p_items: se esperaba P0400 delivery_note_items_from_source, vino %s', v_r);
  END IF;
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (n): un origen inválido dejó efectos (%s -> %s)', v_before, v_after);
  END IF;
  -- Una compra YA existente con ese origen (armada como postgres) sobre un
  -- remito issued: el núcleo rechaza en vez de crear una segunda.
  SET session_replication_role = replica;
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id, branch_id, supplier_id, source_delivery_note_id)
  VALUES (v_owner_a, v_account_a, v_p1, 1000, 1, 1000, v_today, gen_random_uuid(), v_x, v_s1, v_dn_mm);
  SET session_replication_role = DEFAULT;
  v_before := pg_temp.rcb_effects(v_account_a);
  v_r := pg_temp.rcb_core(v_tag || 'mm-dup', v_account_a, v_x, v_s1, v_dn_mm, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|delivery_note_purchase_mismatch%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (n) con una compra ya existente: se esperaba P0409 sin efectos, vino %s (%s -> %s)', v_r, v_before, v_after);
  END IF;
  SET session_replication_role = replica;
  DELETE FROM public.purchases WHERE source_delivery_note_id = v_dn_mm;
  SET session_replication_role = DEFAULT;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (n): los orígenes inválidos (otra cuenta, venta —también sin proveedor—, anulado, convertido, otro proveedor, otra sucursal, p_items del request, compra ya existente) rebotan sin compra, stock, evento ni idempotencia.';
  ELSE
    RAISE NOTICE 'CONTROL (n): %', array_to_string(v_failures[v_fail_before + 1:], ' | ');
  END IF;

  -- Sonda: sin la RPC de conversión el gate aborta acá con 42883 (RED de 6.2).
  -- Va DESPUÉS de (g0), (z) y (n), que no la usan, para que el golden de la
  -- compra directa y el control negativo se vean en su NOTICE antes de abortar.
  PERFORM 'public.rpc_convert_delivery_note_to_purchase(text,uuid,integer,uuid,date,uuid,uuid,uuid,date,text)'::regprocedure;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) conversión cash con snapshots del remito
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- Después de recibir: el producto se renombra y el catálogo se remarca.
  UPDATE public.products SET name = 'Gate RaC Renombrado DESPUES', sku = 'GRAC-REN-2' WHERE id = v_pren;
  UPDATE public.products SET cost = 999 WHERE id = v_p1;
  v_a1 := pg_temp.rcb_stock(v_p1, v_x); v_a2 := pg_temp.rcb_stock(v_p2, v_x); v_a3 := pg_temp.rcb_stock(v_pren, v_x);
  SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
  SELECT count(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_x;
  v_key_cash := v_tag || 'cash';
  v_r := pg_temp.rcb_convert(v_key_cash, v_dn_cash, 1, v_pm_cash, NULL, v_session_x, NULL);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (a): la conversión cash falló: %s', v_r);
  ELSE
    v_j := substr(v_r, 4)::jsonb;
    v_op_cash := (v_j->>'operation_id')::uuid;
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_j) k)
         <> ARRAY['delivery_note_id', 'delivery_note_number', 'operation_id', 'replayed', 'total']
       OR (v_j->>'delivery_note_id')::uuid <> v_dn_cash
       OR (v_j->>'delivery_note_number')::bigint IS DISTINCT FROM (SELECT number FROM public.delivery_notes WHERE id = v_dn_cash)
       OR (v_j->>'total')::numeric <> 2800 OR (v_j->>'replayed')::boolean IS DISTINCT FROM false THEN
      v_failures := v_failures || format('FAIL (a): resultado inesperado %s', v_j);
    END IF;
    IF pg_temp.rcb_stock(v_p1, v_x) <> v_a1 OR pg_temp.rcb_stock(v_p2, v_x) <> v_a2 OR pg_temp.rcb_stock(v_pren, v_x) <> v_a3 THEN
      v_failures := v_failures || 'FAIL (a) DOBLE SUMA: convertir cambió el stock'::text;
    END IF;
    IF (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm
       OR pg_temp.rcb_purchase_moves(v_op_cash) <> 0 THEN
      v_failures := v_failures || 'FAIL (a): convertir escribió movimientos de stock'::text;
    END IF;
    IF (SELECT count(*) FROM public.cash_movements WHERE session_id = v_session_x) <> v_n + 1
       OR NOT EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session_x
                        AND reference_id = v_op_cash AND movement_type = 'purchase_payment' AND amount = -2800) THEN
      v_failures := v_failures || 'FAIL (a): falta el egreso de caja de la compra'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_cash
                     AND (payload->>'total')::numeric = 2800 AND payload->>'payment_method' = 'cash') THEN
      v_failures := v_failures || 'FAIL (a): falta PurchaseCreated con el total del remito y la forma de pago real'::text;
    END IF;
    IF (SELECT count(*) FROM public.purchases WHERE operation_id = v_op_cash AND source_delivery_note_id = v_dn_cash
          AND supplier_id = v_s1 AND branch_id = v_x AND payment_method_id = v_pm_cash AND account_id = v_account_a) <> 3
       OR (SELECT COALESCE(sum(total), 0) FROM public.purchases WHERE operation_id = v_op_cash) <> 2800
       OR (SELECT total FROM public.delivery_notes WHERE id = v_dn_cash) <> 2800 THEN
      v_failures := v_failures || 'FAIL (a): las 3 filas no quedaron con origen, proveedor, sucursal y forma de pago, o el total de la compra no es el del remito'::text;
    END IF;
    IF pg_temp.rcb_status(v_dn_cash) <> 'converted' OR pg_temp.rcb_rev(v_dn_cash) <> 1 THEN
      v_failures := v_failures || format('FAIL (a): el remito quedó %s revisión %s (se esperaba converted, 1)',
                                         pg_temp.rcb_status(v_dn_cash), pg_temp.rcb_rev(v_dn_cash));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'delivery_note_purchase'
                     AND document_id = v_dn_cash AND from_status = 'issued' AND to_status = 'converted' AND performed_by = v_owner_a) THEN
      v_failures := v_failures || 'FAIL (a): falta el historial issued -> converted del remito'::text;
    END IF;
    -- Snapshots: los del remito, aunque el catálogo cambió después de recibir.
    SELECT count(*) INTO v_n2
    FROM public.purchases pu JOIN public.delivery_note_items di ON di.delivery_note_id = v_dn_cash AND di.product_id = pu.product_id
    WHERE pu.operation_id = v_op_cash
      AND pu.name_snapshot IS NOT DISTINCT FROM di.name_snapshot
      AND pu.sku_snapshot IS NOT DISTINCT FROM di.sku_snapshot
      AND pu.unit_cost_snapshot IS NOT DISTINCT FROM di.unit_cost_snapshot
      AND pu.iva_rate_snapshot IS NOT DISTINCT FROM di.iva_rate_snapshot
      AND pu.quantity = di.quantity AND pu.unit_id IS NOT DISTINCT FROM di.unit_id AND pu.amount = di.price;
    IF v_n2 <> 3
       OR NOT EXISTS (SELECT 1 FROM public.purchases pu WHERE pu.operation_id = v_op_cash AND pu.product_id = v_pren
                        AND pu.name_snapshot = 'Gate RaC Renombrado' AND pu.sku_snapshot = 'GRAC-REN')
       OR NOT EXISTS (SELECT 1 FROM public.purchases pu WHERE pu.operation_id = v_op_cash AND pu.product_id = v_p1
                        AND pu.unit_cost_snapshot = 100)
       OR (SELECT count(*) FROM public.purchase_items pi JOIN public.purchases pu ON pu.id = pi.purchase_id
           WHERE pu.operation_id = v_op_cash AND pi.name_snapshot IS NOT NULL) <> 3 THEN
      v_failures := v_failures || format('FAIL (a): purchases / purchase_items no conserva los snapshots del remito (%s de 3 líneas)', v_n2);
    END IF;
    v_j := public._delivery_note_payload(v_dn_cash);
    IF (v_j->>'converted_operation_id')::uuid IS DISTINCT FROM v_op_cash OR (v_j->>'converted_sales_order_id') IS NOT NULL THEN
      v_failures := v_failures || format('FAIL (a): el payload del remito no expone la compra generada (%s / %s)',
                                         v_j->>'converted_operation_id', v_j->>'converted_sales_order_id');
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (a): conversión cash — stock idéntico, 0 movimientos, egreso de caja, PurchaseCreated, 3 filas con origen, total = el del remito, remito converted sin subir revisión, historial, snapshots del remito (renombrado y costo remarcado) y payload con la compra.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (g) replay, (h) clave sobre otro remito, (i) segunda conversión
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_before := pg_temp.rcb_effects(v_account_a);
  v_r := pg_temp.rcb_convert(v_key_cash, v_dn_cash, 1, v_pm_cash, NULL, v_session_x, NULL);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'OK|%' OR (substr(v_r, 4)::jsonb->>'replayed')::boolean IS DISTINCT FROM true
     OR (substr(v_r, 4)::jsonb->>'operation_id')::uuid IS DISTINCT FROM v_op_cash
     OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (g): replay inesperado %s (%s -> %s)', v_r, v_before, v_after);
  END IF;
  v_r := pg_temp.rcb_convert(v_key_cash, v_dn_other, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|idempotency_key_conflict%' OR v_before IS DISTINCT FROM v_after
     OR pg_temp.rcb_status(v_dn_other) <> 'issued' THEN
    v_failures := v_failures || format('FAIL (h): la clave de otro remito debía dar idempotency_key_conflict sin efectos: %s', v_r);
  END IF;
  -- La misma clave que usó una compra DIRECTA tampoco sirve para convertir.
  v_r := pg_temp.rcb_convert(v_tag || 'g-cash', v_dn_other, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|idempotency_key_conflict%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (h): la clave de una compra directa debía dar idempotency_key_conflict: %s', v_r);
  END IF;
  v_r := pg_temp.rcb_convert(v_tag || 'cash-2', v_dn_cash, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0409|delivery_note_invalid_state%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (i): la segunda conversión debía dar delivery_note_invalid_state: %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (g/h/i): replay sin efectos, clave ajena (de otro remito o de una compra directa) -> idempotency_key_conflict, segunda conversión -> delivery_note_invalid_state.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (j) versión vieja y parámetros; (k) roles y tenencia; (l) caja
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- La edición sube la revisión a 2 (precio 900).
  PERFORM public.rpc_update_purchase_delivery_note(v_dn_other, 1, v_s1, v_x, NULL, NULL,
            jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 900, v_u)));
  v_before := pg_temp.rcb_effects(v_account_a);
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('versión vieja',  v_tag || 'old', 1::integer, v_pm_credit, 'ERR|P0409|delivery_note_changed%'),
      ('sin versión',    v_tag || 'norev', NULL::integer, v_pm_credit, 'ERR|P0400|%'),
      ('sin forma de pago', v_tag || 'nopm', 2, NULL::uuid, 'ERR|P0400|payment_method_required%'),
      ('sin clave',      '', 2, v_pm_credit, 'ERR|P0400|%'),
      ('forma de pago ajena', v_tag || 'pmb', 2, v_pm_cash_b, 'ERR|P0404|payment_method_not_found%')
    ) AS t(label, k, rev, pm, expected)
  LOOP
    v_r := pg_temp.rcb_convert(v_rec.k, v_dn_other, v_rec.rev, v_rec.pm);
    IF v_r NOT LIKE v_rec.expected THEN
      v_failures := v_failures || format('FAIL (j) %s: se esperaba %s, vino %s', v_rec.label, v_rec.expected, v_r);
    END IF;
  END LOOP;
  -- Roles: seller y cashier no convierten; el remito ajeno no existe para A.
  FOREACH v_uuid IN ARRAY ARRAY[v_seller, v_cashier] LOOP
    PERFORM pg_temp.rcb_as(v_uuid);
    v_r := pg_temp.rcb_convert(v_tag || 'rol-' || v_uuid::text, v_dn_stk, 1, v_pm_credit);
    IF v_r NOT LIKE 'ERR|P0403|insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (k): el rol de %s debía dar P0403, vino %s', v_uuid, v_r);
    END IF;
    -- El rol se evalúa ANTES que la versión: con una versión vieja un rol sin permiso recibe el rechazo
    -- de rol, no el del contenido del remito (el núcleo evalúa el rol de la transición al final, así
    -- que sin el chequeo explícito de la RPC este caso daría delivery_note_changed).
    v_r := pg_temp.rcb_convert(v_tag || 'rol-viejo-' || v_uuid::text, v_dn_other, 1, v_pm_credit);
    IF v_r NOT LIKE 'ERR|P0403|insufficient_role%' THEN
      v_failures := v_failures || format('FAIL (k): el rol de %s con una versión vieja debía dar P0403 antes que la versión, vino %s', v_uuid, v_r);
    END IF;
  END LOOP;
  PERFORM pg_temp.rcb_as(v_owner_a);
  v_r := pg_temp.rcb_convert(v_tag || 'ajeno', v_dn_b, 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (k): el remito de otra cuenta debía dar P0404, vino %s', v_r);
  END IF;
  v_r := pg_temp.rcb_convert(v_tag || 'sale', v_dn_sale, 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (k): un remito de VENTA por la RPC de compra debía dar P0404, vino %s', v_r);
  END IF;
  v_r := pg_temp.rcb_convert(v_tag || 'inexistente', gen_random_uuid(), 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_not_found%' THEN
    v_failures := v_failures || format('FAIL (k): un id inexistente debía dar P0404, vino %s', v_r);
  END IF;
  -- (l) caja: sesión de otra sucursal, otra fecha y forma de pago que no es efectivo.
  v_r := pg_temp.rcb_convert(v_tag || 'caja-otra-suc', v_dn_stk, 1, v_pm_cash, NULL, v_session_y);
  IF v_r NOT LIKE 'ERR|P0422|cash_optin_requires_open_session%' THEN
    v_failures := v_failures || format('FAIL (l): la sesión de otra sucursal debía dar cash_optin_requires_open_session, vino %s', v_r);
  END IF;
  v_r := pg_temp.rcb_convert(v_tag || 'caja-fecha', v_dn_stk, 1, v_pm_cash, v_today + 1, v_session_x);
  IF v_r NOT LIKE 'ERR|P0422|cash_optin_requires_today%' THEN
    v_failures := v_failures || format('FAIL (l): la caja con otra fecha debía dar cash_optin_requires_today, vino %s', v_r);
  END IF;
  v_r := pg_temp.rcb_convert(v_tag || 'caja-kind', v_dn_stk, 1, v_pm_credit, NULL, v_session_x);
  IF v_r NOT LIKE 'ERR|P0422|cash_optin_requires_cash_kind%' THEN
    v_failures := v_failures || format('FAIL (l): caja con una forma de pago que no es efectivo debía dar cash_optin_requires_cash_kind, vino %s', v_r);
  END IF;
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (j/k/l): un rechazo dejó efectos (%s -> %s)', v_before, v_after);
  END IF;
  -- stock y purchases convierten (con la versión vigente y el precio editado).
  PERFORM pg_temp.rcb_as(v_stocker);
  v_r := pg_temp.rcb_convert(v_tag || 'stocker', v_dn_other, 2, v_pm_other);
  IF v_r NOT LIKE 'OK|%' OR pg_temp.rcb_status(v_dn_other) <> 'converted' OR (substr(v_r, 4)::jsonb->>'total')::numeric <> 900 THEN
    v_failures := v_failures || format('FAIL (k): el rol stock debía convertir con el precio editado del remito, vino %s', v_r);
  END IF;
  PERFORM pg_temp.rcb_as(v_purchaser);
  v_r := pg_temp.rcb_convert(v_tag || 'purchaser', v_dn_stk, 1, v_pm_other);
  IF v_r NOT LIKE 'OK|%' OR pg_temp.rcb_status(v_dn_stk) <> 'converted' THEN
    v_failures := v_failures || format('FAIL (k): el rol purchases debía convertir, vino %s', v_r);
  END IF;
  PERFORM pg_temp.rcb_as(v_owner_a);
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (j/k/l): versión vieja, parámetros, forma de pago ajena, seller y cashier, remito ajeno, de venta e inexistente y la caja (otra sucursal, otra fecha, otra forma de pago) rebotan sin efectos; stock y purchases convierten con el precio del remito.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (b) credit como `authenticated` por el rol purchases
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_a2 := pg_temp.rcb_stock(v_p2, v_x);
  SELECT count(*) INTO v_n FROM public.cash_movements WHERE session_id = v_session_x;
  PERFORM pg_temp.rcb_as(v_purchaser);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_j := public.rpc_convert_delivery_note_to_purchase(v_tag || 'credit', v_dn_credit, 1, v_pm_credit,
             NULL, NULL, NULL, NULL, NULL, NULL);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    EXECUTE 'RESET ROLE';
    v_j := NULL;
    v_failures := v_failures || format('FAIL (b): la conversión a crédito como authenticated falló: %s / %s', v_state, v_msg);
  END;
  PERFORM pg_temp.rcb_as(v_owner_a);
  IF v_j IS NOT NULL THEN
    v_op_credit := (v_j->>'operation_id')::uuid;
    SELECT count(*), max(sam.amount), max(sam.due_date) INTO v_n2, v_val, v_date
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id = v_op_credit AND sam.movement_type = 'purchase';
    IF v_n2 <> 1 OR v_val <> 500 OR v_date IS DISTINCT FROM v_today + 30 THEN
      v_failures := v_failures || format('FAIL (b): cargo en la cuenta corriente del proveedor inesperado (n=%s, monto=%s, vence=%s)', v_n2, v_val, v_date);
    END IF;
    IF (SELECT count(*) FROM public.cash_movements WHERE session_id = v_session_x) <> v_n
       OR pg_temp.rcb_stock(v_p2, v_x) <> v_a2 OR pg_temp.rcb_purchase_moves(v_op_credit) <> 0
       OR pg_temp.rcb_status(v_dn_credit) <> 'converted' THEN
      v_failures := v_failures || 'FAIL (b): la compra a crédito tocó caja o stock, o el remito no quedó converted'::text;
    END IF;
  END IF;
  -- Vencimiento explícito: pisa la cascada.
  v_r := pg_temp.rcb_convert(v_tag || 'credit-due', v_dn_noprice, 1, v_pm_credit);
  IF v_r NOT LIKE 'ERR|P0400|delivery_note_price_required%' THEN
    v_failures := v_failures || format('FAIL (p0): el remito con una línea a precio 0 debía dar delivery_note_price_required, vino %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (b): conversión a crédito como authenticated por el rol purchases — cargo en la cuenta corriente del proveedor con vencimiento por cascada (30 días), sin caja ni stock.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (c) transfer con banco en otra sucursal; (d) producto dado de baja
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_a1 := pg_temp.rcb_stock(v_p1, v_y);
  v_r := pg_temp.rcb_convert(v_tag || 'transfer', v_dn_transfer, 1, v_pm_transfer, NULL, NULL, v_bank_a);
  IF v_r NOT LIKE 'OK|%' THEN
    v_failures := v_failures || format('FAIL (c): la conversión por transferencia falló: %s', v_r);
  ELSE
    v_op_transfer := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.bank_movements WHERE source_doc_type = 'purchase' AND source_doc_ref = v_op_transfer
                     AND bank_account_id = v_bank_a AND amount = -1000 AND branch_id = v_y)
       OR (SELECT branch_id FROM public.purchases WHERE operation_id = v_op_transfer LIMIT 1) <> v_y
       OR pg_temp.rcb_stock(v_p1, v_y) <> v_a1 OR pg_temp.rcb_purchase_moves(v_op_transfer) <> 0 THEN
      v_failures := v_failures || 'FAIL (c): falta el egreso bancario en la sucursal del remito, o cambió el stock'::text;
    END IF;
  END IF;
  -- La baja del producto exige stock 0 (RN-B4) y la mercadería recibida está en el depósito:
  -- se arma como postgres evadiendo el guard (es el caso «dado de baja después de recibir»).
  SET session_replication_role = replica;
  UPDATE public.products SET deleted_at = now() WHERE id = v_pdead;
  SET session_replication_role = DEFAULT;
  v_a1 := pg_temp.rcb_stock(v_pdead, v_x);
  v_r := pg_temp.rcb_convert(v_tag || 'dead', v_dn_dead, 1, v_pm_credit);
  IF v_r NOT LIKE 'OK|%' OR pg_temp.rcb_stock(v_pdead, v_x) <> v_a1
     OR NOT EXISTS (SELECT 1 FROM public.purchases pu
                    WHERE pu.operation_id = (substr(v_r, 4)::jsonb->>'operation_id')::uuid
                      AND pu.product_id = v_pdead AND pu.name_snapshot = 'Gate RaC Se Discontinua') THEN
    v_failures := v_failures || format('FAIL (d): el producto dado de baja después de recibir debía convertirse con su snapshot: %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (c/d): transferencia con egreso bancario en la sucursal del remito; producto dado de baja después de recibir convierte con su snapshot.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (e) proveedor dado de baja; (f) sucursal desactivada / cerrada; (dt) fecha
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  UPDATE public.suppliers SET deleted_at = now() WHERE id = v_s_gone;
  v_before := pg_temp.rcb_effects(v_account_a);
  v_r := pg_temp.rcb_convert(v_tag || 'gone', v_dn_gone, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0404|delivery_note_supplier_unavailable%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (e): proveedor dado de baja debía dar P0404 delivery_note_supplier_unavailable sin efectos: %s (%s -> %s)', v_r, v_before, v_after);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = false WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  v_r := pg_temp.rcb_convert(v_tag || 'z-off', v_dn_z, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0422|branch_closed%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (f): sucursal desactivada debía dar P0422 branch_closed sin efectos: %s', v_r);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET is_active = true, status = 'closed', closed_at = now() WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  v_r := pg_temp.rcb_convert(v_tag || 'z-closed', v_dn_z, 1, v_pm_credit);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0422|branch_closed%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (f): sucursal cerrada debía dar P0422 branch_closed sin efectos: %s', v_r);
  END IF;
  SET session_replication_role = replica;
  UPDATE public.branches SET status = 'active', closed_at = NULL WHERE id = v_z;
  SET session_replication_role = DEFAULT;
  -- Fecha anterior a la del remito (issued_on = hoy): rechazada; hoy y futura, aceptadas por la RPC.
  v_r := pg_temp.rcb_convert(v_tag || 'fecha', v_dn_caja, 1, v_pm_credit, v_today - 1);
  v_after := pg_temp.rcb_effects(v_account_a);
  IF v_r NOT LIKE 'ERR|P0400|delivery_note_purchase_date_before_receipt%' OR v_before IS DISTINCT FROM v_after THEN
    v_failures := v_failures || format('FAIL (dt): fecha anterior al remito debía dar P0400 delivery_note_purchase_date_before_receipt sin efectos: %s', v_r);
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (e/f/dt): proveedor dado de baja -> delivery_note_supplier_unavailable; sucursal desactivada o cerrada -> P0422 branch_closed; fecha anterior al remito -> P0400; cero efectos.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (q) editar la compra nacida del remito; (r) anular un remito convertido
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_op_cash IS NOT NULL THEN
    -- Compra a crédito con cuenta corriente posteada: sin el P0423 propio,
    -- recibiría el P0423 de cuenta corriente (que manda a borrar y volver a cargar).
    SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op_credit;
    v_a1 := pg_temp.rcb_stock(v_p2, v_x);
    v_before := pg_temp.rcb_effects(v_account_a);
    -- La compra a crédito la creó el rol purchases (purchases.user_id): la edita él.
    PERFORM pg_temp.rcb_as(v_purchaser);
    v_txt := pg_temp.rcb_err(format(
      'SELECT public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)',
      v_ids, v_today, jsonb_build_array(pg_temp.rcb_pline(v_p2, 1, 500, v_u))));
    PERFORM pg_temp.rcb_as(v_owner_a);
    IF v_txt NOT LIKE 'P0423 delivery_note_purchase_locked%RC-%' THEN
      v_failures := v_failures || format('FAIL (q): editar la compra a crédito del remito debía dar P0423 delivery_note_purchase_locked antes que el de cuenta corriente, vino %s', v_txt);
    END IF;
    -- Compra en efectivo con caja posteada (cash): lo mismo, antes del de caja.
    SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op_cash;
    v_txt := pg_temp.rcb_err(format(
      'SELECT public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)',
      v_ids, v_today, jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 1000, v_u))));
    IF v_txt NOT LIKE 'P0423 delivery_note_purchase_locked%' THEN
      v_failures := v_failures || format('FAIL (q): editar la compra en efectivo del remito debía dar delivery_note_purchase_locked antes que el de caja, vino %s', v_txt);
    END IF;
    -- Compra SIN dinero posteado (forma de pago 'other'): ningún guard de dinero
    -- la frena. Sin el P0423 propio, la edición restaría el stock que el remito
    -- sigue aportando.
    v_r := pg_temp.rcb_convert(v_tag || 'nomoney', v_dn_nomoney, 1, v_pm_other);
    IF v_r NOT LIKE 'OK|%' THEN
      v_failures := v_failures || format('FAIL (q): no se pudo convertir el remito sin dinero: %s', v_r);
    ELSE
      v_op_nomoney := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
      SELECT array_agg(id) INTO v_ids FROM public.purchases WHERE operation_id = v_op_nomoney;
      v_a2 := pg_temp.rcb_stock(v_p2, v_x);
      v_before := pg_temp.rcb_effects(v_account_a);
      v_txt := pg_temp.rcb_err(format(
        'SELECT public.rpc_atomic_update_purchase_operation(%L::uuid[], %L::date, ''x'', %L::jsonb)',
        v_ids, v_today, jsonb_build_array(pg_temp.rcb_pline(v_p2, 1, 500, v_u))));
      IF v_txt NOT LIKE 'P0423 delivery_note_purchase_locked%' OR pg_temp.rcb_stock(v_p2, v_x) <> v_a2
         OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
        v_failures := v_failures || format('FAIL (q): editar una compra de remito SIN dinero posteado debía dar P0423 sin tocar stock (vino %s, stock %s -> %s)',
                                           v_txt, v_a2, pg_temp.rcb_stock(v_p2, v_x));
      END IF;
    END IF;
    v_before := pg_temp.rcb_effects(v_account_a);
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_cancel_delivery_note(%L::uuid, 1, %L)', v_dn_cash, 'Gate RaC: anular convertido'));
    IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
      v_failures := v_failures || format('FAIL (r): anular un remito convertido debía dar P0423 sin efectos, vino %s', v_txt);
    END IF;
    -- Editar un remito convertido también está bloqueado (tanda A).
    v_txt := pg_temp.rcb_err(format(
      'SELECT public.rpc_update_purchase_delivery_note(%L::uuid, 1, %L::uuid, %L::uuid, NULL, NULL, %L::jsonb)',
      v_dn_cash, v_s1, v_x, jsonb_build_array(pg_temp.rcb_line(v_p1, 1, 1000, v_u))));
    IF v_txt NOT LIKE 'P0423 delivery_note_locked_converted%' THEN
      v_failures := v_failures || format('FAIL (r): editar un remito convertido debía dar P0423 delivery_note_locked_converted, vino %s', v_txt);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (q/r): sin compra cash no se puede probar la edición bloqueada'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (q/r): editar la compra nacida del remito -> P0423 delivery_note_purchase_locked antes del de dinero y sin efectos (con y sin dinero posteado); anular o editar un convertido -> P0423.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (o) borrar la compra: el remito vuelve a pendiente sin tocar el stock
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_op_cash IS NOT NULL AND v_op_credit IS NOT NULL THEN
    -- El rol purchases (y el stock) no reabren el remito.
    FOREACH v_uuid IN ARRAY ARRAY[v_purchaser, v_stocker] LOOP
      v_before := pg_temp.rcb_effects(v_account_a);
      PERFORM pg_temp.rcb_as(v_uuid);
      v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_credit));
      PERFORM pg_temp.rcb_as(v_owner_a);
      -- multiusuario-operativo (tanda B, D9): borrar una compra exige CAN_PURCHASE (dueño, administrador o compras) ANTES de
      -- llegar al remito. El rol `purchases` (autor de esta compra: la convirtió él) la pasa y recibe el literal propio del
      -- remito; el depósito (`stock`) NO tiene CAN_PURCHASE (recibe mercadería por remito, no compra con factura: OQ-3) y
      -- recibe el P0403 insufficient_role de la capacidad. En los dos casos: P0403 y sin efectos.
      IF v_txt NOT LIKE (CASE WHEN v_uuid = v_stocker THEN 'P0403 insufficient_role%' ELSE 'P0403 delivery_note_purchase_delete_forbidden%' END)
         OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
        v_failures := v_failures || format('FAIL (o): el rol %s no debía poder borrar la compra de un remito (P0403 sin efectos: delivery_note_purchase_delete_forbidden para compras, insufficient_role para el depósito), vino %s', v_uuid, v_txt);
      END IF;
    END LOOP;

    v_a1 := pg_temp.rcb_stock(v_p1, v_x); v_a2 := pg_temp.rcb_stock(v_p2, v_x); v_a3 := pg_temp.rcb_stock(v_pren, v_x);
    SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
    PERFORM pg_temp.rcb_as(v_admin);
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, ''gate'')', v_op_cash));
    PERFORM pg_temp.rcb_as(v_owner_a);
    IF v_txt <> 'OK' THEN
      v_failures := v_failures || format('FAIL (o): borrar la compra cash falló: %s', v_txt);
    ELSE
      IF pg_temp.rcb_stock(v_p1, v_x) <> v_a1 OR pg_temp.rcb_stock(v_p2, v_x) <> v_a2 OR pg_temp.rcb_stock(v_pren, v_x) <> v_a3
         OR (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm THEN
        v_failures := v_failures || 'FAIL (o): borrar la compra nacida del remito tocó el stock'::text;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.cash_movements WHERE session_id = v_session_x
                       AND reference_id = v_op_cash AND movement_type = 'purchase_payment_reversal' AND amount = 2800) THEN
        v_failures := v_failures || 'FAIL (o): falta la compensación de caja'::text;
      END IF;
      IF EXISTS (SELECT 1 FROM public.purchases WHERE operation_id = v_op_cash) THEN
        v_failures := v_failures || 'FAIL (o): quedaron filas de la compra borrada'::text;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = v_op_cash) THEN
        v_failures := v_failures || 'FAIL (o): falta PurchaseDeleted'::text;
      END IF;
      IF pg_temp.rcb_status(v_dn_cash) <> 'issued'
         OR NOT EXISTS (SELECT 1 FROM public.document_status_history WHERE document_type = 'delivery_note_purchase'
                          AND document_id = v_dn_cash AND from_status = 'converted' AND to_status = 'issued'
                          AND performed_by = v_admin AND reason = format('Compra eliminada (operación %s)', v_op_cash)) THEN
        v_failures := v_failures || format('FAIL (o): el remito no volvió a issued con historial converted->issued, usuario y motivo (estado %s)', pg_temp.rcb_status(v_dn_cash));
      END IF;
      IF (public._delivery_note_payload(v_dn_cash)->>'converted_operation_id') IS NOT NULL THEN
        v_failures := v_failures || 'FAIL (o): el payload del remito reabierto sigue apuntando a la compra borrada'::text;
      END IF;
      -- Segundo borrado de la misma operación: sin efectos (devuelve false).
      v_before := pg_temp.rcb_effects(v_account_a);
      v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, ''otra vez'')', v_op_cash));
      IF v_txt <> 'OK' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
        v_failures := v_failures || format('FAIL (o): el segundo borrado de la misma operación debía terminar sin efectos, vino %s', v_txt);
      END IF;
      -- Reconvertir: el remito reabierto vuelve a convertirse, con el stock intacto.
      v_r := pg_temp.rcb_convert(v_tag || 'reconvert', v_dn_cash, 1, v_pm_credit);
      IF v_r NOT LIKE 'OK|%' OR pg_temp.rcb_status(v_dn_cash) <> 'converted' OR pg_temp.rcb_stock(v_p1, v_x) <> v_a1 THEN
        v_failures := v_failures || format('FAIL (o): reconvertir el remito reabierto falló o tocó stock: %s', v_r);
      ELSE
        v_op_re := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
      END IF;
    END IF;

    -- Borrar la compra a crédito compensa la cuenta corriente y reabre su remito.
    -- La reversa de stock se saltea de forma EXPLÍCITA, no por la casualidad de que las filas de
    -- la compra no tengan movimientos propios: se arma (como postgres) un movimiento forjado que
    -- apunta a una fila de la compra; si el borrado revirtiera stock, lo contra-asentaría y
    -- bajaría el saldo.
    SELECT pu.id INTO v_uuid FROM public.purchases pu WHERE pu.operation_id = v_op_credit LIMIT 1;
    PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_x, 1);
    INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type, quantity_delta,
                                        quantity_before, quantity_after, reference_id, reference_type,
                                        performed_by, operation_group_id, branch_id, unit_cost_snapshot)
    VALUES (v_owner_a, v_account_a, v_p2, 'forjado', 'purchase', 1, 0, 1, v_uuid, 'purchase',
            v_owner_a, gen_random_uuid(), v_x, 1);
    v_a2 := pg_temp.rcb_stock(v_p2, v_x);
    SELECT count(*) INTO v_sm FROM public.stock_movements WHERE account_id = v_account_a;
    SELECT COALESCE(sum(sa.balance), 0) INTO v_val FROM public.supplier_accounts sa WHERE sa.supplier_id = v_s1;
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_credit));
    IF v_txt <> 'OK' OR pg_temp.rcb_status(v_dn_credit) <> 'issued' OR pg_temp.rcb_stock(v_p2, v_x) <> v_a2
       OR (SELECT count(*) FROM public.stock_movements WHERE account_id = v_account_a) <> v_sm THEN
      v_failures := v_failures || format('FAIL (o): borrar la compra a crédito (compensación, remito issued, stock sin tocar aunque exista un movimiento forjado que apunta a la compra): %s', v_txt);
    END IF;
    IF (SELECT COALESCE(sum(sa.balance), 0) FROM public.supplier_accounts sa WHERE sa.supplier_id = v_s1) >= v_val THEN
      v_failures := v_failures || format('FAIL (o): borrar la compra a crédito no redujo el saldo del proveedor (%s)', v_val);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (o): sin compras cash y crédito no se puede probar el borrado'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (o): borrar la compra compensa caja o cuenta corriente, deja el stock idéntico y devuelve el remito a issued con historial, usuario y motivo; reconvertir funciona; purchases y stock no reabren el remito; el segundo borrado no tiene efectos.';
  END IF;

  -- Orígenes que NO se reabren (armados como postgres): remito de otra cuenta,
  -- remito de venta y una operación con orígenes mezclados -> P0409 sin efectos.
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  v_j := public.rpc_create_purchase_operation(v_tag || 'forj-1', v_today, 'compra directa 1',
           jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 100)), v_x, NULL, v_pm_other, NULL, v_s1, NULL, NULL);
  v_op_d6 := (v_j->>'operation_id')::uuid;
  -- El remito ajeno y el de venta se arman ADEMÁS en estado converted: si quedaran issued, el
  -- chequeo de estado del borrado los frenaría solo y taparía a los filtros de cuenta y de sentido
  -- (mutantes sin cada filtro sobrevivían). Convertidos, lo único que los frena es esa lectura.
  FOREACH v_uuid IN ARRAY ARRAY[v_dn_b, v_dn_sale] LOOP
    SET session_replication_role = replica;
    UPDATE public.purchases SET source_delivery_note_id = v_uuid WHERE operation_id = v_op_d6;
    UPDATE public.delivery_notes SET status = 'converted' WHERE id = v_uuid;
    SET session_replication_role = DEFAULT;
    v_a1 := pg_temp.rcb_stock(v_p1, v_x);
    v_before := pg_temp.rcb_effects(v_account_a);
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_d6));
    IF v_txt NOT LIKE 'P0409 delivery_note_purchase_mismatch%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before
       OR pg_temp.rcb_status(v_uuid) <> 'converted' THEN
      v_failures := v_failures || format('FAIL (o): un origen de otra cuenta o de venta (converted) no se reabre: se esperaba P0409 delivery_note_purchase_mismatch sin efectos, vino %s', v_txt);
    END IF;
    SET session_replication_role = replica;
    UPDATE public.delivery_notes SET status = 'issued' WHERE id = v_uuid;
    SET session_replication_role = DEFAULT;
  END LOOP;
  -- Orígenes mezclados dentro de la misma operación (una fila con origen y otra sin).
  SET session_replication_role = replica;
  UPDATE public.purchases SET source_delivery_note_id = NULL WHERE operation_id = v_op_d6;
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id, branch_id, supplier_id, source_delivery_note_id)
  VALUES (v_owner_a, v_account_a, v_p1, 100, 1, 100, v_today, v_op_d6, v_x, v_s1, v_dn_mm);
  SET session_replication_role = DEFAULT;
  v_before := pg_temp.rcb_effects(v_account_a);
  v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_d6));
  IF v_txt NOT LIKE 'P0409 delivery_note_purchase_mismatch%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
    v_failures := v_failures || format('FAIL (o): una operación con orígenes mezclados debía dar P0409 sin efectos, vino %s', v_txt);
  END IF;
  -- Una operación con origen cuyo remito NO está converted (armada como postgres) tampoco se reabre.
  SET session_replication_role = replica;
  UPDATE public.purchases SET source_delivery_note_id = v_dn_mm WHERE operation_id = v_op_d6;
  SET session_replication_role = DEFAULT;
  v_before := pg_temp.rcb_effects(v_account_a);
  v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_d6));
  IF v_txt NOT LIKE 'P0409 delivery_note_purchase_mismatch%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
    v_failures := v_failures || format('FAIL (o): un origen cuyo remito no está converted debía dar P0409 sin efectos, vino %s', v_txt);
  END IF;
  SET session_replication_role = replica;
  DELETE FROM public.purchases WHERE operation_id = v_op_d6;
  SET session_replication_role = DEFAULT;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (o): un origen de otra cuenta o de venta, orígenes mezclados y un origen cuyo remito no está converted rebotan con P0409 delivery_note_purchase_mismatch sin reabrir nada.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (p) borrar la compra con la sucursal del remito desactivada / cerrada
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  IF v_op_transfer IS NOT NULL THEN
    SET session_replication_role = replica;
    UPDATE public.branches SET is_active = false WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    v_before := pg_temp.rcb_effects(v_account_a);
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%RC-%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
      v_failures := v_failures || format('FAIL (p): borrar la compra con la sucursal del remito desactivada debía dar P0422 delivery_note_branch_inactive sin efectos: %s', v_txt);
    END IF;
    SET session_replication_role = replica;
    UPDATE public.branches SET is_active = true, status = 'closed', closed_at = now() WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    IF v_txt NOT LIKE 'P0422 delivery_note_branch_inactive%' OR pg_temp.rcb_effects(v_account_a) IS DISTINCT FROM v_before THEN
      v_failures := v_failures || format('FAIL (p): con la sucursal cerrada debía dar P0422 delivery_note_branch_inactive sin efectos: %s', v_txt);
    END IF;
    SET session_replication_role = replica;
    UPDATE public.branches SET status = 'active', closed_at = NULL WHERE id = v_y;
    SET session_replication_role = DEFAULT;
    -- Reactivada: el borrado funciona y el remito vuelve a issued.
    v_txt := pg_temp.rcb_err(format('SELECT public.rpc_delete_purchase_operation(NULL, %L::uuid, NULL)', v_op_transfer));
    IF v_txt <> 'OK' OR pg_temp.rcb_status(v_dn_transfer) <> 'issued'
       OR NOT EXISTS (SELECT 1 FROM public.bank_movements WHERE source_doc_ref = v_op_transfer AND amount = 1000) THEN
      v_failures := v_failures || format('FAIL (p): con la sucursal reactivada el borrado debía funcionar y compensar el banco: %s', v_txt);
    END IF;
  ELSE
    v_failures := v_failures || 'FAIL (p): sin la compra por transferencia no se puede probar el guard de sucursal'::text;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (p): con la sucursal del remito desactivada o cerrada el borrado da P0422 delivery_note_branch_inactive sin efectos; reactivada, funciona y compensa el banco.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (pg) integridad del puente por PostgREST con un seller real
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  -- Una compra de remito viva (v_op_pur) y dos compras directas.
  v_r := pg_temp.rcb_convert(v_tag || 'pur', v_dn_pur, 1, v_pm_other);
  v_op_pur := (substr(v_r, 4)::jsonb->>'operation_id')::uuid;
  v_j := public.rpc_create_purchase_operation(v_tag || 'pg-d1', v_today, 'directa 1',
           jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 100)), v_x, NULL, v_pm_other, NULL, NULL, NULL, NULL);
  v_op_d1 := (v_j->>'operation_id')::uuid;
  v_j := public.rpc_create_purchase_operation(v_tag || 'pg-d2', v_today, 'directa 2',
           jsonb_build_array(pg_temp.rcb_pline(v_p1, 1, 100)), v_x, NULL, v_pm_other, NULL, NULL, NULL, NULL);
  v_op_d2 := (v_j->>'operation_id')::uuid;
  v_op_d3 := gen_random_uuid();
  IF v_op_pur IS NULL THEN
    v_failures := v_failures || format('FAIL (pg): no se pudo armar la compra de remito: %s', v_r);
  ELSE
    SELECT string_agg(pu.id::text || ':' || COALESCE(pu.source_delivery_note_id::text, '-') || ':' || COALESCE(pu.operation_id::text, '-')
                      || ':' || COALESCE(pu.description, '-'), ',' ORDER BY pu.id)
      INTO v_snap FROM public.purchases pu WHERE pu.operation_id IN (v_op_pur, v_op_d1, v_op_d2);
    PERFORM pg_temp.rcb_as(v_seller);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOR v_rec IN
      SELECT * FROM (VALUES
        ('forjar el origen de una compra directa',
           format('UPDATE public.purchases SET source_delivery_note_id = %L WHERE operation_id = %L', v_dn_sec, v_op_d1)),
        ('limpiar el origen de una compra de remito',
           format('UPDATE public.purchases SET source_delivery_note_id = NULL WHERE operation_id = %L', v_op_pur)),
        ('cambiar el origen de una compra de remito',
           format('UPDATE public.purchases SET source_delivery_note_id = %L WHERE operation_id = %L', v_dn_sec, v_op_pur)),
        ('modificar cualquier columna de una fila con origen',
           format('UPDATE public.purchases SET description = ''tocada'' WHERE operation_id = %L', v_op_pur)),
        ('partir la compra cambiando su operation_id',
           format('UPDATE public.purchases SET operation_id = %L WHERE operation_id = %L', v_op_d3, v_op_pur)),
        ('mezclar una compra directa con la de remito (UPDATE operation_id)',
           format('UPDATE public.purchases SET operation_id = %L WHERE operation_id = %L', v_op_pur, v_op_d1)),
        ('INSERT de una fila con origen',
           format('INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id, branch_id, source_delivery_note_id) VALUES (%L, %L, %L, 1, 1, 1, %L, %L, %L, %L)',
                  v_seller, v_account_a, v_p1, v_today, gen_random_uuid(), v_x, v_dn_sec)),
        ('mezclar con un INSERT que lleva el operation_id de la compra de remito',
           format('INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id, branch_id) VALUES (%L, %L, %L, 1, 1, 1, %L, %L, %L)',
                  v_seller, v_account_a, v_p1, v_today, v_op_pur, v_x)),
        ('borrar las filas de la compra de remito',
           format('DELETE FROM public.purchases WHERE operation_id = %L', v_op_pur))
      ) AS t(label, stmt)
    LOOP
      BEGIN
        EXECUTE v_rec.stmt;
        v_failures := v_failures || format('FAIL (pg): %s debía rechazarse con P0403 delivery_note_source_protected y prosperó', v_rec.label);
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        IF v_state <> 'P0403' OR v_msg NOT LIKE 'delivery_note_source_protected%' THEN
          v_failures := v_failures || format('FAIL (pg): %s debía dar P0403 delivery_note_source_protected, dio %s %s', v_rec.label, v_state, v_msg);
        END IF;
      END;
    END LOOP;
    -- Controles positivos: las MISMAS escrituras sobre compras directas siguen como hoy.
    BEGIN
      UPDATE public.purchases SET description = 'directa tocada' WHERE operation_id = v_op_d1;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n <> 1 THEN
        v_failures := v_failures || format('FAIL (pg) control: UPDATE de una compra directa afectó %s filas (se esperaba 1)', v_n);
      END IF;
      UPDATE public.purchases SET operation_id = v_op_d2 WHERE operation_id = v_op_d1;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n <> 1 THEN
        v_failures := v_failures || format('FAIL (pg) control: mezclar dos compras DIRECTAS afectó %s filas (se esperaba 1)', v_n);
      END IF;
      INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id, branch_id)
      VALUES (v_seller, v_account_a, v_p1, 1, 1, 1, v_today, v_op_d3, v_x);
      DELETE FROM public.purchases WHERE operation_id = v_op_d3;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n <> 1 THEN
        v_failures := v_failures || format('FAIL (pg) control: INSERT + DELETE de una compra directa afectó %s filas (se esperaba 1)', v_n);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_failures := v_failures || format('FAIL (pg) control: una escritura sobre una compra DIRECTA debía seguir funcionando y dio %s %s', v_state, v_msg);
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.rcb_as(v_owner_a);
    -- Los ataques no dejaron rastro sobre las filas de la compra de remito.
    SELECT string_agg(pu.id::text || ':' || COALESCE(pu.source_delivery_note_id::text, '-') || ':' || COALESCE(pu.operation_id::text, '-')
                      || ':' || COALESCE(pu.description, '-'), ',' ORDER BY pu.id)
      INTO v_before FROM public.purchases pu WHERE pu.operation_id = v_op_pur;
    IF v_before NOT LIKE '%' || v_dn_pur::text || '%' OR v_before LIKE '%tocada%' THEN
      v_failures := v_failures || format('FAIL (pg): la compra de remito quedó alterada (%s)', v_before);
    END IF;
    IF (SELECT count(*) FROM public.purchases WHERE operation_id = v_op_pur AND source_delivery_note_id = v_dn_pur) <> 1 THEN
      v_failures := v_failures || 'FAIL (pg): la compra de remito perdió su origen o sus filas'::text;
    END IF;
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (pg): como seller por PostgREST, forjar / limpiar / cambiar el origen, tocar una fila con origen, partir, mezclar (UPDATE e INSERT), INSERT con origen y DELETE dan P0403 delivery_note_source_protected; las mismas escrituras sobre compras directas siguen funcionando.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (s) invariante: ninguna fila de una compra con origen tiene movimiento de stock
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  SELECT count(*) INTO v_n
  FROM public.stock_movements sm JOIN public.purchases pu ON pu.id = sm.reference_id
  WHERE pu.account_id = v_account_a AND pu.source_delivery_note_id IS NOT NULL;
  IF v_n <> 0 THEN
    v_failures := v_failures || format('FAIL (s): %s movimientos de stock apuntan a filas de compras con origen de remito', v_n);
  END IF;
  -- Σ delta por (producto, sucursal) = lo que aportaron los remitos: el ledger reconcilia.
  FOR v_rec IN
    SELECT bs.product_id, bs.branch_id, bs.quantity,
           COALESCE((SELECT sum(sm.quantity_delta) FROM public.stock_movements sm
                     WHERE sm.product_id = bs.product_id AND sm.branch_id = bs.branch_id), 0) AS ledger
    FROM public.branch_stock bs WHERE bs.account_id = v_account_a
  LOOP
    IF v_rec.quantity IS DISTINCT FROM v_rec.ledger THEN
      v_failures := v_failures || format('FAIL (s): el ledger no reconcilia con branch_stock para %s en %s (%s vs %s)',
                                         COALESCE(v_labels->>v_rec.product_id::text, v_rec.product_id::text),
                                         COALESCE(v_labels->>v_rec.branch_id::text, v_rec.branch_id::text), v_rec.ledger, v_rec.quantity);
    END IF;
  END LOOP;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (s): ninguna fila de compra con origen tiene movimiento de stock y el ledger reconcilia con branch_stock.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Limpieza (toda fila con account_id de las cuentas del gate) y residuo cero
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.rcb_as(NULL);
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
     OR EXISTS (SELECT 1 FROM public.supplier_account_movements WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.internal_document_sequences WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.document_status_history WHERE account_id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM public.operation_idempotency WHERE user_id = ANY (v_users))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    v_failures := v_failures || 'FAIL (limpieza): quedaron filas del gate'::text;
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'GATE REMITO-A-COMPRA FAILED (% fallas):\n  %', array_length(v_failures, 1), array_to_string(v_failures, E'\n  ');
  END IF;
  RAISE NOTICE 'GATE REMITO-A-COMPRA PASSED: golden de la compra directa, núcleo sin doble suma (orígenes inválidos rebotan), conversión cash / crédito / transferencia, rechazos sin efectos, idempotencia, roles, edición bloqueada, borrado que reabre el remito sin tocar stock, sucursal viva, integridad del puente por PostgREST e invariante del ledger — residuo cero.';

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
    RAISE EXCEPTION 'GATE REMITO-A-COMPRA FAILED (abortó): % / %', v_state, v_msg;
END $$;

-- =============================================================================
-- (u) Introspección PERMANENTE de la tanda B (sin fixtures, sin md5): la migración
-- 20261081000001 ya la corre al aplicarse, pero un gate de CI tiene que seguir
-- diciendo la verdad cuando otro change reescriba estas funciones. Por eso mira
-- la ESTRUCTURA (qué hay y en qué orden), no el hash del cuerpo.
-- =============================================================================
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   text;
  v_n    integer;
  v_oid  oid;
  v_src  text;
  v_core constant text := 'public._purchase_operation_core(uuid, text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date, uuid)';
  v_pos_dn integer;
  v_pos_delta integer;
BEGIN
  -- Una sola definición por función (sin overloads).
  FOREACH v_fn IN ARRAY ARRAY['_purchase_operation_core', 'rpc_create_purchase_operation',
                              'rpc_convert_delivery_note_to_purchase', 'rpc_delete_purchase_operation',
                              'rpc_atomic_update_purchase_operation', '_delivery_note_payload',
                              'trg_purchases_guard_delivery_note_source'] LOOP
    SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_n <> 1 THEN v_bad := v_bad || format('(u) %s tiene %s definiciones (se esperaba 1)', v_fn, v_n); END IF;
  END LOOP;

  -- ACLs: núcleo, payload y función del disparador sin EXECUTE para la aplicación; el wrapper y las tres RPC
  -- públicas con authenticated y sin anon/PUBLIC; todo SECURITY DEFINER salvo el disparador (INVOKER, a propósito).
  FOREACH v_fn IN ARRAY ARRAY[v_core, 'public._delivery_note_payload(uuid)', 'public.trg_purchases_guard_delivery_note_source()'] LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN v_bad := v_bad || format('(u) %s no existe', v_fn);
    ELSIF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
          OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                     WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      v_bad := v_bad || format('(u) %s es ejecutable por authenticated, anon o PUBLIC', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)',
                              'public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text)',
                              'public.rpc_delete_purchase_operation(uuid, uuid, text)',
                              'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)'] LOOP
    v_oid := to_regprocedure(v_fn);
    IF v_oid IS NULL THEN v_bad := v_bad || format('(u) %s no existe', v_fn);
    ELSIF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      v_bad := v_bad || format('(u) %s NO es ejecutable por authenticated', v_fn);
    ELSIF has_function_privilege('anon', v_oid, 'EXECUTE')
          OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                     WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      v_bad := v_bad || format('(u) %s es ejecutable por anon o PUBLIC', v_fn);
    ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
      v_bad := v_bad || format('(u) %s no es SECURITY DEFINER', v_fn);
    ELSIF obj_description(v_oid, 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('(u) %s sin COMMENT', v_fn);
    END IF;
  END LOOP;
  IF NOT COALESCE((SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_core)), false) THEN
    v_bad := v_bad || '(u) el núcleo no es SECURITY DEFINER'::text;
  END IF;
  IF COALESCE((SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.trg_purchases_guard_delivery_note_source()')), true) THEN
    v_bad := v_bad || '(u) la función del disparador del puente debe ser SECURITY INVOKER (current_user tiene que ser el que escribe)'::text;
  END IF;

  -- Disparador del puente: por fila, BEFORE INSERT OR UPDATE OR DELETE, habilitado.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                 WHERE t.tgrelid = 'public.purchases'::regclass AND t.tgname = 'trg_purchases_guard_delivery_note_source'
                   AND NOT t.tgisinternal AND t.tgenabled = 'O' AND t.tgtype = 31) THEN
    v_bad := v_bad || '(u) falta el disparador del puente (BEFORE INSERT OR UPDATE OR DELETE, por fila, habilitado)'::text;
  END IF;

  -- Catálogo de la tanda B, por PRESENCIA y atributos (nunca por conteo).
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'issued' AND to_status = 'converted'
                   AND cardinality(allowed_role) = 4 AND allowed_role @> ARRAY['purchases', 'stock', 'admin', 'owner']
                   AND NOT requires_reason AND NOT is_terminal_to) THEN
    v_bad := v_bad || '(u) falta issued -> converted de delivery_note_purchase con {purchases,stock,admin,owner}'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'converted' AND to_status = 'issued'
                   AND allowed_role IS NULL AND NOT requires_reason AND NOT is_terminal_to) THEN
    v_bad := v_bad || '(u) falta converted -> issued de delivery_note_purchase (sin rol)'::text;
  END IF;

  -- Núcleo: la rama de origen, el salto del stock y la transición a converted dentro del propio núcleo.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure(v_core);
  IF position('delivery_note_items_from_source' IN v_src) = 0 OR position('delivery_note_purchase_mismatch' IN v_src) = 0
     OR position('IF NOT v_from_dn THEN' IN v_src) = 0 OR position('c21_apply_branch_stock_delta' IN v_src) = 0
     OR position('''delivery_note_purchase'', p_source_delivery_note_id, ''issued'', ''converted''' IN v_src) = 0 THEN
    v_bad := v_bad || '(u) el núcleo no tiene la rama de origen (p_items nulo, revalidación, salto del stock, transición a converted)'::text;
  ELSE
    -- El salto del stock envuelve al delta de stock: el último IF NOT v_from_dn que lo precede está a menos de
    -- 700 caracteres.
    v_pos_delta := position('c21_apply_branch_stock_delta' IN v_src);
    IF position('IF NOT v_from_dn THEN' IN substr(v_src, GREATEST(v_pos_delta - 700, 1), 700)) = 0 THEN
      v_bad := v_bad || '(u) el delta de stock del núcleo no está dentro del salto IF NOT v_from_dn'::text;
    END IF;
  END IF;

  -- Wrapper: sin lógica propia ni parámetro de origen.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)');
  IF position('_purchase_operation_core(' IN v_src) = 0 OR position('c21_apply_branch_stock_delta' IN v_src) > 0
     OR position('source_delivery_note' IN v_src) > 0 THEN
    v_bad := v_bad || '(u) rpc_create_purchase_operation debe ser un wrapper del núcleo, sin lógica propia ni parámetro de origen'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proargnames) a(n)
             WHERE p.oid = to_regprocedure('public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)')
               AND a.n ILIKE '%source%') THEN
    v_bad := v_bad || '(u) la firma pública de la compra no puede aceptar un parámetro de origen'::text;
  END IF;

  -- Borrado: el lock del remito ANTES de TODA compensación (cuenta corriente, caja, banco, stock), el rol
  -- de anular, la sucursal viva con FOR SHARE y el salto explícito de la reversa de stock.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public.rpc_delete_purchase_operation(uuid, uuid, text)');
  v_pos_dn := position('FROM public.delivery_notes dn' IN v_src);
  IF v_pos_dn = 0 OR position('FOR SHARE' IN v_src) = 0 OR position('delivery_note_purchase_delete_forbidden' IN v_src) = 0
     OR position('IF v_source_dn IS NULL THEN' IN v_src) = 0 OR position('delivery_note_branch_inactive' IN v_src) = 0 THEN
    v_bad := v_bad || '(u) el borrado no tiene el lock del remito, el rol de anular, la sucursal viva o el salto de la reversa de stock'::text;
  ELSIF v_pos_dn > position('_pay_reverse_party_charge(' IN v_src)
        OR v_pos_dn > position('c28_register_cash_movement(' IN v_src)
        OR v_pos_dn > position('FROM public.bank_movements' IN v_src)
        OR v_pos_dn > position('rpc_reverse_stock_movement(' IN v_src) THEN
    v_bad := v_bad || '(u) el borrado toma el lock del remito DESPUÉS de una compensación (orden remito -> dinero)'::text;
  END IF;

  -- Edición: el P0423 del remito ANTES de los P0423 de dinero.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)');
  IF position('delivery_note_purchase_locked' IN v_src) = 0
     OR position('delivery_note_purchase_locked' IN v_src) > position('operation_has_account_charge_immutable' IN v_src) THEN
    v_bad := v_bad || '(u) la edición no rechaza la compra de un remito (P0423) ANTES de los P0423 de dinero'::text;
  END IF;

  -- Conversión: lock, rol del remito, precios y proveedor vivo antes de llamar al núcleo, que es el único camino a la compra.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public.rpc_convert_delivery_note_to_purchase(text, uuid, integer, uuid, date, uuid, uuid, uuid, date, text)');
  IF position('_delivery_note_assert_role_dir(' IN v_src) = 0 OR position('_purchase_operation_core(' IN v_src) = 0
     OR position('_delivery_note_assert_role_dir(' IN v_src) > position('_purchase_operation_core(' IN v_src)
     OR position('FOR UPDATE' IN v_src) = 0 OR position('FOR UPDATE' IN v_src) > position('_delivery_note_assert_role_dir(' IN v_src)
     OR position('delivery_note_price_required' IN v_src) = 0 OR position('delivery_note_price_required' IN v_src) > position('_purchase_operation_core(' IN v_src)
     OR position('delivery_note_supplier_unavailable' IN v_src) = 0 OR position('delivery_note_supplier_unavailable' IN v_src) > position('_purchase_operation_core(' IN v_src) THEN
    v_bad := v_bad || '(u) la conversión no toma el lock, no exige el rol, los precios y el proveedor vivo antes de llamar al núcleo'::text;
  END IF;

  -- Payload: la compra generada en el campo genérico existente, sin un campo paralelo.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public._delivery_note_payload(uuid)');
  IF position('public.purchases pu' IN v_src) = 0 OR position('pu.source_delivery_note_id = dn.id' IN v_src) = 0
     OR position('pu.account_id = dn.account_id' IN v_src) = 0 OR position('converted_purchase' IN v_src) > 0 THEN
    v_bad := v_bad || '(u) el payload no deriva converted_operation_id de purchases.source_delivery_note_id con account_id (o suma un campo paralelo)'::text;
  END IF;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'GATE REMITO-A-COMPRA (u) FAILED:\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'PASS (u): introspección permanente de la tanda B -- una definición por función, ACLs, núcleo interno, wrapper sin parámetro de origen, disparador del puente, catálogo, lock del remito antes de toda compensación, salto de la reversa, P0423 antes del dinero.';
END $$;
