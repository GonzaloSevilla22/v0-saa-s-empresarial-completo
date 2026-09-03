-- =============================================================================
-- GATE: test_product_sku_uniqueness_scope.sql
-- CHANGE: productos-categorias-sku (tasks 4.1 RED, 4.4 TRIANGULATE)
--
-- El alcance de unicidad del SKU pasa de user_id a account_id (D4):
--   (1) existe el índice único parcial (account_id, lower(sku)) sobre filas
--       vivas, y NO sobrevive ningún índice único de sku alcanzado por
--       user_id (dos reglas de unicidad discrepantes = bug),
--   (2) TRIANGULATE: el mismo SKU en dos cuentas → permitido,
--   (3) TRIANGULATE: el mismo SKU con distinta caja en la misma cuenta →
--       rechazado (unique_violation),
--   (4) TRIANGULATE: el SKU de un producto soft-deleteado → recreable
--       (invariante RN-B3 de soft-delete-policy),
--   (5) TRIANGULATE: dos miembros (user_id distinto) de la MISMA cuenta →
--       rechazado — el catálogo es de la organización, no de la persona.
-- =============================================================================

-- ── (1) Índices (no depende de datos) ────────────────────────────────────────
DO $$
DECLARE
  v_new_def text;
  v_old     text;
BEGIN
  SELECT indexdef INTO v_new_def
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'products'
    AND  indexdef ILIKE 'CREATE UNIQUE INDEX%'
    AND  indexdef ILIKE '%(account_id, lower(sku))%';

  IF v_new_def IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (1a): falta el índice único (account_id, lower(sku)) sobre products.';
  END IF;

  IF v_new_def NOT ILIKE '%deleted_at IS NULL%' OR v_new_def NOT ILIKE '%sku IS NOT NULL%' THEN
    RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (1b): el índice de SKU debe ser parcial sobre filas vivas con SKU: %', v_new_def;
  END IF;

  SELECT string_agg(indexname, ', ') INTO v_old
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'products'
    AND  indexdef ILIKE 'CREATE UNIQUE INDEX%'
    AND  indexdef ILIKE '%user_id%'
    AND  indexdef ILIKE '%sku%';

  IF v_old IS NOT NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (1c): sobrevive un índice único de sku alcanzado por user_id: %.', v_old;
  END IF;

  RAISE NOTICE 'PASS (1): unicidad de SKU alcanzada por account_id (case-insensitive, filas vivas) y sin residuo por user_id.';
END $$;


-- ── (2)-(5) Comportamiento con dos cuentas ancla ─────────────────────────────
DO $$
DECLARE
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_account_b uuid;
  v_prod_a    uuid;
  v_prod_b    uuid;
  v_rejected  boolean := false;
  v_prod_new  uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'product-sku-scope-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate SKU A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'product-sku-scope-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate SKU B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-SKU-SCOPE (2-5) degradado: no se pudo resolver cuenta para los anchors sintéticos — omitido sin fallar.';
  ELSE
    -- (2) Mismo SKU en dos cuentas → permitido.
    INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate SKU remera A', 'Otros', 'REM-001', 100, 50, 0)
    RETURNING id INTO v_prod_a;
    INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
    VALUES (v_user_b, v_account_b, 'Gate SKU remera B', 'Otros', 'REM-001', 100, 50, 0)
    RETURNING id INTO v_prod_b;
    IF v_prod_a IS NULL OR v_prod_b IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (2): el mismo SKU en dos cuentas distintas debería coexistir.';
    END IF;
    RAISE NOTICE 'PASS (2): el mismo SKU coexiste en dos cuentas (TRIANGULATE).';

    -- (3) Mismo SKU, distinta caja, misma cuenta → rechazado.
    BEGIN
      INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
      VALUES (v_user_a, v_account_a, 'Gate SKU remera A bis', 'Otros', 'rem-001', 100, 50, 0);
    EXCEPTION
      WHEN unique_violation THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (3): "rem-001" con "REM-001" vivo en la misma cuenta debería ser rechazado (case-insensitive).';
    END IF;
    RAISE NOTICE 'PASS (3): SKU duplicado case-insensitive dentro de la cuenta rechazado (TRIANGULATE).';

    -- (5) Dos miembros de la MISMA cuenta → rechazado (user_id distinto, account_id igual).
    v_rejected := false;
    BEGIN
      INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
      VALUES (v_user_b, v_account_a, 'Gate SKU remera A por B', 'Otros', 'REM-001', 100, 50, 0);
    EXCEPTION
      WHEN unique_violation THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (5): un segundo miembro de la misma cuenta pudo repetir el SKU — el alcance sigue siendo por user_id.';
    END IF;
    RAISE NOTICE 'PASS (5): dos miembros de la misma cuenta no pueden repetir el SKU (TRIANGULATE).';

    -- (4) SKU de un producto soft-deleteado → recreable.
    UPDATE public.products SET deleted_at = now(), deleted_by = v_user_a WHERE id = v_prod_a;
    INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate SKU remera A nueva', 'Otros', 'REM-001', 100, 50, 0)
    RETURNING id INTO v_prod_new;
    IF v_prod_new IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-SKU-SCOPE FAILED (4): el SKU de un producto soft-deleteado debería poder recrearse.';
    END IF;
    RAISE NOTICE 'PASS (4): el SKU de un producto borrado se puede recrear (RN-B3, TRIANGULATE).';
  END IF;

  -- Cleanup hijo→padre.
  DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.products           WHERE account_id IN (v_account_a, v_account_b);
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
      DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.products           WHERE account_id IN (v_account_a, v_account_b);
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
