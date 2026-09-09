-- =============================================================================
-- GATE: test_charge_due_date.sql
-- CHANGE: charge-due-date-update (cobranzas-vencimientos OQ-1)
--
-- Cubre:
--   (1) introspección + ACLs de las dos RPCs (SECURITY DEFINER, search_path,
--       anon sin EXECUTE, authenticated con EXECUTE).
--   (2) cambiar el vencimiento de un cargo abierto reordena el FIFO — el
--       aging de rpc_receivables_report cambia de tramo (31-60 -> current).
--   (3) cargo de OTRA cuenta -> P0404 (nunca revela existencia cross-tenant).
--   (4) cargo YA SALDADO (open_amount = 0) -> P0400.
--   (5) un movimiento que NO es cargo (payment_received) -> P0400.
--   (6) audit_logs tiene la fila con due_date_before/after + reason.
--   (7) p_due_date NULL limpia el vencimiento.
--   (8) no-writer (member) -> P0401.
--   (9) espejo proveedor: update exitoso + P0404 cross-tenant.
--
-- Molde: supabase/tests/test_receivables_aging_fifo.sql (helpers pg_temp +
-- set_config('request.jwt.claims', ...) + cleanup).
-- =============================================================================

-- ═══════════ (1) INTROSPECCIÓN + ACLs — corre SIEMPRE ═══════════════════════
DO $$
DECLARE
  v_def text;
  v_fn  text;
BEGIN
  FOR v_fn IN SELECT unnest(ARRAY[
    'rpc_update_customer_charge_due_date', 'rpc_update_supplier_charge_due_date'
  ]) LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_def IS NULL THEN
      RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (setup): % no existe.', v_fn;
    END IF;
    IF position('SECURITY DEFINER' in v_def) = 0 THEN
      RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED: % debe ser SECURITY DEFINER.', v_fn;
    END IF;
    IF position('is_account_writer' in v_def) = 0 THEN
      RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED: % no usa el guard is_account_writer (owner/admin).', v_fn;
    END IF;
  END LOOP;

  IF has_function_privilege('anon', 'public.rpc_update_customer_charge_due_date(uuid,date,text)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_update_supplier_charge_due_date(uuid,date,text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (acl): anon no debe poder ejecutar estas RPCs.';
  END IF;
  IF NOT (has_function_privilege('authenticated', 'public.rpc_update_customer_charge_due_date(uuid,date,text)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.rpc_update_supplier_charge_due_date(uuid,date,text)'::regprocedure, 'EXECUTE')) THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (acl): authenticated debe poder ejecutar las dos RPCs.';
  END IF;
  RAISE NOTICE 'PASS (1): introspección — SECURITY DEFINER, guard is_account_writer, ACLs exactas.';
END $$;

-- ═══════════ (2)-(9) COMPORTAMIENTO — anchor sintético ══════════════════════
CREATE FUNCTION pg_temp.ins_cam(p_ca uuid, p_acc uuid, p_amount numeric, p_type text,
                                p_due date, p_created timestamptz, p_by uuid) RETURNS uuid AS $ins$
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type,
     reference_id, due_date, created_by, created_at)
  VALUES (p_ca, p_acc, p_amount, 0, p_type, gen_random_uuid(), p_due, p_by, p_created)
  RETURNING id;
$ins$ LANGUAGE sql;

CREATE FUNCTION pg_temp.ins_sam(p_sa uuid, p_acc uuid, p_amount numeric, p_type text,
                                p_due date, p_created timestamptz, p_by uuid) RETURNS uuid AS $ins$
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type,
     reference_id, due_date, created_by, created_at)
  VALUES (p_sa, p_acc, p_amount, 0, p_type, gen_random_uuid(), p_due, p_by, p_created)
  RETURNING id;
$ins$ LANGUAGE sql;

CREATE FUNCTION pg_temp.mk_client(p_uid uuid, p_acc uuid, p_name text) RETURNS uuid AS $mk$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (p_uid, p_acc, p_name) RETURNING id INTO v_id;
  INSERT INTO public.customer_accounts (account_id, client_id, balance)
  VALUES (p_acc, v_id, 0);
  RETURN v_id;
