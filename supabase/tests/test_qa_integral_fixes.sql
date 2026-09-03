-- =============================================================================
-- GATE: test_qa_integral_fixes.sql
-- CHANGE: qa-integral-modulos — G4 (task 4.1/4.2) + G8 (task 8.2)
--
-- Qué ejercita, con un tenant sintético y sesión vía request.jwt.claims
-- (mismo molde que test_gastos_forma_pago.sql):
--
--   (1) rpc_branch_report ejecuta de verdad (el 42702 "column reference
--       branch_id is ambiguous" del CTE all_branch_ids está corregido en
--       20261016000001) y atribuye ventas y gastos a su sucursal. La función
--       NUNCA ejecutó correctamente desde su creación (C-06, 2026-06-07);
--       el warning tolerante de test_gastos_forma_pago (6.5b) se
--       auto-fortalece con el mismo fix — este gate lo exige sin tolerancia.
--
--   (2) rpc_product_profitability ejecuta de verdad (el 42804 last_sale_date
--       date vs MAX(s.date) timestamptz está corregido) Y last_sale_date es
--       la FECHA DE NEGOCIO declarada, sin desplazamiento. estadisticas-ventas
--       (D3 / OQ-3, reporting-invariants "fecha de negocio vs instante"):
--       sales.date guarda el día calendario del formulario a 00:00 UTC (0 de
--       643 líneas con hora en prod); el cast consciente de zona que este gate
--       exigía antes corría CADA venta un día atrás (218/218 productos en
--       /rentabilidad). Ahora el fixture es una fecha de negocio real y el
--       assert exige igualdad exacta; el día anterior delata el AT TIME ZONE
--       regresivo — es el discriminador anti-off-by-one, con el signo correcto.
--
-- ⚠️ REGLA: se asserta el EFECTO (filas, totales, la fecha exacta), nunca
-- "no hubo error".
--
-- Degrade-don't-fail: si el anchor sintético no se aprovisiona o auth.uid()
-- no resuelve bajo request.jwt.claims local, NOTICE y no aborta.
-- Cleanup: DO block separado al final, resuelve por email.
-- =============================================================================

DO $$
DECLARE
  v_user      uuid;
  v_account   uuid;
  v_branch    uuid;
  v_product   uuid;
  v_local_day date;
  v_sale_ts   timestamptz;
  v_row       RECORD;
  v_count     integer;
BEGIN
  -- ── Setup: anchor con provisioning automático (handle_new_user). Se
  -- resuelve por email ANTES de insertar: en la DB local compartida el anchor
  -- puede persistir de una corrida previa y un INSERT con id nuevo y el mismo
  -- email reventaría con 23505 (el modo de fallo ambiental ya documentado en
  -- los otros gates). ─────────────────────────────────────────────────────────
  SELECT id INTO v_user FROM auth.users WHERE email = 'qa-integral-fixes-a@test.local';
  IF v_user IS NULL THEN
    v_user := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', 'qa-integral-fixes-a@test.local',
            now(), now(), jsonb_build_object('name', 'Gate QA Integral A'));
  END IF;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE QA-INTEGRAL: anchor sin cuenta aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch FROM public.branches
  WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL THEN
    RAISE NOTICE 'GATE QA-INTEGRAL: anchor sin sucursal aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;

  -- Limpieza de restos de una corrida previa cortada (los totales de (1) y
  -- (2) son exactos — una segunda venta de 500 los rompería en falso).
  DELETE FROM public.expenses WHERE account_id = v_account AND description = '__gate_qaint_gasto__';
  DELETE FROM public.sales    WHERE account_id = v_account AND product_id IN
    (SELECT id FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__');
  DELETE FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__';

  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_qaint_producto__', 500, 100)
  RETURNING id INTO v_product;

  -- Venta con FECHA DE NEGOCIO de hace 5 días locales, persistida como la
  -- guarda el formulario: día calendario a 00:00 UTC (estadisticas-ventas D3).
  -- La única respuesta correcta para last_sale_date es ese mismo día; el día
  -- anterior (v_local_day - 1) delata un AT TIME ZONE sobre la fecha de negocio.
  v_local_day := public.reporting_local_today() - 5;
  v_sale_ts   := v_local_day::timestamp AT TIME ZONE 'UTC';

  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, total, quantity, date)
  VALUES (v_user, v_account, v_branch, v_product, 500, 500, 1, v_sale_ts);

  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date, description)
  VALUES (v_user, v_account, v_branch, 'Servicios', 1234, v_sale_ts, '__gate_qaint_gasto__');

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN
    RAISE NOTICE 'GATE QA-INTEGRAL: auth.uid() no resuelve al anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- ═══ (1) rpc_branch_report — sin 42702, con atribución correcta ═══════════
  SELECT * INTO v_row
  FROM public.rpc_branch_report(v_account, v_local_day - 1, v_local_day + 1) r
  WHERE r.branch_id = v_branch;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (1): rpc_branch_report no devolvió la sucursal con venta y gasto en rango — ¿volvió el 42702 o cambió la agregación?';
  END IF;
  IF v_row.total_sales <> 500 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (1): rpc_branch_report atribuyó % de ventas a la sucursal y esperaba 500.', v_row.total_sales;
  END IF;
  IF v_row.total_expenses <> 1234 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (1): rpc_branch_report atribuyó % de gastos a la sucursal y esperaba 1234.', v_row.total_expenses;
  END IF;
  IF v_row.operation_count <> 1 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (1): rpc_branch_report contó % operaciones y esperaba 1.', v_row.operation_count;
  END IF;
  RAISE NOTICE 'PASS (1): rpc_branch_report ejecuta y atribuye 500/1234/1 a la sucursal.';

  -- ═══ (2) rpc_product_profitability — sin 42804 y con fecha LOCAL ══════════
  SELECT * INTO v_row
  FROM public.rpc_product_profitability(30) r
  WHERE r.product_id = v_product;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (2): rpc_product_profitability no devolvió el producto vendido — ¿volvió el 42804?';
  END IF;
  IF v_row.total_revenue <> 500 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (2): total_revenue fue % y esperaba 500.', v_row.total_revenue;
  END IF;
  IF v_row.last_sale_date IS DISTINCT FROM v_local_day THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (2): last_sale_date fue % y esperaba % (fecha de negocio declarada) — un % delata un AT TIME ZONE sobre sales.date (off-by-one de estadisticas-ventas OQ-3, 218/218 en prod).',
      v_row.last_sale_date, v_local_day, v_local_day - 1;
  END IF;
  RAISE NOTICE 'PASS (2): rpc_product_profitability ejecuta y fecha la venta en su fecha de negocio (%), sin corrimiento.', v_local_day;
