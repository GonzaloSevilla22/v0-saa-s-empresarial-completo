-- =============================================================================
-- GATE: test_estadisticas_ventas_e2.sql
-- CHANGE: estadisticas-ventas — Etapa E2 (tasks 5.1 / 5.6 / 11.2)
--
-- Verifica las dos RPCs de dimensiones del módulo de estadísticas:
--   rpc_sales_breakdown(p_account_id, p_start, p_end, p_dimension, p_branch_id,
--   p_canal) — canal / branch / weekday / hour / category — y
--   rpc_sales_top_clients(p_account_id, p_start, p_end, p_branch_id, p_limit).
--
--   (introspección) existen, SECURITY DEFINER con search_path fijado, ACLs
--   exactas (anon sin EXECUTE, authenticated con EXECUTE); consumen el helper
--   canónico reporting_sales_lines_in_window (D1) y el clamp
--   reporting_plan_window (D8); NINGÚN cuerpo aplica AT TIME ZONE sobre la
--   fecha de negocio `sales.date` (D3) — y, más estricto que E1, el ÚNICO
--   AT TIME ZONE admitido en estas dos RPCs es sobre `created_at` (instante).
--   (comportamiento) con anchor sintético y sesión vía request.jwt.claims:
--   tramo "Sin canal" / "Sin sucursal" / "Sin categoría" explícito, suma de
--   tramos = total del período de la evolución (sin restar NC: el desglose no
--   resta y el neto sí); filtro de sucursal uniforme fail-closed (la venta sin
--   sucursal queda fuera bajo el filtro); día de la semana desde la fecha de
--   negocio casteada (una venta cargada a las 23:30 ART sigue siendo lunes);
--   los 7 días viajan aunque estén en cero; hora desde created_at convertido
--   a Mendoza (23:30 ART → 23, no 02 UTC ni 00 de la fecha de negocio); 24
--   horas viajan en cero; categoría por products.category_id con el nombre del
--   catálogo (renombrar la categoría cambia el rótulo) y sin líneas de
--   servicio (suma = revenue − service_revenue); top clientes excluye las
--   ventas sin cliente y las devuelve aparte (OQ-2), un cliente de OTRA cuenta
--   referenciado por una venta no expone su nombre ni su id; p_limit acota
--   sólo las filas de cliente; clamp de plan D8; P0400 / P0401.
--
-- ⚠️ REGLA: se asserta el EFECTO (filas, totales, claves exactas), nunca
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
  v_rest    text;
  v_rpcs    text[] := ARRAY[
    'public.rpc_sales_breakdown(uuid,date,date,text,uuid,text)',
    'public.rpc_sales_top_clients(uuid,date,date,uuid,integer)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_rpcs LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (existencia): % no existe.', v_sig;
    END IF;
    SELECT p.prosecdef, p.proconfig, p.proacl INTO v_secdef, v_config, v_acl
    FROM pg_proc p WHERE p.oid = v_oid;
    IF NOT v_secdef THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (secdef): % debe ser SECURITY DEFINER.', v_sig;
    END IF;
    IF v_config IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search_path=%') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (search_path): % no fija search_path.', v_sig;
    END IF;
    IF v_acl IS NULL THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (acl): % tiene proacl NULL — falta el REVOKE ALL FROM PUBLIC.', v_sig;
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (acl): anon NO debe poder ejecutar %.', v_sig;
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (acl): authenticated debe poder ejecutar %.', v_sig;
    END IF;

    v_def := pg_get_functiondef(v_oid);
    -- (a) D1: la población de líneas viene del helper canónico, nunca de un
    --     SELECT propio sobre sales.
    IF v_def !~ 'reporting_sales_lines_in_window' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (helper): % no consume reporting_sales_lines_in_window (D1).', v_sig;
    END IF;
    IF v_def ~* 'FROM\s+public\.sales\M' OR v_def ~* 'JOIN\s+public\.sales\M' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (helper): % lee public.sales por su cuenta — la población de líneas vive sólo en el helper (D1).', v_sig;
    END IF;
    -- (b) D8: clamp de historial en el read-model.
    IF v_def !~ 'reporting_plan_window' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (clamp): % no aplica reporting_plan_window (D8).', v_sig;
    END IF;
    -- (c) D3: nadie convierte de zona la fecha de negocio.
    IF v_def ~* '\.date\s*\)?\s*AT\s+TIME\s+ZONE' OR v_def ~* 'business_date\s*\)?\s*AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (fecha de negocio): % aplica AT TIME ZONE sobre la fecha de negocio — corre cada venta un día atrás (D3).', v_sig;
    END IF;
    -- (d) Más estricto: el ÚNICO AT TIME ZONE admitido es sobre created_at
    --     (instante). Se borran esas ocurrencias y no debe quedar ninguna.
    v_rest := regexp_replace(v_def, 'created_at\s+AT\s+TIME\s+ZONE', '', 'gi');
    IF v_rest ~* 'AT\s+TIME\s+ZONE' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (zona): % aplica AT TIME ZONE a algo que no es created_at.', v_sig;
    END IF;
  END LOOP;

  -- (e) La dimensión horaria deriva de created_at (instante), no de la fecha
  --     de negocio: el cuerpo del breakdown tiene que convertir created_at.
  v_def := pg_get_functiondef(to_regprocedure('public.rpc_sales_breakdown(uuid,date,date,text,uuid,text)'));
  IF v_def !~* 'created_at\s+AT\s+TIME\s+ZONE\s+''America/Argentina/Mendoza''' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora): rpc_sales_breakdown debe derivar la hora de created_at AT TIME ZONE ''America/Argentina/Mendoza'' (D5, OQ-1).';
  END IF;

  RAISE NOTICE 'PASS (introspección E2): 2 RPCs SECURITY DEFINER, ACLs exactas, helper + clamp consumidos, AT TIME ZONE sólo sobre created_at.';
