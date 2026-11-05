-- =============================================================================
-- test_document_lines_consistency.sql — Gate de DINERO (corre con run_gate_strict.py):
-- v31-document-lines-consistency (H-15) — la línea de documento es universal.
--
-- Verifica 20261091000001_v31_document_lines_consistency.sql. EJECUTA de verdad cada
-- escritor de líneas (regla dura del proyecto: una RPC que otras invocan necesita un gate
-- que la corra, no sólo que verifique que existe):
--
--   rpc_create_sale_operation (→ _v2), _c29_confirm_order_core (vía rpc_quick_sale y
--   rpc_confirm_sales_order), rpc_create_purchase_operation (→ _purchase_operation_core),
--   rpc_create_purchase_operation_v2, rpc_atomic_update_sale_operation y
--   rpc_atomic_update_purchase_operation — todos con producto Y con servicio.
--
--   (a) cada escritor deja EXACTAMENTE una línea canónica (variant_id IS NULL) con nombre,
--       con subtotal = COALESCE(total, amount*quantity) del header; la de servicio con
--       product_id NULL y el nombre de la cascada (D3) o la etiqueta 'Ítem sin producto';
--   (b) el flag sale_items_rpc_v2 ya no tiene efecto: sin fila y CON una fila enabled=false;
--   (c) ninguna función de public contiene 'sale_items_rpc_v2' en su cuerpo;
--   (d) barrido: cuentas ancla sin headers sin línea, con más de una, ni nombres NULL, y
--       Σ subtotal de la línea canónica = Σ total del header por documento;
--   (e) los reportes no cambian por la línea de servicio (con y sin la línea);
--   (f) el backfill es idempotente y converge: con fixtures sucias (headers sin línea,
--       líneas sin nombre) se re-ejecuta la migración ENTERA (\i) y queda 0 residuo, global;
--   (g) las ACLs de las 7 funciones reescritas.
--
-- Etapa 1 (esta primera parte): aborta con TODOS los fallos acumulados antes de la etapa 2.
-- Todo corre dentro de BEGIN … ROLLBACK: no deja anclas ni DDL residual.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE h15_fail (msg text);

-- ── helpers temporales (desaparecen con el ROLLBACK) ────────────────────────────────
-- Una línea canónica por header, con nombre, importe del header y producto coherente.
CREATE FUNCTION pg_temp.h15_chk_sale(p_label text, p_sale_id uuid, p_expect_name text, p_expect_service boolean)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_n int; v_line public.sale_items; v_sale public.sales;
BEGIN
  SELECT * INTO v_sale FROM public.sales WHERE id = p_sale_id;
  IF NOT FOUND THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): la venta %s no existe', p_label, p_sale_id)); RETURN;
  END IF;
  SELECT count(*) INTO v_n FROM public.sale_items WHERE sale_id = p_sale_id AND variant_id IS NULL;
  IF v_n <> 1 THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): se esperaba 1 línea canónica en sale_items, hay %s', p_label, v_n)); RETURN;
  END IF;
  SELECT * INTO v_line FROM public.sale_items WHERE sale_id = p_sale_id AND variant_id IS NULL;
  IF v_line.name_snapshot IS DISTINCT FROM p_expect_name THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): name_snapshot esperado %L, hay %L', p_label, p_expect_name, v_line.name_snapshot));
  END IF;
  IF v_line.subtotal IS DISTINCT FROM COALESCE(v_sale.total, v_sale.amount * v_sale.quantity) THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): subtotal %s distinto del total del header %s', p_label, v_line.subtotal, COALESCE(v_sale.total, v_sale.amount * v_sale.quantity)));
  END IF;
  IF v_line.quantity IS DISTINCT FROM v_sale.quantity THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): quantity %s distinta de la del header %s', p_label, v_line.quantity, v_sale.quantity));
  END IF;
  IF p_expect_service AND (v_line.product_id IS NOT NULL OR v_sale.product_id IS NOT NULL) THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): la línea de servicio debe tener product_id NULL', p_label));
  END IF;
  IF NOT p_expect_service AND v_line.product_id IS DISTINCT FROM v_sale.product_id THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): product_id de la línea distinto del header', p_label));
  END IF;
END $f$;

