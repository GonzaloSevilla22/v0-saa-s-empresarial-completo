// Aritmética canónica de reporting para las Edge Functions de IA (runtime Deno) —
// kpi-ia-canonical-revenue, D3.
//
// Gemelo frontend: `frontend/lib/reporting/revenue-canon.ts`. Ambos exponen las
// mismas funciones puras (`lineRevenue`, `sumLineRevenue`, `netMarginPct`,
// `previousWindow`) y están atadas por un test de paridad:
// `frontend/__tests__/reporting/reporting-canon-parity.test.ts`.
//
// TS puro, sin dependencias de `jsr:`/`npm:` ni referencias a `Deno.*` a nivel
// de módulo — es lo que lo hace deployable a Deno (`supabase functions deploy`)
// y a la vez testeable desde vitest importándolo por ruta relativa (patrón ya
// usado por `_shared/ai-quota.ts` y probado en `__tests__/ai-quota.test.ts`).

// ─── Types ────────────────────────────────────────────────────────────────────

/** Fila mínima de venta con la que se puede calcular su revenue de línea.
 *  Los numerics de Postgres llegan como `string` vía supabase-js. */
export interface SaleRevenueRow {
  amount: number | string | null
  total?: number | string | null
}

export interface Window {
  from: string
  to: string
}

/** Ventana con período previo — la que exige `rpc_dashboard_kpi_summary`. */
export interface KpiWindow {
  from: string
  to: string
  prevFrom: string
  prevTo: string
  branchId?: string | null
}

/** Subconjunto de `rpc_dashboard_kpi_summary` que consumen las Edge Functions
 *  de IA — ingresos, ganancia y su comparativa. Superficie deliberadamente
 *  mínima (D3): el hook del Tablero (frontend) mapea las 16 columnas; acá
 *  solo se replican las 4 que estos consumidores necesitan. */
export interface EdgeKpiSummary {
  netProfit: number | null
  prevNetProfit: number | null
  invoicedRevenue: number | null
  prevInvoicedRevenue: number | null
}

interface RpcRow {
  net_profit: string | number | null
  prev_net_profit: string | number | null
  invoiced_revenue: string | number | null
  prev_invoiced_revenue: string | number | null
}

/** Forma estructural mínima del cliente Supabase que este módulo necesita —
 *  sin `any` (regla dura del proyecto), cliente inyectado para poder testear
 *  desde vitest con un doble. */
export interface ReportingCanonClient {
  rpc(
    fn: "rpc_dashboard_kpi_summary",
    args: Record<string, string>,
  ): PromiseLike<{ data: RpcRow[] | null; error: { message: string } | null }>
}

/** Forma estructural mínima del cliente para el KPI canónico de stock
 * crítico. La RPC evalúa el ledger por sucursal y cuenta productos distintos;
 * ningún consumidor de IA debe reconstruir ese predicado sobre el stock total. */
export interface CriticalStockClient {
  rpc(
    fn: "get_dashboard_critical_stock",
    args: { p_branch_id: string | null },
  ): PromiseLike<{ data: number | string | null; error: { message: string } | null }>
}

/** Fila de `get_dashboard_critical_stock_items` mapeada a camelCase —
 *  kpi-canonicalization (candidato S5), gemelo de
 *  `frontend/lib/reporting/critical-stock.ts`. Una fila por (producto,
 *  sucursal) bajo el MISMO predicado que `CriticalStockClient` — sin
 *  deduplicar por producto, a diferencia del conteo. */
export interface CriticalStockItem {
  productId: string
  name: string
  sku: string | null
  branchId: string
  branchName: string
  quantity: number
  minStock: number
}

interface CriticalStockItemRpcRow {
  product_id: string
  name: string
  sku: string | null
  branch_id: string
  branch_name: string
  quantity: string | number
  min_stock: string | number
}

/** Forma estructural mínima del cliente para el detalle canónico de stock
 * crítico. */
