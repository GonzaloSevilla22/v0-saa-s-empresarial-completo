// Export del ranking de productos a CSV — estadisticas-ventas E3 (grupo 8).
//
// Lo consume generate-export/index.ts para el 6º ExportType
// (`product_ranking_csv`). Regla dura (spec data-export, "El archivo del
// ranking coincide con la pantalla"): las filas del CSV salen del read-model
// canónico `rpc_product_ranking` con los MISMOS parámetros que la pantalla
// (período, orden, agrupación de variantes, sucursal), 1:1 y en el mismo
// orden — acá no se agrega, no se reordena, no se filtra. Un archivo que no
// coincide con la pantalla de la que se exportó es indistinguible de un
// archivo corrupto.
//
// La lista de tipos de exportación vive UNA sola vez (EXPORT_TYPES) y el
// tipo `ExportType` deriva de ella: generate-export tenía la unión y el
// array duplicados, y cambiar uno solo lo dejaba roto (task 8.3).
//
// TS puro, sin `Deno.*` a nivel módulo: deployable a Deno y testeable desde
// vitest por ruta relativa (frontend/__tests__/export-ranking.test.ts).

import {
  parseBusinessDateRange,
  parseOptionalUuid,
  type ParseResult,
} from "./statistics-params.ts"

// ─── Tipos de exportación (única fuente) ──────────────────────────────────────

export const EXPORT_TYPES = [
  "sales_csv",
  "purchases_csv",
  "expenses_csv",
  "stock_csv",
  "full_report_xlsx",
  "product_ranking_csv",
] as const

export type ExportType = (typeof EXPORT_TYPES)[number]

export function isExportType(value: unknown): value is ExportType {
  return typeof value === "string" && (EXPORT_TYPES as readonly string[]).includes(value)
}

// ─── Parámetros del ranking (los de la pantalla) ──────────────────────────────

export const RANKING_ORDERS = ["units", "revenue", "margin"] as const
export type RankingOrder = (typeof RANKING_ORDERS)[number]

export interface RankingExportParams {
  start: string
  end: string
  orderBy: RankingOrder
  groupVariants: boolean
  branchId: string | null
}

function isRankingOrder(value: unknown): value is RankingOrder {
  return typeof value === "string" && (RANKING_ORDERS as readonly string[]).includes(value)
}

/**
 * Parámetros del export desde el body de la petición. Defaults = la
 * pantalla /estadisticas recién abierta: últimos 30 días, por unidades,
 * variantes agrupadas, sin filtro de sucursal. Todo lo que no encaja en el
 * dominio se rechaza ANTES de tocar la base.
 */
export function parseRankingExportParams(
  body: Record<string, unknown>,
  now: Date,
): ParseResult<RankingExportParams> {
  const range = parseBusinessDateRange(body, now)
  if (!range.ok) return range

  const rawOrder = body["order_by"]
  if (rawOrder !== undefined && rawOrder !== null && !isRankingOrder(rawOrder)) {
    return { ok: false, error: `order_by debe ser uno de ${RANKING_ORDERS.join(", ")}` }
  }
  const orderBy: RankingOrder = isRankingOrder(rawOrder) ? rawOrder : "units"

  const rawGroup = body["group_variants"]
  if (rawGroup !== undefined && rawGroup !== null && typeof rawGroup !== "boolean") {
    return { ok: false, error: "group_variants debe ser booleano" }
  }
  const groupVariants = typeof rawGroup === "boolean" ? rawGroup : true

  const branch = parseOptionalUuid(body, "branch_id")
  if (!branch.ok) return branch

  return {
    ok: true,
    value: { start: range.value.start, end: range.value.end, orderBy, groupVariants, branchId: branch.value },
  }
}

// ─── Read-model → CSV ─────────────────────────────────────────────────────────

/** Fila de rpc_product_ranking tal como la entrega supabase-js (los numerics
 *  de Postgres llegan como string). */
export interface ProductRankingRpcRow {
  rank: number
  product_id: string
  product_name: string
  sku: string | null
  category: string | null
  parent_id: string | null
  parent_name: string | null
  is_group: boolean
  variant_count: number
  units: number | string
  revenue: number | string
  operations: number | string
  total_cost: number | string | null
  gross_margin: number | string | null
  gross_margin_pct: number | string | null
  cost_coverage_pct: number | string
  last_sale_date: string | null
  total_count: number | string
}

