-- =============================================================================
-- GATE: test_confirm_core_integrity.sql
-- CHANGE: pos-catalogo-pagos (task 2.1) → reescrito a TRANSITIVO por
-- pagos-cableados-restantes (tasks 2.1-2.3, design.md D3)
--
-- Gate anti-regresión de la regresión de julio 2026: 20260721000001 reescribió
-- _c29_confirm_order_core desde una base anterior a C-30 y borró el bloque
-- `credit` en silencio. Nadie lo notó porque ninguna superficie ofrecía
-- `credit` y no había ningún test que inspeccionara el CUERPO PUBLICADO de la
-- función (los tests de negocio solo ejercitan `cash`/`other`, que seguían
-- funcionando). Este gate no ejecuta ninguna función: lee definiciones vivas
-- con pg_get_functiondef y falla si falta cualquier bloque requerido.
--
-- pagos-cableados-restantes (D2/D3) extrae el bloque `credit` inline de
-- _c29_confirm_order_core al helper compartido _pay_register_party_charge
-- (para que el POS y el formulario de venta compartan una sola definición de
-- "cargar una venta a cuenta corriente" — D1/D2). Eso rompería el gate
-- literal original (ya no busca c30_register_customer_account_movement
-- dentro de _c29_confirm_order_core). La respuesta correcta no es relajar el
-- gate sino hacerlo TRANSITIVO: verifica la CADENA COMPLETA en vez de un solo
-- cuerpo, y de paso extiende la cobertura a rpc_create_sale_operation_v2 (el
-- camino del formulario, que hasta este change no tenía NINGUNA protección).
--
-- Cadena verificada:
--   1. _c29_confirm_order_core existe y su cuerpo contiene
--      _pay_register_party_charge + c28_register_cash_movement +
--      credit_requires_client (además de fiscal/outbox/status-history/snapshots).
--   2. _pay_register_party_charge existe y su cuerpo contiene los 4 helpers
--      C-30 (customer Y supplier — el despacho por tipo de parte, D1).
--   3. rpc_create_sale_operation_v2 existe y su cuerpo contiene
--      _pay_register_party_charge + credit_requires_client — el camino del
--      formulario queda igual de protegido que el del POS.
--   4. rpc_create_purchase_operation NO contiene el literal hardcodeado
--      'payment_method', 'credit' (regresión que este change corrige — D7).
--
-- Ejecutado contra la definición ANTERIOR a la migración 20261001000001, este
-- gate falla en (1) y (2): _c29_confirm_order_core todavía tiene el bloque
-- credit inline (no llama al helper) y _pay_register_party_charge no existe.
-- Es la prueba viva de que el gate protege lo que dice proteger, no una
-- hipótesis (evidencia RED capturada en el PR de este change).
-- =============================================================================

DO $$
DECLARE
  v_def       text;
  v_missing   text[];
  v_req       text;
