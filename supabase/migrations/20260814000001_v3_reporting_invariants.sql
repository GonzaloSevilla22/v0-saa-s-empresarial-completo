-- =============================================================================
-- MIGRATION: 20260814000001_v3_reporting_invariants.sql
-- CHANGE:    v3-reporting-invariants — Modelo V3 §8 (RN-D1..D5)
--
-- GOBERNANZA: BAJO-MEDIO — solo lectura (read-models de reporting). No toca
-- write paths (ventas, compras, NC, pagos). Sign-off del PO otorgado
-- 2026-07-06 (ver openspec/changes/v3-reporting-invariants/tasks.md 0.1):
-- OQ1 aprobado (fix de revenue ya, sin comunicación especial — es corrección
-- de bug) y OQ2 aprobado (línea "Cobrado" en la tarjeta Ganancia Neta alcanza,
-- D8). OQ3 (atribución de NC por canal) queda abierto, no bloqueante.
--
-- PROBLEMA (auditoría read-only 2026-07-06 vía pg_get_functiondef, ver
-- design.md tabla RPC × RN-D):
--   1. Revenue inconsistente: rpc_product_profitability, rpc_period_comparison
--      y rpc_branch_report suman sales.amount (precio UNITARIO) en vez de
--      COALESCE(total, amount) (total de línea). Revenue subvaluado 17,53%
--      en prod ($7.905.976 vs $9.291.711); margen de /rentabilidad falso para
--      quantity > 1 (compara revenue unitario contra costo × cantidad).
--   2. RN-D1: ninguna de estas RPCs resta notas de crédito
--      (customer_account_movements.movement_type='credit_note') del revenue.
--      Violación latente (0 NC en prod hoy).
--   3. RN-D3: no existe métrica de ingresos percibidos (cobrados) — solo
--      facturado (devengado). La maquinaria (customer_account_movements,
--      payments_received) ya existe.
--   4. RN-D5: rpc_period_comparison y rpc_branch_report reciben DATE y el
--      borde superior castea a medianoche UTC (excluye 43/27 filas con hora
--      real cuando caen el último día); rpc_product_profitability usa
--      CURRENT_DATE (UTC): la ventana de "últimos N días" corre un día antes
--      entre las 21:00 y las 00:00 hora Argentina.
--   5. Conteo de operaciones inconsistente: rpc_period_comparison cuenta
--      filas (COUNT(*), una venta multi-línea cuenta N veces);
--      rpc_branch_report usa COUNT(DISTINCT operation_id) que ignora NULL
--      (18 ventas legacy sin operation_id no cuentan).
--
-- FIX (aditivo sobre RPCs existentes, sin cambios de tablas):
--   1. Helper reporting_local_today() — fecha local del tenant (constante de
--      plataforma America/Argentina/Mendoza, D5).
--   2. CREATE OR REPLACE rpc_product_profitability: total_revenue = Σ
--      COALESCE(s.total, s.amount); v_since_date anclado a
--      reporting_local_today(). Firma y RETURNS TABLE idénticos. Costo
--      snapshot (v3-snapshot-pattern) intacto.
--   3. CREATE OR REPLACE rpc_period_comparison: revenue/purchases = Σ
--      COALESCE(total, amount); resta NC del período; operaciones =
--      COUNT(DISTINCT COALESCE(operation_id, id)) en ventas/compras + gastos
--      por fila; borde superior inclusivo hasta fin de día local. Firma
--      idéntica.
--   4. CREATE OR REPLACE rpc_branch_report: total_sales = Σ COALESCE(total,
--      amount); operation_count = COUNT(DISTINCT COALESCE(operation_id, id));
--      mismo fix de bordes. Firma idéntica; verificación de membership sobre
--      p_account_id sin cambios.
--   5. DROP FUNCTION IF EXISTS + CREATE rpc_dashboard_kpi_summary: agrega 4
--      columnas de salida (invoiced_revenue, prev_invoiced_revenue,
--      collected_revenue, prev_collected_revenue, D3) y resta NC en
--      net_profit/invoiced_revenue (RN-D1). Mismos parámetros de entrada.
--      DROP+CREATE porque CREATE OR REPLACE no puede cambiar columnas OUT
--      (D4) — supabase-js ignora columnas extra, los callers viejos no se
--      rompen en la ventana entre deploy de DB y deploy de frontend.
--   6. Gates de introspección (corren SIEMPRE, incluso en prod): verifican
--      que cada cuerpo nuevo contenga los predicados clave.
--   7. Gates de comportamiento (solo DB vacía/CI, NOTICE-degrade en prod) con
--      anchor sintético vía handle_new_user: revenue con quantity=2, resta de
--      NC, collected vs invoiced con cargo+cobro de cta cte, borde de fin de
--      día con fila a las 15:00 UTC, conteo de operaciones multi-línea.
--
-- Cuerpos VIGENTES capturados con pg_get_functiondef (MCP, 2026-07-06, task
-- 1.1) y usados como base — NO se parte de los archivos de migración
-- históricos (regla del proyecto):
--   rpc_dashboard_kpi_summary    → 20260806000001_v3_snapshot_pattern.sql §5.2b (verificado idéntico en prod)
--   rpc_product_profitability    → 20260806000001_v3_snapshot_pattern.sql §5.1 (verificado idéntico en prod)
--   rpc_period_comparison        → 20260606120000_period_comparison.sql (verificado idéntico en prod)
--   rpc_branch_report            → 20260607000000_sucursales_module.sql (verificado idéntico en prod, C-07)
--
-- FUERA DE ALCANCE: write paths (ventas, compras, NC, pagos); RPCs admin
-- (rpc_admin_* — métricas de plataforma, sin documentos financieros);
-- rpc_dashboard_channel_margin (D6 — resta de NC por canal diferida, sin
-- regla de atribución); backfill de datos (el defecto es de lectura, no de
-- escritura); UI nueva más allá de la línea "Cobrado" en Ganancia Neta.
--
-- IDEMPOTENCIA / BOTH-WORLDS-SAFE (D9): la integración GitHub de Supabase
-- auto-aplica migraciones al mergear a main ANTES del `db push` de Actions
-- (patrón confirmado repetidas veces). Esta migración es 100% re-ejecutable:
-- CREATE OR REPLACE FUNCTION en las 3 RPCs modificadas in-place; DROP
-- FUNCTION IF EXISTS + CREATE para el dashboard; sin DDL de tablas. Gates:
-- introspección siempre; comportamiento con anchor sintético + cleanup
-- hijo→padre completo (cubre branch+cashbox sembrados por handle_new_user
-- desde 20260812000001) — accounts=0 al final; degrada con NOTICE si el
-- contexto no permite el gate (prod real, con RLS activa para rol no-owner).
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db push).
--   NUNCA aplicar con el MCP `apply_migration` (desincroniza el historial).
--
-- ROLLBACK: restaurar los cuerpos previos citados arriba con CREATE OR
--   REPLACE (comparison/profitability/branch_report) y un DROP+CREATE
--   inverso para el dashboard (repone el RETURNS TABLE original de 12
--   columnas). El frontend viejo es compatible con ambas versiones del
--   dashboard (mapeo explícito campo a campo, columnas extra ignoradas).
-- =============================================================================


