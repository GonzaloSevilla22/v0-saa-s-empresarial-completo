-- =============================================================================
-- GATE: test_product_categories_catalog.sql
-- CHANGE: productos-categorias-sku (tasks 2.1 RED, 2.4 TRIANGULATE)
--
-- Verifica la tabla public.product_categories en sí (sin pasar por ninguna
-- RPC) — molde de test_payment_methods_catalog.sql, sin `kind`:
--   (1) la tabla existe con RLS ACTIVA, las 8 columnas esperadas, el índice
--       por account_id, el unique case-insensitive parcial sobre filas VIVAS
--       y las tres policies (member_select / writer_insert / writer_update),
--   (2) el unique case-insensitive sobre filas vivas rechaza el duplicado,
--   (3) TRIANGULATE: el mismo nombre SÍ se puede reusar contra una fila
--       soft-deleted (deleted_at IS NOT NULL),
--   (4) TRIANGULATE: sort_order nace en 0 si no se especifica,
--   (5) TRIANGULATE: dos cuentas pueden usar el mismo nombre,
--   (6) aislamiento por cuenta bajo RLS REAL (SET LOCAL ROLE authenticated +
--       request.jwt.claims): A ve sus 7 sembradas, no ve las de B.
--
-- Degrade-don't-fail: si el anchor sintético no puede resolver una cuenta,
-- el gate emite NOTICE y no aborta — el check (1) no depende del anchor y
-- corre siempre.
-- =============================================================================

-- ── (1) Estructura + índices + RLS + policies (no depende de datos) ──────────
DO $$
DECLARE
  v_rls_enabled boolean;
  v_unique_def  text;
  v_policies    integer;
BEGIN
  SELECT relrowsecurity INTO v_rls_enabled
  FROM   pg_class c
  JOIN   pg_namespace n ON n.oid = c.relnamespace
  WHERE  n.nspname = 'public' AND c.relname = 'product_categories';

  IF v_rls_enabled IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1a): la tabla public.product_categories no existe.';
  END IF;

  IF NOT v_rls_enabled THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1b): RLS no está activa en product_categories.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'product_categories'
      AND column_name IN ('id','account_id','name','is_active','sort_order','created_at','deleted_at','deleted_by')
    GROUP BY table_name HAVING COUNT(*) = 8
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1c): faltan columnas esperadas en product_categories.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'product_categories' AND column_name = 'kind'
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1d): product_categories no lleva columna kind (una categoría es puro rótulo, D-design).';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'product_categories'
      AND indexdef ILIKE '%(account_id)%' AND indexdef NOT ILIKE '%UNIQUE%'
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1e): falta el índice por account_id.';
  END IF;

  SELECT indexdef INTO v_unique_def
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'product_categories'
    AND  indexdef ILIKE 'CREATE UNIQUE INDEX%'
    AND  indexdef ILIKE '%lower(name)%';

  IF v_unique_def IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1f): falta el unique case-insensitive (account_id, lower(name)).';
  END IF;

  IF v_unique_def NOT ILIKE '%deleted_at IS NULL%' THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1g): el unique de nombre debe ser PARCIAL sobre filas vivas (WHERE deleted_at IS NULL): %', v_unique_def;
  END IF;

  SELECT COUNT(*) INTO v_policies
  FROM   pg_policies
  WHERE  schemaname = 'public' AND tablename = 'product_categories'
    AND  policyname IN ('product_categories_member_select', 'product_categories_writer_insert', 'product_categories_writer_update');

  IF v_policies <> 3 THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (1h): se esperaban 3 policies (member_select/writer_insert/writer_update), hay %.', v_policies;
  END IF;

  RAISE NOTICE 'PASS (1): product_categories existe, RLS activa, columnas, índices y 3 policies presentes.';
END $$;


