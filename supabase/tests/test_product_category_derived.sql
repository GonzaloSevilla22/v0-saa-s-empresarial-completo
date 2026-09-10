-- =============================================================================
-- GATE: test_product_category_derived.sql
-- CHANGE: productos-categoria-text-retiro (reemplaza a test_product_category_mirror.sql)
--
-- products.category (TEXT) fue retirada: la categoría tiene una sola
-- representación física (category_id) y su nombre legible se DERIVA por
-- v_products_with_stock (LEFT JOIN product_categories). Este gate hereda
-- literalmente los tres bloques del gate viejo que siguen siendo normativos
-- —P0404 de tenencia, FK ON DELETE RESTRICT, convivencia con el guard de
-- soft delete— y agrega los siete nuevos (T1-T7) del design D7:
--   T1 — products.category ausente de information_schema.columns.
--   T2 — la vista deriva `category` = nombre vigente de la categoría.
--   T3 — renombrar una categoría se refleja en la vista SIN reescribir
--        ninguna fila de products (xmin intacto) — D1/D3.
--   T4 — categoría desactivada / soft-deleted → la vista sigue devolviendo
--        su nombre (D3: la policy de SELECT no filtra por deleted_at).
--   T5 — category_id NULL no filtra al producto (LEFT JOIN, no INNER); y
--        COUNT(vista) = COUNT(products) para la cuenta de prueba.
--   T6 — la vista conserva security_invoker=true y los GRANT vigentes.
--   T7 — barrido pg_get_functiondef: ninguna función de public referencia ya
--        products.category como columna física (identificador standalone
--        "category" con límite de palabra, sin prefijo _ y sin comillas a
--        los lados). El allowlist documenta las coincidencias LEGÍTIMAS que
--        el barrido no puede distinguir por texto solo — no hay ninguna
--        coincidencia sin justificar.
--   T8 — rpc_product_ranking (consumidor real de `category` fuera de esta
--        vista, revisor adversarial): sobre una venta sintética del producto
--        de T3, el ranking deriva `category` = nombre VIGENTE de la
--        categoría, tanto ANTES (T8a, "Ropa") como DESPUÉS (T8b,
--        "Indumentaria") del renombre que T3 ejercita — nunca un nombre
--        congelado al momento de la venta.
-- =============================================================================

-- =============================================================================
-- Bloques de metadata (T1, T6, T7) — no requieren datos de prueba.
-- =============================================================================

DO $$
DECLARE
  v_orphan_functions text[];
  -- T7 allowlist: cada entrada es una coincidencia LEGÍTIMA del barrido de
  -- texto que no es un lector de la columna física products.category.
  --   - rpc_create_expense / rpc_update_expense: escriben expenses.category
  --     (TEXT libre sin catálogo) — otra tabla, otra columna, otro change
  --     (design.md, "Falsos positivos").
  --   - rpc_product_ranking: RETURNS TABLE conserva el campo de salida
  --     `category text` (D2 — el nombre del campo no cambia).
  --   - rpc_product_sales_evolution: `v_head.category` es el campo de un
  --     RECORD local ya derivado por el LEFT JOIN a product_categories
  --     dentro de la misma función (no una lectura de la columna física).
  --   - rpc_bulk_upsert_products: `r->>'category'` es la CLAVE del payload
  --     JSONB del importador (nombre de columna del CSV, OQ-4) — se
  --     excluye por estar entre comillas, no por allowlist.
  v_allowlist CONSTANT text[] := ARRAY[
    'rpc_create_expense',
    'rpc_update_expense',
    'rpc_product_ranking',
    'rpc_product_sales_evolution'
  ];