END $$;

-- ── 2. Comportamiento con anchor sintético ──────────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'estadisticas-ventas-e2-gate@test.local';
  v_intruder_email text := 'estadisticas-ventas-e2-gate-intruder@test.local';
  v_user      uuid;
  v_intruder  uuid;
  v_account   uuid;
  v_foreign_account uuid;
  v_branch1   uuid;
  v_branch2   uuid;
  v_today     date;
  v_monday    date;
  v_sunday    date;
  v_sat       date;
  v_fri       date;
  v_start     date;
  v_end       date;
  v_cat_a     uuid; v_cat_b uuid;
  v_p_a       uuid; v_p_b uuid; v_p_c uuid;
  v_client1   uuid; v_client2 uuid; v_client_foreign uuid;
  v_ca        uuid;
  v_op1 uuid := gen_random_uuid(); v_op2 uuid := gen_random_uuid(); v_op3 uuid := gen_random_uuid();
  v_op4 uuid := gen_random_uuid(); v_op5 uuid := gen_random_uuid(); v_op6 uuid := gen_random_uuid();
  v_row       record;
  v_evo       record;
  v_count     integer;
  v_sum       numeric;
  v_dim       text;
  v_created   timestamptz;
  v_exp_rev   numeric;
  v_exp_ops   integer;
