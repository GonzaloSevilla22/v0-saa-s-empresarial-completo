-- =============================================================================
-- GATE: test_receivables_report.sql
-- CHANGE: cobranzas-panel (tasks 2.1 / 2.4 / 2.5)
--
-- Verifica rpc_receivables_report:
--   (introspección) existe, SECURITY DEFINER, search_path fijado, ACLs exactas
--   (anon sin EXECUTE, authenticated con EXECUTE, PUBLIC revocado).
--   (comportamiento) deudor con saldo positivo aparece con nombre y saldo;
--   saldo cero no aparece; cliente borrado no aparece; deudor de otro tenant
--   no aparece; no miembro recibe P0401; deuda nacida sólo de adjustment
--   aparece con antigüedad de cargo nula (D5/OQ-4); payment_received_reversal
--   no rejuvenece la antigüedad de cobro y credit_note no cuenta como cargo
--   (D4); los días se computan en día calendario argentino vía
--   reporting_local_today() (cargo de las 22:00 ART de ayer = 1 día, no 0).
-- Mismo patrón de anchor sintético + set_config('request.jwt.claims', ...)
-- que supabase/tests/test_payment_method_report.sql.
-- =============================================================================

-- ── 1. Introspección: existencia, SECURITY DEFINER, search_path, ACLs ────────
DO $$
DECLARE
  v_oid    oid;
  v_secdef boolean;
  v_config text[];
  v_acl    aclitem[];
BEGIN
  SELECT p.oid, p.prosecdef, p.proconfig, p.proacl
    INTO v_oid, v_secdef, v_config, v_acl
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_receivables_report';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (existencia): public.rpc_receivables_report no existe.';
  END IF;

  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (secdef): rpc_receivables_report debe ser SECURITY DEFINER.';
  END IF;

  IF v_config IS NULL OR NOT EXISTS (
    SELECT 1 FROM unnest(v_config) AS cfg WHERE cfg LIKE 'search_path=%'
  ) THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (search_path): rpc_receivables_report no fija search_path.';
  END IF;

  -- proacl NULL = ACL por defecto = PUBLIC conserva EXECUTE.
  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (acl): proacl es NULL — falta el REVOKE ALL FROM PUBLIC en la migración.';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_receivables_report(uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (acl): anon NO debe poder ejecutar rpc_receivables_report.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.rpc_receivables_report(uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (acl): authenticated debe poder ejecutar rpc_receivables_report.';
  END IF;

  RAISE NOTICE 'PASS (introspección): SECURITY DEFINER + search_path + ACLs exactas.';
END $$;

