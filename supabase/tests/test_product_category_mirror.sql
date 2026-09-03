-- =============================================================================
-- GATE: test_product_category_mirror.sql
-- CHANGE: productos-categorias-sku (tasks 3.1 RED, 3.5 TRIANGULATE, 3.6)
--
-- El espejo desnormalizado products.category (TEXT) debe coincidir SIEMPRE
-- con el name de la categoría referenciada por products.category_id (D1):
--   (1) INSERT de producto con category_id → category = name,
--   (2) UPDATE de category_id → category sigue,
--   (3) UPDATE de name en product_categories → propaga a todos los productos
--       que la referencian y NO toca a los demás,
--   (4) TRIANGULATE: renombrar sin cambio efectivo → cero filas tocadas
--       (xmin de los productos intacto),
--   (5) TRIANGULATE: producto sin category_id → su category TEXT queda intacta
--       ante cualquier UPDATE,
--   (6) choke point: un camino legacy que escribe category TEXT a mano sobre
--       un producto con category_id NO puede desincronizar el espejo,
--   (7) TRIANGULATE: categoría de OTRA cuenta → rechazada (P0404),
--   (8) FK ON DELETE RESTRICT: borrar físicamente una categoría referenciada
--       falla por integridad referencial (D3),
--   (9) 3.6: el guard de soft delete (trg_guard_product_soft_delete) sigue
--       vivo y el soft delete de un producto sin stock sigue funcionando con
--       el trigger de espejo montado al lado.
-- =============================================================================