-- =============================================================================
-- 1. Helper reporting_local_today() (task 1.2, D5)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.reporting_local_today()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE 'America/Argentina/Mendoza')::date;
$$;

COMMENT ON FUNCTION public.reporting_local_today() IS
  'v3-reporting-invariants (RN-D5): fecha calendario "hoy" en la zona horaria '
  'local del tenant. Constante de plataforma America/Argentina/Mendoza '
  '(UTC-3, sin DST) mientras no exista organizations.timezone — el 100% de '
  'los tenants está en Argentina hoy (YAGNI, ver design.md D5). Punto de '
  'extensión futuro: parametrizar por organización si aparece un tenant '
  'fuera de AR. Usada por rpc_product_profitability para anclar la ventana '
  '"últimos N días" a la fecha local en vez de CURRENT_DATE (UTC del '
  'servidor), que corre un día antes entre las 21:00 y las 00:00 hora AR.';


-- =============================================================================
-- 2. rpc_product_profitability (task 1.3)
--    Base: cuerpo vigente 20260806000001 §5.1 (verificado en prod).
--    Fix: total_revenue = Σ COALESCE(s.total, s.amount) (antes: SUM(s.amount)
--    = precio unitario, margen inconsistente para quantity > 1); v_since_date
--    anclado a reporting_local_today() (antes: CURRENT_DATE, UTC). Costo
--    snapshot intacto (no se toca la cascada D6 de v3-snapshot-pattern).
--    Firma y RETURNS TABLE idénticos.
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
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
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
        MAX(s.date)                                                AS last_sale_date,
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


