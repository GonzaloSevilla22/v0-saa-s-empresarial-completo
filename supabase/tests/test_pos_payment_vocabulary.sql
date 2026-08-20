-- =============================================================================
-- GATE: test_pos_payment_vocabulary.sql
-- CHANGE: pos-catalogo-pagos (tasks 1.1 RED, 1.3 TRIANGULATE, 1.4 RED / 1.5 GREEN)
--
-- Un solo vocabulario (D4): el CHECK de sales_orders.payment_method SHALL
-- enumerar exactamente el mismo conjunto que payment_methods_kind_check.
-- Antes de esta migración eran 5 valores (cash,transfer,card,other,credit) vs
-- 7 (+ check,wallet) — el hot path solo aceptaba 2 en la práctica (cash/
-- other). Verifica también el mecanismo de backfill de payment_method_id
-- (D9): puebla filas legacy y es idempotente en re-ejecución.
-- =============================================================================

-- ── (1) Los dos vocabularios coinciden exactamente ────────────────────────────
DO $$
DECLARE
  v_sales_orders_set text[];
  v_catalog_set       text[];
  v_missing_in_so     text[];
  v_extra_in_so       text[];
BEGIN
  SELECT array_agg(v ORDER BY v) INTO v_sales_orders_set
  FROM unnest(ARRAY['cash','transfer','card','check','wallet','credit','other']) AS v
  WHERE EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'sales_orders_payment_method_check'
      AND pg_get_constraintdef(c.oid) LIKE '%''' || v || '''%'
  );

  SELECT array_agg(v ORDER BY v) INTO v_catalog_set
  FROM unnest(ARRAY['cash','transfer','card','check','wallet','credit','other']) AS v
  WHERE EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'payment_methods_kind_check'
      AND pg_get_constraintdef(c.oid) LIKE '%''' || v || '''%'
  );

  IF v_sales_orders_set IS DISTINCT FROM v_catalog_set THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (1): sales_orders_payment_method_check = % pero payment_methods_kind_check = % — no coinciden.',
      v_sales_orders_set, v_catalog_set;
  END IF;

  IF array_length(v_sales_orders_set, 1) <> 7 THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (1b): esperaba 7 valores en el vocabulario, hay % (%).', array_length(v_sales_orders_set, 1), v_sales_orders_set;
  END IF;

  RAISE NOTICE 'PASS (1): sales_orders_payment_method_check y payment_methods_kind_check enumeran exactamente los mismos 7 valores.';
END $$;


-- ── (2)/(3) Triangulate CHECK + mecanismo de backfill (anchor sintético) ──────
DO $$
DECLARE
  v_anchor_email  text := 'pos-payment-vocabulary-gate@test.local';
  v_user_id       uuid := gen_random_uuid();
  v_account_id    uuid;
  v_branch_id     uuid;
  v_pm_cash       uuid;
  v_so_id         uuid;
  v_rejected      boolean := false;
  v_pmid_check    uuid;
  v_before        bigint;
  v_after         bigint;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate POS Payment Vocabulary'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE POS-PAYMENT-VOCABULARY: no se pudo resolver cuenta para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;

  IF v_branch_id IS NULL OR v_pm_cash IS NULL THEN
    RAISE NOTICE 'GATE POS-PAYMENT-VOCABULARY: branch/catálogo no sembrado para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- (2) TRIANGULATE: 'wallet' (antes rechazado por el CHECK de 5) ahora pasa.
  INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
  VALUES (v_account_id, v_branch_id, 'draft', 'wallet', 100, v_user_id)
  RETURNING id INTO v_so_id;

  RAISE NOTICE 'PASS (2a): payment_method = ''wallet'' aceptado por el CHECK ampliado.';

  -- (2) 'bitcoin' sigue rechazado.
  BEGIN
    INSERT INTO public.sales_orders (account_id, branch_id, status, payment_method, total, created_by)
    VALUES (v_account_id, v_branch_id, 'draft', 'bitcoin', 100, v_user_id);
  EXCEPTION
    WHEN check_violation THEN
      v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (2b): ''bitcoin'' debería seguir siendo rechazado por el CHECK.';
  END IF;
  RAISE NOTICE 'PASS (2b): un kind fuera del catálogo (''bitcoin'') sigue rechazado.';

  -- (3) RED/GREEN backfill: fila legacy con payment_method_id NULL se puebla,
  -- y re-ejecutar el mismo UPDATE de la migración no cambia nada (idempotente).
  UPDATE public.sales_orders SET payment_method = 'cash' WHERE id = v_so_id;

  SELECT COUNT(*) INTO v_before FROM public.sales_orders WHERE id = v_so_id AND payment_method_id IS NULL;
  IF v_before <> 1 THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (3 setup): la fila de prueba debería nacer con payment_method_id NULL.';
  END IF;

  UPDATE public.sales_orders so
  SET payment_method_id = pm.id
  FROM public.payment_methods pm
  WHERE pm.account_id = so.account_id
    AND pm.kind = so.payment_method
    AND pm.deleted_at IS NULL
    AND so.payment_method_id IS NULL
    AND so.id = v_so_id;

  SELECT payment_method_id INTO v_pmid_check FROM public.sales_orders WHERE id = v_so_id;
  IF v_pmid_check IS DISTINCT FROM v_pm_cash THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (3a): el backfill debería haber imputado payment_method_id = % (Efectivo), quedó %.', v_pm_cash, v_pmid_check;
  END IF;
  RAISE NOTICE 'PASS (3a): el backfill puebla payment_method_id por kind = payment_method.';

  -- Re-ejecutar: idempotente (0 filas afectadas para esta fila, ya poblada).
  UPDATE public.sales_orders so
  SET payment_method_id = pm.id
  FROM public.payment_methods pm
  WHERE pm.account_id = so.account_id
    AND pm.kind = so.payment_method
    AND pm.deleted_at IS NULL
    AND so.payment_method_id IS NULL
    AND so.id = v_so_id;

  GET DIAGNOSTICS v_after = ROW_COUNT;
  IF v_after <> 0 THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (3b): re-ejecutar el backfill no debería tocar filas ya pobladas, tocó %.', v_after;
  END IF;
  RAISE NOTICE 'PASS (3b): el backfill es idempotente en re-ejecución (0 filas en la segunda pasada).';

  -- Cleanup hijo→padre
  DELETE FROM public.sales_orders     WHERE account_id = v_account_id;
  DELETE FROM public.payment_methods  WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches         WHERE account_id = v_account_id;
  DELETE FROM public.account_members  WHERE user_id = v_user_id;
  DELETE FROM public.accounts         WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles         WHERE id = v_user_id;
  DELETE FROM public.email_logs       WHERE user_id = v_user_id;
  DELETE FROM auth.users              WHERE id = v_user_id;

  RAISE NOTICE 'GATE POS-PAYMENT-VOCABULARY PASSED.';

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.sales_orders     WHERE account_id = v_account_id;
        DELETE FROM public.payment_methods  WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches         WHERE account_id = v_account_id;
        DELETE FROM public.account_members  WHERE user_id = v_user_id;
        DELETE FROM public.accounts         WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles   WHERE id = v_user_id;
      DELETE FROM public.email_logs WHERE user_id = v_user_id;
      DELETE FROM auth.users        WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
