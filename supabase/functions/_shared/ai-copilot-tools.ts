// Catálogo de herramientas de SÓLO LECTURA del Copiloto — ia-copilot-v2 (tanda A, D3).
//
// Cada herramienta se traduce a UNA lectura canónica ya existente (RPC con guard de
// membresía y clamp de historial por plan). Reglas que este módulo sostiene:
//
//   - La cuenta la fija el SERVIDOR (`deps.accountId`, de `current_account_ids()`): ningún
//     argumento del modelo puede cambiarla; si el modelo manda `account_id` se ignora.
//   - Los argumentos se validan ANTES de tocar la base (fechas de negocio YYYY-MM-DD,
//     desde <= hasta, hasta 366 días, enumerados y límites). Un argumento fuera de dominio
//     NO es un error HTTP para la persona: vuelve al modelo como {error:"argumento_invalido"}
//     y puede corregir en la ronda siguiente.
//   - Nada se agrega ni se recalcula (reporting-invariants): sólo se recorta a un tope de
//     filas y se compacta. La única suma es el total de cuentas por cobrar / pagar, que se
//     calcula sobre TODAS las filas de la RPC antes de recortar la lista (igual que el
//     endpoint /reports/receivables/summary).
//   - Ninguna herramienta escribe. Una RPC que falla devuelve {error:"no_disponible"} sin
//     filtrar el mensaje; el log lo lleva el handler.
//
// TS puro, sin `Deno.*` a nivel de módulo: deployable a Deno y testeable desde vitest.

import { previousWindow } from "./reporting-canon.ts"
import { isIsoBusinessDate, isUuid } from "./statistics-params.ts"

// ─── Tipos ────────────────────────────────────────────────────────────────────

export interface ToolRpcResult {
  data: unknown
  error: { message: string; code?: string } | null
}

export interface ToolDeps {
  /** Cuenta activa resuelta por el servidor (nunca por el modelo). */
  accountId: string
  now: Date
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<ToolRpcResult>
  /** Lectura de `products` con filtro explícito por cuenta y sin borrados (RLS como red). */
  searchProducts(accountId: string, text: string, limit: number): PromiseLike<ToolRpcResult>
}

export interface FocusState {
  period: { start: string; end: string } | null
  product: { id: string; name: string } | null
  client: { id: string; name: string } | null
}

export interface ConsultedItem {
  tool: string
  label: string
}

export interface ToolOutcome {
  /** JSON que vuelve al modelo. */
  result: Record<string, unknown>
  ok: boolean
  rows: number
  /** Rótulo para la persona; `null` si la herramienta no llegó a consultar nada. */
  consulted: ConsultedItem | null
  /** Foco que esta herramienta deja para los seguimientos (D7). */
  focus: Partial<FocusState>
}

export type ToolName =
  | "resumen_periodo"
  | "evolucion_ventas"
  | "ranking_productos"
  | "desglose_ventas"
  | "mejores_clientes"
  | "stock_critico"
  | "buscar_producto"
  | "detalle_producto"
  | "cuentas_por_cobrar"
  | "cuentas_por_pagar"
  | "comparar_periodos"
  | "rentabilidad_productos"

export const COPILOT_TOOL_NAMES: readonly ToolName[] = [
  "resumen_periodo", "evolucion_ventas", "ranking_productos", "desglose_ventas", "mejores_clientes",
  "stock_critico", "buscar_producto", "detalle_producto", "cuentas_por_cobrar", "cuentas_por_pagar",
  "comparar_periodos", "rentabilidad_productos",
]

// ─── Topes ────────────────────────────────────────────────────────────────────

const MAX_RANGE_DAYS = 366
const CAP_EVOLUTION_BUCKETS = 31
const CAP_BREAKDOWN = 24
const CAP_RANKING = 20
const CAP_CLIENTS = 20
const CAP_STOCK = 50
const CAP_SEARCH = 10
const CAP_PROFITABILITY = 20
const DEFAULT_LIMIT = 5

