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
  mapSalesBreakdown,
  mapTopClients,
  breakdownRowLabel,
  breakdownChartLabel,
  groupHoursIntoBands,
  sumBreakdown,
  shareOf,
  HOUR_BANDS,
  BREAKDOWN_DIMENSION_LABELS,
  type SalesEvolutionRaw,
  type ProductRankingRowRaw,
  type SalesBreakdownRaw,
  type SalesBreakdownRow,
  type TopClientsRaw,
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

// ── E2 (task 7.x) — desgloses por dimensión, franjas horarias y top clientes ─

const BREAKDOWN_RAW: SalesBreakdownRaw = {
  dimension: "canal",
  window: WINDOW_RAW,
  rows: [
    { key: "local", label: "local", sort_order: 1, revenue: "2900", units: "4", operations: 2 },
    { key: "instagram", label: "instagram", sort_order: 2, revenue: "2100", units: "3", operations: 1 },
    { key: null, label: "Sin canal", sort_order: 3, revenue: "600", units: "2", operations: 2 },
  ],
}

function hourRow(hour: number, revenue = 0, units = 0, operations = 0): SalesBreakdownRow {
  return { key: String(hour), label: `${String(hour).padStart(2, "0")}:00`, sortOrder: hour, revenue, units, operations }
}

const HOUR_ROWS: SalesBreakdownRow[] = Array.from({ length: 24 }, (_, h) => {
  if (h === 9) return hourRow(9, 500, 2, 2)
  if (h === 14) return hourRow(14, 2600, 4, 2)
  if (h === 23) return hourRow(23, 2500, 3, 1)
  return hourRow(h)
})

describe("mapSalesBreakdown", () => {
  it("conserva el tramo sin clave (null) con su rótulo, normaliza importes y mapea la ventana", () => {
    const bd = mapSalesBreakdown(BREAKDOWN_RAW)
    expect(bd.dimension).toBe("canal")
    expect(bd.window).toEqual({ start: "2026-08-02", end: "2026-08-31", historyDays: 30, clamped: true })
    expect(bd.rows).toHaveLength(3)
    expect(bd.rows[2]).toEqual({ key: null, label: "Sin canal", sortOrder: 3, revenue: 600, units: 2, operations: 2 })
    expect(bd.rows[0].revenue).toBe(2900)
  })

  it("ventana nula y sin filas cuando la dimensión no devolvió tramos", () => {
    const bd = mapSalesBreakdown({ dimension: "category", window: null, rows: [] })
    expect(bd).toEqual({ dimension: "category", window: null, rows: [] })
  })
})

describe("breakdownRowLabel", () => {
  const row = (key: string | null, label: string): SalesBreakdownRow => ({ key, label, sortOrder: 1, revenue: 0, units: 0, operations: 0 })

  it("canal conocido → etiqueta completa del catálogo de canales; desconocido → capitalizado; sin canal → su rótulo", () => {
    expect(breakdownRowLabel(row("instagram", "instagram"), "canal")).toBe("Instagram")
    expect(breakdownRowLabel(row("mercadolibre", "mercadolibre"), "canal")).toBe("MercadoLibre")
    expect(breakdownRowLabel(row("local", "local"), "canal")).toBe("Local")
    expect(breakdownRowLabel(row("tiktok", "tiktok"), "canal")).toBe("Tiktok")
    expect(breakdownRowLabel(row(null, "Sin canal"), "canal")).toBe("Sin canal")
  })

  it("las demás dimensiones usan el rótulo del read-model tal cual", () => {
    expect(breakdownRowLabel(row("b1", "Casa central"), "branch")).toBe("Casa central")
    expect(breakdownRowLabel(row(null, "Sin sucursal"), "branch")).toBe("Sin sucursal")
    expect(breakdownRowLabel(row("1", "Lunes"), "weekday")).toBe("Lunes")
    expect(breakdownRowLabel(row("23", "23:00"), "hour")).toBe("23:00")
    expect(breakdownRowLabel(row(null, "Sin categoría"), "category")).toBe("Sin categoría")
  })
})

describe("groupHoursIntoBands (D5: la franja es presentación)", () => {
  it("agrupa las 24 horas en 4 franjas ordenadas sumando facturación, unidades y operaciones", () => {
    const bands = groupHoursIntoBands(HOUR_ROWS)
    expect(bands.map((b) => b.key)).toEqual(HOUR_BANDS.map((b) => b.key))
    expect(bands.map((b) => b.label)).toEqual(["Madrugada (0–6)", "Mañana (6–12)", "Tarde (12–19)", "Noche (19–24)"])
    expect(bands[0]).toMatchObject({ revenue: 0, units: 0, operations: 0, sortOrder: 1 })
    expect(bands[1]).toMatchObject({ revenue: 500, units: 2, operations: 2 })
    expect(bands[2]).toMatchObject({ revenue: 2600, units: 4, operations: 2 })
    expect(bands[3]).toMatchObject({ revenue: 2500, units: 3, operations: 1, sortOrder: 4 })
    // Nada se pierde al agrupar.
    expect(bands.reduce((s, b) => s + b.revenue, 0)).toBe(5600)
  })

  it("una hora en el borde inferior pertenece a su franja (6 → mañana, 12 → tarde, 19 → noche)", () => {
    const bands = groupHoursIntoBands([hourRow(6, 10, 1, 1), hourRow(12, 20, 1, 1), hourRow(19, 30, 1, 1), hourRow(5, 1, 1, 1)])
    expect(bands[0].revenue).toBe(1)
    expect(bands[1].revenue).toBe(10)
    expect(bands[2].revenue).toBe(20)
    expect(bands[3].revenue).toBe(30)
  })

  it("con filas faltantes las franjas vacías quedan en cero, nunca se omiten", () => {
    const bands = groupHoursIntoBands([hourRow(14, 100, 1, 1)])
    expect(bands).toHaveLength(4)
    expect(bands[2].revenue).toBe(100)
    expect(bands.filter((b) => b.revenue === 0)).toHaveLength(3)
  })
})