DO $$
DECLARE
  v_user_a      uuid := gen_random_uuid();
  v_user_b      uuid := gen_random_uuid();
  v_account_a   uuid;
  v_account_b   uuid;
  v_cat_ropa    uuid;
  v_cat_hogar   uuid;
  v_cat_b       uuid;
  v_prod1       uuid;
  v_prod2       uuid;
  v_prod_free   uuid;
  v_text        text;
  v_xmin_before xid;
  v_xmin_after  xid;
  v_rejected    boolean := false;
  v_sqlstate    text;
  v_deleted_at  timestamptz;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'product-category-mirror-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Mirror A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'product-category-mirror-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Mirror B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORY-MIRROR degradado: no se pudo resolver cuenta para los anchors sintéticos — omitido sin fallar.';
  ELSE
    SELECT id INTO v_cat_ropa  FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'ropa'  AND deleted_at IS NULL;
    SELECT id INTO v_cat_hogar FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'hogar' AND deleted_at IS NULL;
    SELECT id INTO v_cat_b     FROM public.product_categories WHERE account_id = v_account_b AND lower(name) = 'ropa'  AND deleted_at IS NULL;

    IF v_cat_ropa IS NULL OR v_cat_hogar IS NULL OR v_cat_b IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (0): el seed de provisioning no dejó Ropa/Hogar en las cuentas ancla.';
    END IF;

    -- (1) INSERT con category_id → espejo = name.
    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate mirror remera', v_cat_ropa, 100, 50, 0)
    RETURNING id, category INTO v_prod1, v_text;

    IF v_text IS DISTINCT FROM 'Ropa' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (1): tras INSERT con category_id=Ropa, category esperaba "Ropa", dio %.', v_text;
    END IF;
    RAISE NOTICE 'PASS (1): INSERT con category_id deja el espejo con el nombre de la categoría.';

    -- (2) UPDATE de category_id → espejo sigue.
    UPDATE public.products SET category_id = v_cat_hogar WHERE id = v_prod1;
    SELECT category INTO v_text FROM public.products WHERE id = v_prod1;
    IF v_text IS DISTINCT FROM 'Hogar' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (2): tras UPDATE category_id=Hogar, category esperaba "Hogar", dio %.', v_text;
    END IF;
    RAISE NOTICE 'PASS (2): UPDATE de category_id actualiza el espejo.';

    -- (3) Renombrar la categoría propaga sólo a quien la referencia.
    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate mirror campera', v_cat_ropa, 100, 50, 0)
    RETURNING id INTO v_prod2;

    UPDATE public.product_categories SET name = 'Indumentaria' WHERE id = v_cat_ropa;

    SELECT category INTO v_text FROM public.products WHERE id = v_prod2;
    IF v_text IS DISTINCT FROM 'Indumentaria' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (3a): renombrar Ropa→Indumentaria no propagó al producto que la referencia (category=%).', v_text;
    END IF;
    SELECT category INTO v_text FROM public.products WHERE id = v_prod1;
    IF v_text IS DISTINCT FROM 'Hogar' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (3b): el renombre de Ropa tocó un producto de Hogar (category=%).', v_text;
    END IF;
    RAISE NOTICE 'PASS (3): renombrar propaga a los productos que referencian la categoría y a ningún otro.';

    -- (4) TRIANGULATE: renombrar sin cambio efectivo → cero filas tocadas.
    SELECT xmin INTO v_xmin_before FROM public.products WHERE id = v_prod2;
    UPDATE public.product_categories SET name = 'Indumentaria' WHERE id = v_cat_ropa;
    SELECT xmin INTO v_xmin_after FROM public.products WHERE id = v_prod2;
    IF v_xmin_before IS DISTINCT FROM v_xmin_after THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (4): un renombre sin cambio efectivo reescribió filas de products (xmin % → %).', v_xmin_before, v_xmin_after;
    END IF;
    RAISE NOTICE 'PASS (4): renombre sin cambio efectivo no toca ninguna fila de products (TRIANGULATE).';

    -- (5) TRIANGULATE: producto sin category_id conserva su category TEXT.
    INSERT INTO public.products (user_id, account_id, name, category, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate mirror libre', 'Texto legado', 100, 50, 0)
    RETURNING id INTO v_prod_free;
    UPDATE public.products SET price = 120 WHERE id = v_prod_free;
    SELECT category INTO v_text FROM public.products WHERE id = v_prod_free;
    IF v_text IS DISTINCT FROM 'Texto legado' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (5): un producto sin category_id perdió su category TEXT (%).', v_text;
    END IF;
    RAISE NOTICE 'PASS (5): producto sin category_id conserva su category TEXT intacta (TRIANGULATE).';

    -- (6) Choke point: escribir category TEXT a mano con category_id informado no desincroniza.
    UPDATE public.products SET category = 'Zzz a mano' WHERE id = v_prod2;
    SELECT category INTO v_text FROM public.products WHERE id = v_prod2;
    IF v_text IS DISTINCT FROM 'Indumentaria' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (6): un UPDATE legacy de category TEXT desincronizó el espejo (category=%, esperado "Indumentaria").', v_text;
    END IF;
    RAISE NOTICE 'PASS (6): el trigger BEFORE es choke point — un UPDATE legacy de category TEXT no puede desincronizar el espejo.';

    -- (7) TRIANGULATE: categoría de OTRA cuenta → rechazada con P0404.
    BEGIN
      UPDATE public.products SET category_id = v_cat_b WHERE id = v_prod1;
    EXCEPTION
      WHEN OTHERS THEN
        v_rejected := true;
        v_sqlstate := SQLSTATE;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (7a): imputar un producto de A a una categoría de B debería ser rechazado.';
    END IF;
    IF v_sqlstate IS DISTINCT FROM 'P0404' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (7b): el rechazo esperaba SQLSTATE P0404, dio %.', v_sqlstate;
    END IF;
    RAISE NOTICE 'PASS (7): categoría de otra cuenta rechazada con P0404 (TRIANGULATE).';

    -- (8) FK ON DELETE RESTRICT sobre una categoría referenciada.
    v_rejected := false;
    BEGIN
      DELETE FROM public.product_categories WHERE id = v_cat_hogar;
    EXCEPTION
      WHEN foreign_key_violation THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (8): borrar físicamente una categoría referenciada debería fallar por FK RESTRICT.';
    END IF;
    RAISE NOTICE 'PASS (8): la fila de una categoría en uso no se puede eliminar físicamente (FK RESTRICT).';

    -- (9) 3.6: guard de soft delete intacto + soft delete de un producto sin stock funciona.
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND tgname = 'trg_guard_product_soft_delete' AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (9a): trg_guard_product_soft_delete desapareció de products.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND tgname = 'trg_product_category_mirror' AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (9b): falta trg_product_category_mirror sobre products.';
    END IF;
    UPDATE public.products SET deleted_at = now(), deleted_by = v_user_a WHERE id = v_prod_free;
    SELECT deleted_at INTO v_deleted_at FROM public.products WHERE id = v_prod_free;
    IF v_deleted_at IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-MIRROR FAILED (9c): el soft delete de un producto sin stock dejó de funcionar.';
    END IF;
    RAISE NOTICE 'PASS (9): guard de soft delete vivo y compatible con el trigger de espejo (3.6).';
  END IF;

  -- Cleanup hijo→padre.
  DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
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
      DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id IN (v_account_a, v_account_b));
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
