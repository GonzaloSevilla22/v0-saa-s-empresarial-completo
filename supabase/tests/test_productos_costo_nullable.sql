-- =============================================================================
-- GATE: test_productos_costo_nullable.sql
-- CHANGE: productos-costo-nullable
--
-- T1  — products.cost nullable, sin default (information_schema).
-- T2  — INSERT que omite cost -> cost IS NULL (no el DEFAULT 0 de antes).
-- T3  — cost=0 explícito se conserva y su margen se calcula normalmente.
-- T4  — reporting_sales_lines_in_window expone has_cost (no has_cost_snapshot):
--       true para línea sin snapshot pero con costo de catálogo; false sin
--       ninguno de los dos.
-- T5  — rpc_product_ranking: sin costo resoluble -> total_cost/gross_margin/
--       gross_margin_pct NULL y cost_coverage_pct=0; cobertura parcial (2
--       líneas, 1 con costo) -> margen sobre la cubierta y coverage=50.
-- T6  — el producto sin costo queda al final del orden por margen (NULLS LAST).
-- T7  — rpc_product_sales_evolution: las tres expresiones de cobertura
--       (total/bucket/member) devuelven margen ausente para un producto sin
--       costo.
-- T8  — rpc_product_profitability(30) (NO se reescribe): producto sin costo
--       resoluble llega con total_cost/gross_margin/gross_margin_pct NULL.
-- T9  — op_line_snapshot (D8): venta y compra de un producto sin costo
--       congelan unit_cost_snapshot ausente, no cero.
-- T10 — check_low_margin (D6): no dispara con cost NULL; sí dispara con un
--       costo real que produce margen bajo (caso positivo obligatorio).
-- T11 — rpc_bulk_upsert_products (D10): alta con cost ausente -> NULL; alta
--       con cost=0 -> 0; edición con cost ausente conserva el costo previo.
-- T12 — rpc_dashboard_kpi_summary (OQ-2=a): declara cuántos productos del
--       stock sin rotación no tienen costo; la aritmética del total no cambia.
-- T13 — ACLs de las 5 funciones reescritas (sin EXECUTE para anon, GRANT a
--       authenticated/service_role según corresponda) y una sola definición
--       viva de cada una (sin overload — gotcha 42725).
-- T14 — excepción declarada a RN-D2 (revisión ronda 2, ver design.md Non-
--       Goals): rpc_dashboard_kpi_summary.cost_per_sale y
--       rpc_dashboard_channel_margin.margin_pct SIGUEN tratando un costo
--       ausente como 0 (comportamiento idéntico al de antes de este change).
--       Gate de regresión de la excepción: si alguna migración futura
--       cambia esta aritmética sin actualizar la spec, este test lo detecta.
--
-- Degrade-don't-fail: si auth.uid() no resuelve al anchor bajo
-- request.jwt.claims local, el gate emite NOTICE y omite los bloques que
-- dependen de sesión, sin abortar (mismo patrón que los demás gates).
-- =============================================================================

-- ── T1: products.cost nullable, sin default ─────────────────────────────────
DO $$
DECLARE
  v_nullable text;
  v_default  text;
BEGIN
  SELECT is_nullable, column_default INTO v_nullable, v_default
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'cost';

  IF v_nullable IS DISTINCT FROM 'YES' THEN
    RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T1a): products.cost debe ser NULLABLE, is_nullable=%.', v_nullable;
  END IF;
  IF v_default IS NOT NULL THEN
    RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T1b): products.cost NO debe tener DEFAULT, tiene %.', v_default;
  END IF;
  RAISE NOTICE 'PASS (T1): products.cost es NULLABLE y sin DEFAULT.';
END $$;

-- ── T13: introspección de ACLs — corre ANTES de sesión de usuario ───────────
DO $$
DECLARE
  v_oid oid;
  v_fn  record;
