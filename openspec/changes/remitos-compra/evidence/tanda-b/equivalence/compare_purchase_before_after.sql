-- =============================================================================
-- Comparación diferencial UNA VEZ (tarea 6.4, D8): el cuerpo VIVO previo de
-- rpc_create_purchase_operation (checkpoint 6.1, md5 361a1ffc...) contra el wrapper +
-- _purchase_operation_core de la migración 20261081000001.
--
-- Qué hace: dentro de UNA transacción que se revierte, instala el cuerpo previo
-- como pg_temp.purchase_before(...) y corre las MISMAS compras con las dos
-- funciones sobre DOS cuentas con fixtures idénticos (mismos productos, costos,
-- stock inicial, sucursales, caja abierta, banco, proveedor con plazo). Compara
-- fila a fila -sin ids ni timestamps- purchases, purchase_items, stock_movements,
-- branch_stock, cash_movements, bank_movements, supplier_account_movements y el
-- evento PurchaseCreated, más el resultado y los rechazos (SQLSTATE + mensaje).
--
-- NO se cablea en CI: un cuerpo congelado divergiría a propósito con el primer
-- cambio futuro de la compra (D8). Lo que SÍ queda permanente son los valores
-- golden de test_remito_a_compra.sql (g0).
--
-- Uso (desde la raíz del repo, con la base local construida desde las migraciones):
--   psql -v ON_ERROR_STOP=1 -f openspec/changes/remitos-compra/evidence/tanda-b/equivalence/compare_purchase_before_after.sql
-- =============================================================================
\set ON_ERROR_STOP on
\set oldsrc `sed 's/public\.rpc_create_purchase_operation(/pg_temp.purchase_before(/' openspec/changes/remitos-compra/evidence/tanda-b/rpc_create_purchase_operation.before.sql`

BEGIN;

SET check_function_bodies = off;
SELECT :'oldsrc' \gexec

CREATE OR REPLACE FUNCTION pg_temp.eq_as(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
END; $f$;

-- Fixture idéntico por cuenta: devuelve los ids con sus etiquetas.
CREATE OR REPLACE FUNCTION pg_temp.eq_fixture(p_tag text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE
  v_owner uuid := gen_random_uuid(); v_acc uuid; v_x uuid; v_y uuid; v_cb uuid; v_sess uuid; v_bank uuid;
  v_pm_cash uuid; v_pm_credit uuid; v_pm_transfer uuid; v_pm_other uuid; v_sup uuid; v_kg uuid; v_g uuid; v_u uuid;
  v_p1 uuid; v_p2 uuid; v_pkg uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_owner, 'authenticated', 'authenticated', 'eq-' || p_tag || '@test.local', now(), now(),
          jsonb_build_object('name', 'Eq ' || p_tag, 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_owner ORDER BY created_at LIMIT 1;
  SELECT id INTO v_x FROM public.branches WHERE account_id = v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, created_at)
  VALUES (v_acc, 'Eq Y', TRUE, 'active', now(), now() + interval '1 minute') RETURNING id INTO v_y;
  SELECT id INTO v_cb FROM public.cashboxes WHERE branch_id = v_x ORDER BY created_at LIMIT 1;
  IF v_cb IS NULL THEN INSERT INTO public.cashboxes (branch_id, name) VALUES (v_x, 'Caja Eq X') RETURNING id INTO v_cb; END IF;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES (v_cb, 'open', 0, v_owner) RETURNING id INTO v_sess;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES (v_acc, 'Banco Eq', 'ARS', 0) RETURNING id INTO v_bank;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_acc AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods WHERE account_id = v_acc AND kind = 'credit' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_acc AND kind = 'transfer' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  SELECT id INTO v_pm_other FROM public.payment_methods WHERE account_id = v_acc AND kind = 'other' AND is_active AND deleted_at IS NULL ORDER BY sort_order LIMIT 1;
  INSERT INTO public.suppliers (account_id, name, payment_terms_days) VALUES (v_acc, 'Proveedor Eq', 30) RETURNING id INTO v_sup;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) VALUES (v_acc, 'Unidad Eq', 'u', 'unit', 1, false) RETURNING id INTO v_u;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) VALUES (v_acc, 'Kilogramo Eq', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system) VALUES (v_acc, 'Gramo Eq', 'g', 'weight', 0.001, v_kg, false) RETURNING id INTO v_g;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Eq P1', 'EQ-P1', 100, 1000, v_u) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Eq P2', 'EQ-P2', 50, 500, v_u) RETURNING id INTO v_p2;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Eq Kg', 'EQ-KG', 1000, 2000, v_kg) RETURNING id INTO v_pkg;
  -- stock inicial idéntico (como postgres: el ledger no admite escritura directa de authenticated)
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p1, v_x, 10);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p2, v_x, 5);
  RETURN jsonb_build_object('owner', v_owner, 'acc', v_acc, 'x', v_x, 'y', v_y, 'sess', v_sess, 'bank', v_bank,
    'cash', v_pm_cash, 'credit', v_pm_credit, 'transfer', v_pm_transfer, 'other', v_pm_other, 'sup', v_sup,
    'kg', v_kg, 'g', v_g, 'u', v_u, 'p1', v_p1, 'p2', v_p2, 'pkg', v_pkg,
    'labels', jsonb_build_object(v_p1::text, 'p1', v_p2::text, 'p2', v_pkg::text, 'pkg', v_x::text, 'X', v_y::text, 'Y',
      v_u::text, 'u', v_kg::text, 'kg', v_g::text, 'g', v_sup::text, 'sup', v_pm_cash::text, 'cash',
      v_pm_credit::text, 'credit', v_pm_transfer::text, 'transfer', v_pm_other::text, 'other', v_bank::text, 'bank'));