END;
$mk$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.ca_of(p_client uuid) RETURNS uuid AS $ca$
  SELECT id FROM public.customer_accounts WHERE client_id = p_client;
$ca$ LANGUAGE sql;

DO $$
DECLARE
  v_user_f      uuid := gen_random_uuid();
  v_user_member uuid := gen_random_uuid();
  v_user_g      uuid := gen_random_uuid();
  v_account_f   uuid;
  v_account_g   uuid;
  v_today       date;
  v_cl_a uuid; v_cl_b uuid; v_cl_d uuid;
  v_sup_a uuid; v_sup_acc_a uuid;
  v_charge1 uuid; v_charge2 uuid; v_charge_b uuid; v_payment_b uuid; v_charge_d uuid;
  v_supplier_charge uuid;
  v_row   record;
  v_result jsonb;
  v_due    date;
  v_audit_cnt int;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_user_f,      'authenticated', 'authenticated', 'gate-duedate-f@test.local',
     now(), now(), jsonb_build_object('name', 'Gate DueDate F')),
    (v_user_member, 'authenticated', 'authenticated', 'gate-duedate-member@test.local',
     now(), now(), jsonb_build_object('name', 'Gate DueDate Member')),
    (v_user_g,      'authenticated', 'authenticated', 'gate-duedate-g@test.local',
     now(), now(), jsonb_build_object('name', 'Gate DueDate G'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_f FROM public.account_members
  WHERE user_id = v_user_f ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_g FROM public.account_members
  WHERE user_id = v_user_g ORDER BY created_at LIMIT 1;

  IF v_account_f IS NULL OR v_account_g IS NULL OR v_account_f = v_account_g THEN
    RAISE NOTICE 'GATE CHARGE-DUE-DATE (setup): no se pudieron provisionar 2 tenants independientes — degradando.';
    RETURN;
  END IF;

  -- v_user_member: miembro de F SIN rol de escritura. Hay que retirarle su
  -- propia cuenta auto-provisionada (donde es owner) — is_account_writer se
  -- resuelve vía current_account_ids() -> LIMIT 1, así que si conserva su
  -- cuenta propia el guard pasaría sobre ESA cuenta y el assert mediría otra cosa.
  DELETE FROM public.account_members WHERE user_id = v_user_member;
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_f, v_user_member, 'member');

  v_today := public.reporting_local_today();

  -- ── Cliente A (account_f): dos cargos abiertos, sin cobros ────────────────
  v_cl_a := pg_temp.mk_client(v_user_f, v_account_f, '__duedate_a__');
  v_charge1 := pg_temp.ins_cam(pg_temp.ca_of(v_cl_a), v_account_f, 1000, 'sale', v_today - 40, now() - interval '40 days', v_user_f);
  v_charge2 := pg_temp.ins_cam(pg_temp.ca_of(v_cl_a), v_account_f,  500, 'sale', v_today - 10, now() - interval '10 days', v_user_f);
  UPDATE public.customer_accounts SET balance = 1500 WHERE id = pg_temp.ca_of(v_cl_a);

  -- ── Cliente B (account_f): un cargo saldado + su cobro (no-cargo) ─────────
  v_cl_b := pg_temp.mk_client(v_user_f, v_account_f, '__duedate_b__');
  v_charge_b := pg_temp.ins_cam(pg_temp.ca_of(v_cl_b), v_account_f, 300, 'sale',             v_today - 5, now() - interval '5 days', v_user_f);
  v_payment_b := pg_temp.ins_cam(pg_temp.ca_of(v_cl_b), v_account_f, -300, 'payment_received', NULL,       now() - interval '1 day', v_user_f);
  UPDATE public.customer_accounts SET balance = 0 WHERE id = pg_temp.ca_of(v_cl_b);

  -- ── Cliente D (account_g, OTRO tenant): un cargo abierto ──────────────────
  v_cl_d := pg_temp.mk_client(v_user_g, v_account_g, '__duedate_d__');
  v_charge_d := pg_temp.ins_cam(pg_temp.ca_of(v_cl_d), v_account_g, 100, 'sale', v_today - 1, now() - interval '1 day', v_user_g);
  UPDATE public.customer_accounts SET balance = 100 WHERE id = pg_temp.ca_of(v_cl_d);

  -- ── Proveedor (account_f): un cargo abierto ────────────────────────────────
  INSERT INTO public.suppliers (account_id, name) VALUES (v_account_f, '__duedate_sup__')
  RETURNING id INTO v_sup_a;
  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance)
  VALUES (v_account_f, v_sup_a, 800) RETURNING id INTO v_sup_acc_a;
  v_supplier_charge := pg_temp.ins_sam(v_sup_acc_a, v_account_f, 800, 'purchase', v_today - 20, now() - interval '20 days', v_user_f);

  -- ── Sesión sintética del owner F ───────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_f::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_f THEN
    RAISE NOTICE 'GATE CHARGE-DUE-DATE: auth.uid() no resuelve — se omiten los asserts de comportamiento.';
    RETURN;
  END IF;

  -- ── (2) Antes del cambio: charge1 (40 días) cae en 31-60, charge2 (10) en 1-30 ──
  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_a;
  IF v_row.amount_overdue_31_60 <> 1000 OR v_row.amount_overdue_1_30 <> 500 OR v_row.amount_current <> 0 THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (2-antes): esperaba 31-60=1000 y 1-30=500 antes del cambio; obtuve %/%/%.',
      v_row.amount_overdue_31_60, v_row.amount_overdue_1_30, v_row.amount_current;
  END IF;

  -- Cambiar el vencimiento de charge1 a FUTURO (hoy + 10) — reordena el FIFO:
  -- charge2 (vence hoy-10) pasa a ser el más viejo y sigue abierto en 1-30;
  -- charge1 (ahora vence hoy+10) queda abierto y AL DÍA.
  v_result := public.rpc_update_customer_charge_due_date(v_charge1, v_today + 10, 'corrección de vencimiento — gate');

  IF (v_result->>'movement_id')::uuid <> v_charge1
     OR (v_result->>'due_date')::date <> (v_today + 10)
     OR (v_result->>'previous_due_date')::date <> (v_today - 40) THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (2-respuesta): jsonb inesperado: %', v_result;
  END IF;

  SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_f) r WHERE r.client_id = v_cl_a;
  IF v_row.amount_overdue_31_60 <> 0 OR v_row.amount_current <> 1000 OR v_row.amount_overdue_1_30 <> 500 THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (2-después): el cambio de vencimiento debía mover 1000 de 31-60 a current; obtuve 31-60=% current=% 1-30=%.',
      v_row.amount_overdue_31_60, v_row.amount_current, v_row.amount_overdue_1_30;
  END IF;
  RAISE NOTICE 'PASS (2): cambiar el vencimiento de un cargo abierto reordena el FIFO — el aging cambió de tramo.';

  -- ── (6) audit_logs con before/after + reason ───────────────────────────────
  SELECT count(*) INTO v_audit_cnt
  FROM public.audit_logs
  WHERE entity_type = 'customer_account_movement'
    AND entity_id = v_charge1
    AND action = 'customer_charge.due_date_changed'
    AND (metadata->>'due_date_before')::date = (v_today - 40)
    AND (metadata->>'due_date_after')::date  = (v_today + 10)
    AND metadata->>'reason' = 'corrección de vencimiento — gate';
  IF v_audit_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (6): audit_logs no tiene la fila esperada con before/after/reason (encontradas: %).', v_audit_cnt;
  END IF;
  RAISE NOTICE 'PASS (6): audit_logs registra due_date_before/after + reason.';

  -- ── (7) NULL limpia el vencimiento ─────────────────────────────────────────
  PERFORM public.rpc_update_customer_charge_due_date(v_charge2, NULL, NULL);
  SELECT due_date INTO v_due FROM public.customer_account_movements WHERE id = v_charge2;
  IF v_due IS NOT NULL THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (7): p_due_date NULL debía limpiar el vencimiento, quedó %.', v_due;
  END IF;
  RAISE NOTICE 'PASS (7): p_due_date NULL limpia el vencimiento (sin vencimiento != error).';

  -- ── (4) cargo ya saldado -> P0400 ───────────────────────────────────────────
  BEGIN
    PERFORM public.rpc_update_customer_charge_due_date(v_charge_b, v_today + 1, NULL);
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (4): un cargo saldado (open_amount=0) debía rechazarse con P0400.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS (4): cargo totalmente saldado -> P0400.';

  -- ── (5) movimiento que NO es cargo (payment_received) -> P0400 ─────────────
  BEGIN
    PERFORM public.rpc_update_customer_charge_due_date(v_payment_b, v_today + 1, NULL);
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (5): un pago (no-cargo) debía rechazarse con P0400.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0400' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS (5): movimiento no-cargo (payment_received) -> P0400.';

  -- ── (3) cargo de OTRA cuenta -> P0404 ────────────────────────────────────────
  BEGIN
    PERFORM public.rpc_update_customer_charge_due_date(v_charge_d, v_today + 1, NULL);
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (3): un cargo de otro tenant debía rechazarse con P0404.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS (3): cargo de otra cuenta -> P0404 (tenencia).';

  -- ── (9) espejo proveedor: update exitoso + P0404 cross-tenant ───────────────
  v_result := public.rpc_update_supplier_charge_due_date(v_supplier_charge, v_today + 5, 'ajuste proveedor');
  IF (v_result->>'due_date')::date <> (v_today + 5) OR (v_result->>'previous_due_date')::date <> (v_today - 20) THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (9): rpc_update_supplier_charge_due_date no actualizó como se esperaba: %', v_result;
  END IF;
  SELECT count(*) INTO v_audit_cnt
  FROM public.audit_logs
  WHERE entity_type = 'supplier_account_movement' AND entity_id = v_supplier_charge
    AND action = 'supplier_charge.due_date_changed';
  IF v_audit_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (9): audit_logs no registró el cambio del proveedor.';
  END IF;
  BEGIN
    -- Un cargo de proveedor de otro tenant no existe desde account_f -> P0404.
    PERFORM public.rpc_update_supplier_charge_due_date(gen_random_uuid(), v_today + 1, NULL);
    RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (9): un movement_id inexistente debía rechazarse con P0404.';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0404' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS (9): espejo proveedor — update exitoso + auditoría + P0404.';

  -- ── (8) no-writer (member) -> P0401 ──────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_member::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_member THEN
    RAISE NOTICE 'GATE CHARGE-DUE-DATE: auth.uid() no resolvió para el member — se omite (8).';
  ELSE
    BEGIN
      PERFORM public.rpc_update_customer_charge_due_date(v_charge1, v_today + 20, NULL);
      RAISE EXCEPTION 'GATE CHARGE-DUE-DATE FAILED (8): un member (no owner/admin) pudo cambiar el vencimiento.';
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE <> 'P0401' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'PASS (8): member sin rol de escritura -> P0401.';
  END IF;

  RAISE NOTICE '=== GATE CHARGE-DUE-DATE: TODO OK ===';
