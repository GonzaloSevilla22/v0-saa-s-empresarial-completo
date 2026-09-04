-- =============================================================================
-- GATE: test_estadisticas_ventas_e3.sql
-- CHANGE: estadisticas-ventas — Etapa E3 (tasks 9.1 / 9.6 / 11.2)
--
-- Verifica la RPC de detalle por producto del módulo de estadísticas:
--   rpc_product_sales_evolution(p_account_id, p_product_id, p_start, p_end,
--   p_bucket, p_branch_id, p_canal) — migración 20261026000001.
--
--   (introspección) existe, SECURITY DEFINER con search_path fijado, ACLs
--   exactas (anon sin EXECUTE, authenticated con EXECUTE); consume el helper
--   canónico reporting_sales_lines_in_window (D1) y el clamp
--   reporting_plan_window (D8); el cuerpo NO aplica NINGÚN AT TIME ZONE (más
--   estricto que E2: el detalle no deriva hora alguna, así que no tiene
--   excusa para convertir de zona) y no lee public.sales por su cuenta.
--   (comportamiento) con anchor sintético y sesión vía request.jwt.claims:
--   tres clases de fila (total / bucket / member); el padre agrupa a sus
--   variantes Y a sus propias ventas directas (misma regla que
--   rpc_product_ranking: la cabecera del grupo es el padre); variant_count
--   cuenta sólo las variantes con ventas (no el padre); una variante pedida
--   directamente muestra sólo lo suyo con su padre como contexto; un
--   producto standalone no agrupa; suma de buckets = total = suma de
--   miembros en las 3 granularidades; el total del detalle es IDÉNTICO a la
--   fila del ranking (agrupado para el padre, sin agrupar para la variante)
--   — dos read-models sobre la misma población no pueden disentir; producto
--   sin ventas en el período → total en cero, buckets en cero, sin miembros
--   (nunca un error); filtro de sucursal fail-closed; margen con cascada
--   RN-D2 y cobertura declarada (D11); clamp D8; P0400 / P0401 / P0404
--   (producto de OTRA cuenta o inexistente → 404, sin revelar si existe).
--
-- ⚠️ REGLA: se asserta el EFECTO (filas, totales, claves exactas), nunca
-- "no hubo error". Degrade-don't-fail sólo si el anchor no se aprovisiona o
-- auth.uid() no resuelve bajo request.jwt.claims local (NOTICE, no aborta).
-- Cleanup: DO block separado al final, resuelve por email.
-- =============================================================================

-- ── 1. Introspección ────────────────────────────────────────────────────────
DO $$
DECLARE
  v_sig     text := 'public.rpc_product_sales_evolution(uuid,uuid,date,date,text,uuid,text)';
  v_oid     oid;
  v_secdef  boolean;
  v_config  text[];
  v_acl     aclitem[];
  v_def     text;
BEGIN
  v_oid := to_regprocedure(v_sig);
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (existencia): % no existe.', v_sig;
  END IF;
  SELECT p.prosecdef, p.proconfig, p.proacl INTO v_secdef, v_config, v_acl
  FROM pg_proc p WHERE p.oid = v_oid;
  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (secdef): % debe ser SECURITY DEFINER.', v_sig;
  END IF;
  IF v_config IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search_path=%') THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (search_path): % no fija search_path.', v_sig;
  END IF;
  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (acl): % tiene proacl NULL — falta el REVOKE ALL FROM PUBLIC.', v_sig;
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (acl): anon NO debe poder ejecutar %.', v_sig;
  END IF;
  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (acl): authenticated debe poder ejecutar %.', v_sig;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  -- (a) D1: la población de líneas viene del helper canónico.
  IF v_def !~ 'reporting_sales_lines_in_window' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (helper): % no consume reporting_sales_lines_in_window (D1).', v_sig;
  END IF;
  -- (b) D8: clamp de historial dentro del read-model.
  IF v_def !~ 'reporting_plan_window' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (clamp): % no aplica reporting_plan_window (D8).', v_sig;
  END IF;
  -- (c) D3: el detalle no deriva ninguna hora → NINGÚN AT TIME ZONE admitido.
  IF v_def ~* 'AT\s+TIME\s+ZONE' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (zona): % aplica AT TIME ZONE y el detalle no deriva ninguna hora (D3).', v_sig;
  END IF;
  -- (d) Cero lecturas directas de public.sales: toda la población pasa por el helper.
  IF v_def ~* 'FROM\s+public\.sales\M' OR v_def ~* 'JOIN\s+public\.sales\M' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (helper): % lee public.sales por su cuenta.', v_sig;
  END IF;
  -- (e) Tenencia del producto: la RPC rechaza con P0404, no con un 0 silencioso.
  IF v_def !~ 'P0404' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (tenencia): % no declara el ERRCODE P0404 para el producto ajeno.', v_sig;
  END IF;

  RAISE NOTICE 'PASS (introspección E3): rpc_product_sales_evolution SECURITY DEFINER, ACLs exactas, helper + clamp consumidos, sin AT TIME ZONE, sin lectura directa de sales, P0404 declarado.';