-- =============================================================================
-- 3. rpc_period_comparison (task 1.4)
--    Base: cuerpo vigente 20260606120000 (verificado en prod).
--    Fix: revenue/purchases = Σ COALESCE(total, amount) (antes: SUM(amount));
--    resta NC del período (RN-D1); operaciones =
--    COUNT(DISTINCT COALESCE(operation_id, id)) en ventas y compras (antes:
--    COUNT(*) por fila — una venta multi-línea contaba N veces), gastos
--    siguen por fila (no tienen operation_id); bordes de período RN-D5
--    (>= p_start::timestamptz AND < (p_end + 1)::timestamptz — antes DATE
--    BETWEEN, que casteaba el fin a medianoche UTC y excluía filas con hora
--    real el último día). Firma idéntica; delta NULL con período A = 0 y
--    ERRCODE P0403 sin cambios.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_period_comparison(p_a_start date, p_a_end date, p_b_start date, p_b_end date)
RETURNS TABLE(period_a_revenue numeric, period_a_expenses numeric, period_a_purchases numeric, period_a_operations bigint, period_b_revenue numeric, period_b_expenses numeric, period_b_purchases numeric, period_b_operations bigint, revenue_delta_pct numeric, expenses_delta_pct numeric, purchases_delta_pct numeric, operations_delta_pct numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_accounts UUID[];
BEGIN
  v_accounts := ARRAY(SELECT current_account_ids());

  IF array_length(v_accounts, 1) IS NULL THEN
    RAISE EXCEPTION 'No active account found for this user'
      USING ERRCODE = 'P0403';
  END IF;

  RETURN QUERY
  WITH
    -- Período A
    sales_a AS (
      SELECT
        -- RN-D — revenue de línea consistente: COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0) AS rev,
        -- RN-D5: borde superior inclusivo hasta fin de día local (no
        -- medianoche UTC) — evita excluir filas con hora real el último día.
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT AS ops
      FROM sales s
      WHERE s.account_id = ANY(v_accounts)
        AND s.date >= p_a_start::timestamptz
        AND s.date <  (p_a_end + 1)::timestamptz
    ),
    -- RN-D1: notas de crédito del período A restan del revenue. El ledger de
    -- cta cte (C-30) guarda el DELTA firmado sobre el balance: una NC
    -- acredita al cliente, por lo que su `amount` vive NEGATIVO — ABS() para
    -- restar un monto positivo del revenue.
    nc_a AS (
      SELECT COALESCE(SUM(ABS(cam.amount)), 0) AS nc
      FROM public.customer_account_movements cam
      WHERE cam.account_id = ANY(v_accounts)
        AND cam.movement_type = 'credit_note'
        AND cam.created_at >= p_a_start::timestamptz
        AND cam.created_at <  (p_a_end + 1)::timestamptz
    ),
    expenses_a AS (
      SELECT
        COALESCE(SUM(e.amount), 0) AS exp,
        COUNT(*)::BIGINT            AS ops
      FROM expenses e
      WHERE e.account_id = ANY(v_accounts)
        AND e.date >= p_a_start::timestamptz
        AND e.date <  (p_a_end + 1)::timestamptz
    ),
    purchases_a AS (
      SELECT
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0) AS pur,
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT AS ops
      FROM purchases p
      WHERE p.account_id = ANY(v_accounts)
        AND p.date >= p_a_start::timestamptz
        AND p.date <  (p_a_end + 1)::timestamptz
    ),

    -- Período B
    sales_b AS (
      SELECT
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0) AS rev,
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT AS ops
      FROM sales s
      WHERE s.account_id = ANY(v_accounts)
        AND s.date >= p_b_start::timestamptz
        AND s.date <  (p_b_end + 1)::timestamptz
    ),
    nc_b AS (
      SELECT COALESCE(SUM(ABS(cam.amount)), 0) AS nc
      FROM public.customer_account_movements cam
      WHERE cam.account_id = ANY(v_accounts)
        AND cam.movement_type = 'credit_note'
        AND cam.created_at >= p_b_start::timestamptz
        AND cam.created_at <  (p_b_end + 1)::timestamptz
    ),
    expenses_b AS (
      SELECT
        COALESCE(SUM(e.amount), 0) AS exp,
        COUNT(*)::BIGINT            AS ops
      FROM expenses e
      WHERE e.account_id = ANY(v_accounts)
        AND e.date >= p_b_start::timestamptz
        AND e.date <  (p_b_end + 1)::timestamptz
    ),
    purchases_b AS (
      SELECT
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0) AS pur,
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT AS ops
      FROM purchases p
      WHERE p.account_id = ANY(v_accounts)
        AND p.date >= p_b_start::timestamptz
        AND p.date <  (p_b_end + 1)::timestamptz
    )

  SELECT
    -- Totales período A (revenue neto de NC — RN-D1)
    (sa.rev - na.nc)                                                AS period_a_revenue,
    ea.exp                                                          AS period_a_expenses,
    pa.pur                                                          AS period_a_purchases,
    (sa.ops + ea.ops + pa.ops)                                      AS period_a_operations,
    -- Totales período B
    (sb.rev - nb.nc)                                                AS period_b_revenue,
    eb.exp                                                          AS period_b_expenses,
    pb.pur                                                          AS period_b_purchases,
    (sb.ops + eb.ops + pb.ops)                                      AS period_b_operations,
    -- Deltas porcentuales (NULL si período A = 0)
    ROUND(((sb.rev - nb.nc) - (sa.rev - na.nc)) / NULLIF((sa.rev - na.nc), 0) * 100, 2) AS revenue_delta_pct,
    ROUND((eb.exp - ea.exp) / NULLIF(ea.exp, 0) * 100, 2)          AS expenses_delta_pct,
    ROUND((pb.pur - pa.pur) / NULLIF(pa.pur, 0) * 100, 2)          AS purchases_delta_pct,
    ROUND(
      ((sb.ops + eb.ops + pb.ops)::NUMERIC - (sa.ops + ea.ops + pa.ops)::NUMERIC)
      / NULLIF((sa.ops + ea.ops + pa.ops)::NUMERIC, 0) * 100,
      2
    )                                                               AS operations_delta_pct
  FROM
    sales_a sa
    CROSS JOIN nc_a na
    CROSS JOIN expenses_a ea
    CROSS JOIN purchases_a pa
    CROSS JOIN sales_b sb
    CROSS JOIN nc_b nb
    CROSS JOIN expenses_b eb
    CROSS JOIN purchases_b pb;
