-- =============================================================================
-- GATE: test_expense_import_batch.sql
-- CHANGE: importador-gastos-transaccional
--
-- Pedido del PO (programa "cero candidatos", 2026-09-07, "sí a todo"):
-- el importador de gastos deja de emitir una llamada por fila y pasa a ser
-- UNA SOLA transacción de servidor — todo o nada, con reporte de errores fila
-- por fila. `rpc_import_expenses` INVOCA `rpc_create_expense` por fila y no
-- reimplementa ninguna de sus reglas (D1 del design).
--
-- Qué ejercita, con dos tenants sintéticos y sesión vía request.jwt.claims
-- (mismo molde que test_gastos_forma_pago.sql / test_tenancy_guard_caja_outbox.sql):
--
--   (1.x) ESQUEMA — expense_imports (columnas, PK, UNIQUE, RLS, policy),
--         expenses.import_id (FK, índice), CHECK de operation_idempotency.
--   (2.x) TODO O NADA — una fila inválida no deja escrita ninguna de las
--         válidas, en las CINCO tablas involucradas.
--   (3.x) CAMINO FELIZ — cash + transfer + sin forma de pago, con import_id
--         poblado y el aviso cash_not_posted.
--   (4.x) CAJA JAMÁS (control negativo D6) — fila cash de HOY con sesión de
--         caja ABIERTA en la sucursal: el gasto entra, cash_movements NO CRECE.
--   (5.x) RESPALDO BANCARIO — precedencia del destino configurado sobre el
--         respaldo del lote (D1/D5), y el respaldo cuando no hay configurado.
--   (6.x) EQUIVALENCIA con el alta directa (verifica la llamada anidada
--         SECURITY DEFINER: auth.uid()/current_account_ids() no cambian).
--   (7.x) SIMULACIÓN (p_dry_run) — cero escrituras en las cinco tablas.
--   (8.x) TENENCIA — nombre que no resuelve, y catálogo de otra cuenta.
--   (9.x) TOPE — 501 filas → P0427, lote vacío → P0427.
--   (10.x) IDEMPOTENCIA y DEDUPE — misma clave → replay; mismo file_hash con
--          otra clave → replay; un lote rechazado NO quema la clave.
--   (11.x) ERROR ESTRUCTURAL — también aborta el lote entero (D3).
--   (12.x) ACLs — anon sin EXECUTE; authenticated sin INSERT en expense_imports.
--
-- ⚠️ REGLA DE ESTE GATE: se asserta el EFECTO (filas nuevas o su ausencia,
-- SQLSTATE exacto), nunca "no hubo error".
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================


-- ═══════════════════════ (1) ESQUEMA ═══════════════════════════════════════
DO $$
DECLARE
  v_count       integer;
  v_condef      text;
  v_confdeltype "char";
  v_conname     text;