BEGIN
  -- ── (1) _c29_confirm_order_core: llama al helper, NO tiene el bloque C-30 inline ──
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_c29_confirm_order_core';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED (1): public._c29_confirm_order_core no existe.';
  END IF;

  v_missing := ARRAY[]::text[];
  FOREACH v_req IN ARRAY ARRAY[
    '_pay_register_party_charge',            -- pagos-cableados-restantes: llama al helper compartido (D2)
    'c28_register_cash_movement',            -- bloque de caja (C-28)
    'credit_requires_client',                -- guard de C-30
    'rpc_emit_pending_cae',                  -- bloque fiscal (C-27)
    'record_status_transition',              -- historial de estados (v3-document-status-history)
    'reporting_local_today',                 -- día ART (app-timezone-argentina)
    'INSERT INTO public.sale_items',         -- acarreo de líneas (#415)
    'unit_cost_snapshot',                    -- snapshot de costo (v3-snapshot-pattern)
    'CustomerAccountCharged',                -- evento de outbox de C-30 (emitido desde el helper hoy;
                                              -- el payload lo arma _pay_register_party_charge, pero el
                                              -- INSERT vive ahí, no acá — ver nota abajo)
    'SaleConfirmed'                          -- evento de outbox de C-29
  ]
  LOOP
    IF position(v_req IN v_def) = 0 THEN
      v_missing := array_append(v_missing, v_req);
    END IF;
  END LOOP;

  -- 'CustomerAccountCharged' ahora vive dentro de _pay_register_party_charge,
  -- no en _c29_confirm_order_core (la extracción del bloque D2 se llevó el
  -- INSERT INTO events junto con el cargo — es la misma operación atómica).
  -- Se remueve de la lista estricta de (1) y se verifica en (2) en su lugar,
  -- para no exigirle a confirm-core un substring que legítimamente ya no le
  -- pertenece tras la extracción.
  v_missing := array_remove(v_missing, 'CustomerAccountCharged');

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE CONFIRM-CORE-INTEGRITY FAILED (1): el cuerpo publicado de _c29_confirm_order_core no contiene:\n  %\nEsto es exactamente la regresión de julio 2026 (bloque credit perdido al reescribir desde una base vieja) — ver openspec/changes/pos-catalogo-pagos/design.md Risk #1 y openspec/changes/pagos-cableados-restantes/design.md D2/D3.', array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (1): _c29_confirm_order_core llama a _pay_register_party_charge y conserva caja/fiscal/outbox/status-history/snapshots.';

  -- ── (2) _pay_register_party_charge: los 4 helpers C-30 (customer + supplier) ──
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_pay_register_party_charge';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED (2): public._pay_register_party_charge no existe — el helper compartido de cargo en cuenta corriente (design.md D1) todavía no fue creado.';
  END IF;

  v_missing := ARRAY[]::text[];
  FOREACH v_req IN ARRAY ARRAY[
    'c30_get_or_create_customer_account',
    'c30_register_customer_account_movement',
    'c30_get_or_create_supplier_account',
    'c30_register_supplier_account_movement',
    'CustomerAccountCharged',
    'SupplierAccountCharged'
  ]
  LOOP
    IF position(v_req IN v_def) = 0 THEN
      v_missing := array_append(v_missing, v_req);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE CONFIRM-CORE-INTEGRITY FAILED (2): el cuerpo publicado de _pay_register_party_charge no contiene:\n  %\nEl helper debe despachar por p_party_kind sobre AMBOS pares de helpers C-30 (customer y supplier) — design.md D1.', array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (2): _pay_register_party_charge despacha sobre los 4 helpers C-30 (customer + supplier) y emite ambos eventos.';

  -- ── (3) rpc_create_sale_operation_v2: mismo guard que el POS, vía el helper ──
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_sale_operation_v2';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED (3): public.rpc_create_sale_operation_v2 no existe.';
  END IF;

  v_missing := ARRAY[]::text[];
  FOREACH v_req IN ARRAY ARRAY[
    '_pay_register_party_charge',
    'credit_requires_client'
  ]
  LOOP
    IF position(v_req IN v_def) = 0 THEN
      v_missing := array_append(v_missing, v_req);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE CONFIRM-CORE-INTEGRITY FAILED (3): el cuerpo publicado de rpc_create_sale_operation_v2 no contiene:\n  %\nEl camino del formulario (223 operaciones en prod) debe quedar tan protegido como el del POS — pagos-cableados-restantes design.md D2/OQ-D.', array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS (3): rpc_create_sale_operation_v2 postea el cargo de crédito vía el helper compartido, con el mismo guard credit_requires_client que el POS.';

  -- ── (4) rpc_create_purchase_operation: SIN el literal hardcodeado ─────────
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_purchase_operation';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED (4): public.rpc_create_purchase_operation no existe.';
  END IF;

  IF position($lit$'payment_method', 'credit'$lit$ IN v_def) > 0 THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED (4): rpc_create_purchase_operation todavía hardcodea el literal ''payment_method'', ''credit'' en el payload de PurchaseCreated — las 38 compras de prod hoy postean a 2100 Proveedores sin importar el kind real (pagos-cableados-restantes design.md D7/OQ-E). Debe derivar el kind desde p_payment_method_id con COALESCE(..., ''credit'').';
  END IF;

  RAISE NOTICE 'PASS (4): rpc_create_purchase_operation ya no hardcodea el literal credit — emite el kind real derivado de p_payment_method_id.';

  RAISE NOTICE 'PASS: gate transitivo completo — confirm-core → helper → C-30, formulario cubierto, hardcode de compras corregido.';
END $$;