// ─── Definición de las herramientas para OpenAI ───────────────────────────────

interface JsonSchemaProp {
  type: string | string[]
  description?: string
  enum?: string[]
}

export interface CopilotToolDefinition {
  type: "function"
  function: {
    name: ToolName
    description: string
    strict: true
    parameters: {
      type: "object"
      properties: Record<string, JsonSchemaProp>
      required: string[]
      additionalProperties: false
    }
  }
}

const DATE_FROM: JsonSchemaProp = { type: "string", description: "Fecha de inicio YYYY-MM-DD (día de negocio, inclusive)." }
const DATE_TO: JsonSchemaProp = { type: "string", description: "Fecha de fin YYYY-MM-DD (día de negocio, inclusive). Rango máximo: 366 días." }
const BRANCH: JsonSchemaProp = { type: ["string", "null"], description: "UUID de la sucursal; null = todas." }

function tool(name: ToolName, description: string, properties: Record<string, JsonSchemaProp>): CopilotToolDefinition {
  return {
    type: "function",
    function: {
      name,
      description,
      strict: true,
      parameters: { type: "object", properties, required: Object.keys(properties), additionalProperties: false },
    },
  }
}

export const COPILOT_TOOLS: readonly CopilotToolDefinition[] = [
  tool("resumen_periodo",
    "Resumen del período: ventas facturadas, cobradas, ganancia neta, ticket promedio, cantidad de ventas y stock estancado, comparado con el período anterior de igual duración. Usala para «cuánto vendí», «cuál fue mi ganancia».",
    { desde: DATE_FROM, hasta: DATE_TO, sucursal_id: BRANCH }),
  tool("evolucion_ventas",
    "Evolución de las ventas del período por día, semana ISO o mes, con el total del período y el del período anterior.",
    { desde: DATE_FROM, hasta: DATE_TO, agrupar: { type: "string", enum: ["day", "week", "month"] }, sucursal_id: BRANCH }),
  tool("ranking_productos",
    "Ranking de productos más vendidos del período, con variantes agrupadas. orden: units (unidades), revenue (importe) o margin (margen).",
    { desde: DATE_FROM, hasta: DATE_TO, orden: { type: "string", enum: ["units", "revenue", "margin"] }, limite: { type: ["integer", "null"], description: "Cantidad de filas, 1 a 20 (null = 5)." }, sucursal_id: BRANCH }),
  tool("desglose_ventas",
    "Ventas del período desglosadas por canal, sucursal, día de la semana, horario de carga o categoría.",
    { desde: DATE_FROM, hasta: DATE_TO, dimension: { type: "string", enum: ["canal", "branch", "weekday", "hour", "category"] }, sucursal_id: BRANCH }),
  tool("mejores_clientes",
    "Clientes que más compraron en el período (las ventas sin cliente vienen aparte, en la fila unassigned).",
    { desde: DATE_FROM, hasta: DATE_TO, limite: { type: ["integer", "null"], description: "Cantidad de clientes, 1 a 20 (null = 5)." }, sucursal_id: BRANCH }),
  tool("stock_critico",
    "Productos con stock crítico (por debajo del mínimo) por sucursal, con cantidad y mínimo.",
    { sucursal_id: BRANCH, limite: { type: ["integer", "null"], description: "Cantidad de filas, 1 a 50 (null = 10)." } }),
  tool("buscar_producto",
    "Busca productos por nombre o SKU (hasta 10). Usala para resolver a qué producto se refiere la persona antes de pedir su detalle.",
    { texto: { type: "string", description: "Texto a buscar, de 2 a 80 caracteres." } }),
  tool("detalle_producto",
    "Ventas de un producto puntual en el período (total y evolución por día, semana o mes). Requiere el producto_id que devuelve buscar_producto.",
    { producto_id: { type: "string", description: "UUID del producto." }, desde: DATE_FROM, hasta: DATE_TO, agrupar: { type: "string", enum: ["day", "week", "month"] } }),
  tool("cuentas_por_cobrar",
    "Clientes con saldo pendiente de cobro: saldo, vencido, antigüedad y el total adeudado a la cuenta.",
    { limite: { type: ["integer", "null"], description: "Cantidad de clientes, 1 a 20 (null = 5)." } }),
  tool("cuentas_por_pagar",
    "Proveedores a los que se les debe: saldo, vencido, antigüedad y el total adeudado.",
    { limite: { type: ["integer", "null"], description: "Cantidad de proveedores, 1 a 20 (null = 5)." } }),
  tool("comparar_periodos",
    "Compara dos períodos cualesquiera (A contra B): ventas, gastos, compras y operaciones, con la variación porcentual.",
    { a_desde: DATE_FROM, a_hasta: DATE_TO, b_desde: DATE_FROM, b_hasta: DATE_TO }),
  tool("rentabilidad_productos",
    "Rentabilidad por producto en los últimos N días (7 a 365): ingreso, costo, margen y última venta. orden: mejor (más ganancia) o peor (menos ganancia).",
    { dias: { type: "integer", description: "Ventana en días, 7 a 365." }, limite: { type: ["integer", "null"], description: "Cantidad de filas, 1 a 20 (null = 5)." }, orden: { type: "string", enum: ["mejor", "peor"] } }),
]

