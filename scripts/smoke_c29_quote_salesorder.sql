-- =============================================================================
-- C-29 v21-quote-salesorder — Smoke Transaccional (BEGIN … RAISE → ROLLBACK)
-- =============================================================================
-- INSTRUCCIONES DE USO:
--   npx supabase db push    ← PRIMERO aplicar la migración en prod
--   psql $DATABASE_URL -f scripts/smoke_c29_quote_salesorder.sql
--
-- Este script usa BEGIN/SAVEPOINT + RAISE WARNING (no RAISE EXCEPTION) para
-- que cada caso se evalúe de forma independiente y al final se hace ROLLBACK
-- para no dejar datos basura en la base de producción.
--
-- Proyecto prod: gxdhpxvdjjkmxhdkkwyb
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Setup: necesitamos un account_id real, branch_id, product con stock,
--    y un user_id con rol user/admin.
-- Ajustar estas variables según el entorno de prueba.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_account_id      uuid;
  v_branch_id       uuid;
  v_product_id      uuid;
  v_unit_id         uuid;
  v_initial_stock   numeric(15,4);
  v_user_id         uuid;

  -- Resultados de los casos de prueba
  v_result          jsonb;
  v_quote_id        uuid;
  v_so_id           uuid;
  v_stock_after     numeric(15,4);
  v_op_id1          text;
  v_op_id2          text;
