-- ==============================================================================
-- Fase 3: Validación de KPIs (Expected vs Actual)
-- ==============================================================================
-- Este script inserta mock data determinística y ejecuta los RPCs para comparar
-- los resultados con los cálculos manuales esperados.
-- 
-- Ejecución requerida: supabase db psql -f supabase/tests/test_kpis.sql

DO $$
DECLARE
  v_date_from timestamptz := now() - interval '1 day';
  v_date_to timestamptz := now() + interval '1 day';
  v_u1 uuid := 'a0000000-0000-0000-0000-000000000001';
  v_u2 uuid := 'a0000000-0000-0000-0000-000000000002';
  v_u3 uuid := 'a0000000-0000-0000-0000-000000000003';
  v_u4 uuid := 'a0000000-0000-0000-0000-000000000004';
  v_u5 uuid := 'a0000000-0000-0000-0000-000000000005';
  v_p1 uuid := 'b0000000-0000-0000-0000-000000000001';
  v_prod1 uuid := 'c0000000-0000-0000-0000-000000000001';
  v_prod2 uuid := 'c0000000-0000-0000-0000-000000000002';
  
  -- Valores Esperados (Manuales)
  -- Financials (User 1)
  m_income numeric := 700;
  m_expenses numeric := 100;
  m_purchases numeric := 150;
  m_profit numeric := 450;
  -- Stock
  m_critical_stock bigint := 1;
  -- Cohorts & Admin
  -- Activation: Registrados en perido (5) | con first_operation (3) -> 3/5 = 60.00
  m_activation numeric := 60.00;
  -- UMV: Activados (3) | con insight_generated (2) -> 2/3 = 66.67
  m_umv numeric := 66.67;
  -- Conversion: Pro (2) / Total (5) -> 40.00
  m_conversion numeric := 40.00;
  -- Community: 1 post + 2 replies = 3
  m_community bigint := 3;
  -- Insights Breakdown: alert=1, opportunity=1
  m_insight_alert bigint := 1;
  m_insight_opp bigint := 1;
  
  -- Variables para Resultados de RPCs
  r_income numeric;
  r_expenses numeric;
  r_purchases numeric;
  r_profit numeric;
  r_critical_stock bigint;
  r_activation numeric;
  r_umv numeric;
  r_conversion numeric;
  r_community bigint;
  r_insight_alert_res bigint;
  r_insight_opp_res bigint;