// ─── Validación de argumentos ─────────────────────────────────────────────────

type Args = Record<string, unknown>
type Validated = { ok: true; value: Record<string, unknown> } | { ok: false; detalle: string }

const fail = (detalle: string): Validated => ({ ok: false, detalle })

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}

/** Días calendario entre dos "YYYY-MM-DD" (hasta - desde). */
function daysBetween(from: string, to: string): number {
  const [fy, fm, fd] = from.split("-").map(Number)
  const [ty, tm, td] = to.split("-").map(Number)
  return Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86_400_000)
}

function checkRange(desde: unknown, hasta: unknown, label = ""): string | null {
  if (!isIsoBusinessDate(desde)) return `${label}desde debe ser una fecha YYYY-MM-DD válida`
  if (!isIsoBusinessDate(hasta)) return `${label}hasta debe ser una fecha YYYY-MM-DD válida`
  if (hasta < desde) return `${label}hasta es anterior a desde`
  if (daysBetween(desde, hasta) + 1 > MAX_RANGE_DAYS) return `${label}el rango supera los ${MAX_RANGE_DAYS} días`
  return null
}

function checkBranch(raw: unknown): { ok: true; value: string | null } | { ok: false; detalle: string } {
  if (raw === undefined || raw === null) return { ok: true, value: null }
  if (!isUuid(raw)) return { ok: false, detalle: "sucursal_id debe ser un uuid o null" }
  return { ok: true, value: raw }
}

function checkLimit(raw: unknown, max: number, def: number): { ok: true; value: number } | { ok: false; detalle: string } {
  if (raw === undefined || raw === null) return { ok: true, value: def }
  if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 1 || raw > max) {
    return { ok: false, detalle: `limite debe ser un entero entre 1 y ${max}` }
  }
  return { ok: true, value: raw }
}

function checkEnum<T extends string>(raw: unknown, allowed: readonly T[], name: string): { ok: true; value: T } | { ok: false; detalle: string } {
  if (typeof raw === "string" && (allowed as readonly string[]).includes(raw)) return { ok: true, value: raw as T }
  return { ok: false, detalle: `${name} debe ser uno de: ${allowed.join(", ")}` }
}

