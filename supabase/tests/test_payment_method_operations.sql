-- =============================================================================
-- GATE: test_payment_method_operations.sql
-- CHANGE: metodos-pago-operaciones (tasks 2.1, 2.2 regresión, 2.4)
--
-- Ejercita las 4 RPCs de operaciones YA MIGRADAS (rpc_create_sale_operation,
-- rpc_create_purchase_operation, rpc_atomic_update_sale_operation,
-- rpc_atomic_update_purchase_operation) invocándolas de verdad (sesión
-- sintética vía request.jwt.claims, mismo patrón que
-- supabase/tests/test_operation_edit_lines.sql y el gate de
-- cost-center-report). Cubre:
--   (1) alta de venta CON forma de pago → todas las filas de la operación;
--   (2) alta de venta SIN forma de pago → NULL ("Sin especificar");
--   (3) forma de pago de OTRA cuenta → rechazada, cero líneas persistidas;
--   (4) REGRESIÓN #415: sale_items sigue escribiéndose;
--   (5) REGRESIÓN idempotencia: mismo idempotency_key → misma operación;
--   (6) edición SIN informar método → preserva (COALESCE, D5), líneas
--       nuevas incluidas;
--   (7) edición informando otro método → reimputa todas las líneas;
--   (8) edición con el sentinel "sin especificar" (provided=true, id=NULL)
--       → desimputa (NULL) todas las líneas;
--   (9) REGRESIÓN #417: la edición sigue emitiendo el par REVERSE/APPLY en
--       stock_movements;
--   (10)-(13) mismos checks (1),(2),(3),(6) espejados para compra, más la
--       coexistencia payment_method_id + cost_center_id en la misma línea.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local (contexto no lo permite), el gate emite NOTICE y
-- no aborta — mismo criterio que el gate de cost-center-report.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email    text := 'payment-method-operations-gate@test.local';
  v_other_email     text := 'payment-method-operations-gate-other@test.local';
  v_user_id         uuid := gen_random_uuid();
  v_other_user_id   uuid := gen_random_uuid();
  v_account_id      uuid;
  v_other_account_id uuid;
  v_branch_id       uuid;
  v_product_id      uuid;
  v_pm_cash         uuid;  -- "Efectivo" de la cuenta ancla
  v_pm_transfer     uuid;  -- "Transferencia bancaria" de la cuenta ancla
  v_pm_other_acct   uuid;  -- "Efectivo" de LA OTRA cuenta (para el reject)
  v_cc_id           uuid;  -- centro de costo de la cuenta ancla (coexistencia)
  v_resolved        boolean := false;

  v_result          jsonb;
  v_op_id           uuid;
  v_op_id_2         uuid;
  v_rejected        boolean;
  v_row             record;
  v_pmid_check      uuid;
  v_count           integer;
  v_sale_ids        uuid[];
  v_purchase_ids    uuid[];
  v_result2         jsonb;
