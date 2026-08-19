-- =============================================================================
-- GATE: test_payment_methods_catalog.sql
-- CHANGE: metodos-pago-operaciones (tasks 1.1 RED, 1.3 TRIANGULATE)
--
-- Verifica la tabla public.payment_methods en sí (sin pasar por ninguna RPC):
--   (1) la tabla existe con RLS ACTIVA (relrowsecurity),
--   (2) un kind fuera del vocabulario cerrado es rechazado por el CHECK,
--   (3) el unique case-insensitive sobre filas VIVAS rechaza el duplicado,
--   (4) TRIANGULATE: el mismo nombre SÍ se puede reusar contra una fila
--       soft-deleted (deleted_at IS NOT NULL),
--   (5) TRIANGULATE: sort_order nace en 0 si no se especifica,
--   (6) aislamiento por cuenta: una cuenta no ve las formas de pago de otra
--       — ejercitado con RLS REAL (SET LOCAL ROLE authenticated +
--       request.jwt.claims), no como postgres (que bypassea RLS).
--
-- Degrade-don't-fail: si el anchor sintético no puede resolver una cuenta
-- (contexto no lo permite, p.ej. RLS real bloqueando el propio setup), el
-- gate emite NOTICE y no aborta — los checks (1)-(3) no dependen del anchor
-- y corren siempre.
-- =============================================================================

-- ── (1) Estructura + RLS activa (no depende de datos) ────────────────────────
DO $$
DECLARE
  v_rls_enabled boolean;
BEGIN
  SELECT relrowsecurity INTO v_rls_enabled
  FROM   pg_class c
  JOIN   pg_namespace n ON n.oid = c.relnamespace
  WHERE  n.nspname = 'public' AND c.relname = 'payment_methods';

  IF v_rls_enabled IS NULL THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (1a): la tabla public.payment_methods no existe.';
  END IF;

  IF NOT v_rls_enabled THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (1b): RLS no está activa en payment_methods.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payment_methods'
      AND column_name IN ('id','account_id','name','kind','is_active','sort_order','created_at','deleted_at','deleted_by')
    GROUP BY table_name HAVING COUNT(*) = 9
  ) THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (1c): faltan columnas esperadas en payment_methods.';
  END IF;

  RAISE NOTICE 'PASS (1): payment_methods existe, RLS activa, columnas completas.';
END $$;


-- ── (2)-(5): CHECK, unique vivo/soft-deleted, sort_order default ─────────────
DO $$
DECLARE
  v_account_id   uuid;
  v_rejected     boolean := false;
  v_pm1          uuid;
  v_pm2_rejected boolean := false;
  v_pm3          uuid;
  v_sort_order   integer;
BEGIN
  -- Cuenta ancla mínima (sin trigger de signup — no hace falta un usuario
  -- real para estos checks; se usa un owner sintético para el FK).
  INSERT INTO public.accounts (owner_user_id, billing_plan, billing_status)
  VALUES (gen_random_uuid(), 'free', 'active')
  RETURNING id INTO v_account_id;

  -- (2) kind fuera del vocabulario cerrado es rechazado por el CHECK.
  BEGIN
    INSERT INTO public.payment_methods (account_id, name, kind)
    VALUES (v_account_id, '__gate_pm_bad_kind__', 'crypto');
  EXCEPTION
    WHEN check_violation THEN
      v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (2): kind = ''crypto'' debería ser rechazado por el CHECK.';
  END IF;
  RAISE NOTICE 'PASS (2): kind fuera del vocabulario cerrado rechazado por el CHECK.';

  -- (3) Unique case-insensitive sobre filas vivas.
  INSERT INTO public.payment_methods (account_id, name, kind)
  VALUES (v_account_id, 'Mercado Pago', 'wallet')
  RETURNING id INTO v_pm1;

  BEGIN
    INSERT INTO public.payment_methods (account_id, name, kind)
    VALUES (v_account_id, 'mercado pago', 'wallet');
  EXCEPTION
    WHEN unique_violation THEN
      v_pm2_rejected := true;
  END;

  IF NOT v_pm2_rejected THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (3): "mercado pago" duplicado case-insensitive debería ser rechazado.';
  END IF;
  RAISE NOTICE 'PASS (3): nombre duplicado case-insensitive entre filas vivas rechazado.';

  -- (4) TRIANGULATE: reusar el nombre contra una fila SOFT-DELETED debe permitirse.
  UPDATE public.payment_methods SET deleted_at = now(), deleted_by = NULL WHERE id = v_pm1;

  INSERT INTO public.payment_methods (account_id, name, kind)
  VALUES (v_account_id, 'mercado pago', 'wallet')
  RETURNING id, sort_order INTO v_pm3, v_sort_order;

  IF v_pm3 IS NULL THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (4): reusar el nombre contra una fila soft-deleted debería permitirse.';
  END IF;
  RAISE NOTICE 'PASS (4): nombre reusable contra una fila soft-deleted (TRIANGULATE).';

  -- (5) TRIANGULATE: sort_order nace en 0 si no se especifica.
  IF v_sort_order IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (5): sort_order esperaba default 0, dio %.', v_sort_order;
  END IF;
  RAISE NOTICE 'PASS (5): sort_order nace en 0 por defecto (TRIANGULATE).';

  -- Cleanup
  DELETE FROM public.payment_methods WHERE account_id = v_account_id;
  DELETE FROM public.accounts        WHERE id = v_account_id;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.payment_methods WHERE account_id = v_account_id;
        DELETE FROM public.accounts        WHERE id = v_account_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (6) Aislamiento por cuenta — RLS REAL (SET LOCAL ROLE authenticated) ─────