END $$;


-- ── Cleanup (molde test_receivables_aging_fifo.sql) ─────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN (
    'gate-duedate-f@test.local', 'gate-duedate-member@test.local', 'gate-duedate-g@test.local'
  );

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  -- v_user_member fue retirado de su propia cuenta auto-provisionada (L130) —
  -- esa cuenta ya no tiene ningún account_members apuntando a v_users, así
  -- que resolver v_accounts SOLO por account_members la deja afuera de la
  -- limpieza (sus payment_methods/product_categories/branch quedarían
  -- huérfanos). Se suma por owner_user_id para cubrir las 3 cuentas reales.
  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM (
    SELECT account_id FROM public.account_members WHERE user_id = ANY(v_users)
    UNION
    SELECT id AS account_id FROM public.accounts WHERE owner_user_id = ANY(v_users)
  ) x;

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.audit_logs WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements cam USING public.customer_accounts ca
      WHERE cam.customer_account_id = ca.id AND ca.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements sam USING public.supplier_accounts sa
      WHERE sam.supplier_account_id = sa.id AND sa.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements WHERE bank_account_id IN (SELECT id FROM public.bank_accounts WHERE account_id = ANY(v_accounts));
    DELETE FROM public.bank_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts);
    DELETE FROM public.product_categories WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users)
    OR recipient IN ('gate-duedate-f@test.local', 'gate-duedate-member@test.local', 'gate-duedate-g@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CHARGE-DUE-DATE: cleanup completo.';
END $$;