export interface CriticalStockItemsClient {
  rpc(
    fn: "get_dashboard_critical_stock_items",
    args: { p_branch_id: string | null; p_limit: number },
  ): PromiseLike<{ data: CriticalStockItemRpcRow[] | null; error: { message: string } | null }>
}

/** Ventana simple (sin período comparativo) para `get_dashboard_financials`. */
export interface FinancialsWindow {
  from: string
  to: string
  branchId?: string | null
}

/** Fila mapeada de `get_dashboard_financials` — balance-ai-resumen-compras:
 *  única fuente canónica que expone "compras" del período junto con ingresos
 *  y gastos, con la misma fórmula de `net_profit` que `rpc_dashboard_kpi_summary`
 *  (que calcula compras internamente pero no las devuelve como columna). */
export interface DashboardFinancials {
  totalIncome: number | null
  totalExpenses: number | null
  totalPurchases: number | null
  netProfit: number | null
}

interface FinancialsRpcRow {
  total_income: string | number | null
  total_expenses: string | number | null
  total_purchases: string | number | null
  net_profit: string | number | null
}

/** Forma estructural mínima del cliente para `get_dashboard_financials`. */
export interface FinancialsClient {
  rpc(
    fn: "get_dashboard_financials",
    args: { p_date_from: string; p_date_to: string; p_branch_id?: string },
  ): PromiseLike<{ data: FinancialsRpcRow[] | null; error: { message: string } | null }>
}

/** Fila de `rpc_product_ranking` mapeada a camelCase — migrar-top-productos-canon:
 *  gemelo de `frontend/lib/reporting/product-ranking.ts`. Reemplaza las
 *  agregaciones locales de "top productos" de `ai-insights/index.ts` y del
 *  Copiloto (2ª/3ª definición de una agregación que esta RPC ya canoniza). */
export interface TopProduct {
  productId: string
  name: string
  units: number
  revenue: number
  /** `null` cuando ninguna línea del grupo resolvió costo (cascada RN-D2). */
  marginPct: number | null
}

interface ProductRankingRpcRow {
  product_id: string
  product_name: string
  units: string | number
  revenue: string | number
  gross_margin_pct: string | number | null
}

export interface ProductRankingWindow {
  /** Fecha de negocio (YYYY-MM-DD). */
  start: string
  end: string
  branchId?: string | null
  /** Top N por importe. Default 5. */
  limit?: number
}

/** Forma estructural mínima del cliente para `rpc_product_ranking`. */
export interface ProductRankingClient {
  rpc(
    fn: "rpc_product_ranking",
    args: {
      p_account_id: string
      p_start: string
      p_end: string
      p_order_by: string
      p_group_variants: boolean
      p_branch_id: string | null
      p_canal: null
      p_limit: number
      p_offset: number
    },
  ): PromiseLike<{ data: ProductRankingRpcRow[] | null; error: { message: string } | null }>
}

interface AccountMembershipRow {
  account_id: string
}

/** Forma estructural mínima del cliente para resolver la cuenta activa
 *  (mismo criterio que `backend/core/deps.py:get_account_id` y
 *  `generate-export/index.ts` — Regla de Tres: ya son 3 los consumidores de
 *  este criterio, de ahí la extracción). */
export interface AccountResolutionClient {
  from(table: "account_members"): {
    select(columns: string): {
      eq(column: string, value: string): {
        order(column: string, opts: { ascending: boolean }): {
          order(
            column: string,
            opts: { ascending: boolean },
          ): {
            limit(n: number): PromiseLike<{ data: AccountMembershipRow[] | null; error: { message: string } | null }>
          }
        }
      }
    }
  }
}

// ─── Pure helpers (gemelas de frontend/lib/reporting/revenue-canon.ts) ────────

const toNumber = (v: number | string | null | undefined): number => {
  if (v == null) return 0
  const n = Number(v)
  return Number.isNaN(n) ? 0 : n
}

const num = (v: string | number | null | undefined): number | null =>
  v == null ? null : Number(v)

/** Revenue de una línea de venta: `COALESCE(total, amount)`. Ver el gemelo
 *  frontend para el detalle de por qué `??` y no `||`. */