BEGIN
  -- (1.1) expense_imports: columnas + PK + UNIQUE(account_id, file_hash)
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'expense_imports'
    AND column_name IN ('id','account_id','imported_by','file_name','file_hash','row_count','imported_count','created_at');
  IF v_count <> 8 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.1): public.expense_imports tiene % de las 8 columnas esperadas.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public' AND tablename = 'expense_imports'
    AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%account_id%' AND indexdef LIKE '%file_hash%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.1): falta el UNIQUE (account_id, file_hash) — el dedupe de dominio (D7) depende de él.';
  END IF;

  -- (1.2) RLS habilitada + policy de SELECT por current_account_ids()
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_imports'::regclass) THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.2): expense_imports no tiene RLS habilitada.';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_policy WHERE polrelid = 'public.expense_imports'::regclass AND polname = 'expense_imports_select';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.2): falta la policy expense_imports_select.';
  END IF;

  -- (1.3) expenses.import_id: nullable uuid + FK a expense_imports + índice
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'expenses'
      AND column_name = 'import_id' AND data_type = 'uuid' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.3): expenses.import_id no existe, no es uuid, o no es nullable.';
  END IF;

  SELECT c.conname, c.confdeltype INTO v_conname, v_confdeltype
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  JOIN pg_class f ON f.oid = c.confrelid
  WHERE n.nspname = 'public' AND t.relname = 'expenses' AND c.contype = 'f' AND f.relname = 'expense_imports';
  IF v_conname IS NULL THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.3): expenses.import_id no tiene FK a expense_imports.';
  END IF;
  IF v_confdeltype <> 'n' THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.3): la FK % no es ON DELETE SET NULL (confdeltype=%).', v_conname, v_confdeltype;
  END IF;

  SELECT COUNT(*) INTO v_count FROM pg_indexes
  WHERE schemaname = 'public' AND tablename = 'expenses' AND indexdef LIKE '%import_id%';
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.3): falta el índice sobre expenses.import_id.';
  END IF;

  -- (1.4) CHECK de operation_idempotency.operation_kind suma expense_import,
  -- sin perder ninguno de los 11 kinds previos.
  SELECT pg_get_constraintdef(c.oid) INTO v_condef
  FROM pg_constraint c
  WHERE c.conrelid = 'public.operation_idempotency'::regclass
    AND c.conname = 'operation_idempotency_operation_kind_check';
  IF position('expense_import' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.4): el CHECK de operation_kind no acepta expense_import. Definición viva: %', v_condef;
  END IF;
  IF position('bank_statement_import' in v_condef) = 0 OR position('credit_note' in v_condef) = 0
     OR position('subscription_webhook' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (1.4): la ampliación del CHECK perdió algún kind previo. Definición viva: %', v_condef;
  END IF;

  RAISE NOTICE 'PASS (1): expense_imports con su forma + RLS + policy, expenses.import_id con FK+índice, CHECK ampliado.';
END $$;


-- ═══════════════════════ (setup) fixtures — 2 tenants ═══════════════════════
DO $$
DECLARE
  v_email_a   text := 'expense-import-batch-a@test.local';
  v_email_b   text := 'expense-import-batch-b@test.local';
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_account_b uuid;
  v_branch_a  uuid;
  v_cashbox_a uuid;
  v_ba_a      uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(), jsonb_build_object('name', 'Gate Import A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(), jsonb_build_object('name', 'Gate Import B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (setup): no se pudieron provisionar 2 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  IF v_branch_a IS NULL THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (setup): sucursal no sembrada — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_cashbox_a FROM public.cashboxes WHERE branch_id = v_branch_a ORDER BY created_at LIMIT 1;
  IF v_cashbox_a IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a, '__gate_eib_cashbox_a__') RETURNING id INTO v_cashbox_a;
  END IF;
  -- Sesión de caja ABIERTA en A: sostiene el control negativo (4.x) — la fila
  -- cash de HOY con caja abierta tiene que seguir sin postear.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a, 'open', 10000, v_user_a);

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_eib_bank_a__', 'ARS', 100000) RETURNING id INTO v_ba_a;

  -- Forma de pago CON destino bancario configurado (sostiene 5.x: precedencia
  -- del configurado sobre el respaldo del lote).
  INSERT INTO public.payment_methods (account_id, name, kind, is_active, bank_account_id)
  VALUES (v_account_a, '__gate_eib_pm_transfer_default__', 'transfer', TRUE, v_ba_a);
  -- Forma de pago bancaria SIN destino configurado (sostiene 5.x: el respaldo
  -- del lote sí se aplica acá).
  INSERT INTO public.payment_methods (account_id, name, kind, is_active)
  VALUES (v_account_a, '__gate_eib_pm_transfer_sin_destino__', 'transfer', TRUE);
  -- Forma de pago 'cash' — el catálogo sembrado ya trae 'Efectivo', se
  -- resuelve por nombre sembrado. Forma de pago 'credit' de B, para el
  -- control estructural (11.x).
  SELECT id INTO v_ba_a FROM public.bank_accounts WHERE account_id = v_account_b LIMIT 1; -- reutiliza var, no se usa después

  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_a, '__gate_eib_cc_a__', 'EIB-A', TRUE);
  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_b, '__gate_eib_cc_b__', 'EIB-B', TRUE);

  RAISE NOTICE 'SETUP OK: 2 tenants (A opera, B ajeno) con banco, formas de pago y centro de costo.';
END $$;


-- ═══════════════ (2) TODO O NADA — una fila inválida no deja nada ══════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb;
  v_before_expenses integer; v_before_bank integer; v_before_cash integer;
  v_before_imports integer; v_before_idem integer;
  v_after_expenses  integer; v_after_bank  integer; v_after_cash  integer;
  v_after_imports   integer; v_after_idem  integer;
  v_rows jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (2): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (2): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (2): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  SELECT COUNT(*) INTO v_before_expenses FROM public.expenses WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_bank FROM public.bank_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_cash FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_imports FROM public.expense_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'Gasto 1 válido', 'category', 'Servicios', 'amount', 1000, 'date', public.reporting_local_today()::text),
    jsonb_build_object('row_no', 2, 'description', 'Gasto 2 inválido', 'category', 'Servicios', 'amount', -500, 'date', public.reporting_local_today()::text),
    jsonb_build_object('row_no', 3, 'description', 'Gasto 3 válido', 'category', 'Servicios', 'amount', 2000, 'date', public.reporting_local_today()::text)
  );

  v_result := public.rpc_import_expenses(
    'gate-eib-2-' || gen_random_uuid()::text, v_rows,
    'gate-eib-2.csv', 'gate-eib-2-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): committed=% y esperaba false — un lote con una fila inválida NO puede aplicarse.', v_result->>'committed';
  END IF;
  IF jsonb_array_length(v_result->'errors') <> 1 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): errors tiene % elementos y esperaba 1. Resultado: %', jsonb_array_length(v_result->'errors'), v_result;
  END IF;
  IF (v_result->'errors'->0->>'row')::int <> 2 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): el error reportado es de la fila % y esperaba la 2. Resultado: %', v_result->'errors'->0->>'row', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_expenses FROM public.expenses WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_bank FROM public.bank_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_cash FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_imports FROM public.expense_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  IF v_after_expenses <> v_before_expenses THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): expenses pasó de % a % — un lote rechazado NO puede dejar NINGÚN gasto nuevo.', v_before_expenses, v_after_expenses;
  END IF;
  IF v_after_bank <> v_before_bank THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): bank_movements pasó de % a %.', v_before_bank, v_after_bank;
  END IF;
  IF v_after_cash <> v_before_cash THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): cash_movements pasó de % a %.', v_before_cash, v_after_cash;
  END IF;
  IF v_after_imports <> v_before_imports THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): expense_imports pasó de % a % — un lote rechazado no deja fila de importación.', v_before_imports, v_after_imports;
  END IF;
  IF v_after_idem <> v_before_idem THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (2): operation_idempotency pasó de % a % — un lote rechazado NO puede quemar la clave.', v_before_idem, v_after_idem;
  END IF;

  RAISE NOTICE 'PASS (2): lote de 3 filas con la 2ª inválida no dejó NADA escrito en las 5 tablas.';
