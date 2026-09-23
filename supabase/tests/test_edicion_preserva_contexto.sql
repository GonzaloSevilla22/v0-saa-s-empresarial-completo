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
--   F2 — una VENTA con comprobante fiscal es inmutable (P0423) SÓLO cuando el
--        pedido YA SALIÓ hacia ARCA. venta-editable-sin-cae (D2) reemplaza el
--        predicado original ("hay comprobante pending_cae/authorized") por
--        "el comprobante ya salió": authorized, o pending_cae MARCADO
--        (cae_submit_started_at) o CONGELADO (cae_submit_unconfirmed_at).
--        Un pending_cae sin ninguna marca ya NO bloquea: se ANULA (voided)
--        en la misma transacción de la edición/borrado. rejected, voided y
--        sin comprobante tampoco bloquean.
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
  -- venta-editable-sin-cae: tres comprobantes más para separar "pendiente y
  -- todavía NO enviado" (anulable) de "pendiente pero YA enviado" (bloquea).
  v_doc_marked      uuid;  -- pending_cae con cae_submit_started_at    → BLOQUEA
  v_doc_frozen      uuid;  -- pending_cae con cae_submit_unconfirmed_at → BLOQUEA
  v_doc_lease       uuid;  -- pending_cae con lease/backoff pero SIN marca → anulable
  v_doc_void_del    uuid;  -- pending_cae sin marca, para el caso de BORRADO
  v_msg             text;
  v_status_text     text;
  -- Marca de "cuántos fallos había antes de este bloque", para que el
  -- RAISE NOTICE de PASS de un bloque no dependa de que NINGÚN bloque
  -- anterior haya fallado.
  v_fail_before     integer;

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

  -- fiscal-riesgos-residuales (R2): trg_guard_fiscal_document_insert_interno
  -- rechaza con P0436 todo INSERT que no nazca pending_cae y sin CAE. Los dos
  -- comprobantes 'authorized'/'rejected' de este fixture son estados FINALES
  -- (a los que por el camino legítimo se llega con un UPDATE del relay), así
  -- que eluden el trigger de forma acotada y deliberada. El 'pending_cae' del
  -- medio queda FUERA de la elusión a propósito: es el control positivo de que
  -- el camino legítimo sigue abierto.
  SET session_replication_role = replica;
  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 1, 1000, 'authorized', 0)
  RETURNING id INTO v_doc_authorized;
  SET session_replication_role = DEFAULT;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 2, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_pending;

  SET session_replication_role = replica;
  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 3, 1000, 'rejected', 3)
  RETURNING id INTO v_doc_rejected;
  SET session_replication_role = DEFAULT;

  -- venta-editable-sin-cae: los tres pendientes "con historia" NACEN
  -- pending_cae limpios (camino legítimo, sin eludir
  -- trg_guard_fiscal_document_insert_interno — que rechaza con P0436 un
  -- INSERT que ya traiga marca) y recién después reciben la marca / el lease
  -- por UPDATE. Un UPDATE que NO cambia `status` no dispara
  -- fiscal_documents_enforce_status_transition (su WHEN es
  -- old.status IS DISTINCT FROM new.status), así que no hace falta ninguna
  -- elusión: es exactamente lo que hace el relay en producción.
  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 4, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_marked;
  UPDATE public.fiscal_documents
  SET    cae_submit_started_at = now(), arca_requested_number = 4
  WHERE  id = v_doc_marked;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 5, 1000, 'pending_cae', 1)
  RETURNING id INTO v_doc_frozen;
  UPDATE public.fiscal_documents
  SET    cae_submit_unconfirmed_at = now(), last_error = 'timeout contra ARCA'
  WHERE  id = v_doc_frozen;

  -- Lease de claim_pending (+5 min) MÁS backoff de update_retry, SIN ninguna
  -- marca: el pedido nunca salió hacia ARCA, así que esta venta TIENE que
  -- poder editarse (D3 — si alguien mete next_attempt_at en el predicado,
  -- una venta queda inmutable hasta 60 minutos por un backoff).
  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 6, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_lease;
  UPDATE public.fiscal_documents
  SET    next_attempt_at = now() + interval '15 minutes', attempts = 3,
         last_error = 'fallo previo al envío'
  WHERE  id = v_doc_lease;

  INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
  VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 7, 1000, 'pending_cae', 0)
  RETURNING id INTO v_doc_void_del;

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
  v_msg := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 9))
    );
    v_failures := array_append(v_failures, 'FAIL (2.6): editar una venta con comprobante authorized debería fallar, no falló');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
  END;

  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;

  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.6 SQLSTATE): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  -- venta-editable-sin-cae: con tres causas distintas compartiendo P0423, el
  -- SQLSTATE dejó de alcanzar para saber CUÁL disparó. El token del mensaje
  -- es lo que distingue "emití una nota de crédito" de "esperá al relay", y
  -- es lo que lee el frontend — se asserta explícitamente.
  ELSIF position('invoiced_operation_immutable' in COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.6 token): esperaba el token invoiced_operation_immutable en el mensaje, obtuvo: %s', COALESCE(v_msg, '<sin mensaje>')));
  ELSIF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 2) THEN
    v_failures := array_append(v_failures, 'FAIL (2.6 fila intacta): la venta facturada no debería haber cambiado');
  ELSIF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.6 stock intacto): branch_stock no debería cambiar (%s), quedó %s', v_stock_before, v_stock_after));
  ELSE
    RAISE NOTICE 'PASS (2.6): editar una venta con comprobante authorized falla con P0423 (token invoiced_operation_immutable) y deja fila/stock intactos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.7 — venta-editable-sin-cae (D2), REESCRITO: un pending_cae que
  -- TODAVÍA NO SALIÓ hacia ARCA ya NO bloquea — la venta se edita y el
  -- comprobante se ANULA (voided) en la misma transacción. rejected, voided
  -- y sin comprobante siguen sin bloquear (controles negativos — sin ellos
  -- 2.6 y 2.10/2.11 no prueban nada).
  --
  -- Este bloque afirmaba EXACTAMENTE lo contrario hasta este change
  -- ("pending_cae también bloquea"): era la regla vieja de
  -- edicion-preserva-contexto F2, más estricta de lo que el PO necesita.
  -- Se REESCRIBE, no se extiende.
  -- ═══════════════════════════════════════════════════════════════════════
  -- (a) pending_cae SIN marca: edita y ANULA el comprobante.
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27a-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 100, v_user_a, v_op, v_doc_pending)
  RETURNING id INTO v_so_id;

  v_caught_sqlstate := NULL;
  v_result := NULL;
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
  END;

  IF v_caught_sqlstate IS NOT NULL THEN
    v_failures := array_append(v_failures, format('FAIL (2.7a pending sin marca): la edición debería HABER FUNCIONADO (el comprobante nunca salió hacia ARCA), levantó %s (%s)', v_caught_sqlstate, COALESCE(v_msg, '')));
  ELSE
    v_op := (v_result->>'operation_id')::uuid;

    SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_pending;
    IF v_status_text IS DISTINCT FROM 'voided' THEN
      v_failures := array_append(v_failures, format('FAIL (2.7a anulación): el comprobante pendiente debería quedar voided, quedó %s', COALESCE(v_status_text, '<inexistente>')));
    END IF;

    -- El motivo y el historial: sin la fila de document_status_history la
    -- anulación es invisible para una auditoría posterior.
    SELECT COUNT(*) INTO v_count
    FROM   public.document_status_history
    WHERE  document_type = 'fiscal_document'
      AND  document_id   = v_doc_pending
      AND  from_status   = 'pending_cae'
      AND  to_status     = 'voided'
      AND  reason IS NOT NULL AND trim(reason) <> '';
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (2.7a historial): esperaba 1 fila pending_cae→voided con motivo en document_status_history, hay %s', v_count));
    END IF;

    -- D5: el vínculo orden↔comprobante anulado SOBREVIVE (el badge "Anulado"
    -- lo necesita); y la orden se re-apunta al operation_id nuevo.
    IF NOT EXISTS (
      SELECT 1 FROM public.sales_orders
      WHERE id = v_so_id AND fiscal_document_id = v_doc_pending AND sale_operation_id = v_op
    ) THEN
      v_failures := array_append(v_failures, 'FAIL (2.7a orden): la sales_order debería conservar fiscal_document_id (apuntando al anulado) y re-apuntar sale_operation_id al operation_id nuevo');
    END IF;

    -- El efecto de la edición ocurrió de verdad (si no, "no falló" no prueba nada).
    IF NOT EXISTS (SELECT 1 FROM public.sales WHERE operation_id = v_op AND product_id = v_p1 AND quantity = 5) THEN
      v_failures := array_append(v_failures, 'FAIL (2.7a edición efectiva): la venta editada debería tener quantity=5 en la operación nueva');
    END IF;

    IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
      RAISE NOTICE 'PASS (2.7a): un comprobante pending_cae SIN marca de envío ya no bloquea — la venta se edita y el comprobante queda voided con motivo e historial';
    END IF;
  END IF;

  -- (b) rejected NO bloquea, y TAMPOCO se toca (no es anulable: nunca llegó
  -- a existir fiscalmente, así que no hay nada que anular — el helper
  -- devuelve NULL y no escribe historial).
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27b-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 100, v_user_a, v_op, v_doc_rejected);

  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 5))
    );
    SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_rejected;
    IF v_status_text IS DISTINCT FROM 'rejected' THEN
      v_failures := array_append(v_failures, format('FAIL (2.7b intacto): un comprobante rejected NO debe anularse, quedó %s', COALESCE(v_status_text, '<inexistente>')));
    END IF;
    SELECT COUNT(*) INTO v_count
    FROM   public.document_status_history
    WHERE  document_type = 'fiscal_document' AND document_id = v_doc_rejected;
    IF v_count <> 0 THEN
      v_failures := array_append(v_failures, format('FAIL (2.7b historial): un rejected no debería generar ninguna transición, hay %s', v_count));
    END IF;
    IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
      RAISE NOTICE 'PASS (2.7b): comprobante rejected NO bloquea la edición y NO se toca (sin anulación ni historial)';
    END IF;
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

  -- (d) voided NO bloquea (control negativo del estado nuevo): una venta
  -- cuyo comprobante ya se anuló se puede volver a editar cuantas veces haga
  -- falta, y la segunda edición NO escribe una segunda transición.
  v_result := public.rpc_create_sale_operation(
    'epc-sale-27d-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  -- v_doc_pending YA quedó voided en (a): se reusa como fixture del estado
  -- terminal nuevo, alcanzado por el camino REAL (no sembrado a mano).
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 100, v_user_a, v_op, v_doc_pending);

  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 4))
    );
    SELECT COUNT(*) INTO v_count
    FROM   public.document_status_history
    WHERE  document_type = 'fiscal_document' AND document_id = v_doc_pending AND to_status = 'voided';
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('FAIL (2.7d idempotencia): editar una venta cuyo comprobante YA está voided no debe escribir una segunda transición, hay %s', v_count));
    END IF;
    IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
      RAISE NOTICE 'PASS (2.7d): un comprobante YA voided no bloquea ni se vuelve a anular (sin segunda fila de historial)';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_failures := array_append(v_failures, format('FAIL (2.7d voided): un comprobante voided NO debería bloquear la edición, levantó %s', SQLERRM));
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.10 — venta-editable-sin-cae (D2): pending_cae MARCADO
  -- (cae_submit_started_at) bloquea con P0423, token
  -- fiscal_document_sent_immutable, y deja venta, stock y comprobante
  -- intactos. Es el corazón del change: la marca previa al envío
  -- (fiscal-riesgos-residuales R1) se persiste ANTES del FECAESolicitar, así
  -- que "marcado" es exactamente "el pedido salió hacia ARCA".
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-210-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 200, v_user_a, v_op, v_doc_marked)
  RETURNING id INTO v_so_id;

  SELECT quantity INTO v_stock_before FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  v_caught_sqlstate := NULL;
  v_msg := NULL;
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 9))
    );
    v_failures := array_append(v_failures, 'FAIL (2.10): editar una venta cuyo comprobante YA se envió a ARCA debería fallar, no falló');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
  END;
  SELECT quantity INTO v_stock_after FROM public.branch_stock WHERE product_id = v_p1 AND branch_id = v_branch_a;
  SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_marked;

  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.10 SQLSTATE): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF position('fiscal_document_sent_immutable' in COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.10 token): esperaba fiscal_document_sent_immutable, obtuvo: %s', COALESCE(v_msg, '<sin mensaje>')));
  ELSIF v_status_text IS DISTINCT FROM 'pending_cae' THEN
    v_failures := array_append(v_failures, format('FAIL (2.10 comprobante intacto): un comprobante MARCADO jamás debe anularse, quedó %s', COALESCE(v_status_text, '<inexistente>')));
  ELSIF NOT EXISTS (SELECT 1 FROM public.sales WHERE id = v_sale_id AND quantity = 2) THEN
    v_failures := array_append(v_failures, 'FAIL (2.10 fila intacta): la venta bloqueada no debería haber cambiado');
  ELSIF v_stock_after IS DISTINCT FROM v_stock_before THEN
    v_failures := array_append(v_failures, format('FAIL (2.10 stock intacto): branch_stock no debería cambiar (%s), quedó %s', v_stock_before, v_stock_after));
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc_marked;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.10 historial): un comprobante marcado no debe generar ninguna transición, hay %s', v_count));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2.10): pending_cae MARCADO bloquea con P0423/fiscal_document_sent_immutable — venta, stock y comprobante intactos';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.11 — triangulación de 2.10: pending_cae CONGELADO
  -- (cae_submit_unconfirmed_at, SIN cae_submit_started_at) bloquea igual.
  -- El congelado es un caso de marca: el envío salió y su resultado nunca se
  -- confirmó, así que ARCA pudo haberlo aprobado.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-211-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 200, v_user_a, v_op, v_doc_frozen);

  v_caught_sqlstate := NULL;
  v_msg := NULL;
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 9))
    );
    v_failures := array_append(v_failures, 'FAIL (2.11): editar una venta con comprobante CONGELADO debería fallar, no falló');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
  END;
  SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_frozen;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.11 SQLSTATE): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF position('fiscal_document_sent_immutable' in COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.11 token): esperaba fiscal_document_sent_immutable, obtuvo: %s', COALESCE(v_msg, '<sin mensaje>')));
  ELSIF v_status_text IS DISTINCT FROM 'pending_cae' THEN
    v_failures := array_append(v_failures, format('FAIL (2.11 comprobante intacto): un congelado jamás debe anularse, quedó %s', COALESCE(v_status_text, '<inexistente>')));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2.11): pending_cae CONGELADO bloquea con P0423/fiscal_document_sent_immutable — el comprobante no se anula';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.12 — venta-editable-sin-cae (D3): el LEASE de claim_pending y el
  -- BACKOFF de update_retry comparten la columna next_attempt_at, así que
  -- NO puede entrar en el predicado: si entrara, una venta quedaría
  -- inmutable hasta 60 minutos por un comprobante que nunca llegó a ARCA.
  -- Este bloque es el candado contra ese "endurecimiento" que parece
  -- prudente y es exactamente lo contrario de lo que pidió el PO.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-212-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 200, v_user_a, v_op, v_doc_lease);

  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    v_result := public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 6))
    );
    SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_lease;
    IF v_status_text IS DISTINCT FROM 'voided' THEN
      v_failures := array_append(v_failures, format('FAIL (2.12 anulación): un pendiente con lease/backoff pero SIN marca debe anularse, quedó %s', COALESCE(v_status_text, '<inexistente>')));
    END IF;
    IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
      RAISE NOTICE 'PASS (2.12): next_attempt_at (lease de claim_pending + backoff de update_retry) NO bloquea — la venta se edita y el comprobante se anula';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_failures := array_append(v_failures, format('FAIL (2.12 lease): un comprobante con next_attempt_at futuro y SIN marca NO debe bloquear, levantó %s (%s)', v_caught_sqlstate, SQLERRM));
  END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.13 — la máquina de estados del comprobante no admite nada más.
  -- El catálogo document_status_transitions ES el guard: no hay que escribir
  -- ninguna condición para prohibir authorized→voided ni voided→*, alcanza
  -- con que esas triples NO estén catalogadas y con que el trigger
  -- fiscal_documents_enforce_status_transition siga vivo (P0409).
  -- ═══════════════════════════════════════════════════════════════════════
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);

  v_caught_sqlstate := NULL;
  BEGIN
    UPDATE public.fiscal_documents SET status = 'voided' WHERE id = v_doc_authorized;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0409' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 authorized→voided): esperaba P0409 (fsm_violation), obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  v_caught_sqlstate := NULL;
  BEGIN
    UPDATE public.fiscal_documents SET status = 'voided' WHERE id = v_doc_rejected;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0409' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 rejected→voided): esperaba P0409 (fsm_violation), obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  -- voided es TERMINAL: no vuelve a pending_cae ni salta a authorized.
  v_caught_sqlstate := NULL;
  BEGIN
    UPDATE public.fiscal_documents SET status = 'pending_cae' WHERE id = v_doc_pending;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0409' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 voided→pending_cae): esperaba P0409 (fsm_violation), obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  v_caught_sqlstate := NULL;
  BEGIN
    UPDATE public.fiscal_documents SET status = 'authorized' WHERE id = v_doc_pending;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0409' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 voided→authorized): esperaba P0409 (fsm_violation), obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  -- Un voided NO puede NACER: todo comprobante nace pending_cae (P0436).
  v_caught_sqlstate := NULL;
  BEGIN
    INSERT INTO public.fiscal_documents (id, account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number, total, status, attempts)
    VALUES (gen_random_uuid(), v_account_a, v_fp_id, v_pv_id, 'factura_c', 1, 900, 1000, 'voided', 0);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0436' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 INSERT voided): esperaba P0436, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  -- D6: requires_reason=true en la fila del catálogo — una anulación sin
  -- motivo no se registra (P0400 reason_required). Sin esto, la anulación
  -- quedaría en el historial sin decir por qué.
  v_caught_sqlstate := NULL;
  BEGIN
    PERFORM public.record_status_transition(
      v_account_a, 'fiscal_document', v_doc_lease, 'pending_cae', 'voided', v_user_a, NULL
    );
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
  END;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0400' THEN
    v_failures := array_append(v_failures, format('FAIL (2.13 reason_required): la transición a voided exige motivo (requires_reason=true), esperaba P0400 y obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  END IF;

  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2.13): la FSM sólo admite pending_cae→voided (P0409 en las otras cuatro), un voided no puede nacer (P0436) y la anulación exige motivo (P0400)';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2.14 — venta-editable-sin-cae (R9/T6): el guard fiscal corre ANTES
  -- que el de cuenta corriente, así que anula y RECIÉN DESPUÉS el guard de
  -- pago aborta. La transacción hace rollback completo → la anulación se
  -- deshace con todo lo demás. Se asserta en vez de suponerlo.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'epc-sale-214-' || gen_random_uuid()::text, v_client_a, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch_a, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale_id FROM public.sales WHERE operation_id = v_op AND product_id = v_p1;
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by, sale_operation_id, fiscal_document_id)
  VALUES (v_account_a, v_branch_a, 'confirmed', 200, v_user_a, v_op, v_doc_void_del);

  -- Cargo de cuenta corriente posteado sobre la MISMA operación (D12: los
  -- guards hermanos quedan intactos).
  PERFORM public.c30_register_customer_account_movement(
    public.c30_get_or_create_customer_account(v_account_a, v_client_a), 200, 'sale', v_op
  );

  v_caught_sqlstate := NULL;
  v_msg := NULL;
  v_fail_before := COALESCE(array_length(v_failures, 1), 0);
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale_id], v_client_a, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_p1, 'amount', 100.00, 'quantity', 8))
    );
    v_failures := array_append(v_failures, 'FAIL (2.14): una venta con cargo de cuenta corriente posteado sigue siendo inmutable (D12), no falló');
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_caught_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
  END;
  SELECT status INTO v_status_text FROM public.fiscal_documents WHERE id = v_doc_void_del;
  IF v_caught_sqlstate IS DISTINCT FROM 'P0423' THEN
    v_failures := array_append(v_failures, format('FAIL (2.14 SQLSTATE): esperaba P0423, obtuvo %s', COALESCE(v_caught_sqlstate, 'ningún error')));
  ELSIF position('operation_has_account_charge_immutable' in COALESCE(v_msg, '')) = 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.14 token): esperaba operation_has_account_charge_immutable, obtuvo: %s', COALESCE(v_msg, '<sin mensaje>')));
  ELSIF v_status_text IS DISTINCT FROM 'pending_cae' THEN
    v_failures := array_append(v_failures, format('FAIL (2.14 rollback): el guard de pago abortó DESPUÉS de anular — el rollback de la transacción debe dejar el comprobante en pending_cae, quedó %s', COALESCE(v_status_text, '<inexistente>')));
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM   public.document_status_history
  WHERE  document_type = 'fiscal_document' AND document_id = v_doc_void_del;
  IF v_count <> 0 THEN
    v_failures := array_append(v_failures, format('FAIL (2.14 historial): el rollback debe llevarse también la fila de historial de la anulación, hay %s', v_count));
  END IF;
  IF COALESCE(array_length(v_failures, 1), 0) = v_fail_before THEN
    RAISE NOTICE 'PASS (2.14): con cargo de cuenta corriente posteado la edición sigue bloqueada (D12) y el rollback deshace la anulación — comprobante e historial intactos';
  END IF;

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

  -- venta-editable-sin-cae: este mensaje afirmaba la regla VIEJA de F2 ("P0423
  -- sobre pending_cae/authorized"), que dejó de ser cierta. Una spec o un
  -- mensaje que afirma algo falso es un bug, no cosmética.
  RAISE NOTICE 'GATE EDICION_PRESERVA_CONTEXTO PASSED: F1 (contexto preservado y tri-estado branch/canal, ledger en sucursal efectiva, sales_orders re-apuntada), F2 REDEFINIDO por venta-editable-sin-cae (P0423 sólo cuando el comprobante YA SALIÓ hacia ARCA: authorized, marcado o congelado; un pending_cae sin marca se ANULA y la venta se edita; rejected, voided y sin comprobante no bloquean; la FSM sólo admite pending_cae→voided) y F3 (quantity decimal exacto) verificados.';

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
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
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
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches        WHERE account_id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
      -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
      DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