END $$;

-- ── 1b. Export (grupo 8): la lista de tipos de exportación también vive en la
--       base — CHECK export_logs_type_values (20260610000000). Sin el 6º tipo
--       el archivo se genera y la cuota se cobra pero el historial de
--       /exportaciones nunca lo lista (el INSERT falla "non-fatal" en la Edge
--       Function). Hallazgo del run real de E3. ───────────────────────────────
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM pg_constraint WHERE conrelid = 'public.export_logs'::regclass AND conname = 'export_logs_type_values';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (export): falta el CHECK export_logs_type_values.';
  END IF;
  IF v_def !~ 'product_ranking_csv' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (export): el CHECK export_logs_type_values no admite product_ranking_csv — el historial de exportaciones no listaría el ranking. Def: %', v_def;
  END IF;
  -- Los 5 tipos legacy siguen admitidos (nadie los sacó al ampliar).
  IF v_def !~ 'sales_csv' OR v_def !~ 'purchases_csv' OR v_def !~ 'expenses_csv' OR v_def !~ 'stock_csv' OR v_def !~ 'full_report_xlsx' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (export): el CHECK perdió un tipo legacy. Def: %', v_def;
  END IF;
  RAISE NOTICE 'PASS (export): export_logs_type_values admite los 5 tipos legacy + product_ranking_csv.';
END $$;


-- ── 2. Comportamiento con anchor sintético ──────────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'estadisticas-ventas-e3-gate@test.local';
  v_intruder_email text := 'estadisticas-ventas-e3-gate-intruder@test.local';
  v_user      uuid;
  v_intruder  uuid;
  v_account   uuid;
  v_foreign_account uuid;
  v_branch1   uuid;
  v_today     date;
  v_monday    date;
  v_sunday    date;
  v_sat       date;
  v_fri       date;
  v_start     date;
  v_end       date;
  v_p_parent  uuid; v_p_v1 uuid; v_p_v2 uuid; v_p_alone uuid; v_p_idle uuid; v_p_foreign uuid;
  v_sale_v1_b uuid;
  v_op1 uuid := gen_random_uuid(); v_op2 uuid := gen_random_uuid(); v_op3 uuid := gen_random_uuid();
  v_op4 uuid := gen_random_uuid(); v_op5 uuid := gen_random_uuid(); v_op6 uuid := gen_random_uuid();
  v_row       record;
  v_rank      record;
  v_count     integer;
  v_sum       numeric;
  v_ops       bigint;
  v_bucket    text;
