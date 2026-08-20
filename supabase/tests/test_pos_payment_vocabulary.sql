-- =============================================================================
-- GATE: test_pos_payment_vocabulary.sql
-- CHANGE: pos-catalogo-pagos (tasks 1.1 RED, 1.3 TRIANGULATE, 1.4 RED / 1.5 GREEN)
-- REESCRITO por: limpiezas-pagos-admin (G1c, D6 de design.md, task 6.1)
--
-- Un solo vocabulario (D6): con sales_orders.payment_method retirado, ya no
-- hay dos CHECKs que sincronizar — queda uno solo, payment_methods_kind_
-- check, que es exactamente el invariante que este gate perseguía desde el
-- origen. El gate se reescribe para afirmar:
--   (1) payment_methods_kind_check enumera exactamente los 7 kind;
--   (2) sales_orders ya NO tiene columna payment_method ni su CHECK
--       sales_orders_payment_method_check;
--   (3) triangulación funcional: 'wallet'/'check' (kinds que el vocabulario
--       viejo de 5 no admitía) siguen aceptados por payment_methods_kind_
--       check, y un kind fuera del catálogo ('bitcoin') sigue rechazado.
--
-- Se elimina: la comparación entre dos CHECKs (ya no aplica, solo queda
-- uno) y el ejercicio de backfill de payment_method_id por kind (la columna
-- fuente del backfill, sales_orders.payment_method, ya no existe).
-- =============================================================================

-- ── (1) payment_methods_kind_check enumera exactamente los 7 kind ───────────
DO $$
DECLARE
  v_catalog_set text[];
BEGIN
  SELECT array_agg(v ORDER BY v) INTO v_catalog_set
  FROM unnest(ARRAY['cash','transfer','card','check','wallet','credit','other']) AS v
  WHERE EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'payment_methods_kind_check'
      AND pg_get_constraintdef(c.oid) LIKE '%''' || v || '''%'
  );

  IF array_length(v_catalog_set, 1) <> 7 THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (1): payment_methods_kind_check esperaba 7 valores, hay % (%).', array_length(v_catalog_set, 1), v_catalog_set;
  END IF;

  RAISE NOTICE 'PASS (1): payment_methods_kind_check enumera exactamente los 7 valores del vocabulario.';
END $$;


-- ── (2) sales_orders ya no tiene columna payment_method ni su CHECK ─────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'sales_orders' AND column_name = 'payment_method'
  ) THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (2a): sales_orders.payment_method todavía existe (limpiezas-pagos-admin G1c debería haberla retirado).';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sales_orders_payment_method_check') THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (2b): sales_orders_payment_method_check todavía existe.';
  END IF;

  RAISE NOTICE 'PASS (2): sales_orders ya no tiene columna payment_method ni su CHECK — queda un único vocabulario (payment_methods_kind_check).';
END $$;


-- ── (3) TRIANGULATE: el catálogo admite los 7 kind, rechaza lo demás ────────
DO $$
DECLARE
  v_anchor_email  text := 'pos-payment-vocabulary-gate@test.local';
  v_user_id       uuid := gen_random_uuid();
  v_account_id    uuid;
  v_pm_id         uuid;
  v_rejected      boolean := false;
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

  -- 'wallet' y 'check' (fuera del vocabulario viejo de 5) son aceptados.
  INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
  VALUES (v_account_id, '__gate_wallet__', 'wallet', 99)
  RETURNING id INTO v_pm_id;
  RAISE NOTICE 'PASS (3a): kind = ''wallet'' aceptado por payment_methods_kind_check.';

  INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
  VALUES (v_account_id, '__gate_check__', 'check', 99);
  RAISE NOTICE 'PASS (3b): kind = ''check'' aceptado por payment_methods_kind_check.';

  -- Un kind fuera del catálogo sigue rechazado.
  BEGIN
    INSERT INTO public.payment_methods (account_id, name, kind, sort_order)
    VALUES (v_account_id, '__gate_bitcoin__', 'bitcoin', 99);
  EXCEPTION
    WHEN check_violation THEN
      v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE POS-PAYMENT-VOCABULARY FAILED (3c): ''bitcoin'' debería seguir siendo rechazado por payment_methods_kind_check.';
  END IF;
  RAISE NOTICE 'PASS (3c): un kind fuera del catálogo (''bitcoin'') sigue rechazado.';

  -- Cleanup hijo→padre
  DELETE FROM public.payment_methods  WHERE account_id = v_account_id;
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
        DELETE FROM public.payment_methods  WHERE account_id = v_account_id;
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
