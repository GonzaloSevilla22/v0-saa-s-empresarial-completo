-- =============================================================================
-- qa-integral-modulos — arreglos SQL del QA integral 2026-08-30
-- (G4 task 4.2, G8 task 8.2, G16/OQ-3 task 16.3)
--
-- ⚠️ REGLA DE INTEGRIDAD DE FUNCIÓN: los dos CREATE OR REPLACE de este archivo
-- parten del pg_get_functiondef VIVO de prod, capturado el 2026-08-31 en
-- openspec/changes/qa-integral-modulos/baseline/*.live.sql (md5 verificado
-- byte a byte contra prod, ver baseline/BASELINE.md):
--   · rpc_branch_report(uuid,date,date)        md5 fd21f8864b9878d7cb271ff210ee6953
--   · rpc_product_profitability(integer)       md5 eb25445906c068f6025600517012bf38
-- La ÚNICA diferencia admisible por función es el fix puntual documentado en
-- su sección. NUNCA partir del archivo de migración anterior: el cuerpo vivo
-- de rpc_product_profitability YA divergió de su archivo ('P0403' vivo vs
-- 'P403' en 20260814000001 L153, reescritura in-place del G3 de
-- 20261003000001) — ese 'P0403' se conserva tal cual.
--
-- Sin DROP (resetea ACLs y el RETURNS TABLE exigiría recrear firma): CREATE OR
-- REPLACE conservando firma y tipo de retorno, ACLs reafirmadas igual (defensa
-- en profundidad, lección advisor 0028). Sin ERRCODEs nuevos; sin P0001.
-- Re-appliable por construcción: CREATE OR REPLACE + UPDATEs acotados por
-- description IS NULL. Va como ÚLTIMO eslabón de la cadena de reapply de
-- KPI_Validation.yml.
-- =============================================================================


-- =============================================================================
-- 1. rpc_branch_report — fix 42702 (H4): "column reference branch_id is
--    ambiguous". El RETURNS TABLE declara la variable plpgsql branch_id y el
--    CTE all_branch_ids referenciaba la columna homónima SIN calificar
--    (arrastrado verbatim desde 20260607000000:304). La función NUNCA ejecutó
--    correctamente desde su creación (C-06, 2026-06-07).
--    FIX PUNTUAL (única diferencia con el baseline): calificar branch_id en
--    las dos ramas del CTE all_branch_ids. Probado en local: con eso solo, la
--    función planifica y ejecuta (el ORDER BY total_sales resuelve al alias de
--    salida sin conflicto).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_branch_report(p_account_id uuid, p_start date, p_end date)
 RETURNS TABLE(branch_id uuid, branch_name text, total_sales numeric, total_expenses numeric, operation_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    branch_sales AS (
      SELECT
        s.branch_id,
        -- RN-D — revenue de línea consistente: COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0) AS total_sales,
        -- RN-D — conteo de operaciones unificado: COALESCE(operation_id, id)
        -- para que las ventas legacy sin operation_id cuenten 1 c/u.
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT AS op_count
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.branch_id
    ),
    branch_expenses AS (
      SELECT
        e.branch_id,
        COALESCE(SUM(e.amount), 0) AS total_expenses
      FROM public.expenses e
      WHERE e.account_id = p_account_id
        AND e.date >= p_start::timestamptz
        AND e.date <  (p_end + 1)::timestamptz
      GROUP BY e.branch_id
    ),
    all_branch_ids AS (
      -- qa-integral-modulos (G4): calificado — sin el prefijo, branch_id
      -- colisiona con el parámetro OUT homónimo del RETURNS TABLE (42702).
      SELECT DISTINCT branch_sales.branch_id FROM branch_sales
      UNION
      SELECT DISTINCT branch_expenses.branch_id FROM branch_expenses
    )
  SELECT
    abi.branch_id,
    COALESCE(b.name, 'Sin sucursal')       AS branch_name,
    COALESCE(bs.total_sales, 0)            AS total_sales,
    COALESCE(be.total_expenses, 0)         AS total_expenses,
    COALESCE(bs.op_count, 0)              AS operation_count
  FROM all_branch_ids abi
  LEFT JOIN public.branches b  ON b.id = abi.branch_id
  LEFT JOIN branch_sales   bs  ON bs.branch_id IS NOT DISTINCT FROM abi.branch_id
  LEFT JOIN branch_expenses be ON be.branch_id IS NOT DISTINCT FROM abi.branch_id
  ORDER BY total_sales DESC NULLS LAST;
END;
$function$;

-- ACLs reafirmadas = estado vigente en prod (postgres/authenticated/service_role,
-- sin PUBLIC, sin anon — 20260824000001 revocó anon). CREATE OR REPLACE las
-- preserva; se reafirman igual por si un futuro DROP+CREATE las resetea.
REVOKE ALL     ON FUNCTION public.rpc_branch_report(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_branch_report(uuid, date, date) TO service_role;


-- =============================================================================
-- 2. rpc_product_profitability — fix 42804 (G8): el RETURNS TABLE declara
--    last_sale_date date pero el SELECT devolvía MAX(s.date) (timestamptz) →
--    "structure of query does not match function result type" en TODA
--    ejecución. FIX PUNTUAL (única diferencia con el baseline): cast
--    consciente de zona (MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date
--    — el mismo patrón que public.reporting_local_today() canoniza y que el
--    propio cuerpo ya usa para v_since_date (RN-D5). Un ::date desnudo
--    castearía con la TimeZone de sesión (UTC en Supabase) y una venta de
--    21:00–23:59 ART quedaría fechada el día siguiente (off-by-one que el
--    barrido 20260907000001 ya eliminó). Firma y tipo de retorno intactos.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_profitability(p_period_days integer DEFAULT 30)
 RETURNS TABLE(product_id uuid, product_name text, total_revenue numeric, total_cost numeric, gross_margin numeric, gross_margin_pct numeric, units_sold numeric, last_sale_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        UUID;
  v_account_id UUID;
  v_since_date DATE;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Derive the caller's active account (C-05 D7 pattern)
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- v3-reporting-invariants (RN-D5): ancla a la fecha LOCAL del tenant, no a
  -- CURRENT_DATE (UTC del servidor) — evita que la ventana corra un día
  -- antes entre las 21:00 y las 00:00 hora Argentina.
  v_since_date := public.reporting_local_today() - (p_period_days || ' days')::INTERVAL;

  -- v3-snapshot-pattern (D6, RN-D2): el costo por línea deriva del snapshot
  -- congelado en sale_items (unit_cost_snapshot), no del maestro actual.
  -- Cascada de fallback: (1) unit_cost_snapshot de la línea; (2) products.cost
  -- actual solo cuando el snapshot es NULL (líneas muy viejas no backfilleadas).
  -- CTEs avoid Cartesian product when aggregating two fact tables on the same key
  RETURN QUERY
  WITH
    sales_agg AS (
      SELECT
        s.product_id,
        -- v3-reporting-invariants (RN-D — revenue de línea consistente):
        -- COALESCE(total, amount), nunca amount solo (precio unitario).
        SUM(COALESCE(s.total, s.amount))                           AS total_revenue,
        SUM(s.quantity)                                            AS units_sold,
        -- qa-integral-modulos (G8): cast consciente de zona — el RETURNS TABLE
        -- declara date y s.date es timestamptz (42804 sin el cast).
        (MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date AS last_sale_date,
        SUM(COALESCE(si.unit_cost_snapshot, pr2.cost) * s.quantity) AS total_cost_snapshot,
        bool_or(si.unit_cost_snapshot IS NULL)                     AS any_missing_snapshot
      FROM   public.sales s
      JOIN   public.products pr2 ON pr2.id = s.product_id
      LEFT   JOIN public.sale_items si
             ON si.sale_id = s.id AND si.product_id = s.product_id
      WHERE  s.account_id   = v_account_id
        AND  s.product_id  IS NOT NULL
        AND  s.date        >= v_since_date
      GROUP  BY s.product_id
    )
  SELECT
    sa.product_id,
    pr.name                                                                   AS product_name,
    sa.total_revenue,
    sa.total_cost_snapshot                                                    AS total_cost,
    sa.total_revenue - sa.total_cost_snapshot                                 AS gross_margin,
    ROUND(
      (sa.total_revenue - sa.total_cost_snapshot)
      / NULLIF(sa.total_revenue, 0) * 100,
      2
    )                                                                         AS gross_margin_pct,
    sa.units_sold,
    sa.last_sale_date
  FROM   sales_agg         sa
  JOIN   public.products   pr ON pr.id          = sa.product_id
  ORDER  BY gross_margin_pct DESC NULLS LAST
  LIMIT  200;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_product_profitability(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_product_profitability(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_product_profitability(integer) TO service_role;


-- =============================================================================
-- 3. Backfill OQ-3 (H11 / G16 task 16.3) — motivo de los movimientos de caja
--    y banco generados por gastos desde el 2026-08-30 (gastos-forma-pago):
--    rpc_create_expense los escribía con description NULL. IDEMPOTENTE por
--    construcción: acotado por referencia al gasto vivo y description IS NULL
--    — la segunda pasada no matchea ninguna fila. Los movimientos cuyo gasto
--    ya fue borrado (rpc_delete_expense hace DELETE físico) no tienen fila en
--    expenses para joinear y quedan como están, por diseño: no hay fuente de
--    verdad de la que copiar el motivo. Medido en prod el 2026-08-31: 4 filas
--    de caja y 0 de banco con motivo NULL.
-- =============================================================================
UPDATE public.cash_movements cm
SET    description = e.description
FROM   public.expenses e
WHERE  e.id = cm.reference_id
  AND  cm.movement_type IN ('expense', 'expense_reversal')
  AND  cm.description IS NULL
  AND  e.description IS NOT NULL;

UPDATE public.bank_movements bm
SET    description = e.description
FROM   public.expenses e
WHERE  e.id = bm.source_doc_ref
  AND  bm.source_doc_type = 'expense'
  AND  bm.description IS NULL
  AND  e.description IS NOT NULL;


-- =============================================================================
-- 4. Gate ANTI-OVERLOAD (molde de 20260928000001 §9 / 20261015000001 §5): las
--    dos funciones se reescriben con CREATE OR REPLACE sobre su firma vigente
--    — si un cambio futuro alterara la lista de argumentos sin DROP, quedaría
--    un overload fantasma y la próxima llamada posicional reventaría con 42725.
-- =============================================================================
DO $$
DECLARE
  v_proname text;
  v_count   integer;
BEGIN
  FOREACH v_proname IN ARRAY ARRAY[
    'rpc_branch_report',
    'rpc_product_profitability'
  ] LOOP
    SELECT COUNT(*) INTO v_count
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE ANTI-OVERLOAD FAILED: % tiene % definiciones en public (esperaba exactamente 1) — quedó un overload fantasma y la próxima llamada posicional revienta con 42725.',
        v_proname, v_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'GATE ANTI-OVERLOAD PASSED: rpc_branch_report y rpc_product_profitability tienen exactamente 1 definición cada una.';
END $$;
