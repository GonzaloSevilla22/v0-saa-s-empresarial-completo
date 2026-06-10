-- =============================================================================
-- MIGRATION: 20260616000007_fix_purchase_rpc_ambiguity.sql
-- HOTFIX C-20 — incidente post-merge PR #153 (2026-06-10)
--
-- ROOT CAUSE:
--   20260616000003 creó el wrapper rpc_create_purchase_operation con firma
--   4-args (text, date, text, jsonb) asumiendo la firma de 20260528162050.
--   Pero 20260607000001 (branch support, C-08) había agregado la sobrecarga
--   5-args (text, date, text, jsonb, uuid DEFAULT NULL). CREATE OR REPLACE
--   con 4 args NO reemplazó la de 5 — creó una sobrecarga nueva.
--   Resultado: toda llamada con 4 args (el backend llama $1,$2,$3,$4) es
--   ambigua → "function rpc_create_purchase_operation(...) is not unique"
--   → 500 en la creación de compras.
--
-- FIX:
--   Dropear la sobrecarga legacy 5-args. El wrapper 4-args queda único y
--   despacha a rpc_create_purchase_operation_v2 (flag por cuenta, ON desde
--   el cutover) que escribe purchase_items + header (doble escritura).
--
-- TRADE-OFF DOCUMENTADO:
--   La 5-args contenía el camino dual-ledger de branch_stock para compras
--   por sucursal (C-08). Ningún caller lo usa hoy (el backend FastAPI llama
--   con 4 args, el frontend va vía FastAPI desde C-16, ninguna EF crea
--   compras). PENDIENTE: dar soporte de p_branch_id a
--   rpc_create_purchase_operation_v2 (paridad con ventas v2) antes de
--   exponer compras por sucursal en la API. Registrado como follow-up C-20.
--
-- ROLLBACK:
--   Recrear la función desde 20260607000001_rpc_branch_support.sql (la
--   definición exacta vigente al momento del drop fue capturada en el
--   incidente; idéntica a la de esa migración + fix de idempotencia 3-col).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid);

-- Verificación: debe quedar exactamente una sobrecarga (la 4-args wrapper)
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_purchase_operation';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Esperaba 1 sobrecarga de rpc_create_purchase_operation, hay %', v_count;
  END IF;
END;
$$;