CREATE FUNCTION pg_temp.h15_chk_purchase(p_label text, p_purchase_id uuid, p_expect_name text, p_expect_service boolean)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_n int; v_line public.purchase_items; v_p public.purchases;
BEGIN
  SELECT * INTO v_p FROM public.purchases WHERE id = p_purchase_id;
  IF NOT FOUND THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): la compra %s no existe', p_label, p_purchase_id)); RETURN;
  END IF;
  SELECT count(*) INTO v_n FROM public.purchase_items WHERE purchase_id = p_purchase_id AND variant_id IS NULL;
  IF v_n <> 1 THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): se esperaba 1 línea canónica en purchase_items, hay %s', p_label, v_n)); RETURN;
  END IF;
  SELECT * INTO v_line FROM public.purchase_items WHERE purchase_id = p_purchase_id AND variant_id IS NULL;
  IF v_line.name_snapshot IS DISTINCT FROM p_expect_name THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): name_snapshot esperado %L, hay %L', p_label, p_expect_name, v_line.name_snapshot));
  END IF;
  IF v_line.subtotal IS DISTINCT FROM COALESCE(v_p.total, v_p.amount * v_p.quantity) THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): subtotal %s distinto del total del header %s', p_label, v_line.subtotal, COALESCE(v_p.total, v_p.amount * v_p.quantity)));
  END IF;
  IF p_expect_service AND (v_line.product_id IS NOT NULL OR v_p.product_id IS NOT NULL) THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): la línea de servicio debe tener product_id NULL', p_label));
  END IF;
  IF NOT p_expect_service AND v_line.product_id IS DISTINCT FROM v_p.product_id THEN
    INSERT INTO h15_fail VALUES (format('FAIL (%s): product_id de la línea distinto del header', p_label));
  END IF;
END $f$;

