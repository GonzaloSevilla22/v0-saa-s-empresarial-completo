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
import { SALE_CHANNELS } from "@/lib/kpi-format"

export type EvolutionBucket = "day" | "week" | "month"
export type RankingOrder = "units" | "revenue" | "margin"
/** E2: las cinco dimensiones de GET /reports/statistics/breakdown. */
export type BreakdownDimension = "canal" | "branch" | "weekday" | "hour" | "category"

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

// ═══ E2 — desgloses por dimensión y top clientes ═════════════════════════════
// GET /reports/statistics/breakdown (rpc_sales_breakdown) y
// /reports/statistics/clients (rpc_sales_top_clients).

/**
 * Rótulos de las dimensiones. La horaria dice "de carga" A PROPÓSITO (OQ-1):
 * deriva de `created_at` — cuándo se registró la operación — no de cuándo se
 * vendió, porque la fecha de negocio no tiene hora. Nada en la UI promete
 * "horario de venta".
 */
export const BREAKDOWN_DIMENSION_LABELS: Record<BreakdownDimension, string> = {
  canal:    "Canal",
  branch:   "Sucursal",
  weekday:  "Día de la semana",
  hour:     "Horario de carga",
  category: "Categoría",
}

export interface SalesBreakdownRowRaw {
  /** Valor crudo de la dimensión; null = tramo "Sin canal" / "Sin sucursal" /
   *  "Sin categoría", que NUNCA se omite. */
  key: string | null
  label: string
  sort_order: number
  revenue: string | number | null
  units: string | number | null
  operations: number | string | null
}

export interface SalesBreakdownRaw {
  dimension: BreakdownDimension
  window: StatisticsWindowRaw | null
  rows: SalesBreakdownRowRaw[]
}

export interface SalesBreakdownRow {
  key: string | null
  label: string
  sortOrder: number
  revenue: number
  units: number
  operations: number
}

export interface SalesBreakdown {
  dimension: BreakdownDimension
  window: StatisticsWindow | null
  rows: SalesBreakdownRow[]
}

export function mapSalesBreakdown(raw: SalesBreakdownRaw): SalesBreakdown {
  return {
    dimension: raw.dimension,
    window:    raw.window ? mapStatisticsWindow(raw.window) : null,
    rows:      raw.rows.map((r) => ({
      key:        r.key ?? null,
      label:      r.label,
      sortOrder:  toNumber(r.sort_order),
      revenue:    toNumber(r.revenue),
      units:      toNumber(r.units),
      operations: toNumber(r.operations),
    })),
  }
}

const CHANNEL_FULL_LABEL: Record<string, string> = Object.fromEntries(
  SALE_CHANNELS.map((c) => [c.value, c.label]),
)

/**
 * Rótulo de presentación de un tramo. Para canal se usa la etiqueta completa
 * del catálogo de canales del formulario de venta (SALE_CHANNELS — la misma
 * fuente, no una segunda tabla), capitalizando los desconocidos; el tramo
 * sin clave conserva su rótulo ("Sin canal"). Las demás dimensiones ya
 * llegan rotuladas por el read-model (nombre del catálogo, día, "HH:00").
 */
export function breakdownRowLabel(row: SalesBreakdownRow, dimension: BreakdownDimension): string {
  if (dimension !== "canal" || row.key === null) return row.label
  return CHANNEL_FULL_LABEL[row.key] ?? row.key.charAt(0).toUpperCase() + row.key.slice(1)
}

export interface BreakdownTotals {
  revenue: number
  units: number
  operations: number
}

export function sumBreakdown(rows: SalesBreakdownRow[]): BreakdownTotals {
  return rows.reduce<BreakdownTotals>(
    (acc, r) => ({
      revenue:    acc.revenue + r.revenue,
      units:      acc.units + r.units,
      operations: acc.operations + r.operations,
    }),
    { revenue: 0, units: 0, operations: 0 },
  )
}

/** Participación (%) de un tramo sobre el total, con un decimal; null sin
 *  total (ni NaN ni un 0 que mentiría). */
export function shareOf(value: number, total: number): number | null {
  if (!total) return null
  return Math.round((value / total) * 1000) / 10
}

export interface HourBand {
  key: string
  label: string
  /** Hora inicial incluida. */
  from: number
  /** Hora final excluida. */
  to: number
}

/** D5: la franja es PRESENTACIÓN — el read-model devuelve la hora cruda 0-23
 *  y los cortes viven acá; cambiarlos no toca la base. */
export const HOUR_BANDS: readonly HourBand[] = [
  { key: "madrugada", label: "Madrugada (0–6)", from: 0,  to: 6 },
  { key: "manana",    label: "Mañana (6–12)",   from: 6,  to: 12 },
  { key: "tarde",     label: "Tarde (12–19)",   from: 12, to: 19 },
  { key: "noche",     label: "Noche (19–24)",   from: 19, to: 24 },
]

/** Agrupa las filas de la dimensión horaria (key = hora 0-23) en las cuatro
 *  franjas, sumando; una franja sin filas queda en cero, nunca se omite. */
export function groupHoursIntoBands(rows: SalesBreakdownRow[]): SalesBreakdownRow[] {
  return HOUR_BANDS.map((band, i) => {
    const inBand = rows.filter((r) => {
      const hour = Number(r.key)
      return Number.isFinite(hour) && hour >= band.from && hour < band.to
    })
    return { key: band.key, label: band.label, sortOrder: i + 1, ...sumBreakdown(inBand) }
  })
}

// ── Top clientes (OQ-2) ─────────────────────────────────────────────────────

interface ClientMetricsRaw {
  revenue: string | number | null
  units: string | number | null
  operations: number | string | null
  last_sale_date?: string | null
}

export interface TopClientRowRaw extends ClientMetricsRaw {
  rank: number
  /** null cuando la venta referencia un cliente que no es de la cuenta: rankea
   *  con el nombre de reemplazo, sin exponer datos ajenos. */
  client_id: string | null
  client_name: string
}

export type UnassignedSalesRaw = ClientMetricsRaw

export interface TopClientsRaw {
  window: StatisticsWindowRaw
  items: TopClientRowRaw[]
  unassigned: UnassignedSalesRaw
  total_clients: number
}

interface ClientMetrics {
  revenue: number
  units: number
  operations: number
  lastSaleDate: string | null
}

export interface TopClientRow extends ClientMetrics {
  rank: number
  clientId: string | null
  clientName: string
}

export type UnassignedSales = ClientMetrics

export interface TopClients {
  window: StatisticsWindow
  items: TopClientRow[]
  /** Importe de las ventas sin cliente: NO compite en el ranking, se declara. */
  unassigned: UnassignedSales
  totalClients: number
}

function mapClientMetrics(raw: ClientMetricsRaw): ClientMetrics {
  return {
    revenue:      toNumber(raw.revenue),
    units:        toNumber(raw.units),
    operations:   toNumber(raw.operations),
    lastSaleDate: raw.last_sale_date ?? null,
  }
}

export function mapTopClients(raw: TopClientsRaw): TopClients {
  return {
    window:       mapStatisticsWindow(raw.window),
    items:        raw.items.map((i) => ({
      rank:       toNumber(i.rank),
      clientId:   i.client_id ?? null,
      clientName: i.client_name,
      ...mapClientMetrics(i),
    })),
    unassigned:   mapClientMetrics(raw.unassigned),
    totalClients: toNumber(raw.total_clients),
  }
}
