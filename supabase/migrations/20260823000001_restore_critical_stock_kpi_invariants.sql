-- =============================================================================
-- MIGRATION: 20260823000001_restore_critical_stock_kpi_invariants.sql
-- SECURITY + RN-23: restaura los 2 invariantes de get_dashboard_critical_stock
-- que 20260623000001 (C-21 checkpoint #2) rompió al recrear las funciones para
-- leer v_products_with_stock, y que la CI no atrapó (KPI Validation corría
-- psql sin ON_ERROR_STOP y quedaba verde con los tests fallando; PR #328):
--
--  1. [CRITICAL] Reintrodujo el overload get_dashboard_critical_stock(
--     p_user_id uuid): SECURITY DEFINER, filtra por el user_id que pasa el
--     caller SIN check de auth.uid() → cualquier usuario autenticado puede
--     leer el conteo de stock crítico de otro tenant (IDOR). Ya había sido
--     dropeado por 20260430000007_fix_kpi_rpc_security. Cero callers en
--     frontend/backend (verificado). Se dropea de nuevo.
--
--  2. [MEDIUM] La versión 0-args perdió el guard `min_stock > 0` (RN-23:
--     min_stock = 0 ⇒ "sin umbral configurado" ⇒ NUNCA crítico — predicado
--     canónico, ver frontend/lib/product-stock.ts). Sin el guard, todo
--     producto sin umbral con stock <= 0 cuenta como crítico → KPI inflado.
--     Se recrea con el guard, manteniendo la lectura desde
--     v_products_with_stock (C-21) y el guard de autenticación.
--
-- Idempotente: DROP IF EXISTS + CREATE OR REPLACE + REVOKE/GRANT re-aplicables
-- (la integración GitHub de Supabase auto-aplica al mergear y Actions puede
-- re-aplicar vía db push).
-- =============================================================================

-- ── 1. Drop del overload vulnerable (IDOR) ────────────────────────────────────
-- supabase/tests/test_kpis.sql (PR #328) lo vigila por firma exacta con la CI
-- ya corriendo con ON_ERROR_STOP, así no vuelve a entrar silenciosamente.
DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock(uuid);

-- ── 2. Recrear la 0-args con el guard RN-23 ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_count bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista).
  -- RN-23: min_stock = 0 ⇒ sin umbral configurado ⇒ nunca crítico.
  SELECT COUNT(id) INTO v_count
  FROM public.v_products_with_stock
  WHERE user_id = v_uid
    AND min_stock > 0
    AND stock <= min_stock;

  RETURN COALESCE(v_count, 0);
END;
$$;

-- ── 3. ACLs explícitas ────────────────────────────────────────────────────────
-- Regla advisors 0028: re-aplicar REVOKE al recrear funciones (DROP+CREATE
-- resetea ACLs; CREATE OR REPLACE las conserva pero se fijan explícitas igual).
REVOKE ALL     ON FUNCTION public.get_dashboard_critical_stock() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_critical_stock() FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_critical_stock() TO authenticated;

-- ── 4. GATE: invariantes restaurados ─────────────────────────────────────────
DO $$
DECLARE
  v_bad text;
  v_ok  boolean;
BEGIN
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock'
    AND pg_get_function_identity_arguments(p.oid) <> '';

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'GATE FAILED: overload(s) inesperado(s) de get_dashboard_critical_stock: [%]', v_bad;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND p.prosecdef
      AND p.prosrc LIKE '%min_stock > 0%'
      AND p.prosrc LIKE '%v_products_with_stock%'
      AND p.prosrc LIKE '%auth.uid()%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION
      'GATE FAILED: get_dashboard_critical_stock() no quedó con guard RN-23 + auth.uid() + lectura de v_products_with_stock';
  END IF;

  RAISE NOTICE 'GATE PASSED: get_dashboard_critical_stock sin overloads extra + guard min_stock > 0 restaurado.';
END $$;