BEGIN
  -- ── Anchors sintéticos (dos cuentas) ──────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Operations'))
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_other_user_id, 'authenticated', 'authenticated', v_other_email, now(), now(),
          jsonb_build_object('name', 'Gate PM Operations Other'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_other_account_id FROM public.account_members WHERE user_id = v_other_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL OR v_other_account_id IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-OPERATIONS: no se pudo resolver cuenta para los anchors sintéticos (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash       FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_pm_transfer   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'transfer' LIMIT 1;
  SELECT id INTO v_pm_other_acct FROM public.payment_methods WHERE account_id = v_other_account_id AND kind = 'cash' LIMIT 1;

  IF v_branch_id IS NULL OR v_pm_cash IS NULL OR v_pm_transfer IS NULL OR v_pm_other_acct IS NULL THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-OPERATIONS: catálogo/branch no sembrado para los anchors — degradando sin abortar (¿corrió antes la migración de seed?).';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_pmo_product__', 1000, 400, 'GATE-PMO-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  INSERT INTO public.cost_centers (account_id, name, code)
  VALUES (v_account_id, '__gate_pmo_cc__', 'PMO')
  RETURNING id INTO v_cc_id;

  -- ── Sesión sintética (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ──
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-OPERATIONS: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
  ELSE
    v_resolved := true;

    -- ══════════════════════════════ VENTA ═══════════════════════════════════

    -- (1) Alta CON forma de pago — 2 líneas del mismo producto (misma
    --     operación) para poblar sale_items en ambas filas.
    SELECT public.rpc_create_sale_operation(
      'gate-pmo-sale-1', NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(
        jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1),
        jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 2)
      ),
      v_branch_id, NULL, v_pm_cash
    ) INTO v_result;

    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_id AND payment_method_id = v_pm_cash;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (1): esperaba 2 filas de sales con payment_method_id = Efectivo, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (1): alta de venta con forma de pago persiste en todas las filas de la operación.';

    -- (4) REGRESIÓN #415: sale_items sigue escribiéndose (2 líneas → 2 filas).
    SELECT COUNT(*) INTO v_count FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id WHERE s.operation_id = v_op_id;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (4, regresión #415): esperaba 2 filas en sale_items, hay % — el acarreo de líneas se rompió al agregar payment_method_id.', v_count;
    END IF;
    RAISE NOTICE 'PASS (4, regresión #415): sale_items sigue escribiéndose tras el cambio de firma.';

    -- REGRESIÓN stock_movements (#417 conceptual — la creación también debe seguir moviendo stock).
    SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE operation_group_id = v_op_id AND type = 'sale';
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (4b): esperaba 2 movimientos de stock type=sale, hay %.', v_count;
    END IF;

    -- (5) REGRESIÓN idempotencia: mismo idempotency_key → misma operación, sin duplicar.
    SELECT public.rpc_create_sale_operation(
      'gate-pmo-sale-1', NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      v_branch_id, NULL, v_pm_cash
    ) INTO v_result2;

    IF (v_result2->>'operation_id')::uuid IS DISTINCT FROM v_op_id OR (v_result2->>'replayed')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (5): la idempotencia debería devolver la misma operación con replayed=true.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_id;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (5b): la reemisión con el mismo idempotency_key no debería duplicar filas, hay %.', v_count;
    END IF;
    RAISE NOTICE 'PASS (5): idempotencia intacta — mismo idempotency_key devuelve la misma operación, sin duplicar.';

    -- (2) Alta SIN forma de pago → NULL.
    SELECT public.rpc_create_sale_operation(
      'gate-pmo-sale-2', NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 50, 'quantity', 1)),
      v_branch_id, NULL, NULL
    ) INTO v_result;
    v_op_id_2 := (v_result->>'operation_id')::uuid;

    SELECT payment_method_id INTO v_pmid_check FROM public.sales WHERE operation_id = v_op_id_2 LIMIT 1;
    IF v_pmid_check IS NOT NULL THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (2): alta sin forma de pago debería persistir NULL.';
    END IF;
    RAISE NOTICE 'PASS (2): alta de venta sin forma de pago persiste NULL ("Sin especificar").';

    -- (3) Forma de pago de OTRA cuenta → rechazada, cero líneas persistidas.
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_create_sale_operation(
        'gate-pmo-sale-reject', NULL, CURRENT_DATE, 'ARS',
        jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 10, 'quantity', 1)),
        v_branch_id, NULL, v_pm_other_acct
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE = 'P0404' THEN
          v_rejected := true;
        ELSE
          RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (3): una forma de pago de otra cuenta debería rechazarse con P0404.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.operation_idempotency WHERE user_id = v_user_id AND idempotency_key = 'gate-pmo-sale-reject';
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (3b): el rechazo debería abortar la transacción completa (cero filas persistidas), pero quedó idempotencia registrada.';
    END IF;
    RAISE NOTICE 'PASS (3): forma de pago de otra cuenta rechazada, cero líneas persistidas.';

    -- ══════════════════════════ EDICIÓN DE VENTA ═════════════════════════════

    SELECT array_agg(id) INTO v_sale_ids FROM public.sales WHERE operation_id = v_op_id;

    -- (6) Editar SIN informar método → preserva Efectivo en TODAS las líneas
    --     resultantes, incluida la nueva agregada en esta misma edición.
    SELECT public.rpc_atomic_update_sale_operation(
      v_sale_ids, NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(
        jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 3),
        jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)  -- línea nueva
      )
    ) INTO v_result;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_id AND payment_method_id = v_pm_cash;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (6): editar sin informar método debería preservar Efectivo en las 2 líneas (incluida la nueva), hay % con ese valor.', v_count;
    END IF;
    RAISE NOTICE 'PASS (6): la edición sin informar método PRESERVA el vigente (D5, COALESCE) — línea nueva incluida.';

    -- (7) Editar informando OTRO método → reimputa todas las líneas.
    SELECT array_agg(id) INTO v_sale_ids FROM public.sales WHERE operation_id = v_op_id;
    SELECT public.rpc_atomic_update_sale_operation(
      v_sale_ids, NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 2)),
      v_pm_transfer, true
    ) INTO v_result;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_id AND payment_method_id = v_pm_transfer;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (7): editar informando Transferencia debería reimputar la línea resultante.';
    END IF;
    RAISE NOTICE 'PASS (7): la edición informando otro método reimputa todas las líneas resultantes.';

    -- (9) REGRESIÓN #417: la edición emitió el par REVERSE (sale_return) + APPLY (sale).
    SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE type = 'sale_return' AND account_id = v_account_id;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (9, regresión #417): la edición debería haber emitido movimientos sale_return (reversa) — ninguno encontrado.';
    END IF;
    RAISE NOTICE 'PASS (9, regresión #417): la edición sigue emitiendo el par REVERSE/APPLY en stock_movements.';

    -- (8) Editar con el sentinel "sin especificar" → desimputa (NULL).
    SELECT array_agg(id) INTO v_sale_ids FROM public.sales WHERE operation_id = v_op_id;
    SELECT public.rpc_atomic_update_sale_operation(
      v_sale_ids, NULL, CURRENT_DATE, 'ARS',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 2)),
      NULL, true
    ) INTO v_result;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.sales WHERE operation_id = v_op_id AND payment_method_id IS NULL;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (8): el sentinel "sin especificar" (provided=true, id=NULL) debería desimputar la línea resultante.';
    END IF;
    RAISE NOTICE 'PASS (8): el sentinel "sin especificar" desimputa la operación (NULL explícito, no confundido con "ausente").';

    -- ══════════════════════════════ COMPRA ═══════════════════════════════════

    -- (10) Alta de compra CON forma de pago Y centro de costo (coexistencia).
    SELECT public.rpc_create_purchase_operation(
      'gate-pmo-purchase-1', CURRENT_DATE, 'Gate PMO compra',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 1)),
      v_branch_id, v_cc_id, v_pm_transfer
    ) INTO v_result;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.purchases WHERE operation_id = v_op_id AND payment_method_id = v_pm_transfer AND cost_center_id = v_cc_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (10): alta de compra con forma de pago Y centro de costo debería persistir ambos en la misma línea.';
    END IF;
    RAISE NOTICE 'PASS (10): alta de compra — payment_method_id y cost_center_id coexisten en la misma línea.';

    -- REGRESIÓN #415 (purchase_items) sobre la compra recién creada.
    SELECT COUNT(*) INTO v_count FROM public.purchase_items pi JOIN public.purchases p ON p.id = pi.purchase_id WHERE p.operation_id = v_op_id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (10b, regresión #415): esperaba 1 fila en purchase_items, hay %.', v_count;
    END IF;

    -- (11) Alta de compra SIN forma de pago → NULL.
    SELECT public.rpc_create_purchase_operation(
      'gate-pmo-purchase-2', CURRENT_DATE, 'Gate PMO compra sin metodo',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 20, 'quantity', 1)),
      v_branch_id, NULL, NULL
    ) INTO v_result;
    v_op_id_2 := (v_result->>'operation_id')::uuid;

    SELECT payment_method_id INTO v_pmid_check FROM public.purchases WHERE operation_id = v_op_id_2 LIMIT 1;
    IF v_pmid_check IS NOT NULL THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (11): alta de compra sin forma de pago debería persistir NULL.';
    END IF;
    RAISE NOTICE 'PASS (11): alta de compra sin forma de pago persiste NULL.';

    -- (12) Forma de pago de OTRA cuenta → rechazada en compra también.
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_create_purchase_operation(
        'gate-pmo-purchase-reject', CURRENT_DATE, 'Gate PMO reject',
        jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 5, 'quantity', 1)),
        v_branch_id, NULL, v_pm_other_acct
      );
    EXCEPTION
      WHEN OTHERS THEN
        -- Se matchea por texto (no por SQLSTATE exacto): branch_not_found/
        -- cost_center_not_found en esta misma función usan el ERRCODE
        -- legacy de 4 caracteres 'P404' (preexistente, bug de runtime
        -- descubierto en CI — "unrecognized exception condition" en vez del
        -- error intencional — no lo toca este change) mientras que el check
        -- NUEVO de payment_method_not_found usa 'P0404' (5 chars, válido).
        -- Matchear por texto hace el gate agnóstico a esa inconsistencia.
        IF SQLERRM LIKE '%payment_method_not_found%' THEN
          v_rejected := true;
        ELSE
          RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (12): una forma de pago de otra cuenta debería rechazarse en compra.';
    END IF;
    RAISE NOTICE 'PASS (12): forma de pago de otra cuenta rechazada en la creación de compra.';

    -- (13) Editar compra SIN informar método → preserva Transferencia.
    SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE operation_id = v_op_id;
    SELECT public.rpc_atomic_update_purchase_operation(
      v_purchase_ids, CURRENT_DATE, 'Gate PMO compra editada',
      jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 2))
    ) INTO v_result;
    v_op_id := (v_result->>'operation_id')::uuid;

    SELECT COUNT(*) INTO v_count FROM public.purchases WHERE operation_id = v_op_id AND payment_method_id = v_pm_transfer;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE PAYMENT-METHOD-OPERATIONS FAILED (13): editar compra sin informar método debería preservar Transferencia (D5).';
    END IF;
    RAISE NOTICE 'PASS (13): la edición de compra sin informar método preserva el vigente (D5).';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre (dos cuentas) ──────────────────────────────────────
  DELETE FROM public.sale_items     WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_id, v_other_account_id));
  DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT id FROM public.purchases WHERE account_id IN (v_account_id, v_other_account_id));
  DELETE FROM public.stock_movements WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.sales           WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.purchases       WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.branch_stock    WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.products        WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.cost_centers    WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.payment_methods WHERE account_id IN (v_account_id, v_other_account_id);
  DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_other_account_id));
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id IN (v_account_id, v_other_account_id);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.profiles        WHERE id IN (v_user_id, v_other_user_id);
  DELETE FROM public.email_logs      WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_other_user_id);
  DELETE FROM auth.users             WHERE id IN (v_user_id, v_other_user_id);

  IF v_resolved THEN
    RAISE NOTICE 'GATE PAYMENT-METHOD-OPERATIONS PASSED: alta/edición de venta y compra, regresión #415/#417, idempotencia y aislamiento entre cuentas — todo verde.';
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL OR v_other_account_id IS NOT NULL THEN
        DELETE FROM public.sale_items     WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id IN (v_account_id, v_other_account_id));
        DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT id FROM public.purchases WHERE account_id IN (v_account_id, v_other_account_id));
        DELETE FROM public.stock_movements WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.sales           WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.purchases       WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.branch_stock    WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.products        WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.cost_centers    WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.payment_methods WHERE account_id IN (v_account_id, v_other_account_id);
        DELETE FROM public.cashboxes       WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_other_account_id));
        -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
        SET session_replication_role = replica;
        DELETE FROM public.branches        WHERE account_id IN (v_account_id, v_other_account_id);
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_other_user_id);
        DELETE FROM public.accounts        WHERE owner_user_id IN (v_user_id, v_other_user_id);
      END IF;
      DELETE FROM public.profiles        WHERE id IN (v_user_id, v_other_user_id);
      DELETE FROM public.email_logs      WHERE user_id IN (v_user_id, v_other_user_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_other_user_id);
      DELETE FROM auth.users             WHERE id IN (v_user_id, v_other_user_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