BEGIN
  FOR v_fn IN
    SELECT * FROM (VALUES
      ('reporting_sales_lines_in_window', 'p_account_id uuid, p_start date, p_end date, p_branch_id uuid, p_canal text', false, true),
      ('rpc_product_ranking',             'p_account_id uuid, p_start date, p_end date, p_order_by text, p_group_variants boolean, p_branch_id uuid, p_canal text, p_limit integer, p_offset integer', true, true),
      ('rpc_product_sales_evolution',     'p_account_id uuid, p_product_id uuid, p_start date, p_end date, p_bucket text, p_branch_id uuid, p_canal text', true, true),
      -- importador-productos-fastapi (D4/OQ-7, 2026-09-10): revocada de
      -- `authenticated` — el backend (`rpc_import_products`) es el único
      -- camino de importación desde ese change en adelante. `expect_
      -- authenticated` pasa de `true` a `false`; `service_role` no cambia.
      ('rpc_bulk_upsert_products',        'p_rows jsonb, p_user_id uuid', false, true),
      ('rpc_dashboard_kpi_summary',       'p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid', true, true)
    ) AS t(fname, fargs, expect_authenticated, expect_service_role)
  LOOP
    SELECT p.oid INTO v_oid
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn.fname
      AND pg_get_function_identity_arguments(p.oid) = v_fn.fargs;

    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 existencia): %(%) no existe con esa firma exacta.', v_fn.fname, v_fn.fargs;
    END IF;

    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 acl anon): % no debe ser ejecutable por anon.', v_fn.fname;
    END IF;

    IF v_fn.expect_authenticated AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 acl authenticated): % debe ser ejecutable por authenticated.', v_fn.fname;
    END IF;
    IF NOT v_fn.expect_authenticated AND has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 acl authenticated negativo): % NO debe ser ejecutable por authenticated (helper interno).', v_fn.fname;
    END IF;

    IF v_fn.expect_service_role AND NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 acl service_role): % debe ser ejecutable por service_role.', v_fn.fname;
    END IF;

    -- Sin overload: una sola definición viva con ESTE nombre en public.
    IF (SELECT count(*) FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
        WHERE n2.nspname = 'public' AND p2.proname = v_fn.fname) <> 1 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T13 overload): % tiene más de una definición viva (gotcha 42725).', v_fn.fname;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (T13): ACLs exactas y sin overload en las 5 funciones reescritas/verificadas.';
END $$;

