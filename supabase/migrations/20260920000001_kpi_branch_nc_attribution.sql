-- =============================================================================
-- MIGRATION: 20260920000001_kpi_branch_nc_attribution.sql
-- CHANGE:    kpi-branch-consistency — grupo 6 (D1/D2, OQ-1 FIRMADA por el PO
--            2026-08-12, rama HÍBRIDA — design.md §Open Questions §OQ-1).
--            Completa lo que 20260916000001 dejó bloqueado.
--
-- GOBERNANZA: MEDIO (lógica de negocio de reporting, solo lectura). No toca
-- write paths.
--
-- Timestamp: el MAX real en supabase_migrations.schema_migrations (prod,
-- verificado 2026-08-12) es 20260919000001 (analytics-events-backfill,
-- sesión paralela). Este archivo usa el siguiente slot libre, 20260920000001.
--
-- DECISIÓN OQ-1 (híbrida, design.md §Decisions D1/D2):
--   - A (atribuir por documento origen) para notas de crédito: son
--     factibles y baratas porque customer_account_movements.reference_id →
--     sales_orders.id y sales_orders.branch_id es NOT NULL (DEC-19) — el
--     join siempre resuelve para las NC que referencian una orden.
--   - B (nivel cuenta, sin filtrar) para el par cargos/cobros: los cobros
--     (payments_received.reference_sale_id) son nullable y en la práctica
--     NULL — no son atribuibles sin cambiar el modelo. Como
--     percibido = devengado − cargos + cobros es una identidad, filtrar
--     solo los cargos daría un número aritméticamente incoherente. Se
--     declara collected_revenue = NULL bajo filtro de sucursal en vez de
--     publicar una mezcla (RN-D3, requirement de filtro uniforme de
--     reporting-invariants).
--
-- FIX de esta migración:
--   1. public.reporting_credit_notes_in_window (D1): deja de ignorar
--      p_branch_id. Suma LEFT JOIN sales_orders + predicado
--      (p_branch_id IS NULL OR so.branch_id = p_branch_id). Fail-CLOSED:
--      una NC cuyo reference_id no resuelve a una sales_order (o cuya
--      sucursal no matchea el filtro) no resta en ESA sucursal, y sí resta
--      en la vista sin filtro. Firma sin cambios (D7).
--   2. public.get_dashboard_financials: SIN CAMBIOS DE CÓDIGO. Ya consume el
--      helper de forma genérica (20260916000001) — hereda la atribución
--      real automáticamente. Esta migración no la re-declara.
--   3. public.rpc_dashboard_kpi_summary (D2): collected_revenue y
--      prev_collected_revenue pasan a NULL cuando p_branch_id IS NOT NULL.
--      charges_agg/payments_agg SIGUEN sin filtrar (nivel cuenta, D2) — no
--      se toca su cálculo, solo se envuelve el resultado final en un CASE.
--      invoiced_revenue/prev_invoiced_revenue NO cambian: siguen
--      computándose filtrados (ya usaban el helper, que ahora sí atribuye).
--      Firma y RETURNS TABLE sin cambios (D7, CREATE OR REPLACE puro).
--
-- D7: CREATE OR REPLACE puro en ambos objetos — ni parámetros ni columnas de
-- RETURNS TABLE cambian. No aplica el gotcha 42725 de 20260913000001.
-- CREATE OR REPLACE preserva ACLs; se re-aplican REVOKE/GRANT explícitos
-- igual, por disciplina del backlog de advisors 0028.
--
-- IDEMPOTENCIA: la integración GitHub de Supabase auto-aplica migraciones al
-- mergear a main ANTES del `db push` de Actions. Esta migración es 100%
-- re-ejecutable: CREATE OR REPLACE en los dos objetos, REVOKE/GRANT
-- idempotentes, sin DDL de tablas.
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
--
-- ROLLBACK: re-aplicar el cuerpo de reporting_credit_notes_in_window y
-- rpc_dashboard_kpi_summary tal como quedaron en 20260916000001 (NC global,
-- collected_revenue siempre calculado) con CREATE OR REPLACE. Sin cambios de
-- datos ni de esquema.
-- =============================================================================


