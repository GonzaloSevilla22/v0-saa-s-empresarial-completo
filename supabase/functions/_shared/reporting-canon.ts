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
  ): Promise<{ data: RpcRow[] | null; error: { message: string } | null }>
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