BEGIN
  -- ── Setup: anchors con provisioning automático (handle_new_user), resueltos
  -- por email ANTES de insertar (idempotente sobre la DB local compartida). ──
  SELECT id INTO v_user FROM auth.users WHERE email = v_anchor_email;
  IF v_user IS NULL THEN
    v_user := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas E3'));
  END IF;
  SELECT id INTO v_intruder FROM auth.users WHERE email = v_intruder_email;
  IF v_intruder IS NULL THEN
    v_intruder := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_intruder, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
            jsonb_build_object('name', 'Gate Estadisticas E3 Intruder'));
  END IF;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE ESTADISTICAS E3: anchor sin cuenta aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;
  SELECT account_id INTO v_foreign_account FROM public.account_members
  WHERE user_id = v_intruder ORDER BY created_at LIMIT 1;

  -- Limpieza de restos de una corrida previa cortada (los totales son exactos).
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
  DELETE FROM public.sales WHERE account_id = v_account;
  DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e3_%' AND parent_id IS NOT NULL;
  DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e3_%';
  IF v_foreign_account IS NOT NULL THEN
    DELETE FROM public.products WHERE account_id = v_foreign_account AND name LIKE '__gate_e3_%';
  END IF;

  -- Plan 'pro' explícito (1825 días de historial).
  UPDATE public.accounts
     SET billing_plan = 'pro', billing_status = 'active', trial_plan = NULL,
         trial_expires_at = NULL, plan_expires_at = NULL, billing_exempt = false
   WHERE id = v_account;

  SELECT id INTO v_branch1 FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  IF v_branch1 IS NULL THEN
    RAISE NOTICE 'GATE ESTADISTICAS E3: la cuenta no tiene sucursal aprovisionada — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Fechas relativas (fecha de negocio = día calendario, a medianoche UTC) ─
  v_today  := public.reporting_local_today();
  v_monday := date_trunc('week', v_today::timestamp)::date;  -- lunes ISO
  v_sunday := v_monday - 1;
  v_sat    := v_monday - 2;
  v_fri    := v_monday - 3;
  v_start  := v_today - 10;
  v_end    := v_today;

  -- ── Fixture: padre con 2 variantes, standalone, producto sin ventas, ajeno ─
  INSERT INTO public.products (user_id, account_id, name, sku, price, cost, category)
  VALUES (v_user, v_account, '__gate_e3_padre__', 'E3-PADRE', 1000, 100, 'Ropa') RETURNING id INTO v_p_parent;
  INSERT INTO public.products (user_id, account_id, name, sku, price, cost, parent_id, is_variant)
  VALUES (v_user, v_account, '__gate_e3_v1__', 'E3-V1', 1000, 100, v_p_parent, true) RETURNING id INTO v_p_v1;
  INSERT INTO public.products (user_id, account_id, name, sku, price, cost, parent_id, is_variant)
  VALUES (v_user, v_account, '__gate_e3_v2__', 'E3-V2', 500, 50, v_p_parent, true) RETURNING id INTO v_p_v2;
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_e3_solo__', 700, 70) RETURNING id INTO v_p_alone;
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user, v_account, '__gate_e3_quieto__', 900, 90) RETURNING id INTO v_p_idle;
  IF v_foreign_account IS NOT NULL THEN
    INSERT INTO public.products (user_id, account_id, name, price, cost)
    VALUES (v_intruder, v_foreign_account, '__gate_e3_ajeno__', 100, 10) RETURNING id INTO v_p_foreign;
  END IF;

  -- ── Fixture: ventas ───────────────────────────────────────────────────────
  -- op1 (LUNES, suc1): V1 2u × $1000 = $2000  +  SOLO 1u × $700 (misma operación).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch1, v_p_v1, 1000, 2, 2000, v_monday::timestamp AT TIME ZONE 'UTC', v_op1);
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, v_branch1, v_p_alone, 700, 1, 700, v_monday::timestamp AT TIME ZONE 'UTC', v_op1);
  -- op2 (DOMINGO, sin sucursal): V2 1u × $500.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, NULL, v_p_v2, 500, 1, 500, v_sunday::timestamp AT TIME ZONE 'UTC', v_op2);
  -- op3 (SÁBADO, sin sucursal): el PADRE vendido directo, 1u × $800.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, NULL, v_p_parent, 800, 1, 800, v_sat::timestamp AT TIME ZONE 'UTC', v_op3);
  -- op4 (VIERNES, sin sucursal): SOLO 2u × $700 = $1400.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, NULL, v_p_alone, 700, 2, 1400, v_fri::timestamp AT TIME ZONE 'UTC', v_op4);
  -- op5 (LUNES, sin sucursal): V1 1u × $1000 con snapshot de costo 400 (RN-D2).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, NULL, v_p_v1, 1000, 1, 1000, v_monday::timestamp AT TIME ZONE 'UTC', v_op5)
  RETURNING id INTO v_sale_v1_b;
  INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot)
  VALUES (v_sale_v1_b, v_p_v1, v_account, 1, 1000, 1000, 400);
  -- Z (hoy-15): V1 $333 — fuera de la ventana.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user, v_account, NULL, v_p_v1, 333, 1, 333, (v_today - 15)::timestamp AT TIME ZONE 'UTC', v_op6);

  -- Esperado para el GRUPO del padre en [hoy-10 .. hoy]:
  --   miembros con ventas: V1 (op1 2000 + op5 1000 = 3000 / 3u / 2 ops),
  --   PADRE directo (op3 800 / 1u / 1 op), V2 (op2 500 / 1u / 1 op)
  --   total: revenue 4300, units 5, ops 4, variant_count 2 (V1, V2 — el
  --   padre no se cuenta a sí mismo), is_group true, última venta = lunes.
  --   costo (cascada): op1 2×100 + op2 1×50 + op3 1×100 + op5 1×400(snapshot)
  --   = 750 → margen 3550 (82.56%); cobertura 1 de 4 líneas = 25.0%.
  -- SOLO: revenue 2100, units 3, ops 2 (op1, op4), sin variantes.

  -- ── Autorización: intruso no miembro → P0401 ──────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_intruder::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_intruder THEN
    RAISE NOTICE 'GATE ESTADISTICAS E3: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan la RPC.';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN;
  END IF;
  BEGIN
    PERFORM * FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (P0401): la RPC aceptó a un no miembro.';
  EXCEPTION WHEN SQLSTATE 'P0401' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0401): no miembro rechazado antes de leer dato alguno.';

  -- ── Sesión del anchor ────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ── P0400: bucket fuera de dominio, rango invertido ───────────────────────
  BEGIN
    PERFORM * FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'banana', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (P0400): p_bucket=banana aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_end, v_start, 'day', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (P0400): rango invertido aceptado.';
  EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0400): bucket y rango fuera de dominio rechazados.';

  -- ── P0404: producto de OTRA cuenta e inexistente → mismo error (no revela) ─
  IF v_p_foreign IS NOT NULL THEN
    BEGIN
      PERFORM * FROM public.rpc_product_sales_evolution(v_account, v_p_foreign, v_start, v_end, 'day', NULL, NULL);
      RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (P0404): la RPC devolvió el detalle de un producto de OTRA cuenta.';
    EXCEPTION WHEN SQLSTATE 'P0404' THEN NULL;
    END;
  END IF;
  BEGIN
    PERFORM * FROM public.rpc_product_sales_evolution(v_account, gen_random_uuid(), v_start, v_end, 'day', NULL, NULL);
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (P0404): un producto inexistente no fue rechazado.';
  EXCEPTION WHEN SQLSTATE 'P0404' THEN NULL;
  END;
  RAISE NOTICE 'PASS (P0404): producto ajeno e inexistente rechazados con el mismo código.';

  -- ══ PADRE: total del grupo (variantes + ventas directas) ══════════════════
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (total): falta la fila row_kind=total del padre.';
  END IF;
  IF v_row.revenue <> 4300 OR v_row.units <> 5 OR v_row.operations <> 4 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (total padre): revenue=% units=% ops=% y esperaba 4300/5/4 (V1 3000 + directo 800 + V2 500; op1 multi-línea cuenta 1).', v_row.revenue, v_row.units, v_row.operations;
  END IF;
  IF NOT v_row.is_group OR v_row.variant_count <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (grupo): is_group=% variant_count=% y esperaba true/2 (el padre no se cuenta a sí mismo).', v_row.is_group, v_row.variant_count;
  END IF;
  IF v_row.product_id <> v_p_parent OR v_row.product_name <> '__gate_e3_padre__' OR v_row.product_sku <> 'E3-PADRE'
     OR v_row.product_category <> 'Ropa' OR v_row.parent_id IS NOT NULL OR v_row.parent_name IS NOT NULL THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (cabecera padre): id=% name=% sku=% cat=% parent=% — la cabecera debe ser el propio padre, sin padre.', v_row.product_id, v_row.product_name, v_row.product_sku, v_row.product_category, v_row.parent_id;
  END IF;
  IF v_row.last_sale_date <> v_monday THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (última venta): % y esperaba el lunes % (fecha de negocio sin corrimiento).', v_row.last_sale_date, v_monday;
  END IF;
  -- D11: cascada de costo (snapshot 400 en op5, catálogo en el resto) y cobertura.
  IF v_row.total_cost <> 750 OR v_row.gross_margin <> 3550 OR v_row.gross_margin_pct <> 82.56 OR v_row.cost_coverage_pct <> 25.0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (margen): cost=% margin=% pct=% coverage=% y esperaba 750/3550/82.56/25.0 (RN-D2 + D11).', v_row.total_cost, v_row.gross_margin, v_row.gross_margin_pct, v_row.cost_coverage_pct;
  END IF;
  IF v_row.window_start <> v_start OR v_row.window_end <> v_end OR v_row.window_clamped THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (ventana): [% .. %] clamped=% — un rango dentro del plan no se recorta.', v_row.window_start, v_row.window_end, v_row.window_clamped;
  END IF;
  RAISE NOTICE 'PASS (total padre): 4300/5u/4 ops, 2 variantes, última venta lunes, margen 3550 (25%% con costo).';

  -- ══ PADRE: desglose por miembro (variantes + el padre directo) ════════════
  SELECT count(*) INTO v_count FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'member';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (miembros): esperaba 3 filas member (V1, padre directo, V2) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'member' AND r.variant_id = v_p_v1;
  IF NOT FOUND OR v_row.revenue <> 3000 OR v_row.units <> 3 OR v_row.operations <> 2 OR v_row.variant_name <> '__gate_e3_v1__' OR v_row.variant_sku <> 'E3-V1' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (miembro V1): revenue=% units=% ops=% name=% y esperaba 3000/3/2/__gate_e3_v1__.', v_row.revenue, v_row.units, v_row.operations, v_row.variant_name;
  END IF;
  IF v_row.rank <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (orden miembros): V1 (3000) debía ser el miembro 1 por importe y fue %.', v_row.rank;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'member' AND r.variant_id = v_p_parent;
  IF NOT FOUND OR v_row.revenue <> 800 OR v_row.rank <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (miembro padre directo): las ventas directas del padre deben aparecer como miembro propio (800, puesto 2); found=% revenue=% rank=%.', FOUND, v_row.revenue, v_row.rank;
  END IF;
  SELECT SUM(r.revenue), SUM(r.units), SUM(r.operations) INTO v_sum, v_count, v_ops
  FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r WHERE r.row_kind = 'member';
  IF v_sum <> 4300 OR v_count <> 5 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (identidad miembros): suma de miembros %/% ≠ total 4300/5.', v_sum, v_count;
  END IF;
  -- op1 tiene sólo una línea del grupo (V1) → las operaciones de los miembros
  -- también suman 4 acá; con una operación que abarque dos variantes no
  -- sumarían, y eso es correcto (misma salvedad que categoría en E2).
  RAISE NOTICE 'PASS (miembros): V1 3000 > padre directo 800 > V2 500; suma = total.';

  -- ══ PADRE: buckets rellenos en cero, suma = total en las 3 granularidades ═
  SELECT count(*) INTO v_count FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'bucket';
  IF v_count <> 11 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (buckets día): esperaba 11 buckets (hoy-10 .. hoy, en cero los vacíos) y hubo %.', v_count;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'bucket' AND r.bucket_start = v_monday;
  IF NOT FOUND OR v_row.revenue <> 3000 OR v_row.units <> 3 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (bucket lunes): revenue=% units=% ops=% y esperaba 3000/3/2 (op1 + op5 de V1).', v_row.revenue, v_row.units, v_row.operations;
  END IF;
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'bucket' AND r.bucket_start = v_fri;
  IF NOT FOUND OR v_row.revenue <> 0 OR v_row.operations <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (bucket vacío): el viernes (sin ventas del grupo) debe viajar en cero, no omitirse (found=% revenue=%).', FOUND, v_row.revenue;
  END IF;
  FOREACH v_bucket IN ARRAY ARRAY['day', 'week', 'month'] LOOP
    SELECT SUM(r.revenue), SUM(r.units), SUM(r.operations) INTO v_sum, v_count, v_ops
    FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, v_bucket, NULL, NULL) r WHERE r.row_kind = 'bucket';
    IF v_sum <> 4300 OR v_count <> 5 OR v_ops <> 4 THEN
      RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (identidad buckets %): %/%/% ≠ total 4300/5/4.', v_bucket, v_sum, v_count, v_ops;
    END IF;
  END LOOP;
  -- Semana ISO: la venta del domingo (op2) y las del lunes (op1/op5) caen en
  -- semanas distintas.
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'week', NULL, NULL) r
  WHERE r.row_kind = 'bucket' AND r.bucket_start = v_monday;
  IF NOT FOUND OR v_row.revenue <> 3000 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (semana ISO): la semana que abre el lunes debe traer sólo 3000 (el domingo pertenece a la anterior); found=% revenue=%.', FOUND, v_row.revenue;
  END IF;
  RAISE NOTICE 'PASS (buckets): 11 días con los vacíos en cero, lunes 3000/2, suma = total en día/semana/mes, semana ISO.';

  -- ══ IDENTIDAD con el ranking: el detalle del padre ≡ la fila agrupada ═════
  SELECT * INTO v_rank FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r
  WHERE r.product_id = v_p_parent;
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF NOT FOUND OR v_rank.units <> v_row.units OR v_rank.revenue <> v_row.revenue OR v_rank.operations <> v_row.operations
     OR v_rank.variant_count <> v_row.variant_count OR v_rank.gross_margin <> v_row.gross_margin
     OR v_rank.cost_coverage_pct <> v_row.cost_coverage_pct OR v_rank.last_sale_date <> v_row.last_sale_date THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (identidad ranking padre): ranking %/%/%/%/%/% ≠ detalle %/%/%/%/%/%.',
      v_rank.units, v_rank.revenue, v_rank.operations, v_rank.variant_count, v_rank.gross_margin, v_rank.last_sale_date,
      v_row.units, v_row.revenue, v_row.operations, v_row.variant_count, v_row.gross_margin, v_row.last_sale_date;
  END IF;
  RAISE NOTICE 'PASS (identidad ranking): el total del detalle del padre es idéntico a su fila agrupada del ranking.';

  -- ══ VARIANTE pedida directamente: sólo lo suyo, con el padre como contexto ═
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_v1, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF NOT FOUND OR v_row.revenue <> 3000 OR v_row.units <> 3 OR v_row.operations <> 2 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (variante): revenue=% units=% ops=% y esperaba 3000/3/2 (sólo V1).', v_row.revenue, v_row.units, v_row.operations;
  END IF;
  IF v_row.is_group OR v_row.variant_count <> 0 OR v_row.parent_id <> v_p_parent OR v_row.parent_name <> '__gate_e3_padre__' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (variante contexto): is_group=% variant_count=% parent=% (%) — una variante no agrupa y lleva su padre.', v_row.is_group, v_row.variant_count, v_row.parent_id, v_row.parent_name;
  END IF;
  -- Cobertura de la variante: 1 de sus 2 líneas con snapshot → 50.0; costo 2×100 + 400 = 600.
  IF v_row.total_cost <> 600 OR v_row.cost_coverage_pct <> 50.0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (variante margen): cost=% coverage=% y esperaba 600/50.0.', v_row.total_cost, v_row.cost_coverage_pct;
  END IF;
  SELECT count(*) INTO v_count FROM public.rpc_product_sales_evolution(v_account, v_p_v1, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'member';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (variante miembros): esperaba 1 fila member (ella misma) y hubo %.', v_count;
  END IF;
  -- Identidad con el ranking SIN agrupar.
  SELECT * INTO v_rank FROM public.rpc_product_ranking(v_account, v_start, v_end, 'units', false, NULL, NULL, 50, 0) r
  WHERE r.product_id = v_p_v1;
  IF NOT FOUND OR v_rank.units <> v_row.units OR v_rank.revenue <> v_row.revenue OR v_rank.gross_margin <> v_row.gross_margin THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (identidad ranking variante): ranking sin agrupar %/%/% ≠ detalle %/%/%.',
      v_rank.units, v_rank.revenue, v_rank.gross_margin, v_row.units, v_row.revenue, v_row.gross_margin;
  END IF;
  RAISE NOTICE 'PASS (variante): V1 3000/3/2 sin agrupar, padre como contexto, cobertura 50%%, idéntica al ranking sin agrupar.';

  -- ══ STANDALONE: no agrupa ═════════════════════════════════════════════════
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_alone, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF NOT FOUND OR v_row.revenue <> 2100 OR v_row.units <> 3 OR v_row.operations <> 2 OR v_row.is_group OR v_row.variant_count <> 0
     OR v_row.parent_id IS NOT NULL OR v_row.product_sku IS NOT NULL THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (standalone): revenue=% units=% ops=% is_group=% sku=% y esperaba 2100/3/2/false/NULL.', v_row.revenue, v_row.units, v_row.operations, v_row.is_group, v_row.product_sku;
  END IF;
  RAISE NOTICE 'PASS (standalone): 2100/3u/2 ops, sin variantes, sin padre.';

  -- ══ PRODUCTO SIN VENTAS en el período: cero, no error ═════════════════════
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_idle, v_start, v_end, 'day', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (sin ventas): un producto sin ventas debe devolver su fila total en cero, no ninguna fila.';
  END IF;
  IF v_row.revenue <> 0 OR v_row.units <> 0 OR v_row.operations <> 0 OR v_row.last_sale_date IS NOT NULL
     OR v_row.gross_margin IS NOT NULL OR v_row.product_name <> '__gate_e3_quieto__' THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (sin ventas): revenue=% ops=% last=% margin=% name=% — esperaba ceros, sin última venta, margen NULL y la cabecera del producto.', v_row.revenue, v_row.operations, v_row.last_sale_date, v_row.gross_margin, v_row.product_name;
  END IF;
  SELECT count(*) FILTER (WHERE r.row_kind = 'bucket'), count(*) FILTER (WHERE r.row_kind = 'member')
    INTO v_count, v_ops
  FROM public.rpc_product_sales_evolution(v_account, v_p_idle, v_start, v_end, 'day', NULL, NULL) r;
  IF v_count <> 11 OR v_ops <> 0 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (sin ventas): esperaba 11 buckets en cero y 0 miembros; hubo % / %.', v_count, v_ops;
  END IF;
  RAISE NOTICE 'PASS (sin ventas): total en cero con cabecera, 11 buckets en cero, sin miembros, margen NULL (nunca 0).';

  -- ══ FILTRO DE SUCURSAL fail-closed: bajo suc1 sólo op1 (V1 2000) ══════════
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_start, v_end, 'day', v_branch1, NULL) r
  WHERE r.row_kind = 'total';
  IF v_row.revenue <> 2000 OR v_row.units <> 2 OR v_row.operations <> 1 OR v_row.variant_count <> 1 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (filtro sucursal): bajo suc1 esperaba 2000/2/1 con 1 variante y dio %/%/%/%.', v_row.revenue, v_row.units, v_row.operations, v_row.variant_count;
  END IF;
  RAISE NOTICE 'PASS (filtro sucursal): sólo op1 bajo suc1; las ventas sin sucursal quedan fuera (fail-closed).';

  -- ══ CLAMP DE PLAN (D8) ════════════════════════════════════════════════════
  UPDATE public.accounts SET billing_plan = 'gratis' WHERE id = v_account;   -- history_days 30
  SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account, v_p_parent, v_today - 400, v_today, 'month', NULL, NULL) r
  WHERE r.row_kind = 'total';
  IF v_row.window_start <> v_today - 30 OR NOT v_row.window_clamped OR v_row.history_days <> 30 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (clamp): gratis debía recortar a [% ..] con history 30 y clamped=true; dio start=% history=% clamped=%.', v_today - 30, v_row.window_start, v_row.history_days, v_row.window_clamped;
  END IF;
  -- Con la ventana recortada la venta Z (hoy-15) SÍ entra: 4300 + 333.
  IF v_row.revenue <> 4633 THEN
    RAISE EXCEPTION 'GATE ESTADISTICAS E3 FAILED (clamp datos): la ventana recortada [hoy-30 .. hoy] debía incluir la venta de hoy-15 (4633) y dio %.', v_row.revenue;
  END IF;
  UPDATE public.accounts SET billing_plan = 'pro' WHERE id = v_account;
  RAISE NOTICE 'PASS (clamp D8): recorta a 30 días bajo gratis, lo declara y agrega sólo lo que la ventana recortada contiene.';

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
  SELECT id INTO v_user FROM auth.users WHERE email = 'estadisticas-ventas-e3-gate@test.local';
  SELECT id INTO v_intruder FROM auth.users WHERE email = 'estadisticas-ventas-e3-gate-intruder@test.local';
  IF v_user IS NULL THEN RETURN; END IF;
  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_intruder IS NOT NULL THEN
    SELECT account_id INTO v_foreign FROM public.account_members WHERE user_id = v_intruder ORDER BY created_at LIMIT 1;
  END IF;
  IF v_account IS NOT NULL THEN
    DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account);
    DELETE FROM public.sales WHERE account_id = v_account;
    DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e3_%' AND parent_id IS NOT NULL;
    DELETE FROM public.products WHERE account_id = v_account AND name LIKE '__gate_e3_%';
  END IF;
  IF v_foreign IS NOT NULL THEN
    DELETE FROM public.products WHERE account_id = v_foreign AND name LIKE '__gate_e3_%';
  END IF;
  -- Los anchors y sus cuentas aprovisionadas se dejan (el guard de vaciado de
  -- sucursal prohíbe el DELETE físico; el setup los resuelve por email).
END $$;
