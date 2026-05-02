-- ==============================================================================
-- Fase 3+: Validación de Edge Cases para KPIs
-- ==============================================================================
-- Escenarios límite que validan robustez de los RPCs ante datos atípicos.
-- Ejecución: npx supabase db psql -f supabase/tests/test_kpis_edge_cases.sql
-- ⚠️ SOLO PARA ENTORNO LOCAL

DO $$
DECLARE
  -- Usuarios de test (prefijo e0 para no colisionar con test_kpis.sql)
  eu1 uuid := 'e0000000-0000-0000-0000-000000000001'; -- sin transacciones
  eu2 uuid := 'e0000000-0000-0000-0000-000000000002'; -- solo gastos
  eu3 uuid := 'e0000000-0000-0000-0000-000000000003'; -- solo ingresos
  eu4 uuid := 'e0000000-0000-0000-0000-000000000004'; -- activado sin UMV
  eu5 uuid := 'e0000000-0000-0000-0000-000000000005'; -- volumen alto
  eu6 uuid := 'e0000000-0000-0000-0000-000000000006'; -- tenant aislado

  ep1 uuid := 'd0000000-0000-0000-0000-000000000001';
  ep2 uuid := 'd0000000-0000-0000-0000-000000000002';
  ep3 uuid := 'd0000000-0000-0000-0000-000000000003';
  epost1 uuid := 'f0000000-0000-0000-0000-000000000001';

  v_now timestamptz := now();
  v_from timestamptz := now() - interval '1 day';
  v_to   timestamptz := now() + interval '1 day';
  -- Fechas vacías (rango sin datos)
  v_empty_from timestamptz := '2020-01-01'::timestamptz;
  v_empty_to   timestamptz := '2020-01-02'::timestamptz;
  -- Fechas invertidas
  v_inv_from timestamptz := now() + interval '1 day';
  v_inv_to   timestamptz := now() - interval '1 day';

  -- Variables de resultado
  r_income numeric; r_expenses numeric; r_purchases numeric; r_profit numeric;
  r_stock bigint; r_activation numeric; r_umv numeric;
  r_conversion numeric; r_community bigint;
  r_income2 numeric; r_expenses2 numeric; r_purchases2 numeric; r_profit2 numeric;
  r_insight_uncat bigint;

  pass_count int := 0;
  fail_count int := 0;
