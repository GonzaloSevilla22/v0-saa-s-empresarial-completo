-- =============================================================================
-- GATE: test_compras_proveedor_cuenta_corriente.sql
-- CHANGE: compras-proveedor-cuenta-corriente (grupos 2, 3, 4 y 5 de tasks.md)
-- =============================================================================
--
-- Verifica, contra la DB resultante de TODAS las migraciones (incluida
-- 20261009000001_compras_proveedor_cuenta_corriente.sql):
--
--   (1) suppliers gana identidad fiscal (RN-96, espejo de clients): las cinco
--       columnas, el CHECK de dominio cerrado de iva_condition rechazando un
--       valor invalido con un INSERT REAL, y el indice de listado.
--   (2) rpc_create_purchase_operation persiste supplier_id en LAS DOS ramas
--       del INSERT (linea con producto y linea de servicio sin producto) — la
--       rama ELSE repite la lista de columnas y ya se olvido una vez.
--   (3) GATE ESTRELLA (D5): el cargo se dispara SOLO donde debe. Tres formas
--       en la misma cuenta — credit (carga), cash (no carga) y SIN forma de
--       pago (no carga, PERO el evento contable sigue diciendo 'credit').
--       El tercer caso es el que protege contra usar el COALESCE: si el
--       disparo usara COALESCE(v_kind,'credit'), el 100% de las compras
--       historicas sin forma de pago empezaria a endeudar proveedores en
--       silencio.
--   (4) Guards del alta: credit sin proveedor -> P0400 sin efectos, y el
--       reintento con la MISMA clave de idempotencia + proveedor tiene exito
--       REAL (el rechazo no quema el slot); proveedor de otra cuenta y
--       proveedor borrado -> P0404.
--   (5) rpc_atomic_update_purchase_operation: tri-estado de supplier_id en
--       sus TRES estados (ausente preserva / uuid reimputa / NULL desimputa),
--       proveedor ajeno rechazado, e INVARIANTE D7 — reimputar el proveedor
--       de una compra SIN cargo no crea, mueve ni revierte ningun
--       supplier_account_movement.
--   (6) [OQ-5] mismo tri-estado para cost_center_id — cierra la OQ-1 de
--       edicion-preserva-contexto, que dejo el CostCenterSelect montado en el
--       form de edicion sin ningun efecto (UI que mentia en produccion).
--   (7) COBERTURA DE LO YA CONSTRUIDO QUE NUNCA SE EJERCITO — tres piezas que
--       existen desde pagos-cableados-restantes / delete-guard-ledgers y hasta
--       hoy eran INALCANZABLES porque ningun camino posteaba un cargo de
--       proveedor. Este change las pone en el camino real y aca se cubren:
--         (7a) P0423: la compra con cargo posteado no se puede editar.
--         (7b) el borrado compensa el cargo (debit_note negativo), repone el
--              stock y emite PurchaseDeleted.
--         (7c) P0425: si el cargo ya fue cancelado por un PaymentMade, borrar
--              la compra se rechaza sin efectos parciales.
--         (7d) no-regresion contable: el asiento sigue acreditando 2100
--              Proveedores, sin tocar _journal_post_from_event.
--
-- Degrade-don't-fail: si el anchor sintetico no resuelve cuenta/catalogo
-- (mismo patron que el resto de los gates de este directorio), se emite NOTICE
-- y no aborta.
-- =============================================================================

