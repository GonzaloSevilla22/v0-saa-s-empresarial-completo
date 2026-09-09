-- =============================================================================
-- GATE: test_products_barcode_account_scope.sql
-- CHANGE: candidato heredado de `productos-categorias-sku` (task 4.5) —
--         migración 20261031000001_products_barcode_account_scope.sql
--
-- `idx_products_barcode_unique` estaba alcanzado por `user_id` (mismo residuo
-- de tenencia que tenía el SKU antes de `20261023000001_productos_categorias_sku.sql`
-- §5). Este gate verifica el swap a `idx_products_barcode_account_unique`
-- UNIQUE (account_id, barcode) — molde exacto del ítem (10) de
-- test_bulk_upsert_products_categories.sql para el caso "mismo alcance,
-- distinto user_id", y del check estructural (1) de
-- test_product_categories_catalog.sql:
--   (1) el índice nuevo existe: UNIQUE parcial sobre (account_id, barcode),
--       predicado `barcode IS NOT NULL AND barcode <> '' AND deleted_at IS
--       NULL`, y el índice viejo `idx_products_barcode_unique` YA NO existe,
--   (2) el mismo código de barras en dos cuentas distintas está permitido,
--   (3) el mismo código de barras dos veces en la MISMA cuenta, con dos
--       user_id distintos (dos miembros), viola la unicidad — RED: hoy la
--       clave vieja es (user_id, barcode), así que dos user_id distintos NO
--       colisionan aunque compartan cuenta,
--   (4) TRIANGULATE: un producto soft-deleteado no bloquea reusar su código
--       de barras dentro de la misma cuenta (el índice es parcial sobre
--       filas vivas).
--
-- Degrade-don't-fail: si el anchor sintético no puede resolver una cuenta,
-- el gate emite NOTICE y no aborta — el check (1) no depende de datos y
-- corre siempre.
-- =============================================================================

-- ── (1) Estructura del índice (no depende de datos) ──────────────────────────
DO $$
DECLARE
  v_index_def text;
BEGIN
  SELECT indexdef INTO v_index_def
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'products'
    AND  indexname = 'idx_products_barcode_account_unique';

  IF v_index_def IS NULL THEN
    RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (1a): falta idx_products_barcode_account_unique.';
  END IF;

  IF v_index_def NOT ILIKE '%UNIQUE%' OR v_index_def NOT ILIKE '%(account_id, barcode)%' THEN
    RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (1b): el índice no es UNIQUE (account_id, barcode): %', v_index_def;
  END IF;

  IF v_index_def NOT ILIKE '%deleted_at IS NULL%' THEN
    RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (1c): el índice debe ser PARCIAL sobre filas vivas (deleted_at IS NULL): %', v_index_def;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'products' AND indexname = 'idx_products_barcode_unique'
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (1d): el índice viejo idx_products_barcode_unique (alcanzado por user_id) sigue existiendo — no deben convivir dos reglas de unicidad discrepantes.';
  END IF;

  RAISE NOTICE 'PASS (1): idx_products_barcode_account_unique presente (UNIQUE, parcial sobre filas vivas), idx_products_barcode_unique retirado.';
END $$;


-- ── (2)-(4): dos cuentas / mismo alcance con dos user_id / soft-delete ───────
DO $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_account_a    uuid;
  v_account_b    uuid;
  v_prod_a1      uuid;
  v_prod_b1      uuid;
  v_prod_a2      uuid;
  v_rejected     boolean := false;
  v_prod_a3      uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'products-barcode-scope-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Barcode Scope A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'products-barcode-scope-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Barcode Scope B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE (2-4) degradado: no se pudo resolver cuenta para los anchors sintéticos — omitido sin fallar.';
  ELSE
    -- (2) el mismo código de barras en dos cuentas distintas está permitido.
    INSERT INTO public.products (user_id, account_id, name, category, barcode, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate Barcode A1', 'Otros', '7791111111111', 10, 5, 0)
    RETURNING id INTO v_prod_a1;

    INSERT INTO public.products (user_id, account_id, name, category, barcode, price, cost, min_stock)
    VALUES (v_user_b, v_account_b, 'Gate Barcode B1', 'Otros', '7791111111111', 10, 5, 0)
    RETURNING id INTO v_prod_b1;

    IF v_prod_a1 IS NULL OR v_prod_b1 IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (2): el mismo código de barras en dos cuentas distintas debería coexistir.';
    END IF;
    RAISE NOTICE 'PASS (2): el mismo código de barras coexiste en dos cuentas distintas.';

    -- (3) mismo alcance de cuenta, dos user_id distintos (dos miembros de la
    --     MISMA cuenta A) → debe violar la unicidad. RED contra el índice
    --     viejo (user_id, barcode): v_user_b nunca escribió en account_a
    --     bajo esa clave, así que hoy NO colisiona pese a compartir cuenta.
    BEGIN
      INSERT INTO public.products (user_id, account_id, name, category, barcode, price, cost, min_stock)
      VALUES (v_user_b, v_account_a, 'Gate Barcode A2 por B', 'Otros', '7792222222222', 10, 5, 0);

      INSERT INTO public.products (user_id, account_id, name, category, barcode, price, cost, min_stock)
      VALUES (v_user_a, v_account_a, 'Gate Barcode A2 por A', 'Otros', '7792222222222', 10, 5, 0);
    EXCEPTION
      WHEN unique_violation THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (3): dos miembros de la MISMA cuenta no deberían poder repetir un código de barras.';
    END IF;
    RAISE NOTICE 'PASS (3): el código de barras es único por CUENTA, no por user_id — dos miembros no pueden repetirlo.';

    -- (4) TRIANGULATE: un producto soft-deleteado no bloquea reusar su
    --     código de barras dentro de la misma cuenta.
    UPDATE public.products SET deleted_at = now(), deleted_by = v_user_a WHERE id = v_prod_a1;

    INSERT INTO public.products (user_id, account_id, name, category, barcode, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate Barcode A1 nuevo', 'Otros', '7791111111111', 20, 10, 0)
    RETURNING id INTO v_prod_a3;

    IF v_prod_a3 IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCTS-BARCODE-ACCOUNT-SCOPE FAILED (4): reusar el código de barras de un producto soft-deleteado debería permitirse.';
    END IF;
    RAISE NOTICE 'PASS (4): un producto soft-deleteado no bloquea reusar su código de barras en la misma cuenta (TRIANGULATE).';
  END IF;

  -- Cleanup.
  DELETE FROM public.branch_stock       WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.product_attributes WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
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
      DELETE FROM public.branch_stock       WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.product_attributes WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
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
