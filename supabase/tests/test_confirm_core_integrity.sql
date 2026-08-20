-- =============================================================================
-- GATE: test_confirm_core_integrity.sql
-- CHANGE: pos-catalogo-pagos (task 2.1)
--
-- Gate anti-regresión de la regresión de julio 2026: 20260721000001 reescribió
-- _c29_confirm_order_core desde una base anterior a C-30 y borró el bloque
-- `credit` en silencio. Nadie lo notó porque ninguna superficie ofrecía
-- `credit` y no había ningún test que inspeccionara el CUERPO PUBLICADO de la
-- función (los tests de negocio solo ejercitan `cash`/`other`, que seguían
-- funcionando). Este gate no ejecuta la función: lee su definición viva con
-- pg_get_functiondef y falla si falta cualquiera de los bloques que la
-- confirmación de una venta SHALL incluir según el spec `sales-order`.
--
-- Ejecutado contra la definición ANTERIOR a esta migración (checkout previo
-- al merge), este gate falla: falta `c30_register_customer_account_movement`.
-- Es la prueba viva de la regresión, no una hipótesis.
-- =============================================================================

DO $$
DECLARE
  v_def       text;
  v_missing   text[] := ARRAY[]::text[];
  v_required  CONSTANT text[] := ARRAY[
    'c28_register_cash_movement',            -- bloque de caja (C-28)
    'c30_register_customer_account_movement', -- bloque de cuenta corriente (C-30) — el que se perdió
    'c30_get_or_create_customer_account',     -- lazy-create de CustomerAccount (C-30)
    'credit_requires_client',                 -- guard de C-30
    'rpc_emit_pending_cae',                   -- bloque fiscal (C-27)
    'record_status_transition',               -- historial de estados (v3-document-status-history)
    'reporting_local_today',                  -- día ART (app-timezone-argentina)
    'INSERT INTO public.sale_items',          -- acarreo de líneas (#415)
    'unit_cost_snapshot',                     -- snapshot de costo (v3-snapshot-pattern)
    'CustomerAccountCharged',                 -- evento de outbox de C-30
    'SaleConfirmed'                           -- evento de outbox de C-29
  ];
  v_req       text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_c29_confirm_order_core';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE CONFIRM-CORE-INTEGRITY FAILED: public._c29_confirm_order_core no existe.';
  END IF;

  FOREACH v_req IN ARRAY v_required LOOP
    IF position(v_req IN v_def) = 0 THEN
      v_missing := array_append(v_missing, v_req);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'GATE CONFIRM-CORE-INTEGRITY FAILED: el cuerpo publicado de _c29_confirm_order_core no contiene:\n  %\nEsto es exactamente la regresión de julio 2026 (bloque credit perdido al reescribir desde una base vieja) — ver openspec/changes/pos-catalogo-pagos/design.md Risk #1.', array_to_string(v_missing, E'\n  ');
  END IF;

  RAISE NOTICE 'PASS: _c29_confirm_order_core contiene los % bloques requeridos (caja, cuenta corriente, fiscal, outbox, status-history, snapshots).', array_length(v_required, 1);
END $$;