END $$;


-- ═══ (3) H11/G16 — el motivo del gasto viaja a caja, a banco y a las reversas ═
-- rpc_create_expense escribía los movimientos con description NULL (llamaba a
-- c28_register_cash_movement con 4 args y a _pay_register_operation_bank_movement
-- con NULL literal en p_description) y la reversa de caja del borrado tampoco
-- llevaba motivo. Corregido en 20261016000001 §5/§6. Se asserta el EFECTO: la
-- description exacta en los cuatro movimientos (expense, bank out, expense_reversal,
-- espejo bancario) — nunca "no hubo error".
DO $$
DECLARE
  v_user     uuid;
  v_account  uuid;
  v_branch   uuid;
  v_cashbox  uuid;
  v_session  uuid;
  v_bank     uuid;
  v_pm_cash  uuid;
  v_pm_transf uuid;
  v_today    date;
  v_exp_cash uuid;
  v_exp_bank uuid;
  v_row      RECORD;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = 'qa-integral-fixes-a@test.local';
  IF v_user IS NULL THEN
    RAISE NOTICE 'GATE QA-INTEGRAL (3): sin anchor — degradando sin abortar.';
    RETURN;
  END IF;
  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE QA-INTEGRAL (3): anchor sin cuenta — degradando sin abortar.';
    RETURN;
  END IF;

  v_branch := public.c26_default_branch(v_account);
  SELECT id INTO v_pm_cash FROM public.payment_methods
  WHERE account_id = v_account AND kind = 'cash' AND is_active AND deleted_at IS NULL
  ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_transf FROM public.payment_methods
  WHERE account_id = v_account AND kind = 'transfer' AND is_active AND deleted_at IS NULL
  ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL OR v_pm_cash IS NULL OR v_pm_transf IS NULL THEN
    RAISE NOTICE 'GATE QA-INTEGRAL (3): anchor sin sucursal o sin catálogo de pagos sembrado — degradando sin abortar.';
    RETURN;
  END IF;

  -- Infraestructura idempotente: cashbox + sesión abierta + cuenta bancaria.
  SELECT id INTO v_cashbox FROM public.cashboxes WHERE branch_id = v_branch ORDER BY created_at LIMIT 1;
  IF v_cashbox IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch, '__gate_qaint_cashbox__')
    RETURNING id INTO v_cashbox;
  END IF;
  SELECT id INTO v_session FROM public.cash_sessions
  WHERE cashbox_id = v_cashbox AND status = 'open' ORDER BY opened_at DESC LIMIT 1;
  IF v_session IS NULL THEN
    INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
    VALUES (v_cashbox, 'open', 0, v_user) RETURNING id INTO v_session;
  END IF;
  SELECT id INTO v_bank FROM public.bank_accounts
  WHERE account_id = v_account AND name = '__gate_qaint_banco__' AND deleted_at IS NULL;
  IF v_bank IS NULL THEN
    INSERT INTO public.bank_accounts (account_id, name)
    VALUES (v_account, '__gate_qaint_banco__') RETURNING id INTO v_bank;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user THEN
    RAISE NOTICE 'GATE QA-INTEGRAL (3): auth.uid() no resuelve al anchor — degradando sin abortar.';
    RETURN;
  END IF;
  v_today := public.reporting_local_today();

  -- (3a) Gasto en efectivo con opt-in de caja → el movimiento lleva el motivo.
  v_exp_cash := (public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 1500, p_date => v_today,
      p_description => '__gate_qaint_motivo_caja__', p_branch_id => v_branch,
      p_payment_method_id => v_pm_cash, p_cash_session_id => v_session
    )->>'expense_id')::uuid;
  SELECT * INTO v_row FROM public.cash_movements
  WHERE reference_id = v_exp_cash AND movement_type = 'expense';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3a): el gasto en efectivo con opt-in no registró movimiento de caja.';
  END IF;
  IF v_row.description IS DISTINCT FROM '__gate_qaint_motivo_caja__' THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3a): el movimiento de caja del gasto quedó con description=% y esperaba el motivo del gasto (H11).', COALESCE(v_row.description, 'NULL');
  END IF;

  -- (3b) Gasto por transferencia → el movimiento bancario lleva el motivo.
  v_exp_bank := (public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 2500, p_date => v_today,
      p_description => '__gate_qaint_motivo_banco__', p_branch_id => v_branch,
      p_payment_method_id => v_pm_transf, p_bank_account_id => v_bank
    )->>'expense_id')::uuid;
  SELECT * INTO v_row FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_bank AND amount < 0;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3b): el gasto por transferencia no registró movimiento bancario.';
  END IF;
  IF v_row.description IS DISTINCT FROM '__gate_qaint_motivo_banco__' THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3b): el movimiento bancario del gasto quedó con description=% y esperaba el motivo del gasto (H11).', COALESCE(v_row.description, 'NULL');
  END IF;

  -- (3c) TRIANGULACIÓN: la reversa de caja del borrado lleva el mismo motivo.
  PERFORM public.rpc_delete_expense(p_expense_id => v_exp_cash);
  SELECT * INTO v_row FROM public.cash_movements
  WHERE reference_id = v_exp_cash AND movement_type = 'expense_reversal';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3c): el borrado del gasto en efectivo no registró expense_reversal.';
  END IF;
  IF v_row.description IS DISTINCT FROM '__gate_qaint_motivo_caja__' THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3c): la reversa de caja quedó con description=% y esperaba el motivo del gasto borrado.', COALESCE(v_row.description, 'NULL');
  END IF;

  -- (3d) TRIANGULACIÓN: el espejo bancario del borrado nombra al gasto Y
  -- conserva el marcador de reversión (contrato 5.5/5.7 de test_gastos_forma_pago).
  PERFORM public.rpc_delete_expense(p_expense_id => v_exp_bank);
  SELECT * INTO v_row FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_bank AND amount > 0;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3d): el borrado del gasto bancario no registró el espejo de ingreso.';
  END IF;
  IF position('Reversión por borrado de gasto' in COALESCE(v_row.description, '')) = 0 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3d): el espejo bancario perdió el marcador de reversión (description=%).', COALESCE(v_row.description, 'NULL');
  END IF;
  IF position('__gate_qaint_motivo_banco__' in COALESCE(v_row.description, '')) = 0 THEN
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (3d): el espejo bancario no nombra al gasto borrado (description=%).', COALESCE(v_row.description, 'NULL');
  END IF;

  -- Limpieza de los movimientos de esta corrida (los gastos ya los borró la RPC).
  DELETE FROM public.cash_movements WHERE reference_id IN (v_exp_cash, v_exp_bank);
  DELETE FROM public.bank_movements WHERE source_doc_ref IN (v_exp_cash, v_exp_bank);

  RAISE NOTICE 'PASS (3): el motivo del gasto viaja a caja, a banco y a las dos reversas del borrado.';