export const RANKING_CSV_HEADERS = [
  "puesto",
  "producto",
  "sku",
  "categoria",
  "producto_padre",
  "variantes",
  "unidades",
  "importe",
  "operaciones",
  "costo",
  "margen",
  "margen_pct",
  "cobertura_costo_pct",
  "ultima_venta",
] as const

export type RankingCsvRow = Record<(typeof RANKING_CSV_HEADERS)[number], string | number>

/** D11: un margen / costo ausente es celda VACÍA — nunca 0, nunca un valor
 *  inventado. */
function cell(value: number | string | null | undefined): string | number {
  return value === null || value === undefined ? "" : value
}

export function rankingRowToCsvRow(row: ProductRankingRpcRow): RankingCsvRow {
  return {
    puesto:              row.rank,
    producto:            row.product_name,
    sku:                 cell(row.sku),
    categoria:           cell(row.category),
    producto_padre:      cell(row.parent_name),
    variantes:           row.variant_count,
    unidades:            cell(row.units),
    importe:             cell(row.revenue),
    operaciones:         cell(row.operations),
    costo:               cell(row.total_cost),
    margen:              cell(row.gross_margin),
    margen_pct:          cell(row.gross_margin_pct),
    cobertura_costo_pct: cell(row.cost_coverage_pct),
    ultima_venta:        cell(row.last_sale_date),
  }
}

/** Serialización CSV (RFC 4180: coma, CRLF, comillas dobladas). Movida acá
 *  desde generate-export/index.ts sin cambios de comportamiento para que sea
 *  testeable; el index sigue usándola para los otros cinco tipos. */
export function rowsToCsv(headers: readonly string[], rows: Record<string, unknown>[]): string {
  const escape = (v: unknown) => {
    const s = v == null ? "" : String(v)
    return s.includes(",") || s.includes('"') || s.includes("\n")
      ? `"${s.replace(/"/g, '""')}"`
      : s
  }
  const lines = [headers.join(",")]
  for (const row of rows) {
    lines.push(headers.map((h) => escape(row[h])).join(","))
  }
  return lines.join("\r\n")
}

export function buildRankingCsv(rows: ProductRankingRpcRow[]): string {
  return rowsToCsv(RANKING_CSV_HEADERS, rows.map(rankingRowToCsvRow))
}

// ─── Lectura del read-model, paginada ─────────────────────────────────────────

/** rpc_product_ranking acota p_limit a 500; el export recorre las páginas
 *  con los mismos parámetros hasta agotar el conjunto o el tope (mismo tope
 *  de 10.000 filas que los otros exports). */
export const RANKING_PAGE_SIZE = 500
export const RANKING_MAX_ROWS = 10_000

export interface RankingRpcArgs {
  p_account_id: string
  p_start: string
  p_end: string
  p_order_by: RankingOrder
  p_group_variants: boolean
  p_branch_id: string | null
  p_canal: null
  p_limit: number
  p_offset: number
}

/** Forma estructural mínima del cliente Supabase que este módulo necesita —
 *  sin `any` (regla dura del proyecto). */
export interface RankingRpcClient {
  rpc(
    fn: "rpc_product_ranking",
    args: RankingRpcArgs,
  ): Promise<{ data: ProductRankingRpcRow[] | null; error: { message: string } | null }>
}

export async function fetchAllRankingRows(
  client: RankingRpcClient,
  accountId: string,
  params: RankingExportParams,
): Promise<ProductRankingRpcRow[]> {
  const rows: ProductRankingRpcRow[] = []
  let offset = 0
  while (rows.length < RANKING_MAX_ROWS) {
    const { data, error } = await client.rpc("rpc_product_ranking", {
      p_account_id: accountId,
      p_start: params.start,
      p_end: params.end,
      p_order_by: params.orderBy,
      p_group_variants: params.groupVariants,
      p_branch_id: params.branchId,
      p_canal: null,
      p_limit: RANKING_PAGE_SIZE,
      p_offset: offset,
    })
    if (error) {
      // Nunca un CSV vacío que parezca "sin ventas": el error se propaga.
      throw new Error(`rpc_product_ranking: ${error.message}`)
    }
    const page = data ?? []
    rows.push(...page)
    if (page.length < RANKING_PAGE_SIZE) break
    offset += RANKING_PAGE_SIZE
  }
  return rows.slice(0, RANKING_MAX_ROWS)
}