DO $$
DECLARE
  v_anchor_email  text := 'compras-proveedor-cta-cte-gate@test.local';
  v_user_id       uuid := gen_random_uuid();
  v_other_user    uuid := gen_random_uuid();
  v_account_id    uuid;
  v_other_account uuid;
  v_branch_id     uuid;
  v_product_id    uuid;
  v_supplier_id   uuid;
  v_supplier2_id  uuid;
  v_supplier_del  uuid;
  v_supplier_alien uuid;
  v_pm_cash       uuid;
  v_pm_credit     uuid;
  v_cc1_id        uuid;
  v_cc2_id        uuid;
  v_sa_id         uuid;
  v_result        jsonb;
  v_op_id         uuid;
  v_purchase_id   uuid;
  v_purchase_ids  uuid[];
  v_count         integer;
  v_balance       numeric;
  v_qty           numeric;
  v_qty_before    numeric;
  v_rejected      boolean;
  v_sqlstate      text;
  v_payload       jsonb;
  v_val           uuid;
  v_cc_val        uuid;
  v_movs_before   integer;
  v_entry_status  text;
BEGIN
  -- ── Anchor sintetico ───────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Compras Proveedor Cta Cte'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE COMPRAS-PROVEEDOR: no se pudo resolver cuenta para el anchor sintetico — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id FROM public.branches WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash   FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'cash'   LIMIT 1;
  SELECT id INTO v_pm_credit FROM public.payment_methods WHERE account_id = v_account_id AND kind = 'credit' LIMIT 1;

  IF v_branch_id IS NULL OR v_pm_cash IS NULL OR v_pm_credit IS NULL THEN
    RAISE NOTICE 'GATE COMPRAS-PROVEEDOR: branch/catalogo de formas de pago no disponible para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  -- Segunda cuenta, para el caso "proveedor ajeno".
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_other_user, 'authenticated', 'authenticated', 'compras-proveedor-cta-cte-alien@test.local',
          now(), now(), jsonb_build_object('name', 'Gate Compras Proveedor Alien'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_other_account
  FROM public.account_members WHERE user_id = v_other_user ORDER BY created_at LIMIT 1;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_id, v_account_id, '__gate_cpcc_product__', 1000, 400, 'GATE-CPCC-1')
  RETURNING id INTO v_product_id;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_id, v_branch_id, v_product_id, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.cost_centers (account_id, name, is_active)
  VALUES (v_account_id, '__gate_cpcc_cc1__', true) RETURNING id INTO v_cc1_id;
  INSERT INTO public.cost_centers (account_id, name, is_active)
  VALUES (v_account_id, '__gate_cpcc_cc2__', true) RETURNING id INTO v_cc2_id;

  -- ═══════════════════ (1) suppliers: identidad fiscal (RN-96) ═══════════════
  -- (1a) las cinco columnas existen. En PROD tax_id/email/phone ya existian
  -- (schema pre-migraciones); en CI/local las cinco nacen con este change.
  SELECT count(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'suppliers'
    AND column_name IN ('tax_id', 'legal_name', 'iva_condition', 'email', 'phone');

  IF v_count <> 5 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (1a): esperaba las 5 columnas de identidad fiscal en suppliers, hay %.', v_count;
  END IF;

  -- (1b) alta CON identidad fiscal completa: persiste tal cual.
  INSERT INTO public.suppliers (account_id, name, tax_id, legal_name, iva_condition, email, phone)
  VALUES (v_account_id, '__gate_cpcc_supplier__', '30-71234567-8', 'Proveedor SRL',
          'responsable_inscripto', 'prov@test.local', '+5492611234567')
  RETURNING id INTO v_supplier_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers
    WHERE id = v_supplier_id AND tax_id = '30-71234567-8' AND legal_name = 'Proveedor SRL'
      AND iva_condition = 'responsable_inscripto' AND email = 'prov@test.local'
      AND phone = '+5492611234567'
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (1b): la identidad fiscal del proveedor no se persistio completa.';
  END IF;

  -- (1b bis) alta SOLO con nombre: las cinco quedan NULL (todas opcionales).
  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_id, '__gate_cpcc_supplier2__')
  RETURNING id INTO v_supplier2_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers
    WHERE id = v_supplier2_id AND tax_id IS NULL AND legal_name IS NULL
      AND iva_condition IS NULL AND email IS NULL AND phone IS NULL
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (1b bis): un proveedor creado solo con nombre deberia dejar la identidad fiscal en NULL.';
  END IF;

  -- (1c) el CHECK rechaza un valor fuera del dominio cerrado — INSERT REAL,
  -- no inspeccion de la definicion (la migracion ya verifica la definicion).
  v_rejected := false;
  BEGIN
    INSERT INTO public.suppliers (account_id, name, iva_condition)
    VALUES (v_account_id, '__gate_cpcc_bad_iva__', 'monotributo_social');
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (1c): iva_condition fuera del dominio cerrado deberia ser rechazado por el CHECK.';
  END IF;

  -- (1c bis) control positivo: los cuatro valores validos entran.
  INSERT INTO public.suppliers (account_id, name, iva_condition) VALUES
    (v_account_id, '__gate_cpcc_iva_ri__',  'responsable_inscripto'),
    (v_account_id, '__gate_cpcc_iva_mt__',  'monotributista'),
    (v_account_id, '__gate_cpcc_iva_ex__',  'exento'),
    (v_account_id, '__gate_cpcc_iva_cf__',  'consumidor_final');

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'suppliers' AND indexname = 'idx_suppliers_account_alive'
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (1d): falta el indice de listado idx_suppliers_account_alive.';
  END IF;

  RAISE NOTICE 'PASS (1): suppliers gana identidad fiscal RN-96 — 5 columnas opcionales, CHECK de dominio cerrado con rechazo real, indice de listado.';

  -- Proveedor borrado y proveedor de otra cuenta, para los guards P0404.
  INSERT INTO public.suppliers (account_id, name, deleted_at)
  VALUES (v_account_id, '__gate_cpcc_supplier_deleted__', now())
  RETURNING id INTO v_supplier_del;

  IF v_other_account IS NOT NULL THEN
    INSERT INTO public.suppliers (account_id, name)
    VALUES (v_other_account, '__gate_cpcc_supplier_alien__')
    RETURNING id INTO v_supplier_alien;
  END IF;

  -- ── Sesion sintetica (request.jwt.claims) — SECURITY DEFINER usa auth.uid() ─
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE COMPRAS-PROVEEDOR: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════ (2) supplier_id persistido en LAS DOS ramas del INSERT ════════════
  -- Una sola operacion con DOS items: uno con producto (rama IF) y uno de
  -- servicio sin producto (rama ELSE, que repite la lista de columnas).
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-2-both-branches',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_two_branches__',
    p_items             => jsonb_build_array(
                             jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1),
                             jsonb_build_object('product_id', NULL,         'amount',  50, 'quantity', 1)
                           ),
    p_branch_id         => v_branch_id,
    p_supplier_id       => v_supplier_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT count(*) INTO v_count
  FROM public.purchases WHERE operation_id = v_op_id AND supplier_id = v_supplier_id;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (2): esperaba 2 filas con supplier_id imputado (rama con producto + rama de servicio), hay %.', v_count;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE operation_id = v_op_id AND product_id IS NOT NULL AND supplier_id = v_supplier_id)
  OR NOT EXISTS (SELECT 1 FROM public.purchases WHERE operation_id = v_op_id AND product_id IS NULL     AND supplier_id = v_supplier_id) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (2 bis): supplier_id debe escribirse en AMBAS ramas del INSERT — la rama ELSE (linea de servicio) es la que se olvida.';
  END IF;
  RAISE NOTICE 'PASS (2): supplier_id se persiste en las DOS ramas del INSERT a purchases (con producto y linea de servicio).';

  -- ═══ (3) GATE ESTRELLA (D5): el cargo se dispara SOLO donde debe ═══════════
  -- (3a) credit + proveedor -> UN movimiento, balance_after = total, evento.
  -- El proveedor NO tiene cuenta corriente previa: el helper la crea en el
  -- mismo commit (task 3.10).
  IF EXISTS (SELECT 1 FROM public.supplier_accounts WHERE supplier_id = v_supplier_id) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a-pre): el proveedor no deberia tener cuenta corriente antes del primer cargo.';
  END IF;

  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-3a-credit',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_credit__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 300, 'quantity', 2)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit,
    p_supplier_id       => v_supplier_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT id INTO v_sa_id FROM public.supplier_accounts
  WHERE account_id = v_account_id AND supplier_id = v_supplier_id;
  IF v_sa_id IS NULL THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a): el helper compartido deberia haber creado la SupplierAccount en el mismo commit.';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.supplier_account_movements WHERE reference_id = v_op_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a): esperaba EXACTAMENTE 1 movimiento de cuenta corriente para la compra a credito, hay %.', v_count;
  END IF;

  SELECT balance_after INTO v_balance
  FROM public.supplier_account_movements WHERE reference_id = v_op_id;
  IF v_balance <> 600 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a): balance_after esperado 600 (300 x 2), es %.', v_balance;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.supplier_account_movements
    WHERE reference_id = v_op_id AND movement_type = 'purchase' AND amount = 600
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a): el movimiento deberia ser movement_type=purchase por 600.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'SupplierAccountCharged'
      AND (payload->>'operation_id')::uuid = v_op_id
      AND (payload->>'supplier_id')::uuid  = v_supplier_id
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3a): el helper compartido deberia haber emitido SupplierAccountCharged.';
  END IF;

  -- (3b) cash -> CERO movimientos.
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-3b-cash',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_cash__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 400, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_cash,
    p_supplier_id       => v_supplier_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT count(*) INTO v_count FROM public.supplier_account_movements WHERE reference_id = v_op_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3b): una compra en efectivo NO debe cargar cuenta corriente, hay % movimiento(s).', v_count;
  END IF;

  -- (3c) EL CASO QUE PROTEGE CONTRA EL COALESCE: sin forma de pago imputada,
  -- CERO movimientos — pero el evento contable sigue propagando 'credit'.
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-3c-nopm',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_no_pm__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 500, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_supplier_id       => v_supplier_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT count(*) INTO v_count FROM public.supplier_account_movements WHERE reference_id = v_op_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3c, ESTRELLA): una compra SIN forma de pago imputada NO debe cargar cuenta corriente — el disparo debe usar v_kind CRUDO, no COALESCE(v_kind,''credit''). Hay % movimiento(s).', v_count;
  END IF;

  SELECT payload INTO v_payload
  FROM public.events
  WHERE event_type = 'PurchaseCreated' AND aggregate_id = v_op_id;

  IF v_payload IS NULL OR v_payload->>'payment_method' <> 'credit' THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (3c, ESTRELLA): el evento PurchaseCreated de una compra sin forma de pago debe seguir propagando ''credit'' (COALESCE del evento INTACTO), es %.', COALESCE(v_payload->>'payment_method', '<sin evento>');
  END IF;

  RAISE NOTICE 'PASS (3, GATE ESTRELLA): el cargo se dispara SOLO con kind=credit — cash y "sin forma de pago" no cargan, y el evento contable conserva su COALESCE(...,''credit'').';

  -- ═══════════════ (4) Guards del alta ═══════════════════════════════════════
  -- (4a) credit SIN proveedor -> P0400, sin efectos en purchases/stock.
  SELECT quantity INTO v_qty_before
  FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key   => 'gate-cpcc-4a-credit-no-supplier',
      p_date              => CURRENT_DATE,
      p_description       => '__gate_cpcc_credit_no_supplier__',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 700, 'quantity', 1)),
      p_branch_id         => v_branch_id,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF v_sqlstate = 'P0400' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4a): una compra a credito SIN proveedor deberia fallar con P0400 (credit_requires_supplier) — no hay deuda sin acreedor.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.purchases WHERE description = '__gate_cpcc_credit_no_supplier__') THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4a): el rechazo no debe dejar filas en purchases.';
  END IF;

  SELECT quantity INTO v_qty FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  IF v_qty <> v_qty_before THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4a): el guard corre ANTES de tocar stock — branch_stock esperado %, es %.', v_qty_before, v_qty;
  END IF;

  -- (4b) el rechazo NO quemo el slot de idempotencia: el reintento con la
  -- MISMA clave y proveedor tiene exito REAL (no un replay vacio). Esto es lo
  -- que distingue "guard antes de reservar el slot" de "guard despues" — el
  -- mismo criterio que el P0413 de banco-caja-historial-ajustes.
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-4a-credit-no-supplier',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_credit_retry__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 700, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit,
    p_supplier_id       => v_supplier_id
  ) INTO v_result;

  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4b): el reintento tras el rechazo P0400 devolvio replayed=true — el guard quemo el slot de idempotencia.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE description = '__gate_cpcc_credit_retry__') THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4b): el reintento deberia haber creado la compra realmente.';
  END IF;

  -- (4c) proveedor de OTRA cuenta -> P0404.
  IF v_supplier_alien IS NOT NULL THEN
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_create_purchase_operation(
        p_idempotency_key => 'gate-cpcc-4c-alien',
        p_date            => CURRENT_DATE,
        p_description     => '__gate_cpcc_alien__',
        p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
        p_branch_id       => v_branch_id,
        p_supplier_id     => v_supplier_alien
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE CPCC FAILED (4c): un proveedor de OTRA cuenta deberia rechazarse con P0404.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.purchases WHERE description = '__gate_cpcc_alien__') THEN
      RAISE EXCEPTION 'GATE CPCC FAILED (4c): el rechazo no debe dejar filas.';
    END IF;
  ELSE
    RAISE NOTICE 'GATE COMPRAS-PROVEEDOR (4c): no se pudo resolver una segunda cuenta — caso "proveedor ajeno" omitido.';
  END IF;

  -- (4d) proveedor BORRADO (soft delete) -> P0404.
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_purchase_operation(
      p_idempotency_key => 'gate-cpcc-4d-deleted',
      p_date            => CURRENT_DATE,
      p_description     => '__gate_cpcc_deleted__',
      p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
      p_branch_id       => v_branch_id,
      p_supplier_id     => v_supplier_del
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (4d): un proveedor con deleted_at deberia rechazarse con P0404 — un proveedor borrado no recibe imputaciones nuevas.';
  END IF;

  RAISE NOTICE 'PASS (4): guards del alta — P0400 credit_requires_supplier sin efectos y sin quemar la idempotencia, P0404 para proveedor ajeno y borrado.';

  -- ═══════════ (5) Edicion: tri-estado de supplier_id (D7) ═══════════════════
  -- Compra SIN cargo (sin forma de pago) — el unico caso editable.
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key => 'gate-cpcc-5-base',
    p_date            => CURRENT_DATE,
    p_description     => '__gate_cpcc_edit_base__',
    p_items           => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 100, 'quantity', 1)),
    p_branch_id       => v_branch_id,
    p_cost_center_id  => v_cc1_id,
    p_supplier_id     => v_supplier_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE operation_id = v_op_id;

  SELECT count(*) INTO v_movs_before FROM public.supplier_account_movements WHERE account_id = v_account_id;

  -- (5a) AUSENTE (provided=false) -> preserva el vigente.
  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids => v_purchase_ids,
    p_date         => CURRENT_DATE,
    p_description  => '__gate_cpcc_edit_absent__',
    p_items        => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 110, 'quantity', 1))
  );
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE description = '__gate_cpcc_edit_absent__';
  SELECT supplier_id INTO v_val FROM public.purchases WHERE description = '__gate_cpcc_edit_absent__' LIMIT 1;
  IF v_val IS DISTINCT FROM v_supplier_id THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (5a): sin informar supplier_id la edicion debe PRESERVAR el vigente (esperado %, es %).', v_supplier_id, v_val;
  END IF;

  -- (5b) PRESENTE con uuid -> reimputa.
  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids      => v_purchase_ids,
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_edit_reimpute__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 120, 'quantity', 1)),
    p_supplier_id       => v_supplier2_id,
    p_supplier_provided => true
  );
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE description = '__gate_cpcc_edit_reimpute__';
  SELECT supplier_id INTO v_val FROM public.purchases WHERE description = '__gate_cpcc_edit_reimpute__' LIMIT 1;
  IF v_val IS DISTINCT FROM v_supplier2_id THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (5b): informar supplier_id con un uuid debe REIMPUTAR (esperado %, es %).', v_supplier2_id, v_val;
  END IF;

  -- (5c) PRESENTE en NULL -> desimputa.
  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids      => v_purchase_ids,
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_edit_clear__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 130, 'quantity', 1)),
    p_supplier_id       => NULL,
    p_supplier_provided => true
  );
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE description = '__gate_cpcc_edit_clear__';
  SELECT supplier_id INTO v_val FROM public.purchases WHERE description = '__gate_cpcc_edit_clear__' LIMIT 1;
  IF v_val IS NOT NULL THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (5c): informar supplier_id en NULL debe DESIMPUTAR, quedo %.', v_val;
  END IF;

  -- (5d) proveedor ajeno en la edicion -> P0404, sin reversa ni reaplicacion.
  IF v_supplier_alien IS NOT NULL THEN
    SELECT quantity INTO v_qty_before FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_atomic_update_purchase_operation(
        p_purchase_ids      => v_purchase_ids,
        p_date              => CURRENT_DATE,
        p_description       => '__gate_cpcc_edit_alien__',
        p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 140, 'quantity', 1)),
        p_supplier_id       => v_supplier_alien,
        p_supplier_provided => true
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE CPCC FAILED (5d): reimputar a un proveedor de otra cuenta deberia fallar con P0404.';
    END IF;
    SELECT quantity INTO v_qty FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
    IF v_qty <> v_qty_before THEN
      RAISE EXCEPTION 'GATE CPCC FAILED (5d): el rechazo corre ANTES del REVERSE — branch_stock esperado %, es %.', v_qty_before, v_qty;
    END IF;
  END IF;

  -- (5e) INVARIANTE D7: nada de esto toco la cuenta corriente.
  SELECT count(*) INTO v_count FROM public.supplier_account_movements WHERE account_id = v_account_id;
  IF v_count <> v_movs_before THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (5e, INVARIANTE D7): editar una compra SIN cargo (incluso cambiando de proveedor) no debe crear, mover ni revertir ningun supplier_account_movement — habia %, hay %.', v_movs_before, v_count;
  END IF;

  RAISE NOTICE 'PASS (5): tri-estado de supplier_id en sus tres estados + P0404 en la edicion + INVARIANTE D7 (la edicion sin cargo no toca la cuenta corriente).';

  -- ═══════ (6) [OQ-5] tri-estado de cost_center_id ═══════════════════════════
  SELECT cost_center_id INTO v_cc_val FROM public.purchases WHERE description = '__gate_cpcc_edit_clear__' LIMIT 1;
  IF v_cc_val IS DISTINCT FROM v_cc1_id THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (6a): cost_center_id deberia haberse PRESERVADO en las ediciones anteriores (esperado %, es %).', v_cc1_id, v_cc_val;
  END IF;

  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids         => v_purchase_ids,
    p_date                 => CURRENT_DATE,
    p_description          => '__gate_cpcc_cc_reimpute__',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 150, 'quantity', 1)),
    p_cost_center_id       => v_cc2_id,
    p_cost_center_provided => true
  );
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE description = '__gate_cpcc_cc_reimpute__';
  SELECT cost_center_id INTO v_cc_val FROM public.purchases WHERE description = '__gate_cpcc_cc_reimpute__' LIMIT 1;
  IF v_cc_val IS DISTINCT FROM v_cc2_id THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (6b): informar cost_center_id con un uuid debe REIMPUTAR (esperado %, es %). Hasta este change el CostCenterSelect del form de edicion no tenia efecto alguno.', v_cc2_id, v_cc_val;
  END IF;

  PERFORM public.rpc_atomic_update_purchase_operation(
    p_purchase_ids         => v_purchase_ids,
    p_date                 => CURRENT_DATE,
    p_description          => '__gate_cpcc_cc_clear__',
    p_items                => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 160, 'quantity', 1)),
    p_cost_center_id       => NULL,
    p_cost_center_provided => true
  );
  SELECT cost_center_id INTO v_cc_val FROM public.purchases WHERE description = '__gate_cpcc_cc_clear__' LIMIT 1;
  IF v_cc_val IS NOT NULL THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (6c): informar cost_center_id en NULL debe DESIMPUTAR, quedo %.', v_cc_val;
  END IF;

  RAISE NOTICE 'PASS (6, OQ-5): tri-estado de cost_center_id en sus tres estados — cierra la OQ-1 de edicion-preserva-contexto completa.';

  -- ═══ (7) Cobertura de lo ya construido que nunca se ejercito ═══════════════
  -- Compra a credito CON proveedor: a partir de aca hay cargo posteado, que es
  -- justo lo que estas tres piezas necesitaban para volverse alcanzables.
  SELECT quantity INTO v_qty_before FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;

  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-7-charged',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_charged__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 250, 'quantity', 2)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit,
    p_supplier_id       => v_supplier2_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;
  SELECT array_agg(id) INTO v_purchase_ids FROM public.purchases WHERE operation_id = v_op_id;
  SELECT id INTO v_sa_id FROM public.supplier_accounts WHERE account_id = v_account_id AND supplier_id = v_supplier2_id;

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 500 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7-pre): saldo del proveedor esperado 500, es %.', v_balance;
  END IF;

  -- (7a / task 5.1) P0423: la compra con cargo posteado es INMUTABLE. Este
  -- guard lo escribio pagos-cableados-restantes (D6) y hasta hoy era
  -- inalcanzable: ningun camino posteaba un cargo de proveedor.
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_atomic_update_purchase_operation(
      p_purchase_ids => v_purchase_ids,
      p_date         => CURRENT_DATE,
      p_description  => '__gate_cpcc_charged_edit__',
      p_items        => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 260, 'quantity', 2))
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0423' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7a): una compra a credito con su cargo posteado NO deberia poder editarse (P0423).';
  END IF;
  RAISE NOTICE 'PASS (7a): P0423 — la compra a credito con cargo posteado es inmutable (guard de pagos-cableados-restantes D6, alcanzable por primera vez).';

  -- (7d / task 5.4) no-regresion contable: el asiento acredita 2100
  -- Proveedores. Se verifica ANTES del borrado, sobre la compra viva.
  PERFORM public.rpc_process_outbox_dispatch(1000);

  IF NOT EXISTS (
    SELECT 1
    FROM public.journal_entries je
    JOIN public.journal_lines  jl ON jl.entry_id = je.id
    WHERE je.source_doc_type = 'Purchase' AND je.source_doc_ref = v_op_id
      AND jl.account_code = '2100' AND jl.side = 'credit' AND jl.amount = 500
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7d): la compra a credito con proveedor debe seguir produciendo el mismo asiento (2100 Proveedores acreditada por 500), sin tocar _journal_post_from_event.';
  END IF;
  RAISE NOTICE 'PASS (7d): no-regresion contable — 2100 Proveedores acreditada; el journal no se toco.';

  -- (7b / task 5.2) el borrado compensa: debit_note negativo, saldo previo,
  -- stock repuesto y evento PurchaseDeleted.
  IF NOT public.rpc_delete_purchase_operation(p_operation_id => v_op_id) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b): rpc_delete_purchase_operation devolvio false.';
  END IF;

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b): tras borrar, el saldo del proveedor debe volver a su valor previo (0), es %.', v_balance;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.supplier_account_movements
    WHERE supplier_account_id = v_sa_id AND movement_type = 'debit_note' AND amount = -500
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b): esperaba un movimiento debit_note(-500) compensando el cargo.';
  END IF;

  SELECT quantity INTO v_qty FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  IF v_qty <> v_qty_before THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b): el borrado debe reponer el stock — esperado %, es %.', v_qty_before, v_qty;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.events WHERE event_type = 'PurchaseDeleted' AND aggregate_id = v_op_id
  ) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b): el borrado debe emitir PurchaseDeleted.';
  END IF;

  PERFORM public.rpc_process_outbox_dispatch(1000);
  SELECT status INTO v_entry_status
  FROM public.journal_entries WHERE source_doc_type = 'Purchase' AND source_doc_ref = v_op_id AND reversal_of IS NULL;
  IF v_entry_status <> 'reversed' THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7b-contable): el asiento original de la compra borrada deberia quedar reversed, es %.', v_entry_status;
  END IF;

  RAISE NOTICE 'PASS (7b): el borrado compensa el cargo (debit_note -500), repone el stock, emite PurchaseDeleted y revierte el asiento.';

  -- (7c / task 5.3) P0425: si el cargo ya fue cancelado por un PaymentMade,
  -- borrar la compra dejaria el saldo en negativo -> rechazo, sin efectos.
  SELECT public.rpc_create_purchase_operation(
    p_idempotency_key   => 'gate-cpcc-7c-paid',
    p_date              => CURRENT_DATE,
    p_description       => '__gate_cpcc_paid__',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_id, 'amount', 200, 'quantity', 1)),
    p_branch_id         => v_branch_id,
    p_payment_method_id => v_pm_credit,
    p_supplier_id       => v_supplier2_id
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  PERFORM public.rpc_register_payment_made(
    p_idempotency_key => 'gate-cpcc-7c-payment',
    p_supplier_id     => v_supplier2_id,
    p_amount          => 200
  );

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7c-pre): saldo esperado 0 (cargo 200 + pago 200), es %.', v_balance;
  END IF;

  SELECT quantity INTO v_qty_before FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_delete_purchase_operation(p_operation_id => v_op_id);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0425' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7c): borrar una compra cuyo cargo ya fue cancelado por un pago deberia fallar con P0425.';
  END IF;

  SELECT balance INTO v_balance FROM public.supplier_accounts WHERE id = v_sa_id;
  IF v_balance <> 0 THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7c): el saldo no debe modificarse cuando el borrado se rechaza, es %.', v_balance;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE operation_id = v_op_id) THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7c): la compra rechazada no deberia haberse borrado (efecto parcial).';
  END IF;
  SELECT quantity INTO v_qty FROM public.branch_stock WHERE branch_id = v_branch_id AND product_id = v_product_id;
  IF v_qty <> v_qty_before THEN
    RAISE EXCEPTION 'GATE CPCC FAILED (7c): el rechazo no debe tocar el stock — esperado %, es %.', v_qty_before, v_qty;
  END IF;

  RAISE NOTICE 'PASS (7c): P0425 — la compra con cargo ya cancelado no se puede borrar, sin efectos parciales sobre saldo, filas ni stock.';

  RAISE NOTICE 'PASS: gate compras-proveedor-cuenta-corriente completo — identidad fiscal RN-96, supplier_id en ambas ramas, GATE ESTRELLA del disparo por v_kind crudo, guards P0400/P0404 sin quemar idempotencia, tri-estado de supplier_id y cost_center_id, y las tres piezas latentes (P0423, compensacion por borrado, P0425) ejercitadas por primera vez en su camino real.';
END $$;