-- ── T2-T12: fixtures con sesión de usuario ───────────────────────────────────
DO $$
DECLARE
  v_anchor_email text := 'costo-nullable-gate@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_account_id   uuid;
  v_branch_id    uuid;
  v_today        date := current_date;
  v_start        date;
  v_end          date;
  v_p_none       uuid;  -- sin cost (NULL), sin snapshot -> 0% cobertura
  v_p_zero       uuid;  -- cost=0 declarado
  v_p_partial    uuid;  -- cost NULL en catálogo, 1 línea con snapshot + 1 sin
  v_sale_none    uuid;
  v_sale_zero    uuid;
  v_sale_partial_a uuid;
  v_sale_partial_b uuid;
  v_row          record;
  v_row2         record;
  v_snap         jsonb;
  v_purch_id     uuid;
  v_email_before int;
  v_email_after  int;
  v_bulk_res     jsonb;
  v_new_id       uuid;
  v_existing_id  uuid;
  v_kpi          record;
  v_resolved     boolean := false;
  v_sale_gate14  uuid;
  v_margin       record;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Costo Nullable'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE COSTO-NULLABLE degradado: no se pudo resolver la cuenta del anchor — omitido sin fallar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;

  v_start := v_today - 5;
  v_end   := v_today;

  -- ── Fixture: productos ────────────────────────────────────────────────────
  INSERT INTO public.products (user_id, account_id, name, price)  -- T2: cost OMITIDO
  VALUES (v_user_id, v_account_id, '__gate_pcn_none__', 1000) RETURNING id INTO v_p_none;

  IF (SELECT cost FROM public.products WHERE id = v_p_none) IS NOT NULL THEN
    RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T2): INSERT sin cost debía dejar cost IS NULL.';
  END IF;
  RAISE NOTICE 'PASS (T2): INSERT sin cost deja cost IS NULL (no 0).';

  INSERT INTO public.products (user_id, account_id, name, price, cost)  -- T3: cost=0 EXPLÍCITO
  VALUES (v_user_id, v_account_id, '__gate_pcn_zero__', 1000, 0) RETURNING id INTO v_p_zero;

  IF (SELECT cost FROM public.products WHERE id = v_p_zero) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T3a): cost=0 explícito debía conservarse como 0.';
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price)  -- sin cost de catálogo (partial coverage)
  VALUES (v_user_id, v_account_id, '__gate_pcn_partial__', 1000) RETURNING id INTO v_p_partial;

  -- ── Fixture: ventas ───────────────────────────────────────────────────────
  -- none: 1 línea sin snapshot, catálogo NULL -> 0% cobertura.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_p_none, 1000, 1, 1000, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
  RETURNING id INTO v_sale_none;

  -- zero: 1 línea sin snapshot, catálogo=0 -> resuelve por catálogo (has_cost=true).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_p_zero, 1000, 1, 1000, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
  RETURNING id INTO v_sale_zero;

  -- partial A: CON snapshot=200 (has_cost=true vía snapshot).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_p_partial, 1000, 1, 1000, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
  RETURNING id INTO v_sale_partial_a;
  INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot)
  VALUES (v_sale_partial_a, v_p_partial, v_account_id, 1, 1000, 1000, 200);

  -- partial B: SIN snapshot, catálogo NULL -> has_cost=false.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_p_partial, 1000, 1, 1000, (v_start + 1)::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
  RETURNING id INTO v_sale_partial_b;

  -- ── Sesión del anchor ─────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE COSTO-NULLABLE: auth.uid() no resuelve con request.jwt.claims local — se omiten los bloques que invocan RPCs.';
  ELSE
    v_resolved := true;

    -- ── T3b: margen de cost=0 se calcula normalmente (no ausente) ───────────
    SELECT * INTO v_row FROM public.rpc_product_ranking(v_account_id, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r
    WHERE r.product_id = v_p_zero;
    IF NOT FOUND OR v_row.total_cost IS DISTINCT FROM 0 OR v_row.gross_margin IS DISTINCT FROM 1000 OR v_row.gross_margin_pct IS DISTINCT FROM 100.00 OR v_row.cost_coverage_pct <> 100.0 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T3b): producto con cost=0 esperaba total_cost=0/margin=1000/pct=100/coverage=100 y dio cost=%/margin=%/pct=%/coverage=%.',
        v_row.total_cost, v_row.gross_margin, v_row.gross_margin_pct, v_row.cost_coverage_pct;
    END IF;
    RAISE NOTICE 'PASS (T3): cost=0 declarado se conserva y su margen se calcula normalmente (100%%, no ausente).';

    -- ── T4: reporting_sales_lines_in_window expone has_cost ─────────────────
    IF EXISTS (
      SELECT 1 FROM public.reporting_sales_lines_in_window(v_account_id, v_start, v_end, NULL, NULL) l
      WHERE l.sale_id = v_sale_zero AND l.has_cost IS NOT TRUE
    ) THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T4a): línea sin snapshot con costo de catálogo (0, declarado) debía tener has_cost=true.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.reporting_sales_lines_in_window(v_account_id, v_start, v_end, NULL, NULL) l
      WHERE l.sale_id = v_sale_none AND l.has_cost IS NOT FALSE
    ) THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T4b): línea sin snapshot y sin costo de catálogo debía tener has_cost=false.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.reporting_sales_lines_in_window(v_account_id, v_start, v_end, NULL, NULL) l
      WHERE l.sale_id = v_sale_partial_b AND l.has_cost IS NOT FALSE
    ) THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T4c): línea partial-B (sin snapshot, catálogo NULL) debía tener has_cost=false.';
    END IF;
    RAISE NOTICE 'PASS (T4): reporting_sales_lines_in_window expone has_cost, no has_cost_snapshot.';

    -- ── T5: rpc_product_ranking — sin costo resoluble ───────────────────────
    SELECT * INTO v_row FROM public.rpc_product_ranking(v_account_id, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r
    WHERE r.product_id = v_p_none;
    IF NOT FOUND OR v_row.total_cost IS NOT NULL OR v_row.gross_margin IS NOT NULL OR v_row.gross_margin_pct IS NOT NULL OR v_row.cost_coverage_pct <> 0 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T5a): producto sin costo resoluble esperaba total_cost/margin/pct NULL y coverage=0, dio cost=%/margin=%/pct=%/coverage=%.',
        v_row.total_cost, v_row.gross_margin, v_row.gross_margin_pct, v_row.cost_coverage_pct;
    END IF;

    -- Gemelo con cobertura parcial: 2 líneas, 1 con costo (200) -> coverage=50.
    SELECT * INTO v_row FROM public.rpc_product_ranking(v_account_id, v_start, v_end, 'units', true, NULL, NULL, 50, 0) r
    WHERE r.product_id = v_p_partial;
    IF NOT FOUND OR v_row.total_cost IS DISTINCT FROM 200 OR v_row.cost_coverage_pct <> 50.0 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T5b): cobertura parcial esperaba total_cost=200/coverage=50, dio cost=%/coverage=%.', v_row.total_cost, v_row.cost_coverage_pct;
    END IF;
    RAISE NOTICE 'PASS (T5): margen ausente sin costo resoluble; cobertura parcial declarada correctamente.';

    -- ── T6: el producto sin costo queda al final del orden por margen ───────
    SELECT * INTO v_row FROM public.rpc_product_ranking(v_account_id, v_start, v_end, 'margin', true, NULL, NULL, 50, 0) r
    ORDER BY r.rank DESC LIMIT 1;
    IF v_row.product_id <> v_p_none THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T6): el producto sin costo debía quedar último en el orden por margen, la última posición fue %.', v_row.product_name;
    END IF;
    RAISE NOTICE 'PASS (T6): el producto sin costo queda al final del ranking por margen (NULLS LAST efectivo).';

    -- ── T7: rpc_product_sales_evolution — tres expresiones de cobertura ─────
    SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account_id, v_p_none, v_start, v_end, 'day', NULL, NULL) r
    WHERE r.row_kind = 'total';
    IF NOT FOUND OR v_row.gross_margin IS NOT NULL OR v_row.gross_margin_pct IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T7 total): esperaba margen ausente, dio margin=%/pct=%.', v_row.gross_margin, v_row.gross_margin_pct;
    END IF;
    SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account_id, v_p_none, v_start, v_end, 'day', NULL, NULL) r
    WHERE r.row_kind = 'member' AND r.variant_id = v_p_none;
    IF NOT FOUND OR v_row.gross_margin IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T7 member): esperaba margen ausente para la fila member, dio margin=%.', v_row.gross_margin;
    END IF;
    SELECT * INTO v_row FROM public.rpc_product_sales_evolution(v_account_id, v_p_none, v_start, v_end, 'day', NULL, NULL) r
    WHERE r.row_kind = 'bucket' AND r.bucket_start = v_start;
    IF NOT FOUND OR v_row.gross_margin IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T7 bucket): esperaba margen ausente para el bucket con la venta, dio margin=%.', v_row.gross_margin;
    END IF;
    RAISE NOTICE 'PASS (T7): las tres expresiones de cobertura (total/bucket/member) devuelven margen ausente.';

    -- ── T8: rpc_product_profitability(30) — NO se reescribe, igual hereda ──
    SELECT * INTO v_row FROM public.rpc_product_profitability(30) r WHERE r.product_id = v_p_none;
    IF NOT FOUND OR v_row.total_cost IS NOT NULL OR v_row.gross_margin IS NOT NULL OR v_row.gross_margin_pct IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T8): rpc_product_profitability esperaba total_cost/margin/pct NULL para un producto sin costo, dio cost=%/margin=%/pct=%.', v_row.total_cost, v_row.gross_margin, v_row.gross_margin_pct;
    END IF;
    RAISE NOTICE 'PASS (T8): rpc_product_profitability hereda la ausencia sin haber sido tocada.';

    -- ── T9 (D8): op_line_snapshot congela la ausencia, venta y compra ───────
    v_snap := public.op_line_snapshot(NULL, '__gate_pcn_none__', NULL, NULL);
    IF (v_snap->>'unit_cost_snapshot') IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T9a venta): op_line_snapshot con p_cost NULL debía congelar unit_cost_snapshot NULL, dio %.', v_snap->>'unit_cost_snapshot';
    END IF;
    INSERT INTO public.sale_items (sale_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot)
    VALUES (v_sale_none, v_p_none, v_account_id, 1, 1000, 1000, (v_snap->>'unit_cost_snapshot')::numeric);
    IF (SELECT unit_cost_snapshot FROM public.sale_items WHERE sale_id = v_sale_none AND product_id = v_p_none) IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T9a persistido): la línea de venta debía persistir unit_cost_snapshot NULL.';
    END IF;

    INSERT INTO public.purchases (user_id, account_id, branch_id, amount, quantity, total, date, operation_id)
    VALUES (v_user_id, v_account_id, v_branch_id, 500, 1, 500, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
    RETURNING id INTO v_purch_id;
    v_snap := public.op_line_snapshot(NULL, '__gate_pcn_none__', NULL, NULL);
    INSERT INTO public.purchase_items (purchase_id, product_id, account_id, quantity, price, subtotal, unit_cost_snapshot)
    VALUES (v_purch_id, v_p_none, v_account_id, 1, 500, 500, (v_snap->>'unit_cost_snapshot')::numeric);
    IF (SELECT unit_cost_snapshot FROM public.purchase_items WHERE purchase_id = v_purch_id) IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T9b persistido): la línea de compra debía persistir unit_cost_snapshot NULL.';
    END IF;
    RAISE NOTICE 'PASS (T9): venta y compra de un producto sin costo congelan unit_cost_snapshot ausente (D8).';

    -- ── T10 (D6): check_low_margin no dispara con cost NULL, sí con margen bajo real ──
    SELECT count(*) INTO v_email_before FROM public.email_logs WHERE user_id = v_user_id AND event_type = 'low_margin_alert';
    INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
    VALUES (v_user_id, v_account_id, v_branch_id, v_p_none, 1000, 1, 1000, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid());
    SELECT count(*) INTO v_email_after FROM public.email_logs WHERE user_id = v_user_id AND event_type = 'low_margin_alert';
    IF v_email_after <> v_email_before THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T10a): una venta de un producto sin costo NO debía disparar la alerta de margen bajo (antes=%, después=%).', v_email_before, v_email_after;
    END IF;

    -- Caso positivo: producto con costo real que produce margen bajo (<15%).
    UPDATE public.products SET cost = 900 WHERE id = v_p_zero;  -- price=1000 -> margen 10% < 15
    INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
    VALUES (v_user_id, v_account_id, v_branch_id, v_p_zero, 1000, 1, 1000, v_start::timestamp AT TIME ZONE 'UTC', gen_random_uuid());
    SELECT count(*) INTO v_email_after FROM public.email_logs WHERE user_id = v_user_id AND event_type = 'low_margin_alert';
    IF v_email_after <= v_email_before THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T10b caso positivo): una venta con margen real del 10%% debía disparar la alerta (antes=%, después=%).', v_email_before, v_email_after;
    END IF;
    UPDATE public.products SET cost = 0 WHERE id = v_p_zero;  -- restaura para el resto del gate
    RAISE NOTICE 'PASS (T10): check_low_margin no dispara con cost NULL y sí dispara con un margen bajo real (caso positivo).';

    -- ── T11 (D10): rpc_bulk_upsert_products — tri-estado ─────────────────────
    -- (a) alta con cost ausente del JSON -> NULL.
    v_bulk_res := public.rpc_bulk_upsert_products(
      jsonb_build_array(jsonb_build_object('name', '__gate_pcn_bulk_absent__', 'sku', 'GATE-PCN-ABSENT')),
      v_user_id
    );
    SELECT id INTO v_new_id FROM public.products WHERE account_id = v_account_id AND sku = 'GATE-PCN-ABSENT';
    IF v_new_id IS NULL OR (SELECT cost FROM public.products WHERE id = v_new_id) IS NOT NULL THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T11a): alta con cost ausente del JSON debía dejar cost IS NULL.';
    END IF;

    -- (b) alta con cost=0 explícito -> 0.
    v_bulk_res := public.rpc_bulk_upsert_products(
      jsonb_build_array(jsonb_build_object('name', '__gate_pcn_bulk_zero__', 'sku', 'GATE-PCN-ZEROB', 'cost', 0)),
      v_user_id
    );
    SELECT id INTO v_new_id FROM public.products WHERE account_id = v_account_id AND sku = 'GATE-PCN-ZEROB';
    IF v_new_id IS NULL OR (SELECT cost FROM public.products WHERE id = v_new_id) IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T11b): alta con "cost":0 debía dejar cost=0.';
    END IF;

    -- (c) edición con cost ausente sobre un producto CON costo -> conserva.
    INSERT INTO public.products (user_id, account_id, name, sku, cost)
    VALUES (v_user_id, v_account_id, '__gate_pcn_bulk_existing__', 'GATE-PCN-EXIST', 777) RETURNING id INTO v_existing_id;
    v_bulk_res := public.rpc_bulk_upsert_products(
      jsonb_build_array(jsonb_build_object('name', '__gate_pcn_bulk_existing__', 'sku', 'GATE-PCN-EXIST')),
      v_user_id
    );
    IF (SELECT cost FROM public.products WHERE id = v_existing_id) IS DISTINCT FROM 777 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T11c): edición con cost ausente debía CONSERVAR el costo previo (777), dio %.', (SELECT cost FROM public.products WHERE id = v_existing_id);
    END IF;
    RAISE NOTICE 'PASS (T11): rpc_bulk_upsert_products — alta ausente->NULL, alta 0->0, edición ausente conserva.';

    -- ── T12 (OQ-2=a): rpc_dashboard_kpi_summary declara productos sin costo ──
    IF v_branch_id IS NOT NULL THEN
      INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
      VALUES (v_account_id, v_p_none, v_branch_id, 5)
      ON CONFLICT (product_id, branch_id) DO UPDATE SET quantity = 5;

      -- Ventana SIN ventas de v_p_none (todas sus ventas del fixture caen en
      -- [v_start, v_end]) — si no, la fila no calificaría como "sin rotación"
      -- y el test no ejercitaría nada.
      SELECT * INTO v_kpi FROM public.rpc_dashboard_kpi_summary(
        (v_today + 10)::timestamptz, (v_today + 11)::timestamptz,
        (v_today + 20)::timestamptz, (v_today + 21)::timestamptz,
        v_branch_id
      );
      IF v_kpi.stagnant_stock_without_cost_count IS NULL OR v_kpi.stagnant_stock_without_cost_count < 1 THEN
        RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T12): esperaba stagnant_stock_without_cost_count >= 1 (v_p_none sin costo, con stock, sin ventas en la ventana previa), dio %.', v_kpi.stagnant_stock_without_cost_count;
      END IF;
      RAISE NOTICE 'PASS (T12): rpc_dashboard_kpi_summary declara cuántos productos del stock sin rotación no tienen costo (%).', v_kpi.stagnant_stock_without_cost_count;
    ELSE
      RAISE NOTICE 'GATE COSTO-NULLABLE: sin sucursal auto-provisionada — se omite T12 sin fallar.';
    END IF;

    -- ── T14 — excepción declarada a RN-D2: rpc_dashboard_kpi_summary.cost_per_sale
    -- y rpc_dashboard_channel_margin.margin_pct sobre un producto sin costo,
    -- sin línea de snapshot, en una ventana aislada (una sola venta, sin
    -- ningún otro fixture de este archivo). El costo ausente contribuye 0 al
    -- COGS — igual que un `cost=0` hoy — así que cost_per_sale=0 y
    -- margin_pct=100. Si algún día se decide "arreglar" esto, este test
    -- fallará y obligará a actualizar la spec en el mismo PR.
    INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
    VALUES (v_user_id, v_account_id, v_branch_id, v_p_none, 500, 1, 500, (v_today + 30)::timestamp AT TIME ZONE 'UTC', gen_random_uuid())
    RETURNING id INTO v_sale_gate14;

    SELECT * INTO v_kpi FROM public.rpc_dashboard_kpi_summary(
      (v_today + 30)::timestamptz, (v_today + 30)::timestamptz,
      (v_today + 31)::timestamptz, (v_today + 31)::timestamptz,
      NULL
    );
    IF v_kpi.cost_per_sale IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T14a): rpc_dashboard_kpi_summary.cost_per_sale esperaba 0 (costo ausente = excepción declarada a RN-D2), dio %.', v_kpi.cost_per_sale;
    END IF;

    SELECT * INTO v_margin FROM public.rpc_dashboard_channel_margin(
      (v_today + 30)::timestamptz, (v_today + 30)::timestamptz,
      (v_today + 31)::timestamptz, (v_today + 31)::timestamptz,
      NULL
    );
    IF v_margin.margin_pct IS DISTINCT FROM 100 THEN
      RAISE EXCEPTION 'GATE COSTO-NULLABLE FAILED (T14b): rpc_dashboard_channel_margin.margin_pct esperaba 100 (costo ausente = excepción declarada a RN-D2), dio %.', v_margin.margin_pct;
    END IF;
    RAISE NOTICE 'PASS (T14): rpc_dashboard_kpi_summary/rpc_dashboard_channel_margin conservan la excepción declarada a RN-D2 (costo ausente = 0, sin cambios).';

    DELETE FROM public.sales WHERE id = v_sale_gate14;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre ────────────────────────────────────────────────────
  DELETE FROM public.branch_stock WHERE product_id IN (v_p_none, v_p_zero, v_p_partial);
  DELETE FROM public.sale_items WHERE sale_id IN (v_sale_none, v_sale_zero, v_sale_partial_a, v_sale_partial_b);
  DELETE FROM public.sales WHERE account_id = v_account_id AND product_id IN (v_p_none, v_p_zero, v_p_partial);
  DELETE FROM public.purchase_items WHERE purchase_id = v_purch_id;
  DELETE FROM public.purchases WHERE id = v_purch_id;
  DELETE FROM public.email_logs WHERE user_id = v_user_id;
  DELETE FROM public.products WHERE account_id = v_account_id
    AND name LIKE '__gate_pcn_%';
  DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
  DELETE FROM public.account_members WHERE user_id = v_user_id;
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a
  -- branches (ON DELETE CASCADE) y trg_guard_branch_decommission prohibe TODO
  -- borrado físico de una sucursal (P0428) — bypass explícito para el
  -- cleanup del fixture sintético. session_replication_role sólo lo puede
  -- fijar un rol con privilegio de superusuario (postgres en CI); no abre
  -- ningún camino para authenticated/anon vía PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = v_user_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = v_user_id;
  DELETE FROM auth.users WHERE id = v_user_id;

  IF v_resolved THEN
    RAISE NOTICE 'GATE COSTO-NULLABLE PASSED.';
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      DELETE FROM public.branch_stock WHERE product_id IN (v_p_none, v_p_zero, v_p_partial);
      DELETE FROM public.sale_items WHERE sale_id IN (v_sale_none, v_sale_zero, v_sale_partial_a, v_sale_partial_b);
      DELETE FROM public.sales WHERE account_id = v_account_id AND product_id IN (v_p_none, v_p_zero, v_p_partial);
      IF v_purch_id IS NOT NULL THEN
        DELETE FROM public.purchase_items WHERE purchase_id = v_purch_id;
        DELETE FROM public.purchases WHERE id = v_purch_id;
      END IF;
      DELETE FROM public.email_logs WHERE user_id = v_user_id;
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.products WHERE account_id = v_account_id AND name LIKE '__gate_pcn_%';
      END IF;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM public.account_members WHERE user_id = v_user_id;
      SET session_replication_role = replica;
      DELETE FROM public.accounts WHERE owner_user_id = v_user_id;
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles WHERE id = v_user_id;
      DELETE FROM auth.users WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