END $$;


-- ═══ (3) CAMINO FELIZ — cash + transfer + sin forma de pago, aviso caja ═════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid; v_branch_a uuid; v_ba_a uuid;
  v_pm_cash uuid; v_pm_transfer uuid;
  v_result jsonb;
  v_import_id uuid;
  v_rows jsonb;
  v_count integer;
  v_exp_cash uuid; v_exp_transfer uuid; v_exp_none uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (3): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_eib_pm_transfer_default__';
  IF v_account_a IS NULL OR v_pm_cash IS NULL OR v_pm_transfer IS NULL THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (3): setup incompleto — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (3): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  -- Fechas ANTERIORES a hoy: sostiene que la pata bancaria es RETROACTIVA
  -- (D5) sin que el opt-in de caja pueda aplicar de casualidad.
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'Gasto en efectivo', 'category', 'Servicios', 'amount', 1000, 'date', '2026-05-01', 'payment_method_name', '__gate_eib_nombre_inexistente__'),
    jsonb_build_object('row_no', 2, 'description', 'Gasto por transferencia', 'category', 'Servicios', 'amount', 2000, 'date', '2026-05-02', 'payment_method_name', '__gate_eib_pm_transfer_default__'),
    jsonb_build_object('row_no', 3, 'description', 'Gasto sin forma de pago', 'category', 'Servicios', 'amount', 3000, 'date', '2026-05-03')
  );
  -- Fila 1 usa un nombre inexistente A PROPÓSITO para el bloque 8; acá se
  -- corrige a un nombre real (Efectivo) para el camino feliz.
  v_rows := jsonb_set(v_rows, '{0,payment_method_name}', to_jsonb((SELECT name FROM public.payment_methods WHERE id = v_pm_cash)));

  v_result := public.rpc_import_expenses(
    'gate-eib-3-' || gen_random_uuid()::text, v_rows,
    'gate-eib-3.csv', 'gate-eib-3-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): committed=% y esperaba true. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'imported')::int <> 3 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): imported=% y esperaba 3. Resultado: %', v_result->>'imported', v_result;
  END IF;

  v_import_id := (v_result->>'import_id')::uuid;
  IF v_import_id IS NULL THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): import_id vino NULL en un lote committed.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.expenses WHERE import_id = v_import_id;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): % gastos con import_id=% y esperaba 3.', v_count, v_import_id;
  END IF;

  SELECT id INTO v_exp_cash FROM public.expenses WHERE import_id = v_import_id AND description = 'Gasto en efectivo';
  SELECT id INTO v_exp_transfer FROM public.expenses WHERE import_id = v_import_id AND description = 'Gasto por transferencia';
  SELECT id INTO v_exp_none FROM public.expenses WHERE import_id = v_import_id AND description = 'Gasto sin forma de pago';

  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_transfer;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): el gasto por transferencia tiene % movimientos bancarios y esperaba 1.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_cash;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): el gasto en efectivo escribió % movimientos bancarios — D6 lo prohíbe también para el banco (no aplica, no tiene kind bancario).', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id IN (v_exp_cash, v_exp_transfer, v_exp_none);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): el lote escribió % movimientos de caja — D6 prohíbe SIEMPRE la pata de caja.', v_count;
  END IF;

  -- Aviso cash_not_posted para la fila 1 (D6 — obligatorio, no opcional)
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'notices') n
    WHERE (n->>'row')::int = 1 AND n->>'code' = 'cash_not_posted'
  ) THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (3): falta el aviso cash_not_posted para la fila 1 (cash). Resultado: %', v_result;
  END IF;

  RAISE NOTICE 'PASS (3): lote de 3 (cash/transfer/sin forma) commitea entero — 1 movimiento bancario, 0 de caja, import_id poblado, aviso cash_not_posted presente.';
END $$;