BEGIN
  -- ── Seleccionar datos de prueba de la BD real ──────────────────────────────
  -- Tomar el primer account que tenga al menos una branch operativa
  SELECT a.id INTO v_account_id
  FROM accounts a
  LIMIT 1;

  SELECT b.id INTO v_branch_id
  FROM branches b
  WHERE b.account_id = v_account_id
    AND b.status = 'active'
  LIMIT 1;

  -- Tomar un producto con stock disponible en esa branch
  SELECT bs.product_id, bs.unit_id, bs.quantity
  INTO v_product_id, v_unit_id, v_initial_stock
  FROM branch_stock bs
  WHERE bs.branch_id = v_branch_id
    AND bs.quantity >= 2
  LIMIT 1;

  -- Tomar un user_id con membresía en esa account
  SELECT om.user_id INTO v_user_id
  FROM org_members om
  WHERE om.account_id = v_account_id
    AND om.role IN ('user', 'admin')
  LIMIT 1;

  RAISE NOTICE '=== SMOKE C-29 ===';
  RAISE NOTICE 'account_id: %, branch_id: %, product_id: %, unit_id: %, initial_stock: %, user_id: %',
    v_account_id, v_branch_id, v_product_id, v_unit_id, v_initial_stock, v_user_id;

  IF v_account_id IS NULL THEN
    RAISE WARNING '[SKIP] No hay cuentas en la BD. Smoke no puede ejecutarse.';
    RETURN;
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE WARNING '[SKIP] No hay branch activa para account_id=%', v_account_id;
    RETURN;
  END IF;
  IF v_product_id IS NULL THEN
    RAISE WARNING '[SKIP] No hay product con stock >= 2 en branch_id=%', v_branch_id;
    RETURN;
  END IF;

  -- ─────────────────────────────────────────────────────────────────────────
  -- CASO 1: Quote.accept() → crea SalesOrder con los mismos ítems
  -- ─────────────────────────────────────────────────────────────────────────
  SAVEPOINT sp_case1;
  BEGIN
    -- Insertar quote directo (saltamos auth para el smoke)
    INSERT INTO public.quotes (account_id, branch_id, status, total, created_by)
    VALUES (v_account_id, v_branch_id, 'sent', 100.00, v_user_id)
    RETURNING id INTO v_quote_id;

    INSERT INTO public.quote_items (quote_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES (v_quote_id, v_account_id, v_product_id, v_unit_id, 2, 50.00, 100.00);

    -- Actualizar valid_until para que no esté vencida
    UPDATE public.quotes SET valid_until = CURRENT_DATE + 7 WHERE id = v_quote_id;

    -- Llamar al RPC (como si fuera el usuario autenticado)
    -- Nota: en smoke real, set local jwt = '...' del usuario
    v_result := rpc_accept_quote(v_quote_id);

    v_so_id := (v_result->>'sales_order_id')::uuid;

    IF v_so_id IS NOT NULL THEN
      RAISE NOTICE '[OK] CASO 1: quote.accept() → sales_order_id=%', v_so_id;
      -- Verificar que los ítems se copiaron
      IF EXISTS (
        SELECT 1 FROM public.sales_order_items soi
        WHERE soi.sales_order_id = v_so_id
          AND soi.product_id = v_product_id
          AND soi.quantity = 2
      ) THEN
        RAISE NOTICE '[OK] CASO 1: items copiados correctamente (qty=2, product=%)', v_product_id;
      ELSE
        RAISE WARNING '[FAIL] CASO 1: items NO copiados en sales_order_id=%', v_so_id;
      END IF;
    ELSE
      RAISE WARNING '[FAIL] CASO 1: rpc_accept_quote devolvió NULL sales_order_id. result=%', v_result;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[FAIL] CASO 1 excepción: % — %', SQLSTATE, SQLERRM;
  END;
  ROLLBACK TO sp_case1;

  -- ─────────────────────────────────────────────────────────────────────────
  -- CASO 2: quickSale de 2 uds → branch_stock decrementado en 2
  -- ─────────────────────────────────────────────────────────────────────────
  SAVEPOINT sp_case2;
  BEGIN
    v_result := rpc_quick_sale(
      p_idempotency_key  := 'smoke-c29-case2-' || gen_random_uuid()::text,
      p_client_id        := NULL,
      p_items            := jsonb_build_array(
                              jsonb_build_object(
                                'product_id', v_product_id,
                                'unit_id',    v_unit_id,
                                'quantity',   2,
                                'price',      50.00,
                                'subtotal',   100.00
                              )
                            ),
      p_payment_method   := 'other',
      p_cash_session_id  := NULL,
      p_comprobante_type := NULL,
      p_point_of_sale_id := NULL,
      p_branch_id        := v_branch_id,
      p_canal            := 'smoke_test'
    );

    SELECT bs.quantity INTO v_stock_after
    FROM branch_stock bs
    WHERE bs.branch_id = v_branch_id AND bs.product_id = v_product_id;

    IF v_stock_after = v_initial_stock - 2 THEN
      RAISE NOTICE '[OK] CASO 2: quickSale 2 uds → stock decrementó de % a %', v_initial_stock, v_stock_after;
    ELSE
      RAISE WARNING '[FAIL] CASO 2: stock esperado=%, encontrado=%', v_initial_stock - 2, v_stock_after;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[FAIL] CASO 2 excepción: % — %', SQLSTATE, SQLERRM;
  END;
  ROLLBACK TO sp_case2;

  -- ─────────────────────────────────────────────────────────────────────────
  -- CASO 3: Stock 0 → P0409 stock_insuficiente
  -- ─────────────────────────────────────────────────────────────────────────
  SAVEPOINT sp_case3;
  BEGIN
    -- Temporalmente poner stock en 0
    UPDATE branch_stock SET quantity = 0 WHERE branch_id = v_branch_id AND product_id = v_product_id;

    BEGIN
      v_result := rpc_quick_sale(
        p_idempotency_key  := 'smoke-c29-case3-' || gen_random_uuid()::text,
        p_client_id        := NULL,
        p_items            := jsonb_build_array(
                                jsonb_build_object(
                                  'product_id', v_product_id,
                                  'unit_id',    v_unit_id,
                                  'quantity',   1,
                                  'price',      50.00,
                                  'subtotal',   50.00
                                )
                              ),
        p_payment_method   := 'other',
        p_cash_session_id  := NULL,
        p_comprobante_type := NULL,
        p_point_of_sale_id := NULL,
        p_branch_id        := v_branch_id,
        p_canal            := 'smoke_test'
      );
      RAISE WARNING '[FAIL] CASO 3: debería haber lanzado P0409, pero no lo hizo. result=%', v_result;
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0409' OR SQLERRM LIKE '%stock_insuficiente%' THEN
        RAISE NOTICE '[OK] CASO 3: stock=0 → P0409 stock_insuficiente correctamente';
      ELSE
        RAISE WARNING '[FAIL] CASO 3: error inesperado: % — %', SQLSTATE, SQLERRM;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[FAIL] CASO 3 excepción outer: % — %', SQLSTATE, SQLERRM;
  END;
  ROLLBACK TO sp_case3;

  -- ─────────────────────────────────────────────────────────────────────────
  -- CASO 4: Idempotencia — doble quickSale misma key → replayed=true, sin dup
  -- ─────────────────────────────────────────────────────────────────────────
  SAVEPOINT sp_case4;
  BEGIN
    DECLARE v_idem_key text := 'smoke-c29-case4-idempotency';
    BEGIN
      v_result := rpc_quick_sale(
        p_idempotency_key  := v_idem_key,
        p_client_id        := NULL,
        p_items            := jsonb_build_array(
                                jsonb_build_object(
                                  'product_id', v_product_id,
                                  'unit_id',    v_unit_id,
                                  'quantity',   1,
                                  'price',      50.00,
                                  'subtotal',   50.00
                                )
                              ),
        p_payment_method   := 'other',
        p_cash_session_id  := NULL,
        p_comprobante_type := NULL,
        p_point_of_sale_id := NULL,
        p_branch_id        := v_branch_id,
        p_canal            := 'smoke_test'
      );
      v_op_id1 := v_result->>'operation_id';

      -- Segunda llamada con la misma key
      v_result := rpc_quick_sale(
        p_idempotency_key  := v_idem_key,
        p_client_id        := NULL,
        p_items            := jsonb_build_array(
                                jsonb_build_object(
                                  'product_id', v_product_id,
                                  'unit_id',    v_unit_id,
                                  'quantity',   1,
                                  'price',      50.00,
                                  'subtotal',   50.00
                                )
                              ),
        p_payment_method   := 'other',
        p_cash_session_id  := NULL,
        p_comprobante_type := NULL,
        p_point_of_sale_id := NULL,
        p_branch_id        := v_branch_id,
        p_canal            := 'smoke_test'
      );
      v_op_id2 := v_result->>'operation_id';

      IF (v_result->>'replayed')::boolean IS TRUE AND v_op_id1 = v_op_id2 THEN
        RAISE NOTICE '[OK] CASO 4: idempotencia OK — replayed=true, mismo operation_id=%', v_op_id1;
      ELSE
        RAISE WARNING '[FAIL] CASO 4: replayed=%, op1=%, op2=%',
          v_result->>'replayed', v_op_id1, v_op_id2;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[FAIL] CASO 4 excepción: % — %', SQLSTATE, SQLERRM;
    END;
  END;
  ROLLBACK TO sp_case4;

  RAISE NOTICE '=== FIN SMOKE C-29 — ROLLBACK TOTAL (sin efectos en prod) ===';

END $$;

ROLLBACK;
-- ─────────────────────────────────────────────────────────────────────────────
-- Verificación post-ROLLBACK: confirmar que no quedaron datos residuales
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM public.quotes WHERE created_at >= NOW() - INTERVAL '5 minutes') AS quotes_creadas_en_ultimo_minuto,
  (SELECT COUNT(*) FROM public.sales_orders WHERE created_at >= NOW() - INTERVAL '5 minutes') AS sales_orders_creadas,
  (SELECT COUNT(*) FROM public.events WHERE occurred_at >= NOW() - INTERVAL '5 minutes' AND event_type = 'SaleConfirmed') AS eventos_outbox;
-- Todos deben ser 0 (el ROLLBACK limpió todo).
