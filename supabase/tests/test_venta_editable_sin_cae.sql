-- =============================================================================
-- GATE: test_venta_editable_sin_cae.sql
-- CHANGE: venta-editable-sin-cae (20261060000001) — governance CRÍTICO
--
-- Pedido del PO: "necesito que las ventas se puedan modificar, sólo si ésta no
-- tiene el CAE, es decir no se envió al ARCA aún".
--
-- Este archivo es dueño de lo que NO vive en los dos gates de comportamiento
-- que el change ya extiende (test_edicion_preserva_contexto.sql para la
-- edición, test_delete_guard_ledgers.sql para el borrado):
--
--   (1) Introspección estructural: el CHECK de 4 estados, la fila del catálogo
--       FSM, las ACLs del helper, una sola definición viva de las 3 RPCs
--       reescritas y el guard nuevo en sus cuerpos.
--   (2) RE-EMISIÓN (D5): después de anular por edición, la orden se puede
--       volver a facturar — comprobante NUEVO, número NUEVO (el anulado deja
--       un hueco en document_sequences, D9), orden re-apuntada.
--   (3) Triangulación de la allow-list de re-emisión: 'rejected' también
--       habilita (cierra un bug preexistente), 'pending_cae' sin marca y
--       'authorized' siguen dando already_invoiced (P0409).
--   (4) La carrera edición-vs-relay, caso (d): el relay RECLAMA (lease
--       commiteado, sin marca), la edición anula, y el relay YA NO PUEDE
--       enviar — mark_submit_started levanta P0437 y claim_pending devuelve
--       0 filas. Es el candado que impide facturar importes viejos.
--       El caso (c) —el relay tiene la fila TOMADA y la edición pide
--       FOR UPDATE NOWAIT— necesita dos conexiones reales y vive en
--       supabase/tests/test_venta_editable_sin_cae_race.sh, su propio paso de
--       CI. El caso (b) —marca ya commiteada— lo cubre el gate 2.10 de
--       test_edicion_preserva_contexto.sql.
--   (5) Limpieza verificada de sus propios fixtures.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

-- ── (1) Introspección estructural ───────────────────────────────────────────
DO $$
DECLARE
  v_failures text[] := '{}';
  v_def      text;
  v_count    int;