BEGIN
  ---------------------------------------------------------------------------
  -- 0. LIMPIEZA
  ---------------------------------------------------------------------------
  RAISE NOTICE 'Limpiando datos edge case (e0/d0/f0)...';
  DELETE FROM public.replies WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.posts WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.sales WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.expenses WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.purchases WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.products WHERE name LIKE 'test_kpi_edge_%';
  DELETE FROM public.analytics_events WHERE user_id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM public.profiles WHERE id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  DELETE FROM auth.users WHERE id IN (eu1,eu2,eu3,eu4,eu5,eu6);

  ---------------------------------------------------------------------------
  -- 1. SEED
  ---------------------------------------------------------------------------
  RAISE NOTICE 'Insertando mock data edge cases...';

  INSERT INTO auth.users (id, aud, role, email) VALUES
    (eu1, 'authenticated','authenticated','test_kpi_edge_1@test.com'),
    (eu2, 'authenticated','authenticated','test_kpi_edge_2@test.com'),
    (eu3, 'authenticated','authenticated','test_kpi_edge_3@test.com'),
    (eu4, 'authenticated','authenticated','test_kpi_edge_4@test.com'),
    (eu5, 'authenticated','authenticated','test_kpi_edge_5@test.com'),
    (eu6, 'authenticated','authenticated','test_kpi_edge_6@test.com');

  EXECUTE 'ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation';
  UPDATE public.profiles SET
    name = CASE id
      WHEN eu1 THEN 'test_kpi_edge_u1'
      WHEN eu2 THEN 'test_kpi_edge_u2'
      WHEN eu3 THEN 'test_kpi_edge_u3'
      WHEN eu4 THEN 'test_kpi_edge_u4'
      WHEN eu5 THEN 'test_kpi_edge_u5'
      WHEN eu6 THEN 'test_kpi_edge_u6'
    END,
    plan = CASE id
      WHEN eu1 THEN 'free'::user_plan
      WHEN eu2 THEN 'free'::user_plan
      WHEN eu3 THEN 'free'::user_plan
      WHEN eu4 THEN 'free'::user_plan
      WHEN eu5 THEN 'free'::user_plan
      WHEN eu6 THEN 'free'::user_plan
    END,
    created_at = v_now
  WHERE id IN (eu1,eu2,eu3,eu4,eu5,eu6);
  EXECUTE 'ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation';

  -- Productos
  INSERT INTO public.products (id,user_id,name,stock,min_stock,price,cost,category,is_variant) VALUES
    (ep1, eu2, 'test_kpi_edge_prod1', 5, 10, 100, 50, 'General', false),
    (ep2, eu3, 'test_kpi_edge_prod2', 20, 5, 200, 80, 'General', false),
    (ep3, eu5, 'test_kpi_edge_prod3', 3, 10, 50, 25, 'General', false);

  -- eu2: Solo gastos (caso f)
  INSERT INTO public.expenses (user_id, amount, description, date, category) VALUES
    (eu2, 300, 'test_kpi_edge_exp1', v_now, 'General'),
    (eu2, 150, 'test_kpi_edge_exp2', v_now, 'General');

  -- eu3: Solo ingresos (caso g)
  INSERT INTO public.sales (user_id, amount, quantity, date, product_id, currency) VALUES
    (eu3, 1000, 2, v_now, ep2, 'ARS'),
    (eu3, 500, 1, v_now, ep2, 'ARS');

  -- eu4: Activado sin UMV (caso e)
  INSERT INTO public.analytics_events (user_id, event_name, created_at) VALUES
    (eu4, 'first_operation', v_now);

  -- eu5: Volumen alto (caso j) — 20 ventas + 10 gastos
  FOR i IN 1..20 LOOP
    INSERT INTO public.sales (user_id, amount, quantity, date, product_id, currency)
    VALUES (eu5, 100, 1, v_now, ep3, 'ARS');
  END LOOP;
  FOR i IN 1..10 LOOP
    INSERT INTO public.expenses (user_id, amount, description, date, category)
    VALUES (eu5, 50, 'test_kpi_edge_vol_' || i, v_now, 'General');
  END LOOP;

  -- eu6: Tenant aislado con datos propios (caso i)
  INSERT INTO public.sales (user_id, amount, quantity, date, product_id, currency) VALUES
    (eu6, 999, 1, v_now, ep2, 'ARS');
  INSERT INTO public.expenses (user_id, amount, description, date, category) VALUES
    (eu6, 111, 'test_kpi_edge_tenant', v_now, 'General');

  -- Comunidad: 1 post de eu5 (para test fecha vacía)
  INSERT INTO public.posts (id, user_id, title, content, created_at, category) VALUES
    (epost1, eu5, 'test_kpi_edge_post', 'contenido', v_now, 'General');

  -- Caso K: Evento insight_generated con event_data NULL y con '{}'
  -- Deben agruparse como 'uncategorized' por el RPC get_admin_insights_breakdown
  INSERT INTO public.analytics_events (user_id, event_name, event_data, created_at) VALUES
    (eu1, 'insight_generated', NULL, v_now),
    (eu2, 'insight_generated', '{}', v_now);

  ---------------------------------------------------------------------------
  -- REPORTE
  ---------------------------------------------------------------------------
  RAISE NOTICE '========================================================';
  RAISE NOTICE '          EDGE CASE VALIDATION REPORT';
  RAISE NOTICE '========================================================';

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO A: Rango de fechas vacío (sin datos en ese periodo)
  -- Valida: Los RPCs devuelven 0 cuando no hay datos en el rango.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO A: Rango de fechas vacio (sin datos)';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu5, v_empty_from, v_empty_to);
  r_activation := get_admin_activation_rate(v_empty_from, v_empty_to);
  r_community  := get_admin_community_interactions(v_empty_from, v_empty_to);

  IF r_income = 0 AND r_expenses = 0 AND r_profit = 0 THEN
    RAISE NOTICE '  Financials   | Exp: 0 | Act: % / % / % | OK', r_income, r_expenses, r_profit;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  Financials   | Exp: 0 | Act: % / % / % | FAIL', r_income, r_expenses, r_profit;
    fail_count := fail_count + 1;
  END IF;

  IF r_activation = 0 THEN
    RAISE NOTICE '  Activation   | Exp: 0 | Act: % | OK', r_activation;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  Activation   | Exp: 0 | Act: % | FAIL', r_activation;
    fail_count := fail_count + 1;
  END IF;

  IF r_community = 0 THEN
    RAISE NOTICE '  Community    | Exp: 0 | Act: % | OK', r_community;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  Community    | Exp: 0 | Act: % | FAIL', r_community;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO B: Fechas invertidas (date_from > date_to)
  -- Valida: Los RPCs devuelven 0 sin error por la regla 3.6.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO B: Fechas invertidas';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu5, v_inv_from, v_inv_to);
  r_activation := get_admin_activation_rate(v_inv_from, v_inv_to);
  r_umv        := get_admin_umv_rate(v_inv_from, v_inv_to);
  r_community  := get_admin_community_interactions(v_inv_from, v_inv_to);

  IF r_income = 0 AND r_expenses = 0 AND r_profit = 0 AND r_activation = 0 AND r_umv = 0 AND r_community = 0 THEN
    RAISE NOTICE '  Todos RPCs   | Exp: 0 | Act: 0 | OK';
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  Todos RPCs   | Exp: 0 | Act: %/%/%/%/%/% | FAIL', r_income, r_expenses, r_profit, r_activation, r_umv, r_community;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO C: Usuario sin transacciones (eu1)
  -- Valida: Financials devuelve 0, stock crítico = 0 (sin productos).
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO C: Usuario sin transacciones (eu1)';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu1, v_from, v_to);
  r_stock := get_dashboard_critical_stock(eu1);

  IF r_income = 0 AND r_expenses = 0 AND r_purchases = 0 AND r_profit = 0 AND r_stock = 0 THEN
    RAISE NOTICE '  Financials   | Exp: todo 0 | Act: 0/0/0/0 | OK';
    RAISE NOTICE '  Stock        | Exp: 0 | Act: % | OK', r_stock;
    pass_count := pass_count + 2;
  ELSE
    RAISE NOTICE '  Financials   | Act: %/%/%/% | FAIL', r_income, r_expenses, r_purchases, r_profit;
    RAISE NOTICE '  Stock        | Act: % | FAIL', r_stock;
    fail_count := fail_count + 2;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO D: Cohorte sin activaciones
  -- Valida: activation_rate = 0 cuando nadie tiene first_operation.
  --   Nota: eu2 y eu3 no tienen eventos first_operation. Usando
  --   un rango donde solo ellos se registraron no es posible (todos
  --   tienen created_at = now()). Se valida implícitamente con
  --   rango vacío (caso A). Aquí verificamos que eu1 (sin eventos)
  --   no afecta la tasa global.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO D: Cohorte sin activaciones (via rango vacio)';
  -- Ya cubierto en Caso A con r_activation = 0. Validación adicional:
  r_activation := get_admin_activation_rate(v_empty_from, v_empty_to);
  IF r_activation = 0 THEN
    RAISE NOTICE '  Act. Rate    | Exp: 0 | Act: % | OK', r_activation;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  Act. Rate    | Exp: 0 | Act: % | FAIL', r_activation;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO E: Activado sin UMV (eu4 tiene first_operation pero no insight)
  -- Valida: UMV rate refleja solo quienes tienen insight_generated.
  --   eu4 activado + 6 edge users registrados en periodo.
  --   Pero UMV depende del universo total. Verificamos que eu4 NO
  --   cuente como UMV.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO E: Activado sin UMV (eu4)';
  r_umv := get_admin_umv_rate(v_from, v_to);
  -- eu4 es el ÚNICO activado en este batch. Tiene 0 insight_generated.
  -- UMV = 0 / 1 = 0%  (si SOLO contamos los edge users, pero la BD
  --   puede tener datos de test_kpis.sql también).
  -- Lo importante es que NO sea 100% (eu4 no debe contar como UMV).
  IF r_umv < 100 THEN
    RAISE NOTICE '  UMV Rate     | Exp: <100 | Act: % | OK (eu4 no es UMV)', r_umv;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  UMV Rate     | Exp: <100 | Act: % | FAIL', r_umv;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO F: Solo gastos sin ingresos (eu2)
  -- Valida: income = 0, profit = negativo, expenses = 450.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO F: Solo gastos sin ingresos (eu2)';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu2, v_from, v_to);

  IF r_income = 0 AND r_expenses = 450 AND r_profit = -450 THEN
    RAISE NOTICE '  Income       | Exp: 0    | Act: % | OK', r_income;
    RAISE NOTICE '  Expenses     | Exp: 450  | Act: % | OK', r_expenses;
    RAISE NOTICE '  Profit       | Exp: -450 | Act: % | OK', r_profit;
    pass_count := pass_count + 3;
  ELSE
    RAISE NOTICE '  Income       | Exp: 0    | Act: % | %', r_income, CASE WHEN r_income=0 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Expenses     | Exp: 450  | Act: % | %', r_expenses, CASE WHEN r_expenses=450 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Profit       | Exp: -450 | Act: % | %', r_profit, CASE WHEN r_profit=-450 THEN 'OK' ELSE 'FAIL' END;
    fail_count := fail_count + 3;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO G: Solo ingresos sin gastos (eu3)
  -- Valida: expenses = 0, profit = income = 1500.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO G: Solo ingresos sin gastos (eu3)';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu3, v_from, v_to);

  IF r_income = 1500 AND r_expenses = 0 AND r_purchases = 0 AND r_profit = 1500 THEN
    RAISE NOTICE '  Income       | Exp: 1500 | Act: % | OK', r_income;
    RAISE NOTICE '  Expenses     | Exp: 0    | Act: % | OK', r_expenses;
    RAISE NOTICE '  Profit       | Exp: 1500 | Act: % | OK', r_profit;
    pass_count := pass_count + 3;
  ELSE
    RAISE NOTICE '  Income       | Exp: 1500 | Act: % | %', r_income, CASE WHEN r_income=1500 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Expenses     | Exp: 0    | Act: % | %', r_expenses, CASE WHEN r_expenses=0 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Profit       | Exp: 1500 | Act: % | %', r_profit, CASE WHEN r_profit=1500 THEN 'OK' ELSE 'FAIL' END;
    fail_count := fail_count + 3;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO I: Multi-tenant (eu6 aislado de eu5)
  -- Valida: Los datos de eu6 NO contaminan los de eu5 y viceversa.
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO I: Multi-tenant (eu5 vs eu6)';

  SELECT total_income INTO r_income FROM get_dashboard_financials(eu5, v_from, v_to);
  SELECT total_income INTO r_income2 FROM get_dashboard_financials(eu6, v_from, v_to);

  -- eu5: 20 ventas * 100 = 2000
  -- eu6: 1 venta * 999 = 999
  IF r_income = 2000 AND r_income2 = 999 THEN
    RAISE NOTICE '  eu5 Income   | Exp: 2000 | Act: % | OK', r_income;
    RAISE NOTICE '  eu6 Income   | Exp: 999  | Act: % | OK', r_income2;
    pass_count := pass_count + 2;
  ELSE
    RAISE NOTICE '  eu5 Income   | Exp: 2000 | Act: % | %', r_income, CASE WHEN r_income=2000 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  eu6 Income   | Exp: 999  | Act: % | %', r_income2, CASE WHEN r_income2=999 THEN 'OK' ELSE 'FAIL' END;
    fail_count := fail_count + 2;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO J: Alta carga (eu5 con 20 ventas + 10 gastos)
  -- Valida: Sumas correctas con volumen > 10 registros.
  --   Income = 20*100 = 2000, Expenses = 10*50 = 500, Profit = 1500
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO J: Alta carga (eu5: 20 ventas + 10 gastos)';

  SELECT total_income, total_expenses, total_purchases, net_profit
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(eu5, v_from, v_to);

  IF r_income = 2000 AND r_expenses = 500 AND r_purchases = 0 AND r_profit = 1500 THEN
    RAISE NOTICE '  Income       | Exp: 2000 | Act: % | OK', r_income;
    RAISE NOTICE '  Expenses     | Exp: 500  | Act: % | OK', r_expenses;
    RAISE NOTICE '  Profit       | Exp: 1500 | Act: % | OK', r_profit;
    pass_count := pass_count + 3;
  ELSE
    RAISE NOTICE '  Income       | Exp: 2000 | Act: % | %', r_income, CASE WHEN r_income=2000 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Expenses     | Exp: 500  | Act: % | %', r_expenses, CASE WHEN r_expenses=500 THEN 'OK' ELSE 'FAIL' END;
    RAISE NOTICE '  Profit       | Exp: 1500 | Act: % | %', r_profit, CASE WHEN r_profit=1500 THEN 'OK' ELSE 'FAIL' END;
    fail_count := fail_count + 3;
  END IF;

  -- Critical stock eu2: 1 producto critico (stock 5 <= min 10)
  r_stock := get_dashboard_critical_stock(eu2);
  RAISE NOTICE '';
  RAISE NOTICE 'CASO H: Stock critico por tenant';
  IF r_stock = 1 THEN
    RAISE NOTICE '  eu2 Stock    | Exp: 1 | Act: % | OK', r_stock;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  eu2 Stock    | Exp: 1 | Act: % | FAIL', r_stock;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CASO K: Datos NULL / faltantes
  -- Valida: get_admin_insights_breakdown agrupa eventos sin type como
  --   'uncategorized'. Un event_data NULL y un '{}' deben ambos caer
  --   en esa categoría gracias a COALESCE(event_data->>'type', 'uncategorized').
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE 'CASO K: Datos NULL / faltantes (insights sin type)';

  SELECT total INTO r_insight_uncat
    FROM get_admin_insights_breakdown(v_from, v_to)
    WHERE insight_type = 'uncategorized';
  r_insight_uncat := COALESCE(r_insight_uncat, 0);

  IF r_insight_uncat >= 2 THEN
    RAISE NOTICE '  uncategorized| Exp: >=2 | Act: % | OK', r_insight_uncat;
    pass_count := pass_count + 1;
  ELSE
    RAISE NOTICE '  uncategorized| Exp: >=2 | Act: % | FAIL', r_insight_uncat;
    fail_count := fail_count + 1;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- RESUMEN FINAL
  -- ═══════════════════════════════════════════════════════════════════════
  RAISE NOTICE '';
  RAISE NOTICE '========================================================';
  RAISE NOTICE '  RESULTADO: % PASS / % FAIL', pass_count, fail_count;
  IF fail_count = 0 THEN
    RAISE NOTICE '  VEREDICTO: ALL EDGE CASES PASSED';
  ELSE
    RAISE NOTICE '  VEREDICTO: HAY FALLOS - REVISAR';
  END IF;
  RAISE NOTICE '========================================================';

END;
$$;