export function lineRevenue(row: SaleRevenueRow): number {
  const raw = row.total ?? row.amount
  return toNumber(raw)
}

/** Suma el revenue de línea de un conjunto de filas de venta. */
export function sumLineRevenue(rows: SaleRevenueRow[]): number {
  return rows.reduce((sum, row) => sum + lineRevenue(row), 0)
}

/** Margen neto porcentual, redondeado. `null` sin base de cálculo (revenue
 *  nulo/0/negativo) o sin `netProfit` disponible. Ganancia negativa se informa. */
export function netMarginPct(
  netProfit: number | null,
  revenue: number | null,
): number | null {
  if (netProfit == null || revenue == null || revenue <= 0) return null
  return Math.round((netProfit / revenue) * 100)
}

/** Ventana comparativa sintética (D2): intervalo inmediatamente anterior de
 *  igual duración, nunca invertido, sin solapar la ventana original. */
export function previousWindow(from: string, to: string): Window {
  const fromMs = Date.parse(from)
  const toMs = Date.parse(to)
  const durationMs = toMs - fromMs

  const prevToMs = fromMs - 1
  const prevFromMs = prevToMs - durationMs

  return {
    from: new Date(prevFromMs).toISOString(),
    to: new Date(prevToMs).toISOString(),
  }
}

// ─── Access ───────────────────────────────────────────────────────────────────

/**
 * Llama `rpc_dashboard_kpi_summary` con la ventana dada y devuelve el
 * subconjunto de columnas que necesitan las Edge Functions de IA, o `null`
 * si no hay filas. Propaga cualquier error del RPC — la decisión de degradar
 * (D4) es del consumidor, no de esta capa de acceso.
 */
export async function fetchKpiSummary(
  client: ReportingCanonClient,
  window: KpiWindow,
): Promise<EdgeKpiSummary | null> {
  const params: Record<string, string> = {
    p_from: window.from,
    p_to: window.to,
    p_prev_from: window.prevFrom,
    p_prev_to: window.prevTo,
  }
  if (window.branchId) params.p_branch_id = window.branchId

  const { data, error } = await client.rpc("rpc_dashboard_kpi_summary", params)
  if (error) throw error

  const row = data && data.length > 0 ? data[0] : null
  if (!row) return null

  return {
    netProfit: num(row.net_profit),
    prevNetProfit: num(row.prev_net_profit),
    invoicedRevenue: num(row.invoiced_revenue),
    prevInvoicedRevenue: num(row.prev_invoiced_revenue),
  }
}

/** Devuelve el conteo canónico de productos críticos para una sucursal o,
 * con `null`, el agregado consciente de sucursal. Propaga el error para que
 * cada consumidor decida si omite el dato o degrada a cero. */
export async function fetchCriticalStockCount(
  client: CriticalStockClient,
  branchId: string | null = null,
): Promise<number> {
  const { data, error } = await client.rpc("get_dashboard_critical_stock", {
    p_branch_id: branchId,
  })
  if (error) throw error

  return data == null ? 0 : Number(data)
}

/**
 * Llama `get_dashboard_critical_stock_items` (mismo predicado que
 * `fetchCriticalStockCount`, sin deduplicar por producto) y devuelve las
 * filas mapeadas, top `limit` por criticidad. Propaga cualquier error del
 * RPC — la decisión de degradar (omitir el bloque, nunca reconstruir desde
 * `v_products_with_stock`) es del consumidor.
 */
export async function fetchCriticalStockItems(
  client: CriticalStockItemsClient,
  branchId: string | null = null,
  limit = 5,
): Promise<CriticalStockItem[]> {
  const { data, error } = await client.rpc("get_dashboard_critical_stock_items", {
    p_branch_id: branchId,
    p_limit: limit,
  })
  if (error) throw error

  const rows = data ?? []
  return rows.map((row) => ({
    productId: row.product_id,
    name: row.name,
    sku: row.sku,
    branchId: row.branch_id,
    branchName: row.branch_name,
    quantity: toNumber(row.quantity),
    minStock: toNumber(row.min_stock),
  }))
}

