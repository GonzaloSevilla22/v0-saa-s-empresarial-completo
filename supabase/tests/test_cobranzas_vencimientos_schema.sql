-- =============================================================================
-- GATE: test_cobranzas_vencimientos_schema.sql
-- CHANGE: cobranzas-vencimientos (Etapa B del módulo de cobranzas)
--
-- Cubre tasks 2.1/2.3 (schema) y 3.1/3.5-3.8 (helpers de cargo + cascada):
--   (1) Las cinco columnas nuevas existen, con tipo/nulabilidad correctos y
--       SIN default (D2: DEFAULT 0 declararía morosa a toda la deuda nueva).
--   (2) CHECK (>= 0) en los tres niveles de plazo, por nombre de constraint.
--   (3) UNA sola definición de cada función reescrita (gotcha 42725) con el
--       argumento de vencimiento TRAILING.
--   (4) ACLs exactas capturadas en el checkpoint 1.4 (2026-09-02, prod):
--       - _pay_register_party_charge: SIN authenticated y SIN anon (hotfix
--         20261010000001 — recrearla con GRANT reabriría el cross-tenant).
--       - c30_register_*: CON anon+authenticated (estado vivo de prod,
--         candidato h3 pendiente — este gate replica lo VIVO; cuando h3
--         endurezca las ACLs debe actualizar este assert).
--   (5) Cascada (D2/D3): parte gana a cuenta; herencia; sin plazo → NULL sin
--       fallar; plazo 0 → vence hoy.
--   (6) Override (D3): explícito gana; anterior al cargo → P0400 atómico;
--       pasado pero posterior al cargo → aceptado.
--   (7) Simetría formulario/POS (D3/D11): mismo día, mismo plazo → mismo
--       vencimiento por los dos caminos.
--   (8) Lado proveedor: lee el plazo del PROVEEDOR y escribe en
--       supplier_account_movements.
--
-- Degrade-don't-fail: si el anchor sintético no provisiona, NOTICE y return.
-- =============================================================================

-- ═══════════ (1)+(2) SCHEMA — estructural, corre SIEMPRE ════════════════════
DO $$
DECLARE
  v_rec record;
  v_cnt int;
BEGIN
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('accounts',                   'default_payment_terms_days', 'smallint'),
      ('clients',                    'payment_terms_days',         'smallint'),
      ('suppliers',                  'payment_terms_days',         'smallint'),
      ('customer_account_movements', 'due_date',                   'date'),
      ('supplier_account_movements', 'due_date',                   'date')
    ) AS t(tbl, col, typ)
  LOOP
    SELECT COUNT(*) INTO v_cnt
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = v_rec.tbl
      AND column_name = v_rec.col AND data_type = v_rec.typ
      AND is_nullable = 'YES' AND column_default IS NULL;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (1): %.% debe existir como % NULLABLE y SIN default.',
        v_rec.tbl, v_rec.col, v_rec.typ;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (1): las 5 columnas existen, nullable, sin default.';

  -- (2) CHECK (>= 0) por nombre en los tres niveles de plazo
  FOR v_rec IN
    SELECT * FROM (VALUES
      ('accounts',  'accounts_default_payment_terms_days_nonneg'),
      ('clients',   'clients_payment_terms_days_nonneg'),
      ('suppliers', 'suppliers_payment_terms_days_nonneg')
    ) AS t(tbl, con)
  LOOP
    SELECT COUNT(*) INTO v_cnt
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'public' AND r.relname = v_rec.tbl
      AND c.conname = v_rec.con AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) LIKE '%>= 0%';
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (2): falta el CHECK % (>= 0) en public.%.',
        v_rec.con, v_rec.tbl;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (2): CHECK (>= 0) presente en los tres niveles de plazo.';
END $$;

-- ═══════════ (3)+(4) FUNCIONES + ACLs — estructural, corre SIEMPRE ══════════
DO $$
DECLARE
  v_cnt  int;
  v_args text;