-- =============================================================================
-- 1. reporting_credit_notes_in_window — D1: atribución de NC por sucursal
-- =============================================================================
CREATE OR REPLACE FUNCTION public.reporting_credit_notes_in_window(
  p_account_id uuid,
  p_from       timestamptz,
  p_to         timestamptz,
  p_branch_id  uuid DEFAULT NULL
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
  -- kpi-branch-consistency (D1, grupo 6 — OQ-1 firmada 2026-08-12, rama
  -- HÍBRIDA): la NC se atribuye a la sucursal de su documento origen vía
  -- customer_account_movements.reference_id → sales_orders.id
  -- (sales_orders.branch_id es NOT NULL, DEC-19 — el join siempre resuelve
  -- para las NC que sí referencian una sales_order). Fail-CLOSED sobre
  -- referencias que no resuelven o no matchean: bajo filtro de sucursal, esa
  -- NC no resta en la sucursal filtrada; sí resta en la vista sin filtro
  -- (p_branch_id IS NULL — el LEFT JOIN no se descarta, solo el predicado de
  -- sucursal deja de aplicar).
  --
  -- El ledger de cta cte (C-30) guarda el DELTA firmado sobre el balance:
  -- una NC acredita al cliente, por lo que su `amount` vive NEGATIVO —
  -- ABS() para restar un monto positivo del revenue. Imputación por
  -- created_at (fecha de emisión de la NC, no de la venta original).
  SELECT COALESCE(SUM(ABS(cam.amount)), 0)
  FROM public.customer_account_movements cam
  LEFT JOIN public.sales_orders so ON so.id = cam.reference_id
  WHERE cam.account_id = p_account_id
    AND cam.movement_type = 'credit_note'
    AND cam.created_at BETWEEN p_from AND p_to
    AND (p_branch_id IS NULL OR so.branch_id = p_branch_id);
$$;

COMMENT ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) IS
  'kpi-branch-consistency (D1, grupo 6, OQ-1 híbrida firmada 2026-08-12): '
  'fuente única de la regla de notas de crédito (movement_type=credit_note, '
  'imputación por created_at, ABS(amount)) consumida por '
  'get_dashboard_financials y rpc_dashboard_kpi_summary. Atribuye la NC a la '
  'sucursal de su documento origen (reference_id -> sales_orders.branch_id, '
  'NOT NULL). Fail-closed: NC sin sales_order resuelta no resta bajo filtro '
  'de sucursal, sí resta sin filtro. Interna: solo la llaman funciones '
  'SECURITY DEFINER (REVOKE de anon/authenticated abajo).';

-- Interna: sin callers fuera de funciones SECURITY DEFINER, que ejecutan
-- como su owner y conservan EXECUTE aunque el rol del caller sea
-- `authenticated` (Paso 2 de v31-tenancy-pool-rls hace SET LOCAL ROLE
-- authenticated, y eso no afecta al cuerpo de una definer). No expuesta por
-- REST — evita el backlog de advisors 0028 y mantiene verde
-- test_function_acl_gate.sql.
REVOKE ALL     ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) FROM anon, authenticated;