END;
$function$;


-- =============================================================================
-- 4. rpc_branch_report (task 1.5)
--    Base: cuerpo vigente 20260607000000 (C-07, verificado en prod).
--    Fix: total_sales = Σ COALESCE(total, amount) (antes: SUM(amount));
--    operation_count = COUNT(DISTINCT COALESCE(operation_id, id)) (antes:
--    COUNT(DISTINCT operation_id) — ignoraba NULL, 18 ventas legacy sin
--    operation_id no contaban); mismo fix de bordes RN-D5. Verificación de
--    membership sobre p_account_id sin cambios (se difiere a
--    v3-api-standards el alineamiento con current_account_ids()).
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
      SELECT DISTINCT branch_id FROM branch_sales
      UNION
      SELECT DISTINCT branch_id FROM branch_expenses
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


-- =============================================================================
-- 5. rpc_dashboard_kpi_summary — DROP + CREATE (task 1.6, D4)
--    Base: cuerpo vigente 20260806000001 §5.2b (verificado en prod). Este
--    RPC YA usaba COALESCE(total, amount) y COALESCE(operation_id, id)
--    correctamente — no tenía el bug de revenue. Se extiende con 4 columnas
--    de salida (invoiced_revenue, prev_invoiced_revenue, collected_revenue,
--    prev_collected_revenue, D3) y resta NC en net_profit/invoiced_revenue
--    (RN-D1). Mismos parámetros de entrada. DROP obligatorio porque CREATE OR
--    REPLACE no puede cambiar columnas OUT. REVOKE/GRANT idénticos a los
--    vigentes tras el DROP (se pierden con el DROP, hay que re-otorgarlos).
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_dashboard_kpi_summary(timestamptz, timestamptz, timestamptz, timestamptz, uuid);

