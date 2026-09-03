/**
 * estadisticas-ventas E1 — capa canónica del módulo de estadísticas de ventas
 * (task 4.2). Lectura de GET /reports/statistics/evolution y
 * /reports/statistics/products (backend FastAPI sobre rpc_sales_evolution y
 * rpc_product_ranking). Espejo de lib/payment-method-report.ts.
 *
 * El mapeo, los rótulos y la presentación del margen viven acá (no en la
 * pantalla) para que sean testeables y reutilizables por E2/E3.
 *
 * Reglas:
 * - Los importes llegan como string (Decimal) y se normalizan a number.
 * - Un margen ausente (null) se PRESERVA: la superficie muestra "—", nunca
 *   0 ni un margen inventado (D11).
 * - Las fechas de negocio ("YYYY-MM-DD") se formatean por partes, sin pasar
 *   por `Date`, para que la zona del navegador no corra el día
 *   (reporting-invariants "fecha de negocio vs instante").
 */

import { formatMoney } from "@/lib/format"

export type EvolutionBucket = "day" | "week" | "month"
export type RankingOrder = "units" | "revenue" | "margin"

export const EVOLUTION_BUCKET_LABELS: Record<EvolutionBucket, string> = {
  day:   "Día",
  week:  "Semana",
  month: "Mes",
}

export const RANKING_ORDER_LABELS: Record<RankingOrder, string> = {
  units:   "Unidades",
  revenue: "Importe",
  margin:  "Margen",
}

// ── Contratos crudos (tal como responde el backend) ─────────────────────────

export interface StatisticsWindowRaw {
  start: string
  end: string
  history_days: number
  clamped: boolean
}

interface PeriodMetricsRaw {
  revenue: string | number | null
  credit_notes: string | number | null
  net_revenue: string | number | null
  units: string | number | null
  operations: number | string | null
  service_revenue: string | number | null
}

export interface SalesEvolutionPointRaw extends PeriodMetricsRaw {
  bucket_start: string
  bucket_end: string
}

export interface SalesPeriodTotalsRaw extends PeriodMetricsRaw {
  start: string
  end: string
}

export interface SalesEvolutionRaw {
  bucket: EvolutionBucket
  window: StatisticsWindowRaw
  points: SalesEvolutionPointRaw[]
  current: SalesPeriodTotalsRaw
  previous: SalesPeriodTotalsRaw
}

export interface ProductRankingRowRaw {
  rank: number
  product_id: string
  product_name: string
  sku?: string | null
  category?: string | null
  parent_id?: string | null
  parent_name?: string | null
  is_group: boolean
  variant_count: number
  units: string | number | null
  revenue: string | number | null
  operations: number | string | null
  total_cost?: string | number | null
  gross_margin?: string | number | null
  gross_margin_pct?: string | number | null
  cost_coverage_pct: string | number | null
  last_sale_date?: string | null
}

export interface ProductRankingPageRaw {
  items: ProductRankingRowRaw[]
  total: number
  page: number
  pages: number
  window: StatisticsWindowRaw | null
}

// ── Modelo de la pantalla ───────────────────────────────────────────────────

export interface StatisticsWindow {
  start: string
  end: string
  historyDays: number
  clamped: boolean
}

interface PeriodMetrics {
  revenue: number
  creditNotes: number
  netRevenue: number
  units: number
  operations: number
  serviceRevenue: number
}

export interface SalesEvolutionPoint extends PeriodMetrics {
  bucketStart: string
  bucketEnd: string
}

export interface SalesPeriodTotals extends PeriodMetrics {
  start: string
  end: string
}

export interface SalesEvolution {
  bucket: EvolutionBucket
  window: StatisticsWindow
  points: SalesEvolutionPoint[]
  current: SalesPeriodTotals
  previous: SalesPeriodTotals
}

export interface ProductRankingRow {
  rank: number
  productId: string
  productName: string
  sku: string | null
  category: string | null
  parentId: string | null
  parentName: string | null
  isGroup: boolean
  variantCount: number
  units: number
  revenue: number
  operations: number
  totalCost: number | null
  grossMargin: number | null
  grossMarginPct: number | null
  costCoveragePct: number
  lastSaleDate: string | null
}

export interface ProductRankingPage {
  items: ProductRankingRow[]
  total: number
  page: number
  pages: number
  window: StatisticsWindow | null
}

// ── Mapeos ──────────────────────────────────────────────────────────────────

