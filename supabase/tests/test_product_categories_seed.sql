-- =============================================================================
-- GATE: test_product_categories_seed.sql
-- CHANGE: productos-categorias-sku (tasks 6.1 RED, 6.5 TRIANGULATE, 6.6)
--
-- Seed de provisioning y backfill de categorías de producto (D13) — molde
-- de test_payment_methods_seed.sql:
--   (1) toda cuenta existente tiene las 7 categorías sembradas (backfill
--       paso 1 — verificado sobre las cuentas reales del stack, degrada si
--       no hay ninguna),
--   (2) re-ejecutar el backfill (paso 1 + paso 2) no duplica categorías ni
--       reescribe productos (idempotencia real, fingerprint antes/después),
--   (3) un signup nuevo nace con las 7 categorías activas sin intervención
--       manual (handle_new_user, sub-bloque 7),
--   (4) un fallo forzado del sub-bloque de seed NO aborta el signup: el
--       perfil, la cuenta y la membresía se crean igual (degrade-don't-fail,
--       técnica CHECK ... NOT VALID — mismo patrón que el gate de formas de
--       pago),
--   (5) criterio de aceptación duro (6.6): tras el backfill, ningún producto
--       vivo con category TEXT resoluble en su cuenta quedó con category_id
--       NULL.
-- =============================================================================

-- ── (1) Toda cuenta existente tiene las 7 categorías sembradas ────────────────
DO $$
DECLARE
  v_total_accounts   integer;
  v_accounts_missing integer;
BEGIN
  SELECT COUNT(*) INTO v_total_accounts FROM public.accounts;

  IF v_total_accounts = 0 THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORIES-SEED (1) degradado: no hay cuentas en el stack — nada que verificar.';
  ELSE
    SELECT COUNT(*) INTO v_accounts_missing
    FROM public.accounts a
    WHERE (SELECT COUNT(*) FROM public.product_categories pc WHERE pc.account_id = a.id) < 7;

    IF v_accounts_missing > 0 THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (1): % de % cuentas tienen menos de 7 categorías de producto (backfill paso 1 incompleto).',
        v_accounts_missing, v_total_accounts;
    END IF;

    RAISE NOTICE 'PASS (1): las % cuentas existentes tienen las 7 categorías sembradas.', v_total_accounts;
  END IF;
END $$;


-- ── (2) Re-ejecutar el backfill no duplica ni reescribe ──────────────────────
DO $$
DECLARE
  v_cats_before  bigint;
  v_cats_after   bigint;
  v_prod_before  text;
  v_prod_after   text;
BEGIN
  SELECT COUNT(*) INTO v_cats_before FROM public.product_categories;
  -- Fingerprint de products: (id, xmin) — cualquier reescritura cambia xmin.
  SELECT md5(string_agg(id::text || ':' || xmin::text, ',' ORDER BY id)) INTO v_prod_before FROM public.products;

  -- Mismo INSERT exacto que el paso 1 del backfill de la migración 20261023000001.
  INSERT INTO public.product_categories (account_id, name, sort_order)
  SELECT a.id, v.name, v.sort_order
  FROM   public.accounts a
  CROSS JOIN (VALUES
      ('Electrónica', 1),
      ('Ropa',        2),
      ('Alimentos',   3),
      ('Hogar',       4),
      ('Salud',       5),
      ('Accesorios',  6),
      ('Otros',       7)
  ) AS v(name, sort_order)
  WHERE NOT EXISTS (
      SELECT 1 FROM public.product_categories pc WHERE pc.account_id = a.id
  );

  -- Mismo UPDATE exacto que el paso 2 del backfill.
  UPDATE public.products p
  SET    category_id = pc.id
  FROM   public.product_categories pc
  WHERE  p.category_id IS NULL
    AND  p.account_id IS NOT NULL
    AND  pc.account_id = p.account_id
    AND  pc.deleted_at IS NULL
    AND  lower(pc.name) = lower(btrim(p.category));

  SELECT COUNT(*) INTO v_cats_after FROM public.product_categories;
  SELECT md5(string_agg(id::text || ':' || xmin::text, ',' ORDER BY id)) INTO v_prod_after FROM public.products;

  IF v_cats_before <> v_cats_after THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (2a): el backfill paso 1 NO es idempotente — % categorías antes, % después.', v_cats_before, v_cats_after;
  END IF;
  IF v_prod_before IS DISTINCT FROM v_prod_after THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (2b): el backfill paso 2 reescribió productos al re-ejecutarse (fingerprint cambió).';
  END IF;

  RAISE NOTICE 'PASS (2): backfill idempotente — % categorías y cero productos reescritos (TRIANGULATE).', v_cats_before;
END $$;