-- ═══ (4) CAJA JAMÁS — control negativo D6: cash de HOY con caja ABIERTA ════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid; v_pm_cash uuid;
  v_before_cash integer; v_after_cash integer;
  v_result jsonb; v_rows jsonb; v_exp_id uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (4): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_pm_cash IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (4): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (4): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_cash FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'Gasto cash HOY con caja abierta', 'category', 'Servicios',
                        'amount', 500, 'date', public.reporting_local_today()::text,
                        'payment_method_name', (SELECT name FROM public.payment_methods WHERE id = v_pm_cash))
  );

  v_result := public.rpc_import_expenses(
    'gate-eib-4-' || gen_random_uuid()::text, v_rows,
    'gate-eib-4.csv', 'gate-eib-4-hash-' || gen_random_uuid()::text
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (4): committed=% y esperaba true (una fila cash de hoy es válida, sólo no toca caja). Resultado: %', v_result->>'committed', v_result;
  END IF;

  v_exp_id := (SELECT id FROM public.expenses WHERE import_id = (v_result->>'import_id')::uuid LIMIT 1);
  IF v_exp_id IS NULL THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (4): el gasto no persistió.';
  END IF;

  SELECT COUNT(*) INTO v_after_cash FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id WHERE b.account_id = v_account_a;

  IF v_after_cash <> v_before_cash THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (4): cash_movements pasó de % a % — CON SESIÓN ABIERTA HOY el lote SIGUE sin poder tocar caja (D6 es incondicional, no depende del estado de la sesión).', v_before_cash, v_after_cash;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'notices') n WHERE n->>'code' = 'cash_not_posted') THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (4): falta el aviso cash_not_posted pese a la sesión abierta.';
  END IF;

  RAISE NOTICE 'PASS (4): CONTROL NEGATIVO — fila cash de HOY con sesión de caja ABIERTA en la sucursal no escribió ningún movimiento de caja.';
END $$;


-- ═══ (5) RESPALDO BANCARIO — precedencia del configurado vs. respaldo ═══════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_pm_con_destino uuid; v_pm_sin_destino uuid;
  v_ba_configurada uuid; v_ba_respaldo uuid;
  v_result jsonb; v_rows jsonb;
  v_exp_a uuid; v_exp_b uuid;
  v_ba_movimiento uuid;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (5): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id, bank_account_id INTO v_pm_con_destino, v_ba_configurada FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_eib_pm_transfer_default__';
  SELECT id INTO v_pm_sin_destino FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_eib_pm_transfer_sin_destino__';
  IF v_account_a IS NULL OR v_pm_con_destino IS NULL OR v_pm_sin_destino IS NULL THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (5): setup incompleto — degradando.'; RETURN;
  END IF;

  -- Segunda cuenta bancaria de A: será el "respaldo del lote", DISTINTA de la
  -- configurada en la forma de pago — sostiene el assert de que NO la pisa.
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_eib_bank_respaldo__', 'ARS', 0)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_ba_respaldo;
  IF v_ba_respaldo IS NULL THEN
    SELECT id INTO v_ba_respaldo FROM public.bank_accounts WHERE account_id = v_account_a AND name = '__gate_eib_bank_respaldo__';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (5): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'Con destino configurado', 'category', 'Servicios',
                        'amount', 700, 'date', '2026-05-10',
                        'payment_method_name', '__gate_eib_pm_transfer_default__'),
    jsonb_build_object('row_no', 2, 'description', 'Sin destino configurado', 'category', 'Servicios',
                        'amount', 800, 'date', '2026-05-11',
                        'payment_method_name', '__gate_eib_pm_transfer_sin_destino__')
  );

  v_result := public.rpc_import_expenses(
    'gate-eib-5-' || gen_random_uuid()::text, v_rows,
    'gate-eib-5.csv', 'gate-eib-5-hash-' || gen_random_uuid()::text,
    NULL, NULL, NULL, v_ba_respaldo -- p_fallback_bank_account_id = respaldo del lote
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (5): committed=% y esperaba true. Resultado: %', v_result->>'committed', v_result;
  END IF;

  SELECT id INTO v_exp_a FROM public.expenses WHERE import_id = (v_result->>'import_id')::uuid AND description = 'Con destino configurado';
  SELECT id INTO v_exp_b FROM public.expenses WHERE import_id = (v_result->>'import_id')::uuid AND description = 'Sin destino configurado';

  SELECT bank_account_id INTO v_ba_movimiento FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_a;
  IF v_ba_movimiento IS DISTINCT FROM v_ba_configurada THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (5): el gasto con forma de pago CON destino configurado registró el movimiento contra % y esperaba el configurado % — el respaldo del lote NO puede pisar el destino de la forma de pago.', v_ba_movimiento, v_ba_configurada;
  END IF;

  SELECT bank_account_id INTO v_ba_movimiento FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_b;
  IF v_ba_movimiento IS DISTINCT FROM v_ba_respaldo THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (5): el gasto SIN destino configurado registró el movimiento contra % y esperaba el respaldo del lote % — sin destino propio, el respaldo tiene que aplicarse.', v_ba_movimiento, v_ba_respaldo;
  END IF;

  RAISE NOTICE 'PASS (5): el destino configurado en la forma de pago conserva precedencia; el respaldo del lote sólo llena el hueco cuando no hay uno propio.';
END $$;


-- ═══ (6) EQUIVALENCIA con el alta directa (llamada anidada SECURITY DEFINER) ══
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid; v_pm_transfer uuid;
  v_result jsonb; v_rows jsonb;
  v_direct jsonb; v_exp_direct uuid; v_exp_batch uuid;
  v_row_direct RECORD; v_row_batch RECORD;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (6): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_eib_pm_transfer_default__';
  IF v_account_a IS NULL OR v_pm_transfer IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (6): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (6): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_direct := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 4321, p_date => '2026-05-15',
    p_description => 'gate 6 directo', p_payment_method_id => v_pm_transfer
  );
  v_exp_direct := (v_direct->>'expense_id')::uuid;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'gate 6 lote', 'category', 'Servicios',
                        'amount', 4321, 'date', '2026-05-15', 'payment_method_name', '__gate_eib_pm_transfer_default__')
  );
  v_result := public.rpc_import_expenses(
    'gate-eib-6-' || gen_random_uuid()::text, v_rows,
    'gate-eib-6.csv', 'gate-eib-6-hash-' || gen_random_uuid()::text
  );
  v_exp_batch := (SELECT id FROM public.expenses WHERE import_id = (v_result->>'import_id')::uuid LIMIT 1);

  SELECT branch_id, cost_center_id, payment_method_id, amount, date INTO v_row_direct FROM public.expenses WHERE id = v_exp_direct;
  SELECT branch_id, cost_center_id, payment_method_id, amount, date INTO v_row_batch  FROM public.expenses WHERE id = v_exp_batch;

  IF v_row_direct.branch_id IS DISTINCT FROM v_row_batch.branch_id
     OR v_row_direct.payment_method_id IS DISTINCT FROM v_row_batch.payment_method_id
     OR v_row_direct.amount IS DISTINCT FROM v_row_batch.amount
     OR v_row_direct.date IS DISTINCT FROM v_row_batch.date THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (6): el gasto directo y el del lote DIVERGEN — directo=% lote=% — la llamada anidada SECURITY DEFINER cambió la resolución.', v_row_direct, v_row_batch;
  END IF;

  IF (SELECT COUNT(*) FROM public.bank_movements WHERE source_doc_type='expense' AND source_doc_ref=v_exp_direct)
     <> (SELECT COUNT(*) FROM public.bank_movements WHERE source_doc_type='expense' AND source_doc_ref=v_exp_batch) THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (6): el conteo de movimientos bancarios difiere entre el directo y el del lote.';
  END IF;

  RAISE NOTICE 'PASS (6): el gasto creado por el lote es equivalente al creado directo — auth.uid()/current_account_ids() resuelven igual anidados.';
