-- =============================================================================
-- C-29 v21-quote-salesorder — Smoke Transaccional (DO + subtransacciones → RAISE/ROLLBACK)
-- =============================================================================
-- INSTRUCCIONES DE USO:
--   1) Aplicar primero la migración en prod (npx supabase db push).
--   2) Correr este script contra la DB real. Dos formas:
--        psql "$DATABASE_URL" -f scripts/smoke_c29_quote_salesorder.sql
--      o vía el MCP de Supabase: pasar SOLO el bloque DO $$ ... $$ a execute_sql
--      (el MCP envuelve su propia transacción; el RAISE final hace rollback).
--
-- Proyecto prod: gxdhpxvdjjkmxhdkkwyb
--
-- DISEÑO (por qué así):
--   * Corre con un rol admin (psql/MCP) donde auth.uid() es NULL. Los RPCs exigen
--     un usuario autenticado, así que inyectamos el claim JWT de un owner/admin real
--     vía set_config('request.jwt.claims', ...). is_account_writer()/current_account_ids()
--     leen ese claim contra public.account_members (writer = role owner|admin).
--   * SAVEPOINT / ROLLBACK TO NO son válidos dentro de un bloque PL/pgSQL DO
--     (dan 42601). La aislación por caso se hace con subtransacciones
--     BEGIN ... EXCEPTION WHEN OTHERS THEN ... END, y cada caso exitoso termina con
--     RAISE EXCEPTION 'SMOKE_UNDO' para revertir SUS efectos de DB. Las variables
--     PL/pgSQL NO se revierten al capturar la excepción, así que v_report se preserva.
--   * Al final, RAISE EXCEPTION 'C29_SMOKE_RESULTS ...' devuelve el reporte y aborta
--     toda la transacción (cero datos en prod). El ROLLBACK; de abajo es redundante
--     (belt-and-suspenders para el modo psql).
--
--   >>> El ERROR final "C29_SMOKE_RESULTS" es ESPERADO y contiene el reporte.
--   >>> El smoke PASA si todas las líneas del reporte dicen [OK].
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_account_id  uuid;
  v_branch_id   uuid;
  v_product_id  uuid;
  v_initial     numeric(15,4);
  v_user_id     uuid;
  v_result      jsonb;
  v_quote_id    uuid;
  v_so_id       uuid;
  v_after       numeric(15,4);
  v_op1         text;
  v_op2         text;
  v_idem4       text;
  v_report      text := E'\n';
