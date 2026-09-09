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
import { argentinaToday } from "./argentina-time.ts"

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

/** Hallazgo del PO (2026-09-04, humo real): los numerics de Postgres llegan
 *  como string con PUNTO decimal ("1234.56"); Excel en español (Argentina)
 *  usa COMA decimal y toma un punto como separador de miles o directamente
 *  como texto — el PO no podía sumar la columna. Se convierte el punto a
 *  coma SOLO acá (ranking): es un reporte de análisis que nadie re-importa.
 *  D11 sigue vigente: una celda ausente sigue VACÍA, nunca "0". */
function decimalCell(value: number | string | null | undefined): string {
  if (value === null || value === undefined) return ""
  return String(value).replace(".", ",")
}

export function rankingRowToCsvRow(row: ProductRankingRpcRow): RankingCsvRow {
  return {
    puesto:              row.rank,
    producto:            row.product_name,
    sku:                 cell(row.sku),
    categoria:           cell(row.category),
    producto_padre:      cell(row.parent_name),
    variantes:           row.variant_count,
    unidades:            decimalCell(row.units),
    importe:             decimalCell(row.revenue),
    operaciones:         cell(row.operations),
    costo:               decimalCell(row.total_cost),
    margen:              decimalCell(row.gross_margin),
    margen_pct:          decimalCell(row.gross_margin_pct),
    cobertura_costo_pct: decimalCell(row.cost_coverage_pct),
    ultima_venta:        cell(row.last_sale_date),
  }
}

/** Serialización CSV (RFC 4180 con separador `;`, CRLF, comillas dobladas).
 *  Movida acá desde generate-export/index.ts; el index sigue usándola para
 *  los otros cinco tipos. Separador `;` (no coma): hallazgo del PO
 *  (2026-09-04) — Excel con configuración regional es-AR usa `;` como
 *  separador de listas, la misma convención que ya usa el export local
 *  `frontend/lib/excel.ts` (`exportToCSV`). Un CSV con comas se abre en
 *  Excel es-AR con todo apilado en la columna A. La coma se conserva en la
 *  lista de caracteres que fuerzan comillas (ya no es el separador, pero
 *  sigue siendo más seguro entrecomillar un valor que la contenga). */
export function rowsToCsv(headers: readonly string[], rows: Record<string, unknown>[]): string {
  const escape = (v: unknown) => {
    const s = v == null ? "" : String(v)
    return s.includes(";") || s.includes(",") || s.includes('"') || s.includes("\n")
      ? `"${s.replace(/"/g, '""')}"`
      : s
  }
  const lines = [headers.join(";")]
  for (const row of rows) {
    lines.push(headers.map((h) => escape(row[h])).join(";"))
  }
  return lines.join("\r\n")
}

export function buildRankingCsv(rows: ProductRankingRpcRow[]): string {
  return rowsToCsv(RANKING_CSV_HEADERS, rows.map(rankingRowToCsvRow))
}

// ─── Read-model → hoja XLSX (5ª hoja del reporte completo) ────────────────────
//
// Mismas columnas que el CSV (mismo orden, MISMOS nombres — RANKING_XLSX_HEADERS
// === RANKING_CSV_HEADERS) pero SheetJS necesita `number` en las columnas
// numéricas para que Excel las trate como cantidades (sumables/filtrables),
// no como texto: a diferencia de rankingRowToCsvRow (D11: coma decimal para
// Excel es-AR, que exige string), acá NO se convierte a string ni se
// reemplaza el punto decimal. D11 sí se mantiene igual: una celda ausente es
// "" vacía, nunca 0.

export const RANKING_XLSX_HEADERS = RANKING_CSV_HEADERS

export type RankingXlsxRow = Record<(typeof RANKING_XLSX_HEADERS)[number], string | number>

function numberCell(value: number | string | null | undefined): string | number {
  if (value === null || value === undefined) return ""
  return typeof value === "number" ? value : Number(value)
}

export function rankingRowToXlsxRow(row: ProductRankingRpcRow): RankingXlsxRow {
  return {
    puesto:              row.rank,
    producto:            row.product_name,
    sku:                 cell(row.sku),
    categoria:           cell(row.category),
    producto_padre:      cell(row.parent_name),
    variantes:           row.variant_count,
    unidades:            numberCell(row.units),
    importe:             numberCell(row.revenue),
    // Revisión adversarial (fix 10): `operations` puede llegar como bigint de
    // Postgres serializado en string (p.ej. "3") — con `cell()` la celda
    // quedaba de texto en Excel (no sumable/filtrable), la misma clase de bug
    // que `numberCell` ya resuelve para unidades/importe/costo/margen.
    operaciones:         numberCell(row.operations),
    costo:               numberCell(row.total_cost),
    margen:              numberCell(row.gross_margin),
    margen_pct:          numberCell(row.gross_margin_pct),
    cobertura_costo_pct: numberCell(row.cost_coverage_pct),
    ultima_venta:        cell(row.last_sale_date),
  }
}

export function buildRankingXlsxRows(rows: ProductRankingRpcRow[]): RankingXlsxRow[] {
  return rows.map(rankingRowToXlsxRow)
}

/** Parámetros del ranking dentro del reporte completo (`full_report_xlsx`):
 *  no tiene pantalla ni filtros propios, así que usa el MISMO período que
 *  ya rigen las otras hojas del reporte (`dateFrom` del historial del plan
 *  → hoy) con los defaults de /estadisticas (unidades, agrupado, sin
 *  sucursal) — documentado acá en vez de quedar implícito en el índice de
 *  la función. El fin de ventana es el día de negocio ARGENTINO
 *  (`argentinaToday`, D1 de `_shared/argentina-time.ts`), no el día UTC del
 *  runtime: a las 21:00-23:59 ART el día UTC ya rodó a mañana. */
export function defaultFullReportRankingParams(dateFrom: string, now: Date): RankingExportParams {
  return {
    start: dateFrom,
    end: argentinaToday(now),
    orderBy: "units",
    groupVariants: true,
    branchId: null,
  }
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
  ): PromiseLike<{ data: ProductRankingRpcRow[] | null; error: { message: string } | null }>
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

/**
 * Filas de ranking para la 5ª hoja ("Ranking") del reporte completo
 * (`full_report_xlsx`), con degradado: si `accountId` no se resolvió o si
 * `rpc_product_ranking` falla, la hoja queda VACÍA en vez de tirar abajo el
 * reporte entero — las otras 4 hojas (Ventas/Compras/Gastos/Inventario) no
 * dependen de `account_members` ni del ranking.
 *
 * Revisión adversarial (fix 1): antes, `generate-export/index.ts` armaba las
 * 5 hojas con un solo `Promise.all` donde esta rama NO tenía `.catch()` — un
 * error de `rpc_product_ranking` (p.ej. P0401) rechazaba el `Promise.all`
 * ENTERO y el reporte completo se caía sin generar ninguna hoja, pese a que
 * el comentario de al lado prometía degradar. Extraída acá (en vez de un
 * `.catch()` inline en el índice) para ser testeable sin `Deno.serve`/SheetJS
 * — `generate-export/index.ts` no es importable desde vitest.
 */
export async function fetchFullReportRankingRows(
  client: RankingRpcClient,
  accountId: string | null,
  dateFrom: string,
  now: Date,
): Promise<ProductRankingRpcRow[]> {
  if (!accountId) return []
  try {
    return await fetchAllRankingRows(client, accountId, defaultFullReportRankingParams(dateFrom, now))
  } catch (err) {
    console.error("[generate-export] ranking degradado, hoja vacía:", err)
    return []
  }
}