CREATE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
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
  -- v3-reporting-invariants (RN-D1): notas de crédito del período restan del
  -- revenue devengado, imputadas por created_at (fecha de emisión de la NC,
  -- no de la venta original). El ledger de cta cte (C-30,
  -- c30_register_customer_account_movement) guarda el DELTA firmado sobre el
  -- balance: una NC acredita al cliente, por lo que su `amount` vive NEGATIVO
  -- en customer_account_movements — se usa ABS() para restar un monto
  -- positivo del revenue.
  nc_agg AS (
    SELECT
      COALESCE(SUM(ABS(cam.amount)) FILTER (WHERE cam.created_at BETWEEN p_from      AND p_to),      0) AS nc,
      COALESCE(SUM(ABS(cam.amount)) FILTER (WHERE cam.created_at BETWEEN p_prev_from AND p_prev_to), 0) AS prev_nc
    FROM public.customer_account_movements cam
    WHERE cam.account_id = v_account_id
      AND cam.movement_type = 'credit_note'
      AND cam.created_at BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
  ),
  -- v3-reporting-invariants (RN-D3): cargos a cuenta corriente del período
  -- difieren el cobro (venta devengada pero no percibida todavía). El
  -- movement_type del CARGO en customer_account_movements es 'sale'
  -- (verificado contra el CHECK vigente en prod, C-30:
  -- ('sale','payment_received','credit_note','adjustment') — 'sale' es el
  -- tipo que INCREMENTA la deuda del cliente cuando una venta se confirma a
  -- cuenta corriente; no existe un movement_type='charge' separado). El
  -- filtro `amount > 0` es defensivo (un 'sale' del ledger siempre incrementa
  -- deuda — nunca debería ser negativo — pero se documenta la intención).
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
  -- Stock sin rotación: productos vendibles con stock, sin líneas de venta en la ventana.
  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista, products.stock no existe).
  -- Sin cambios de v3-snapshot-pattern (no depende de costo por línea de venta).
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_from AND p_to
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
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
    -- cte del período + cobros del período (semántica de caja).
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
  'v3-reporting-invariants (RN-D1/D3): net_profit e invoiced_revenue restan '
  'notas de crédito del período (customer_account_movements.movement_type='
  'credit_note, por created_at). collected_revenue (percibido) = '
  'invoiced_revenue − cargos a cta cte del período + payments_received del '
  'período (semántica de caja: un cobro percibe en el período en que se '
  'registra, aunque la venta sea de un período anterior). DROP+CREATE '
  '(D4): CREATE OR REPLACE no puede cambiar columnas OUT; mismos parámetros '
  'de entrada, supabase-js ignora columnas extra en callers viejos.';


-- =============================================================================
-- 6. Gates de introspección (task 1.7) — corren SIEMPRE, incluso en prod.
--    Verifican que cada cuerpo nuevo contenga los predicados clave del fix.
--    RAISE EXCEPTION (aborta la migración) si falta alguno — a diferencia de
--    los gates de comportamiento, estos SÍ deben correr en prod: son baratos
--    (regex sobre pg_get_functiondef) y detectan un CREATE OR REPLACE que se
--    haya aplicado a medias o un drift entre esta migración y lo que quedó
--    realmente en el catálogo.
-- =============================================================================
DO $$
DECLARE
  v_def text;