BEGIN
  -- ── Setup: anchors con provisioning automático (handle_new_user), resueltos
  -- por email ANTES de insertar (idempotente sobre la DB local compartida). ──
  SELECT id INTO v_user FROM auth.users WHERE email = v_anchor_email;
  IF v_user IS NULL THEN
    v_user := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas E2'));
  END IF;
  SELECT id INTO v_intruder FROM auth.users WHERE email = v_intruder_email;
  IF v_intruder IS NULL THEN
    v_intruder := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_intruder, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas E2 Intruder'));
  END IF;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE ESTADISTICAS E2: anchor sin cuenta aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;
  SELECT account_id INTO v_foreign_account FROM public.account_members
  WHERE user_id = v_intruder ORDER BY created_at LIMIT 1;

  -- Limpieza de restos de una corrida previa cortada (los totales son exactos).
  DELETE FROM public.customer_account_movements WHERE account_id = v_account;
  DELETE FROM public.customer_accounts WHERE account_id = v_account;
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
  DELETE FROM public.sales WHERE account_id = v_account;
  DELETE FROM public.clients WHERE account_id = v_account AND name LIKE '__gate_e2_%';
  IF v_foreign_account IS NOT NULL THEN
    DELETE FROM public.clients WHERE account_id = v_foreign_account AND name LIKE '__gate_e2_%';
  END IF;
  DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e2_%';
  DELETE FROM public.product_categories WHERE account_id = v_account AND name LIKE '__gate_e2_%';

  -- Plan 'pro' explícito (1825 días de historial).
  UPDATE public.accounts
     SET billing_plan = 'pro', billing_status = 'active', trial_plan = NULL,
         trial_expires_at = NULL, plan_expires_at = NULL, billing_exempt = false
   WHERE id = v_account;

  -- ── Sucursales: la aprovisionada + una segunda (idempotente por nombre) ───
  SELECT id INTO v_branch1 FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  IF v_branch1 IS NULL THEN
    RAISE NOTICE 'GATE ESTADISTICAS E2: la cuenta no tiene sucursal aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;
  SELECT id INTO v_branch2 FROM public.branches WHERE account_id = v_account AND name = '__gate_e2_suc2__';
  IF v_branch2 IS NULL THEN
    INSERT INTO public.branches (account_id, name) VALUES (v_account, '__gate_e2_suc2__') RETURNING id INTO v_branch2;
  END IF;

  -- ── Fechas relativas (fecha de negocio = día calendario, a medianoche UTC) ─
  v_today  := public.reporting_local_today();
  v_monday := date_trunc('week', v_today::timestamp)::date;  -- lunes ISO
  v_sunday := v_monday - 1;
  v_sat    := v_monday - 2;
  v_fri    := v_monday - 3;
  v_start  := v_today - 10;
  v_end    := v_today;

  -- ── Fixture: categorías del catálogo de la cuenta + productos ─────────────
  INSERT INTO public.product_categories (account_id, name) VALUES (v_account, '__gate_e2_cat_a__') RETURNING id INTO v_cat_a;
  INSERT INTO public.product_categories (account_id, name) VALUES (v_account, '__gate_e2_cat_b__') RETURNING id INTO v_cat_b;
  INSERT INTO public.products (user_id, account_id, name, price, cost, category_id)
  VALUES (v_user, v_account, '__gate_e2_prod_a__', 1000, 100, v_cat_a) RETURNING id INTO v_p_a;
  INSERT INTO public.products (user_id, account_id, name, price, cost, category_id)
  VALUES (v_user, v_account, '__gate_e2_prod_b__', 500, 50, v_cat_b) RETURNING id INTO v_p_b;
  -- Producto SIN categoría (category_id NULL → tramo "Sin categoría").
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_e2_prod_c__', 700, 70) RETURNING id INTO v_p_c;

  -- ── Fixture: clientes (dos propios + uno de OTRA cuenta) ──────────────────
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account, v_user, '__gate_e2_cliente_1__') RETURNING id INTO v_client1;
  INSERT INTO public.clients (account_id, user_id, name) VALUES (v_account, v_user, '__gate_e2_cliente_2__') RETURNING id INTO v_client2;
  IF v_foreign_account IS NOT NULL THEN
    INSERT INTO public.clients (account_id, user_id, name) VALUES (v_foreign_account, v_intruder, '__gate_e2_cliente_ajeno__') RETURNING id INTO v_client_foreign;
  END IF;

  -- ── Fixture: ventas ───────────────────────────────────────────────────────
  -- date = fecha de negocio a 00:00 UTC (como prod); created_at = instante
  -- real, escrito en hora de Mendoza y convertido a timestamptz.
  --
  -- S1: canal local, suc1, cliente1, prod A (cat A), 2u × $1000 = $2000,
  --     LUNES, cargada a las 23:30 ART del lunes (= martes 02:30 UTC), op1.
  v_created := (v_monday::timestamp + interval '23 hours 30 minutes') AT TIME ZONE 'America/Argentina/Mendoza';
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
  VALUES (v_user, v_account, v_branch1, v_client1, 'local', v_p_a, 1000, 2, 2000, v_monday::timestamp AT TIME ZONE 'UTC', v_op1, v_created);
  -- S5: segunda línea de la MISMA operación op1: prod B (cat B), 1u × $500.
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
  VALUES (v_user, v_account, v_branch1, v_client1, 'local', v_p_b, 500, 1, 500, v_monday::timestamp AT TIME ZONE 'UTC', v_op1, v_created);
  -- S2: SIN canal, SIN sucursal, SIN cliente, prod B (cat B), 1u × $500,
  --     DOMINGO, cargada a las 14:00 ART, op2.
  v_created := (v_sunday::timestamp + interval '14 hours') AT TIME ZONE 'America/Argentina/Mendoza';
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
  VALUES (v_user, v_account, NULL, NULL, NULL, v_p_b, 500, 1, 500, v_sunday::timestamp AT TIME ZONE 'UTC', v_op2, v_created);
  -- S3: canal instagram, suc2, cliente2, prod C (sin categoría), 3u × $700 =
  --     $2100, SÁBADO, cargada a las 14:30 ART, op3.
  v_created := (v_sat::timestamp + interval '14 hours 30 minutes') AT TIME ZONE 'America/Argentina/Mendoza';
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
  VALUES (v_user, v_account, v_branch2, v_client2, 'instagram', v_p_c, 700, 3, 2100, v_sat::timestamp AT TIME ZONE 'UTC', v_op3, v_created);
  -- S4: canal local, suc1, cliente1, línea de SERVICIO (product_id NULL),
  --     $400, VIERNES, cargada a las 09:00 ART, op4.
  v_created := (v_fri::timestamp + interval '9 hours') AT TIME ZONE 'America/Argentina/Mendoza';
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
  VALUES (v_user, v_account, v_branch1, v_client1, 'local', NULL, 400, 1, 400, v_fri::timestamp AT TIME ZONE 'UTC', v_op4, v_created);
  -- S8: cliente de OTRA cuenta, sin canal, sin sucursal, servicio, $100,
  --     VIERNES, cargada a las 09:15 ART, op5 (sólo si hay cuenta ajena).
  IF v_client_foreign IS NOT NULL THEN
    v_created := (v_fri::timestamp + interval '9 hours 15 minutes') AT TIME ZONE 'America/Argentina/Mendoza';
    INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
    VALUES (v_user, v_account, NULL, v_client_foreign, NULL, NULL, 100, 1, 100, v_fri::timestamp AT TIME ZONE 'UTC', v_op5, v_created);
  ELSE
    -- Sin cuenta ajena: misma línea pero sin cliente, para que los totales
    -- del resto de los asserts no cambien (queda como "sin cliente").
    v_created := (v_fri::timestamp + interval '9 hours 15 minutes') AT TIME ZONE 'America/Argentina/Mendoza';
    INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id, created_at)
    VALUES (v_user, v_account, NULL, NULL, NULL, NULL, 100, 1, 100, v_fri::timestamp AT TIME ZONE 'UTC', v_op5, v_created);
  END IF;
  -- Z: período ANTERIOR (hoy-15), canal local, cliente1, $333, op6 — fuera.
  INSERT INTO public.sales (user_id, account_id, branch_id, client_id, canal, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch1, v_client1, 'local', v_p_a, 333, 1, 333, (v_today - 15)::timestamp AT TIME ZONE 'UTC', v_op6);

  -- ── Fixture: nota de crédito de $150 el sábado (12:00 UTC) ───────────────
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account, v_client1, 0, v_user) RETURNING id INTO v_ca;
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by, created_at)
  VALUES (v_ca, v_account, -150, 0, 'credit_note', v_user, (v_sat::timestamp + interval '12 hours') AT TIME ZONE 'UTC');

  -- Totales esperados de la ventana [hoy-10 .. hoy]:
  --   revenue 2000+500+500+2100+400+100 = 5600; units 9; ops 5 (op1 multi-línea
  --   cuenta 1); servicio 500 (S4+S8); NC 150 → neto 5450.

  -- ── Autorización: intruso no miembro → P0401 en las dos RPCs ─────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_intruder::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_intruder THEN
    RAISE NOTICE 'GATE ESTADISTICAS E2: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN;
  END IF;
  BEGIN
    PERFORM * FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0401): rpc_sales_breakdown aceptó a un no miembro.';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0401): rpc_sales_top_clients aceptó a un no miembro.';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0401): no miembro rechazado en breakdown y top clientes.';

  -- ── Sesión del anchor ────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ── P0400: dimensión fuera de dominio, límite inválido, rango invertido ───
  BEGIN
    PERFORM * FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'banana', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): p_dimension=banana aceptada.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_breakdown(v_account, v_start, v_end, NULL, NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): p_dimension NULL aceptada.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 0);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): p_limit=0 aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 999);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): p_limit=999 aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_breakdown(v_account, v_end, v_start, 'canal', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): rango invertido aceptado en breakdown.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_sales_top_clients(v_account, v_end, v_start, NULL, 10);
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (P0400): rango invertido aceptado en top clientes.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0400): dimensión, límite y rango fuera de dominio rechazados.';

  -- Referencia: totales del período según la evolución (E1).
  SELECT * INTO v_evo FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', NULL, NULL) r WHERE r.period = 'current';
  IF v_evo.revenue <> 5600 OR v_evo.net_revenue <> 5450 OR v_evo.service_revenue <> 500 OR v_evo.operations <> 5 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (fixture): la evolución dio revenue=% net=% svc=% ops=% y el fixture esperaba 5600/5450/500/5.',
      v_evo.revenue, v_evo.net_revenue, v_evo.service_revenue, v_evo.operations;
  END IF;

  -- ══ CANAL: tramo "Sin canal" explícito, suma = total bruto ════════════════
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, NULL);
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (canal): esperaba 3 tramos (local, instagram, sin canal) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, NULL) r WHERE r.bucket_key = 'local';
  IF NOT FOUND OR v_row.revenue <> 2900 OR v_row.operations <> 2 OR v_row.units <> 4 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (canal local): revenue=% ops=% units=% y esperaba 2900/2/4 (op1 multi-línea cuenta 1, servicio incluido).', v_row.revenue, v_row.operations, v_row.units;
  END IF;
  IF v_row.sort_order <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (canal orden): local (2900) debía ser el tramo 1 por importe y fue %.', v_row.sort_order;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, NULL) r WHERE r.bucket_key IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (canal): falta el tramo "Sin canal" (bucket_key NULL) — nunca se omite.';
  END IF;
  IF v_row.bucket_label <> 'Sin canal' OR v_row.revenue <> 600 OR v_row.operations <> 2 OR v_row.units <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sin canal): label=% revenue=% ops=% units=% y esperaba "Sin canal"/600/2/2.', v_row.bucket_label, v_row.revenue, v_row.operations, v_row.units;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, NULL) r;
  IF v_sum <> v_evo.revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad canal): suma de tramos % ≠ revenue del período % (spec: "Dos agregados informan la misma facturación").', v_sum, v_evo.revenue;
  END IF;
  IF v_sum = v_evo.net_revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (canal/NC): la suma de tramos coincide con el NETO — el desglose restó NC y no debe (una NC no tiene canal).';
  END IF;
  -- Ventana declarada por fila (D8), plan pro sin recorte.
  IF v_row.window_start <> v_start OR v_row.window_end <> v_end OR v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (ventana): plan pro no debe recortar 11 días (start=% end=% clamped=%).', v_row.window_start, v_row.window_end, v_row.window_clamped;
  END IF;
  -- Bajo filtro de canal: un solo tramo.
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, 'instagram');
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', NULL, 'instagram') r LIMIT 1;
  IF v_count <> 1 OR v_row.bucket_key <> 'instagram' OR v_row.revenue <> 2100 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (filtro canal): esperaba 1 tramo instagram/2100 y hubo % (%/%).', v_count, v_row.bucket_key, v_row.revenue;
  END IF;
  RAISE NOTICE 'PASS (canal): local 2900/2 > instagram 2100 > Sin canal 600/2; suma = 5600 bruto (no neto); filtro de canal aplicado.';

  -- ══ SUCURSAL: tramo "Sin sucursal", filtro fail-closed uniforme ═══════════
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', NULL, NULL);
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sucursal): esperaba 3 tramos y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', NULL, NULL) r WHERE r.bucket_key = v_branch2::text;
  IF NOT FOUND OR v_row.bucket_label <> '__gate_e2_suc2__' OR v_row.revenue <> 2100 OR v_row.operations <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sucursal 2): label=% revenue=% ops=% y esperaba el nombre del catálogo / 2100 / 1.', v_row.bucket_label, v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', NULL, NULL) r WHERE r.bucket_key = v_branch1::text;
  IF NOT FOUND OR v_row.revenue <> 2900 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sucursal 1): revenue=% ops=% y esperaba 2900/2.', v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', NULL, NULL) r WHERE r.bucket_key IS NULL;
  IF NOT FOUND OR v_row.bucket_label <> 'Sin sucursal' OR v_row.revenue <> 600 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sin sucursal): falta o difiere el tramo "Sin sucursal" (label=% revenue=% ops=%; esperaba 600/2).', v_row.bucket_label, v_row.revenue, v_row.operations;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', NULL, NULL) r;
  IF v_sum <> v_evo.revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad sucursal): suma % ≠ %.', v_sum, v_evo.revenue;
  END IF;
  -- Filtro de sucursal fail-closed: la venta sin sucursal queda FUERA en
  -- todos los agregados por igual (evolución, desglose por canal y por
  -- sucursal, top clientes).
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', v_branch1, NULL);
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'branch', v_branch1, NULL) r LIMIT 1;
  IF v_count <> 1 OR v_row.bucket_key <> v_branch1::text OR v_row.revenue <> 2900 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (filtro sucursal): esperaba 1 tramo (suc1/2900) y hubo % (%/%) — ¿la venta sin sucursal se coló?', v_count, v_row.bucket_label, v_row.revenue;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'canal', v_branch1, NULL) r;
  SELECT * INTO v_row FROM public.rpc_sales_evolution(v_account, v_start, v_end, 'day', v_branch1, NULL) r WHERE r.period = 'current';
  IF v_sum <> 2900 OR v_row.revenue <> 2900 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (filtro uniforme): canal bajo suc1 sumó % y la evolución bajo suc1 dio % — ambos debían dar 2900.', v_sum, v_row.revenue;
  END IF;
  RAISE NOTICE 'PASS (sucursal): suc1 2900 / suc2 2100 (nombre del catálogo) / Sin sucursal 600; filtro fail-closed uniforme en desglose y evolución.';

  -- ══ DÍA DE LA SEMANA: fecha de negocio casteada, 7 días siempre ═══════════
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL);
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (weekday): esperaba los 7 días (en cero los vacíos) y hubo %.', v_count;
  END IF;
  -- La venta del LUNES cargada a las 23:30 ART sigue siendo lunes (D3): un
  -- AT TIME ZONE sobre la fecha de negocio (00:00 UTC = 21:00 del domingo)
  -- la correría al domingo.
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL) r WHERE r.bucket_key = '1';
  IF NOT FOUND OR v_row.bucket_label <> 'Lunes' OR v_row.sort_order <> 1 OR v_row.revenue <> 2500 OR v_row.operations <> 1 OR v_row.units <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (lunes): label=% orden=% revenue=% ops=% units=% y esperaba Lunes/1/2500/1/3 — la venta de las 23:30 ART debe seguir siendo lunes (D3).', v_row.bucket_label, v_row.sort_order, v_row.revenue, v_row.operations, v_row.units;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL) r WHERE r.bucket_key = '7';
  IF NOT FOUND OR v_row.bucket_label <> 'Domingo' OR v_row.revenue <> 500 OR v_row.operations <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (domingo): label=% revenue=% ops=% y esperaba Domingo/500/1 (sólo S2; si la de las 23:30 se corrió, daría 3000).', v_row.bucket_label, v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL) r WHERE r.bucket_key = '5';
  IF NOT FOUND OR v_row.bucket_label <> 'Viernes' OR v_row.revenue <> 500 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (viernes): revenue=% ops=% y esperaba 500/2 (S4 + S8).', v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL) r WHERE r.bucket_key = '3';
  IF NOT FOUND OR v_row.bucket_label <> 'Miércoles' OR v_row.revenue <> 0 OR v_row.operations <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (miércoles): el día sin ventas debe viajar en cero (label=% revenue=% ops=%).', v_row.bucket_label, v_row.revenue, v_row.operations;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'weekday', NULL, NULL) r;
  IF v_sum <> v_evo.revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad weekday): suma % ≠ %.', v_sum, v_evo.revenue;
  END IF;
  RAISE NOTICE 'PASS (día de la semana): lunes 2500 (la venta de las 23:30 ART no se corrió al domingo), domingo 500, viernes 500/2, miércoles en cero; 7 filas.';

  -- ══ HORARIO DE CARGA: created_at convertido a Mendoza, 24 horas siempre ═══
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL);
  IF v_count <> 24 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hour): esperaba 24 horas (en cero las vacías) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.bucket_key = '23';
  IF NOT FOUND OR v_row.bucket_label <> '23:00' OR v_row.sort_order <> 23 OR v_row.revenue <> 2500 OR v_row.operations <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora 23): label=% orden=% revenue=% ops=% y esperaba 23:00/23/2500/1 — la carga de las 23:30 ART es la hora 23 local, no la 02 UTC.', v_row.bucket_label, v_row.sort_order, v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.bucket_key = '2';
  IF v_row.revenue <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora 02): hay % en la hora 02 — created_at se leyó en UTC sin convertir a Mendoza.', v_row.revenue;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.bucket_key = '0';
  IF v_row.revenue <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora 00): hay % en la hora 00 — la hora se derivó de la fecha de negocio (00:00 UTC), que no tiene hora (invariante: distribución degenerada).', v_row.revenue;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.bucket_key = '14';
  IF NOT FOUND OR v_row.revenue <> 2600 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora 14): revenue=% ops=% y esperaba 2600/2 (S2 14:00 + S3 14:30 ART).', v_row.revenue, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.bucket_key = '9';
  IF NOT FOUND OR v_row.bucket_label <> '09:00' OR v_row.revenue <> 500 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hora 09): label=% revenue=% ops=% y esperaba 09:00/500/2.', v_row.bucket_label, v_row.revenue, v_row.operations;
  END IF;
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r WHERE r.revenue > 0;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (hour): esperaba exactamente 3 horas con ventas (09, 14, 23) y hubo %.', v_count;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'hour', NULL, NULL) r;
  IF v_sum <> v_evo.revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad hour): suma % ≠ %.', v_sum, v_evo.revenue;
  END IF;
  RAISE NOTICE 'PASS (horario de carga): 23:00 → 2500 (Mendoza, no UTC ni fecha de negocio), 14:00 → 2600/2, 09:00 → 500/2; 24 filas; suma 5600.';

  -- ══ CATEGORÍA: category_id del catálogo, "Sin categoría", sin servicio ════
  SELECT count(*) INTO v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL);
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (categoría): esperaba 3 tramos (cat A, cat B, sin categoría) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL) r WHERE r.bucket_key = v_cat_a::text;
  IF NOT FOUND OR v_row.bucket_label <> '__gate_e2_cat_a__' OR v_row.revenue <> 2000 OR v_row.units <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (cat A): label=% revenue=% units=% y esperaba el nombre del catálogo / 2000 / 2.', v_row.bucket_label, v_row.revenue, v_row.units;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL) r WHERE r.bucket_key = v_cat_b::text;
  IF NOT FOUND OR v_row.revenue <> 1000 OR v_row.units <> 2 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (cat B): revenue=% units=% ops=% y esperaba 1000/2/2 (S5 + S2).', v_row.revenue, v_row.units, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL) r WHERE r.bucket_key IS NULL;
  IF NOT FOUND OR v_row.bucket_label <> 'Sin categoría' OR v_row.revenue <> 2100 OR v_row.units <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sin categoría): label=% revenue=% units=% y esperaba "Sin categoría"/2100/3 (prod C) — el tramo nunca se omite.', v_row.bucket_label, v_row.revenue, v_row.units;
  END IF;
  IF v_row.sort_order <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (categoría orden): "Sin categoría" (2100) debía ser el tramo 1 por importe y fue %.', v_row.sort_order;
  END IF;
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL) r;
  IF v_sum <> v_evo.revenue - v_evo.service_revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad categoría): suma % ≠ revenue − servicio % (D6: las líneas de servicio no tienen categoría y quedan fuera, declaradas por service_revenue).', v_sum, v_evo.revenue - v_evo.service_revenue;
  END IF;
  -- Espejo: renombrar la categoría en el catálogo cambia el rótulo del tramo
  -- (se agrupa por category_id, el nombre se lee del catálogo, no del TEXT).
  UPDATE public.product_categories SET name = '__gate_e2_cat_a_renombrada__' WHERE id = v_cat_a;
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_start, v_end, 'category', NULL, NULL) r WHERE r.bucket_key = v_cat_a::text;
  IF v_row.bucket_label <> '__gate_e2_cat_a_renombrada__' OR v_row.revenue <> 2000 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (espejo): tras renombrar, label=% revenue=% — el tramo debe seguir al catálogo sin cambiar de importe.', v_row.bucket_label, v_row.revenue;
  END IF;
  UPDATE public.product_categories SET name = '__gate_e2_cat_a__' WHERE id = v_cat_a;
  RAISE NOTICE 'PASS (categoría): cat A 2000 / cat B 1000 / Sin categoría 2100 (primero por importe); suma = revenue − servicio; el rótulo sigue al catálogo.';

  -- ══ TOP CLIENTES (OQ-2): sin cliente fuera y declarado, tenencia ══════════
  SELECT count(*) INTO v_count FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'client';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top clientes): esperaba 3 filas de cliente (C1, C2, ajeno) y hubo %.', v_count;
  END IF;
  IF EXISTS (SELECT 1 FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'client' AND r.client_id IS NULL AND r.client_name IS NULL) THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top clientes): una fila de cliente representa "sin cliente" — OQ-2: las ventas sin cliente NO compiten.';
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'client' AND r.rank = 1;
  IF v_row.client_id <> v_client1 OR v_row.client_name <> '__gate_e2_cliente_1__' OR v_row.revenue <> 2900 OR v_row.operations <> 2 OR v_row.units <> 4 OR v_row.last_sale_date <> v_monday THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top #1): % %/%/% u, última % — esperaba cliente 1 2900/2/4, última venta el lunes.', v_row.client_name, v_row.revenue, v_row.operations, v_row.units, v_row.last_sale_date;
  END IF;
  IF v_row.total_clients <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top clientes): total_clients=% y esperaba 3.', v_row.total_clients;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'client' AND r.rank = 2;
  IF v_row.client_id <> v_client2 OR v_row.revenue <> 2100 OR v_row.operations <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top #2): % %/% — esperaba cliente 2 2100/1.', v_row.client_name, v_row.revenue, v_row.operations;
  END IF;
  -- Tenencia: el cliente de OTRA cuenta rankea por su importe (la venta es de
  -- esta cuenta) pero NO expone ni su nombre ni su id.
  IF v_client_foreign IS NOT NULL THEN
    SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'client' AND r.rank = 3;
    IF v_row.revenue <> 100 OR v_row.client_id IS NOT NULL OR v_row.client_name LIKE '%ajeno%' THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (tenencia): la fila del cliente ajeno expone id=% nombre=% (revenue %) — debe rankear con id NULL y sin el nombre.', v_row.client_id, v_row.client_name, v_row.revenue;
    END IF;
    IF EXISTS (SELECT 1 FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.client_name = '__gate_e2_cliente_ajeno__' OR r.client_id = v_client_foreign) THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (tenencia): el nombre o el id del cliente de otra cuenta viaja en la respuesta.';
    END IF;
  ELSE
    RAISE NOTICE 'GATE ESTADISTICAS E2: sin cuenta ajena aprovisionada — se omite el assert de tenencia del cliente ajeno.';
  END IF;
  -- Fila "sin cliente": exactamente una, con el importe aparte (S2 = 500 + S8
  -- cuando no hubo cuenta ajena).
  SELECT count(*) INTO v_count FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'unassigned';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sin cliente): esperaba exactamente 1 fila unassigned y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r WHERE r.row_kind = 'unassigned';
  -- (Los esperados se resuelven ANTES del IF: plpgsql corta la condición de
  -- un IF en el primer THEN, así que un CASE WHEN … THEN ahí no compila.)
  IF v_client_foreign IS NOT NULL THEN
    v_exp_rev := 500; v_exp_ops := 1;
  ELSE
    v_exp_rev := 600; v_exp_ops := 2;
  END IF;
  IF v_row.rank IS NOT NULL OR v_row.client_id IS NOT NULL
     OR v_row.revenue <> v_exp_rev OR v_row.operations <> v_exp_ops THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (sin cliente): rank=% id=% revenue=% ops=% — esperaba rank NULL, id NULL, %/% (OQ-2: declarado aparte).', v_row.rank, v_row.client_id, v_row.revenue, v_row.operations, v_exp_rev, v_exp_ops;
  END IF;
  -- Identidad: clientes + sin cliente = revenue del período.
  SELECT SUM(r.revenue) INTO v_sum FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 10) r;
  IF v_sum <> v_evo.revenue THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad clientes): clientes + sin cliente = % ≠ revenue %.', v_sum, v_evo.revenue;
  END IF;
  -- p_limit acota SÓLO las filas de cliente; la fila unassigned y el total siguen.
  SELECT count(*) INTO v_count FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 1) r WHERE r.row_kind = 'client';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (limit): p_limit=1 devolvió % filas de cliente.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, NULL, 1) r WHERE r.row_kind = 'unassigned';
  IF NOT FOUND OR v_row.total_clients <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (limit): con p_limit=1 la fila unassigned debe seguir viajando con total_clients=3 (found=% total=%).', FOUND, v_row.total_clients;
  END IF;
  -- Filtro de sucursal fail-closed también acá: bajo suc1 sólo C1 (2900) y
  -- sin cliente = 0 (S2 y S8 no tienen sucursal).
  SELECT count(*) INTO v_count FROM public.rpc_sales_top_clients(v_account, v_start, v_end, v_branch1, 10) r WHERE r.row_kind = 'client';
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_start, v_end, v_branch1, 10) r WHERE r.row_kind = 'unassigned';
  IF v_count <> 1 OR v_row.revenue <> 0 OR v_row.operations <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (top clientes filtro): bajo suc1 esperaba 1 cliente y sin cliente en 0; hubo % clientes y sin cliente %/%.', v_count, v_row.revenue, v_row.operations;
  END IF;
  RAISE NOTICE 'PASS (top clientes): C1 2900/2 > C2 2100/1 > ajeno 100 (sin nombre ni id); sin cliente 500/1 aparte; limit acota sólo clientes; filtro fail-closed.';

  -- ══ CLAMP DE PLAN (D8) en las dos RPCs ════════════════════════════════════
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;   -- history_days 30
  SELECT * INTO v_row FROM public.rpc_sales_breakdown(v_account, v_today - 400, v_today, 'weekday', NULL, NULL) r LIMIT 1;
  IF v_row.window_start <> v_today - 30 OR NOT v_row.window_clamped OR v_row.history_days <> 30 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (clamp breakdown): gratis debía recortar a [% ..] con history 30 y clamped=true; dio start=% history=% clamped=%.', v_today - 30, v_row.window_start, v_row.history_days, v_row.window_clamped;
  END IF;
  SELECT * INTO v_row FROM public.rpc_sales_top_clients(v_account, v_today - 400, v_today, NULL, 10) r WHERE r.row_kind = 'unassigned';
  IF v_row.window_start <> v_today - 30 OR NOT v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (clamp top clientes): no declaró el recorte (start=% clamped=%).', v_row.window_start, v_row.window_clamped;
  END IF;
  UPDATE public.accounts SET billing_plan = 'pro' WHERE id = v_account;
  RAISE NOTICE 'PASS (clamp D8): breakdown y top clientes recortan a 30 días bajo gratis y lo declaran.';

  -- ══ Identidad cruzada final: las 4 dimensiones de facturación coinciden ═══
  FOREACH v_dim IN ARRAY ARRAY['canal', 'branch', 'weekday', 'hour'] LOOP
    SELECT SUM(r.revenue), SUM(r.units) INTO v_sum, v_count FROM public.rpc_sales_breakdown(v_account, v_start, v_end, v_dim, NULL, NULL) r;
    IF v_sum <> v_evo.revenue OR v_count <> v_evo.units THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E2 FAILED (identidad %): revenue %/units % ≠ evolución %/%.', v_dim, v_sum, v_count, v_evo.revenue, v_evo.units;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (identidad): canal, sucursal, día y hora suman exactamente el revenue y las unidades de la evolución.';

  PERFORM set_config('request.jwt.claims', '', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE;
END $$;

-- ═══ CLEANUP — resuelve por email, sobrevive corridas cortadas ══════════════
DO $$
DECLARE
  v_user     uuid;
  v_intruder uuid;
  v_account  uuid;
  v_foreign  uuid;
BEGIN
  SELECT id INTO v_user FROM auth.users WHERE email = 'estadisticas-ventas-e2-gate@test.local';
  SELECT id INTO v_intruder FROM auth.users WHERE email = 'estadisticas-ventas-e2-gate-intruder@test.local';
  IF v_user IS NULL THEN RETURN; END IF;
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_intruder IS NOT NULL THEN
    SELECT account_id INTO v_foreign FROM public.account_members WHERE user_id = v_intruder ORDER BY created_at LIMIT 1;
  END IF;
  IF v_account IS NOT NULL THEN
    DELETE FROM public.customer_account_movements WHERE account_id = v_account;
    DELETE FROM public.customer_accounts WHERE account_id = v_account;
    DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
    DELETE FROM public.sales WHERE account_id = v_account;
    DELETE FROM public.clients WHERE account_id = v_account AND name LIKE '__gate_e2_%';
    DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e2_%';
    DELETE FROM public.product_categories WHERE account_id = v_account AND name LIKE '__gate_e2_%';
  END IF;
  IF v_foreign IS NOT NULL THEN
    DELETE FROM public.clients WHERE account_id = v_foreign AND name LIKE '__gate_e2_%';
  END IF;
  -- La segunda sucursal se deja: borrarla dispararía el guard de vaciado
  -- (P0428, prohíbe el DELETE físico) y el setup la resuelve por nombre.
  -- Los anchors y sus cuentas aprovisionadas se dejan por el mismo motivo.
END $$;
