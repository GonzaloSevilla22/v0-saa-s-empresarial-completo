-- =============================================================================
-- GATE: test_pos_rpc_signatures.sql
-- CHANGE: pos-catalogo-pagos (task 3.1)
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
-- =============================================================================

DO $$
DECLARE
  v_count integer;
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
END $$;