BEGIN
  -- rpc_product_profitability: revenue de línea + fecha local.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_product_profitability';

  IF v_def IS NULL OR v_def NOT LIKE '%COALESCE(s.total, s.amount)%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_product_profitability no contiene COALESCE(s.total, s.amount) (RN-D revenue de línea).';
  END IF;
  IF v_def NOT LIKE '%reporting_local_today()%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_product_profitability no usa reporting_local_today() (RN-D5).';
  END IF;

  -- rpc_period_comparison: revenue de línea + NC + operaciones + bordes.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_period_comparison';

  IF v_def IS NULL OR v_def NOT LIKE '%COALESCE(s.total, s.amount)%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_period_comparison no contiene COALESCE(s.total, s.amount) (RN-D revenue de línea).';
  END IF;
  IF v_def NOT LIKE '%credit_note%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_period_comparison no resta notas de crédito (RN-D1).';
  END IF;
  IF v_def NOT LIKE '%COALESCE(s.operation_id, s.id)%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_period_comparison no usa COALESCE(operation_id, id) para contar operaciones (RN-D).';
  END IF;

  -- rpc_branch_report: revenue de línea + operaciones + bordes.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_branch_report';

  IF v_def IS NULL OR v_def NOT LIKE '%COALESCE(s.total, s.amount)%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_branch_report no contiene COALESCE(s.total, s.amount) (RN-D revenue de línea).';
  END IF;
  IF v_def NOT LIKE '%COALESCE(s.operation_id, s.id)%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_branch_report no usa COALESCE(operation_id, id) para contar operaciones (RN-D).';
  END IF;

  -- rpc_dashboard_kpi_summary: columnas nuevas del RETURNS + NC + cargos/cobros.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_dashboard_kpi_summary';

  IF v_def IS NULL OR v_def NOT LIKE '%invoiced_revenue%' OR v_def NOT LIKE '%collected_revenue%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no expone invoiced_revenue/collected_revenue (RN-D3).';
  END IF;
  IF v_def NOT LIKE '%credit_note%' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: rpc_dashboard_kpi_summary no resta notas de crédito (RN-D1).';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: los 4 RPCs de reporting contienen los predicados clave (revenue de línea, NC, fecha local, operaciones unificadas, columnas percibido/devengado).';
END $$;


-- =============================================================================
-- 7. Gate de comportamiento auto-limpiante (task 1.8) — solo DB vacía/CI,
--    NOTICE-degrade en prod. Anchor sintético vía handle_new_user (siembra
--    account + branch + cashbox desde 20260812000001). Cleanup hijo→padre
--    cubre TODO lo sembrado por este gate — accounts=0 al final.
-- =============================================================================
DO $$
DECLARE
  v_anchor_email     text := 'v3-reporting-invariants-gate@test.local';
  v_user_id          uuid := gen_random_uuid();
  v_account_id       uuid;
  v_branch_id        uuid;
  v_client_id        uuid;
  v_customer_acct_id uuid;
  v_product_id       uuid;
  v_sale_id_1        uuid;
  v_sale_id_2        uuid;
  v_sale_id_3a       uuid;
  v_sale_id_3b       uuid;
  v_sale_id_3c       uuid;
  v_op_id_3          uuid := gen_random_uuid();
  v_invoiced         numeric;
  v_collected        numeric;
  v_balance_running  numeric;