BEGIN
  -- (3a) una sola definición de cada función reescrita (42725)
  FOR v_args IN
    SELECT t.fn FROM (VALUES
      ('_pay_register_party_charge'),
      ('c30_register_customer_account_movement'),
      ('c30_register_supplier_account_movement'),
      ('rpc_create_sale_operation'),
      ('rpc_create_sale_operation_v2'),
      ('rpc_create_purchase_operation'),
      ('rpc_receivables_report'),
      ('rpc_payables_report'),
      ('rpc_set_default_payment_terms'),
      ('_produce_receivables_overdue_digest'),
      ('_notification_from_event')
    ) AS t(fn)
  LOOP
    SELECT COUNT(*) INTO v_cnt
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_args;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (3a): % tiene % definiciones (esperaba 1 — gotcha 42725).',
        v_args, v_cnt;
    END IF;
  END LOOP;

  -- (3b) argumento de vencimiento TRAILING donde corresponde
  SELECT pg_get_function_identity_arguments(p.oid) INTO v_args
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = '_pay_register_party_charge';
  IF v_args NOT LIKE '%p_charge_date date, p_due_date date' THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (3b): _pay_register_party_charge debe terminar en (..., p_charge_date date, p_due_date date) — tiene (%).', v_args;
  END IF;

  FOR v_args IN
    SELECT pg_get_function_identity_arguments(p.oid)
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('c30_register_customer_account_movement',
                        'c30_register_supplier_account_movement',
                        'rpc_create_sale_operation',
                        'rpc_create_sale_operation_v2',
                        'rpc_create_purchase_operation')
  LOOP
    IF v_args NOT LIKE '%p_due_date date' THEN
      RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (3b): una función de alta no termina en p_due_date date — tiene (%).', v_args;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (3): una sola definición por función, vencimiento trailing.';

  -- (4a) _pay_register_party_charge SIN authenticated NI anon (hotfix #454)
  IF has_function_privilege('authenticated',
       'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon',
       'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (4a): _pay_register_party_charge quedó ejecutable por authenticated/anon — el DROP+CREATE le devolvió un GRANT que el hotfix 20261010000001 había revocado (escritura cross-tenant reabierta).';
  END IF;

  -- (4b) c30_register_*: ACLs vivas replicadas EXACTO (checkpoint 1.4 —
  --      anon+authenticated+service_role; candidato h3 pendiente, ver cabecera)
  IF NOT (has_function_privilege('authenticated',
            'public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('anon',
            'public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('service_role',
            'public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (4b): c30_register_customer_account_movement no replica las ACLs vivas capturadas en 1.4 (anon+authenticated+service_role). Si esto falla porque h3 endureció las ACLs, actualizar este assert en el mismo PR.';
  END IF;
  IF NOT (has_function_privilege('authenticated',
            'public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('anon',
            'public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')
      AND has_function_privilege('service_role',
            'public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date)'::regprocedure, 'EXECUTE')) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC SCHEMA FAILED (4b): c30_register_supplier_account_movement no replica las ACLs vivas capturadas en 1.4.';
  END IF;
  RAISE NOTICE 'PASS (4): ACLs replicadas — helper de cargo cerrado, c30_* como en prod.';
END $$;

-- ═══════════ (5)-(8) COMPORTAMIENTO — anchor sintético ══════════════════════
DO $$
DECLARE
  v_user_a    uuid := gen_random_uuid();
  v_account_a uuid;
  v_branch_a  uuid;
  v_pm_credit uuid;
  v_client_1  uuid;  -- plazo propio 60 (la parte gana)
  v_client_2  uuid;  -- sin plazo (hereda 30 de la cuenta)
  v_client_3  uuid;  -- sin plazo y cuenta sin default (due NULL)
  v_client_4  uuid;  -- plazo 0 (contado a la vista)
  v_client_5  uuid;  -- plazo 15 (simetría form/POS)
  v_supplier_1 uuid; -- plazo 15 (lado proveedor)
  v_today     date;
  v_due       date;
  v_ca_id     uuid;
  v_cnt       int;
  v_n_sales   int;
  v_n_movs    int;
  v_rejected  boolean;
  v_result    jsonb;
  v_op_id     uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'gate-cobven-a@test.local',
          now(), now(), jsonb_build_object('name', 'Gate CobVen A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members
  WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE COBRANZAS-VENC (setup): tenant no provisionado — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods
  WHERE account_id = v_account_a AND kind = 'credit' LIMIT 1;
  IF v_branch_a IS NULL OR v_pm_credit IS NULL THEN
    RAISE NOTICE 'GATE COBRANZAS-VENC (setup): sin sucursal/forma de pago credit sembradas — degradando.';
    RETURN;
  END IF;

  v_today := public.reporting_local_today();

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE COBRANZAS-VENC: auth.uid() no resuelve al anchor — se omiten los asserts de comportamiento.';
    RETURN;
  END IF;

  -- ── CHECKs negativos (2.3) en los tres niveles ────────────────────────────
  v_rejected := false;
  BEGIN
    UPDATE public.accounts SET default_payment_terms_days = -1 WHERE id = v_account_a;
  EXCEPTION WHEN check_violation THEN v_rejected := true; END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (2.3-accounts): un plazo negativo debe rechazarse por CHECK.';
  END IF;

  UPDATE public.accounts SET default_payment_terms_days = 30 WHERE id = v_account_a;

  INSERT INTO public.clients (user_id, account_id, name, payment_terms_days)
  VALUES (v_user_a, v_account_a, '__gate_cobven_c1__', 60) RETURNING id INTO v_client_1;
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, '__gate_cobven_c2__') RETURNING id INTO v_client_2;
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, '__gate_cobven_c3__') RETURNING id INTO v_client_3;
  INSERT INTO public.clients (user_id, account_id, name, payment_terms_days)
  VALUES (v_user_a, v_account_a, '__gate_cobven_c4__', 0) RETURNING id INTO v_client_4;
  INSERT INTO public.clients (user_id, account_id, name, payment_terms_days)
  VALUES (v_user_a, v_account_a, '__gate_cobven_c5__', 15) RETURNING id INTO v_client_5;
  INSERT INTO public.suppliers (account_id, name, payment_terms_days)
  VALUES (v_account_a, '__gate_cobven_s1__', 15) RETURNING id INTO v_supplier_1;

  v_rejected := false;
  BEGIN
    UPDATE public.clients SET payment_terms_days = -5 WHERE id = v_client_1;
  EXCEPTION WHEN check_violation THEN v_rejected := true; END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (2.3-clients): plazo negativo debe rechazarse.';
  END IF;
  v_rejected := false;
  BEGIN
    UPDATE public.suppliers SET payment_terms_days = -5 WHERE id = v_supplier_1;
  EXCEPTION WHEN check_violation THEN v_rejected := true; END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (2.3-suppliers): plazo negativo debe rechazarse.';
  END IF;
  RAISE NOTICE 'PASS (2.3): plazo negativo rechazado por CHECK en los tres niveles.';

  -- ── (5a) cascada: el plazo de la parte (60) gana al de la cuenta (30) ─────
  PERFORM public._pay_register_party_charge(
    v_account_a, 'customer', v_client_1, 1000, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_client_1 ORDER BY m.created_at DESC LIMIT 1;
  IF v_due IS DISTINCT FROM (v_today + 60) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (5a): esperaba due %, obtuve % — el plazo del cliente (60) debe ganar al de la cuenta (30).', v_today + 60, v_due;
  END IF;

  -- ── (5b) cascada: sin plazo propio hereda el de la cuenta (30) ────────────
  PERFORM public._pay_register_party_charge(
    v_account_a, 'customer', v_client_2, 1000, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_client_2 ORDER BY m.created_at DESC LIMIT 1;
  IF v_due IS DISTINCT FROM (v_today + 30) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (5b): esperaba due %, obtuve % — sin plazo propio hereda el default de la cuenta.', v_today + 30, v_due;
  END IF;

  -- ── (5d) plazo 0 = contado a la vista: vence HOY ──────────────────────────
  PERFORM public._pay_register_party_charge(
    v_account_a, 'customer', v_client_4, 1000, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_client_4 ORDER BY m.created_at DESC LIMIT 1;
  IF v_due IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (5d): plazo 0 debe vencer HOY (%), obtuve %.', v_today, v_due;
  END IF;

  -- ── (5c) sin plazo en ningún nivel: due NULL, SIN fallar ─────────────────
  UPDATE public.accounts SET default_payment_terms_days = NULL WHERE id = v_account_a;
  PERFORM public._pay_register_party_charge(
    v_account_a, 'customer', v_client_3, 1000, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date, m.id INTO v_due, v_ca_id
  FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_client_3 ORDER BY m.created_at DESC LIMIT 1;
  IF v_ca_id IS NULL OR v_due IS NOT NULL THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (5c): sin plazo en ningún nivel el cargo debe postearse con due NULL (movimiento=%, due=%).', v_ca_id, v_due;
  END IF;
  UPDATE public.accounts SET default_payment_terms_days = 30 WHERE id = v_account_a;
  RAISE NOTICE 'PASS (5): cascada — parte gana, herencia, NULL sin fallar, plazo 0 vence hoy.';

  -- ── (6a) override explícito gana a la cascada (vía la RPC del formulario) ─
  v_result := public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-cobven-6a',
    p_client_id         => v_client_1,
    p_date              => v_today,
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('amount', 500, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit,
    p_due_date          => v_today + 7
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m WHERE m.reference_id = v_op_id;
  IF v_due IS DISTINCT FROM (v_today + 7) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (6a): el override explícito (hoy+7) debe ganar al plazo del cliente (60) — obtuve %.', v_due;
  END IF;

  -- ── (6b) override anterior a la fecha del cargo → P0400 atómico ───────────
  SELECT COUNT(*) INTO v_n_sales FROM public.sales WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_movs FROM public.customer_account_movements WHERE account_id = v_account_a;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-cobven-6b',
      p_client_id         => v_client_1,
      p_date              => v_today,
      p_currency          => 'ARS',
      p_items             => jsonb_build_array(jsonb_build_object('amount', 500, 'quantity', 1)),
      p_branch_id         => v_branch_a,
      p_payment_method_id => v_pm_credit,
      p_due_date          => v_today - 1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0400' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (6b): un vencimiento anterior a la fecha del cargo debe abortar con P0400.';
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.sales WHERE account_id = v_account_a;
  IF v_cnt <> v_n_sales THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (6b-atomicidad): el rechazo dejó una venta persistida.';
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.customer_account_movements WHERE account_id = v_account_a;
  IF v_cnt <> v_n_movs THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (6b-atomicidad): el rechazo dejó un movimiento de cuenta corriente.';
  END IF;

  -- ── (6c) vencimiento ya cumplido pero POSTERIOR al cargo → aceptado ───────
  v_result := public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-cobven-6c',
    p_client_id         => v_client_1,
    p_date              => v_today - 10,
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('amount', 500, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit,
    p_due_date          => v_today - 3
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m WHERE m.reference_id = v_op_id;
  IF v_due IS DISTINCT FROM (v_today - 3) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (6c): venta fechada hace 10 días con vencimiento hace 3 debe aceptarse (obtuve %).', v_due;
  END IF;
  RAISE NOTICE 'PASS (6): override gana; anterior al cargo P0400 atómico; pasado posterior al cargo aceptado.';

  -- ── (7) SIMETRÍA formulario/POS: mismo plazo, mismo día → mismo due ───────
  -- El camino del formulario (v2, sin override) y el del POS
  -- (_c29_confirm_order_core llama al helper con la firma corta — acá se
  -- invoca EXACTAMENTE esa forma) tienen que producir el mismo vencimiento.
  v_result := public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-cobven-7-form',
    p_client_id         => v_client_5,
    p_date              => v_today,
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('amount', 700, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  );
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m WHERE m.reference_id = v_op_id;
  IF v_due IS DISTINCT FROM (v_today + 15) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (7-form): el formulario sin override debe resolver la cascada (hoy+15), obtuve %.', v_due;
  END IF;

  PERFORM public._pay_register_party_charge(
    v_account_a, 'customer', v_client_5, 700, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date INTO v_due
  FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_client_5 ORDER BY m.created_at DESC, m.id DESC LIMIT 1;
  IF v_due IS DISTINCT FROM (v_today + 15) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (7-pos): la invocación corta del helper (la del POS) debe resolver la MISMA cascada (hoy+15), obtuve %.', v_due;
  END IF;
  RAISE NOTICE 'PASS (7): simetría formulario/POS — mismo vencimiento por los dos caminos.';

  -- ── (8) lado proveedor: lee el plazo del PROVEEDOR (15), no el del cliente ─
  PERFORM public._pay_register_party_charge(
    v_account_a, 'supplier', v_supplier_1, 800, gen_random_uuid(), gen_random_uuid());
  SELECT m.due_date INTO v_due
  FROM public.supplier_account_movements m
  JOIN public.supplier_accounts sa ON sa.id = m.supplier_account_id
  WHERE sa.supplier_id = v_supplier_1 ORDER BY m.created_at DESC LIMIT 1;
  IF v_due IS DISTINCT FROM (v_today + 15) THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (8): el cargo de compra debe leer el plazo del proveedor (hoy+15), obtuve %.', v_due;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM public.customer_account_movements m
  JOIN public.customer_accounts ca ON ca.id = m.customer_account_id
  WHERE ca.client_id = v_supplier_1;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'GATE COBRANZAS-VENC FAILED (8): el cargo supplier no debe tocar el ledger de clientes.';
  END IF;
  RAISE NOTICE 'PASS (8): lado proveedor con su propio plazo, en su propio ledger.';

  RAISE NOTICE '=== GATE COBRANZAS-VENCIMIENTOS (schema+cascada): TODO OK ===';
END $$;


-- ── Cleanup (molde test_party_payment_cash — deja la DB como estaba) ─────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('gate-cobven-a@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.operation_idempotency
      WHERE event_id IN (SELECT id FROM public.events WHERE account_id = ANY(v_accounts));
    DELETE FROM public.notifications WHERE account_id = ANY(v_accounts);
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchase_items WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases WHERE account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_received WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made     WHERE account_id = ANY(v_accounts);
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
    DELETE FROM public.events  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts);
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
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users) OR recipient IN ('gate-cobven-a@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE COBRANZAS-VENC: cleanup completo.';
END $$;