BEGIN
  -- CHECK de status: los 4 valores, ni uno más ni uno menos.
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM   pg_constraint
  WHERE  conrelid = 'public.fiscal_documents'::regclass
    AND  conname  = 'fiscal_documents_status_check';

  IF v_def IS NULL THEN
    v_failures := v_failures || format('(1) fiscal_documents_status_check NO EXISTE');
  ELSE
    IF position('voided' in v_def) = 0 THEN
      v_failures := v_failures || format('(1) el CHECK no admite ''voided'': la anulación sería imposible');
    END IF;
    IF position('pending_cae' in v_def) = 0
       OR position('authorized' in v_def) = 0
       OR position('rejected'   in v_def) = 0 THEN
      v_failures := v_failures || format('(1) el CHECK perdió alguno de los 3 estados previos');
    END IF;
  END IF;

  -- Catálogo FSM: exactamente 4 filas de fiscal_document, y la nueva con
  -- requires_reason (D6) y allowed_role NULL (D7).
  SELECT count(*) INTO v_count
  FROM   public.document_status_transitions WHERE document_type = 'fiscal_document';
  IF v_count <> 4 THEN
    v_failures := v_failures || format('(1) document_status_transitions: esperaba 4 filas de fiscal_document, hay %s', v_count);
  END IF;

  SELECT count(*) INTO v_count
  FROM   public.document_status_transitions
  WHERE  document_type = 'fiscal_document' AND from_status = 'pending_cae' AND to_status = 'voided'
    AND  is_terminal_to AND requires_reason AND allowed_role IS NULL;
  IF v_count <> 1 THEN
    v_failures := v_failures || format('(1) falta la fila pending_cae→voided terminal/con-motivo/sin-rol (hay %s)', v_count);
  END IF;

  -- voided es TERMINAL y sólo se alcanza desde pending_cae: el catálogo ES el
  -- guard de authorized→voided, rejected→voided y voided→*.
  SELECT count(*) INTO v_count
  FROM   public.document_status_transitions
  WHERE  document_type = 'fiscal_document'
    AND  (to_status = 'voided' OR from_status = 'voided')
    AND  NOT (from_status = 'pending_cae' AND to_status = 'voided');
  IF v_count <> 0 THEN
    v_failures := v_failures || format('(1) hay %s transición(es) extra hacia/desde voided — voided es terminal', v_count);
  END IF;

  -- Helper: existe, SECURITY DEFINER, y CERRADO a anon/authenticated.
  IF to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)') IS NULL THEN
    v_failures := v_failures || format('(1) _fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text) NO EXISTE (¿cambió de firma? el chequeo (3) del gate de ACLs es drift-tolerante y una firma vieja lo apaga EN SILENCIO)');
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc
            WHERE oid = to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)')) THEN
      v_failures := v_failures || format('(1) el helper de anulación no es SECURITY DEFINER');
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      IF has_function_privilege('anon', to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)'), 'EXECUTE')
         OR has_function_privilege('authenticated', to_regprocedure('public._fiscal_void_pending_for_sale_edit(uuid, uuid, uuid, text)'), 'EXECUTE') THEN
        v_failures := v_failures || format('(1) el helper de anulación es ejecutable por anon/authenticated: sería la primitiva para anular por PostgREST el comprobante pendiente de cualquier cuenta');
      END IF;
    END IF;
  END IF;

  -- Las 3 RPCs: una sola definición viva (sin overload fantasma, gotcha 42725).
  FOR v_def IN SELECT unnest(ARRAY['rpc_atomic_update_sale_operation',
                                   'rpc_delete_sale_operation',
                                   'rpc_emit_sale_invoice'])
  LOOP
    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_def;
    IF v_count <> 1 THEN
      v_failures := v_failures || format('(1) %s: %s definiciones vivas (esperaba 1)', v_def, v_count);
    END IF;
  END LOOP;

  -- El guard nuevo está en los cuerpos vivos, y el viejo NO.
  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)');
  IF v_def IS NULL OR position('_fiscal_void_pending_for_sale_edit' in v_def) = 0 THEN
    v_failures := v_failures || format('(1) rpc_atomic_update_sale_operation no llama al helper de anulación');
  END IF;
  IF v_def IS NOT NULL AND position('comprobante fiscal emitido y no puede editarse' in v_def) > 0 THEN
    v_failures := v_failures || format('(1) rpc_atomic_update_sale_operation conserva el RAISE del guard VIEJO');
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_delete_sale_operation(uuid, uuid, text)');
  IF v_def IS NULL OR position('_fiscal_void_pending_for_sale_edit' in v_def) = 0 THEN
    v_failures := v_failures || format('(1) rpc_delete_sale_operation no llama al helper de anulación');
  END IF;
  IF v_def IS NOT NULL AND position('comprobante fiscal emitido y no puede borrarse' in v_def) > 0 THEN
    v_failures := v_failures || format('(1) rpc_delete_sale_operation conserva el RAISE del guard VIEJO');
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.rpc_emit_sale_invoice(uuid, uuid)');
  IF v_def IS NULL OR position('NOT IN (''rejected'', ''voided'')' in v_def) = 0 THEN
    v_failures := v_failures || format('(1) rpc_emit_sale_invoice sin la ALLOW-LIST de re-emisión: o no se puede re-facturar, o —peor— el guard pasó a deny-list y un status futuro desconocido habilitaría una SEGUNDA factura real');
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE VENTA-EDITABLE-SIN-CAE (1) FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (1): CHECK de 4 estados, catálogo con voided terminal/con-motivo/sin-rol y sin transiciones extra, helper cerrado a anon/authenticated, 3 RPCs con una sola definición viva y el guard nuevo (y sin el viejo).';
END $$;