/** Limpia el patrón de búsqueda: sin comodines de LIKE ni separadores de filtros de PostgREST. */
export function sanitizeSearchText(text: string): string {
  return text.replace(/[%*_\\,()"'`;:]/g, "").replace(/\s+/g, " ").trim()
}

const BUCKETS = ["day", "week", "month"] as const

export function validateToolArgs(name: string, raw: unknown): Validated {
  if (!isRecord(raw)) return fail("los argumentos deben ser un objeto")
  const a: Args = raw
  switch (name) {
    case "resumen_periodo": {
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      return { ok: true, value: { desde: a.desde, hasta: a.hasta, sucursal_id: b.value } }
    }
    case "evolucion_ventas": {
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const g = checkEnum(a.agrupar, BUCKETS, "agrupar"); if (!g.ok) return fail(g.detalle)
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      return { ok: true, value: { desde: a.desde, hasta: a.hasta, agrupar: g.value, sucursal_id: b.value } }
    }
    case "ranking_productos": {
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const o = checkEnum(a.orden, ["units", "revenue", "margin"] as const, "orden"); if (!o.ok) return fail(o.detalle)
      const l = checkLimit(a.limite, CAP_RANKING, DEFAULT_LIMIT); if (!l.ok) return fail(l.detalle)
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      return { ok: true, value: { desde: a.desde, hasta: a.hasta, orden: o.value, limite: l.value, sucursal_id: b.value } }
    }
    case "desglose_ventas": {
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const d = checkEnum(a.dimension, ["canal", "branch", "weekday", "hour", "category"] as const, "dimension"); if (!d.ok) return fail(d.detalle)
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      return { ok: true, value: { desde: a.desde, hasta: a.hasta, dimension: d.value, sucursal_id: b.value } }
    }
    case "mejores_clientes": {
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const l = checkLimit(a.limite, CAP_CLIENTS, DEFAULT_LIMIT); if (!l.ok) return fail(l.detalle)
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      return { ok: true, value: { desde: a.desde, hasta: a.hasta, limite: l.value, sucursal_id: b.value } }
    }
    case "stock_critico": {
      const b = checkBranch(a.sucursal_id); if (!b.ok) return fail(b.detalle)
      const l = checkLimit(a.limite, CAP_STOCK, 10); if (!l.ok) return fail(l.detalle)
      return { ok: true, value: { sucursal_id: b.value, limite: l.value } }
    }
    case "buscar_producto": {
      if (typeof a.texto !== "string") return fail("texto debe ser un texto")
      const t = a.texto.trim()
      if (t.length < 2 || t.length > 80) return fail("texto debe tener entre 2 y 80 caracteres")
      const clean = sanitizeSearchText(t)
      if (clean.length < 2) return fail("texto no tiene caracteres de búsqueda válidos")
      return { ok: true, value: { texto: clean } }
    }
    case "detalle_producto": {
      if (!isUuid(a.producto_id)) return fail("producto_id debe ser un uuid (el que devuelve buscar_producto)")
      const r = checkRange(a.desde, a.hasta); if (r) return fail(r)
      const g = checkEnum(a.agrupar, BUCKETS, "agrupar"); if (!g.ok) return fail(g.detalle)
      return { ok: true, value: { producto_id: a.producto_id, desde: a.desde, hasta: a.hasta, agrupar: g.value } }
    }
    case "cuentas_por_cobrar":
    case "cuentas_por_pagar": {
      const l = checkLimit(a.limite, CAP_CLIENTS, DEFAULT_LIMIT); if (!l.ok) return fail(l.detalle)
      return { ok: true, value: { limite: l.value } }
    }
    case "comparar_periodos": {
      const ra = checkRange(a.a_desde, a.a_hasta, "período A: "); if (ra) return fail(ra)
      const rb = checkRange(a.b_desde, a.b_hasta, "período B: "); if (rb) return fail(rb)
      return { ok: true, value: { a_desde: a.a_desde, a_hasta: a.a_hasta, b_desde: a.b_desde, b_hasta: a.b_hasta } }
    }
    case "rentabilidad_productos": {
      const d = a.dias
      if (typeof d !== "number" || !Number.isInteger(d) || d < 7 || d > 365) return fail("dias debe ser un entero entre 7 y 365")
      const l = checkLimit(a.limite, CAP_PROFITABILITY, DEFAULT_LIMIT); if (!l.ok) return fail(l.detalle)
      const o = checkEnum(a.orden, ["mejor", "peor"] as const, "orden"); if (!o.ok) return fail(o.detalle)
      return { ok: true, value: { dias: d, limite: l.value, orden: o.value } }
    }
    default:
      return fail(`herramienta desconocida: ${name}`)
  }
}

// ─── Rótulos en castellano ────────────────────────────────────────────────────

const MONTHS_ES = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
]

function parts(iso: string): { y: number; m: number; d: number } {
  const [y, m, d] = iso.split("-").map(Number)
  return { y, m, d }
}

/** «6 de noviembre», «1 al 6 de noviembre», «28 de octubre al 6 de noviembre» (con año si cambia). */
export function formatRangeEs(desde: string, hasta: string): string {
  const a = parts(desde)
  const b = parts(hasta)
  if (desde === hasta) return `${a.d} de ${MONTHS_ES[a.m - 1]}${a.y !== b.y ? ` de ${a.y}` : ""}`
  if (a.y !== b.y) return `${a.d} de ${MONTHS_ES[a.m - 1]} de ${a.y} al ${b.d} de ${MONTHS_ES[b.m - 1]} de ${b.y}`
  if (a.m === b.m) return `${a.d} al ${b.d} de ${MONTHS_ES[b.m - 1]}`
  return `${a.d} de ${MONTHS_ES[a.m - 1]} al ${b.d} de ${MONTHS_ES[b.m - 1]}`
}

const DIMENSION_LABEL: Record<string, string> = {
  canal: "canal", branch: "sucursal", weekday: "día de la semana", hour: "horario de carga", category: "categoría",
}

// ─── Compactación (sin re-agregar) ────────────────────────────────────────────

const num = (v: unknown): number | null => {
  if (v === null || v === undefined) return null
  const n = Number(v)
  return Number.isNaN(n) ? null : n
}

function pick(row: Record<string, unknown>, numeric: readonly string[], text: readonly string[]): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const k of text) if (k in row) out[k] = row[k] ?? null
  for (const k of numeric) if (k in row) out[k] = num(row[k])
  return out
}