END; $f$;

-- Retrato canónico de una operación y del estado que dejó (sin ids ni timestamps).
CREATE OR REPLACE FUNCTION pg_temp.eq_snap(p_op uuid, p_fx jsonb, p_ref date) RETURNS text LANGUAGE sql AS $f$
  SELECT concat_ws(E'\n',
    (SELECT string_agg(format('PU|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_fx->'labels'->>pu.product_id::text, '-'), pu.amount, pu.quantity, COALESCE(p_fx->'labels'->>pu.unit_id::text, '-'),
         pu.total, COALESCE(p_fx->'labels'->>pu.branch_id::text, '-'), COALESCE(pu.name_snapshot, '-'), COALESCE(pu.sku_snapshot, '-'),
         COALESCE(pu.unit_cost_snapshot::text, '-'), COALESCE(pu.iva_rate_snapshot::text, '-'),
         COALESCE(p_fx->'labels'->>pu.supplier_id::text, '-'), COALESCE(p_fx->'labels'->>pu.payment_method_id::text, '-'),
         pu.date, COALESCE(pu.description, '-')),
       E'\n' ORDER BY COALESCE(p_fx->'labels'->>pu.product_id::text, '-'), pu.amount, pu.quantity, pu.description)
     FROM public.purchases pu WHERE pu.operation_id = p_op),
    (SELECT string_agg(format('PI|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_fx->'labels'->>pi.product_id::text, '-'), pi.quantity, COALESCE(p_fx->'labels'->>pi.unit_id::text, '-'),
         pi.price, pi.subtotal, COALESCE(pi.name_snapshot, '-'), COALESCE(pi.sku_snapshot, '-'), COALESCE(pi.unit_cost_snapshot::text, '-')),
       E'\n' ORDER BY COALESCE(p_fx->'labels'->>pi.product_id::text, '-'), pi.price, pi.quantity)
     FROM public.purchase_items pi WHERE pi.purchase_id IN (SELECT id FROM public.purchases WHERE operation_id = p_op)),
    (SELECT string_agg(format('SM|%s|%s|%s|%s|%s|%s|%s|%s|%s',
         COALESCE(p_fx->'labels'->>sm.product_id::text, '-'), sm.product_name, sm.type, sm.reference_type, sm.quantity_delta,
         sm.quantity_before, sm.quantity_after, COALESCE(p_fx->'labels'->>sm.branch_id::text, '-'), COALESCE(sm.unit_cost_snapshot::text, '-')),
       E'\n' ORDER BY COALESCE(p_fx->'labels'->>sm.product_id::text, '-'), sm.quantity_delta)
     FROM public.stock_movements sm WHERE sm.reference_id IN (SELECT id FROM public.purchases WHERE operation_id = p_op)),
    (SELECT string_agg(format('CM|%s|%s', cm.movement_type, cm.amount), E'\n' ORDER BY cm.movement_type, cm.amount)
     FROM public.cash_movements cm WHERE cm.reference_id = p_op),
    (SELECT string_agg(format('BM|%s|%s|%s|%s', bm.movement_type, bm.amount, COALESCE(p_fx->'labels'->>bm.branch_id::text, '-'),
                              bm.source_doc_type),
                       E'\n' ORDER BY bm.movement_type, bm.amount)
     FROM public.bank_movements bm WHERE bm.source_doc_ref = p_op),
    (SELECT string_agg(format('SA|%s|%s|%s', sam.movement_type, sam.amount, COALESCE((sam.due_date - p_ref)::text, '-')),
                       E'\n' ORDER BY sam.movement_type, sam.amount)
     FROM public.supplier_account_movements sam WHERE sam.reference_id = p_op),
    (SELECT string_agg(format('EV|%s|%s|%s|%s|%s', e.event_type, e.aggregate_type, e.payload->>'total', e.payload->>'payment_method',
                              COALESCE(e.payload->>'cost_center_id', '-')), E'\n' ORDER BY e.event_type)
     FROM public.events e WHERE e.aggregate_id = p_op),
    (SELECT 'IDEM|' || count(*) FROM public.operation_idempotency oi WHERE oi.operation_id = p_op),
    (SELECT 'BS|' || COALESCE(string_agg(format('%s:%s:%s', COALESCE(p_fx->'labels'->>bs.product_id::text, '-'),
                       COALESCE(p_fx->'labels'->>bs.branch_id::text, '-'), bs.quantity), ',' ORDER BY p_fx->'labels'->>bs.product_id::text, p_fx->'labels'->>bs.branch_id::text), '')
       FROM public.branch_stock bs WHERE bs.account_id = (p_fx->>'acc')::uuid));
