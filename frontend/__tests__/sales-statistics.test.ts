/**
 * estadisticas-ventas E1 (task 4.2) — capa canónica del módulo:
 * lib/sales-statistics.ts. Mapeos de fila (string → number, null se preserva),
 * variación contra el período anterior, rótulos de bucket y la celda de margen
 * con su cobertura (D11: "—" cuando no hay costo, NUNCA 0).
 */
import { describe, it, expect } from "vitest"
import {
  mapSalesEvolution,
  mapProductRankingRow,
  mapProductRankingPage,
  percentChange,
  formatBucketLabel,
  marginCell,
  defaultStatisticsRange,
  type SalesEvolutionRaw,
  type ProductRankingRowRaw,
} from "@/lib/sales-statistics"

const WINDOW_RAW = { start: "2026-08-02", end: "2026-08-31", history_days: 30, clamped: true }

const EVOLUTION_RAW: SalesEvolutionRaw = {
  bucket: "day",
  window: WINDOW_RAW,
  points: [
    { bucket_start: "2026-08-02", bucket_end: "2026-08-02", revenue: "2900", credit_notes: "150", net_revenue: "2750", units: "4", operations: 2, service_revenue: "400" },
    { bucket_start: "2026-08-03", bucket_end: "2026-08-03", revenue: "0", credit_notes: "0", net_revenue: "0", units: "0", operations: 0, service_revenue: "0" },
  ],
  current: { start: "2026-08-02", end: "2026-08-31", revenue: "2900", credit_notes: "150", net_revenue: "2750", units: "4", operations: 2, service_revenue: "400" },
  previous: { start: "2026-07-03", end: "2026-08-01", revenue: "333", credit_notes: "0", net_revenue: "333", units: "1", operations: 1, service_revenue: "0" },
}

const ROW_RAW: ProductRankingRowRaw = {
  rank: 2,
  product_id: "p-parent",
  product_name: "Remera",
  sku: null,
  category: "Ropa",
  parent_id: null,
  parent_name: null,
  is_group: true,
  variant_count: 2,
  units: "4",
  revenue: "2600",
  operations: 2,
  total_cost: "350",
  gross_margin: "2250",
  gross_margin_pct: "86.54",
  cost_coverage_pct: "0.0",
  last_sale_date: "2026-08-31",
}

describe("mapSalesEvolution", () => {
  it("convierte importes string a number y conserva la ventana aplicada (D8)", () => {
    const evo = mapSalesEvolution(EVOLUTION_RAW)
    expect(evo.window).toEqual({ start: "2026-08-02", end: "2026-08-31", historyDays: 30, clamped: true })
    expect(evo.points).toHaveLength(2)
    expect(evo.points[0]).toEqual({
      bucketStart: "2026-08-02", bucketEnd: "2026-08-02",
      revenue: 2900, creditNotes: 150, netRevenue: 2750, units: 4, operations: 2, serviceRevenue: 400,
    })
    expect(evo.current.netRevenue).toBe(2750)
    expect(evo.current.serviceRevenue).toBe(400)
    expect(evo.previous.revenue).toBe(333)
    expect(evo.previous.start).toBe("2026-07-03")
  })

  it("un bucket en cero sigue siendo un punto (no se omite)", () => {
    const evo = mapSalesEvolution(EVOLUTION_RAW)
    expect(evo.points[1].netRevenue).toBe(0)
    expect(evo.points[1].operations).toBe(0)
  })
})

