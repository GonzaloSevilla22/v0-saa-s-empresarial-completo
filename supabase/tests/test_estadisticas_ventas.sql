-- =============================================================================
-- GATE: test_estadisticas_ventas.sql
-- CHANGE: estadisticas-ventas — Etapa E1 (tasks 2.1 / 2.12 / 2.15 / 11.2 / 11.3)
--
-- Verifica el read-model del módulo de estadísticas de ventas:
--   (introspección) helper canónico + clamp de plan + rpc_sales_evolution +
--   rpc_product_ranking existen; las RPCs son SECURITY DEFINER con search_path
--   fijado y ACLs exactas (anon sin EXECUTE, authenticated con EXECUTE); los
--   helpers NO son ejecutables por anon/authenticated (toman p_account_id);
--   rpc_product_profitability, rpc_product_ranking y rpc_sales_evolution
--   consumen el helper canónico (D1/D2); la evolución resta NC vía
--   reporting_credit_notes_in_window (D7); el clamp vive en reporting_plan_window
--   sobre get_effective_plan + reporting_local_today (D8); NINGÚN cuerpo aplica
--   AT TIME ZONE sobre la fecha de negocio `sales.date` (D3, invariante nuevo de
--   reporting-invariants); el índice idx_sales_account_date existe (D10).
--   (comportamiento) con anchor sintético y sesión vía request.jwt.claims:
--   revenue de línea = COALESCE(total, amount); borde superior incluido
--   completo y el día siguiente excluido; operación multi-línea cuenta 1 y la
--   venta legacy sin operation_id cuenta 1; semana ISO (domingo y lunes en
--   semanas distintas); NC restada en la evolución y no en el ranking; línea
--   de servicio dentro de la facturación y fuera del ranking, con su importe
--   declarado; variantes agrupadas bajo el padre con variant_count; variante
--   huérfana agrupa bajo sí misma; ranking por unidades ≠ por importe; margen
--   con cascada snapshot→products.cost y cobertura de snapshot; paginación
--   sobre el conjunto completo con total_count; suma de buckets = total del
--   período en las tres granularidades; el total del módulo coincide con
--   rpc_dashboard_kpi_summary.invoiced_revenue sobre la misma ventana (11.3);
--   rpc_product_profitability ≡ ranking en revenue/unidades y last_sale_date
--   SIN corrimiento (OQ-3, 2.15); clamp de plan recorta, declara la ventana y
--   es fail-closed; P0400 / P0401.
--
-- ⚠️ REGLA: se asserta el EFECTO (filas, totales, fechas exactas), nunca
-- "no hubo error". Degrade-don't-fail sólo si el anchor no se aprovisiona o
-- auth.uid() no resuelve bajo request.jwt.claims local (NOTICE, no aborta).
-- Cleanup: DO block separado al final, resuelve por email.
-- =============================================================================

-- ── 1. Introspección ────────────────────────────────────────────────────────
DO $$
DECLARE
  v_sig     text;
  v_oid     oid;
  v_secdef  boolean;
  v_config  text[];
  v_acl     aclitem[];
  v_def     text;
  v_rpcs    text[] := ARRAY[
    'public.rpc_sales_evolution(uuid,date,date,text,uuid,text)',
    'public.rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,integer)',
    'public.rpc_product_profitability(integer)'
  ];
  v_helpers text[] := ARRAY[
    'public.reporting_sales_lines_in_window(uuid,date,date,uuid,text)',
    'public.reporting_plan_window(uuid,date,date)'
  ];
  v_business_date_fns text[] := ARRAY[
    'public.reporting_sales_lines_in_window(uuid,date,date,uuid,text)',
    'public.rpc_sales_evolution(uuid,date,date,text,uuid,text)',
    'public.rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,integer)',
    'public.rpc_product_profitability(integer)'
  ];