$f$;

-- Ejecuta un caso con la función vieja o la nueva: devuelve el retrato (o el error) del resultado.
CREATE OR REPLACE FUNCTION pg_temp.eq_run(p_which text, p_fx jsonb, p_key text, p_date date, p_items jsonb,
        p_branch uuid, p_pm uuid, p_bank uuid, p_sup uuid, p_session uuid, p_due date, p_cc uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v jsonb; v_state text; v_msg text; v_op uuid; v_items jsonb;
BEGIN
  PERFORM pg_temp.eq_as((p_fx->>'owner')::uuid);
  IF p_which = 'old' THEN
    v := pg_temp.purchase_before(p_key, p_date, 'eq caso', p_items, p_branch, p_cc, p_pm, p_bank, p_sup, p_session, p_due);
  ELSE
    v := public.rpc_create_purchase_operation(p_key, p_date, 'eq caso', p_items, p_branch, p_cc, p_pm, p_bank, p_sup, p_session, p_due);
  END IF;
  v_op := (v->>'operation_id')::uuid;
  v_items := v->'items';
  RETURN 'OK|replayed=' || (v->>'replayed') || '|items=' || jsonb_array_length(v_items) || E'\n' || pg_temp.eq_snap(v_op, p_fx, p_date);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  RETURN 'ERR|' || v_state || '|' || v_msg;
END; $f$;

CREATE OR REPLACE FUNCTION pg_temp.eq_pline(p_product uuid, p_qty numeric, p_amount numeric, p_unit uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$ SELECT jsonb_build_object('product_id', p_product, 'unit_id', p_unit, 'quantity', p_qty, 'amount', p_amount); $f$;

-- Un caso = (numero, argumentos de la compra) sobre un fixture; devuelve el retrato.
CREATE OR REPLACE FUNCTION pg_temp.eq_case(p_n int, p_which text, p_fx jsonb) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_today date := public.reporting_local_today();
  k text := 'eq-' || p_n || '-' || p_which;
  p1 uuid := (p_fx->>'p1')::uuid; p2 uuid := (p_fx->>'p2')::uuid; pkg uuid := (p_fx->>'pkg')::uuid;
  x uuid := (p_fx->>'x')::uuid; y uuid := (p_fx->>'y')::uuid;
  pmc uuid := (p_fx->>'cash')::uuid; pmk uuid := (p_fx->>'credit')::uuid; pmt uuid := (p_fx->>'transfer')::uuid; pmo uuid := (p_fx->>'other')::uuid;
  sup uuid := (p_fx->>'sup')::uuid; sess uuid := (p_fx->>'sess')::uuid; bank uuid := (p_fx->>'bank')::uuid;
  g uuid := (p_fx->>'g')::uuid;
BEGIN
  RETURN CASE p_n
    WHEN 1  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 2, 1000)), x, pmc, NULL, NULL, sess, NULL)
    WHEN 2  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 500)), x, pmc, NULL, NULL, NULL, NULL)
    WHEN 3  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 3, 100)), x, pmk, NULL, sup, NULL, NULL)
    WHEN 4  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 700)), x, pmk, NULL, sup, NULL, v_today + 10)
    WHEN 5  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p2, 4, 250)), x, pmt, bank, NULL, NULL, NULL)
    WHEN 6  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(NULL, 1, 1500), pg_temp.eq_pline(p1, 1, 90)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 7  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(pkg, 450, 2, g)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 8  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100), pg_temp.eq_pline(p1, 2, 110), pg_temp.eq_pline(p2, 5, 60)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 9  THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), NULL, pmo, NULL, NULL, NULL, NULL)
    WHEN 10 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p2, 2, 100)), y, pmo, NULL, NULL, NULL, NULL)
    WHEN 11 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p2, 1, 100)), x, NULL, NULL, NULL, NULL, NULL)
    WHEN 12 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmo, NULL, NULL, NULL, NULL)
                 || E'\n--segunda llamada, misma clave--\n' ||
                 pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 13 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 0)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 14 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 0, 100)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 15 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmk, NULL, NULL, NULL, NULL)
    WHEN 16 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmt, NULL, NULL, sess, NULL)
    WHEN 17 THEN pg_temp.eq_run(p_which, p_fx, k, v_today + 1, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmc, NULL, NULL, sess, NULL)
    WHEN 18 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, '[]'::jsonb, x, pmo, NULL, NULL, NULL, NULL)
    WHEN 19 THEN pg_temp.eq_run(p_which, p_fx, '', v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 20 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), x, pmo, NULL, gen_random_uuid(), NULL, NULL)
    WHEN 21 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), gen_random_uuid(), pmo, NULL, NULL, NULL, NULL)
    WHEN 22 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(gen_random_uuid(), 1, 100)), x, pmo, NULL, NULL, NULL, NULL)
    WHEN 23 THEN pg_temp.eq_run(p_which, p_fx, k, v_today, jsonb_build_array(pg_temp.eq_pline(p1, 1, 100)), y, pmc, NULL, NULL, sess, NULL)
  END;