BEGIN
  -- T1: la columna física ya no existe.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'category'
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T1): products.category todavía existe físicamente.';
  END IF;
  RAISE NOTICE 'PASS (T1): products.category no existe en information_schema.columns.';

  -- T6: la vista conserva security_invoker=true y sus GRANT.
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
     WHERE relname = 'v_products_with_stock'
       AND 'security_invoker=true' = ANY(reloptions)
  ) THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T6a): v_products_with_stock perdió security_invoker=true.';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_products_with_stock', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_products_with_stock', 'SELECT') THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T6b): v_products_with_stock perdió el GRANT SELECT de authenticated/service_role.';
  END IF;
  RAISE NOTICE 'PASS (T6): la vista conserva security_invoker=true y sus GRANT.';

  -- T7: ningún lector de public referencia ya la columna física. El patrón
  -- exige "category" como identificador STANDALONE: sin "_" ni letra
  -- inmediatamente antes (excluye category_id, head_category,
  -- product_category, p_category) y sin comilla/letra/dígito inmediatamente
  -- después (excluye 'category' como clave JSONB o string literal).
  SELECT array_agg(proname ORDER BY proname) INTO v_orphan_functions
    FROM (
      SELECT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.prokind = 'f'
         AND pg_get_functiondef(p.oid) ~ $rx$(?<!['_a-zA-Z])category(?!['_a-zA-Z0-9])$rx$
         AND p.proname <> ALL (v_allowlist)
         -- Dominio de gastos: expenses.category es OTRA columna TEXT (sin
         -- catálogo). Toda función de ese dominio la menciona legítimamente
         -- (rpc_create_expense, rpc_update_expense, rpc_import_expenses del
         -- change importador-gastos-transaccional, y las que vengan): se
         -- excluyen por convención de nombre para no perseguir el allowlist
         -- cada vez que nazca una función de gastos.
         AND p.proname !~ 'expense'
    ) orphans;

  IF v_orphan_functions IS NOT NULL THEN
    RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T7): función(es) fuera del allowlist siguen mencionando "category" como identificador standalone — revisar si son un lector nuevo de la columna física: %.', v_orphan_functions;
  END IF;
  RAISE NOTICE 'PASS (T7): ninguna función de public (fuera del allowlist documentado) referencia ya la columna física.';
END $$;


-- =============================================================================
-- Bloque principal — requiere cuentas/categorías sintéticas (T2-T5, (7)-(9)).
-- =============================================================================

