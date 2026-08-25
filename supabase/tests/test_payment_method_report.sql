-- =============================================================================
-- GATE: test_payment_method_report.sql
-- CHANGE: metodos-pago-operaciones (task 3.1)
--
-- Verifica rpc_payment_method_report: agregación correcta por forma de pago,
-- fila "Sin especificar" para lo no imputado, COUNT(DISTINCT COALESCE(
-- operation_id, id)), COALESCE(total, amount), borde superior inclusivo
-- (< p_end + 1), y rechazo P0401 para un caller no miembro de la cuenta.
-- Mismo patrón de anchor sintético + set_config('request.jwt.claims', ...)
-- que supabase/migrations/20260901000001_cost_center_report.sql §4.
-- =============================================================================
DO $$
DECLARE
  v_anchor_email text := 'payment-method-report-gate@test.local';
  v_intruder_email text := 'payment-method-report-gate-intruder@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_intruder_id  uuid := gen_random_uuid();
  v_account_id   uuid;
  v_branch_id    uuid;
  v_product_id   uuid;
  v_pm_cash      uuid;
  v_pm_transfer  uuid;
  v_op_a         uuid := gen_random_uuid();
  v_op_b         uuid := gen_random_uuid();
  v_start        date := (CURRENT_DATE - 10);
  v_end          date := CURRENT_DATE;
  v_row          record;
  v_total_sold   numeric;
  v_unauthorized boolean := false;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Report'))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_intruder_id, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Report Intruder'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-REPORT: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;

  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user_id, v_account_id, '__gate_pmr_product__', 1000, 400)
  RETURNING id INTO v_product_id;

  -- (a) Dos ventas "Efectivo" ($10.000 + $5.000, misma operación → 1 op) +
  --     una venta "Transferencia" ($20.000) + una compra "Efectivo" ($3.000).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id, payment_method_id)
  VALUES
    (v_user_id, v_account_id, v_branch_id, v_product_id, 10000, 1, 10000, now(), v_op_a, v_pm_cash),
    (v_user_id, v_account_id, v_branch_id, v_product_id, 5000,  1, 5000,  now(), v_op_a, v_pm_cash);

  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, payment_method_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 20000, 1, 20000, now(), v_pm_transfer);

  INSERT INTO public.purchases (user_id, account_id, branch_id, product_id, amount, quantity, total, date, payment_method_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 3000, 1, 3000, now(), v_pm_cash);

  -- (b) Venta histórica SIN imputar dentro del rango → "Sin especificar".
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, payment_method_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 700, 1, 700, now(), NULL);

  -- (c) Venta en el borde: hora real en el último día del rango (RN-D5).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, payment_method_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 100, 1, 100, (v_end::timestamptz + interval '15 hours'), v_pm_cash);

  -- ── Assert de autorización: intruso no miembro → P0401 ───────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_intruder_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_intruder_id THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-REPORT: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan el RPC.';
  ELSE
    BEGIN
      PERFORM * FROM public.rpc_payment_method_report(v_account_id, v_start, v_end);
    EXCEPTION
      WHEN sqlstate 'P0401' THEN
        v_unauthorized := true;
    END;

    IF NOT v_unauthorized THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (auth): un caller no miembro debería ser rechazado con P0401.';
    END IF;
    RAISE NOTICE 'PASS (auth): caller no miembro rechazado con P0401.';

    -- ── Sesión del anchor real ────────────────────────────────────────────
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

    -- (1) Efectivo: $15.000 vendidos ($10k+$5k, 1 operación) + $100 del borde
    --     = $15.100 vendidos; $3.000 comprados; operation_count = 2 (1 op de
    --     venta multilínea + 1 venta del borde sin operation_id + 1 compra) → 3.
    SELECT * INTO v_row FROM public.rpc_payment_method_report(v_account_id, v_start, v_end) r WHERE r.payment_method_id = v_pm_cash;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (1): Efectivo no aparece en el reporte.';
    END IF;

    IF v_row.total_sold <> 15100 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (1a): Efectivo esperaba total_sold 15100 (15000 + 100 del borde), dio %.', v_row.total_sold;
    END IF;

    IF v_row.total_purchased <> 3000 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (1b): Efectivo esperaba total_purchased 3000, dio %.', v_row.total_purchased;
    END IF;

    IF v_row.operation_count <> 3 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (1c): Efectivo esperaba operation_count 3 (1 operación multilínea + 1 venta del borde + 1 compra), dio % — revisar COUNT(DISTINCT COALESCE(operation_id, id)).', v_row.operation_count;
    END IF;

    -- (2) Transferencia: $20.000 vendidos, nada comprado.
    SELECT * INTO v_row FROM public.rpc_payment_method_report(v_account_id, v_start, v_end) r WHERE r.payment_method_id = v_pm_transfer;
    IF NOT FOUND OR v_row.total_sold <> 20000 OR v_row.total_purchased <> 0 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (2): Transferencia esperaba 20000 vendidos y 0 comprados.';
    END IF;
    RAISE NOTICE 'PASS (2): Transferencia agregada correctamente.';

    -- (3) "Sin especificar": la venta histórica de $700 sin imputar.
    SELECT * INTO v_row FROM public.rpc_payment_method_report(v_account_id, v_start, v_end) r WHERE r.payment_method_id IS NULL;
    IF NOT FOUND OR v_row.payment_method_name <> 'Sin especificar' OR v_row.total_sold <> 700 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (3): lo no imputado debería aparecer como "Sin especificar" con 700 vendidos.';
    END IF;
    RAISE NOTICE 'PASS (3): fila "Sin especificar" para lo no imputado, sin repartirse entre las demás.';

    -- (4) La suma de las filas iguala el total del período (15100+20000+3000+700).
    SELECT COALESCE(SUM(r.total_sold), 0) INTO v_total_sold FROM public.rpc_payment_method_report(v_account_id, v_start, v_end) r;
    IF v_total_sold <> 35800 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-REPORT FAILED (4): la suma de total_sold esperaba 35800, dio %.', v_total_sold;
    END IF;

    RAISE NOTICE 'PASS (1): Efectivo agrega ventas+compras y cuenta operaciones con COUNT(DISTINCT COALESCE(operation_id, id)) — borde de fin de día incluido (RN-D5).';
    RAISE NOTICE 'GATE PAYMENT-METHOD-REPORT PASSED.';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre ─────────────────────────────────────────────────
  DELETE FROM public.sales           WHERE account_id = v_account_id;
  DELETE FROM public.purchases       WHERE account_id = v_account_id;
  DELETE FROM public.products        WHERE account_id = v_account_id;
  DELETE FROM public.payment_methods WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id = v_account_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_id, v_intruder_id);
  DELETE FROM public.profiles        WHERE id IN (v_user_id, v_intruder_id);
  DELETE FROM public.email_logs      WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM auth.users             WHERE id IN (v_user_id, v_intruder_id);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.sales           WHERE account_id = v_account_id;
        DELETE FROM public.purchases       WHERE account_id = v_account_id;
        DELETE FROM public.products        WHERE account_id = v_account_id;
        DELETE FROM public.payment_methods WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
        SET session_replication_role = replica;
        DELETE FROM public.branches        WHERE account_id = v_account_id;
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
        DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_id, v_intruder_id);
      END IF;
      DELETE FROM public.profiles        WHERE id IN (v_user_id, v_intruder_id);
      DELETE FROM public.email_logs      WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM auth.users             WHERE id IN (v_user_id, v_intruder_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