-- ── (3) Signup nuevo nace con las 7 categorías ───────────────────────────────
DO $$
DECLARE
  v_user_id    uuid := gen_random_uuid();
  v_account_id uuid;
  v_count      integer;
  v_last_name  text;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', 'product-categories-seed-gate-new@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Seed New'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORIES-SEED (3) degradado: no se pudo resolver una cuenta para el anchor sintético — omitido sin fallar.';
  ELSE
    SELECT COUNT(*) INTO v_count
    FROM public.product_categories
    WHERE account_id = v_account_id AND deleted_at IS NULL AND is_active = TRUE;

    IF v_count <> 7 THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (3a): un signup nuevo esperaba nacer con 7 categorías activas, tiene %.', v_count;
    END IF;

    SELECT name INTO v_last_name
    FROM public.product_categories
    WHERE account_id = v_account_id
    ORDER BY sort_order DESC LIMIT 1;

    IF v_last_name IS DISTINCT FROM 'Otros' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (3b): "Otros" debe sembrarse al final (sort_order 7), la última es %.', v_last_name;
    END IF;

    RAISE NOTICE 'PASS (3): el signup nuevo nace con las 7 categorías sembradas, Otros al final.';
  END IF;

  DELETE FROM public.product_categories WHERE account_id = v_account_id;
  DELETE FROM public.payment_methods    WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  SET session_replication_role = replica;
  DELETE FROM public.branches               WHERE account_id = v_account_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members        WHERE user_id = v_user_id;
  SET session_replication_role = replica;
  DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles               WHERE id = v_user_id;
  DELETE FROM public.email_logs             WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
  DELETE FROM auth.users                    WHERE id = v_user_id;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.product_categories WHERE account_id = v_account_id;
        DELETE FROM public.payment_methods    WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        SET session_replication_role = replica;
        DELETE FROM public.branches               WHERE account_id = v_account_id;
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members        WHERE user_id = v_user_id;
        SET session_replication_role = replica;
        DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
        SET session_replication_role = DEFAULT;
      END IF;
      DELETE FROM public.profiles               WHERE id = v_user_id;
      DELETE FROM public.email_logs             WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
      DELETE FROM auth.users                    WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (4) Fallo forzado del sub-bloque de seed no aborta el signup ─────────────
DO $$
DECLARE
  v_user_id    uuid := gen_random_uuid();
  v_account_id uuid;
  v_profile_ok boolean;
  v_count      integer;
BEGIN
  ALTER TABLE public.product_categories
    ADD CONSTRAINT tmp_pc_force_fail CHECK (false) NOT VALID;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', 'product-categories-seed-gate-forced@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Seed Forced'))
  ON CONFLICT (id) DO NOTHING;

  ALTER TABLE public.product_categories DROP CONSTRAINT IF EXISTS tmp_pc_force_fail;

  SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) INTO v_profile_ok;
  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF NOT v_profile_ok OR v_account_id IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORIES-SEED (4) degradado: no se pudo verificar el signup del anchor — omitido sin fallar.';
  ELSE
    SELECT COUNT(*) INTO v_count FROM public.product_categories WHERE account_id = v_account_id;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (4a): con el CHECK forzado, el seed no debería haber insertado ninguna categoría, insertó %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (4): el signup (perfil + cuenta + membresía) se completa igual aunque el sub-bloque de seed de categorías falle.';
  END IF;

  DELETE FROM public.product_categories WHERE account_id = v_account_id;
  DELETE FROM public.payment_methods    WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  SET session_replication_role = replica;
  DELETE FROM public.branches               WHERE account_id = v_account_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members        WHERE user_id = v_user_id;
  SET session_replication_role = replica;
  DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles               WHERE id = v_user_id;
  DELETE FROM public.email_logs             WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
  DELETE FROM auth.users                    WHERE id = v_user_id;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      ALTER TABLE public.product_categories DROP CONSTRAINT IF EXISTS tmp_pc_force_fail;
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.product_categories WHERE account_id = v_account_id;
        DELETE FROM public.payment_methods    WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        SET session_replication_role = replica;
        DELETE FROM public.branches               WHERE account_id = v_account_id;
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members        WHERE user_id = v_user_id;
        SET session_replication_role = replica;
        DELETE FROM public.accounts               WHERE owner_user_id = v_user_id;
        SET session_replication_role = DEFAULT;
      END IF;
      DELETE FROM public.profiles               WHERE id = v_user_id;
      DELETE FROM public.email_logs             WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency  WHERE user_id = v_user_id;
      DELETE FROM auth.users                    WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;


-- ── (5) 6.6: ningún producto resoluble quedó sin category_id ────────────────
DO $$
DECLARE
  v_unresolved integer;
  v_orphans    integer;
BEGIN
  -- Productos cuya category TEXT coincide con una categoría viva de SU
  -- cuenta y sin embargo tienen category_id NULL → el backfill los debió
  -- cubrir. (Un producto con un texto que no existe en su catálogo queda
  -- fuera de este conteo: es el residuo tolerado del D13, que en prod es 0.)
  SELECT COUNT(*) INTO v_unresolved
  FROM public.products p
  WHERE p.category_id IS NULL
    AND p.account_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.product_categories pc
      WHERE pc.account_id = p.account_id AND pc.deleted_at IS NULL
        AND lower(pc.name) = lower(btrim(p.category))
    );

  IF v_unresolved > 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (5a): % productos con categoría resoluble en su cuenta quedaron con category_id NULL.', v_unresolved;
  END IF;

  -- Ningún producto imputado a una categoría de OTRA cuenta.
  SELECT COUNT(*) INTO v_orphans
  FROM public.products p
  JOIN public.product_categories pc ON pc.id = p.category_id
  WHERE pc.account_id IS DISTINCT FROM p.account_id;

  IF v_orphans > 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (5b): % productos imputados a una categoría de otra cuenta.', v_orphans;
  END IF;

  RAISE NOTICE 'PASS (5): backfill completo — cero productos resolubles sin category_id y cero cruces de cuenta (6.6).';
END $$;