DO $$
DECLARE
  v_user_a      uuid := gen_random_uuid();
  v_user_b      uuid := gen_random_uuid();
  v_account_a   uuid;
  v_account_b   uuid;
  v_cat_ropa    uuid;
  v_cat_hogar   uuid;
  v_cat_zapatos uuid;
  v_cat_b       uuid;
  v_prod1       uuid;
  v_prod2       uuid;
  v_prod_hogar  uuid;
  v_prod_free   uuid;
  v_prod_zap    uuid;
  v_text        text;
  v_count_view  bigint;
  v_count_tbl   bigint;
  v_xmin_before xid;
  v_xmin_after  xid;
  v_rejected    boolean := false;
  v_sqlstate    text;
  v_deleted_at  timestamptz;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'product-category-derived-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Derived A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'product-category-derived-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate PC Derived B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE NOTICE 'GATE PRODUCT-CATEGORY-DERIVED degradado: no se pudo resolver cuenta para los anchors sintéticos — omitido sin fallar.';
  ELSE
    SELECT id INTO v_cat_ropa  FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'ropa'  AND deleted_at IS NULL;
    SELECT id INTO v_cat_hogar FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'hogar' AND deleted_at IS NULL;
    SELECT id INTO v_cat_b     FROM public.product_categories WHERE account_id = v_account_b AND lower(name) = 'ropa'  AND deleted_at IS NULL;

    IF v_cat_ropa IS NULL OR v_cat_hogar IS NULL OR v_cat_b IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (0): el seed de provisioning no dejó Ropa/Hogar en las cuentas ancla.';
    END IF;

    -- Categoría propia para T4, para no interferir con los pasos (7)/(8) que
    -- ya ejercitan Ropa/Hogar.
    INSERT INTO public.product_categories (account_id, name, sort_order)
    VALUES (v_account_a, 'Gate zapatos', 999)
    RETURNING id INTO v_cat_zapatos;

    -- (T2) INSERT con category_id → la VISTA deriva el nombre vigente.
    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate derived remera', v_cat_ropa, 100, 50, 0)
    RETURNING id INTO v_prod1;

    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod1;
    IF v_text IS DISTINCT FROM 'Ropa' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T2): la vista esperaba category="Ropa" para un producto con category_id=Ropa, dio %.', v_text;
    END IF;
    RAISE NOTICE 'PASS (T2): v_products_with_stock deriva category = nombre vigente de la categoría referenciada.';

    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate derived campera', v_cat_ropa, 100, 50, 0)
    RETURNING id INTO v_prod2;

    -- Producto propio de Hogar — necesario para que (8) ejercite el FK
    -- RESTRICT sobre una categoría REALMENTE referenciada (v_cat_ropa/v_cat_b
    -- ya están comprometidas por T2/T3/(7)).
    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate derived sillón', v_cat_hogar, 100, 50, 0)
    RETURNING id INTO v_prod_hogar;

    -- (7) TRIANGULATE: categoría de OTRA cuenta → rechazada con P0404 (el
    -- guard de tenencia particionado, D4, sobrevive al retiro del espejo).
    BEGIN
      UPDATE public.products SET category_id = v_cat_b WHERE id = v_prod1;
    EXCEPTION
      WHEN OTHERS THEN
        v_rejected := true;
        v_sqlstate := SQLSTATE;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (7a): imputar un producto de A a una categoría de B debería ser rechazado.';
    END IF;
    IF v_sqlstate IS DISTINCT FROM 'P0404' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (7b): el rechazo esperaba SQLSTATE P0404, dio %.', v_sqlstate;
    END IF;
    RAISE NOTICE 'PASS (7): categoría de otra cuenta rechazada con P0404 (guard de tenencia particionado, TRIANGULATE).';

    -- (8) FK ON DELETE RESTRICT sobre una categoría referenciada.
    v_rejected := false;
    BEGIN
      DELETE FROM public.product_categories WHERE id = v_cat_hogar;
    EXCEPTION
      WHEN foreign_key_violation THEN
        v_rejected := true;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (8): borrar físicamente una categoría referenciada debería fallar por FK RESTRICT.';
    END IF;
    RAISE NOTICE 'PASS (8): la fila de una categoría en uso no se puede eliminar físicamente (FK RESTRICT).';

    -- (9) guard de soft delete intacto al lado del guard de tenencia nuevo
    -- (ya NO trg_product_category_mirror — ese trigger fue retirado).
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND tgname = 'trg_guard_product_soft_delete' AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (9a): trg_guard_product_soft_delete desapareció de products.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND tgname = 'trg_product_category_tenancy_guard' AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (9b): falta trg_product_category_tenancy_guard sobre products.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND tgname = 'trg_product_category_mirror' AND NOT tgisinternal
    ) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (9c): trg_product_category_mirror debería haber sido retirado.';
    END IF;

    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate derived libre', NULL, 100, 50, 0)
    RETURNING id INTO v_prod_free;
    UPDATE public.products SET deleted_at = now(), deleted_by = v_user_a WHERE id = v_prod_free;
    SELECT deleted_at INTO v_deleted_at FROM public.products WHERE id = v_prod_free;
    IF v_deleted_at IS NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (9c): el soft delete de un producto sin stock dejó de funcionar.';
    END IF;
    RAISE NOTICE 'PASS (9): guard de soft delete vivo y compatible con el trigger de tenencia nuevo.';

    -- (T8a) rpc_product_ranking es un CONSUMIDOR REAL de `category` fuera de
    -- v_products_with_stock (hallazgo del revisor adversarial: el gate viejo
    -- sólo ejercitaba la vista). Venta sintética mínima sobre v_prod2 (molde
    -- de test_estadisticas_ventas_e3.sql: un INSERT directo en `sales` alcanza
    -- para que reporting_sales_lines_in_window la vea, sin sale_items) — ANTES
    -- de que T3 (más abajo) renombre Ropa→Indumentaria.
    -- reporting-invariants: sales.date guarda la fecha de negocio a medianoche
    -- UTC (RN-D5) — nunca now() crudo, que corre la venta al día siguiente en
    -- UTC pasada cierta hora y la saca de la ventana [hoy-1 .. hoy] de abajo.
    INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
    VALUES (v_user_a, v_account_a, NULL, v_prod2, 100, 1, 100, public.reporting_local_today()::timestamp AT TIME ZONE 'UTC', gen_random_uuid());

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

    SELECT r.category INTO v_text
      FROM public.rpc_product_ranking(v_account_a, (public.reporting_local_today() - 1), public.reporting_local_today(), 'units', true, NULL, NULL, 50, 0) r
     WHERE r.product_id = v_prod2;
    IF NOT FOUND OR v_text IS DISTINCT FROM 'Ropa' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T8a): rpc_product_ranking esperaba category="Ropa" ANTES de renombrar la categoría, dio %.', v_text;
    END IF;
    RAISE NOTICE 'PASS (T8a): rpc_product_ranking deriva category = nombre vigente de la categoría ANTES de renombrarla.';

    -- (T3) Renombrar una categoría se refleja en la vista SIN reescribir
    -- ninguna fila de products (xmin intacto) — D1/D3, el reverso exacto
    -- del bloque (4) del gate viejo, que probaba lo contrario.
    SELECT xmin INTO v_xmin_before FROM public.products WHERE id = v_prod2;
    UPDATE public.product_categories SET name = 'Indumentaria' WHERE id = v_cat_ropa;
    SELECT xmin INTO v_xmin_after FROM public.products WHERE id = v_prod2;
    IF v_xmin_before IS DISTINCT FROM v_xmin_after THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T3a): renombrar una categoría reescribió una fila de products (xmin % → %).', v_xmin_before, v_xmin_after;
    END IF;
    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod2;
    IF v_text IS DISTINCT FROM 'Indumentaria' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T3b): tras renombrar Ropa→Indumentaria, la vista esperaba "Indumentaria", dio %.', v_text;
    END IF;
    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod_hogar;
    IF v_text IS DISTINCT FROM 'Hogar' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T3c): el renombre de Ropa afectó a un producto de Hogar (dio %).', v_text;
    END IF;
    RAISE NOTICE 'PASS (T3): renombrar una categoría se refleja en la vista sin reescribir ninguna fila de products.';

    -- (T8b) mismo producto y misma venta que T8a, DESPUÉS del renombre
    -- Ropa→Indumentaria que acaba de ejercitar T3: rpc_product_ranking debe
    -- reflejar el nombre VIGENTE, nunca el congelado al momento de la venta
    -- (D1 — la categoría no es un snapshot). El RED de este bloque es lógico,
    -- no un experimento a comentar en la migración: el assert de arriba (T8a)
    -- ya prueba que "Ropa" es correcto ANTES del rename — si el bug existiera
    -- (p.ej. category cacheada/snapshoteada), este bloque fallaría al seguir
    -- esperando "Ropa" en vez de "Indumentaria" después del rename.
    SELECT r.category INTO v_text
      FROM public.rpc_product_ranking(v_account_a, (public.reporting_local_today() - 1), public.reporting_local_today(), 'units', true, NULL, NULL, 50, 0) r
     WHERE r.product_id = v_prod2;
    IF NOT FOUND OR v_text IS DISTINCT FROM 'Indumentaria' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T8b): rpc_product_ranking esperaba category="Indumentaria" DESPUÉS de renombrar la categoría, dio %.', v_text;
    END IF;
    RAISE NOTICE 'PASS (T8b): rpc_product_ranking deriva category = nombre vigente de la categoría DESPUÉS de renombrarla (nunca el nombre congelado al momento de la venta).';

    -- (T4) Producto imputado a una categoría dada de baja sigue mostrando su
    -- nombre — desactivada y soft-deleted (D3: la policy de SELECT no
    -- filtra por is_active/deleted_at).
    INSERT INTO public.products (user_id, account_id, name, category_id, price, cost, min_stock)
    VALUES (v_user_a, v_account_a, 'Gate derived zapato', v_cat_zapatos, 100, 50, 0)
    RETURNING id INTO v_prod_zap;

    UPDATE public.product_categories SET is_active = false WHERE id = v_cat_zapatos;
    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod_zap;
    IF v_text IS DISTINCT FROM 'Gate zapatos' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T4a): una categoría desactivada dejó de resolver su nombre (dio %).', v_text;
    END IF;
    RAISE NOTICE 'PASS (T4a): categoría desactivada — el producto imputado sigue mostrando su nombre.';

    UPDATE public.product_categories SET deleted_at = now() WHERE id = v_cat_zapatos;
    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod_zap;
    IF v_text IS DISTINCT FROM 'Gate zapatos' THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T4b): una categoría soft-deleted dejó de resolver su nombre (dio %).', v_text;
    END IF;
    RAISE NOTICE 'PASS (T4b): categoría soft-deleted — el producto imputado sigue mostrando su nombre.';

    -- (T5) category_id NULL no filtra al producto (LEFT JOIN, nunca INNER);
    -- y el LEFT JOIN no filtra a NADIE: COUNT(vista) = COUNT(products) para
    -- la cuenta de prueba.
    SELECT category INTO v_text FROM public.v_products_with_stock WHERE id = v_prod_free;
    IF v_text IS NOT NULL THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T5a): un producto con category_id NULL esperaba category NULL, dio %.', v_text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.v_products_with_stock WHERE id = v_prod_free) THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T5b): un producto con category_id NULL desapareció de la vista.';
    END IF;

    SELECT COUNT(*) INTO v_count_view FROM public.v_products_with_stock WHERE account_id = v_account_a;
    SELECT COUNT(*) INTO v_count_tbl  FROM public.products               WHERE account_id = v_account_a;
    IF v_count_view IS DISTINCT FROM v_count_tbl THEN
      RAISE EXCEPTION 'GATE PRODUCT-CATEGORY-DERIVED FAILED (T5c): el LEFT JOIN filtró productos — vista=% products=%.', v_count_view, v_count_tbl;
    END IF;
    RAISE NOTICE 'PASS (T5): category_id NULL no excluye al producto de la vista, y el LEFT JOIN no filtra a nadie (% filas).', v_count_tbl;
  END IF;

  -- Cleanup hijo→padre.
  PERFORM set_config('request.jwt.claims', '', true);
  -- sales.account_id no tiene ON DELETE — la venta sintética de T8a/T8b
  -- bloquearía el DELETE de accounts más abajo si no se limpia primero.
  DELETE FROM public.sales WHERE account_id IN (v_account_a, v_account_b);
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
      PERFORM set_config('request.jwt.claims', '', true);
      DELETE FROM public.sales WHERE account_id IN (v_account_a, v_account_b);
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