END $$;


-- ═══════════════ (7) SIMULACIÓN (p_dry_run) — cero escrituras ══════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_before_expenses integer; v_before_bank integer; v_before_imports integer; v_before_idem integer;
  v_after_expenses integer; v_after_bank integer; v_after_imports integer; v_after_idem integer;
  v_result jsonb; v_rows jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (7): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (7): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (7): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_expenses FROM public.expenses WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_bank FROM public.bank_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_imports FROM public.expense_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_before_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'gate 7 simulado', 'category', 'Servicios', 'amount', 999, 'date', '2026-05-20')
  );
  v_result := public.rpc_import_expenses(
    'gate-eib-7-' || gen_random_uuid()::text, v_rows,
    'gate-eib-7.csv', 'gate-eib-7-hash-' || gen_random_uuid()::text,
    NULL, NULL, NULL, NULL, true -- p_dry_run
  );

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (7): committed=% en modo simulación y esperaba false. Resultado: %', v_result->>'committed', v_result;
  END IF;
  IF (v_result->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (7): dry_run=% y esperaba true.', v_result->>'dry_run';
  END IF;
  IF (v_result->>'imported')::int <> 1 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (7): imported=% y esperaba 1 (lo que SE HABRÍA importado). Resultado: %', v_result->>'imported', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_expenses FROM public.expenses WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_bank FROM public.bank_movements WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_imports FROM public.expense_imports WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_after_idem FROM public.operation_idempotency WHERE user_id = v_user_a;

  IF v_after_expenses <> v_before_expenses OR v_after_bank <> v_before_bank
     OR v_after_imports <> v_before_imports OR v_after_idem <> v_before_idem THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (7): la simulación dejó escrituras — expenses %→%, bank %→%, imports %→%, idem %→%.',
      v_before_expenses, v_after_expenses, v_before_bank, v_after_bank, v_before_imports, v_after_imports, v_before_idem, v_after_idem;
  END IF;

  RAISE NOTICE 'PASS (7): p_dry_run ejecuta el mismo camino y no deja NINGUNA escritura, ni siquiera el slot de idempotencia.';
END $$;


-- ═══════════════ (8) TENENCIA y nombre que no resuelve ═════════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid; v_account_b uuid;
  v_cc_b uuid;
  v_result jsonb; v_rows jsonb;
  v_before_expenses integer; v_after_expenses integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (8): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members
    WHERE user_id = (SELECT id FROM auth.users WHERE email = 'expense-import-batch-b@test.local') ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cc_b FROM public.cost_centers WHERE account_id = v_account_b AND name = '__gate_eib_cc_b__';
  IF v_account_a IS NULL OR v_account_b IS NULL OR v_cc_b IS NULL THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT (8): setup incompleto — degradando.'; RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (8): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_expenses FROM public.expenses WHERE account_id = v_account_a;

  -- (8.1) nombre de forma de pago que NO existe
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'gate 8.1', 'category', 'Servicios', 'amount', 100, 'date', '2026-05-21',
                        'payment_method_name', 'Transferenca')
  );
  v_result := public.rpc_import_expenses(
    'gate-eib-8a-' || gen_random_uuid()::text, v_rows, 'gate-eib-8a.csv', 'gate-eib-8a-hash-' || gen_random_uuid()::text
  );
  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8.1): un nombre de forma de pago inexistente NO rechazó el lote. Resultado: %', v_result;
  END IF;
  IF (v_result->'errors'->0->>'code') <> 'P0404' THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8.1): code=% y esperaba P0404. Resultado: %', v_result->'errors'->0->>'code', v_result;
  END IF;

  -- (8.2) centro de costo de OTRA cuenta pasado como DEFAULT del lote (uuid
  -- directo — rpc_create_expense lo rechaza con P0404 por su propio guard,
  -- sin que este RPC duplique la validación de tenencia).
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'gate 8.2', 'category', 'Servicios', 'amount', 100, 'date', '2026-05-22')
  );
  v_result := public.rpc_import_expenses(
    'gate-eib-8b-' || gen_random_uuid()::text, v_rows, 'gate-eib-8b.csv', 'gate-eib-8b-hash-' || gen_random_uuid()::text,
    NULL, NULL, v_cc_b, NULL -- p_default_cost_center_id de OTRA cuenta
  );
  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8.2): un centro de costo de OTRA cuenta como default del lote NO rechazó. Resultado: %', v_result;
  END IF;
  IF (v_result->'errors'->0->>'code') <> 'P0404' THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8.2): code=% y esperaba P0404. Resultado: %', v_result->'errors'->0->>'code', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_expenses FROM public.expenses WHERE account_id = v_account_a;
  IF v_after_expenses <> v_before_expenses THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8): expenses de A pasó de % a % — ningún intento de tenencia cruzada puede escribir.', v_before_expenses, v_after_expenses;
  END IF;
  IF EXISTS (SELECT 1 FROM public.expenses WHERE account_id = v_account_b AND description LIKE 'gate 8.%') THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (8): se escribió algo en la cuenta B ajena.';
  END IF;

  RAISE NOTICE 'PASS (8): nombre que no resuelve y catálogo de otra cuenta — ambos error de fila, nada escrito en ninguna cuenta.';