function asRows(data: unknown): Record<string, unknown>[] {
  return Array.isArray(data) ? data.filter(isRecord) : []
}

function clamped(rows: Record<string, unknown>[]): boolean {
  return rows.some((r) => r.window_clamped === true)
}

const UNAVAILABLE: ToolOutcome = { result: { error: "no_disponible" }, ok: false, rows: 0, consulted: null, focus: {} }

function invalid(detalle: string): ToolOutcome {
  return { result: { error: "argumento_invalido", detalle }, ok: false, rows: 0, consulted: null, focus: {} }
}

function success(tool: string, label: string, result: Record<string, unknown>, rows: number, focus: Partial<FocusState> = {}): ToolOutcome {
  return { result, ok: true, rows, consulted: { tool, label }, focus }
}

const periodOf = (start: unknown, end: unknown): { start: string; end: string } => ({ start: String(start), end: String(end) })

// ─── Ejecución ────────────────────────────────────────────────────────────────

/**
 * Ejecuta UNA llamada a herramienta. Nunca lanza: un argumento inválido, una herramienta
 * desconocida o una RPC que falla se convierten en un resultado para el modelo.
 */
export async function executeCopilotTool(deps: ToolDeps, name: string, rawArgs: unknown): Promise<ToolOutcome> {
  if (!(COPILOT_TOOL_NAMES as readonly string[]).includes(name)) {
    return { result: { error: "herramienta_desconocida" }, ok: false, rows: 0, consulted: null, focus: {} }
  }
  const v = validateToolArgs(name, rawArgs)
  if (!v.ok) return invalid(v.detalle)
  const a = v.value
  try {
    return await run(deps, name as ToolName, a)
  } catch (_err) {
    return UNAVAILABLE
  }
}

