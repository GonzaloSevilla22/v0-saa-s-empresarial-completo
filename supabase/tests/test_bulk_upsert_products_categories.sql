-- =============================================================================
-- GATE: test_bulk_upsert_products_categories.sql
-- CHANGE: productos-categorias-sku (tasks 5.2 RED contrato, 5.3 RED nuevo,
--         5.7 TRIANGULATE)
--
-- rpc_bulk_upsert_products se reescribe partiendo de su cuerpo VIVO de prod
-- (md5 dc56bfc24e7f31c85dc9f04463af26eb, 2026-09-03) con DOS ejes: (a) las
-- tres resoluciones (SKU existente, sku_parent, parent_name) pasan de user_id
-- a account_id + case-insensitive + filas vivas, y (b) resolución/creación
-- de la categoría contra el catálogo de la cuenta (D4/D6).
--
-- Contrato que NO debe moverse (5.2):
--   (1) Padre + Variante por sku_parent → parent_id resuelto, branch_stock en
--       la sucursal default con el stock del CSV, product_attributes escrito,
--   (2) Variante por parent_name → resuelta,
--   (3) Variante por parent_id explícito → resuelta,
--   (4) reimportar el mismo SKU con otro stock → updated (no inserted),
--       branch_stock reemplazado (set absoluto).
-- Lo nuevo (5.3):
--   (5) categoría desconocida → se crea en la cuenta e imputa (category_id +
--       espejo TEXT),
--   (6) "ropa" / "Ropa " / "ROPA" → todas a la "Ropa" sembrada, sin crear,
--   (7) fila sin categoría → categoría por defecto ("Otros"), sin crear,
--   (8) fila con error fatal (sku_parent inexistente) y categoría nueva →
--       error de fila y la categoría NO se crea,
--   (9) superar el tope (51 categorías nuevas) → rechazo P0400 de toda la
--       llamada, cero categorías y cero productos creados,
--  (10) alcance de cuenta: un producto de otro MIEMBRO de la misma cuenta con
--       SKU "ACC-1" se actualiza al importar "acc-1" (case-insensitive) en vez
--       de duplicarse,
--  (11) un producto soft-deleteado con SKU "DEL-1" no se "resucita": la fila
--       importada crea un producto vivo nuevo.
--
-- Degrade-don't-fail: si auth.uid() no resuelve al anchor bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_account_a    uuid;
  v_branch_a     uuid;
  v_res          jsonb;
  v_parent_id    uuid;
  v_child_id     uuid;
  v_pid          uuid;
  v_qty          numeric;
  v_attr_val     text;
  v_cat_id       uuid;
  v_cat_name     text;
  v_cats_before  integer;
  v_cats_after   integer;
  v_prods_before integer;
  v_prods_after  integer;
  v_ropa_id      uuid;
  v_otros_id     uuid;
  v_rows         jsonb;
  v_i            integer;
  v_rejected     boolean := false;
  v_sqlstate     text;
  v_other_id     uuid;
  v_deleted_id   uuid;
  v_count        integer;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'bulk-upsert-categories-gate-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Bulk A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'bulk-upsert-categories-gate-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Bulk B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE BULK-UPSERT-CATEGORIES degradado: no se pudo resolver la cuenta del anchor — omitido sin fallar.';
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

    IF auth.uid() IS DISTINCT FROM v_user_a THEN
      RAISE NOTICE 'GATE BULK-UPSERT-CATEGORIES degradado: auth.uid() no resuelve al anchor bajo request.jwt.claims — omitido sin fallar.';
    ELSE
      SELECT id INTO v_ropa_id  FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'ropa'  AND deleted_at IS NULL;
      SELECT id INTO v_otros_id FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'otros' AND deleted_at IS NULL;
      SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

      -- ── (1)-(3): jerarquía padre/variante por las tres estrategias ─────────
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Zapatillas','sku','GZAP','category','Ropa','price',0,'cost',0,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','variant_only','attributes','[]'::jsonb),
        jsonb_build_object('name','Gate Zapatillas 41','sku','GZAP-41','sku_parent','GZAP','category','Ropa','price',100,'cost',50,'stock',5,'min_stock',1,'barcode',NULL,'parent_id',NULL,'is_variant',true,'stock_control_type','tracked','attributes',jsonb_build_array(jsonb_build_object('key','talle','value','41','sort_order',0))),
        jsonb_build_object('name','Gate Zapatillas 42','sku','GZAP-42','parent_name','Gate Zapatillas','category','Ropa','price',100,'cost',50,'stock',3,'min_stock',1,'barcode',NULL,'parent_id',NULL,'is_variant',true,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);

      IF (v_res->>'inserted')::int <> 3 OR jsonb_array_length(v_res->'errors') <> 0 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (1a): esperaba 3 inserted sin errores, dio %.', v_res;
      END IF;

      SELECT id INTO v_parent_id FROM public.products WHERE account_id = v_account_a AND sku = 'GZAP';
      SELECT id, parent_id INTO v_child_id, v_pid FROM public.products WHERE account_id = v_account_a AND sku = 'GZAP-41';
      IF v_pid IS DISTINCT FROM v_parent_id THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (1b): la variante por sku_parent no quedó vinculada al padre.';
      END IF;
      SELECT quantity INTO v_qty FROM public.branch_stock WHERE product_id = v_child_id AND branch_id = v_branch_a;
      IF v_qty IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (1c): branch_stock esperaba 5 en la sucursal default, dio %.', v_qty;
      END IF;
      SELECT value INTO v_attr_val FROM public.product_attributes WHERE product_id = v_child_id AND key = 'talle';
      IF v_attr_val IS DISTINCT FROM '41' THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (1d): product_attributes no acarreó talle=41 (dio %).', v_attr_val;
      END IF;
      RAISE NOTICE 'PASS (1): Padre + Variante por sku_parent, branch_stock y product_attributes intactos.';

      SELECT parent_id INTO v_pid FROM public.products WHERE account_id = v_account_a AND sku = 'GZAP-42';
      IF v_pid IS DISTINCT FROM v_parent_id THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (2): la variante por parent_name no quedó vinculada al padre.';
      END IF;
      RAISE NOTICE 'PASS (2): variante por parent_name resuelta.';

      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Zapatillas 43','sku','GZAP-43','category','Ropa','price',100,'cost',50,'stock',1,'min_stock',1,'barcode',NULL,'parent_id',v_parent_id::text,'is_variant',true,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      SELECT parent_id INTO v_pid FROM public.products WHERE account_id = v_account_a AND sku = 'GZAP-43';
      IF v_pid IS DISTINCT FROM v_parent_id THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (3): la variante por parent_id explícito no quedó vinculada (res=%).', v_res;
      END IF;
      RAISE NOTICE 'PASS (3): variante por parent_id explícito resuelta.';

      -- ── (4): reimportar = update, stock reemplazado ─────────────────────────
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Zapatillas 41','sku','GZAP-41','sku_parent','GZAP','category','Ropa','price',120,'cost',50,'stock',9,'min_stock',1,'barcode',NULL,'parent_id',NULL,'is_variant',true,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      IF (v_res->>'updated')::int <> 1 OR (v_res->>'inserted')::int <> 0 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (4a): reimportar GZAP-41 esperaba updated=1/inserted=0, dio %.', v_res;
      END IF;
      SELECT quantity INTO v_qty FROM public.branch_stock WHERE product_id = v_child_id AND branch_id = v_branch_a;
      IF v_qty IS DISTINCT FROM 9 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (4b): branch_stock esperaba 9 tras la reimportación, dio %.', v_qty;
      END IF;
      RAISE NOTICE 'PASS (4): reimportar por SKU actualiza (no duplica) y reemplaza el stock.';

      -- ── (5): categoría desconocida se crea e imputa ────────────────────────
      SELECT COUNT(*) INTO v_cats_before FROM public.product_categories WHERE account_id = v_account_a AND deleted_at IS NULL;
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Martillo','sku','GMAR','category','Ferretería','price',500,'cost',200,'stock',2,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      SELECT category_id, category INTO v_cat_id, v_cat_name FROM public.products WHERE account_id = v_account_a AND sku = 'GMAR';
      IF v_cat_id IS NULL OR v_cat_name IS DISTINCT FROM 'Ferretería' THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (5a): el producto no quedó imputado a "Ferretería" (category_id=%, category=%).', v_cat_id, v_cat_name;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.product_categories WHERE id = v_cat_id AND account_id = v_account_a AND name = 'Ferretería' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (5b): la categoría "Ferretería" no se creó en la cuenta importadora.';
      END IF;
      RAISE NOTICE 'PASS (5): categoría desconocida creada en la cuenta e imputada.';

      -- ── (6): variantes de escritura → la misma categoría existente ─────────
      SELECT COUNT(*) INTO v_cats_before FROM public.product_categories WHERE account_id = v_account_a AND deleted_at IS NULL;
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Remera 1','sku','GREM-1','category','ropa','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb),
        jsonb_build_object('name','Gate Remera 2','sku','GREM-2','category','Ropa ','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb),
        jsonb_build_object('name','Gate Remera 3','sku','GREM-3','category','ROPA','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      SELECT COUNT(*) INTO v_cats_after FROM public.product_categories WHERE account_id = v_account_a AND deleted_at IS NULL;
      IF v_cats_after <> v_cats_before THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (6a): "ropa"/"Ropa "/"ROPA" crearon categorías nuevas (% → %).', v_cats_before, v_cats_after;
      END IF;
      SELECT COUNT(*) INTO v_count FROM public.products WHERE account_id = v_account_a AND sku IN ('GREM-1','GREM-2','GREM-3') AND category_id = v_ropa_id AND category = 'Ropa';
      IF v_count <> 3 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (6b): sólo % de 3 filas quedaron en la "Ropa" existente.', v_count;
      END IF;
      RAISE NOTICE 'PASS (6): resolución case-insensitive y tolerante a espacios, sin duplicar.';

      -- ── (7): fila sin categoría → default de la cuenta ─────────────────────
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Sin cat','sku','GSIN','category','','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      SELECT category_id INTO v_cat_id FROM public.products WHERE account_id = v_account_a AND sku = 'GSIN';
      IF v_cat_id IS DISTINCT FROM v_otros_id THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (7): fila sin categoría esperaba la default "Otros" (%), dio %.', v_otros_id, v_cat_id;
      END IF;
      SELECT COUNT(*) INTO v_cats_after FROM public.product_categories WHERE account_id = v_account_a AND deleted_at IS NULL;
      IF v_cats_after <> v_cats_before THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (7b): una fila sin categoría creó una categoría.';
      END IF;
      RAISE NOTICE 'PASS (7): fila sin categoría va a la categoría por defecto sin crear nada.';

      -- ── (8): fila con error fatal no crea su categoría ─────────────────────
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Fantasma','sku','GFAN','sku_parent','NO-EXISTE','category','Fantasma','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',true,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      IF jsonb_array_length(v_res->'errors') <> 1 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (8a): la fila con sku_parent inexistente debía dar 1 error, dio %.', v_res;
      END IF;
      IF EXISTS (SELECT 1 FROM public.product_categories WHERE account_id = v_account_a AND lower(name) = 'fantasma') THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (8b): la categoría de una fila con error se creó igual.';
      END IF;
      RAISE NOTICE 'PASS (8): una fila con error fatal no origina la creación de su categoría.';

      -- ── (9): tope de categorías nuevas → rechazo total ─────────────────────
      SELECT COUNT(*) INTO v_cats_before FROM public.product_categories WHERE account_id = v_account_a;
      SELECT COUNT(*) INTO v_prods_before FROM public.products WHERE account_id = v_account_a;
      v_rows := '[]'::jsonb;
      FOR v_i IN 1..51 LOOP
        v_rows := v_rows || jsonb_build_array(jsonb_build_object(
          'name','Gate tope '||v_i,'sku','GTOPE-'||v_i,'category','Cat tope '||v_i,
          'price',1,'cost',0,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,
          'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb));
      END LOOP;
      BEGIN
        v_res := public.rpc_bulk_upsert_products(v_rows, v_user_a);
      EXCEPTION
        WHEN OTHERS THEN
          v_rejected := true;
          v_sqlstate := SQLSTATE;
      END;
      IF NOT v_rejected THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (9a): 51 categorías nuevas deberían rechazar la importación (tope 50).';
      END IF;
      IF v_sqlstate IS DISTINCT FROM 'P0400' THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (9b): el rechazo esperaba SQLSTATE P0400, dio %.', v_sqlstate;
      END IF;
      SELECT COUNT(*) INTO v_cats_after FROM public.product_categories WHERE account_id = v_account_a;
      SELECT COUNT(*) INTO v_prods_after FROM public.products WHERE account_id = v_account_a;
      IF v_cats_after <> v_cats_before OR v_prods_after <> v_prods_before THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (9c): el rechazo por tope dejó rastro (cats % → %, prods % → %).', v_cats_before, v_cats_after, v_prods_before, v_prods_after;
      END IF;
      RAISE NOTICE 'PASS (9): superar el tope de 50 rechaza toda la importación con P0400 y sin crear nada.';

      -- ── (10): alcance de cuenta en la resolución del SKU ───────────────────
      INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock)
      VALUES (v_user_b, v_account_a, 'Gate Accesorio por B', 'Accesorios', 'ACC-1', 10, 5, 0)
      RETURNING id INTO v_other_id;
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Accesorio por B','sku','acc-1','category','Accesorios','price',33,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      IF (v_res->>'updated')::int <> 1 OR (v_res->>'inserted')::int <> 0 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (10a): el SKU de otro miembro de la misma cuenta debía actualizarse, dio %.', v_res;
      END IF;
      SELECT COUNT(*) INTO v_count FROM public.products WHERE account_id = v_account_a AND lower(sku) = 'acc-1' AND deleted_at IS NULL;
      IF v_count <> 1 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (10b): quedaron % productos vivos con SKU acc-1 en la cuenta (esperado 1).', v_count;
      END IF;
      SELECT price INTO v_qty FROM public.products WHERE id = v_other_id;
      IF v_qty IS DISTINCT FROM 33 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (10c): el producto del otro miembro no recibió el precio nuevo (%).', v_qty;
      END IF;
      RAISE NOTICE 'PASS (10): la resolución por SKU usa el alcance de la cuenta, case-insensitive.';

      -- ── (11): un producto borrado no se resucita ───────────────────────────
      INSERT INTO public.products (user_id, account_id, name, category, sku, price, cost, min_stock, deleted_at, deleted_by)
      VALUES (v_user_a, v_account_a, 'Gate Borrado', 'Otros', 'DEL-1', 10, 5, 0, now(), v_user_a)
      RETURNING id INTO v_deleted_id;
      v_res := public.rpc_bulk_upsert_products(jsonb_build_array(
        jsonb_build_object('name','Gate Borrado nuevo','sku','DEL-1','category','Otros','price',10,'cost',5,'stock',0,'min_stock',0,'barcode',NULL,'parent_id',NULL,'is_variant',false,'stock_control_type','tracked','attributes','[]'::jsonb)
      ), v_user_a);
      IF (v_res->>'inserted')::int <> 1 THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (11a): el SKU de un producto borrado debía crear un producto vivo nuevo, dio %.', v_res;
      END IF;
      IF (SELECT deleted_at FROM public.products WHERE id = v_deleted_id) IS NULL THEN
        RAISE EXCEPTION 'GATE BULK-UPSERT-CATEGORIES FAILED (11b): la importación resucitó un producto borrado.';
      END IF;
      RAISE NOTICE 'PASS (11): un producto soft-deleteado no se resucita — la fila crea uno vivo nuevo.';
    END IF;
  END IF;

  -- Cleanup hijo→padre.
  DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id = v_account_a);
  DELETE FROM public.product_attributes WHERE product_id IN (SELECT id FROM public.products WHERE account_id = v_account_a);
  DELETE FROM public.products           WHERE account_id = v_account_a;
  DELETE FROM public.product_categories WHERE account_id = v_account_a;
  DELETE FROM public.payment_methods    WHERE account_id = v_account_a;
  DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
  DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
  SET session_replication_role = replica;
  DELETE FROM public.branches           WHERE account_id = v_account_a;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.product_categories WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
  DELETE FROM public.payment_methods    WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
  DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b));
  SET session_replication_role = replica;
  DELETE FROM public.branches           WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
  DELETE FROM public.accounts           WHERE owner_user_id IN (v_user_a, v_user_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles           WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs         WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                WHERE id IN (v_user_a, v_user_b);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      DELETE FROM public.branch_stock WHERE product_id IN (SELECT id FROM public.products WHERE account_id = v_account_a);
      DELETE FROM public.product_attributes WHERE product_id IN (SELECT id FROM public.products WHERE account_id = v_account_a);
      DELETE FROM public.products           WHERE account_id = v_account_a;
      DELETE FROM public.product_categories WHERE account_id = v_account_a;
      DELETE FROM public.payment_methods    WHERE account_id = v_account_a;
      DELETE FROM public.branch_stock       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
      DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_a);
      SET session_replication_role = replica;
      DELETE FROM public.branches           WHERE account_id = v_account_a;
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members    WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.product_categories WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
      DELETE FROM public.payment_methods    WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
      DELETE FROM public.cashboxes          WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b));
      SET session_replication_role = replica;
      DELETE FROM public.branches           WHERE account_id IN (SELECT id FROM public.accounts WHERE owner_user_id = v_user_b);
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