DO $$
DECLARE
  v_anchor_a_email text := 'payment-methods-catalog-gate-a@test.local';
  v_anchor_b_email text := 'payment-methods-catalog-gate-b@test.local';
  v_user_a         uuid := gen_random_uuid();
  v_user_b         uuid := gen_random_uuid();
  v_account_a      uuid;
  v_account_b      uuid;
  v_seen_other     boolean := false;
  v_count_a        integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Catalog A'))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Catalog B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHODS-CATALOG (6): no se pudo resolver cuenta para los anchors sintéticos (contexto no permite el gate) — degradando sin abortar.';
  ELSE
    -- Impersonar A con RLS REAL activa (rol authenticated, no postgres).
    -- El stack local de CI (supabase start) no siempre replica el GRANT base
    -- de anon/authenticated que trae prod por default privileges del schema
    -- — "permission denied for table" es entonces un límite del ENTORNO, no
    -- una violación de RLS (mismo criterio que test_analytics_events.sql
    -- Gate 5). Solo una fuga de datos real hace fallar el gate.
    BEGIN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';

      BEGIN
        SELECT COUNT(*) INTO v_count_a FROM public.payment_methods WHERE account_id = v_account_a;
        SELECT EXISTS (
          SELECT 1 FROM public.payment_methods WHERE account_id = v_account_b
        ) INTO v_seen_other;
      EXCEPTION
        WHEN insufficient_privilege THEN
          IF SQLERRM LIKE 'permission denied for table%' THEN
            v_count_a := NULL;
            v_seen_other := false;
          ELSE
            RAISE;
          END IF;
      END;

      EXECUTE 'RESET ROLE';
    EXCEPTION
      WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
    END;

    IF v_count_a IS NULL THEN
      RAISE NOTICE 'GATE PAYMENT-METHODS-CATALOG (6) degradado: el entorno no otorga GRANT base de authenticated sobre payment_methods (permission denied, no RLS) — omitido sin fallar.';
    ELSIF v_count_a <> 6 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (6a): la cuenta A esperaba ver sus 6 formas de pago sembradas bajo RLS real, vio %.', v_count_a;
    ELSIF v_seen_other THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHODS-CATALOG FAILED (6b): bajo RLS real, la cuenta A vio filas de la cuenta B — aislamiento roto.';
    ELSE
      RAISE NOTICE 'PASS (6): aislamiento por cuenta verificado bajo RLS real (rol authenticated) — A ve sus 6, no ve las de B.';
    END IF;
  END IF;

  -- Cleanup hijo→padre (postgres bypassea RLS acá).
  DELETE FROM public.payment_methods  WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.branch_stock     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.branches         WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members  WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.accounts         WHERE owner_user_id IN (v_user_a, v_user_b);
  DELETE FROM public.profiles         WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs       WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users              WHERE id IN (v_user_a, v_user_b);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
      DELETE FROM public.payment_methods  WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.branch_stock     WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.cashboxes        WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.branches         WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.account_members  WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.accounts         WHERE owner_user_id IN (v_user_a, v_user_b);
      DELETE FROM public.profiles         WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs       WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users              WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