-- ── (2)-(5) Comportamiento sobre datos ──────────────────────────────────────
DO $$
DECLARE
  v_failures  text[] := '{}';

  v_email     text := 'venta-editable-sin-cae@test.local';
  v_user      uuid := gen_random_uuid();
  v_account   uuid;
  v_branch    uuid;
  v_client    uuid;
  v_product   uuid;
  v_fp        uuid;
  v_pv        uuid;
  v_claims    text;

  v_result    jsonb;
  v_emit      jsonb;
  v_op        uuid;
  v_sale      uuid;
  v_so        uuid;
  v_doc1      uuid;
  v_doc2      uuid;
  v_num1      bigint;
  v_num2      bigint;
  v_status    text;
  v_count     int;
  v_sqlstate  text;
  v_msg       text;
  v_claimed   int;
BEGIN
  -- ═══ Setup ═══
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
          jsonb_build_object('name', 'Gate Venta Editable Sin CAE', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account
  FROM   public.account_members WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    -- ABORTA, no degrada (red team 2026-09-22, m4). Degradar acá saltea los
    -- bloques (2) a (5) ENTEROS y deja el gate en verde sin haber probado nada:
    -- es el mismo modo de fallo que este change encontró y arregló en
    -- test_delete_guard_ledgers.sql, donde el único test del guard fiscal del
    -- borrado no se había ejecutado NUNCA. El .sh hermano ya hace esto bien.
    RAISE EXCEPTION 'GATE VENTA-EDITABLE-SIN-CAE: SETUP FAILED — handle_new_user no creó la cuenta del anchor sintético; sin cuenta los bloques de comportamiento no prueban nada.';
  END IF;

  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_account ORDER BY created_at LIMIT 1;

  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user, v_account, '__gate_vesc_client__') RETURNING id INTO v_client;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user, v_account, '__gate_vesc_product__', 'VESC-1', 300, 500)
  RETURNING id INTO v_product;
  PERFORM public.c21_apply_branch_stock_delta(v_account, v_product, v_branch, 500);

  -- Emisor MONOTRIBUTISTA: rpc_emit_sale_invoice bloquea a los RI (P0401,
  -- factura A/B fuera de alcance del MVP). CUIT y número de punto de venta
  -- propios: fn_guard_pos_cuit_cross_account (P0435) rechaza el mismo CUIT con
  -- el mismo PV activo en otra cuenta, y los demás gates fiscales ya usan
  -- 201111111xx / 205555555xx / 20666666663 / 20777777775 / 27888888884.
  INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
  VALUES (v_account, '20999999995', 'monotributista', 'homologacion', true)
  RETURNING id INTO v_fp;

  INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active)
  VALUES (v_fp, v_account, 9601, true) RETURNING id INTO v_pv;

  v_claims := json_build_object('sub', v_user::text, 'role', 'authenticated')::text;
  PERFORM set_config('request.jwt.claims', v_claims, true);
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);

  -- ═══════════════════════════════════════════════════════════════════════
  -- (2) RE-EMISIÓN: anular por edición y volver a facturar
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'vesc-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL)),
    v_branch, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op AND product_id = v_product;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, v_client, 'confirmed', 1000, v_user, v_op)
  RETURNING id INTO v_so;

  -- Primera emisión: nace pending_cae, sin marca, sin haber salido a ARCA.
  v_emit := public.rpc_emit_sale_invoice(v_so, v_pv);
  v_doc1 := (v_emit->>'fiscal_document_id')::uuid;
  SELECT number INTO v_num1 FROM public.fiscal_documents WHERE id = v_doc1;

  IF v_doc1 IS NULL THEN
    v_failures := v_failures || format('(2) la primera emisión no devolvió fiscal_document_id');
  END IF;

  -- Editar la venta ANTES de que el relay la tome → anula el comprobante.
  v_result := public.rpc_atomic_update_sale_operation(
    ARRAY[v_sale], v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 5))
  );
  v_op := (v_result->>'operation_id')::uuid;

  -- El descriptor viaja en la respuesta (lo consume el toast del frontend).
  IF v_result->'voided_fiscal_document'->>'fiscal_document_id' IS DISTINCT FROM v_doc1::text THEN
    v_failures := v_failures || format('(2) la RPC debía devolver voided_fiscal_document con el id anulado, devolvió %s', COALESCE(v_result->'voided_fiscal_document'::text, '<null>'));
  END IF;
  IF v_result->'voided_fiscal_document'->>'label' IS DISTINCT FROM
     (lpad('9601', 4, '0') || '-' || lpad(v_num1::text, 8, '0')) THEN
    v_failures := v_failures || format('(2) label del comprobante anulado inesperado: %s', COALESCE(v_result->'voided_fiscal_document'->>'label', '<null>'));
  END IF;

  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc1;
  IF v_status IS DISTINCT FROM 'voided' THEN
    v_failures := v_failures || format('(2) el comprobante debía quedar voided, quedó %s', COALESCE(v_status, '<inexistente>'));
  END IF;

  -- Re-facturar la MISMA orden: comprobante nuevo, número NUEVO (el del
  -- anulado no se reutiliza — D9, el hueco local es deliberado).
  v_emit := public.rpc_emit_sale_invoice(v_so, v_pv);
  v_doc2 := (v_emit->>'fiscal_document_id')::uuid;
  SELECT number INTO v_num2 FROM public.fiscal_documents WHERE id = v_doc2;

  IF v_doc2 IS NULL OR v_doc2 = v_doc1 THEN
    v_failures := v_failures || format('(2) la re-emisión debía crear un comprobante NUEVO (doc1=%s doc2=%s)', v_doc1, v_doc2);
  END IF;
  IF v_num2 IS NULL OR v_num1 IS NULL OR v_num2 <= v_num1 THEN
    v_failures := v_failures || format('(2) el número no se reutiliza: esperaba num2 > num1 (num1=%s num2=%s)', v_num1, v_num2);
  END IF;
  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_status IS DISTINCT FROM 'pending_cae' THEN
    v_failures := v_failures || format('(2) el comprobante nuevo debía nacer pending_cae, nació %s', COALESCE(v_status, '<inexistente>'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_orders WHERE id = v_so AND fiscal_document_id = v_doc2) THEN
    v_failures := v_failures || format('(2) la orden debía re-apuntar al comprobante nuevo');
  END IF;
  -- El anulado sigue existiendo con su número: el hueco es explicable.
  IF NOT EXISTS (SELECT 1 FROM public.fiscal_documents WHERE id = v_doc1 AND number = v_num1 AND status = 'voided') THEN
    v_failures := v_failures || format('(2) el comprobante anulado debe conservarse con su punto de venta y su número (rastro auditable)');
  END IF;

  IF array_length(v_failures, 1) IS NULL THEN
    RAISE NOTICE 'PASS (2): anular por edición y volver a facturar produce un comprobante NUEVO con número NUEVO; el anulado queda como rastro con su número (hueco deliberado, D9).';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (3) Triangulación de la allow-list de re-emisión
  -- ═══════════════════════════════════════════════════════════════════════
  -- (3a) pending_cae SIN marca → sigue dando already_invoiced: no se puede
  -- emitir dos veces sin anular primero (v_doc2 está pending_cae ahora).
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_emit_sale_invoice(v_so, v_pv);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0409' THEN
    v_failures := v_failures || format('(3a) emitir dos veces sobre un pending_cae vivo debe dar P0409, dio %s', COALESCE(v_sqlstate, 'ningún error'));
  ELSIF position('already_invoiced' in COALESCE(v_msg, '')) = 0 THEN
    v_failures := v_failures || format('(3a) esperaba el token already_invoiced, obtuvo: %s', COALESCE(v_msg, '<sin mensaje>'));
  END IF;

  -- (3b) 'rejected' TAMBIÉN habilita la re-emisión — cierra un bug
  -- preexistente: hasta este change una orden cuyo único comprobante quedó
  -- rejected no se podía volver a facturar NUNCA.
  PERFORM public.rpc_fiscal_document_reject(v_doc2, 'rechazo sintético del gate');
  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_status IS DISTINCT FROM 'rejected' THEN
    v_failures := v_failures || format('(3b) el fixture no quedó rejected (quedó %s) — el resto del bloque no probaría nada', COALESCE(v_status, '<inexistente>'));
  ELSE
    v_sqlstate := NULL;
    BEGIN
      v_emit := public.rpc_emit_sale_invoice(v_so, v_pv);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_msg := SQLERRM;
    END;
    IF v_sqlstate IS NOT NULL THEN
      v_failures := v_failures || format('(3b) una orden con comprobante rejected debe poder re-facturarse, levantó %s (%s)', v_sqlstate, COALESCE(v_msg, ''));
    ELSE
      v_doc2 := (v_emit->>'fiscal_document_id')::uuid;
    END IF;
  END IF;

  -- (3c) 'authorized' NUNCA habilita la re-emisión.
  UPDATE public.fiscal_documents
  SET    status = 'authorized', cae = '70000000000001', cae_due_date = CURRENT_DATE + 10
  WHERE  id = v_doc2;
  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc2;
  IF v_status IS DISTINCT FROM 'authorized' THEN
    v_failures := v_failures || format('(3c) el fixture no quedó authorized (quedó %s)', COALESCE(v_status, '<inexistente>'));
  ELSE
    v_sqlstate := NULL;
    BEGIN
      PERFORM public.rpc_emit_sale_invoice(v_so, v_pv);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    END;
    IF v_sqlstate IS DISTINCT FROM 'P0409' THEN
      v_failures := v_failures || format('(3c) una orden ya AUTORIZADA jamás debe re-facturarse: esperaba P0409, obtuvo %s', COALESCE(v_sqlstate, 'ningún error'));
    END IF;
  END IF;

  IF array_length(v_failures, 1) IS NULL THEN
    RAISE NOTICE 'PASS (3): la allow-list de re-emisión sólo habilita rejected y voided — pending_cae vivo y authorized siguen dando already_invoiced (P0409).';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (4) Carrera edición-vs-relay, caso (d): el relay RECLAMA y la edición
  -- ANULA en el medio. El relay ya no puede enviar nada.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'vesc-race-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;
  SELECT id INTO v_sale FROM public.sales WHERE operation_id = v_op AND product_id = v_product;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, v_client, 'confirmed', 500, v_user, v_op)
  RETURNING id INTO v_so;

  v_emit := public.rpc_emit_sale_invoice(v_so, v_pv);
  v_doc1 := (v_emit->>'fiscal_document_id')::uuid;

  -- El relay RECLAMA: pone el lease (next_attempt_at = now()+5min) y commitea.
  -- Todavía NO marcó, así que el pedido NO salió hacia ARCA.
  SELECT count(*) INTO v_claimed FROM public.rpc_fiscal_document_claim_pending(v_doc1, 10);
  IF v_claimed <> 1 THEN
    v_failures := v_failures || format('(4) el fixture no se pudo reclamar (claim_pending devolvió %s filas) — el resto del bloque no probaría nada', v_claimed);
  END IF;

  -- La edición entra en el medio y ANULA (D3: el lease NO bloquea).
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_atomic_update_sale_operation(
      ARRAY[v_sale], v_client, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 3))
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  IF v_sqlstate IS NOT NULL THEN
    v_failures := v_failures || format('(4) un comprobante RECLAMADO pero sin marca debe poder anularse, levantó %s (%s)', v_sqlstate, COALESCE(v_msg, ''));
  END IF;

  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc1;
  IF v_status IS DISTINCT FROM 'voided' THEN
    v_failures := v_failures || format('(4) el comprobante reclamado-sin-marca debía quedar voided, quedó %s', COALESCE(v_status, '<inexistente>'));
  END IF;

  -- Ahora el relay intenta seguir: los DOS puntos de paso lo frenan.
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_fiscal_document_mark_submit_started(v_doc1, 777001);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0437' THEN
    v_failures := v_failures || format('(4) mark_submit_started sobre un comprobante ANULADO debe levantar P0437 (nunca enviar): obtuvo %s', COALESCE(v_sqlstate, 'ningún error — SE HABRÍA ENVIADO A ARCA'));
  END IF;
  -- Y no quedó marcado ni con número pedido.
  IF EXISTS (SELECT 1 FROM public.fiscal_documents
             WHERE id = v_doc1 AND (cae_submit_started_at IS NOT NULL OR arca_requested_number IS NOT NULL)) THEN
    v_failures := v_failures || format('(4) un comprobante anulado no debe quedar marcado ni con arca_requested_number');
  END IF;

  SELECT count(*) INTO v_claimed FROM public.rpc_fiscal_document_claim_pending(v_doc1, 10);
  IF v_claimed <> 0 THEN
    v_failures := v_failures || format('(4) claim_pending sobre un comprobante ANULADO debe devolver 0 filas, devolvió %s', v_claimed);
  END IF;

  IF array_length(v_failures, 1) IS NULL THEN
    RAISE NOTICE 'PASS (4): con el lease del relay ya puesto, la edición anula igual; después el relay NO puede enviar — mark_submit_started da P0437 y claim_pending devuelve 0 filas.';
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- (5) Guard de TENENCIA del helper (red team 2026-09-22, m1). El helper es
  -- un SECURITY DEFINER que recibe el tenant por PARÁMETRO: sin comparar la
  -- cuenta de la orden contra ese parámetro, quien pudiera llamarlo anularía el
  -- comprobante pendiente de cualquier cuenta (y escribiría el historial bajo
  -- la cuenta equivocada). Es el anti-patrón que la casa ya cerró en
  -- cuenta-corriente-party-guard: el guard va en el CHOKE POINT, no en los
  -- callers. Se prueba llamando al helper directamente, que es justamente el
  -- camino que los guards de los callers NO cubren.
  -- ═══════════════════════════════════════════════════════════════════════
  v_result := public.rpc_create_sale_operation(
    'vesc-tenancy-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_product, 'amount', 500.00, 'quantity', 1, 'unit_id', NULL)),
    v_branch, NULL, NULL
  );
  v_op := (v_result->>'operation_id')::uuid;

  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by, sale_operation_id)
  VALUES (v_account, v_branch, v_client, 'confirmed', 500, v_user, v_op)
  RETURNING id INTO v_so;

  v_doc1 := (public.rpc_emit_sale_invoice(v_so, v_pv)->>'fiscal_document_id')::uuid;
  SELECT count(*) INTO v_count FROM public.document_status_history WHERE document_id = v_doc1;

  -- (5a) Cuenta AJENA → P0404 y nada escrito.
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._fiscal_void_pending_for_sale_edit(
      v_so, gen_random_uuid(), v_user, 'intento con una cuenta ajena');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  IF v_sqlstate IS DISTINCT FROM 'P0404' THEN
    v_failures := v_failures || format('(5a) el helper con una cuenta ajena debe levantar P0404, obtuvo %s (%s) — anularía el comprobante pendiente de cualquier cuenta', COALESCE(v_sqlstate, 'ningún error'), COALESCE(v_msg, ''));
  END IF;
  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc1;
  IF v_status IS DISTINCT FROM 'pending_cae' THEN
    v_failures := v_failures || format('(5a) el comprobante de la cuenta legítima quedó %s: el helper escribió con una cuenta ajena', COALESCE(v_status, '<inexistente>'));
  END IF;
  IF (SELECT count(*) FROM public.document_status_history WHERE document_id = v_doc1) <> v_count THEN
    v_failures := v_failures || format('(5a) el intento con cuenta ajena escribió en document_status_history');
  END IF;

  -- (5b) Control positivo: con la cuenta CORRECTA el mismo helper sí anula. Sin
  -- esto, (5a) podría estar pasando porque el helper no anula nunca.
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._fiscal_void_pending_for_sale_edit(
      v_so, v_account, v_user, 'control positivo del guard de tenencia');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
  END;
  IF v_sqlstate IS NOT NULL THEN
    v_failures := v_failures || format('(5b) con la cuenta correcta el helper debía anular, levantó %s (%s)', v_sqlstate, COALESCE(v_msg, ''));
  END IF;
  SELECT status INTO v_status FROM public.fiscal_documents WHERE id = v_doc1;
  IF v_status IS DISTINCT FROM 'voided' THEN
    v_failures := v_failures || format('(5b) con la cuenta correcta el comprobante debía quedar voided, quedó %s', COALESCE(v_status, '<inexistente>'));
  END IF;

  IF array_length(v_failures, 1) IS NULL THEN
    RAISE NOTICE 'PASS (5): el helper rechaza con P0404 la orden de otra cuenta sin escribir nada, y con la cuenta correcta anula (control positivo).';
  END IF;

  -- ═══ Resultado ═══
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE VENTA-EDITABLE-SIN-CAE FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  -- ═══ (5) Limpieza de los fixtures propios ═══
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  DELETE FROM public.sales_orders          WHERE account_id = v_account;
  DELETE FROM public.document_status_history WHERE account_id = v_account;
  DELETE FROM public.fiscal_documents      WHERE account_id = v_account;
  DELETE FROM public.points_of_sale        WHERE account_id = v_account;
  DELETE FROM public.fiscal_profiles       WHERE account_id = v_account;
  DELETE FROM public.sale_items            WHERE account_id = v_account;
  DELETE FROM public.stock_movements       WHERE account_id = v_account;
  DELETE FROM public.sales                 WHERE account_id = v_account;
  DELETE FROM public.events                WHERE account_id = v_account;
  DELETE FROM public.branch_stock          WHERE account_id = v_account;
  DELETE FROM public.products              WHERE account_id = v_account;
  DELETE FROM public.clients               WHERE account_id = v_account;
  DELETE FROM public.analytics_events      WHERE user_id = v_user;
  DELETE FROM public.cashboxes             WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account);
  -- sucursal-guard-vaciado-auditoria: branches prohíbe el borrado físico
  -- SIEMPRE (trg_guard_branch_decommission, P0428). Bypass explícito para el
  -- cleanup del fixture sintético — session_replication_role sólo lo puede
  -- fijar un rol con privilegio de superusuario (postgres en CI); no abre
  -- ningún camino para authenticated/anon vía PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches              WHERE account_id = v_account;
  DELETE FROM public.accounts              WHERE id = v_account;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members       WHERE user_id = v_user;
  DELETE FROM public.profiles              WHERE id = v_user;
  DELETE FROM public.email_logs            WHERE user_id = v_user;
  DELETE FROM public.operation_idempotency WHERE user_id = v_user;
  DELETE FROM auth.users                   WHERE id = v_user;

  -- La limpieza se VERIFICA: un gate que deja basura hace fallar al siguiente
  -- (precedente real de este repo — huérfanos de fixtures en test_admin_kpis).
  SELECT count(*) INTO v_count FROM public.fiscal_documents WHERE account_id = v_account;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE VENTA-EDITABLE-SIN-CAE: la limpieza dejó % fiscal_documents del fixture', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM auth.users WHERE id = v_user;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE VENTA-EDITABLE-SIN-CAE: la limpieza dejó el anchor sintético en auth.users';
  END IF;

  RAISE NOTICE 'GATE VENTA-EDITABLE-SIN-CAE PASSED: introspección, re-emisión con número nuevo, allow-list de re-emisión, carrera edición-vs-relay (caso d) y guard de tenencia del helper — fixtures limpios.';
END $$;