BEGIN
  -- (a) RPCs: existencia, SECURITY DEFINER, search_path, ACLs exactas.
  FOREACH v_sig IN ARRAY v_rpcs LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (existencia): % no existe.', v_sig;
    END IF;
    SELECT p.prosecdef, p.proconfig, p.proacl INTO v_secdef, v_config, v_acl
    FROM pg_proc p WHERE p.oid = v_oid;
    IF NOT v_secdef THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (secdef): % debe ser SECURITY DEFINER.', v_sig;
    END IF;
    IF v_config IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search_path=%') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (search_path): % no fija search_path.', v_sig;
    END IF;
    IF v_acl IS NULL THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (acl): % tiene proacl NULL — falta el REVOKE ALL FROM PUBLIC.', v_sig;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (acl): anon NO debe poder ejecutar %.', v_sig;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (acl): authenticated debe poder ejecutar %.', v_sig;
    END IF;
  END LOOP;

  -- (b) Helpers con p_account_id: NUNCA ejecutables por anon/authenticated
  --     (la tenencia la valida la RPC SECURITY DEFINER que los envuelve).
  FOREACH v_sig IN ARRAY v_helpers LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (existencia): % no existe.', v_sig;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (acl): el helper % toma p_account_id y NO debe ser ejecutable por anon/authenticated.', v_sig;
    END IF;
  END LOOP;

  -- (c) De-duplicación real (D1/D2): los tres read-models consumen el helper.
  FOREACH v_sig IN ARRAY v_rpcs LOOP
    v_def := pg_get_functiondef(to_regprocedure(v_sig));
    IF v_def !~ 'reporting_sales_lines_in_window' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (helper): % no consume reporting_sales_lines_in_window (D1/D2).', v_sig;
    END IF;
  END LOOP;

  -- (d) La evolución resta NC por el helper compartido (D7) y ambas RPCs
  --     nuevas aplican el clamp por reporting_plan_window (D8).
  v_def := pg_get_functiondef(to_regprocedure('public.rpc_sales_evolution(uuid,date,date,text,uuid,text)'));
  IF v_def !~ 'reporting_credit_notes_in_window' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (nc): rpc_sales_evolution no resta NC vía reporting_credit_notes_in_window (D7).';
  END IF;
  IF v_def !~ 'reporting_plan_window' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): rpc_sales_evolution no aplica reporting_plan_window (D8).';
  END IF;
  v_def := pg_get_functiondef(to_regprocedure('public.rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,integer,integer)'));
  IF v_def !~ 'reporting_plan_window' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): rpc_product_ranking no aplica reporting_plan_window (D8).';
  END IF;
  v_def := pg_get_functiondef(to_regprocedure('public.reporting_plan_window(uuid,date,date)'));
  IF v_def !~ 'get_effective_plan' OR v_def !~ 'reporting_local_today' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): reporting_plan_window debe resolver el plan con get_effective_plan y anclar a reporting_local_today (D8, RN-D5).';
  END IF;

  -- (e) Invariante nuevo (reporting-invariants): NADIE convierte de zona la
  --     fecha de negocio `sales.date`. El patrón cubre `s.date AT TIME ZONE`
  --     y `MAX(s.date) AT TIME ZONE`; `created_at AT TIME ZONE` (instante)
  --     sigue permitido.
  FOREACH v_sig IN ARRAY v_business_date_fns LOOP
    v_def := pg_get_functiondef(to_regprocedure(v_sig));
    IF v_def ~* '\.date\s*\)?\s*AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (fecha de negocio): % aplica AT TIME ZONE sobre sales.date — corre cada venta un día atrás (D3).', v_sig;
    END IF;
  END LOOP;

  -- (f) Índice (D10).
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'sales' AND indexname = 'idx_sales_account_date'
      AND indexdef ~* '\(account_id, date DESC\)'
  ) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (índice): idx_sales_account_date (account_id, date DESC) no existe.';
  END IF;

  RAISE NOTICE 'PASS (introspección): helper + clamp + 2 RPCs + profitability de-duplicada, ACLs exactas, sin AT TIME ZONE sobre la fecha de negocio, índice presente.';
END $$;

-- ── 2. Comportamiento con anchor sintético ──────────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'estadisticas-ventas-gate@test.local';
  v_intruder_email text := 'estadisticas-ventas-gate-intruder@test.local';
  v_user      uuid;
  v_intruder  uuid;
  v_account   uuid;
  v_branch    uuid;
  v_today     date;
  v_monday    date;  -- lunes de la semana ISO de hoy (<= hoy)
  v_sunday    date;  -- domingo anterior
  v_sat       date;
  v_fri       date;
  v_start     date;
  v_end       date;
  v_p_parent  uuid; v_p_v1 uuid; v_p_v2 uuid; v_p_simple uuid; v_p_orphan uuid;
  v_client    uuid; v_ca uuid;
  v_sale_a    uuid;
  v_op1 uuid := gen_random_uuid(); v_op2 uuid := gen_random_uuid(); v_op3 uuid := gen_random_uuid();
  v_op4 uuid := gen_random_uuid(); v_op5 uuid := gen_random_uuid(); v_op6 uuid := gen_random_uuid();
  v_row       record;
  v_row2      record;
  v_count     integer;
  v_sum       numeric;
  v_expected  numeric;
  v_kpi       record;
  v_sqlstate  text;