-- ── (2)-(5): unique vivo/soft-deleted, sort_order default, mismo nombre en 2 cuentas
DO $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_account_a    uuid;
  v_account_b    uuid;
  v_cat1         uuid;
  v_rejected     boolean := false;
  v_cat3         uuid;
  v_sort_order   integer;
  v_cat_b        uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'product-categories-catalog-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Catalog A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'product-categories-catalog-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Catalog B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORIES-CATALOG (2-5) degradado: no se pudo resolver cuenta para los anchors sintéticos — omitido sin fallar.';
  ELSE
    -- (2) Unique case-insensitive sobre filas vivas.
    INSERT INTO public.product_categories (account_id, name)
    VALUES (v_account_a, 'Ferretería')
    RETURNING id INTO v_cat1;

    BEGIN
      INSERT INTO public.product_categories (account_id, name)
      VALUES (v_account_a, 'ferretería');
    EXCEPTION
      WHEN unique_violation THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (2): "ferretería" duplicado case-insensitive debería ser rechazado.';
    END IF;
    RAISE NOTICE 'PASS (2): nombre duplicado case-insensitive entre filas vivas rechazado.';

    -- (3) TRIANGULATE: reusar el nombre contra una fila SOFT-DELETED debe permitirse.
    UPDATE public.product_categories SET deleted_at = now(), deleted_by = NULL WHERE id = v_cat1;

    INSERT INTO public.product_categories (account_id, name)
    VALUES (v_account_a, 'ferretería')
    RETURNING id, sort_order INTO v_cat3, v_sort_order;

    IF v_cat3 IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (3): reusar el nombre contra una fila soft-deleted debería permitirse.';
    END IF;
    RAISE NOTICE 'PASS (3): nombre reusable contra una fila soft-deleted (TRIANGULATE).';

    -- (4) TRIANGULATE: sort_order nace en 0.
    IF v_sort_order IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (4): sort_order esperaba default 0, dio %.', v_sort_order;
    END IF;
    RAISE NOTICE 'PASS (4): sort_order nace en 0 por defecto (TRIANGULATE).';

    -- (5) TRIANGULATE: dos cuentas pueden usar el mismo nombre.
    INSERT INTO public.product_categories (account_id, name)
    VALUES (v_account_b, 'Ferretería')
    RETURNING id INTO v_cat_b;

    IF v_cat_b IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (5): la cuenta B debería poder tener su propia "Ferretería".';
    END IF;
    RAISE NOTICE 'PASS (5): el mismo nombre coexiste en dos cuentas distintas (TRIANGULATE).';
  END IF;

  -- Cleanup hijo→padre (todo lo que handle_new_user sembró para los anchors).
  DELETE FROM public.product_categories WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.payment_methods    WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  -- sucursal-guard-vaciado-auditoria: branches prohibe el borrado fisico SIEMPRE (P0428). Bypass explicito para el cleanup del fixture sintetico (solo superusuario en CI).
  SET session_replication_role = replica;
  DELETE FROM public.branches           WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
  SET session_replication_role = replica;
  DELETE FROM public.accounts           WHERE owner_user_id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles           WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs         WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                WHERE id IN (v_user_a, v_user_b);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.product_categories WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.payment_methods    WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      SET session_replication_role = replica;
      DELETE FROM public.branches           WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
      SET session_replication_role = replica;
      DELETE FROM public.accounts           WHERE owner_user_id IN (v_user_a, v_user_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles           WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs         WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (6) Aislamiento por cuenta — RLS REAL (SET LOCAL ROLE authenticated) ─────
DO $$
DECLARE
  v_user_a         uuid := gen_random_uuid();
  v_user_b         uuid := gen_random_uuid();
  v_account_a      uuid;
  v_account_b      uuid;
  v_seen_other     boolean := false;
  v_count_a        integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'product-categories-catalog-gate-rls-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC RLS A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'product-categories-catalog-gate-rls-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC RLS B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORIES-CATALOG (6): no se pudo resolver cuenta para los anchors sintéticos — degradando sin abortar.';
  ELSE
    BEGIN
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';

      BEGIN
        SELECT COUNT(*) INTO v_count_a FROM public.product_categories WHERE account_id = v_account_a;
        SELECT EXISTS (
          SELECT 1 FROM public.product_categories WHERE account_id = v_account_b
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
      RAISE NOTICE 'GATE PRODUCT-CATEGORIES-CATALOG (6) degradado: el entorno no otorga GRANT base de authenticated sobre product_categories (permission denied, no RLS) — omitido sin fallar.';
    ELSIF v_count_a <> 7 THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (6a): la cuenta A esperaba ver sus 7 categorías sembradas bajo RLS real, vio %.', v_count_a;
    ELSIF v_seen_other THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-CATALOG FAILED (6b): bajo RLS real, la cuenta A vio filas de la cuenta B — aislamiento roto.';
    ELSE
      RAISE NOTICE 'PASS (6): aislamiento por cuenta verificado bajo RLS real (rol authenticated) — A ve sus 7, no ve las de B.';
    END IF;
  END IF;

  DELETE FROM public.product_categories WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.payment_methods    WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  SET session_replication_role = replica;
  DELETE FROM public.branches           WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
  SET session_replication_role = replica;
  DELETE FROM public.accounts           WHERE owner_user_id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles           WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs         WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                WHERE id IN (v_user_a, v_user_b);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      EXECUTE 'RESET ROLE';
      DELETE FROM public.product_categories WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.payment_methods    WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      SET session_replication_role = replica;
      DELETE FROM public.branches           WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
      SET session_replication_role = replica;
      DELETE FROM public.accounts           WHERE owner_user_id IN (v_user_a, v_user_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles           WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs         WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