END $$;


-- ═══ CLEANUP — resuelve por email, sobrevive corridas cortadas ══════════════
DO $$
DECLARE
  v_user    uuid;
  v_account uuid;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = 'qa-integral-fixes-a@test.local';
  IF v_user IS NULL THEN RETURN; END IF;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NOT NULL THEN
    -- Restos de una corrida de (3) cortada antes de sus borrados.
    DELETE FROM public.cash_movements cm USING public.expenses e
      WHERE e.id = cm.reference_id AND e.account_id = v_account
        AND e.description IN ('__gate_qaint_motivo_caja__', '__gate_qaint_motivo_banco__');
    DELETE FROM public.bank_movements bm USING public.expenses e
      WHERE e.id = bm.source_doc_ref AND bm.source_doc_type = 'expense'
        AND e.account_id = v_account
        AND e.description IN ('__gate_qaint_motivo_caja__', '__gate_qaint_motivo_banco__');
    DELETE FROM public.expenses WHERE account_id = v_account
      AND description IN ('__gate_qaint_motivo_caja__', '__gate_qaint_motivo_banco__');
    DELETE FROM public.expenses WHERE account_id = v_account AND description = '__gate_qaint_gasto__';
    DELETE FROM public.sales    WHERE account_id = v_account AND product_id IN
      (SELECT id FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__');
    DELETE FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__';
  END IF;

  -- El usuario ancla y su cuenta aprovisionada se dejan: borrarlos en cascada
  -- dispararía el guard de vaciado de sucursales (P0428) — el setup resuelve
  -- por email y es idempotente sobre el anchor persistido.
END $$;