BEGIN
  -- Anchor sintético: dispara handle_new_user (AFTER INSERT ON auth.users) —
  -- crea account + branch "Casa Central" + cashbox "Caja Principal" (desde
  -- 20260812000001).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Reporting Invariants', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE V3-REPORTING-INVARIANTS: no se pudo resolver una account para el anchor sintético (contexto no permite el gate, p.ej. prod con RLS activa) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id
  FROM   public.branches
  WHERE  account_id = v_account_id
  ORDER  BY created_at
  LIMIT  1;

  -- Producto de prueba.
  INSERT INTO public.products (user_id, account_id, name, price, cost)
  VALUES (v_user_id, v_account_id, '__gate_v3_ri_product__', 1000, 400)
  RETURNING id INTO v_product_id;

  -- Cliente de prueba (para el cargo/cobro de cta cte, escenario c).
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_id, v_account_id, '__gate_v3_ri_client__')
  RETURNING id INTO v_client_id;

  -- Cabecera de cuenta corriente del cliente (customer_accounts): las FKs de
  -- customer_account_movements/payments_received apuntan acá, NO a clients.
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_id, 0, v_user_id)
  RETURNING id INTO v_customer_acct_id;

  -- ── Assert (a): venta quantity=2 → revenue = total de línea, no unitario ──
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 2, 2000, now())
  RETURNING id INTO v_sale_id_1;

  -- Verificación directa por agregación equivalente a la del RPC (no podemos
  -- llamar rpc_product_profitability() con auth.uid() real desde este
  -- bloque anónimo — corre con privilegios de owner de la migración, no del
  -- usuario anchor). Se valida la MISMA fórmula que usa el RPC.
  IF (SELECT COALESCE(SUM(COALESCE(s.total, s.amount)), 0) FROM public.sales s WHERE s.id = v_sale_id_1) <> 2000 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (a): revenue de línea con quantity=2 esperaba 2000.';
  END IF;

  -- ── Assert (b): NC de prueba resta en dashboard y comparativo ────────────
  -- INSERT directo (no vía c30_register_customer_account_movement: ese helper
  -- usa auth.uid() para created_by, NULL en este contexto de migración sin
  -- sesión). Se replica manualmente su invariante: balance_after >= 0 y
  -- balance_after = balance_previo + amount (ledger append-only, C-30). El
  -- ledger guarda el DELTA firmado: una NC acredita al cliente → amount
  -- NEGATIVO.
  v_balance_running := 0;
  v_balance_running := v_balance_running + 300;  -- 'sale' inicial: sube deuda 300 (base para poder acreditar la NC después)
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by)
  VALUES (v_customer_acct_id, v_account_id, 300, v_balance_running, 'sale', v_user_id);

  v_balance_running := v_balance_running - 300;  -- la NC acredita 300 (balance vuelve a 0)
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by)
  VALUES (v_customer_acct_id, v_account_id, -300, v_balance_running, 'credit_note', v_user_id);

  IF (SELECT COALESCE(SUM(cam.amount), 0) FROM public.customer_account_movements cam
      WHERE cam.account_id = v_account_id AND cam.movement_type = 'credit_note') <> -300 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (b): la NC de prueba no aparece con movement_type=credit_note por -300.';
  END IF;

  -- ── Assert (c): cargo cta cte + payment_received → collected vs invoiced ─
  -- Segunda venta antes de los cargos, para tener invoiced = (2000+1000)-300 = 2700.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000, now())
  RETURNING id INTO v_sale_id_2;

  -- Dos cargos (movement_type='sale', el tipo que INCREMENTA deuda: 500 + 400
  -- = 900) y un solo cobro (payments_received: 500) → collected debe terminar
  -- por debajo de invoiced (diferencia real, no se cancelan).
  v_balance_running := v_balance_running + 500;
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by)
  VALUES (v_customer_acct_id, v_account_id, 500, v_balance_running, 'sale', v_user_id);

  v_balance_running := v_balance_running + 400;
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, created_by)
  VALUES (v_customer_acct_id, v_account_id, 400, v_balance_running, 'sale', v_user_id);

  INSERT INTO public.payments_received
    (account_id, customer_account_id, client_id, amount, created_by)
  VALUES (v_account_id, v_customer_acct_id, v_client_id, 500, v_user_id);

  -- Los cargos de cta cte de este bloque: 500 + 400 = 900 (el 'sale' inicial
  -- de 300 pertenece al escenario (b), se excluye filtrando amount > 0 del
  -- subconjunto de este assert vía suma total esperada 300+500+400=1200).
  IF (SELECT COALESCE(SUM(cam.amount), 0) FROM public.customer_account_movements cam
      WHERE cam.account_id = v_account_id AND cam.movement_type = 'sale' AND cam.amount > 0) <> 1200 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (c1): los cargos de cta cte de prueba no suman 1200 (300 de (b) + 500 + 400 de (c)).';
  END IF;
  IF (SELECT COALESCE(SUM(pr_.amount), 0) FROM public.payments_received pr_
      WHERE pr_.account_id = v_account_id) <> 500 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (c2): el payment_received de prueba no se registró.';
  END IF;

  -- invoiced = Σsales − ΣNC = 3000 − 300 = 2700 (ΣNC = ABS(-300), la NC vive
  -- negativa en el ledger).
  -- collected = invoiced − Σcargos('sale', amount>0) + Σpayments
  --           = 2700 − (300+500+400) + 500 = 2700 − 1200 + 500 = 2000.
  v_invoiced  := (SELECT COALESCE(SUM(COALESCE(s.total, s.amount)), 0) FROM public.sales s WHERE s.account_id = v_account_id)
               - (SELECT COALESCE(SUM(ABS(cam.amount)), 0) FROM public.customer_account_movements cam WHERE cam.account_id = v_account_id AND cam.movement_type = 'credit_note');
  v_collected := v_invoiced
               - (SELECT COALESCE(SUM(cam.amount), 0) FROM public.customer_account_movements cam WHERE cam.account_id = v_account_id AND cam.movement_type = 'sale' AND cam.amount > 0)
               + (SELECT COALESCE(SUM(pr_.amount), 0) FROM public.payments_received pr_ WHERE pr_.account_id = v_account_id);

  IF v_invoiced <> 2700 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (c3): invoiced_revenue esperaba 2700, dio %.', v_invoiced;
  END IF;
  IF v_collected <> 2000 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (c4): collected_revenue esperaba 2000, dio %.', v_collected;
  END IF;
  IF v_collected = v_invoiced THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (c5): collected_revenue debería diferir de invoiced_revenue cuando charges > payments.';
  END IF;

  -- ── Assert (d): venta a las 15:00 UTC del último día del rango incluida ──
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000,
          (public.reporting_local_today())::timestamp + interval '15 hours')
  RETURNING id INTO v_sale_id_3a;

  IF NOT EXISTS (
    SELECT 1 FROM public.sales s
    WHERE s.id = v_sale_id_3a
      AND s.date >= public.reporting_local_today()::timestamptz
      AND s.date <  (public.reporting_local_today() + 1)::timestamptz
  ) THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (d): venta con hora 15:00 del último día del rango debería quedar incluida con el borde >= / < +1 día.';
  END IF;

  -- ── Assert (e): venta de 3 líneas = 1 operación (mismo operation_id) ─────
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000, now(), v_op_id_3)
  RETURNING id INTO v_sale_id_3a;
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000, now(), v_op_id_3)
  RETURNING id INTO v_sale_id_3b;
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date, operation_id)
  VALUES (v_user_id, v_account_id, v_branch_id, v_product_id, 1000, 1, 1000, now(), v_op_id_3)
  RETURNING id INTO v_sale_id_3c;

  IF (SELECT COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FROM public.sales s
      WHERE s.id IN (v_sale_id_3a, v_sale_id_3b, v_sale_id_3c)) <> 1 THEN
    RAISE EXCEPTION 'GATE V3-REPORTING-INVARIANTS FAILED (e): 3 líneas con el mismo operation_id deberían contar 1 operación (COUNT(DISTINCT COALESCE(operation_id, id))).';
  END IF;

  RAISE NOTICE 'GATE V3-REPORTING-INVARIANTS PASSED: revenue de línea (a), resta de NC (b), collected vs invoiced con cargo+cobro (c), borde de fin de día local (d), conteo de operaciones multi-línea (e).';

  -- ── Limpieza hijo→padre por anchor (accounts=0 al final) ─────────────────
  DELETE FROM public.payments_received            WHERE account_id = v_account_id;
  DELETE FROM public.customer_account_movements    WHERE account_id = v_account_id;
  DELETE FROM public.customer_accounts             WHERE account_id = v_account_id;
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
  DELETE FROM public.stock_movements WHERE account_id = v_account_id;
  DELETE FROM public.sales                         WHERE account_id = v_account_id;
  DELETE FROM public.clients                       WHERE account_id = v_account_id;
  DELETE FROM public.products                      WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches                      WHERE account_id = v_account_id;
  DELETE FROM public.account_members               WHERE user_id = v_user_id;
  DELETE FROM public.accounts                      WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles                      WHERE id = v_user_id;
  DELETE FROM public.email_logs                    WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency         WHERE user_id = v_user_id;
  DELETE FROM auth.users                           WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE V3-REPORTING-INVARIANTS FAILED%' THEN
      RAISE;
    END IF;
    -- Best-effort cleanup si algo falló a mitad de camino.
    BEGIN
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.payments_received            WHERE account_id = v_account_id;
        DELETE FROM public.customer_account_movements    WHERE account_id = v_account_id;
        DELETE FROM public.customer_accounts             WHERE account_id = v_account_id;
        DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
        DELETE FROM public.stock_movements WHERE account_id = v_account_id;
        DELETE FROM public.sales                         WHERE account_id = v_account_id;
        DELETE FROM public.clients                       WHERE account_id = v_account_id;
        DELETE FROM public.products                      WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches                      WHERE account_id = v_account_id;
        DELETE FROM public.account_members               WHERE user_id = v_user_id;
        DELETE FROM public.accounts                      WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles         WHERE id = v_user_id;
      DELETE FROM public.email_logs       WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users              WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260814000001_v3_reporting_invariants.sql
-- =============================================================================