describe("mapProductRankingRow / mapProductRankingPage", () => {
  it("mapea la fila agrupada con su cantidad de variantes y su margen", () => {
    const row = mapProductRankingRow(ROW_RAW)
    expect(row.productId).toBe("p-parent")
    expect(row.isGroup).toBe(true)
    expect(row.variantCount).toBe(2)
    expect(row.units).toBe(4)
    expect(row.revenue).toBe(2600)
    expect(row.grossMargin).toBe(2250)
    expect(row.grossMarginPct).toBe(86.54)
    expect(row.costCoveragePct).toBe(0)
    expect(row.lastSaleDate).toBe("2026-08-31")
  })

  it("un margen ausente queda null — jamás degradado a 0 (D11)", () => {
    const row = mapProductRankingRow({ ...ROW_RAW, total_cost: null, gross_margin: null, gross_margin_pct: null })
    expect(row.grossMargin).toBeNull()
    expect(row.grossMarginPct).toBeNull()
    expect(row.totalCost).toBeNull()
  })

  it("la variante sin agrupar lleva su padre como contexto", () => {
    const row = mapProductRankingRow({ ...ROW_RAW, is_group: false, variant_count: 0, parent_id: "p-parent", parent_name: "Remera", product_name: "Remera Talle M" })
    expect(row.isGroup).toBe(false)
    expect(row.parentId).toBe("p-parent")
    expect(row.parentName).toBe("Remera")
  })

  it("la página conserva el envelope y una ventana nula cuando no hay filas", () => {
    const page = mapProductRankingPage({ items: [], total: 0, page: 0, pages: 0, window: null })
    expect(page).toEqual({ items: [], total: 0, page: 0, pages: 0, window: null })
    const page2 = mapProductRankingPage({ items: [ROW_RAW], total: 3, page: 1, pages: 2, window: WINDOW_RAW })
    expect(page2.items[0].rank).toBe(2)
    expect(page2.window?.clamped).toBe(true)
    expect(page2.pages).toBe(2)
  })
})

describe("percentChange", () => {
  it("variación relativa contra el período anterior, redondeada a entero", () => {
    expect(percentChange(150, 100)).toBe(50)
    expect(percentChange(80, 100)).toBe(-20)
    expect(percentChange(2750, 333)).toBe(726)
  })

  it("sin base de comparación devuelve null (no un +Infinity ni un 0 falso)", () => {
    expect(percentChange(100, 0)).toBeNull()
    expect(percentChange(0, 0)).toBeNull()
  })
})

describe("formatBucketLabel", () => {
  it("día → dd/MM, semana → 'Sem. dd/MM' (lunes ISO), mes → 'MMM yyyy'", () => {
    expect(formatBucketLabel("2026-08-31", "day")).toBe("31/08")
    expect(formatBucketLabel("2026-08-31", "week")).toBe("Sem. 31/08")
    expect(formatBucketLabel("2026-08-01", "month")).toMatch(/^ago 2026$/i)
  })

  it("no corre la fecha de negocio un día por la zona del navegador", () => {
    // "2026-08-31" es una fecha de negocio (sin hora): el rótulo es 31/08
    // en cualquier huso — nunca 30/08.
    expect(formatBucketLabel("2026-08-31", "day")).toBe("31/08")
    expect(formatBucketLabel("2026-01-01", "day")).toBe("01/01")
  })
})

describe("marginCell (D11)", () => {
  it("sin margen muestra '—' y ninguna cobertura", () => {
    const cell = marginCell(mapProductRankingRow({ ...ROW_RAW, gross_margin: null, gross_margin_pct: null, total_cost: null }))
    expect(cell.value).toBe("—")
    expect(cell.coverage).toBeNull()
  })

  it("con cobertura parcial declara qué proporción de líneas tiene costo congelado", () => {
    const cell = marginCell(mapProductRankingRow({ ...ROW_RAW, cost_coverage_pct: "33.3" }))
    expect(cell.value).toMatch(/2\.250/)
    expect(cell.coverage).toBe("33% con costo")
  })

  it("con cobertura total no agrega marca", () => {
    const cell = marginCell(mapProductRankingRow({ ...ROW_RAW, cost_coverage_pct: "100" }))
    expect(cell.coverage).toBeNull()
  })

  it("cobertura 0 se declara explícitamente (el margen sale del costo actual del catálogo)", () => {
    const cell = marginCell(mapProductRankingRow(ROW_RAW))
    expect(cell.coverage).toBe("0% con costo")
  })
})

describe("defaultStatisticsRange", () => {
  it("últimos 30 días incluyendo hoy", () => {
    const today = new Date(2026, 8, 3) // 3 de septiembre 2026
    const { from, to } = defaultStatisticsRange(today)
    expect(to.getTime()).toBe(today.getTime())
    expect(from.getFullYear()).toBe(2026)
    expect(from.getMonth()).toBe(7)
    expect(from.getDate()).toBe(5) // 3/9 − 29 días = 5/8
  })
})
