-- =============================================================================
-- test_edicion_preserva_contexto.sql — Gates de comportamiento:
-- edicion-preserva-contexto.
--
-- Verifica 20260930000001_edicion_preserva_contexto.sql sobre
-- rpc_atomic_update_sale_operation / rpc_atomic_update_purchase_operation:
--
--   F1 — el contexto del header (branch_id, canal, unit_id, supplier_id,
--        cost_center_id) sobrevive a la edición en vez de quedar NULL en
--        silencio; branch_id/canal se vuelven ADEMÁS editables (tri-estado,
--        espejo de payment_method_id de #419); la pata APPLY del ledger
--        aterriza en la sucursal EFECTIVA (no en la default); la sales_orders
--        promovida sin comprobante se re-apunta al operation_id nuevo.
--   F2 — una VENTA con comprobante fiscal pending_cae/authorized es
--        inmutable (P0423); rejected y sin comprobante no bloquean.
--   F3 — quantity acepta decimales en la ruta de edición, igual que la de
--        creación.
--
-- Patrón del proyecto (test_operation_edit_lines.sql / test_stock_movements_
-- edicion.sql): acumular fallos en text[], un solo RAISE EXCEPTION al final.
-- Anchors sintéticos vía handle_new_user. Sesión simulada con set_config,
-- LOCAL a la transacción de este archivo — NUNCA usar este patrón contra prod.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures        text[] := '{}';

  -- Anchor A: cuenta principal.
  v_email_a         text := 'edicion-preserva-contexto-a@test.local';
  v_user_a          uuid := gen_random_uuid();
  v_account_a       uuid;
  v_branch_a        uuid;  -- default (auto-provisionada)
  v_branch_b        uuid;  -- no-default, activa
  v_branch_closed   uuid;  -- activa pero status='closed'
  v_client_a        uuid;

  -- Anchor B: cuenta ajena, para el gate de sucursal de otra cuenta.
  v_email_b         text := 'edicion-preserva-contexto-b@test.local';
  v_user_b          uuid := gen_random_uuid();
  v_account_b       uuid;
  v_branch_other    uuid;

  -- Productos / unidades / dimensiones.
  v_p1              uuid;
  v_p2              uuid;
  v_pp1             uuid;
  v_unit_kg         uuid;
  v_supplier_1      uuid;
  v_cc_1            uuid;
  v_fake_company_id uuid := gen_random_uuid();

  -- Fiscal fixtures.
  v_fp_id           uuid;
  v_pv_id           uuid;
  v_doc_authorized  uuid;
  v_doc_pending     uuid;
  v_doc_rejected    uuid;

  v_result          jsonb;
  v_op              uuid;
  v_count           integer;
  v_val_uuid        uuid;
  v_val_text        text;
  v_val_numeric     numeric;
  v_stock_before    numeric;
  v_stock_after     numeric;
  v_sale_id         uuid;
  v_sale_id2        uuid;
  v_purch_id        uuid;
  v_so_id           uuid;
  v_caught_sqlstate text;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor A
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Edicion Preserva Contexto A', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a
  FROM   public.account_members
  WHERE  user_id = v_user_a
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_a IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor A — handle_new_user no corrió';
  END IF;

  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;

  INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
  VALUES (v_account_a, 'Sucursal EPC No-Default', TRUE, 'active', now())
  RETURNING id INTO v_branch_b;

  INSERT INTO public.branches (account_id, name, is_active, status, opened_at, closed_at)
  VALUES (v_account_a, 'Sucursal EPC Cerrada', TRUE, 'closed', now(), now())
  RETURNING id INTO v_branch_closed;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_a, v_account_a, 'Cliente Gate EPC A')
  RETURNING id INTO v_client_a;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto EPC P1', 'EPC-P1', 600.00, 1000.00)
  RETURNING id INTO v_p1;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_a, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p1, v_branch_b, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto EPC P2 (decimal)', 'EPC-P2', 200.00, 400.00)
  RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p2, v_branch_a, 50);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Producto EPC PP1 (compra)', 'EPC-PP1', 300.00, 500.00)
  RETURNING id INTO v_pp1;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
  VALUES (v_account_a, 'Kilogramo EPC', 'kg', 'weight', 1.0, false)
  RETURNING id INTO v_unit_kg;

  INSERT INTO public.suppliers (account_id, company_id, name)
  VALUES (v_account_a, v_fake_company_id, 'Proveedor Gate EPC')
  RETURNING id INTO v_supplier_1;

  INSERT INTO public.cost_centers (account_id, name, code)
  VALUES (v_account_a, 'Centro Gate EPC', 'EPC-CC')
  RETURNING id INTO v_cc_1;

  -- Fiscal fixtures: perfil + punto de venta + 3 comprobantes (authorized /
  -- pending_cae / rejected) — mismo patrón mínimo de
  -- 20260828000001_v31_rls_collision_rpcs.sql.
  INSERT INTO public.fiscal_profiles (id, account_id, cuit, iva_condition, ambiente, delegacion_autorizada, created_at)
  VALUES (gen_random_uuid(), v_account_a, '20111111112', 'responsable_inscripto', 'homologacion', true, now())
  RETURNING id INTO v_fp_id;

  INSERT INTO public.points_of_sale (id, fiscal_profile_id, account_id, numero, is_active, created_at)
  VALUES (gen_random_uuid(), v_fp_id, v_account_a, 1, true, now())
  RETURNING id INTO v_pv_id;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 1, 1000, 'authorized', 0)
  RETURNING id INTO v_doc_authorized;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 2, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_pending;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 3, 1000, 'rejected', 3)
  RETURNING id INTO v_doc_rejected;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Setup anchor B (cuenta ajena, solo para el gate de sucursal cross-account)
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Edicion Preserva Contexto B', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b
  FROM   public.account_members
  WHERE  user_id = v_user_b
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: no se pudo resolver account para el anchor B';
  END IF;

  SELECT id INTO v_branch_other FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  -- ── Sesión sintética del anchor A ──────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.1 — editar una venta imputada a sucursal no-default + canal, sin
  -- informar ninguno, conserva ambos (RED hoy: ambos quedan NULL).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-21-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5, 'unit_id', NULL)),
    v_branch_b, 'instagram', NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  -- Editar SIN informar branch/canal — solo cambia la cantidad.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 4))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  SELECT branch_id, canal INTO v_val_uuid, v_val_text FROM public.sales WHERE id = v_sale_id;
  IF v_val_uuid IS DISTINCT FROM v_branch_b THEN
    v_failures := array_append(v_failures, format('FAIL (2.1 branch_id): esperaba branch_id=%s preservado, quedó %s', v_branch_b, v_val_uuid));
  ELSIF v_val_text IS DISTINCT FROM 'instagram' THEN
    v_failures := array_append(v_failures, format('FAIL (2.1 canal): esperaba canal=instagram preservado, quedó %s', v_val_text));
  ELSE
    RAISE NOTICE 'PASS (2.1): editar sin informar sucursal/canal preserva ambos (branch_id no-default + canal=instagram)';
  END IF;

  -- Triangulación (spec operation-edit-context, escenario "reimputar la
  -- sucursal"): informar p_branch_provided=true con una sucursal válida
  -- distinta reimputa. Verifica que el tri-estado no es un simple COALESCE
  -- ciego (D3 — alternativa descartada).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 4)),
    NULL, false, v_branch_a, true
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  SELECT branch_id INTO v_val_uuid FROM public.sales WHERE id = v_sale_id;
  IF v_val_uuid IS DISTINCT FROM v_branch_a THEN
    v_failures := array_append(v_failures, format('FAIL (triangulación reimputar sucursal): esperaba branch_id=%s (reimputada), quedó %s', v_branch_a, v_val_uuid));
  ELSE
    RAISE NOTICE 'PASS (triangulación): reimputar la sucursal con p_branch_provided=true la cambia efectivamente';
  END IF;

  -- Triangulación (spec, escenario "desimputar el canal explícitamente"):
  -- p_canal_provided=true con NULL desimputa, no restaura el viejo.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 4)),
    NULL, false, NULL, false, NULL, true
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  SELECT canal INTO v_val_text FROM public.sales WHERE id = v_sale_id;
  IF v_val_text IS NOT NULL THEN
    v_failures := array_append(v_failures, format('FAIL (triangulación desimputar canal): esperaba canal NULL tras p_canal_provided=true/NULL, quedó %s', v_val_text));
  ELSE
    RAISE NOTICE 'PASS (triangulación): desimputar el canal explícitamente (provided=true, valor NULL) lo deja sin canal';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.2 — editar una compra con supplier_id, cost_center_id y unit_id
  -- conserva los tres (RED hoy: los tres quedan NULL). rpc_create_purchase_
  -- operation no tiene parámetro p_supplier_id (0/427 en prod hoy — la única
  -- forma de que una compra tenga supplier_id hoy es una fila preexistente),
  -- así que la fila "vieja" se construye con INSERT directo, simulando una
  -- compra ya imputada.
  -- ═══════════════════════════════════════════════════════════════════════
  DECLARE
    v_purch_op uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.purchases (
      user_id, account_id, product_id, amount, quantity, unit_id, total, description, date,
      operation_id, branch_id, supplier_id, cost_center_id
    ) VALUES (
      v_user_a, v_account_a, v_pp1, 50.00, 10, v_unit_kg, 500.00, 'Compra gate EPC 2.2', CURRENT_DATE,
      v_purch_op, v_branch_a, v_supplier_1, v_cc_1
    ) RETURNING id INTO v_purch_id;
    PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pp1, v_branch_a, 10);

    v_result := public.rpc_atomic_update_purchase_operation(
      ARRAY[v_purch_id], CURRENT_DATE, 'Compra gate EPC 2.2 editada',
      jsonb_build_array(jsonb_build_object('product_id', v_pp1, 'amount', 55.00, 'quantity', 10, 'unit_id', v_unit_kg))
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_purch_id FROM public.purchases WHERE operation_id = v_op AND product_id = v_pp1;

    DECLARE
      v_pre_count integer := array_length(v_failures, 1);
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purch_id AND supplier_id = v_supplier_1) THEN
        v_failures := array_append(v_failures, 'FAIL (2.2 supplier_id): esperaba supplier_id preservado tras la edición');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purch_id AND cost_center_id = v_cc_1) THEN
        v_failures := array_append(v_failures, 'FAIL (2.2 cost_center_id): esperaba cost_center_id preservado tras la edición');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE id = v_purch_id AND unit_id = v_unit_kg) THEN
        v_failures := array_append(v_failures, 'FAIL (2.2 unit_id header): esperaba unit_id preservado en el header tras la edición');
      END IF;
      IF COALESCE(array_length(v_failures, 1), 0) = COALESCE(v_pre_count, 0) THEN
        RAISE NOTICE 'PASS (2.2): editar una compra conserva supplier_id, cost_center_id y unit_id';
      END IF;
    END;
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.3 — editar una venta con unit_id conserva la unidad en el header
  -- Y en sale_items (RED hoy: la línea nace con unit_id=NULL explícito).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-23-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 80.00, 'quantity', 3, 'unit_id', v_unit_kg)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

  -- Editar re-enviando el mismo unit_id por ítem (D7/D11: viaja pegado a la
  -- línea — el form lo prefillea y lo reenvía, igual que quantity/price).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 80.00, 'quantity', 2, 'unit_id', v_unit_kg))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

  IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND unit_id = v_unit_kg) THEN
    v_failures := array_append(v_failures, 'FAIL (2.3 header): esperaba unit_id preservado en sales tras la edición');
  ELSIF NOT EXISTS (SELECT 1 FROM public.sale_items WHERE sale_id = v_sale_id AND unit_id = v_unit_kg) THEN
    v_failures := array_append(v_failures, 'FAIL (2.3 línea): esperaba unit_id preservado en sale_items tras la edición (nacía NULL explícito)');
  ELSE
    RAISE NOTICE 'PASS (2.3): editar una venta con unit_id lo conserva en el header y en sale_items';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.4 — editar una venta de sucursal no-default deja AMBAS patas del
  -- ledger sobre esa sucursal y no toca el stock de la default (RED hoy: la
  -- pata APPLY cae en la default).
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;

  v_result := public.rpc_create_sale_operation(
    'epc-sale-24-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 4, 'unit_id', NULL)),
    v_branch_b, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  -- Editar SIN informar sucursal (debe preservar v_branch_b en ambas patas).
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id2 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  -- Pata APPLY (id nuevo) debe estar en branch_id = v_branch_b, no en la default.
  IF NOT EXISTS (
    SELECT 1 FROM public.stock_movements
    WHERE reference_id = v_sale_id2 AND reference_type = 'sale' AND type = 'sale' AND branch_id = v_branch_b
  ) THEN
    v_failures := array_append(v_failures, 'FAIL (2.4 APPLY branch): esperaba la pata APPLY sobre v_branch_b (no la default)');
  ELSE
    RAISE NOTICE 'PASS (2.4 APPLY branch): la pata APPLY de la edición aterriza en la sucursal no-default preservada';
  END IF;

  -- El stock de la sucursal DEFAULT no debe haberse movido por esta secuencia.
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  IF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.4 default intacta): branch_stock de la sucursal default no debería cambiar (%s), quedó %s', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (2.4 default intacta): editar una venta de sucursal no-default no mueve stock de la sucursal default';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.5 — editar una venta creada con quantity=2.5 a 3.25 funciona y
  -- persiste 3.25 en header, línea y delta de stock (RED hoy: 22P02).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-25-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 40.00, 'quantity', 2.5, 'unit_id', v_unit_kg)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 40.00, 'quantity', 3.25, 'unit_id', v_unit_kg))
    );
    v_op := (v_result->>'operation_id')::uuid;
    SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;

    IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 3.25) THEN
      v_failures := array_append(v_failures, 'FAIL (2.5 header): esperaba quantity=3.25 en sales');
    ELSIF NOT EXISTS (SELECT 1 FROM public.sale_items WHERE sale_id = v_sale_id AND quantity = 3.25) THEN
      v_failures := array_append(v_failures, 'FAIL (2.5 línea): esperaba quantity=3.25 en sale_items');
    ELSIF NOT EXISTS (
      SELECT 1 FROM public.stock_movements
      WHERE reference_id = v_sale_id AND reference_type = 'sale' AND type = 'sale' AND quantity_delta = -3.25
    ) THEN
      v_failures := array_append(v_failures, 'FAIL (2.5 stock delta): esperaba quantity_delta=-3.25 en la pata APPLY');
    ELSE
      RAISE NOTICE 'PASS (2.5): editar una venta de 2.5 a 3.25 funciona y persiste el decimal exacto en header/línea/stock';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_failures := array_append(v_failures, format('FAIL (2.5): editar a quantity=3.25 debería funcionar, levantó SQLSTATE %s (%s)', v_caught_sqlstate, SQLERRM));
  END;

  -- Triangulación F3 (spec "la cantidad decimal no se redondea"): tres
  -- decimales exactos, no solo uno.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 40.00, 'quantity', 1.234, 'unit_id', v_unit_kg))
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p2;
  IF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 1.234) THEN
    v_failures := array_append(v_failures, 'FAIL (triangulación 3 decimales): esperaba quantity=1.234 exacto, sin redondeo');
  ELSE
    RAISE NOTICE 'PASS (triangulación): tres decimales (1.234) persisten exactos, sin redondeo a entero';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.6 — editar una venta con comprobante 'authorized' falla con
  -- P0423 y deja filas/líneas/stock intactos (RED hoy: la edición procede y
  -- destruye la venta facturada).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-26-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 200, v_user_a, v_op, v_doc_authorized)
  RETURNING id INTO v_so_id;

  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;

  v_caught_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 9))
    );
    v_failures := array_append(v_failures, 'FAIL (2.6): editar una venta con comprobante authorized debería fallar, no falló');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;

  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;

  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.6 SQLSTATE): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 2) THEN
    v_failures := array_append(v_failures, 'FAIL (2.6 fila intacta): la venta facturada no debería haber cambiado');
  ELSIF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.6 stock intacto): branch_stock no debería cambiar (%s), quedó %s', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (2.6): editar una venta con comprobante authorized falla con P0423 y deja fila/stock intactos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.7 — pending_cae también bloquea (P0423); rejected y sin
  -- comprobante NO bloquean (control negativo — sin esto 2.6 no prueba nada).
  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) pending_cae bloquea.
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27a-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 100, v_user_a, v_op, v_doc_pending);

  v_caught_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.7a pending_cae): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSE
    RAISE NOTICE 'PASS (2.7a): comprobante pending_cae también bloquea la edición con P0423';
  END IF;

  -- (b) rejected NO bloquea.
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27b-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 100, v_user_a, v_op, v_doc_rejected);

  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
    );
    RAISE NOTICE 'PASS (2.7b): comprobante rejected NO bloquea la edición';
  EXCEPTION
    WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (2.7b rejected): un comprobante rejected NO debería bloquear la edición, levantó %s', SQLERRM));
  END;

  -- (c) sin comprobante (ni sales_orders) NO bloquea — control negativo base.
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27c-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
    );
    RAISE NOTICE 'PASS (2.7c): una venta sin sales_orders/comprobante edita normalmente (guard fiscal no dispara)';
  EXCEPTION
    WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (2.7c sin comprobante): no debería bloquear, levantó %s', SQLERRM));
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.8 — editar una venta promovida a sales_orders SIN comprobante
  -- re-apunta sale_operation_id al operation_id nuevo; no quedan órdenes
  -- huérfanas (RED hoy: la orden queda colgada).
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-28-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;

  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 300, v_user_a, v_op, NULL)
  RETURNING id INTO v_so_id;

  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 7))
  );
  v_op := (v_result->>'operation_id')::uuid;  -- operation_id NUEVO

  IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so_id AND sale_operation_id = v_op) THEN
    v_failures := array_append(v_failures, 'FAIL (2.8 re-apuntado): la sales_orders promovida debería apuntar al operation_id nuevo tras la edición');
  ELSE
    RAISE NOTICE 'PASS (2.8): la sales_orders promovida sin comprobante se re-apunta al operation_id nuevo tras editar';
  END IF;

  -- Huérfanas nuevas = 0: ninguna sales_orders de esta cuenta apunta a un
  -- operation_id sin ninguna fila viva en sales.
  SELECT COUNT(*) INTO v_count
  FROM   public.sales_orders so
  WHERE  so.account_id = v_account_a
    AND  so.sale_operation_id IS NOT NULL
    AND  NOT EXISTS (SELECT 1 FROM public.sales s WHERE s.operation_id = so.sale_operation_id);
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.8 huérfanas nuevas): %s sales_orders de la cuenta A quedaron apuntando a un operation_id sin ventas vivas', v_count));
  ELSE
    RAISE NOTICE 'PASS (2.8 huérfanas nuevas): ninguna sales_orders de la cuenta A quedó apuntando a un operation_id inexistente';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.9 — reimputar sucursal a una de otra cuenta, o cerrada, falla con
  -- P0422 sin haber revertido ni reaplicado stock.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-29-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;

  -- (a) sucursal de otra cuenta.
  v_caught_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3)),
      NULL, false, v_branch_other, true
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0422' THEN
    v_failures := array_append(v_failures, format('FAIL (2.9a cross-account): esperaba P0422, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.9a stock intacto): no debería haber revertido/reaplicado stock (%s), quedó %s', v_stock_before, v_stock_after));
  ELSIF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 3) THEN
    v_failures := array_append(v_failures, 'FAIL (2.9a fila intacta): la venta no debería haber cambiado tras el rechazo P0422');
  ELSE
    RAISE NOTICE 'PASS (2.9a): reimputar a una sucursal de otra cuenta falla con P0422, sin revertir ni reaplicar stock';
  END IF;

  -- (b) sucursal cerrada (misma cuenta).
  v_caught_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 3)),
      NULL, false, v_branch_closed, true
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0422' THEN
    v_failures := array_append(v_failures, format('FAIL (2.9b cerrada): esperaba P0422, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.9b stock intacto): no debería haber revertido/reaplicado stock (%s), quedó %s', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (2.9b): reimputar a una sucursal cerrada falla con P0422, sin revertir ni reaplicar stock';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- No-regresión rápida: el acarreo de líneas (#415) y el par espejo del
  -- ledger (#417) siguen funcionando después de reescribir por completo el
  -- cuerpo de ambas RPCs (las suites dedicadas de #415/#417/#419 corren sin
  -- modificar en el mismo CI — esto es un spot-check adicional, no un
  -- reemplazo).
  -- ═══════════════════════════════════════════════════════════════════════
  IF NOT EXISTS (SELECT 1 FROM public.sale_items WHERE sale_id = v_sale_id) THEN
    v_failures := array_append(v_failures, 'FAIL (no-regresión #415): la venta editada en 2.9 debería tener su sale_items');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.stock_movements
    WHERE reference_id = v_sale_id AND reference_type = 'sale' AND type = 'sale'
  ) THEN
    v_failures := array_append(v_failures, 'FAIL (no-regresión #417): la venta editada en 2.9 debería tener su movimiento APPLY');
  END IF;
  IF array_length(v_failures, 1) IS NULL THEN
    RAISE NOTICE 'PASS (spot-check no-regresión): #415 (sale_items) y #417 (stock_movements) siguen intactos tras la reescritura completa del cuerpo';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- Resultado
  -- ═══════════════════════════════════════════════════════════════════════
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE EDICION_PRESERVA_CONTEXTO FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE EDICION_PRESERVA_CONTEXTO PASSED: F1 (contexto preservado y tri-estado branch/canal, ledger en sucursal efectiva, sales_orders re-apuntada), F2 (P0423 sobre pending_cae/authorized, rejected y sin comprobante no bloquean) y F3 (quantity decimal exacto) verificados.';

  -- ── Limpieza ────────────────────────────────────────────────────────────
  DELETE FROM public.sales_orders     WHERE account_id = v_account_a;
  DELETE FROM public.fiscal_documents WHERE account_id = v_account_a;
  DELETE FROM public.points_of_sale   WHERE account_id = v_account_a;
  DELETE FROM public.fiscal_profiles  WHERE account_id = v_account_a;
  DELETE FROM public.sale_items      WHERE account_id = v_account_a;
  DELETE FROM public.purchase_items  WHERE account_id = v_account_a;
  DELETE FROM public.stock_movements WHERE account_id = v_account_a;
  DELETE FROM public.sales           WHERE account_id = v_account_a;
  DELETE FROM public.purchases       WHERE account_id = v_account_a;
  DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.branch_stock    WHERE account_id = v_account_a;
  DELETE FROM public.products        WHERE account_id = v_account_a;
  DELETE FROM public.suppliers       WHERE account_id = v_account_a;
  DELETE FROM public.cost_centers    WHERE account_id = v_account_a;
  DELETE FROM public.units_of_measure WHERE account_id = v_account_a;
  DELETE FROM public.clients         WHERE account_id = v_account_a;
  DELETE FROM public.events          WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
  DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);

EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      DELETE FROM public.sales_orders     WHERE account_id = v_account_a;
      DELETE FROM public.fiscal_documents WHERE account_id = v_account_a;
      DELETE FROM public.points_of_sale   WHERE account_id = v_account_a;
      DELETE FROM public.fiscal_profiles  WHERE account_id = v_account_a;
      DELETE FROM public.sale_items      WHERE account_id = v_account_a;
      DELETE FROM public.purchase_items  WHERE account_id = v_account_a;
      DELETE FROM public.stock_movements WHERE account_id = v_account_a;
      DELETE FROM public.sales           WHERE account_id = v_account_a;
      DELETE FROM public.purchases       WHERE account_id = v_account_a;
      DELETE FROM public.analytics_events WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.branch_stock    WHERE account_id = v_account_a;
      DELETE FROM public.products        WHERE account_id = v_account_a;
      DELETE FROM public.suppliers       WHERE account_id = v_account_a;
      DELETE FROM public.cost_centers    WHERE account_id = v_account_a;
      DELETE FROM public.units_of_measure WHERE account_id = v_account_a;
      DELETE FROM public.clients         WHERE account_id = v_account_a;
      DELETE FROM public.events          WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_a, v_account_b));
      DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
      DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
