-- =============================================================================
-- MIGRATION: 20260916000001_kpi_branch_consistency.sql
-- CHANGE:    kpi-branch-consistency — APLICACIÓN PARCIAL (grupos 1-5, 7 de
--            tasks.md). El grupo 6 (atribución de NC por sucursal, D1/D2)
--            queda BLOQUEADO por el sign-off explícito del PO sobre OQ-1
--            (design.md §Open Questions) y NO se implementa en esta
--            migración — ver openspec/changes/kpi-branch-consistency/.
--
-- GOBERNANZA: MEDIO (lógica de negocio de reporting, solo lectura). No toca
-- write paths.
--
-- Timestamp: la propuesta original planeaba 20260914000001, pero ese slot lo
-- tomó #383 (analytics-events-revival, ya en main). Se usa 20260916000001
-- (20260915 queda reservado para un backfill de analytics no relacionado).
--
-- PROBLEMA (verificado 2026-08-11 contra la definición vigente
-- 20260814000001 + 20260610000001, ver proposal.md/design.md):
--   F3a — en el mensual (rpc_dashboard_kpi_summary), sales_agg/expenses_agg/
--     purchases_agg filtran p_branch_id; nc_agg, charges_agg, payments_agg y
--     stagnant_curr/stagnant_prev NO. El stock sin rotación valoriza el
--     agregado de TODAS las sucursales sin importar el filtro, e ignora
--     productos soft-deleted (defecto latente adicional).
--   F3b — en el diario (get_dashboard_financials), las tres CTEs sí filtran
--     sucursal, pero net_profit = ingresos − (gastos + compras): NO resta
--     notas de crédito. El mensual sí las resta. Diario y mensual disienten
--     sobre la misma ventana — nada en CI lo detecta.
--
-- FIX (esta migración — SOLO lo no bloqueado por OQ-1):
--   1. Helper nuevo public.reporting_credit_notes_in_window(p_account_id,
--      p_from, p_to, p_branch_id) — única fuente de la regla de NC (D5),
--      consumida por AMBOS RPCs. p_branch_id se ACEPTA pero se IGNORA
--      mientras OQ-1 no esté firmada (task 3.2): la NC resta GLOBAL en
--      ambos, que es exactamente la semántica vigente hoy del mensual — el
--      diario se ALINEA a ella, no se inventa una semántica nueva. Cuando
--      OQ-1 se firme (grupo 6, change separado o continuación de este), el
--      helper gana el JOIN a sales_orders y el predicado de sucursal, y
--      ningún consumidor cambia.
--   2. get_dashboard_financials (D6): total_income = Σ COALESCE(total,
--      amount) − NC(ventana); net_profit = total_income − (gastos +
--      compras). Antes: net_profit no restaba NC. Firma sin cambios.
--   3. rpc_dashboard_kpi_summary: nc_agg pasa a consumir el helper (D5,
--      mismo resultado numérico que el nc_agg inline que reemplaza — no hay
--      cambio de comportamiento acá, es la unificación de la fuente).
--      stagnant_curr/stagnant_prev (D3/D4) se reescriben sobre
--      branch_stock (fila por sucursal) en vez de v_products_with_stock
--      (agregado): value = SUM(bs.quantity * cost) y cnt =
--      COUNT(DISTINCT product_id) de las filas que matchean p_branch_id (o
--      todas si NULL); se agrega exclusión de deleted_at IS NOT NULL
--      (defecto latente corregido); el NOT EXISTS de rotación gana
--      fail-open D4: con filtro, una venta cuenta como evidencia de
--      rotación si sx.branch_id = p_branch_id OR sx.branch_id IS NULL (75%
--      de sales en prod son legacy sin sucursal — fail-closed marcaría casi
--      todo el catálogo como estancado). Firma y RETURNS TABLE sin cambios.
--
-- D7: CREATE OR REPLACE puro en los dos RPCs — ni parámetros de entrada ni
-- columnas de RETURNS TABLE cambian. NO aplica el gotcha 42725 de
-- 20260913000001 (agregar un parámetro con CREATE OR REPLACE crea un
-- segundo overload) porque no se agrega ningún parámetro. CREATE OR REPLACE
-- preserva ACLs, pero se re-aplican REVOKE/GRANT explícitos igual, por
-- disciplina del backlog de advisors 0028.
--
-- FUERA DE ALCANCE DE ESTA MIGRACIÓN (grupo 6, tasks.md): atribución de NC
-- por sucursal (D1) y collected_revenue = NULL bajo filtro (D2). Ambos
-- documentados en design.md/specs pero NO implementados — bloqueados por
-- OQ-1. charges_agg/payments_agg quedan intactos (sin tocar).
--
-- IDEMPOTENCIA: la integración GitHub de Supabase auto-aplica migraciones al
-- mergear a main ANTES del `db push` de Actions. Esta migración es 100%
-- re-ejecutable: CREATE OR REPLACE en los tres objetos, REVOKE/GRANT
-- idempotentes, sin DDL de tablas.
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
--
-- ROLLBACK: re-aplicar el cuerpo vigente de 20260814000001 §5 (nc_agg
-- inline + stagnant sobre v_products_with_stock) y de 20260610000001 (sin
-- resta de NC) con CREATE OR REPLACE. DROP FUNCTION del helper (sin
-- callers fuera de estos dos RPCs). Sin cambios de datos ni de esquema.
-- =============================================================================