-- ── 2. Comportamiento con anchor sintético ───────────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'receivables-report-gate@test.local';
  v_intruder_email text := 'receivables-report-gate-intruder@test.local';
  v_user_id     uuid := gen_random_uuid();
  v_intruder_id uuid := gen_random_uuid();
  v_account_id          uuid;
  v_intruder_account_id uuid;
  v_client_a uuid;  -- deudor grande, historia completa de movimientos
  v_client_b uuid;  -- al día (saldo 0)
  v_client_c uuid;  -- borrado con deuda
  v_client_d uuid;  -- deuda nacida sólo de adjustment
  v_client_e uuid;  -- cargo nocturno (22:00 ART de ayer)
  v_client_x uuid;  -- deudor de otro tenant
  v_ca_a uuid; v_ca_b uuid; v_ca_c uuid; v_ca_d uuid; v_ca_e uuid; v_ca_x uuid;
  v_row   record;
  v_count int;
  v_unauthorized boolean := false;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Receivables'))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_intruder_id, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
          jsonb_build_object('name', 'Gate Receivables Intruder'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id          FROM public.account_members WHERE user_id = v_user_id     ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_intruder_account_id FROM public.account_members WHERE user_id = v_intruder_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL OR v_intruder_account_id IS NULL THEN
    RAISE NOTICE 'GATE RECEIVABLES-REPORT: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Fixture: clientes ──────────────────────────────────────────────────────
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account_id, v_user_id, '__gate_rcv_deudor_a__')  RETURNING id INTO v_client_a;
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account_id, v_user_id, '__gate_rcv_al_dia__')    RETURNING id INTO v_client_b;
  INSERT INTO public.clients (account_id, user_id, name, deleted_at) VALUES (v_account_id, v_user_id, '__gate_rcv_borrado__', now()) RETURNING id INTO v_client_c;
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account_id, v_user_id, '__gate_rcv_ajuste__')    RETURNING id INTO v_client_d;
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account_id, v_user_id, '__gate_rcv_nocturno__')  RETURNING id INTO v_client_e;
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_intruder_account_id, v_intruder_id, '__gate_rcv_ajeno__') RETURNING id INTO v_client_x;

  -- ── Fixture: cuentas corrientes ───────────────────────────────────────────
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_a, 12000, v_user_id) RETURNING id INTO v_ca_a;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_b, 0, v_user_id)     RETURNING id INTO v_ca_b;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_c, 5000, v_user_id)  RETURNING id INTO v_ca_c;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_d, 3000, v_user_id)  RETURNING id INTO v_ca_d;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_e, 1000, v_user_id)  RETURNING id INTO v_ca_e;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_intruder_account_id, v_client_x, 7000, v_intruder_id) RETURNING id INTO v_ca_x;

  -- ── Fixture: movimientos ──────────────────────────────────────────────────
  -- Cliente A: última venta hace 12 días; credit_note HOY (no debe contar como
  -- cargo, D4); último cobro hace 30 días; reversa HOY (no debe rejuvenecer, D4).
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by, created_at)
  VALUES
    (v_ca_a, v_account_id, 20000, 20000, 'sale',                      v_user_id, now() - interval '12 days'),
    (v_ca_a, v_account_id, -6000, 14000, 'payment_received',          v_user_id, now() - interval '30 days'),
    (v_ca_a, v_account_id, -2000, 12000, 'credit_note',               v_user_id, now()),
    (v_ca_a, v_account_id,  6000, 12000, 'payment_received_reversal', v_user_id, now());

  -- Cliente D: deuda nacida sólo de un adjustment (OQ-4) → antigüedades nulas.
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by, created_at)
  VALUES (v_ca_d, v_account_id, 3000, 3000, 'adjustment', v_user_id, now() - interval '5 days');

  -- Cliente E: cargo a las 22:00 ART de AYER (01:00 UTC de hoy) → 1 día, no 0.
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by, created_at)
  VALUES (v_ca_e, v_account_id, 1000, 1000, 'sale', v_user_id,
          ((public.reporting_local_today() - 1)::timestamp + interval '22 hours') AT TIME ZONE 'America/Argentina/Mendoza');

  -- ── Assert de autorización: intruso no miembro → P0401 ────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_intruder_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_intruder_id THEN
    RAISE NOTICE 'GATE RECEIVABLES-REPORT: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan el RPC.';
  ELSE
    BEGIN
      PERFORM * FROM public.rpc_receivables_report(v_account_id);
    EXCEPTION
      WHEN sqlstate 'P0401' THEN
        v_unauthorized := true;
    END;

    IF NOT v_unauthorized THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (auth): un caller no miembro debería ser rechazado con P0401.';
    END IF;
    RAISE NOTICE 'PASS (auth): caller no miembro rechazado con P0401.';

    -- ── Sesión del anchor real ──────────────────────────────────────────────
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

    -- (1) Exactamente 3 deudores: A (12000), D (3000), E (1000).
    --     Ni el saldo 0 (B), ni el borrado (C), ni el ajeno (X).
    SELECT COUNT(*) INTO v_count FROM public.rpc_receivables_report(v_account_id);
    IF v_count <> 3 THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (1): esperaba 3 deudores (saldo>0, no borrados, del tenant), dio %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (1): saldo 0, cliente borrado y deudor ajeno quedan fuera.';

    -- (2) Orden por saldo DESC: la primera fila es A con 12000 y su nombre.
    SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_id) LIMIT 1;
    IF v_row.client_id <> v_client_a OR v_row.balance <> 12000 OR v_row.client_name <> '__gate_rcv_deudor_a__' THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (2): la primera fila debía ser el deudor A (12000, orden balance DESC).';
    END IF;
    RAISE NOTICE 'PASS (2): deudor con saldo positivo aparece con nombre y saldo, ordenado por saldo DESC.';

    -- (3) D4: credit_note de hoy no cuenta como cargo (la venta de hace 12 días
    --     manda) y la reversa de hoy no rejuvenece el cobro de hace 30 días.
    SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_id) r WHERE r.client_id = v_client_a;
    IF v_row.days_since_last_charge <> 12 THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (3a): esperaba 12 días desde el último cargo (credit_note no cuenta), dio %.', v_row.days_since_last_charge;
    END IF;
    IF v_row.days_since_last_payment <> 30 THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (3b): esperaba 30 días desde el último cobro (la reversa no rejuvenece), dio %.', v_row.days_since_last_payment;
    END IF;
    IF v_row.last_payment_date <> ((now() - interval '30 days') AT TIME ZONE 'America/Argentina/Mendoza')::date THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (3c): last_payment_date debía ser la fecha ART del cobro original.';
    END IF;
    RAISE NOTICE 'PASS (3): credit_note no es cargo y payment_received_reversal no rejuvenece el cobro (D4).';

    -- (4) OQ-4: deuda nacida sólo de adjustment aparece con antigüedades nulas.
    SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_id) r WHERE r.client_id = v_client_d;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (4): la deuda nacida de adjustment debe aparecer (OQ-4).';
    END IF;
    IF v_row.days_since_last_charge IS NOT NULL OR v_row.days_since_last_payment IS NOT NULL OR v_row.last_payment_date IS NOT NULL THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (4b): sin sale ni payment_received las antigüedades deben ser NULL (adjustment no cuenta como cargo).';
    END IF;
    RAISE NOTICE 'PASS (4): adjustment aparece con antigüedad nula, sin contar como cargo.';

    -- (5) Día calendario argentino: cargo de las 22:00 ART de ayer = 1 día.
    SELECT * INTO v_row FROM public.rpc_receivables_report(v_account_id) r WHERE r.client_id = v_client_e;
    IF v_row.days_since_last_charge <> 1 THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (5): el cargo de las 22:00 ART de ayer debía computar 1 día (calendario argentino, no UTC), dio %.', v_row.days_since_last_charge;
    END IF;
    RAISE NOTICE 'PASS (5): los días se computan en día calendario argentino (reporting_local_today).';

    -- (6) El deudor del intruso sólo es visible desde su propia cuenta.
    SELECT COUNT(*) INTO v_count FROM public.rpc_receivables_report(v_account_id) r WHERE r.client_id = v_client_x;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE RECEIVABLES-REPORT FAILED (6): un deudor de otro tenant no debe aparecer.';
    END IF;

    RAISE NOTICE 'GATE RECEIVABLES-REPORT PASSED.';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre ─────────────────────────────────────────────────────
  DELETE FROM public.customer_account_movements WHERE account_id IN (v_account_id, v_intruder_account_id);
  DELETE FROM public.customer_accounts          WHERE account_id IN (v_account_id, v_intruder_account_id);
  DELETE FROM public.clients                    WHERE account_id IN (v_account_id, v_intruder_account_id);
  DELETE FROM public.payment_methods            WHERE account_id IN (v_account_id, v_intruder_account_id);
  DELETE FROM public.branch_stock  WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id));
  DELETE FROM public.cashboxes     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id));
  -- sucursal-guard-vaciado-auditoria: branches prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches      WHERE account_id IN (v_account_id, v_intruder_account_id);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts      WHERE owner_user_id IN (v_user_id, v_intruder_id);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles      WHERE id IN (v_user_id, v_intruder_id);
  DELETE FROM public.email_logs    WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM auth.users           WHERE id IN (v_user_id, v_intruder_id);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.customer_account_movements WHERE account_id IN (v_account_id, v_intruder_account_id);
        DELETE FROM public.customer_accounts          WHERE account_id IN (v_account_id, v_intruder_account_id);
        DELETE FROM public.clients                    WHERE account_id IN (v_account_id, v_intruder_account_id);
        DELETE FROM public.payment_methods            WHERE account_id IN (v_account_id, v_intruder_account_id);
        DELETE FROM public.branch_stock  WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id));
        DELETE FROM public.cashboxes     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id));
        -- sucursal-guard-vaciado-auditoria: bypass explicito del trigger P0428 para el cleanup del fixture sintetico (solo superusuario postgres en CI).
        SET session_replication_role = replica;
        DELETE FROM public.branches      WHERE account_id IN (v_account_id, v_intruder_account_id);
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
        -- sucursal-guard-vaciado-auditoria: bypass explicito del trigger P0428 para el cleanup del fixture sintetico (solo superusuario postgres en CI).
        SET session_replication_role = replica;
        DELETE FROM public.accounts      WHERE owner_user_id IN (v_user_id, v_intruder_id);
        SET session_replication_role = DEFAULT;
      END IF;
      DELETE FROM public.profiles      WHERE id IN (v_user_id, v_intruder_id);
      DELETE FROM public.email_logs    WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM auth.users           WHERE id IN (v_user_id, v_intruder_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