BEGIN
  -------------------------------------------------------------------------------
  -- 1. LIMPIEZA DE DATOS PREVIOS (Reversibilidad)
  -------------------------------------------------------------------------------
  RAISE NOTICE 'Limpiando datos de prueba (test_kpi_)...';
  DELETE FROM public.replies WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.posts WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.products WHERE name LIKE 'test_kpi_%';
  DELETE FROM public.sales WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.expenses WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.purchases WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.analytics_events WHERE user_id IN (v_u1, v_u2, v_u3, v_u4, v_u5);
  DELETE FROM public.profiles WHERE name LIKE 'test_kpi_%';
  DELETE FROM auth.users WHERE email LIKE 'test_kpi_%';

  -------------------------------------------------------------------------------
  -- 2. INSERCIÓN DE MOCK DATA (Determinística)
  -------------------------------------------------------------------------------
  RAISE NOTICE 'Insertando mock data...';
  -- 2.1 Usuarios
  INSERT INTO auth.users (id, aud, role, email) VALUES 
  (v_u1, 'authenticated', 'authenticated', 'test_kpi_1@example.com'),
  (v_u2, 'authenticated', 'authenticated', 'test_kpi_2@example.com'),
  (v_u3, 'authenticated', 'authenticated', 'test_kpi_3@example.com'),
  (v_u4, 'authenticated', 'authenticated', 'test_kpi_4@example.com'),
  (v_u5, 'authenticated', 'authenticated', 'test_kpi_5@example.com');

  -- 2.2 Perfiles (Conversión a Pago)
  -- El trigger on_auth_user_created ya insertó las filas en public.profiles.
  -- Se actualiza en lugar de insertar para evitar duplicate key en profiles_pkey.
  --
  -- ⚠️ SOLO PARA TEST LOCAL: Se deshabilita temporalmente el trigger de seguridad
  -- que bloquea la modificación directa de profiles.plan. Se rehabilita inmediatamente.
  EXECUTE 'ALTER TABLE public.profiles DISABLE TRIGGER trg_prevent_profile_escalation';

  UPDATE public.profiles SET
    name = CASE id
      WHEN v_u1 THEN 'test_kpi_user1'
      WHEN v_u2 THEN 'test_kpi_user2'
      WHEN v_u3 THEN 'test_kpi_user3'
      WHEN v_u4 THEN 'test_kpi_user4'
      WHEN v_u5 THEN 'test_kpi_user5'
    END,
    plan = CASE id
      WHEN v_u1 THEN 'pro'::user_plan
      WHEN v_u2 THEN 'free'::user_plan
      WHEN v_u3 THEN 'free'::user_plan
      WHEN v_u4 THEN 'pro'::user_plan
      WHEN v_u5 THEN 'free'::user_plan
    END,
    created_at = now()
  WHERE id IN (v_u1, v_u2, v_u3, v_u4, v_u5);

  -- ⚠️ SOLO PARA TEST LOCAL: Trigger de seguridad rehabilitado inmediatamente.
  EXECUTE 'ALTER TABLE public.profiles ENABLE TRIGGER trg_prevent_profile_escalation';

  -- 2.3 Productos (Critical Stock) - Insertados antes para Foreign Keys
  INSERT INTO public.products (id, user_id, name, stock, min_stock, price, cost, category, is_variant) VALUES
  (v_prod1, v_u1, 'test_kpi_prod_1', 5, 10, 100, 50, 'General', false), -- Crítico (5 <= 10)
  (v_prod2, v_u1, 'test_kpi_prod_2', 15, 10, 100, 50, 'General', false); -- OK (15 > 10)

  -- 2.4 Operaciones Financieras (Ganancia, Ingresos, Gastos)
  INSERT INTO public.sales (user_id, amount, quantity, date, product_id, currency) VALUES 
  (v_u1, 500, 1, now(), v_prod1, 'ARS'),
  (v_u1, 200, 1, now(), v_prod2, 'ARS');

  INSERT INTO public.expenses (user_id, amount, description, date, category) VALUES 
  (v_u1, 100, 'test_kpi_exp', now(), 'General');

  INSERT INTO public.purchases (user_id, amount, quantity, date, product_id) VALUES 
  (v_u1, 150, 1, now(), v_prod1);


  -- 2.5 Eventos (Activación y UMV)
  -- 3 Activados (u1, u2, u4)
  INSERT INTO public.analytics_events (user_id, event_name, created_at) VALUES
  (v_u1, 'first_operation', now()),
  (v_u2, 'first_operation', now()),
  (v_u4, 'first_operation', now());

  -- 2 Alcanzaron UMV (u1, u4)
  INSERT INTO public.analytics_events (user_id, event_name, event_data, created_at) VALUES
  (v_u1, 'insight_generated', '{"type": "alert"}', now()),
  (v_u4, 'insight_generated', '{"type": "opportunity"}', now());

  -- 2.6 Interacciones de Comunidad
  INSERT INTO public.posts (id, user_id, title, content, created_at, category) VALUES 
  (v_p1, v_u1, 'test_kpi_title', 'test_kpi_post', now(), 'General');
  
  INSERT INTO public.replies (post_id, user_id, content, created_at) VALUES 
  (v_p1, v_u2, 'test_kpi_reply1', now()),
  (v_p1, v_u3, 'test_kpi_reply2', now());

  -------------------------------------------------------------------------------
  -- 3. CÁLCULO MEDIANTE RPCS
  -------------------------------------------------------------------------------
  RAISE NOTICE 'Ejecutando RPCs...';
  SELECT total_income, total_expenses, total_purchases, net_profit 
    INTO r_income, r_expenses, r_purchases, r_profit
    FROM get_dashboard_financials(v_u1, v_date_from, v_date_to);
  
  r_critical_stock := get_dashboard_critical_stock(v_u1);
  r_activation := get_admin_activation_rate(v_date_from, v_date_to);
  r_umv := get_admin_umv_rate(v_date_from, v_date_to);
  r_conversion := get_admin_paid_conversion_rate();
  r_community := get_admin_community_interactions(v_date_from, v_date_to);
  
  SELECT total INTO r_insight_alert_res FROM get_admin_insights_breakdown(v_date_from, v_date_to) WHERE insight_type = 'alert';
  SELECT total INTO r_insight_opp_res FROM get_admin_insights_breakdown(v_date_from, v_date_to) WHERE insight_type = 'opportunity';

  r_insight_alert_res := COALESCE(r_insight_alert_res, 0);
  r_insight_opp_res := COALESCE(r_insight_opp_res, 0);

  -------------------------------------------------------------------------------
  -- 4. REPORTE DE COMPARACIÓN
  -------------------------------------------------------------------------------
  RAISE NOTICE '=======================================================';
  RAISE NOTICE '                 REPORTE DE VALIDACION                 ';
  RAISE NOTICE '=======================================================';
  
  RAISE NOTICE '1. FINANCIALS (User 1)';
  RAISE NOTICE '  - Income    | Exp: % | Act: % | Dif: % | %', m_income, r_income, m_income - r_income, CASE WHEN m_income = r_income THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Expenses  | Exp: % | Act: % | Dif: % | %', m_expenses, r_expenses, m_expenses - r_expenses, CASE WHEN m_expenses = r_expenses THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Purchases | Exp: % | Act: % | Dif: % | %', m_purchases, r_purchases, m_purchases - r_purchases, CASE WHEN m_purchases = r_purchases THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Profit    | Exp: % | Act: % | Dif: % | %', m_profit, r_profit, m_profit - r_profit, CASE WHEN m_profit = r_profit THEN '✅ OK' ELSE '❌ FAIL' END;

  RAISE NOTICE '2. CRITICAL STOCK (User 1)';
  RAISE NOTICE '  - Count     | Exp: % | Act: % | Dif: % | %', m_critical_stock, r_critical_stock, m_critical_stock - r_critical_stock, CASE WHEN m_critical_stock = r_critical_stock THEN '✅ OK' ELSE '❌ FAIL' END;

  RAISE NOTICE '3. ADMIN KPIS (Cohortes & Instantáneas)';
  RAISE NOTICE '  - Act. Rate | Exp: % | Act: % | Dif: % | %', m_activation, r_activation, m_activation - r_activation, CASE WHEN m_activation = r_activation THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - UMV Rate  | Exp: % | Act: % | Dif: % | %', m_umv, r_umv, m_umv - r_umv, CASE WHEN m_umv = r_umv THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Paid Conv.| Exp: % | Act: % | Dif: % | %', m_conversion, r_conversion, m_conversion - r_conversion, CASE WHEN m_conversion = r_conversion THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Community | Exp: % | Act: % | Dif: % | %', m_community, r_community, m_community - r_community, CASE WHEN m_community = r_community THEN '✅ OK' ELSE '❌ FAIL' END;

  RAISE NOTICE '4. INSIGHTS BREAKDOWN';
  RAISE NOTICE '  - Alert     | Exp: % | Act: % | Dif: % | %', m_insight_alert, r_insight_alert_res, m_insight_alert - r_insight_alert_res, CASE WHEN m_insight_alert = r_insight_alert_res THEN '✅ OK' ELSE '❌ FAIL' END;
  RAISE NOTICE '  - Opport.   | Exp: % | Act: % | Dif: % | %', m_insight_opp, r_insight_opp_res, m_insight_opp - r_insight_opp_res, CASE WHEN m_insight_opp = r_insight_opp_res THEN '✅ OK' ELSE '❌ FAIL' END;

  RAISE NOTICE '=======================================================';
  RAISE NOTICE 'Script finalizado.';
  
  -- Cleanup opcional aquí si fuera estrictamente temporal, pero
  -- como el inicio del script borra el "test_kpi_%", se puede inspeccionar
  -- la BD manualmente si hubo un error.
END;
$$;