async function run(deps: ToolDeps, name: ToolName, a: Record<string, unknown>): Promise<ToolOutcome> {
  const acc = deps.accountId
  switch (name) {
    case "resumen_periodo": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const from = `${desde}T00:00:00.000Z`
      const to = `${hasta}T23:59:59.999Z`
      const prev = previousWindow(from, to)
      const res = await deps.rpc("rpc_dashboard_kpi_summary", {
        p_from: from, p_to: to, p_prev_from: prev.from, p_prev_to: prev.to, p_branch_id: a.sucursal_id,
      })
      if (res.error) return UNAVAILABLE
      const row = asRows(res.data)[0]
      if (!row) return success(name, `ventas del ${formatRangeEs(desde, hasta)}`, { desde, hasta, sin_datos: true }, 0, { period: periodOf(desde, hasta) })
      const summary = pick(row, [
        "invoiced_revenue", "prev_invoiced_revenue", "collected_revenue", "prev_collected_revenue", "net_profit", "prev_net_profit",
        "avg_ticket", "prev_avg_ticket", "cost_per_sale", "prev_cost_per_sale", "sales_count", "prev_sales_count",
        "stagnant_stock_value", "stagnant_stock_count", "stagnant_stock_without_cost_count", "prev_stagnant_stock_value", "prev_stagnant_stock_count",
      ], [])
      return success(name, `ventas del ${formatRangeEs(desde, hasta)}`, { desde, hasta, ...summary }, 1, { period: periodOf(desde, hasta) })
    }
    case "evolucion_ventas": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const res = await deps.rpc("rpc_sales_evolution", {
        p_account_id: acc, p_start: desde, p_end: hasta, p_bucket: a.agrupar, p_branch_id: a.sucursal_id, p_canal: null,
      })
      if (res.error) return UNAVAILABLE
      const rows = asRows(res.data)
      const totals = rows.filter((r) => r.period !== "bucket")
      const buckets = rows.filter((r) => r.period === "bucket").slice(0, CAP_EVOLUTION_BUCKETS)
      const keep = [...totals, ...buckets].map((r) =>
        pick(r, ["revenue", "credit_notes", "net_revenue", "units", "operations", "service_revenue"], ["period", "bucket_start", "bucket_end"]))
      return success(name, `evolución de ventas del ${formatRangeEs(desde, hasta)}`,
        { desde, hasta, agrupar: a.agrupar, rows: keep, window_clamped: clamped(rows) }, keep.length, { period: periodOf(desde, hasta) })
    }
    case "ranking_productos": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const res = await deps.rpc("rpc_product_ranking", {
        p_account_id: acc, p_start: desde, p_end: hasta, p_order_by: a.orden, p_group_variants: true,
        p_branch_id: a.sucursal_id, p_canal: null, p_limit: a.limite, p_offset: 0,
      })
      if (res.error) return UNAVAILABLE
      const all = asRows(res.data)
      const rows = all.slice(0, CAP_RANKING).map((r) =>
        pick(r, ["rank", "units", "revenue", "gross_margin", "gross_margin_pct", "cost_coverage_pct", "operations", "variant_count"],
          ["product_id", "product_name", "sku", "category", "is_group", "last_sale_date"]))
      return success(name, `ranking de productos del ${formatRangeEs(desde, hasta)}`,
        { desde, hasta, orden: a.orden, rows, window_clamped: clamped(all) }, rows.length, { period: periodOf(desde, hasta) })
    }
    case "desglose_ventas": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const res = await deps.rpc("rpc_sales_breakdown", {
        p_account_id: acc, p_start: desde, p_end: hasta, p_dimension: a.dimension, p_branch_id: a.sucursal_id, p_canal: null,
      })
      if (res.error) return UNAVAILABLE
      const all = asRows(res.data)
      const rows = all.slice(0, CAP_BREAKDOWN).map((r) =>
        pick(r, ["revenue", "units", "operations", "sort_order"], ["bucket_key", "bucket_label"]))
      return success(name, `ventas por ${DIMENSION_LABEL[a.dimension as string]} del ${formatRangeEs(desde, hasta)}`,
        { desde, hasta, dimension: a.dimension, rows, window_clamped: clamped(all) }, rows.length, { period: periodOf(desde, hasta) })
    }
    case "mejores_clientes": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const res = await deps.rpc("rpc_sales_top_clients", {
        p_account_id: acc, p_start: desde, p_end: hasta, p_branch_id: a.sucursal_id, p_limit: a.limite,
      })
      if (res.error) return UNAVAILABLE
      const all = asRows(res.data)
      const clients = all.filter((r) => r.row_kind === "client").slice(0, CAP_CLIENTS)
      const unassigned = all.filter((r) => r.row_kind === "unassigned").slice(0, 1)
      const rows = [...clients, ...unassigned].map((r) =>
        pick(r, ["rank", "revenue", "units", "operations", "total_clients"], ["row_kind", "client_id", "client_name", "last_sale_date"]))
      const focus: Partial<FocusState> = { period: periodOf(desde, hasta) }
      if (clients.length === 1 && typeof clients[0].client_id === "string" && typeof clients[0].client_name === "string") {
        focus.client = { id: clients[0].client_id, name: clients[0].client_name }
      }
      return success(name, `mejores clientes del ${formatRangeEs(desde, hasta)}`,
        { desde, hasta, rows, window_clamped: clamped(all) }, rows.length, focus)
    }
    case "stock_critico": {
      const res = await deps.rpc("get_dashboard_critical_stock_items", { p_branch_id: a.sucursal_id, p_limit: a.limite })
      if (res.error) return UNAVAILABLE
      const rows = asRows(res.data).slice(0, CAP_STOCK).map((r) =>
        pick(r, ["quantity", "min_stock"], ["product_id", "name", "sku", "branch_id", "branch_name"]))
      return success(name, a.sucursal_id ? "stock crítico de la sucursal" : "stock crítico de todas las sucursales", { rows }, rows.length)
    }
    case "buscar_producto": {
      const texto = a.texto as string
      const res = await deps.searchProducts(acc, texto, CAP_SEARCH)
      if (res.error) return UNAVAILABLE
      const rows = asRows(res.data).slice(0, CAP_SEARCH).map((r) => pick(r, [], ["id", "name", "sku"]))
      const focus: Partial<FocusState> = {}
      if (rows.length === 1 && typeof rows[0].id === "string" && typeof rows[0].name === "string") {
        focus.product = { id: rows[0].id, name: rows[0].name }
      }
      return success(name, `búsqueda del producto «${texto}»`, { texto, rows }, rows.length, focus)
    }
    case "detalle_producto": {
      const desde = a.desde as string
      const hasta = a.hasta as string
      const res = await deps.rpc("rpc_product_sales_evolution", {
        p_account_id: acc, p_product_id: a.producto_id, p_start: desde, p_end: hasta, p_bucket: a.agrupar,
        p_branch_id: null, p_canal: null,
      })
      if (res.error) {
        if (res.error.code === "P0404") return { result: { error: "producto_no_encontrado" }, ok: false, rows: 0, consulted: null, focus: {} }
        return UNAVAILABLE
      }
      const all = asRows(res.data)
      const totals = all.filter((r) => r.row_kind !== "bucket")
      const buckets = all.filter((r) => r.row_kind === "bucket").slice(0, CAP_EVOLUTION_BUCKETS)
      const rows = [...totals, ...buckets].map((r) =>
        pick(r, ["units", "revenue", "operations", "gross_margin", "gross_margin_pct", "variant_count"],
          ["row_kind", "product_id", "product_name", "bucket_start", "bucket_end", "variant_name", "last_sale_date"]))
      const focus: Partial<FocusState> = { period: periodOf(desde, hasta) }
      const head = all.find((r) => typeof r.product_name === "string" && typeof r.product_id === "string")
      if (head) focus.product = { id: head.product_id as string, name: head.product_name as string }
      return success(name, `ventas de un producto del ${formatRangeEs(desde, hasta)}`,
        { desde, hasta, agrupar: a.agrupar, rows, window_clamped: clamped(all) }, rows.length, focus)
    }
    case "cuentas_por_cobrar":
    case "cuentas_por_pagar": {
      const isReceivable = name === "cuentas_por_cobrar"
      const res = await deps.rpc(isReceivable ? "rpc_receivables_report" : "rpc_payables_report", { p_account_id: acc })
      if (res.error) return UNAVAILABLE
      const all = asRows(res.data)
      // El total sale de TODAS las filas, antes de recortar la lista (igual que /reports/receivables/summary).
      let totalBalance = 0
      let totalOverdue = 0
      for (const r of all) {
        totalBalance += num(r.balance) ?? 0
        totalOverdue += num(r.overdue_total) ?? 0
      }
      const sorted = [...all].sort((x, y) => (num(y.balance) ?? 0) - (num(x.balance) ?? 0))
      const idKey = isReceivable ? "client_id" : "supplier_id"
      const nameKey = isReceivable ? "client_name" : "supplier_name"
      const rows = sorted.slice(0, a.limite as number).map((r) =>
        pick(r, ["balance", "overdue_total", "days_overdue_max", "days_since_last_charge", "days_since_last_payment", "amount_overdue_1_30", "amount_overdue_31_60", "amount_overdue_60_plus"],
          [idKey, nameKey, "oldest_due_date", "last_payment_date"]))
      const focus: Partial<FocusState> = {}
      if (isReceivable && rows.length === 1 && typeof rows[0][idKey] === "string" && typeof rows[0][nameKey] === "string") {
        focus.client = { id: rows[0][idKey] as string, name: rows[0][nameKey] as string }
      }
      return success(name, isReceivable ? "cuentas por cobrar" : "cuentas por pagar",
        { total_balance: totalBalance, total_overdue: totalOverdue, debtors_count: all.length, rows }, rows.length, focus)
    }
    case "comparar_periodos": {
      const res = await deps.rpc("rpc_period_comparison", {
        p_a_start: a.a_desde, p_a_end: a.a_hasta, p_b_start: a.b_desde, p_b_end: a.b_hasta,
      })
      if (res.error) return UNAVAILABLE
      const row = asRows(res.data)[0]
      if (!row) return success(name, "comparación de períodos", { sin_datos: true }, 0)
      const cmp = pick(row, [
        "period_a_revenue", "period_a_expenses", "period_a_purchases", "period_a_operations",
        "period_b_revenue", "period_b_expenses", "period_b_purchases", "period_b_operations",
        "revenue_delta_pct", "expenses_delta_pct", "purchases_delta_pct", "operations_delta_pct",
      ], [])
      return success(name,
        `comparación del ${formatRangeEs(a.a_desde as string, a.a_hasta as string)} contra el ${formatRangeEs(a.b_desde as string, a.b_hasta as string)}`,
        { a: { desde: a.a_desde, hasta: a.a_hasta }, b: { desde: a.b_desde, hasta: a.b_hasta }, ...cmp }, 1,
        { period: periodOf(a.a_desde, a.a_hasta) })
    }
    case "rentabilidad_productos": {
      const res = await deps.rpc("rpc_product_profitability", { p_period_days: a.dias })
      if (res.error) return UNAVAILABLE
      const all = asRows(res.data)
      const dir = a.orden === "mejor" ? -1 : 1
      const sorted = [...all].sort((x, y) => dir * ((num(x.gross_margin) ?? 0) - (num(y.gross_margin) ?? 0)) || String(x.product_name).localeCompare(String(y.product_name)))
      const rows = sorted.slice(0, Math.min(a.limite as number, CAP_PROFITABILITY)).map((r) =>
        pick(r, ["total_revenue", "total_cost", "gross_margin", "gross_margin_pct", "units_sold"], ["product_id", "product_name", "last_sale_date"]))
      return success(name, `rentabilidad de productos de los últimos ${a.dias} días`,
        { dias: a.dias, orden: a.orden, products_total: all.length, rows }, rows.length)
    }
  }
}
