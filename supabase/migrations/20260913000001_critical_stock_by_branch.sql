-- =============================================================================
-- MIGRATION: 20260913000001_critical_stock_by_branch.sql
-- kpi-critical-stock-dashboard: get_dashboard_critical_stock pasa a ser
-- consciente de sucursal (D1) y a contar sobre branch_stock (fila por
-- sucursal), no sobre el agregado v_products_with_stock.
--
-- Contexto (proposal.md / design.md):
--   La tarjeta "Productos en alerta" del Tablero recalculaba su propio
--   predicado inline sobre `products` (agregado Σ branch_stock) e ignoraba
--   `?branch=`. La RPC canónica existía pero tenía CERO callers (grep
--   verificado). Este change hace que el Tablero consuma la RPC y que la
--   RPC cuente lo mismo que la UI necesita.
--
-- Cambios de contrato (BREAKING, sin impacto: 0 callers hoy):
--   - Nueva firma: get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL).
--     Con p_branch_id: crítico EN esa sucursal. Sin p_branch_id: crítico en
--     ALGUNA sucursal con umbral (COUNT DISTINCT product_id — D2), así un
--     faltante local ya no se tapa con el stock de otra sucursal.
--   - Exclusiones D3: stock_control_type IN ('untracked','variant_only') no
--     suma (fail-open: NULL o valor legacy desconocido SÍ suma, espejo de
--     holdsOwnStock en frontend/lib/product-stock.ts). deleted_at IS NOT NULL
--     tampoco suma (soft delete).
--   - Tenancy D4: account_id IN (SELECT current_account_ids()), el mismo
--     helper canónico que get_dashboard_financials (20260610000001) — antes
--     filtraba por products.user_id (dueño original), así que un MIEMBRO de
--     la cuenta leía 0.
--
-- Gotcha 42725: CREATE OR REPLACE agregando un parámetro nuevo crea un
-- SEGUNDO overload en vez de reemplazar la función → DROP FUNCTION IF EXISTS
-- de la firma vieja (0-args) ANTES del CREATE, en este mismo archivo.
--
-- DROP + CREATE resetea ACLs → REVOKE/GRANT re-aplicados acá mismo (regla
-- del backlog de advisors 0028).
--
-- Idempotente: la integración GitHub de Supabase auto-aplica al mergear y
-- Actions puede re-aplicar vía `db push` sin fallar ni cambiar el resultado.
-- =============================================================================

-- ── 1. Drop de la firma vieja (0-args) ────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock();

-- ── 2. Crear la firma nueva, consciente de sucursal ───────────────────────────
CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- D1: cuenta sobre branch_stock (fila por sucursal), no sobre el agregado.
  -- D2: sin p_branch_id, COUNT(DISTINCT product_id) — "crítico en alguna
  --     sucursal con umbral", no pares producto-sucursal.
  -- D3: excluye productos que no sostienen stock propio (fail-open sobre
  --     valores desconocidos, espejo de holdsOwnStock) y soft-deleted.
  -- D4: scope por cuenta (current_account_ids()), no por products.user_id.
  SELECT COUNT(DISTINCT bs.product_id)
  INTO v_count
  FROM public.branch_stock bs
  JOIN public.products p ON p.id = bs.product_id
  WHERE bs.account_id IN (SELECT current_account_ids())
    AND bs.min_stock > 0
    AND bs.quantity <= bs.min_stock
    AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
    AND p.deleted_at IS NULL
    AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only');

  RETURN COALESCE(v_count, 0);
END;
$$;

-- ── 3. ACLs explícitas (DROP+CREATE resetea; regla advisors 0028) ────────────
REVOKE ALL     ON FUNCTION public.get_dashboard_critical_stock(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_critical_stock(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_critical_stock(uuid) TO authenticated;

-- ── 4. GATE: firma única + invariantes de seguridad ───────────────────────────
DO $$
DECLARE
  v_bad text;
  v_ok  boolean;
BEGIN
  -- Exactamente una firma, y es la esperada (p_branch_id uuid).
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock'
    AND pg_get_function_identity_arguments(p.oid) <> 'p_branch_id uuid';

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'GATE FAILED: firma(s) inesperada(s) de get_dashboard_critical_stock: [%]', v_bad;
  END IF;

  -- Nunca debe existir la firma con identidad de usuario (vector IDOR).
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND pg_get_function_identity_arguments(p.oid) ILIKE '%p_user_id%'
  ) THEN
    RAISE EXCEPTION
      'GATE FAILED: get_dashboard_critical_stock(p_user_id uuid) reintroducido — vector IDOR prohibido';
  END IF;

  -- Invariantes de seguridad conservados en el cuerpo.
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid'
      AND p.prosecdef
      AND p.prosrc LIKE '%min_stock > 0%'
      AND p.prosrc LIKE '%auth.uid()%'
      AND p.prosrc LIKE '%branch_stock%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION
      'GATE FAILED: get_dashboard_critical_stock no conserva SECURITY DEFINER + guard min_stock > 0 + auth.uid() + lectura de branch_stock';
  END IF;

  RAISE NOTICE 'GATE PASSED: get_dashboard_critical_stock(p_branch_id uuid) — firma única, sin overload IDOR, invariantes de seguridad conservados.';
END $$;