/**
 * Llama `get_dashboard_financials` con la ventana dada y devuelve la fila
 * mapeada, o `null` si no hay filas. Propaga cualquier error del RPC — la
 * decisión de degradar (D4, balance-ai-resumen-compras) es del consumidor,
 * no de esta capa de acceso.
 *
 * Nit (revisión adversarial, fix 8): esta RPC resuelve la tenencia con un
 * criterio DISTINTO al de `rpc_dashboard_kpi_summary` (`fetchKpiSummary`
 * arriba) — `get_dashboard_financials` filtra directo por
 * `account_id IN (SELECT current_account_ids())` (el conjunto derivado de
 * `auth.uid()`, sin materializar una cuenta), mientras que
 * `rpc_dashboard_kpi_summary` resuelve una única `v_account_id` explícita
 * (`SELECT cai INTO v_account_id ... LIMIT 1`) antes de filtrar. Ninguna de
 * las dos recibe un `p_account_id` del caller (a diferencia de
 * `fetchTopProducts`/`resolveActiveAccountId` más abajo, que sí lo resuelven
 * en el cliente y lo pasan explícito). `ai-resumen/index.ts` llama a AMBAS
 * (`fetchKpiSummary` + `fetchDashboardFinancials`) para el mismo prompt sin
 * armonizar esta diferencia — hoy inocuo porque la tenency es de una sola
 * cuenta por usuario (OQ-2), pero deja de serlo si eso cambia.
 */
export async function fetchDashboardFinancials(
  client: FinancialsClient,
  window: FinancialsWindow,
): Promise<DashboardFinancials | null> {
  const args: { p_date_from: string; p_date_to: string; p_branch_id?: string } = {
    p_date_from: window.from,
    p_date_to: window.to,
  }
  if (window.branchId) args.p_branch_id = window.branchId

  const { data, error } = await client.rpc("get_dashboard_financials", args)
  if (error) throw error

  const row = data && data.length > 0 ? data[0] : null
  if (!row) return null

  return {
    totalIncome: num(row.total_income),
    totalExpenses: num(row.total_expenses),
    totalPurchases: num(row.total_purchases),
    netProfit: num(row.net_profit),
  }
}

/**
 * Resuelve la cuenta activa del usuario con el mismo criterio determinístico
 * que `backend/core/deps.py:get_account_id` y `generate-export/index.ts`: la
 * membresía con `created_at` más antiguo, desempatada por `id`. `null` si no
 * tiene ninguna cuenta activa — el caller decide si degrada.
 */
export async function resolveActiveAccountId(
  client: AccountResolutionClient,
  userId: string,
): Promise<string | null> {
  const { data, error } = await client
    .from("account_members")
    .select("account_id")
    .eq("user_id", userId)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .limit(1)

  if (error || !data || data.length === 0) return null
  return data[0].account_id
}

/**
 * Llama `rpc_product_ranking` (orden por importe, variantes agrupadas, top
 * `window.limit`) y devuelve las filas mapeadas. Propaga cualquier error del
 * RPC — la decisión de degradar (omitir el bloque, nunca reconstruir la
 * suma local sobre `v_sales_flat`/`sales`) es del consumidor.
 */
export async function fetchTopProducts(
  client: ProductRankingClient,
  accountId: string,
  window: ProductRankingWindow,
): Promise<TopProduct[]> {
  const { data, error } = await client.rpc("rpc_product_ranking", {
    p_account_id: accountId,
    p_start: window.start,
    p_end: window.end,
    p_order_by: "revenue",
    p_group_variants: true,
    p_branch_id: window.branchId ?? null,
    p_canal: null,
    p_limit: window.limit ?? 5,
    p_offset: 0,
  })
  if (error) throw error

  const rows = data ?? []
  return rows.map((row) => ({
    productId: row.product_id,
    name: row.product_name,
    units: toNumber(row.units),
    revenue: toNumber(row.revenue),
    marginPct: num(row.gross_margin_pct),
  }))
}