-- =============================================================================
-- 1. Helper único de notas de crédito (D5, task 3.2)
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
  -- kpi-branch-consistency (D5): fuente única de la regla de NC, consumida
  -- por get_dashboard_financials y rpc_dashboard_kpi_summary. El ledger de
  -- cta cte (C-30) guarda el DELTA firmado sobre el balance: una NC acredita
  -- al cliente, por lo que su `amount` vive NEGATIVO — ABS() para restar un
  -- monto positivo del revenue. Imputación por created_at (fecha de emisión
  -- de la NC, no de la venta original).
  --
  -- p_branch_id se ACEPTA pero se IGNORA (task 3.2): la atribución de NC por
  -- sucursal (D1, grupo 6 de tasks.md) está BLOQUEADA por el sign-off del PO
  -- sobre OQ-1 (design.md §Open Questions). Mientras no se firme, la NC
  -- resta GLOBAL en ambos read-models — misma semántica que ya tenía el
  -- mensual antes de este change. Cuando OQ-1 se firme, acá se agrega
  -- LEFT JOIN public.sales_orders so ON so.id = cam.reference_id y el
  -- predicado (p_branch_id IS NULL OR so.branch_id = p_branch_id), sin
  -- tocar ningún consumidor (esa es la razón de ser del helper único).
  SELECT COALESCE(SUM(ABS(cam.amount)), 0)
  FROM public.customer_account_movements cam
  WHERE cam.account_id = p_account_id
    AND cam.movement_type = 'credit_note'
    AND cam.created_at BETWEEN p_from AND p_to;
$$;

COMMENT ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) IS
  'kpi-branch-consistency (D5): fuente única de la regla de notas de crédito '
  '(movement_type=credit_note, imputación por created_at, ABS(amount)) '
  'consumida por get_dashboard_financials y rpc_dashboard_kpi_summary. '
  'p_branch_id se acepta pero se ignora mientras OQ-1 no esté firmada (grupo '
  '6 de tasks.md, atribución de NC por sucursal vía sales_orders.branch_id) '
  '— la NC resta global en ambos read-models. Interna: solo la llaman '
  'funciones SECURITY DEFINER (REVOKE de anon/authenticated abajo).';

-- Interna: sin callers fuera de funciones SECURITY DEFINER, que ejecutan
-- como su owner y conservan EXECUTE aunque el rol del caller sea
-- `authenticated` (Paso 2 de v31-tenancy-pool-rls hace SET LOCAL ROLE
-- authenticated, y eso no afecta al cuerpo de una definer). No expuesta por
-- REST — evita el backlog de advisors 0028 y mantiene verde
-- test_function_acl_gate.sql.
REVOKE ALL     ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reporting_credit_notes_in_window(uuid, timestamptz, timestamptz, uuid) FROM anon, authenticated;


