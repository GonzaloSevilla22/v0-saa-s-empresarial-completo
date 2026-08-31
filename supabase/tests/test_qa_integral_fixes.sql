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
--       date vs MAX(s.date) timestamptz está corregido) Y el cast es
--       consciente de zona: una venta a las 23:30 ART queda fechada en su día
--       LOCAL, no en el día UTC siguiente (RN-D5). Un fix regresivo con
--       ::date desnudo pasa el 42804 pero FALLA este assert — es el
--       discriminador anti-off-by-one.
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

  -- Venta a las 23:30 ART de hace 5 días locales = 02:30 UTC del día
  -- SIGUIENTE. El día local es la única respuesta correcta para
  -- last_sale_date; el día UTC (v_local_day + 1) delata un ::date desnudo.
  v_local_day := public.reporting_local_today() - 5;
  v_sale_ts   := (v_local_day::timestamp + interval '23 hours 30 minutes')
                   AT TIME ZONE 'America/Argentina/Mendoza';

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
    RAISE EXCEPTION 'GATE QA-INTEGRAL FAILED (2): last_sale_date fue % y esperaba % (día LOCAL de la venta de 23:30 ART) — un % delata el cast con la TimeZone de sesión (::date desnudo, off-by-one de RN-D5).',
      v_row.last_sale_date, v_local_day, v_local_day + 1;
  END IF;
  RAISE NOTICE 'PASS (2): rpc_product_profitability ejecuta y fecha la venta de 23:30 ART en su día local (%).', v_local_day;
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
    DELETE FROM public.expenses WHERE account_id = v_account AND description = '__gate_qaint_gasto__';
    DELETE FROM public.sales    WHERE account_id = v_account AND product_id IN
      (SELECT id FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__');
    DELETE FROM public.products WHERE account_id = v_account AND name = '__gate_qaint_producto__';
  END IF;

  -- El usuario ancla y su cuenta aprovisionada se dejan: borrarlos en cascada
  -- dispararía el guard de vaciado de sucursales (P0428) — el setup resuelve
  -- por email y es idempotente sobre el anchor persistido.
END $$;