function toNumber(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

/** Como toNumber, pero un valor ausente sigue ausente (margen sin costo, D11). */
function toNullableNumber(value: string | number | null | undefined): number | null {
  if (value === null || value === undefined) return null
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

function mapMetrics(raw: PeriodMetricsRaw): PeriodMetrics {
  return {
    revenue:        toNumber(raw.revenue),
    creditNotes:    toNumber(raw.credit_notes),
    netRevenue:     toNumber(raw.net_revenue),
    units:          toNumber(raw.units),
    operations:     toNumber(raw.operations),
    serviceRevenue: toNumber(raw.service_revenue),
  }
}

export function mapStatisticsWindow(raw: StatisticsWindowRaw): StatisticsWindow {
  return {
    start:       raw.start,
    end:         raw.end,
    historyDays: toNumber(raw.history_days),
    clamped:     Boolean(raw.clamped),
  }
}

export function mapSalesEvolution(raw: SalesEvolutionRaw): SalesEvolution {
  return {
    bucket:  raw.bucket,
    window:  mapStatisticsWindow(raw.window),
    points:  raw.points.map((p) => ({
      bucketStart: p.bucket_start,
      bucketEnd:   p.bucket_end,
      ...mapMetrics(p),
    })),
    current:  { start: raw.current.start,  end: raw.current.end,  ...mapMetrics(raw.current) },
    previous: { start: raw.previous.start, end: raw.previous.end, ...mapMetrics(raw.previous) },
  }
}

export function mapProductRankingRow(raw: ProductRankingRowRaw): ProductRankingRow {
  return {
    rank:            raw.rank,
    productId:       raw.product_id,
    productName:     raw.product_name,
    sku:             raw.sku ?? null,
    category:        raw.category ?? null,
    parentId:        raw.parent_id ?? null,
    parentName:      raw.parent_name ?? null,
    isGroup:         Boolean(raw.is_group),
    variantCount:    toNumber(raw.variant_count),
    units:           toNumber(raw.units),
    revenue:         toNumber(raw.revenue),
    operations:      toNumber(raw.operations),
    totalCost:       toNullableNumber(raw.total_cost),
    grossMargin:     toNullableNumber(raw.gross_margin),
    grossMarginPct:  toNullableNumber(raw.gross_margin_pct),
    costCoveragePct: toNumber(raw.cost_coverage_pct),
    lastSaleDate:    raw.last_sale_date ?? null,
  }
}

export function mapProductRankingPage(raw: ProductRankingPageRaw): ProductRankingPage {
  return {
    items:  raw.items.map(mapProductRankingRow),
    total:  raw.total,
    page:   raw.page,
    pages:  raw.pages,
    window: raw.window ? mapStatisticsWindow(raw.window) : null,
  }
}

// ── Presentación ────────────────────────────────────────────────────────────

/**
 * Variación relativa (%) del período actual contra el anterior, redondeada a
 * entero. Sin base de comparación (anterior = 0) devuelve null: la tarjeta no
 * muestra variación, en vez de un +Infinity o un 0 que mentiría.
 */
export function percentChange(current: number, previous: number): number | null {
  if (!previous) return null
  return Math.round(((current - previous) / previous) * 100)
}

const MONTHS_ES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

/** Partes de una fecha de negocio "YYYY-MM-DD" — sin `Date`, sin zona. */
function businessDateParts(iso: string): { yyyy: string; mm: string; dd: string } {
  const [yyyy = "", mm = "", dd = ""] = iso.slice(0, 10).split("-")
  return { yyyy, mm, dd }
}

/** "YYYY-MM-DD" → "dd/MM/yyyy", sin corrimiento por zona del navegador. */
export function formatBusinessDate(iso: string): string {
  const { yyyy, mm, dd } = businessDateParts(iso)
  return `${dd}/${mm}/${yyyy}`
}

/** Rótulo del bucket para ejes y tablas: día "dd/MM", semana "Sem. dd/MM"
 *  (lunes ISO), mes "MMM yyyy". */
export function formatBucketLabel(bucketStart: string, bucket: EvolutionBucket): string {
  const { yyyy, mm, dd } = businessDateParts(bucketStart)
  if (bucket === "month") {
    const month = MONTHS_ES[Number(mm) - 1] ?? mm
    return `${month} ${yyyy}`
  }
  const dayLabel = `${dd}/${mm}`
  return bucket === "week" ? `Sem. ${dayLabel}` : dayLabel
}

export interface MarginCell {
  /** Importe formateado, o "—" cuando no hay margen (D11). */
  value: string
  /** Marca de cobertura ("33% con costo") cuando no todas las líneas del
   *  grupo tienen costo congelado; null con cobertura total o sin margen. */
  coverage: string | null
}

export function marginCell(row: ProductRankingRow): MarginCell {
  if (row.grossMargin === null) return { value: "—", coverage: null }
  const coverage = row.costCoveragePct >= 100
    ? null
    : `${Math.round(row.costCoveragePct)}% con costo`
  return { value: formatMoney(row.grossMargin), coverage }
}

/** Rango por defecto de la pantalla: los últimos 30 días, hoy incluido. */
export function defaultStatisticsRange(today: Date = new Date()): { from: Date; to: Date } {
  const from = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 29)
  return { from, to: today }
}
