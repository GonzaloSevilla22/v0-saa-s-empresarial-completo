-- =============================================================================
-- GATE: test_pos_rpc_signatures.sql
-- CHANGE: pos-catalogo-pagos (task 3.1) → extendido por pos-banco-movimientos
-- (task 2.2)
--
-- Guard 42725: rpc_quick_sale y rpc_confirm_sales_order tienen TODOS sus
-- parámetros con DEFAULT desde el segundo. Agregar p_payment_method_id
-- trailing sin dropear la firma vieja crea un overload ambiguo para
-- cualquier invocación con el número de argumentos original. Verifica:
--   (1) exactamente UNA fila en pg_proc por proname para las dos RPCs
--       públicas y para el helper interno _c29_confirm_order_core;
--   (2) EXECUTE de authenticated en las dos RPCs públicas, con PUBLIC
--       revocado (el DROP+CREATE resetea ACLs — gotcha advisors 0028/0029,
--       mismo gate que test_function_acl_gate.sql pero acotado a estas 3
--       funciones inmediatamente después de la migración).
--
-- pos-banco-movimientos (D6, task 2.2): extiende (1) a las 3 RPCs restantes
-- que ganan p_bank_account_id trailing (rpc_create_sale_operation,
-- rpc_create_sale_operation_v2, rpc_create_purchase_operation) y (2) a sus
-- ACLs — mismo riesgo 42725/ACL-reset, ahora en 6 firmas en vez de 3.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
  v_name  text;
BEGIN
  -- ── (1) Una sola firma por función ────────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_quick_sale';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (1a, 42725): esperaba 1 firma de rpc_quick_sale, hay % (overload ambiguo — ¿faltó el DROP FUNCTION de la firma vieja?).', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_confirm_sales_order';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (1b, 42725): esperaba 1 firma de rpc_confirm_sales_order, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_c29_confirm_order_core';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (1c, 42725): esperaba 1 firma de _c29_confirm_order_core, hay %.', v_count;
  END IF;

  RAISE NOTICE 'PASS (1): una sola firma por función — rpc_quick_sale, rpc_confirm_sales_order y _c29_confirm_order_core.';

  -- ── (1d) pos-banco-movimientos: las 3 RPCs restantes con firma nueva ──────
  FOREACH v_name IN ARRAY ARRAY[
    'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation'
  ]
  LOOP
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (1d, 42725): esperaba 1 firma de %, hay % (pos-banco-movimientos D6 — ¿faltó el DROP FUNCTION de la firma vieja?).', v_name, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS (1d): una sola firma por función — rpc_create_sale_operation, rpc_create_sale_operation_v2 y rpc_create_purchase_operation (p_bank_account_id trailing).';

  -- ── (2) ACLs: authenticated puede ejecutar, PUBLIC no ─────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_quick_sale'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (2a): authenticated no tiene EXECUTE sobre rpc_quick_sale (¿faltó el GRANT tras el DROP+CREATE?).';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_confirm_sales_order'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (2b): authenticated no tiene EXECUTE sobre rpc_confirm_sales_order.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname IN ('rpc_quick_sale', 'rpc_confirm_sales_order', '_c29_confirm_order_core')
        AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ) THEN
      RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (2c): anon tiene EXECUTE sobre alguna de las 3 funciones — el REVOKE ALL FROM PUBLIC no se re-emitió tras el DROP+CREATE.';
    END IF;
  END IF;

  RAISE NOTICE 'PASS (2): authenticated ejecuta las 2 RPCs públicas; anon/PUBLIC sin acceso.';

  -- ── (2d) pos-banco-movimientos: ACLs de las 3 RPCs restantes ──────────────
  FOREACH v_name IN ARRAY ARRAY[
    'rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_name
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    ) THEN
      RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (2d): authenticated no tiene EXECUTE sobre % (¿faltó el GRANT tras el DROP+CREATE?).', v_name;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('rpc_create_sale_operation', 'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation')
        AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ) THEN
      RAISE EXCEPTION 'GATE POS-RPC-SIGNATURES FAILED (2d): anon tiene EXECUTE sobre alguna de las 3 RPCs de creación — el REVOKE ALL FROM PUBLIC no se re-emitió tras el DROP+CREATE.';
    END IF;
  END IF;

  RAISE NOTICE 'PASS (2d): authenticated ejecuta las 3 RPCs de creación; anon/PUBLIC sin acceso.';
END $$;