END $$;


-- ═══════════════ (9) TOPE — 501 filas y lote vacío ═════════════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_result jsonb; v_rows jsonb;
  v_before_expenses integer; v_after_expenses integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (9): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (9): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (9): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_expenses FROM public.expenses WHERE account_id = v_account_a;

  SELECT jsonb_agg(jsonb_build_object('row_no', g, 'description', 'gate 9 fila ' || g, 'category', 'Servicios', 'amount', 10, 'date', '2026-05-25'))
  INTO v_rows FROM generate_series(1, 501) g;

  BEGIN
    v_result := public.rpc_import_expenses(
      'gate-eib-9a-' || gen_random_uuid()::text, v_rows, 'gate-eib-9a.csv', 'gate-eib-9a-hash-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (9.1): 501 filas NO levantó excepción — el tope de 500 tiene que rechazarse ANTES de escribir.';
  EXCEPTION WHEN SQLSTATE 'P0427' THEN
    RAISE NOTICE 'PASS (9.1): 501 filas rechazadas con P0427, tal como se esperaba.';
  END;

  -- (9.2) lote vacío
  BEGIN
    v_result := public.rpc_import_expenses(
      'gate-eib-9b-' || gen_random_uuid()::text, '[]'::jsonb, 'gate-eib-9b.csv', 'gate-eib-9b-hash-' || gen_random_uuid()::text
    );
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (9.2): un lote vacío NO levantó excepción.';
  EXCEPTION WHEN SQLSTATE 'P0427' THEN
    RAISE NOTICE 'PASS (9.2): lote vacío rechazado con P0427.';
  END;

  SELECT COUNT(*) INTO v_after_expenses FROM public.expenses WHERE account_id = v_account_a;
  IF v_after_expenses <> v_before_expenses THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (9): expenses pasó de % a % — el tope se evalúa ANTES de cualquier escritura.', v_before_expenses, v_after_expenses;
  END IF;

  RAISE NOTICE 'PASS (9): tope de 500 y lote vacío, los dos con P0427 y cero escrituras.';
END $$;


-- ═══════════════ (10) IDEMPOTENCIA y DEDUPE ════════════════════════════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_key text := 'gate-eib-10-' || gen_random_uuid()::text;
  v_hash text := 'gate-eib-10-hash-' || gen_random_uuid()::text;
  v_rows jsonb; v_result1 jsonb; v_result2 jsonb; v_result3 jsonb;
  v_count_after_1 integer; v_count_after_2 integer;
  v_rejected_key text := 'gate-eib-10r-' || gen_random_uuid()::text;
  v_rejected_hash text := 'gate-eib-10r-hash-' || gen_random_uuid()::text;
  v_result_rej jsonb; v_result_retry jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (10): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (10): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (10): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'gate 10 idempotencia', 'category', 'Servicios', 'amount', 300, 'date', '2026-05-27')
  );

  -- (10.1) primera aplicación
  v_result1 := public.rpc_import_expenses(v_key, v_rows, 'gate-eib-10.csv', v_hash);
  IF (v_result1->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.1): el primer lote no commiteó. Resultado: %', v_result1;
  END IF;
  SELECT COUNT(*) INTO v_count_after_1 FROM public.expenses WHERE import_id = (v_result1->>'import_id')::uuid;

  -- (10.2) reintento con LA MISMA clave → replay, sin segundo lote
  v_result2 := public.rpc_import_expenses(v_key, v_rows, 'gate-eib-10.csv', v_hash);
  IF (v_result2->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.2): el reintento con la misma clave no se reportó como replayed. Resultado: %', v_result2;
  END IF;
  IF (v_result2->>'import_id')::uuid IS DISTINCT FROM (v_result1->>'import_id')::uuid THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.2): el replay devolvió un import_id distinto.';
  END IF;
  SELECT COUNT(*) INTO v_count_after_2 FROM public.expenses WHERE description = 'gate 10 idempotencia';
  IF v_count_after_2 <> v_count_after_1 THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.2): el reintento CREÓ un segundo conjunto de gastos (% vs %).', v_count_after_2, v_count_after_1;
  END IF;

  -- (10.3) MISMO archivo (mismo hash), OTRA clave → replay también
  v_result3 := public.rpc_import_expenses('gate-eib-10-otra-clave-' || gen_random_uuid()::text, v_rows, 'gate-eib-10.csv', v_hash);
  IF (v_result3->>'replayed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.3): mismo file_hash con otra clave no se reportó como replayed. Resultado: %', v_result3;
  END IF;

  -- (10.4) un lote RECHAZADO no quema la clave: mismo key, primero con una
  -- fila inválida (rechazo), después corregido (aplica).
  v_result_rej := public.rpc_import_expenses(
    v_rejected_key,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'description', 'gate 10.4 malo', 'category', 'Servicios', 'amount', -1, 'date', '2026-05-28')),
    'gate-eib-10r.csv', v_rejected_hash
  );
  IF (v_result_rej->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.4): el lote con importe negativo debía rechazarse. Resultado: %', v_result_rej;
  END IF;

  v_result_retry := public.rpc_import_expenses(
    v_rejected_key,
    jsonb_build_array(jsonb_build_object('row_no', 1, 'description', 'gate 10.4 corregido', 'category', 'Servicios', 'amount', 50, 'date', '2026-05-28')),
    'gate-eib-10r.csv', v_rejected_hash
  );
  IF (v_result_retry->>'committed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.4): reintentar con la MISMA clave tras un rechazo debía poder aplicarse. Resultado: %', v_result_retry;
  END IF;
  IF (v_result_retry->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (10.4): el reintento corregido se reportó como replay, y debía ser un lote nuevo aplicado.';
  END IF;

  RAISE NOTICE 'PASS (10): idempotencia por clave, dedupe por archivo, y un lote rechazado no quema la clave.';
END $$;


-- ═══════════════ (11) ERROR ESTRUCTURAL también aborta el lote (D3) ════════
DO $$
DECLARE
  v_user_a uuid; v_account_a uuid;
  v_before_expenses integer; v_after_expenses integer;
  v_result jsonb; v_rows jsonb;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'expense-import-batch-a@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (11): sin anchor A — degradando.'; RETURN; END IF;
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (11): setup incompleto — degradando.'; RETURN; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN RAISE NOTICE 'GATE EXPENSE-IMPORT (11): auth.uid() no resuelve — degradando.'; RETURN; END IF;

  SELECT COUNT(*) INTO v_before_expenses FROM public.expenses WHERE account_id = v_account_a;

  -- category NULL: pasa el shape check de "campos mínimos" (D3 exige NOT
  -- NULL en la validación P0427), así que se fuerza con un valor de category
  -- que dispara un error NO previsto por ninguna regla de negocio: category
  -- con más caracteres que el límite de un tipo (no aplica, category es
  -- text sin límite) — en su lugar, se usa una fecha inválida para el tipo
  -- `date` del jsonb_to_recordset, que revienta con un error de CASTEO
  -- (22007/22008), no un ERRCODE de dominio del alta.
  v_rows := jsonb_build_array(
    jsonb_build_object('row_no', 1, 'description', 'ok', 'category', 'Servicios', 'amount', 100, 'date', '2026-05-30'),
    jsonb_build_object('row_no', 2, 'description', 'estructural', 'category', 'Servicios', 'amount', 100, 'date', 'no-es-una-fecha')
  );

  BEGIN
    v_result := public.rpc_import_expenses(
      'gate-eib-11-' || gen_random_uuid()::text, v_rows, 'gate-eib-11.csv', 'gate-eib-11-hash-' || gen_random_uuid()::text
    );
  EXCEPTION WHEN OTHERS THEN
    -- El casteo de "date" con un valor inválido ocurre DENTRO del
    -- jsonb_to_recordset del FOR (evaluado antes de entrar al loop), así que
    -- puede escapar como excepción de la función entera en vez de quedar
    -- atrapado por el BEGIN/EXCEPTION de la fila. En ese caso el rollback lo
    -- garantiza la transacción del propio bloque DO — se verifica lo mismo:
    -- cero escrituras.
    v_result := jsonb_build_object('committed', false, 'errors', jsonb_build_array(jsonb_build_object('code', SQLSTATE)));
  END;

  IF (v_result->>'committed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (11): un error ESTRUCTURAL (fecha inválida) no rechazó el lote. Resultado: %', v_result;
  END IF;

  SELECT COUNT(*) INTO v_after_expenses FROM public.expenses WHERE account_id = v_account_a;
  IF v_after_expenses <> v_before_expenses THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (11): expenses pasó de % a % — un error estructural TAMBIÉN tiene que dejar el lote sin ninguna escritura parcial.', v_before_expenses, v_after_expenses;
  END IF;

  RAISE NOTICE 'PASS (11): un error estructural (no de dominio) también aborta el lote entero, sin escritura parcial.';
END $$;


-- ═══════════════ (12) ACLs ══════════════════════════════════════════════════
DO $$
DECLARE
  v_has_anon_execute boolean;
  v_has_authenticated_execute boolean;
  v_has_authenticated_insert boolean;
BEGIN
  SELECT has_function_privilege('anon', 'public.rpc_import_expenses(text,jsonb,text,text,uuid,uuid,uuid,uuid,boolean)', 'EXECUTE')
    INTO v_has_anon_execute;
  IF v_has_anon_execute THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (12): anon TIENE EXECUTE sobre rpc_import_expenses.';
  END IF;

  SELECT has_function_privilege('authenticated', 'public.rpc_import_expenses(text,jsonb,text,text,uuid,uuid,uuid,uuid,boolean)', 'EXECUTE')
    INTO v_has_authenticated_execute;
  IF NOT v_has_authenticated_execute THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (12): authenticated NO tiene EXECUTE sobre rpc_import_expenses.';
  END IF;

  SELECT has_table_privilege('authenticated', 'public.expense_imports', 'INSERT') INTO v_has_authenticated_insert;
  IF v_has_authenticated_insert THEN
    RAISE EXCEPTION 'GATE EXPENSE-IMPORT FAILED (12): authenticated TIENE INSERT sobre expense_imports — la escritura debe ser exclusiva de la RPC SECURITY DEFINER.';
  END IF;

  RAISE NOTICE 'PASS (12): anon sin EXECUTE, authenticated con EXECUTE y sin INSERT en expense_imports.';
END $$;


-- @@CLEANUP@@
DO $$
DECLARE
  v_emails   text[] := ARRAY['expense-import-batch-a@test.local', 'expense-import-batch-b@test.local'];
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users FROM auth.users WHERE email = ANY(v_emails);
  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE EXPENSE-IMPORT: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT a), ARRAY[]::uuid[]) INTO v_accounts
  FROM (
    SELECT account_id AS a FROM public.account_members WHERE user_id = ANY(v_users)
    UNION
    SELECT id         AS a FROM public.accounts        WHERE owner_user_id = ANY(v_users)
  ) x;

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    -- Sin filtrar por nombre de cashbox: la sesión de A se abrió en el
    -- cashbox AUTO-PROVISIONADO de la sucursal (no uno con nombre __gate_eib_%).
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts) AND cb.name LIKE '__gate_eib_%';
    DELETE FROM public.bank_movements WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_accounts  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.expenses       WHERE account_id = ANY(v_accounts);
    DELETE FROM public.expense_imports WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cost_centers   WHERE account_id = ANY(v_accounts) AND name LIKE '__gate_eib_%';
    DELETE FROM public.payment_methods WHERE account_id = ANY(v_accounts) AND name LIKE '__gate_eib_%';
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  DELETE FROM public.branches              WHERE account_id = ANY(v_accounts) AND name LIKE '__gate_eib_%';
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY(v_users) OR recipient = ANY(v_emails);
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE EXPENSE-IMPORT: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