BEGIN
  -- ── Selección robusta de datos de prueba ─────────────────────────────────────
  -- Un (account, branch activa, product) con stock >= 2 cuya cuenta tenga
  -- al menos un miembro writer (owner|admin).
  SELECT bs.account_id, bs.branch_id, bs.product_id, bs.quantity
    INTO v_account_id, v_branch_id, v_product_id, v_initial
  FROM public.branch_stock bs
  JOIN public.branches b ON b.id = bs.branch_id AND b.status = 'active'
  WHERE bs.quantity >= 2
    AND EXISTS (
      SELECT 1 FROM public.account_members am
      WHERE am.account_id = bs.account_id AND am.role IN ('owner', 'admin')
    )
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'C29_SMOKE_RESULTS %', E'\n[SKIP] No hay (cuenta con writer owner/admin + branch activa + producto con stock>=2) en la BD.';
  END IF;

  SELECT am.user_id INTO v_user_id
  FROM public.account_members am
  WHERE am.account_id = v_account_id AND am.role IN ('owner', 'admin')
  LIMIT 1;

  -- ── Inyección del claim JWT del usuario writer (sino auth.uid() = NULL) ───────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_id, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_id::text, true);

  v_report := v_report || format('setup acct=%s branch=%s prod=%s stock=%s authuid=%s',
                                 v_account_id, v_branch_id, v_product_id, v_initial, auth.uid()) || E'\n';

  -- ── CASE 1: Quote.accept() → crea SalesOrder con los mismos ítems ────────────
  BEGIN
    INSERT INTO public.quotes (account_id, branch_id, status, total, created_by, valid_until)
    VALUES (v_account_id, v_branch_id, 'sent', 100.00, v_user_id, CURRENT_DATE + 7)
    RETURNING id INTO v_quote_id;

    INSERT INTO public.quote_items (quote_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES (v_quote_id, v_account_id, v_product_id, NULL, 2, 50.00, 100.00);

    v_result := rpc_accept_quote(v_quote_id);
    v_so_id  := (v_result->>'sales_order_id')::uuid;

    IF v_so_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.sales_order_items
         WHERE sales_order_id = v_so_id AND product_id = v_product_id AND quantity = 2)
      THEN v_report := v_report || '[OK] CASE1 accept_quote -> SalesOrder + items copiados' || E'\n';
      ELSE v_report := v_report || format('[FAIL] CASE1 result=%s', v_result) || E'\n';
    END IF;

    RAISE EXCEPTION 'SMOKE_UNDO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SMOKE_UNDO' THEN
      v_report := v_report || format('[FAIL] CASE1 %s -- %s', SQLSTATE, SQLERRM) || E'\n';
    END IF;
  END;

  -- ── CASE 2: quickSale de 2 uds → branch_stock −2 + outbox SaleConfirmed ──────
  BEGIN
    v_result := rpc_quick_sale(
      p_idempotency_key  := 'smoke-c29-2-' || gen_random_uuid()::text,
      p_items            := jsonb_build_array(jsonb_build_object(
                              'product_id', v_product_id, 'unit_id', NULL,
                              'quantity', 2, 'price', 50.00, 'subtotal', 100.00)),
      p_payment_method   := 'other',
      p_branch_id        := v_branch_id,
      p_canal            := 'smoke');

    SELECT quantity INTO v_after
    FROM public.branch_stock
    WHERE branch_id = v_branch_id AND product_id = v_product_id;

    IF v_after = v_initial - 2
      THEN v_report := v_report || format('[OK] CASE2 quickSale 2 uds -> stock %s -> %s + outbox OK', v_initial, v_after) || E'\n';
      ELSE v_report := v_report || format('[FAIL] CASE2 stock esperado %s, encontrado %s', v_initial - 2, v_after) || E'\n';
    END IF;

    RAISE EXCEPTION 'SMOKE_UNDO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SMOKE_UNDO' THEN
      v_report := v_report || format('[FAIL] CASE2 %s -- %s', SQLSTATE, SQLERRM) || E'\n';
    END IF;
  END;

  -- ── CASE 3: stock 0 → P0409 stock_insuficiente ──────────────────────────────
  BEGIN
    UPDATE public.branch_stock SET quantity = 0
    WHERE branch_id = v_branch_id AND product_id = v_product_id;

    BEGIN
      v_result := rpc_quick_sale(
        p_idempotency_key  := 'smoke-c29-3-' || gen_random_uuid()::text,
        p_items            := jsonb_build_array(jsonb_build_object(
                                'product_id', v_product_id, 'unit_id', NULL,
                                'quantity', 1, 'price', 50.00, 'subtotal', 50.00)),
        p_payment_method   := 'other',
        p_branch_id        := v_branch_id,
        p_canal            := 'smoke');
      v_report := v_report || format('[FAIL] CASE3 esperaba P0409, devolvio %s', v_result) || E'\n';
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0409' OR SQLERRM LIKE '%stock_insuficiente%'
        THEN v_report := v_report || '[OK] CASE3 stock=0 -> P0409 stock_insuficiente' || E'\n';
        ELSE v_report := v_report || format('[FAIL] CASE3 inesperado %s -- %s', SQLSTATE, SQLERRM) || E'\n';
      END IF;
    END;

    RAISE EXCEPTION 'SMOKE_UNDO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SMOKE_UNDO' THEN
      v_report := v_report || format('[FAIL] CASE3 outer %s -- %s', SQLSTATE, SQLERRM) || E'\n';
    END IF;
  END;

  -- ── CASE 4: idempotencia — doble quickSale misma key → replayed=true, sin dup ─
  BEGIN
    v_idem4 := 'smoke-c29-4-' || gen_random_uuid()::text;

    v_result := rpc_quick_sale(
      p_idempotency_key  := v_idem4,
      p_items            := jsonb_build_array(jsonb_build_object(
                              'product_id', v_product_id, 'unit_id', NULL,
                              'quantity', 1, 'price', 50.00, 'subtotal', 50.00)),
      p_payment_method   := 'other',
      p_branch_id        := v_branch_id,
      p_canal            := 'smoke');
    v_op1 := v_result->>'operation_id';

    v_result := rpc_quick_sale(
      p_idempotency_key  := v_idem4,
      p_items            := jsonb_build_array(jsonb_build_object(
                              'product_id', v_product_id, 'unit_id', NULL,
                              'quantity', 1, 'price', 50.00, 'subtotal', 50.00)),
      p_payment_method   := 'other',
      p_branch_id        := v_branch_id,
      p_canal            := 'smoke');
    v_op2 := v_result->>'operation_id';

    IF (v_result->>'replayed')::boolean IS TRUE AND v_op1 = v_op2
      THEN v_report := v_report || format('[OK] CASE4 idempotente -> replayed=true, mismo operation_id=%s', v_op1) || E'\n';
      ELSE v_report := v_report || format('[FAIL] CASE4 replayed=%s op1=%s op2=%s', v_result->>'replayed', v_op1, v_op2) || E'\n';
    END IF;

    RAISE EXCEPTION 'SMOKE_UNDO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SMOKE_UNDO' THEN
      v_report := v_report || format('[FAIL] CASE4 %s -- %s', SQLSTATE, SQLERRM) || E'\n';
    END IF;
  END;

  -- Devuelve el reporte y aborta toda la transacción (rollback total, 0 datos en prod).
  RAISE EXCEPTION 'C29_SMOKE_RESULTS %', v_report;
END $$;

ROLLBACK;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verificación post-ROLLBACK (modo psql): confirmar que no quedaron residuos.
-- Todos deben ser 0.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM public.quotes        WHERE created_at  >= now() - interval '5 minutes') AS quotes_recientes,
  (SELECT COUNT(*) FROM public.sales_orders  WHERE created_at  >= now() - interval '5 minutes') AS sales_orders_recientes,
  (SELECT COUNT(*) FROM public.events        WHERE occurred_at >= now() - interval '5 minutes' AND event_type = 'SaleConfirmed') AS outbox_saleconfirmed,
  (SELECT COUNT(*) FROM public.sales         WHERE canal = 'smoke') AS sales_canal_smoke,
  (SELECT COUNT(*) FROM public.operation_idempotency WHERE idempotency_key LIKE 'smoke-c29-%') AS idempotency_smoke;