END; $f$;

DO $$
DECLARE
  v_fa jsonb := pg_temp.eq_fixture('old');   -- cuenta donde corre el cuerpo PREVIO
  v_fb jsonb := pg_temp.eq_fixture('new');   -- cuenta donde corre el wrapper + núcleo
  v_labels text[] := ARRAY[
    'cash con caja abierta de la sucursal, hoy',
    'cash SIN caja (sólo stock)',
    'credit con proveedor: cargo y vencimiento por cascada (30 días)',
    'credit con vencimiento explícito',
    'transfer con cuenta bancaria',
    'línea sin producto + línea con producto',
    '450 g de un producto en kg (unidad no base)',
    'dos líneas del mismo producto + otro producto',
    'sin sucursal elegida (sucursal por defecto)',
    'sucursal Y elegida',
    'sin forma de pago',
    'replay con la misma clave',
    'rechazo: monto 0',
    'rechazo: cantidad 0',
    'rechazo: crédito sin proveedor',
    'rechazo: caja con forma de pago que no es efectivo',
    'rechazo: caja con otra fecha',
    'rechazo: sin items',
    'rechazo: clave vacía',
    'rechazo: proveedor inexistente',
    'rechazo: sucursal inexistente',
    'rechazo: producto inexistente',
    'rechazo: sesión de caja de otra sucursal'];
  v_n int; v_bad text[] := '{}'; v_ra text; v_rb text;
BEGIN
  FOR v_n IN 1..array_length(v_labels, 1) LOOP
    v_ra := pg_temp.eq_case(v_n, 'old', v_fa);
    v_rb := pg_temp.eq_case(v_n, 'new', v_fb);
    -- Los mensajes de error pueden llevar uuids propios de cada cuenta: se enmascaran antes de comparar.
    v_ra := regexp_replace(v_ra, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g');
    v_rb := regexp_replace(v_rb, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g');
    IF v_ra IS DISTINCT FROM v_rb THEN
      v_bad := v_bad || format(E'caso %s (%s) DIFIERE\n--- previo:\n%s\n--- nuevo:\n%s', v_n, v_labels[v_n], v_ra, v_rb);
    ELSE
      RAISE NOTICE 'caso % (%): IDENTICO [%]', v_n, v_labels[v_n], split_part(v_ra, E'\n', 1);
    END IF;
  END LOOP;
  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'EQUIVALENCIA FALLO en % de % casos:\n%', array_length(v_bad, 1), array_length(v_labels, 1), array_to_string(v_bad, E'\n\n');
  END IF;
  RAISE NOTICE 'EQUIVALENCIA OK: % casos identicos fila a fila entre el cuerpo previo y wrapper + nucleo (purchases, purchase_items, stock_movements, branch_stock, caja, banco, cuenta corriente, evento, idempotencia, rechazos).', array_length(v_labels, 1);
END $$;

ROLLBACK;