BEGIN
  -- ── Setup: anchors con provisioning automático (handle_new_user), resueltos
  -- por email ANTES de insertar (idempotente sobre la DB local compartida). ──
  SELECT id INTO v_user FROM auth.users WHERE email = v_anchor_email;
  IF v_user IS NULL THEN
    v_user := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas'));
  END IF;
  SELECT id INTO v_intruder FROM auth.users WHERE email = v_intruder_email;
  IF v_intruder IS NULL THEN
    v_intruder := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_intruder, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas Intruder'));
  END IF;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE ESTADISTICAS: anchor sin cuenta aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  -- Limpieza de restos de una corrida previa cortada (los totales son exactos).
  DELETE FROM public.customer_account_movements WHERE account_id = v_account;
  DELETE FROM public.customer_accounts WHERE account_id = v_account;
  DELETE FROM public.clients WHERE account_id = v_account AND name LIKE '__gate_ev_%';
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
  DELETE FROM public.sales WHERE account_id = v_account;
  DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_ev_%' AND parent_id IS NOT NULL;
  DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_ev_%';

  -- Plan 'pro' explícito (1825 días de historial): los asserts de negocio no
  -- deben depender del trial que handle_new_user pueda o no sembrar.
  UPDATE public.accounts
     SET billing_plan = 'pro', billing_status = 'active', trial_plan = NULL,
         trial_expires_at = NULL, plan_expires_at = NULL, billing_exempt = false
   WHERE id = v_account;

  -- ── Fechas relativas (fecha de negocio = día calendario, a medianoche UTC) ─
  v_today  := public.reporting_local_today();
  v_monday := date_trunc('week', v_today::timestamp)::date;  -- lunes ISO
  v_sunday := v_monday - 1;
  v_sat    := v_monday - 2;
  v_fri    := v_monday - 3;
  v_start  := v_today - 10;   -- ventana de 11 días: contiene v_fri..v_today
  v_end    := v_today;

  -- ── Fixture: productos ────────────────────────────────────────────────────
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_ev_padre__', 1000, 0) RETURNING id INTO v_p_parent;
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant)
  VALUES (v_user, v_account, '__gate_ev_variante_1__', 500, 80, v_p_parent, true) RETURNING id INTO v_p_v1;
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant)
  VALUES (v_user, v_account, '__gate_ev_variante_2__', 700, 90, v_p_parent, true) RETURNING id INTO v_p_v2;
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_ev_simple__', 1000, 100) RETURNING id INTO v_p_simple;
  -- Variante huérfana: parent_id NULL (el padre se borró → ON DELETE SET NULL).
  INSERT INTO public.products (user_id, account_id, name, price, cost, parent_id, is_variant)
  VALUES (v_user, v_account, '__gate_ev_huerfana__', 700, 10, NULL, true) RETURNING id INTO v_p_orphan;

  -- ── Fixture: ventas (date = fecha de negocio a 00:00 UTC, como prod) ──────
  -- A: simple, 2 u × $1000 = $2000, sábado, op1, snapshot de costo 600.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_simple, 1000, 2, 2000, v_sat::timestamp AT TIME ZONE 'UTC', v_op1)
  RETURNING id INTO v_sale_a;
  INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot)
  VALUES (v_sale_a, v_p_simple, v_account, 2, 1000, 2000, 600);
  -- B: variante 1, $500, sábado, MISMA operación op1 (multi-línea cuenta 1).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_v1, 500, 1, 500, v_sat::timestamp AT TIME ZONE 'UTC', v_op1);
  -- C: variante 2, 3 u × $700 = $2100, DOMINGO, op2.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_v2, 700, 3, 2100, v_sunday::timestamp AT TIME ZONE 'UTC', v_op2);
  -- D: línea de SERVICIO (product_id NULL), $400, sábado, op3.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, NULL, 400, 1, 400, v_sat::timestamp AT TIME ZONE 'UTC', v_op3);
  -- E: huérfana, $700, ÚLTIMO día del rango (incluido completo), op4.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_orphan, 700, 1, 700, v_end::timestamp AT TIME ZONE 'UTC', v_op4);
  -- F: huérfana, $999, día SIGUIENTE al rango (excluido).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_orphan, 999, 1, 999, (v_end + 1)::timestamp AT TIME ZONE 'UTC', gen_random_uuid());
  -- G: simple, legacy SIN operation_id y SIN total (revenue = amount = 250), viernes.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_simple, 250, 1, NULL, v_fri::timestamp AT TIME ZONE 'UTC', NULL);
  -- H: simple, 2 u × $50 = $100, LUNES (abre la semana siguiente), op5.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_simple, 50, 2, 100, v_monday::timestamp AT TIME ZONE 'UTC', v_op5);
  -- Z: simple, $333, período ANTERIOR (hoy-15), op6.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch, v_p_simple, 333, 1, 333, (v_today - 15)::timestamp AT TIME ZONE 'UTC', v_op6);

  -- ── Fixture: nota de crédito de $150 el sábado (instante a las 12:00 UTC) ─
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account, v_user, '__gate_ev_cliente__') RETURNING id INTO v_client;
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account, v_client, 0, v_user) RETURNING id INTO v_ca;
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by, created_at)
  VALUES (v_ca, v_account, -150, 0, 'credit_note', v_user, (v_sat::timestamp + interval '12 hours') AT TIME ZONE 'UTC');

  -- ── Autorización: intruso no miembro → P0401 en las dos RPCs ─────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_intruder::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_intruder THEN
    RAISE NOTICE 'GATE ESTADISTICAS: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN;
  END IF;
  BEGIN
    PERFORM * FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (P0401): rpc_sales_evolution aceptó a un no miembro.';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0);
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (P0401): rpc_product_ranking aceptó a un no miembro.';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0401): no miembro rechazado en evolución y ranking.';

  -- ── Sesión del anchor ────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ── P0400: bucket / orden fuera de dominio, rango invertido ──────────────
  BEGIN
    PERFORM * FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'hour', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (P0400): p_bucket=hour aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_product_ranking(v_account, v_start, v_end, 'banana', true, NULL, NULL, 50, 0);
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (P0400): p_order_by=banana aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_evolution(v_account, v_end, v_start, 'day', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (P0400): rango invertido aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0400): bucket, orden y rango fuera de dominio rechazados.';

  -- ══ EVOLUCIÓN DIARIA ══════════════════════════════════════════════════════
  -- Fila total del período: 250+2000+500+400+2100+100+700 = 6050; NC 150;
  -- neto 5900; unidades 11; operaciones 6 (G legacy cuenta 1, op1 multi-línea
  -- cuenta 1); servicio 400. F (día siguiente) queda fuera, E (último día) dentro.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.period = 'current';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): falta la fila period=current.';
  END IF;
  IF v_row.revenue <> 6050 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): revenue del período fue % y esperaba 6050 (COALESCE(total, amount), borde superior incluido, día siguiente excluido).', v_row.revenue;
  END IF;
  IF v_row.credit_notes <> 150 OR v_row.net_revenue <> 5900 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución/NC): credit_notes=% net=% y esperaba 150/5900 (D7).', v_row.credit_notes, v_row.net_revenue;
  END IF;
  IF v_row.units <> 11 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): units fue % y esperaba 11.', v_row.units;
  END IF;
  IF v_row.operations <> 6 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): operations fue % y esperaba 6 (multi-línea cuenta 1, legacy sin operation_id cuenta 1).', v_row.operations;
  END IF;
  IF v_row.service_revenue <> 400 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): service_revenue fue % y esperaba 400 (D6: la línea de servicio SÍ factura).', v_row.service_revenue;
  END IF;
  IF v_row.window_start <> v_start OR v_row.window_end <> v_end OR v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ventana): plan pro no debe recortar 11 días (start=% end=% clamped=%).', v_row.window_start, v_row.window_end, v_row.window_clamped;
  END IF;

  -- Buckets diarios: 11 filas, zero-filled.
  SELECT count(*) INTO v_count FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r WHERE r.period = 'bucket';
  IF v_count <> 11 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (evolución): esperaba 11 buckets diarios y hubo % (deben rellenarse en cero).', v_count;
  END IF;
  -- Sábado: 2000+500+400 = 2900, 2 operaciones (op1 y op3), NC 150 → neto 2750.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.period = 'bucket' AND r.bucket_start = v_sat;
  IF v_row.revenue <> 2900 OR v_row.operations <> 2 OR v_row.units <> 4 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (bucket sábado): revenue=% ops=% units=% y esperaba 2900/2/4.', v_row.revenue, v_row.operations, v_row.units;
  END IF;
  IF v_row.credit_notes <> 150 OR v_row.net_revenue <> 2750 OR v_row.service_revenue <> 400 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (bucket sábado): nc=% net=% svc=% y esperaba 150/2750/400.', v_row.credit_notes, v_row.net_revenue, v_row.service_revenue;
  END IF;
  -- Viernes (legacy sin total ni operation_id): 250 / 1 operación.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.period = 'bucket' AND r.bucket_start = v_fri;
  IF v_row.revenue <> 250 OR v_row.operations <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (bucket viernes): revenue=% ops=% y esperaba 250/1 (amount como fallback, legacy cuenta 1).', v_row.revenue, v_row.operations;
  END IF;
  -- Un día sin ventas del rango informa cero, no se omite.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.period = 'bucket' AND r.bucket_start = v_today - 9;
  IF NOT FOUND OR v_row.revenue <> 0 OR v_row.operations <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (bucket vacío): el día % debe existir en cero.', v_today - 9;
  END IF;
  -- Sin corrimiento de zona (D3): el jueves anterior al viernes legacy no
  -- tiene ventas; un AT TIME ZONE sobre sales.date correría la de G a ese día.
  IF EXISTS (SELECT 1 FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
             WHERE r.period = 'bucket' AND r.bucket_start = v_fri - 1 AND r.revenue <> 0) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (D3): hay revenue el jueves % que no le corresponde — la fecha de negocio se corrió un día.', v_fri - 1;
  END IF;

  -- Período anterior (hoy-21 .. hoy-11): sólo Z = 333.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.period = 'previous';
  IF NOT FOUND OR v_row.revenue <> 333 OR v_row.operations <> 1 OR v_row.bucket_start <> v_today - 21 OR v_row.bucket_end <> v_today - 11 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (previous): revenue=% ops=% [% .. %] y esperaba 333/1 [% .. %].',
      v_row.revenue, v_row.operations, v_row.bucket_start, v_row.bucket_end, v_today - 21, v_today - 11;
  END IF;
  RAISE NOTICE 'PASS (evolución diaria): total 6050/150/5900, 11 buckets, sábado 2900/2, legacy 250/1, previous 333.';

  -- ══ SEMANA ISO (lunes) ════════════════════════════════════════════════════
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'week', NULL, NULL) r
  WHERE r.period = 'bucket' AND r.bucket_start = v_monday - 7;
  IF NOT FOUND OR v_row.revenue <> 5250 OR v_row.operations <> 4 OR v_row.credit_notes <> 150 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (semana): la semana del % debía sumar 5250/4 ops/NC 150 (viernes+sábado+DOMINGO) y dio %/%/%.',
      v_monday - 7, v_row.revenue, v_row.operations, v_row.credit_notes;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'week', NULL, NULL) r
  WHERE r.period = 'bucket' AND r.bucket_start = v_monday;
  IF NOT FOUND OR v_row.revenue <> 800 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (semana): la semana que abre el LUNES % debía sumar 800/2 ops (H + E) y dio %/%.',
      v_monday, v_row.revenue, v_row.operations;
  END IF;
  RAISE NOTICE 'PASS (semana ISO): domingo y lunes en semanas distintas; el lunes abre la siguiente.';

  -- ══ Identidad suma de buckets = total, en las tres granularidades ═════════
  FOREACH v_sqlstate IN ARRAY ARRAY['day','week','month'] LOOP
    SELECT SUM(r.revenue), SUM(r.credit_notes) INTO v_sum, v_expected
    FROM public.rpc_sales_evolution(v_account, v_start, v_end, v_sqlstate, NULL, NULL) r WHERE r.period = 'bucket';
    IF v_sum <> 6050 OR v_expected <> 150 THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (identidad %): suma de buckets %/% ≠ total 6050/150.', v_sqlstate, v_sum, v_expected;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (identidad): suma de buckets = total en día/semana/mes.';

  -- ══ 11.3 — Coincide con el Tablero sobre la misma ventana ═════════════════
  SELECT * INTO v_kpi FROM public.rpc_dashboard_kpi_summary(
    v_start::timestamp AT TIME ZONE 'UTC',
    ((v_end + 1)::timestamp AT TIME ZONE 'UTC') - interval '1 microsecond',
    (v_today - 21)::timestamp AT TIME ZONE 'UTC',
    ((v_today - 10)::timestamp AT TIME ZONE 'UTC') - interval '1 microsecond',
    NULL);
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r WHERE r.period = 'current';
  IF v_kpi.invoiced_revenue <> v_row.net_revenue OR v_kpi.sales_count <> v_row.operations THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (11.3 Tablero): kpi invoiced=% ops=% vs módulo net=% ops=% — dos pantallas del mismo sistema informan cifras distintas.',
      v_kpi.invoiced_revenue, v_kpi.sales_count, v_row.net_revenue, v_row.operations;
  END IF;
  RAISE NOTICE 'PASS (11.3): el módulo coincide con rpc_dashboard_kpi_summary (neto % / % ops).', v_row.net_revenue, v_row.operations;

  -- ══ RANKING AGRUPADO POR UNIDADES ═════════════════════════════════════════
  -- simple S = 5 u / $2350; padre P = 4 u / $2600 (V1 1u + V2 3u); huérfana O = 1 u / $700.
  SELECT count(*) INTO v_count FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0);
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking): esperaba 3 filas agrupadas y hubo % (¿la línea de servicio entró al ranking?).', v_count;
  END IF;
  IF EXISTS (SELECT 1 FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r WHERE r.product_id IS NULL) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking): una fila representa la línea de servicio (product_id NULL) — D6.';
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r WHERE r.rank = 1;
  IF v_row.product_id <> v_p_simple OR v_row.units <> 5 OR v_row.revenue <> 2350 OR v_row.operations <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking units #1): esperaba simple 5u/2350/3 ops y fue % %u/%/% ops.', v_row.product_name, v_row.units, v_row.revenue, v_row.operations;
  END IF;
  IF v_row.total_count <> 3 OR v_row.window_start <> v_start OR v_row.window_end <> v_end THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking meta): total_count=% ventana [% .. %].', v_row.total_count, v_row.window_start, v_row.window_end;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r WHERE r.rank = 2;
  IF v_row.product_id <> v_p_parent OR v_row.units <> 4 OR v_row.revenue <> 2600 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking units #2): esperaba el PADRE 4u/2600/2 ops (V1+V2) y fue % %u/%/% ops.', v_row.product_name, v_row.units, v_row.revenue, v_row.operations;
  END IF;
  IF NOT v_row.is_group OR v_row.variant_count <> 2 OR v_row.product_name <> '__gate_ev_padre__' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (agrupación): la fila del padre debe declarar is_group y 2 variantes (is_group=% variant_count=% name=%).', v_row.is_group, v_row.variant_count, v_row.product_name;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r WHERE r.rank = 3;
  IF v_row.product_id <> v_p_orphan OR v_row.is_group OR v_row.revenue <> 700 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (huérfana): la variante sin padre debe agrupar bajo sí misma con $700 (fue % / %).', v_row.product_name, v_row.revenue;
  END IF;
  -- Última venta de S = lunes (H), sin corrimiento.
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_simple;
  IF v_row.last_sale_date <> v_monday THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking last_sale_date): fue % y esperaba % (D3).', v_row.last_sale_date, v_monday;
  END IF;
  RAISE NOTICE 'PASS (ranking por unidades): S 5u > P 4u (2 variantes) > O 1u; servicio fuera; huérfana bajo sí misma.';

  -- ══ RANKING POR IMPORTE: orden distinto (P 2600 > S 2350 > O 700) ═════════
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'revenue', true, NULL, NULL, 50, 0) r WHERE r.rank = 1;
  SELECT * INTO v_row2 FROM public.rpc_product_ranking(v_account, v_start, v_end, 'revenue', true, NULL, NULL, 50, 0) r WHERE r.rank = 2;
  IF v_row.product_id <> v_p_parent OR v_row2.product_id <> v_p_simple THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking revenue): esperaba PADRE (2600) > simple (2350) y fue % > %.', v_row.product_name, v_row2.product_name;
  END IF;
  RAISE NOTICE 'PASS (ranking por importe): el orden difiere del de unidades.';

  -- ══ MARGEN: cascada snapshot → products.cost, cobertura de snapshot ═══════
  -- S: A 600×2 (snapshot) + G 100×1 + H 100×2 (fallback) = 1500 → margen 850, cobertura 1/3 = 33.3.
  -- P: V1 80×1 + V2 90×3 = 350 → margen 2250, cobertura 0. O: 10 → 690.
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'margin', true, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_simple;
  IF v_row.total_cost <> 1500 OR v_row.gross_margin <> 850 OR v_row.cost_coverage_pct <> 33.3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (margen S): cost=% margin=% coverage=% y esperaba 1500/850/33.3 (snapshot congelado, fallback al catálogo sólo sin snapshot).', v_row.total_cost, v_row.gross_margin, v_row.cost_coverage_pct;
  END IF;
  IF v_row.gross_margin_pct <> ROUND(850.0 / 2350 * 100, 2) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (margen S): gross_margin_pct=% y esperaba %.', v_row.gross_margin_pct, ROUND(850.0 / 2350 * 100, 2);
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'margin', true, NULL, NULL, 50, 0) r WHERE r.rank = 1;
  IF v_row.product_id <> v_p_parent OR v_row.gross_margin <> 2250 OR v_row.cost_coverage_pct <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (ranking margen #1): esperaba PADRE 2250 / cobertura 0 y fue % % / %.', v_row.product_name, v_row.gross_margin, v_row.cost_coverage_pct;
  END IF;
  -- Remarcar el catálogo NO altera el margen de la línea con snapshot (RN-D2).
  UPDATE public.products SET cost = 900 WHERE id = v_p_simple;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'margin', true, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_simple;
  -- A sigue a 600×2 = 1200; G y H (sin snapshot) pasan a 900×1 + 900×2 = 2700 → 3900.
  IF v_row.total_cost <> 3900 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (RN-D2): tras remarcar a 900, cost=% y esperaba 3900 (1200 congelado + 2700 fallback).', v_row.total_cost;
  END IF;
  UPDATE public.products SET cost = 100 WHERE id = v_p_simple;
  RAISE NOTICE 'PASS (margen): cascada snapshot→catálogo, cobertura declarada, remarcar no toca el snapshot.';

  -- ══ SIN AGRUPAR: cada variante es una fila ════════════════════════════════
  SELECT count(*) INTO v_count FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', false, NULL, NULL, 50, 0);
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (sin agrupar): esperaba 4 filas (S, V2, V1, O) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', false, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_v1;
  IF NOT FOUND OR v_row.units <> 1 OR v_row.parent_id <> v_p_parent OR v_row.parent_name <> '__gate_ev_padre__' OR v_row.is_group OR v_row.variant_count <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (sin agrupar): V1 debía ser fila propia 1u con parent_id/parent_name del padre.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', false, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_parent) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (sin agrupar): el padre sin ventas propias no debe aparecer.';
  END IF;
  RAISE NOTICE 'PASS (sin agrupar): 4 filas, la variante lleva su padre como contexto.';

  -- ══ PAGINACIÓN sobre el conjunto completo ═════════════════════════════════
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 1, 1);
  IF v_row.product_id <> v_p_parent OR v_row.rank <> 2 OR v_row.total_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (paginación): limit 1 offset 1 debía devolver el #2 (padre) con total_count 3 y dio % #% / %.', v_row.product_name, v_row.rank, v_row.total_count;
  END IF;
  SELECT count(*) INTO v_count FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 1, 1);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (paginación): limit 1 devolvió % filas.', v_count;
  END IF;
  RAISE NOTICE 'PASS (paginación): orden resuelto sobre el conjunto completo, total_count viaja por fila.';

  -- ══ 2.15 / OQ-3 — rpc_product_profitability ≡ ranking y sin off-by-one ════
  -- Ventana de 30 días: S = A 2000 + G 250 + H 100 + Z 333 = 2683, 6 u,
  -- costo 1200 + 100 + 200 + 100 = 1600, última venta = lunes (H).
  SELECT * INTO v_row FROM public.rpc_product_profitability(30) r WHERE r.product_id = v_p_simple;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (profitability): no devolvió el producto simple.';
  END IF;
  IF v_row.total_revenue <> 2683 OR v_row.units_sold <> 6 OR v_row.total_cost <> 1600 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (profitability): revenue=% units=% cost=% y esperaba 2683/6/1600.', v_row.total_revenue, v_row.units_sold, v_row.total_cost;
  END IF;
  IF v_row.last_sale_date IS DISTINCT FROM v_monday THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (OQ-3 off-by-one): last_sale_date fue % y esperaba % — un % delata el AT TIME ZONE sobre la fecha de negocio.',
      v_row.last_sale_date, v_monday, v_monday - 1;
  END IF;
  SELECT * INTO v_row2 FROM public.rpc_product_ranking(v_account, v_today - 30, v_today, 'revenue', true, NULL, NULL, 50, 0) r WHERE r.product_id = v_p_simple;
  IF v_row2.revenue <> v_row.total_revenue OR v_row2.units <> v_row.units_sold OR v_row2.total_cost <> v_row.total_cost OR v_row2.last_sale_date <> v_row.last_sale_date THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (profitability ≡ ranking): ranking %/%/%/% vs profitability %/%/%/% — dos read-models sobre la misma población discrepan.',
      v_row2.revenue, v_row2.units, v_row2.total_cost, v_row2.last_sale_date, v_row.total_revenue, v_row.units_sold, v_row.total_cost, v_row.last_sale_date;
  END IF;
  RAISE NOTICE 'PASS (2.15/OQ-3): profitability 2683/6/1600, última venta el lunes % (sin corrimiento), igual al ranking.', v_monday;

  -- ══ CLAMP DE PLAN (D8): recorta, declara la ventana, fail-closed ══════════
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;   -- history_days 30
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_today - 400, v_today, 'day', NULL, NULL) r WHERE r.period = 'current';
  IF v_row.window_start <> v_today - 30 OR v_row.window_end <> v_today OR NOT v_row.window_clamped OR v_row.history_days <> 30 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): gratis debía recortar a [% .. %] con history_days 30 y clamped=true; dio [% .. %] history=% clamped=%.',
      v_today - 30, v_today, v_row.window_start, v_row.window_end, v_row.history_days, v_row.window_clamped;
  END IF;
  SELECT count(*) INTO v_count FROM public.rpc_sales_evolution(v_account, v_today - 400, v_today, 'day', NULL, NULL) r WHERE r.period = 'bucket';
  IF v_count <> 31 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): esperaba 31 buckets recortados y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_ranking(v_account, v_today - 400, v_today, 'units', true, NULL, NULL, 50, 0) r WHERE r.rank = 1;
  IF v_row.window_start <> v_today - 30 OR NOT v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp ranking): el ranking no declaró el recorte (start=% clamped=%).', v_row.window_start, v_row.window_clamped;
  END IF;
  -- Rango dentro del plan: no se toca.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r WHERE r.period = 'current';
  IF v_row.window_clamped OR v_row.window_start <> v_start THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): un rango de 11 días bajo gratis no debe recortarse.';
  END IF;
  -- Rango enteramente fuera del historial: ventana vacía del primer día permitido, jamás datos.
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_today - 400, v_today - 300, 'day', NULL, NULL) r WHERE r.period = 'current';
  IF v_row.window_start <> v_today - 30 OR v_row.window_end <> v_today - 30 OR NOT v_row.window_clamped OR v_row.revenue <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (clamp): rango fuera del historial debía quedar en [% .. %] vacío y dio [% .. %] revenue=%.',
      v_today - 30, v_today - 30, v_row.window_start, v_row.window_end, v_row.revenue;
  END IF;
  -- Fail-closed: cuenta inexistente → plan más restrictivo.
  SELECT * INTO v_row FROM public.reporting_plan_window(gen_random_uuid(), v_today - 400, v_today);
  IF v_row.history_days <> 30 OR v_row.plan <> 'gratis' OR NOT v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS FAILED (fail-closed): cuenta inexistente dio plan=% history=%.', v_row.plan, v_row.history_days;
  END IF;
  UPDATE public.accounts SET billing_plan = 'pro' WHERE id = v_account;
  RAISE NOTICE 'PASS (clamp D8): recorta a 30 días bajo gratis, declara la ventana, no toca rangos válidos, fail-closed.';

  PERFORM set_config('request.jwt.claims', '', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE;
END $$;

-- ═══ CLEANUP — resuelve por email, sobrevive corridas cortadas ══════════════
DO $$
DECLARE
  v_user    uuid;
  v_account uuid;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = 'estadisticas-ventas-gate@test.local';
  IF v_user IS NULL THEN RETURN; END IF;
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NOT NULL THEN
    DELETE FROM public.customer_account_movements WHERE account_id = v_account;
    DELETE FROM public.customer_accounts WHERE account_id = v_account;
    DELETE FROM public.clients WHERE account_id = v_account AND name LIKE '__gate_ev_%';
    DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
    DELETE FROM public.sales WHERE account_id = v_account;
    DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_ev_%' AND parent_id IS NOT NULL;
    DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_ev_%';
  END IF;
  -- Los anchors y sus cuentas aprovisionadas se dejan: borrarlos en cascada
  -- dispararía el guard de vaciado de sucursales (P0428) — el setup resuelve
  -- por email y es idempotente sobre el anchor persistido.
END $$;