-- ── Etapa 1: escritores + flag + prosrc + barrido de anclas + reportes + ACLs ────────
DO $$
DECLARE
  v_label constant text := 'Ítem sin producto';
  v_user uuid := gen_random_uuid();
  v_account uuid; v_branch uuid; v_client uuid; v_p1 uuid; v_p2 uuid;
  v_res jsonb; v_op uuid; v_sale uuid; v_sale2 uuid; v_pur uuid; v_pur2 uuid; v_order uuid;
  v_pm text := 'other';
  v_n int; v_msg text; v_so uuid;
  v_before jsonb; v_after jsonb; v_line public.sale_items;
  v_from timestamptz := date_trunc('month', now());
  v_to timestamptz := now() + interval '1 day';
  r record;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'h15-document-lines@test.local', now(), now(),
          jsonb_build_object('name', 'Gate H15', 'phone', '', 'locality', '', 'province', ''));

  SELECT account_id INTO v_account FROM public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no aprovisionó la cuenta ancla — el gate no puede aseverar nada';
  END IF;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: la cuenta ancla no tiene sucursal';
  END IF;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'H15 Producto Uno', 'H15-P1', 50.00, 100.00) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, 'H15 Producto Dos', 'H15-P2', 80.00, 160.00) RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p1, v_branch, 200);
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_p2, v_branch, 200);
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_user, v_account, 'Cliente H15') RETURNING id INTO v_client;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  -- ── (a) VENTA: rpc_create_sale_operation (→ v2) ───────────────────────────────────
  v_res := public.rpc_create_sale_operation('h15-sale-prod-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3, 'unit_id', NULL)), v_branch, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_sale('a1 venta producto', v_sale, 'H15 Producto Uno', false);

  v_res := public.rpc_create_sale_operation('h15-sale-svc-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)), v_branch, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_sale('a2 venta servicio', v_sale2, v_label, true);

  -- idempotencia sobre el camino único: 2 llamadas, 1 sola línea
  DECLARE v_key text := 'h15-sale-idem-' || gen_random_uuid(); v_r1 jsonb; v_r2 jsonb;
  BEGIN
    v_r1 := public.rpc_create_sale_operation(v_key, v_client, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
    v_r2 := public.rpc_create_sale_operation(v_key, v_client, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
    SELECT count(*) INTO v_n FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id
     WHERE s.operation_id = (v_r1->>'operation_id')::uuid;
    IF (v_r2->>'replayed') IS DISTINCT FROM 'true' OR v_n <> 1 THEN
      INSERT INTO h15_fail VALUES (format('FAIL (a3 idempotencia): replayed=%s, líneas=%s (esperaba true y 1)', v_r2->>'replayed', v_n));
    END IF;
  END;

  -- ── (a) VENTA: ruta C-29 (_c29_confirm_order_core) vía rpc_quick_sale ─────────────
  v_res := public.rpc_quick_sale('h15-quick-' || gen_random_uuid(), v_client,
    jsonb_build_array(
      jsonb_build_object('product_id', v_p2, 'quantity', 2, 'price', 160.00, 'subtotal', 320.00),
      jsonb_build_object('product_id', NULL, 'quantity', 1, 'price', 70.00, 'subtotal', 70.00)),
    v_pm, NULL, NULL, NULL, v_branch);
  v_so := (v_res->>'sales_order_id')::uuid;
  IF v_so IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: rpc_quick_sale no devolvió sales_order_id (%)', v_res;
  END IF;
  SELECT s.id INTO v_sale FROM public.sales s WHERE s.operation_id = (SELECT sale_operation_id FROM public.sales_orders WHERE id = v_so) AND s.product_id = v_p2;
  PERFORM pg_temp.h15_chk_sale('a4 quickSale producto', v_sale, 'H15 Producto Dos', false);
  SELECT s.id INTO v_sale2 FROM public.sales s WHERE s.operation_id = (SELECT sale_operation_id FROM public.sales_orders WHERE id = v_so) AND s.product_id IS NULL;
  PERFORM pg_temp.h15_chk_sale('a5 quickSale servicio', v_sale2, v_label, true);

  -- orden con línea de servicio NOMBRADA (cascada: sales_order_items.name_snapshot) → rpc_confirm_sales_order
  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by)
  VALUES (v_account, v_branch, v_client, 'draft', 90.00, v_user) RETURNING id INTO v_order;
  INSERT INTO public.sales_order_items (sales_order_id, account_id, product_id, quantity, price, subtotal, name_snapshot)
  VALUES (v_order, v_account, NULL, 3, 30.00, 90.00, 'Flete H15');
  v_res := public.rpc_confirm_sales_order('h15-confirm-' || gen_random_uuid(), v_order, v_pm);
  SELECT s.id INTO v_sale2 FROM public.sales s WHERE s.operation_id = (SELECT sale_operation_id FROM public.sales_orders WHERE id = v_order);
  PERFORM pg_temp.h15_chk_sale('a6 confirmación servicio nombrado', v_sale2, 'Flete H15', true);

  -- ── (a) COMPRA: rpc_create_purchase_operation (→ _purchase_operation_core) ─────────
  v_res := public.rpc_create_purchase_operation('h15-pur-prod-' || gen_random_uuid(), CURRENT_DATE, 'Compra H15',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 40.00, 'quantity', 5, 'unit_id', NULL)), v_branch, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_purchase('a7 compra producto', v_pur, 'H15 Producto Uno', false);

  v_res := public.rpc_create_purchase_operation('h15-pur-svc-' || gen_random_uuid(), CURRENT_DATE, 'Flete compra H15',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 900.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_pur2 FROM public.purchases WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_purchase('a8 compra servicio con descripción', v_pur2, 'Flete compra H15', true);

  v_res := public.rpc_create_purchase_operation('h15-pur-svc2-' || gen_random_uuid(), CURRENT_DATE, NULL,
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 120.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_pur2 FROM public.purchases WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_purchase('a9 compra servicio sin descripción', v_pur2, v_label, true);

  -- ── (a) COMPRA: rpc_create_purchase_operation_v2 (sólo service_role en prod; acá corre como postgres) ──
  v_res := public.rpc_create_purchase_operation_v2('h15-purv2-prod-' || gen_random_uuid(), CURRENT_DATE, 'Compra v2 H15',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 70.00, 'quantity', 2, 'unit_id', NULL)));
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_purchase('a10 compra v2 producto', v_pur, 'H15 Producto Dos', false);

  v_res := public.rpc_create_purchase_operation_v2('h15-purv2-svc-' || gen_random_uuid(), CURRENT_DATE, 'Servicio v2 H15',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 300.00, 'quantity', 1, 'unit_id', NULL)));
  v_op := (v_res->>'operation_id')::uuid;
  SELECT id INTO v_pur2 FROM public.purchases WHERE operation_id = v_op;
  PERFORM pg_temp.h15_chk_purchase('a11 compra v2 servicio', v_pur2, 'Servicio v2 H15', true);

  -- ── (a) EDICIÓN de venta: producto → producto (acarrea nombre) y servicio → servicio ──
  v_res := public.rpc_create_sale_operation('h15-edit-s-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  v_res := public.rpc_atomic_update_sale_operation(ARRAY[v_sale], v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 110.00, 'quantity', 4)));
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_sale('a12 edición venta producto', v_sale, 'H15 Producto Uno', false);

  v_res := public.rpc_create_sale_operation('h15-edit-ssvc-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 250.00, 'quantity', 2, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  v_res := public.rpc_atomic_update_sale_operation(ARRAY[v_sale2], v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 260.00, 'quantity', 3)));
  SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_sale('a13 edición venta servicio', v_sale2, v_label, true);

  -- ── (a) EDICIÓN de compra: producto y servicio (la descripción editada nombra la línea) ──
  v_res := public.rpc_create_purchase_operation('h15-edit-p-' || gen_random_uuid(), CURRENT_DATE, 'Compra a editar',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 40.00, 'quantity', 2, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  v_res := public.rpc_atomic_update_purchase_operation(ARRAY[v_pur], CURRENT_DATE, 'Compra editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 45.00, 'quantity', 6)));
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_purchase('a14 edición compra producto', v_pur, 'H15 Producto Uno', false);

  v_res := public.rpc_create_purchase_operation('h15-edit-psvc-' || gen_random_uuid(), CURRENT_DATE, 'Servicio a editar',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_pur2 FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  v_res := public.rpc_atomic_update_purchase_operation(ARRAY[v_pur2], CURRENT_DATE, 'Servicio editado',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 520.00, 'quantity', 1)));
  SELECT id INTO v_pur2 FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_purchase('a15 edición compra servicio', v_pur2, 'Servicio editado', true);

  -- ── (b) el flag ya no tiene efecto: con una fila enabled=false el resultado es el mismo ──
  INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
  VALUES (v_account, 'sale_items_rpc_v2', false)
  ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = false;

  v_res := public.rpc_create_sale_operation('h15-flagoff-s-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_sale('b1 flag=false venta producto', v_sale, 'H15 Producto Uno', false);

  v_res := public.rpc_create_sale_operation('h15-flagoff-ssvc-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 80.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_sale('b2 flag=false venta servicio', v_sale2, v_label, true);

  v_res := public.rpc_create_purchase_operation('h15-flagoff-p-' || gen_random_uuid(), CURRENT_DATE, 'Compra flag',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 40.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_purchase('b3 flag=false compra producto', v_pur, 'H15 Producto Uno', false);

  v_res := public.rpc_atomic_update_sale_operation(ARRAY[v_sale], v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2)));
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_sale('b4 flag=false edición venta', v_sale, 'H15 Producto Uno', false);

  v_res := public.rpc_atomic_update_purchase_operation(ARRAY[v_pur], CURRENT_DATE, 'Compra flag editada',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 40.00, 'quantity', 2)));
  SELECT id INTO v_pur FROM public.purchases WHERE operation_id = (v_res->>'operation_id')::uuid;
  PERFORM pg_temp.h15_chk_purchase('b5 flag=false edición compra', v_pur, 'H15 Producto Uno', false);

  -- ── (c) ninguna función de public lee el flag ─────────────────────────────────────
  FOR r IN
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosrc ILIKE '%sale_items_rpc_v2%'
  LOOP
    INSERT INTO h15_fail VALUES (format('FAIL (c): %s todavía menciona sale_items_rpc_v2', r.proname));
  END LOOP;

  -- ── (d) barrido de las cuentas ancla ────────────────────────────────────────────
  SELECT count(*) INTO v_n FROM public.sales s
   WHERE s.account_id = v_account
     AND NOT EXISTS (SELECT 1 FROM public.sale_items i WHERE i.sale_id = s.id AND i.variant_id IS NULL);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s ventas de la cuenta ancla sin línea canónica', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.purchases s
   WHERE s.account_id = v_account
     AND NOT EXISTS (SELECT 1 FROM public.purchase_items i WHERE i.purchase_id = s.id AND i.variant_id IS NULL);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s compras de la cuenta ancla sin línea canónica', v_n)); END IF;
  SELECT count(*) INTO v_n FROM (SELECT sale_id FROM public.sale_items WHERE account_id = v_account AND variant_id IS NULL GROUP BY 1 HAVING count(*) > 1) x;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s ventas con más de una línea canónica', v_n)); END IF;
  SELECT count(*) INTO v_n FROM (SELECT purchase_id FROM public.purchase_items WHERE account_id = v_account AND variant_id IS NULL GROUP BY 1 HAVING count(*) > 1) x;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s compras con más de una línea canónica', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.sale_items WHERE account_id = v_account AND name_snapshot IS NULL;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s líneas de venta sin nombre', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.purchase_items WHERE account_id = v_account AND name_snapshot IS NULL;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s líneas de compra sin nombre', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.sales s
    JOIN public.sale_items i ON i.sale_id = s.id AND i.variant_id IS NULL
   WHERE s.account_id = v_account AND i.subtotal IS DISTINCT FROM COALESCE(s.total, s.amount * s.quantity);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s ventas cuyo subtotal de línea ≠ total del header', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.purchases s
    JOIN public.purchase_items i ON i.purchase_id = s.id AND i.variant_id IS NULL
   WHERE s.account_id = v_account AND i.subtotal IS DISTINCT FROM COALESCE(s.total, s.amount * s.quantity);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (d): %s compras cuyo subtotal de línea ≠ total del header', v_n)); END IF;

  -- ── (e) los reportes no cambian por la línea de servicio ────────────────────────────
  -- Una venta de servicio reciente; se calculan los reportes CON su línea y SIN ella: iguales.
  v_res := public.rpc_create_sale_operation('h15-rep-svc-' || gen_random_uuid(), v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', NULL, 'amount', 1000.00, 'quantity', 1, 'unit_id', NULL)), v_branch, NULL);
  SELECT id INTO v_sale2 FROM public.sales WHERE operation_id = (v_res->>'operation_id')::uuid;
  SELECT * INTO v_line FROM public.sale_items WHERE sale_id = v_sale2;
  IF v_line.id IS NULL THEN
    INSERT INTO h15_fail VALUES ('FAIL (e): la venta de servicio no tiene línea — el control de invariancia no es significativo');
  ELSE
    SELECT jsonb_build_object(
             'lines', (SELECT coalesce(jsonb_agg(to_jsonb(l) - 'created_at' ORDER BY l.sale_id), '[]'::jsonb) FROM public.reporting_sales_lines_in_window(v_account, CURRENT_DATE - 30, CURRENT_DATE + 1) l),
             'kpi',   (SELECT to_jsonb(k) FROM public.rpc_dashboard_kpi_summary(v_from, v_to, v_from - interval '1 month', v_from) k))
      INTO v_before;
    DELETE FROM public.sale_items WHERE id = v_line.id;
    SELECT jsonb_build_object(
             'lines', (SELECT coalesce(jsonb_agg(to_jsonb(l) - 'created_at' ORDER BY l.sale_id), '[]'::jsonb) FROM public.reporting_sales_lines_in_window(v_account, CURRENT_DATE - 30, CURRENT_DATE + 1) l),
             'kpi',   (SELECT to_jsonb(k) FROM public.rpc_dashboard_kpi_summary(v_from, v_to, v_from - interval '1 month', v_from) k))
      INTO v_after;
    IF v_before IS DISTINCT FROM v_after THEN
      INSERT INTO h15_fail VALUES ('FAIL (e): los reportes cambian según exista o no la línea de servicio (reporting_sales_lines_in_window / rpc_dashboard_kpi_summary)');
    END IF;
    INSERT INTO public.sale_items SELECT (v_line).*;
  END IF;

  -- ── (g) ACLs de las 7 funciones reescritas ────────────────────────────────────────
  FOR r IN
    SELECT p.proname, p.proacl::text AS acl FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname IN
       ('rpc_create_sale_operation','rpc_create_sale_operation_v2','_c29_confirm_order_core','rpc_atomic_update_sale_operation','rpc_atomic_update_purchase_operation')
  LOOP
    IF r.acl IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
      INSERT INTO h15_fail VALUES (format('FAIL (g): ACL de %s = %s (esperaba postgres, authenticated, service_role)', r.proname, r.acl));
    END IF;
  END LOOP;
  FOR r IN
    SELECT p.proname, p.proacl::text AS acl FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname IN ('_purchase_operation_core','rpc_create_purchase_operation_v2')
  LOOP
    IF r.acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
      INSERT INTO h15_fail VALUES (format('FAIL (g): ACL de %s = %s (esperaba sólo postgres y service_role)', r.proname, r.acl));
    END IF;
  END LOOP;
END $$;

DO $$
DECLARE v_msg text;
BEGIN
  SELECT string_agg(msg, E'\n' ORDER BY msg) INTO v_msg FROM h15_fail;
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION E'GATE DOCUMENT_LINES_CONSISTENCY FAILED (etapa 1):\n%', v_msg;
  END IF;
  RAISE NOTICE 'PASS etapa 1: los 6 escritores (producto y servicio), el flag sin efecto, 0 funciones con el flag, barrido de anclas, reportes invariantes y ACLs.';
END $$;

-- ── Etapa 2 (f): backfill idempotente y convergente ────────────────────────────────────
-- Se aflojan los NOT NULL para sembrar fixtures sucias (las que dejaba el esquema previo),
-- se re-ejecuta la migración ENTERA y se asevera que converge. Todo dentro de la transacción.
CREATE TEMP TABLE h15_fix (s_nolines uuid, s_ledger uuid, s_var uuid, pu_none uuid, pu_nolines uuid, pu_desc uuid);
ALTER TABLE public.sale_items     ALTER COLUMN name_snapshot DROP NOT NULL;
ALTER TABLE public.purchase_items ALTER COLUMN name_snapshot DROP NOT NULL;

DO $$
DECLARE
  v_user uuid; v_account uuid; v_branch uuid; v_p uuid;
  v_s_nolines uuid; v_s_ledger uuid; v_s_var uuid; v_pu_nolines uuid; v_pu_desc uuid; v_pu_none uuid;
  v_op uuid := gen_random_uuid(); v_variant uuid;
BEGIN
  SELECT m.user_id, m.account_id INTO v_user, v_account FROM public.account_members m
    JOIN auth.users u ON u.id = m.user_id WHERE u.email = 'h15-document-lines@test.local' LIMIT 1;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  SELECT id INTO v_p FROM public.products WHERE account_id = v_account AND sku = 'H15-P1';

  -- venta de servicio histórica SIN ninguna línea (el caso de las 2 ventas de prod)
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user, v_account, NULL, 31920, 1, 31920, 'ARS', CURRENT_DATE, v_op, v_branch) RETURNING id INTO v_s_nolines;
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type, quantity_delta, quantity_before, quantity_after, reference_id, reference_type, performed_by, branch_id)
  VALUES (v_user, v_account, v_p, 'Nombre desde el ledger', 'sale', -1, 1, 0, v_s_nolines, 'sale', v_user, v_branch);

  -- venta con producto borrado: línea sin nombre, product_id NULL, nombre sólo en el ledger
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user, v_account, NULL, 10, 1, 10, 'ARS', CURRENT_DATE, gen_random_uuid(), v_branch) RETURNING id INTO v_s_ledger;
  INSERT INTO public.sale_items (sale_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
  VALUES (v_s_ledger, v_account, NULL, NULL, 1, 10, 10, NULL);
  INSERT INTO public.stock_movements (user_id, account_id, product_id, product_name, type, quantity_delta, quantity_before, quantity_after, reference_id, reference_type, performed_by, branch_id)
  VALUES (v_user, v_account, v_p, 'Producto borrado X', 'sale', -1, 1, 0, v_s_ledger, 'sale', v_user, v_branch);

  -- venta con línea canónica nombrada + fila legacy de variante SIN nombre (la fila se conserva y recibe nombre)
  INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id)
  VALUES (v_user, v_account, v_p, 20, 1, 20, 'ARS', CURRENT_DATE, gen_random_uuid(), v_branch) RETURNING id INTO v_s_var;
  INSERT INTO public.sale_items (sale_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
  VALUES (v_s_var, v_account, v_p, NULL, 1, 20, 20, 'H15 Producto Uno');
  INSERT INTO public.product_variants (product_id, name) VALUES (v_p, 'Variante H15') RETURNING id INTO v_variant;
  INSERT INTO public.sale_items (sale_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
  VALUES (v_s_var, v_account, NULL, v_variant, 1, 20, 20, NULL);

  -- compras: sin línea y sin descripción / sin línea y con descripción / línea sin nombre con descripción
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user, v_account, NULL, 12000, 1, 12000, NULL, CURRENT_DATE, gen_random_uuid(), v_branch) RETURNING id INTO v_pu_none;
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user, v_account, NULL, 20000, 1, 20000, '  Descripción de la compra  ', CURRENT_DATE, gen_random_uuid(), v_branch) RETURNING id INTO v_pu_nolines;
  INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id)
  VALUES (v_user, v_account, NULL, 30, 1, 30, 'Otra descripción', CURRENT_DATE, gen_random_uuid(), v_branch) RETURNING id INTO v_pu_desc;
  INSERT INTO public.purchase_items (purchase_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
  VALUES (v_pu_desc, v_account, NULL, NULL, 1, 30, 30, NULL);

  INSERT INTO h15_fix VALUES (v_s_nolines, v_s_ledger, v_s_var, v_pu_none, v_pu_nolines, v_pu_desc);
END $$;

-- La migración ENTERA (idempotente): la primera pasada repara las fixtures, la segunda no toca nada.
\i supabase/migrations/20261091000001_v31_document_lines_consistency.sql

CREATE TEMP TABLE h15_snapshot_1 AS
  SELECT 's' AS k, i.id::text, to_jsonb(i) AS j FROM public.sale_items i
  UNION ALL SELECT 'p', i.id::text, to_jsonb(i) FROM public.purchase_items i;

\i supabase/migrations/20261091000001_v31_document_lines_consistency.sql

DO $$
DECLARE
  v_label constant text := 'Ítem sin producto';
  f h15_fix; v_n int; v_changed int; v_name text; v_bf boolean;
BEGIN
  SELECT * INTO f FROM h15_fix;

  -- venta sin línea: gana la línea con el importe del header y el nombre del ledger
  SELECT count(*), max(name_snapshot), bool_and(snapshot_backfilled) INTO v_n, v_name, v_bf FROM public.sale_items WHERE sale_id = f.s_nolines AND variant_id IS NULL;
  IF v_n <> 1 OR v_name IS DISTINCT FROM 'Nombre desde el ledger' OR v_bf IS DISTINCT FROM true THEN
    INSERT INTO h15_fail VALUES (format('FAIL (f1): venta sin línea → líneas=%s nombre=%L backfilled=%s (esperaba 1, ''Nombre desde el ledger'', true)', v_n, v_name, v_bf));
  END IF;
  IF (SELECT subtotal FROM public.sale_items WHERE sale_id = f.s_nolines) IS DISTINCT FROM 31920 THEN
    INSERT INTO h15_fail VALUES ('FAIL (f1): el subtotal de la línea creada no coincide con el total del header (31920)');
  END IF;

  -- línea sin nombre y sin producto: nombre del ledger
  SELECT name_snapshot, snapshot_backfilled INTO v_name, v_bf FROM public.sale_items WHERE sale_id = f.s_ledger;
  IF v_name IS DISTINCT FROM 'Producto borrado X' OR v_bf IS DISTINCT FROM true THEN
    INSERT INTO h15_fail VALUES (format('FAIL (f2): línea sin nombre → %L / backfilled=%s (esperaba el nombre del ledger)', v_name, v_bf));
  END IF;

  -- fila legacy de variante: se conserva, recibe nombre; la canónica sigue siendo una sola
  SELECT count(*) INTO v_n FROM public.sale_items WHERE sale_id = f.s_var AND variant_id IS NULL;
  IF v_n <> 1 OR (SELECT count(*) FROM public.sale_items WHERE sale_id = f.s_var) <> 2 THEN
    INSERT INTO h15_fail VALUES ('FAIL (f3): la fila legacy de variante no se conservó, o se duplicó la canónica');
  END IF;
  IF (SELECT name_snapshot FROM public.sale_items WHERE sale_id = f.s_var AND variant_id IS NOT NULL) IS NULL THEN
    INSERT INTO h15_fail VALUES ('FAIL (f3): la fila legacy de variante quedó sin nombre');
  END IF;

  -- compras: etiqueta, descripción (con trim) y línea sin nombre con descripción
  IF (SELECT name_snapshot FROM public.purchase_items WHERE purchase_id = f.pu_none AND variant_id IS NULL) IS DISTINCT FROM v_label THEN
    INSERT INTO h15_fail VALUES ('FAIL (f4): compra sin línea ni descripción ni ledger debería quedar con la etiqueta');
  END IF;
  IF (SELECT name_snapshot FROM public.purchase_items WHERE purchase_id = f.pu_nolines AND variant_id IS NULL) IS DISTINCT FROM 'Descripción de la compra' THEN
    INSERT INTO h15_fail VALUES ('FAIL (f5): la línea de la compra debería llevar la descripción recortada');
  END IF;
  IF (SELECT name_snapshot FROM public.purchase_items WHERE purchase_id = f.pu_desc AND variant_id IS NULL) IS DISTINCT FROM 'Otra descripción' THEN
    INSERT INTO h15_fail VALUES ('FAIL (f6): la línea sin nombre debería tomar purchases.description');
  END IF;

  -- idempotencia: la segunda pasada no cambió NINGUNA fila de líneas
  SELECT count(*) INTO v_changed FROM (
    SELECT 's', i.id::text, to_jsonb(i) FROM public.sale_items i
    UNION ALL SELECT 'p', i.id::text, to_jsonb(i) FROM public.purchase_items i
    EXCEPT SELECT k, id, j FROM h15_snapshot_1) d;
  IF v_changed <> 0 THEN
    INSERT INTO h15_fail VALUES (format('FAIL (f7): la segunda pasada de la migración modificó o insertó %s filas de líneas (no es idempotente)', v_changed));
  END IF;
  IF (SELECT count(*) FROM h15_snapshot_1) <> (SELECT count(*) FROM public.sale_items) + (SELECT count(*) FROM public.purchase_items) THEN
    INSERT INTO h15_fail VALUES ('FAIL (f7): la segunda pasada cambió la cantidad de líneas');
  END IF;

  -- convergencia GLOBAL (incluye lo que dejaron otros gates): 0 residuo y el NOT NULL vuelto a imponer
  SELECT count(*) INTO v_n FROM public.sales s WHERE NOT EXISTS (SELECT 1 FROM public.sale_items i WHERE i.sale_id = s.id AND i.variant_id IS NULL);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s ventas sin línea canónica tras el backfill (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.purchases s WHERE NOT EXISTS (SELECT 1 FROM public.purchase_items i WHERE i.purchase_id = s.id AND i.variant_id IS NULL);
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s compras sin línea canónica tras el backfill (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM (SELECT sale_id FROM public.sale_items WHERE variant_id IS NULL GROUP BY 1 HAVING count(*) > 1) x;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s ventas con más de una línea canónica (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM (SELECT purchase_id FROM public.purchase_items WHERE variant_id IS NULL GROUP BY 1 HAVING count(*) > 1) x;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s compras con más de una línea canónica (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.sale_items WHERE name_snapshot IS NULL;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s líneas de venta sin nombre (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM public.purchase_items WHERE name_snapshot IS NULL;
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (f8): %s líneas de compra sin nombre (global)', v_n)); END IF;
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name IN ('sale_items','purchase_items') AND column_name = 'name_snapshot' AND is_nullable = 'YES';
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES ('FAIL (f9): name_snapshot no quedó NOT NULL en las dos tablas tras la migración'); END IF;

  -- (f10) la columna rechaza de verdad una línea sin nombre
  BEGIN
    INSERT INTO public.sale_items (sale_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
    VALUES (f.s_nolines, (SELECT account_id FROM public.sales WHERE id = f.s_nolines), NULL, NULL, 1, 1, 1, NULL);
    INSERT INTO h15_fail VALUES ('FAIL (f10): sale_items aceptó una línea con name_snapshot NULL');
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;
  BEGIN
    INSERT INTO public.purchase_items (purchase_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
    VALUES (f.pu_none, (SELECT account_id FROM public.purchases WHERE id = f.pu_none), NULL, NULL, 1, 1, 1, NULL);
    INSERT INTO h15_fail VALUES ('FAIL (f10): purchase_items aceptó una línea con name_snapshot NULL');
  EXCEPTION WHEN not_null_violation THEN
    NULL;
  END;

  -- (c) tras la migración (que se re-ejecutó entera) tampoco hay funciones con el flag
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosrc ILIKE '%sale_items_rpc_v2%';
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (c): %s funciones mencionan sale_items_rpc_v2 tras re-ejecutar la migración', v_n)); END IF;

  SELECT count(*) INTO v_n FROM public.account_feature_flags WHERE flag_key = 'sale_items_rpc_v2';
  IF v_n <> 0 THEN INSERT INTO h15_fail VALUES (format('FAIL (b): quedan %s filas del flag tras la migración', v_n)); END IF;
END $$;

DO $$
DECLARE v_msg text;
BEGIN
  SELECT string_agg(msg, E'\n' ORDER BY msg) INTO v_msg FROM h15_fail;
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION E'GATE DOCUMENT_LINES_CONSISTENCY FAILED (etapa 2):\n%', v_msg;
  END IF;
  RAISE NOTICE 'GATE DOCUMENT_LINES_CONSISTENCY PASSED: líneas universales — seis escritores con producto y servicio, flag sin efecto, backfill idempotente y convergente, name_snapshot NOT NULL, reportes invariantes y ACLs.';
END $$;

ROLLBACK;