-- =============================================================================
-- 2. rpc_dashboard_kpi_summary — D2: collected_revenue NULL bajo filtro de
--    sucursal. Base: cuerpo vigente de 20260916000001 (verificado: ninguna
--    migración posterior lo redefine). CREATE OR REPLACE puro (D7).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(
  net_profit numeric,
  prev_net_profit numeric,
  avg_ticket numeric,
  prev_avg_ticket numeric,
  cost_per_sale numeric,
  prev_cost_per_sale numeric,
  stagnant_stock_value numeric,
  stagnant_stock_count integer,
  prev_stagnant_stock_value numeric,
  prev_stagnant_stock_count integer,
  sales_count integer,
  prev_sales_count integer,
  invoiced_revenue numeric,
  prev_invoiced_revenue numeric,
  collected_revenue numeric,
  prev_collected_revenue numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      -- v3-snapshot-pattern (D6): COGS = snapshot congelado (via sale_items),
      -- fallback a pr.cost actual solo si la línea no tiene snapshot.
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(si.unit_cost_snapshot, pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    LEFT JOIN public.sale_items si
          ON  si.sale_id = s.id
          AND si.product_id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D1, grupo 6): la regla de NC —incluida la
  -- atribución de sucursal— vive en el helper único (D5) consumido también
  -- por get_dashboard_financials. p_branch_id ahora SÍ filtra (helper
  -- reescrito en esta migración).
  nc_agg AS (
    SELECT
      public.reporting_credit_notes_in_window(v_account_id, p_from,      p_to,      p_branch_id) AS nc,
      public.reporting_credit_notes_in_window(v_account_id, p_prev_from, p_prev_to, p_branch_id) AS prev_nc
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cargos a cuenta corriente del período. SIGUEN sin filtrar por sucursal
  -- (nivel cuenta) — no son la causa de collected_revenue = NULL bajo
  -- filtro, pero tampoco se filtran: ver el CASE del SELECT final.
  charges_agg AS (
    SELECT
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_from      AND p_to),      0) AS charges,
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_charges
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'sale'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3) / kpi-branch-consistency (D2, grupo 6):
  -- cobros del período. payments_received no tiene sucursal atribuible
  -- (reference_sale_id opcional y en la práctica NULL) — no filtrable.
  payments_agg AS (
    SELECT
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_from      AND p_to),      0) AS payments,
      COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_payments
    FROM public.payments_received pr_
    WHERE pr_.account_id = v_account_id
      AND pr_.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D3, grupo 5): stock sin rotación por sucursal
  -- sobre branch_stock. Sin cambios en esta migración.
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_from AND p_to
          -- kpi-branch-consistency (D4): fail-open sobre ventas legacy sin
          -- sucursal. 75% de las filas de `sales` en producción tienen
          -- branch_id NULL (medido 2026-08-11) — una venta legacy es
          -- evidencia REAL de rotación y no se puede duplicar (EXISTS, no
          -- SUM); fail-closed marcaría como "sin rotación" a casi todo el
          -- catálogo apenas se selecciona una sucursal.
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(bs.quantity * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(DISTINCT bs.product_id)::integer               AS cnt
    FROM public.branch_stock bs
    JOIN public.products p ON p.id = bs.product_id
    WHERE bs.account_id = v_account_id
      AND bs.quantity > 0
      AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id)
      AND p.deleted_at IS NULL
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = bs.product_id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
          AND (p_branch_id IS NULL OR sx.branch_id = p_branch_id OR sx.branch_id IS NULL)
      )
  )
  SELECT
    (sa.revenue - na.nc)      - (ea.expenses      + pa.purchases)       AS net_profit,
    (sa.prev_revenue - na.prev_nc) - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count,
    -- v3-reporting-invariants (RN-D3): devengado neto de NC, filtrado por
    -- sucursal (el helper ya atribuye — D1, grupo 6).
    (sa.revenue - na.nc)                                      AS invoiced_revenue,
    (sa.prev_revenue - na.prev_nc)                            AS prev_invoiced_revenue,
    -- kpi-branch-consistency (D2, grupo 6): collected_revenue no es
    -- computable por sucursal — payments_received no tiene branch_id
    -- atribuible (reference_sale_id opcional y en la práctica NULL), y
    -- percibido = devengado - cargos + cobros es una identidad cuyos tres
    -- términos deben vivir en el mismo universo. Bajo filtro de sucursal se
    -- declara NULL (requirement de filtro uniforme, reporting-invariants)
    -- en vez de mezclar un devengado filtrado con cargos/cobros de toda la
    -- cuenta. Sin filtro, comportamiento sin cambios.
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.revenue - na.nc) - ca.charges + pay.payments
    END                                                        AS collected_revenue,
    CASE WHEN p_branch_id IS NOT NULL THEN NULL
         ELSE (sa.prev_revenue - na.prev_nc) - ca.prev_charges + pay.prev_payments
    END                                                        AS prev_collected_revenue
  FROM sales_agg sa
  CROSS JOIN nc_agg        na
  CROSS JOIN charges_agg   ca
  CROSS JOIN payments_agg  pay
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid) IS
  'kpi-branch-consistency (grupo 6, OQ-1 híbrida firmada 2026-08-12): '
  'nc_agg hereda la atribución de sucursal real del helper (D1). '
  'collected_revenue/prev_collected_revenue son NULL cuando p_branch_id IS '
  'NOT NULL (D2 — cargos/cobros quedan a nivel cuenta, no atribuibles). '
  'Stock sin rotación (D3/D4) y firma sin cambios respecto a 20260916000001 '
  '(D7, CREATE OR REPLACE puro).';


-- =============================================================================
-- 3. Gate de introspección (corre SIEMPRE, incluso en prod) — verifica que
--    los cuerpos nuevos contengan los predicados clave del fix. Barato
--    (regex sobre pg_get_functiondef); detecta un CREATE OR REPLACE
--    aplicado a medias o drift entre esta migración y el catálogo real.
-- =============================================================================
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporting_credit_notes_in_window';

  IF v_def IS NULL OR v_def NOT LIKE '%sales_orders%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: reporting_credit_notes_in_window no atribuye NC por sucursal vía sales_orders (D1, grupo 6).';
  END IF;
  IF v_def NOT LIKE '%so.branch_id = p_branch_id%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: reporting_credit_notes_in_window no filtra por so.branch_id (D1, grupo 6).';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_dashboard_kpi_summary';

  IF v_def IS NULL OR v_def NOT LIKE '%p_branch_id IS NOT NULL THEN NULL%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no devuelve collected_revenue NULL bajo filtro de sucursal (D2, grupo 6).';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: reporting_credit_notes_in_window atribuye NC por sucursal vía sales_orders (D1); rpc_dashboard_kpi_summary devuelve collected_revenue NULL bajo filtro (D2).';
END $$;

-- =============================================================================
-- END OF MIGRATION 20260920000001_kpi_branch_nc_attribution.sql
-- =============================================================================
