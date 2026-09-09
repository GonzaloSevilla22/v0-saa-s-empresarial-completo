-- =============================================================================
-- CHANGE: kpi-canonicalization (candidato S5 — "RPC canónica de productos
-- críticos por sucursal + consumidores de IA", ver CLAUDE.md §Candidatos /
-- CHANGES.md, hallazgo dejado por PR #521).
--
-- Desde #521, `get_dashboard_critical_stock(p_branch_id)` es la ÚNICA fuente
-- del KPI de stock crítico — pero devuelve `bigint` (un conteo). El Copiloto
-- (`buildBusinessSnapshot.ts`) y `ai-insights/index.ts` sólo pueden decir
-- "N productos críticos" sin poder decir CUÁLES. Este change agrega la
-- hermana de detalle, `get_dashboard_critical_stock_items`, que expone las
-- filas de `branch_stock` bajo el MISMO predicado — nunca reconstruido desde
-- `v_products_with_stock` (regla de reutilización antes que repetición).
--
-- ── Verificación de integridad de función (regla dura del proyecto) ─────────
-- Esta migración NO reescribe `get_dashboard_critical_stock` — sólo agrega
-- una función nueva. Aun así, el predicado se copia literal desde el cuerpo
-- VIVO verificado hoy (2026-09-09) contra la base local recién reseteada
-- (migrada hasta 20261034000001, paridad con prod verificada por el
-- orquestador):
--
--   pg_get_functiondef('public.get_dashboard_critical_stock(uuid)'::regprocedure)
--   → LANGUAGE plpgsql, SECURITY DEFINER, SET search_path TO 'public':
--     SELECT COUNT(DISTINCT bs.product_id)
--     FROM public.branch_stock bs
--     JOIN public.products p ON p.id = bs.product_id
--     WHERE bs.account_id IN (SELECT current_account_ids())
--       AND bs.min_stock > 0
--       AND bs.quantity <= bs.min_stock
--       AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
--       AND p.deleted_at IS NULL
--       AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
--
-- (El WHERE coincide letra por letra con el predicado citado en el candidato
-- original — la envoltura `plpgsql` con el guard `auth.uid() IS NULL` es la
-- evolución posterior a 20260913000001 que ya trae prod; no afecta al
-- predicado que este change debe replicar.) `get_dashboard_critical_stock_items`
-- copia ese mismo WHERE sin alterarlo — es la garantía de paridad que el gate
-- (2) de `test_dashboard_critical_stock_items.sql` ejercita con datos.
--
-- Diferencia deliberada con la hermana: el conteo dedupea por
-- `COUNT(DISTINCT product_id)` (un producto crítico en 3 sucursales cuenta
-- 1 vez); el detalle es por definición "por sucursal" — devuelve UNA FILA
-- POR (producto, sucursal) que cumple el predicado, sin deduplicar. La
-- paridad de conteo se verifica con `COUNT(DISTINCT product_id)` sobre las
-- filas del detalle.
--
-- Idempotente: CREATE OR REPLACE (firma nueva, sin overload previo) +
-- REVOKE/GRANT re-ejecutables (auto-apply de Supabase GitHub reaplica el
-- archivo).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock_items(
  p_branch_id uuid DEFAULT NULL,
  p_limit     integer DEFAULT 20
)
RETURNS TABLE (
  product_id  uuid,
  name        text,
  sku         text,
  branch_id   uuid,
  branch_name text,
  quantity    numeric,
  min_stock   integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- D7 (contrato de paginación): p_limit NULL = sin límite (Postgres ya
  -- trata LIMIT NULL como "sin límite" nativamente); p_limit <= 0 es un
  -- error del caller, no un "cero resultados" silencioso.
  IF p_limit IS NOT NULL AND p_limit <= 0 THEN
    RAISE EXCEPTION 'p_limit debe ser positivo (o NULL para sin límite): %', p_limit
      USING ERRCODE = 'P0400';
  END IF;

  RETURN QUERY
  -- Mismo FROM/JOIN/WHERE que get_dashboard_critical_stock(p_branch_id) —
  -- ver el bloque de verificación de integridad arriba. Una fila por
  -- (producto, sucursal), no deduplicada por producto (el detalle es "por
  -- sucursal"; la hermana sí dedupea porque cuenta productos distintos).
  SELECT
    bs.product_id,
    p.name,
    p.sku,
    bs.branch_id,
    b.name AS branch_name,
    bs.quantity,
    bs.min_stock
  FROM public.branch_stock bs
  JOIN public.products p ON p.id = bs.product_id
  JOIN public.branches b ON b.id = bs.branch_id
  WHERE bs.account_id IN (SELECT current_account_ids())
    AND bs.min_stock > 0
    AND bs.quantity <= bs.min_stock
    AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
    AND p.deleted_at IS NULL
    AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
  -- Más crítico primero: menor razón quantity/min_stock (más lejos bajo su
  -- umbral), desempatado por nombre para un orden determinístico en tests.
  ORDER BY (bs.quantity / NULLIF(bs.min_stock, 0)) ASC, p.name ASC
  LIMIT p_limit;
END;
$function$;

COMMENT ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) IS
    'kpi-canonicalization (candidato S5): detalle canónico de productos '
    'críticos por sucursal — hermana de get_dashboard_critical_stock(uuid) '
    'con el MISMO predicado (branch_stock.min_stock > 0 AND quantity <= '
    'min_stock, tracked/untracked/variant_only, deleted_at, tenencia vía '
    'current_account_ids()), pero devolviendo las filas (una por producto+'
    'sucursal, sin deduplicar) en vez del conteo. Consumido por el Copiloto '
    '(buildBusinessSnapshot.ts) y ai-insights/index.ts para poder nombrar '
    'los productos críticos, no sólo contarlos. Nunca reconstruir este '
    'predicado desde v_products_with_stock.';

-- =============================================================================
-- ACLs — exigido por supabase/tests/test_function_acl_gate.sql (revocar anon
-- explícitamente; REVOKE FROM PUBLIC no alcanza). La llaman el frontend
-- (Copiloto) y las Edge Functions de IA, ambas con JWT de usuario.
-- =============================================================================
REVOKE ALL     ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_critical_stock_items(uuid, integer) TO authenticated;

-- =============================================================================
-- Gate de introspección inline (corre SIEMPRE, también en prod).
-- =============================================================================
DO $$
DECLARE
  v_oid    oid;
  v_secdef boolean;
  v_config text[];
  v_prosrc text;
BEGIN
  SELECT p.oid, p.prosecdef, p.proconfig, p.prosrc
    INTO v_oid, v_secdef, v_config, v_prosrc
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock_items'
    AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid, p_limit integer';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_critical_stock_items(p_branch_id uuid, p_limit integer) no existe tras la migración.';
  END IF;

  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_critical_stock_items debe ser SECURITY DEFINER.';
  END IF;

  IF v_config IS NULL OR NOT EXISTS (
    SELECT 1 FROM unnest(v_config) AS cfg WHERE cfg LIKE 'search_path=%'
  ) THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_critical_stock_items no fija search_path.';
  END IF;

  IF position('min_stock > 0' in v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_critical_stock_items no conserva el guard min_stock > 0 (RN-23).';
  END IF;

  IF position('variant_only' in v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_critical_stock_items no excluye stock_control_type = variant_only.';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: anon NO debe poder ejecutar get_dashboard_critical_stock_items.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: authenticated debe poder ejecutar get_dashboard_critical_stock_items.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: get_dashboard_critical_stock_items con firma única, SECURITY DEFINER, guards min_stock/variant_only y ACLs exactas.';
END $$;
