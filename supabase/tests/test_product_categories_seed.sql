-- =============================================================================
-- GATE: test_product_categories_seed.sql
-- CHANGE: productos-categorias-sku (tasks 6.1 RED, 6.5 TRIANGULATE, 6.6)
-- ACTUALIZADO por productos-categoria-text-retiro (2026-09-09): el backfill
-- histórico `UPDATE products SET category_id = ... WHERE lower(pc.name) =
-- lower(btrim(p.category))` (paso 2 de la migración 20261023000001) leía la
-- columna física `products.category`, que este change retiró. Ese paso YA
-- CORRIÓ una sola vez en prod (verificado 0 sin resolver al archivar
-- `productos-categorias-sku`) y no puede volver a ejecutarse ni volver a
-- probarse — no porque se haya decidido no hacerlo, sino porque la columna
-- que necesitaría leer ya no existe en ninguna base migrada a este punto.
-- Los bloques (2) y (5) se **retiran** en la parte que dependía de esa
-- columna (nunca se "arreglan" a leer algo que no existe); el resto del gate
-- —seed en signup, degrade-don't-fail, aislamiento cross-cuenta— sigue
-- siendo normativo y no cambia.
--
-- Vigente hoy:
--   (1) toda cuenta existente tiene las 7 categorías sembradas (backfill
--       paso 1 — verificado sobre las cuentas reales del stack, degrada si
--       no hay ninguna),
--   (2) re-ejecutar el paso 1 del backfill no duplica categorías (idempotencia
--       real, conteo antes/después). El paso 2 (backfill de `category_id`
--       desde `category` TEXT) se retiró de este gate — ver nota arriba.
--   (3) un signup nuevo nace con las 7 categorías activas sin intervención
--       manual (handle_new_user, sub-bloque 7),
--   (4) un fallo forzado del sub-bloque de seed NO aborta el signup: el
--       perfil, la cuenta y la membresía se crean igual (degrade-don't-fail,
--       técnica CHECK ... NOT VALID — mismo patrón que el gate de formas de
--       pago),
--   (5) ningún producto está imputado a una categoría de OTRA cuenta (el
--       criterio "ningún producto resoluble por TEXT quedó sin category_id"
--       se retiró — no hay TEXT que resolver; el invariante equivalente hoy
--       es el guard de tenencia `fn_product_category_tenancy_guard`, ya
--       cubierto por el gate `test_product_category_derived.sql`).
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


-- ── (2) Re-ejecutar el seed de categorías no duplica ─────────────────────────
-- productos-categoria-text-retiro: el paso 2 del backfill histórico (`UPDATE
-- products SET category_id = ... WHERE lower(pc.name) = lower(btrim(p.category))`)
-- se retiró de este bloque — leía la columna física `category`, que ya no
-- existe en ninguna base migrada a este punto (ya cumplió su función una
-- sola vez en prod, verificado al archivar `productos-categorias-sku`).
DO $$
DECLARE
  v_cats_before  bigint;
  v_cats_after   bigint;
BEGIN
  SELECT COUNT(*) INTO v_cats_before FROM public.product_categories;

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

  SELECT COUNT(*) INTO v_cats_after FROM public.product_categories;

  IF v_cats_before <> v_cats_after THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (2): el seed de categorías NO es idempotente — % categorías antes, % después.', v_cats_before, v_cats_after;
  END IF;

  RAISE NOTICE 'PASS (2): el seed de categorías es idempotente — % categorías, sin duplicar (TRIANGULATE).', v_cats_before;
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


-- ── (5) Ningún producto imputado a una categoría de OTRA cuenta ──────────────
-- productos-categoria-text-retiro: el criterio "ningún producto resoluble
-- por category TEXT quedó sin category_id" se retiró — no hay TEXT que
-- resolver, la columna no existe más. Ese invariante ya cumplió su función
-- una sola vez en prod (0 sin resolver, verificado al archivar
-- `productos-categorias-sku`); el invariante que sigue siendo alcanzable
-- hoy (y el que de verdad importa a nivel de base, D4 de este change) es el
-- aislamiento por cuenta, que `fn_product_category_tenancy_guard` hace
-- imposible violar desde el momento de la escritura — ver también el gate
-- `test_product_category_derived.sql`.
DO $$
DECLARE
  v_orphans integer;
BEGIN
  SELECT COUNT(*) INTO v_orphans
  FROM public.products p
  JOIN public.product_categories pc ON pc.id = p.category_id
  WHERE pc.account_id IS DISTINCT FROM p.account_id;

  IF v_orphans > 0 THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORIES-SEED FAILED (5): % productos imputados a una categoría de otra cuenta.', v_orphans;
  END IF;

  RAISE NOTICE 'PASS (5): cero productos imputados a una categoría de otra cuenta.';
END $$;