describe("sumBreakdown / shareOf", () => {
  it("suma facturación, unidades y operaciones de los tramos", () => {
    expect(sumBreakdown(mapSalesBreakdown(BREAKDOWN_RAW).rows)).toEqual({ revenue: 5600, units: 9, operations: 5 })
    expect(sumBreakdown([])).toEqual({ revenue: 0, units: 0, operations: 0 })
  })

  it("participación en % con un decimal; null sin total (no un NaN ni un 0 falso)", () => {
    expect(shareOf(2900, 5600)).toBe(51.8)
    expect(shareOf(600, 5600)).toBe(10.7)
    expect(shareOf(0, 5600)).toBe(0)
    expect(shareOf(100, 0)).toBeNull()
  })
})

describe("mapTopClients", () => {
  const raw: TopClientsRaw = {
    window: WINDOW_RAW,
    items: [
      { rank: 1, client_id: "c-a", client_name: "Ana", revenue: "2900", units: "4", operations: 2, last_sale_date: "2026-08-31" },
      { rank: 2, client_id: null, client_name: "Cliente no disponible", revenue: "100", units: "1", operations: 1, last_sale_date: "2026-08-28" },
    ],
    unassigned: { revenue: "500", units: "1", operations: 1, last_sale_date: "2026-08-29" },
    total_clients: 2,
  }

  it("mapea los items, la fila sin cliente aparte y el total de clientes", () => {
    const top = mapTopClients(raw)
    expect(top.window.clamped).toBe(true)
    expect(top.items[0]).toEqual({ rank: 1, clientId: "c-a", clientName: "Ana", revenue: 2900, units: 4, operations: 2, lastSaleDate: "2026-08-31" })
    expect(top.unassigned).toEqual({ revenue: 500, units: 1, operations: 1, lastSaleDate: "2026-08-29" })
    expect(top.totalClients).toBe(2)
  })

  it("un cliente ajeno viaja con clientId null y su nombre de reemplazo (nunca datos de otra cuenta)", () => {
    const top = mapTopClients(raw)
    expect(top.items[1].clientId).toBeNull()
    expect(top.items[1].clientName).toBe("Cliente no disponible")
  })
})

describe("BREAKDOWN_DIMENSION_LABELS", () => {
  it("la dimensión horaria se rotula como horario de carga — nunca promete horario de venta (OQ-1)", () => {
    expect(BREAKDOWN_DIMENSION_LABELS.hour).toMatch(/horario de carga/i)
    expect(BREAKDOWN_DIMENSION_LABELS.hour).not.toMatch(/venta/i)
    expect(Object.keys(BREAKDOWN_DIMENSION_LABELS).sort()).toEqual(["branch", "canal", "category", "hour", "weekday"])
  })
})

describe("breakdownChartLabel (rótulo corto del gráfico en orientación vertical)", () => {
  const row = (key: string | null, label: string): SalesBreakdownRow => ({ key, label, sortOrder: 1, revenue: 0, units: 0, operations: 0 })

  it("día de la semana → abreviatura de tres letras por isodow; la tabla conserva el nombre completo", () => {
    expect(breakdownChartLabel(row("1", "Lunes"), "weekday", false)).toBe("Lun")
    expect(breakdownChartLabel(row("3", "Miércoles"), "weekday", false)).toBe("Mié")
    expect(breakdownChartLabel(row("6", "Sábado"), "weekday", false)).toBe("Sáb")
    expect(breakdownChartLabel(row("7", "Domingo"), "weekday", false)).toBe("Dom")
  })

  it("franja horaria → nombre corto sin el rango; la hora cruda conserva HH:00", () => {
    expect(breakdownChartLabel(row("madrugada", "Madrugada (0–6)"), "hour", true)).toBe("Madrugada")
    expect(breakdownChartLabel(row("noche", "Noche (19–24)"), "hour", true)).toBe("Noche")
    expect(breakdownChartLabel(row("23", "23:00"), "hour", false)).toBe("23:00")
  })

  it("las dimensiones categóricas usan el mismo rótulo que la tabla", () => {
    expect(breakdownChartLabel(row("instagram", "instagram"), "canal", false)).toBe("Instagram")
    expect(breakdownChartLabel(row(null, "Sin canal"), "canal", false)).toBe("Sin canal")
    expect(breakdownChartLabel(row(null, "Sin categoría"), "category", false)).toBe("Sin categoría")
  })

  it("HOUR_BANDS: toda franja tiene rótulo corto, sin paréntesis, prefijo del completo", () => {
    for (const b of HOUR_BANDS) {
      expect(b.shortLabel).toBeTruthy()
      expect(b.shortLabel).not.toMatch(/[()]/)
      expect(b.label.startsWith(b.shortLabel)).toBe(true)
    }
  })
})