-- =============================================================================
-- 2. get_dashboard_financials — Parte B, diario deja de disentir (D6, grupo 4)
--    Base: cuerpo vigente 20260610000001 (verificado: ninguna migración
--    posterior lo redefine). Firma sin cambios.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_financials(
  p_date_from  timestamptz,
  p_date_to    timestamptz,
  p_branch_id  uuid DEFAULT NULL
)
RETURNS TABLE (
  total_income    numeric,
  total_expenses  numeric,
  total_purchases numeric,
  net_profit      numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_date_from > p_date_to THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, 0::numeric;
    RETURN;
  END IF;

  RETURN QUERY
  WITH ingresos AS (
    SELECT COALESCE(SUM(COALESCE(total, amount)), 0) AS total
    FROM public.sales
    WHERE account_id IN (SELECT current_account_ids())
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  -- kpi-branch-consistency (D6): notas de crédito del período restan del
  -- devengado, vía el helper único D5. Se suma por cuenta porque
  -- current_account_ids() puede en teoría devolver más de una fila (aunque
  -- hoy la tenancy es única, OQ-2) y el helper toma un solo account_id.
  notas_credito AS (
    SELECT COALESCE(SUM(public.reporting_credit_notes_in_window(cai, p_date_from, p_date_to, p_branch_id)), 0) AS total
    FROM current_account_ids() AS cai
  ),
  gastos AS (
    SELECT COALESCE(SUM(amount), 0) AS total
    FROM public.expenses
    WHERE account_id IN (SELECT current_account_ids())
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ),
  compras AS (
    SELECT COALESCE(SUM(COALESCE(total, amount)), 0) AS total
    FROM public.purchases
    WHERE account_id IN (SELECT current_account_ids())
      AND date >= p_date_from
      AND date <= p_date_to
      AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  )
  SELECT
    (i.total - n.total)                          AS total_income,
    g.total                                       AS total_expenses,
    c.total                                       AS total_purchases,
    ((i.total - n.total) - (g.total + c.total))   AS net_profit
  FROM ingresos i
  CROSS JOIN notas_credito n
  CROSS JOIN gastos g
  CROSS JOIN compras c;
END;
$$;

REVOKE ALL     ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz, uuid) TO authenticated;

COMMENT ON FUNCTION public.get_dashboard_financials(timestamptz, timestamptz, uuid) IS
  'kpi-branch-consistency (D6): total_income y net_profit ahora netos de '
  'notas de crédito del período (public.reporting_credit_notes_in_window, '
  'D5) — mismo helper que consume rpc_dashboard_kpi_summary, para que el '
  'diario y el mensual coincidan sobre la misma ventana. Antes solo restaba '
  'gastos y compras. Firma sin cambios.';


-- =============================================================================
-- 3. rpc_dashboard_kpi_summary — nc_agg vía helper + stock sin rotación por
--    sucursal (grupo 5, D3/D4/D5). Base: cuerpo vigente 20260814000001 §5
--    (verificado: ninguna migración posterior lo redefine). CREATE OR
--    REPLACE puro (D7): ni parámetros ni columnas de RETURNS TABLE cambian
--    — a diferencia de 20260814000001, que sí agregaba columnas y necesitó
--    DROP+CREATE.
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
  -- kpi-branch-consistency (D5, task 5.3): la regla de NC vive en el helper
  -- único consumido también por get_dashboard_financials — mismo resultado
  -- numérico que el nc_agg inline que reemplaza (p_branch_id se ignora
  -- mientras OQ-1 no esté firmada, ver comentario del helper). Sin cambio de
  -- comportamiento acá: es la unificación de la fuente (grupo 6, D1,
  -- bloqueado por OQ-1, agregaría el filtro real de sucursal adentro del
  -- helper sin tocar esta CTE).
  nc_agg AS (
    SELECT
      public.reporting_credit_notes_in_window(v_account_id, p_from,      p_to,      p_branch_id) AS nc,
      public.reporting_credit_notes_in_window(v_account_id, p_prev_from, p_prev_to, p_branch_id) AS prev_nc
  ),
  -- v3-reporting-invariants (RN-D3): cargos a cuenta corriente del período
  -- difieren el cobro (venta devengada pero no percibida todavía). Sin
  -- cambios en este change (D2, grupo 6, bloqueado por OQ-1: el par
  -- cargos/cobros sigue a nivel cuenta).
  charges_agg AS (
    SELECT
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_from      AND p_to),      0) AS charges,
      COALESCE(SUM(cam.amount) FILTER (WHERE cam.amount > 0 AND cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_charges
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'sale'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3): cobros del período percibidos en el
  -- período del cobro (semántica de caja), sin importar cuándo se vendió.
  -- Sin cambios en este change (D2, grupo 6, bloqueado por OQ-1).
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
  -- kpi-branch-consistency (D3, grupo 5): stock sin rotación reescrito sobre
  -- branch_stock (fila por sucursal), no sobre el agregado
  -- v_products_with_stock (F3a). value = SUM(qty de la sucursal filtrada, o
  -- de todas si p_branch_id IS NULL, × costo); cnt = COUNT(DISTINCT
  -- product_id) — un producto sin rotación en dos sucursales cuenta una vez
  -- en la vista agregada (mismo criterio D2 de 20260913000001). Se agrega
  -- exclusión de deleted_at IS NOT NULL (defecto latente del CTE vigente,
  -- corregido acá porque el CTE se reescribe igual).
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
    -- v3-reporting-invariants (RN-D3): devengado neto de NC.
    (sa.revenue - na.nc)                                      AS invoiced_revenue,
    (sa.prev_revenue - na.prev_nc)                            AS prev_invoiced_revenue,
    -- v3-reporting-invariants (RN-D3): percibido = devengado − cargos cta
    -- cte del período + cobros del período (semántica de caja). Sin cambios
    -- en este change (D2, grupo 6, bloqueado por OQ-1).
    (sa.revenue - na.nc) - ca.charges + pay.payments                    AS collected_revenue,
    (sa.prev_revenue - na.prev_nc) - ca.prev_charges + pay.prev_payments AS prev_collected_revenue
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
  'kpi-branch-consistency: nc_agg consume el helper único '
  'reporting_credit_notes_in_window (D5, mismo diario y mensual). Stock sin '
  'rotación (stagnant_curr/prev) reescrito sobre branch_stock por sucursal '
  '(D3), excluye soft-deleted, y el NOT EXISTS de rotación es fail-open '
  'sobre ventas legacy sin sucursal (D4). Atribución de NC por sucursal '
  '(D1/D2) queda BLOQUEADA por OQ-1 — charges_agg/payments_agg/collected_revenue '
  'sin cambios. Firma y RETURNS TABLE sin cambios (D7, CREATE OR REPLACE puro).';


-- =============================================================================
-- 4. Gate de introspección (corre SIEMPRE, incluso en prod) — verifica que
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
  WHERE n.nspname = 'public' AND p.proname = 'get_dashboard_financials';

  IF v_def IS NULL OR v_def NOT LIKE '%reporting_credit_notes_in_window%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: get_dashboard_financials no consume reporting_credit_notes_in_window (D6).';
  END IF;

  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_dashboard_kpi_summary';

  IF v_def IS NULL OR v_def NOT LIKE '%reporting_credit_notes_in_window%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no consume reporting_credit_notes_in_window (D5).';
  END IF;
  IF v_def NOT LIKE '%branch_stock bs%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no calcula stock sin rotación sobre branch_stock (D3).';
  END IF;
  IF v_def NOT LIKE '%p.deleted_at IS NULL%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no excluye productos soft-deleted del stock sin rotación (D3).';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: get_dashboard_financials y rpc_dashboard_kpi_summary consumen reporting_credit_notes_in_window; stock sin rotación reescrito sobre branch_stock con exclusión soft-delete.';
END $$;

-- =============================================================================
-- END OF MIGRATION 20260916000001_kpi_branch_consistency.sql
-- =============================================================================
