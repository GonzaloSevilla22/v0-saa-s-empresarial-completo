/**
 * EstadisticasPage — /estadisticas (estadisticas-ventas E1, tasks 4.4-4.11).
 * Molde de CobranzasPage.test.tsx: hooks de datos mockeados, se asserta la
 * superficie.
 *
 * Invariantes bajo test:
 * - KPIs del período con variación contra el período anterior (no "vs ayer").
 * - Orden por unidades ≠ orden por importe: cambiar el orden re-consulta con
 *   el criterio nuevo (el orden lo resuelve el servidor, nunca la página).
 * - Agrupación de variantes conmutable: re-consulta con group_variants=false.
 * - Margen ausente se muestra como "—" (NUNCA 0) y la cobertura parcial se
 *   declara junto al margen (D11).
 * - Aviso de recorte de historial cuando la ventana aplicada difiere (D8).
 * - Pie declarando el importe de servicios fuera del ranking y que el ranking
 *   no descuenta NC (D6/D7).
 * - Estado vacío y estado de error visibles y distinguibles.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

const useSalesEvolutionMock = vi.fn()
const useProductRankingMock = vi.fn()
const useSalesBreakdownMock = vi.fn()
const useTopClientsMock = vi.fn()
vi.mock("@/hooks/data/use-sales-statistics", () => ({
  useSalesEvolution: (params: unknown) => useSalesEvolutionMock(params),
  useProductRanking: (params: unknown) => useProductRankingMock(params),
  useSalesBreakdown: (params: unknown) => useSalesBreakdownMock(params),
  useTopClients: (params: unknown) => useTopClientsMock(params),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: 365 }, isLoading: false }),
}))

// E2: el filtro de sucursal es el BranchFilter compartido (URL ?branch=),
// como en el Tablero; acá se stubbea y se controla el search param.
const nav = vi.hoisted(() => ({ params: new URLSearchParams() }))
vi.mock("next/navigation", () => ({
  useSearchParams: () => nav.params,
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}))
vi.mock("@/components/branches/BranchFilter", () => ({
  BranchFilter: () => <div data-testid="branch-filter" />,
}))

// E3: el botón de export y el panel de IA tienen sus propios tests; acá se
// stubbean capturando las props para fijar QUÉ parámetros les llegan desde
// la pantalla (los mismos que el ranking muestra).
const exportButtonMock = vi.fn()
vi.mock("@/components/export/ExportButton", () => ({
  ExportButton: (props: { exportType: string; params?: Record<string, unknown> }) => {
    exportButtonMock(props)
    return <button type="button" data-testid="export-button">{props.exportType}</button>
  },
}))
const aiPanelMock = vi.fn()
vi.mock("@/components/statistics/StatisticsAiPanel", () => ({
  StatisticsAiPanel: (props: Record<string, unknown>) => {
    aiPanelMock(props)
    return <div data-testid="ai-panel" />
  },
}))

// Los gráficos tienen sus propios tests (report-charts.test.tsx); acá se
// stubbean para que Recharts no interfiera con la superficie bajo test.
vi.mock("@/components/charts/ReportTimeSeriesChart", () => ({
  ReportTimeSeriesChart: ({ ariaLabel }: { ariaLabel: string }) => <div data-testid="timeseries-stub">{ariaLabel}</div>,
}))
vi.mock("@/components/charts/ReportBarChart", () => ({
  ReportBarChart: ({ ariaLabel, data }: { ariaLabel: string; data: { name: string }[] }) => (
    <div data-testid="bar-stub">{ariaLabel}:{data.map((d) => d.name).join(",")}</div>
  ),
}))

import EstadisticasPage from "@/app/(dashboard)/estadisticas/page"

const WINDOW = { start: "2026-08-05", end: "2026-09-03", historyDays: 365, clamped: false }

function evolution(overrides: Record<string, unknown> = {}) {
  return {
    bucket: "day",
    window: WINDOW,
    points: [
      { bucketStart: "2026-08-29", bucketEnd: "2026-08-29", revenue: 2900, creditNotes: 150, netRevenue: 2750, units: 4, operations: 2, serviceRevenue: 400 },
      { bucketStart: "2026-08-30", bucketEnd: "2026-08-30", revenue: 2100, creditNotes: 0, netRevenue: 2100, units: 3, operations: 1, serviceRevenue: 0 },
    ],
    current: { start: "2026-08-05", end: "2026-09-03", revenue: 6050, creditNotes: 150, netRevenue: 5900, units: 11, operations: 6, serviceRevenue: 400 },
    previous: { start: "2026-07-06", end: "2026-08-04", revenue: 333, creditNotes: 0, netRevenue: 333, units: 1, operations: 1, serviceRevenue: 0 },
    ...overrides,
  }
}

const ROWS = [
  { rank: 1, productId: "p-simple", productName: "Gorra", sku: null, category: "Accesorios", parentId: null, parentName: null, isGroup: false, variantCount: 0, units: 5, revenue: 2350, operations: 3, totalCost: 1500, grossMargin: 850, grossMarginPct: 36.17, costCoveragePct: 33.3, lastSaleDate: "2026-08-31" },
  { rank: 2, productId: "p-parent", productName: "Remera", sku: null, category: "Ropa", parentId: null, parentName: null, isGroup: true, variantCount: 2, units: 4, revenue: 2600, operations: 2, totalCost: 350, grossMargin: 2250, grossMarginPct: 86.54, costCoveragePct: 0, lastSaleDate: "2026-08-30" },
  { rank: 3, productId: "p-orphan", productName: "Bufanda", sku: null, category: null, parentId: null, parentName: null, isGroup: false, variantCount: 0, units: 1, revenue: 700, operations: 1, totalCost: null, grossMargin: null, grossMarginPct: null, costCoveragePct: 0, lastSaleDate: "2026-09-03" },
]

function ranking(overrides: Record<string, unknown> = {}) {
  return {
    data: { items: ROWS, total: 3, page: 0, pages: 1, window: WINDOW },
    isLoading: false,
    isError: false,
    ...overrides,
  }
}

function evolutionReturn(overrides: Record<string, unknown> = {}) {
  return { data: evolution(), isLoading: false, isError: false, ...overrides }
}

// ── E2 fixtures: desgloses por dimensión y top clientes ─────────────────────

function bdRow(key: string | null, label: string, sortOrder: number, revenue: number, units: number, operations: number) {
  return { key, label, sortOrder, revenue, units, operations }
}

const WEEKDAYS = ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"]
const WEEKDAY_VALUES: Record<string, [number, number, number]> = {
  Lunes: [2500, 3, 1], Viernes: [500, 2, 2], Sábado: [2100, 3, 1], Domingo: [500, 1, 1],
}

const BREAKDOWNS: Record<string, { dimension: string; window: typeof WINDOW | null; rows: ReturnType<typeof bdRow>[] }> = {
  canal: {
    dimension: "canal", window: WINDOW,
    rows: [bdRow("local", "local", 1, 2900, 4, 2), bdRow("instagram", "instagram", 2, 2100, 3, 1), bdRow(null, "Sin canal", 3, 600, 2, 2)],
  },
  branch: {
    dimension: "branch", window: WINDOW,
    rows: [bdRow("b1", "Casa central", 1, 2900, 4, 2), bdRow("b2", "Showroom", 2, 2100, 3, 1), bdRow(null, "Sin sucursal", 3, 600, 2, 2)],
  },
  weekday: {
    dimension: "weekday", window: WINDOW,
    rows: WEEKDAYS.map((d, i) => bdRow(String(i + 1), d, i + 1, ...(WEEKDAY_VALUES[d] ?? [0, 0, 0]))),
  },
  hour: {
    dimension: "hour", window: WINDOW,
    rows: Array.from({ length: 24 }, (_, h) => {
      const v: [number, number, number] = h === 9 ? [500, 2, 2] : h === 14 ? [2600, 4, 2] : h === 23 ? [2500, 3, 1] : [0, 0, 0]
      return bdRow(String(h), `${String(h).padStart(2, "0")}:00`, h, ...v)
    }),
  },
  category: {
    dimension: "category", window: WINDOW,
    rows: [bdRow(null, "Sin categoría", 1, 2100, 3, 1), bdRow("c1", "Ropa", 2, 2000, 2, 1), bdRow("c2", "Accesorios", 3, 1000, 2, 2)],
  },
}

const TOP_CLIENTS = {
  window: WINDOW,
  items: [
    { rank: 1, clientId: "c-a", clientName: "Ana Pérez", revenue: 2900, units: 4, operations: 2, lastSaleDate: "2026-08-31" },
    { rank: 2, clientId: "c-b", clientName: "Beto Gómez", revenue: 2100, units: 3, operations: 1, lastSaleDate: "2026-08-30" },
  ],
  unassigned: { revenue: 500, units: 1, operations: 1, lastSaleDate: "2026-08-29" },
  totalClients: 2,
}

function breakdownImpl(overrides: Partial<Record<string, Record<string, unknown>>> = {}) {
  return ({ dimension }: { dimension: string }) => ({
    data: BREAKDOWNS[dimension],
    isLoading: false,
    isError: false,
    ...(overrides[dimension] ?? {}),
  })
}

function switchTab(name: RegExp) {
  const tab = screen.getByRole("tab", { name })
  fireEvent.mouseDown(tab)
  fireEvent.click(tab)
}

describe("EstadisticasPage", () => {
  beforeEach(() => {
    useSalesEvolutionMock.mockReset()
    useProductRankingMock.mockReset()
    useSalesBreakdownMock.mockReset()
    useTopClientsMock.mockReset()
    nav.params = new URLSearchParams()
    useSalesEvolutionMock.mockReturnValue(evolutionReturn())
    useProductRankingMock.mockReturnValue(ranking())
    useSalesBreakdownMock.mockImplementation(breakdownImpl())
    useTopClientsMock.mockReturnValue({ data: TOP_CLIENTS, isLoading: false, isError: false })
  })

  it("muestra los KPIs del período con la variación contra el período anterior", () => {
    render(<EstadisticasPage />)
    expect(screen.getByText("Facturación neta")).toBeInTheDocument()
    expect(screen.getAllByText(/5\.900/).length).toBeGreaterThan(0)
    // "Operaciones" es título de tarjeta Y cabecera de la tabla de evolución.
    expect(screen.getAllByText("Operaciones").length).toBeGreaterThan(0)
    expect(screen.getByText("Unidades", { selector: "span" })).toBeInTheDocument()
    // (5900 − 333) / 333 ≈ +1672 % — y el rótulo NO es "vs ayer".
    expect(screen.getAllByText(/vs período anterior/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/vs ayer/)).not.toBeInTheDocument()
  })

  it("la tabla de evolución acompaña al gráfico con un punto por intervalo y totales", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /evolución/i })
    expect(within(table).getByText("29/08")).toBeInTheDocument()
    expect(within(table).getByText("30/08")).toBeInTheDocument()
    expect(within(table).getByText("Totales del período")).toBeInTheDocument()
    expect(screen.getByTestId("timeseries-stub")).toBeInTheDocument()
  })

  it("cambiar el orden a importe re-consulta el ranking con order_by=revenue", () => {
    render(<EstadisticasPage />)
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ orderBy: "units" }))
    fireEvent.click(screen.getByRole("radio", { name: "Importe" }))
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ orderBy: "revenue", page: 0 }))
  })

  it("desactivar la agrupación re-consulta con group_variants=false", () => {
    render(<EstadisticasPage />)
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ groupVariants: true }))
    fireEvent.click(screen.getByRole("switch", { name: /agrupar variantes/i }))
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ groupVariants: false }))
  })

  it("la fila agrupada declara cuántas variantes agrupa", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /ranking/i })
    expect(within(table).getByText("2 variantes")).toBeInTheDocument()
  })

  it("margen ausente se muestra como '—' (nunca 0) y la cobertura parcial se declara", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /ranking/i })
    const orphanRow = within(table).getByText("Bufanda").closest("tr")!
    expect(within(orphanRow).getByText("—")).toBeInTheDocument()
    expect(within(orphanRow).queryByText(/\$\s?0,00/)).not.toBeInTheDocument()
    const simpleRow = within(table).getByText("Gorra").closest("tr")!
    expect(within(simpleRow).getByText("33% con costo")).toBeInTheDocument()
  })

  it("el pie declara el importe de servicios fuera del ranking y que el ranking no descuenta NC", () => {
    render(<EstadisticasPage />)
    expect(screen.getByText(/líneas de servicio/i)).toHaveTextContent(/400/)
    expect(screen.getByText(/no descuenta notas de crédito/i)).toBeInTheDocument()
  })

  it("muestra el aviso de recorte cuando la ventana aplicada difiere de la pedida (D8)", () => {
    useSalesEvolutionMock.mockReturnValue(evolutionReturn({
      data: evolution({ window: { start: "2026-08-05", end: "2026-09-03", historyDays: 30, clamped: true } }),
    }))
    render(<EstadisticasPage />)
    const alert = screen.getByRole("status", { name: /historial/i })
    expect(alert).toHaveTextContent(/30 días/)
    expect(alert).toHaveTextContent(/05\/08\/2026/)
  })

  it("sin recorte no muestra el aviso", () => {
    render(<EstadisticasPage />)
    expect(screen.queryByRole("status", { name: /historial/i })).not.toBeInTheDocument()
  })

  it("período sin ventas: estado vacío explicativo, distinto del error", () => {
    useSalesEvolutionMock.mockReturnValue(evolutionReturn({
      data: evolution({
        points: [],
        current: { start: "2026-08-05", end: "2026-09-03", revenue: 0, creditNotes: 0, netRevenue: 0, units: 0, operations: 0, serviceRevenue: 0 },
      }),
    }))
    useProductRankingMock.mockReturnValue(ranking({ data: { items: [], total: 0, page: 0, pages: 0, window: null } }))
    render(<EstadisticasPage />)
    expect(screen.getAllByText("Sin ventas en el período seleccionado").length).toBeGreaterThan(0)
    expect(screen.queryByText(/no pudimos cargar/i)).not.toBeInTheDocument()
  })

  it("fallo de carga: estado de error visible, nunca presentado como 'sin datos'", () => {
    useSalesEvolutionMock.mockReturnValue(evolutionReturn({ data: undefined, isError: true }))
    useProductRankingMock.mockReturnValue(ranking({ data: undefined, isError: true }))
    render(<EstadisticasPage />)
    expect(screen.getAllByRole("alert").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/no pudimos cargar/i).length).toBeGreaterThan(0)
    expect(screen.queryByText("Sin ventas en el período seleccionado")).not.toBeInTheDocument()
  })

  it("la paginación del ranking avanza de página sin reordenar en el cliente", () => {
    useProductRankingMock.mockReturnValue(ranking({ data: { items: ROWS, total: 60, page: 0, pages: 3, window: WINDOW } }))
    render(<EstadisticasPage />)
    expect(screen.getByText(/Página 1 de 3/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /siguiente/i }))
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ page: 1 }))
  })

  // ── E2 (tasks 7.1-7.5) ──────────────────────────────────────────────────

  it("desglose por canal: el tramo 'Sin canal' es visible con su importe y los canales llevan su etiqueta completa", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /desglose por canal/i })
    const none = within(table).getByText("Sin canal").closest("tr")!
    expect(within(none).getByText(/600/)).toBeInTheDocument()
    expect(within(table).getByText("Instagram")).toBeInTheDocument()
    expect(within(table).getByText("Local")).toBeInTheDocument()
    // El total del desglose es la suma de los tramos (5.600), no el neto.
    expect(within(table).getAllByText(/5\.600/).length).toBeGreaterThan(0)
  })

  it("cambiar a sucursal muestra el tramo 'Sin sucursal' con el nombre de cada sucursal", () => {
    render(<EstadisticasPage />)
    switchTab(/por sucursal/i)
    const table = screen.getByRole("table", { name: /desglose por sucursal/i })
    expect(within(table).getByText("Sin sucursal")).toBeInTheDocument()
    expect(within(table).getByText("Casa central")).toBeInTheDocument()
    expect(within(table).getByText("Showroom")).toBeInTheDocument()
    expect(useSalesBreakdownMock).toHaveBeenCalledWith(expect.objectContaining({ dimension: "branch" }))
  })

  it("día de la semana: los siete días, con los vacíos en cero", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /día de la semana/i })
    for (const d of WEEKDAYS) expect(within(table).getByText(d)).toBeInTheDocument()
    const wed = within(table).getByText("Miércoles").closest("tr")!
    // formatMoney(0) = "$ 0" (es-AR, sin decimales forzados): el día vacío
    // viaja y se muestra en cero, no se omite.
    expect(within(wed).getAllByText(/^\$\s?0$/).length).toBeGreaterThan(0)
    const mon = within(table).getByText("Lunes").closest("tr")!
    expect(within(mon).getByText(/2\.500/)).toBeInTheDocument()
  })

  it("horarios: rotulados como horario de carga con la salvedad visible, y la franja se arma en el cliente", () => {
    render(<EstadisticasPage />)
    switchTab(/horario de carga/i)
    const table = screen.getByRole("table", { name: /horario de carga/i })
    expect(within(table).getByText("23:00")).toBeInTheDocument()
    // OQ-1: la salvedad es visible y nada promete "horario de venta".
    expect(screen.getByText(/no es el horario de venta/i)).toBeInTheDocument()
    expect(screen.queryByRole("tab", { name: /horario de venta/i })).not.toBeInTheDocument()
    expect(useSalesBreakdownMock).toHaveBeenCalledWith(expect.objectContaining({ dimension: "hour" }))
    // Conmutación hora / franja resuelta en el cliente (D5): sin re-consulta.
    // React Query sólo vuelve a consultar cuando cambia la clave, así que la
    // prueba es que el conjunto de parámetros DISTINTOS pedidos al hook no
    // crece al cambiar de vista (un re-render repite los mismos params).
    const distinctParams = () => new Set(useSalesBreakdownMock.mock.calls.map(([p]) => JSON.stringify(p))).size
    const before = distinctParams()
    fireEvent.click(screen.getByRole("radio", { name: /por franja/i }))
    const banded = screen.getByRole("table", { name: /horario de carga/i })
    const night = within(banded).getByText("Noche (19–24)").closest("tr")!
    expect(within(night).getByText(/2\.500/)).toBeInTheDocument()
    const afternoon = within(banded).getByText("Tarde (12–19)").closest("tr")!
    expect(within(afternoon).getByText(/2\.600/)).toBeInTheDocument()
    expect(within(banded).queryByText("23:00")).not.toBeInTheDocument()
    expect(distinctParams()).toBe(before)
  })

  it("top clientes: ordenados por importe, sin fila 'sin cliente', y con el importe sin cliente declarado al pie", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /top clientes/i })
    const rows = within(table).getAllByRole("row").slice(1)
    expect(within(rows[0]).getByText("Ana Pérez")).toBeInTheDocument()
    expect(within(rows[1]).getByText("Beto Gómez")).toBeInTheDocument()
    expect(within(table).queryByText(/sin cliente/i)).not.toBeInTheDocument()
    const note = screen.getByText(/sin cliente asignado/i)
    expect(note).toHaveTextContent(/500/)
    expect(note).toHaveTextContent(/no compiten/i)
  })

  it("ventas por categoría: tramo 'Sin categoría' visible y las ventas sin producto declaradas fuera", () => {
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /ventas por categoría/i })
    expect(within(table).getByText("Sin categoría")).toBeInTheDocument()
    expect(within(table).getByText("Ropa")).toBeInTheDocument()
    expect(screen.getByText(/no tienen categoría/i)).toHaveTextContent(/400/)
  })

  it("el filtro de sucursal de la URL viaja a todas las consultas del módulo", () => {
    nav.params = new URLSearchParams("branch=b1")
    render(<EstadisticasPage />)
    expect(screen.getByTestId("branch-filter")).toBeInTheDocument()
    expect(useSalesEvolutionMock).toHaveBeenLastCalledWith(expect.objectContaining({ branchId: "b1" }))
    expect(useProductRankingMock).toHaveBeenLastCalledWith(expect.objectContaining({ branchId: "b1" }))
    expect(useSalesBreakdownMock).toHaveBeenCalledWith(expect.objectContaining({ dimension: "canal", branchId: "b1" }))
    expect(useTopClientsMock).toHaveBeenLastCalledWith(expect.objectContaining({ branchId: "b1" }))
  })

  it("sin filtro de sucursal las consultas viajan con branchId null", () => {
    render(<EstadisticasPage />)
    expect(useSalesEvolutionMock).toHaveBeenLastCalledWith(expect.objectContaining({ branchId: null }))
    expect(useTopClientsMock).toHaveBeenLastCalledWith(expect.objectContaining({ branchId: null }))
  })

  it("el fallo de un desglose se muestra como error en su tarjeta, nunca como 'sin datos'", () => {
    useSalesBreakdownMock.mockImplementation(breakdownImpl({ canal: { data: undefined, isError: true } }))
    render(<EstadisticasPage />)
    expect(screen.getByText(/no pudimos cargar el desglose/i)).toBeInTheDocument()
    expect(screen.queryByRole("table", { name: /desglose por canal/i })).not.toBeInTheDocument()
  })

  it("el pie declara que los desgloses y el top de clientes no descuentan notas de crédito", () => {
    render(<EstadisticasPage />)
    expect(screen.getByText(/tampoco descuentan notas de crédito/i)).toBeInTheDocument()
  })

  it("un desglose sin tramos muestra el vacío explícito, no una tabla en cero", () => {
    useSalesBreakdownMock.mockImplementation(breakdownImpl({ canal: { data: { dimension: "canal", window: null, rows: [] } } }))
    render(<EstadisticasPage />)
    expect(screen.getByText(/sin ventas en el período para este desglose/i)).toBeInTheDocument()
    expect(screen.queryByRole("table", { name: /desglose por canal/i })).not.toBeInTheDocument()
    // Las demás tarjetas no se contagian: el día de la semana sigue con su tabla.
    expect(screen.getByRole("table", { name: /día de la semana/i })).toBeInTheDocument()
  })

  it("los gráficos de día de la semana y de franja usan rótulos cortos (móvil sin solapes); las tablas conservan los completos", () => {
    render(<EstadisticasPage />)
    expect(screen.getByText("Gráfico: Ventas por día de la semana:Lun,Mar,Mié,Jue,Vie,Sáb,Dom")).toBeInTheDocument()
    const weekTable = screen.getByRole("table", { name: /día de la semana/i })
    expect(within(weekTable).getByText("Miércoles")).toBeInTheDocument()
    switchTab(/horario de carga/i)
    fireEvent.click(screen.getByRole("radio", { name: /por franja/i }))
    expect(screen.getByText("Gráfico: Ventas por horario de carga:Madrugada,Mañana,Tarde,Noche")).toBeInTheDocument()
    const hourTable = screen.getByRole("table", { name: /horario de carga/i })
    expect(within(hourTable).getByText("Madrugada (0–6)")).toBeInTheDocument()
  })

  it("top clientes sin clientes identificados: vacío explícito que igual declara el importe sin cliente (OQ-2)", () => {
    useTopClientsMock.mockReturnValue({ data: { ...TOP_CLIENTS, items: [], totalClients: 0 }, isLoading: false, isError: false })
    render(<EstadisticasPage />)
    expect(screen.getByText(/sin ventas a clientes identificados/i)).toBeInTheDocument()
    expect(screen.getByText(/sin cliente asignado/i)).toHaveTextContent(/500/)
    expect(screen.queryByRole("table", { name: /top clientes/i })).not.toBeInTheDocument()
  })

  // ── E3 ────────────────────────────────────────────────────────────────────

  it("el botón de export del ranking viaja con los MISMOS parámetros que la pantalla muestra (período, orden, agrupación, sucursal)", () => {
    nav.params = new URLSearchParams("branch=b-9")
    render(<EstadisticasPage />)
    const last = () => exportButtonMock.mock.calls.at(-1)?.[0] as { exportType: string; params: Record<string, unknown> }
    expect(last().exportType).toBe("product_ranking_csv")
    expect(last().params).toEqual(expect.objectContaining({ order_by: "units", group_variants: true, branch_id: "b-9" }))
    // Las fechas del body son las del selector de rango (las mismas que el hook recibe).
    const hookParams = useProductRankingMock.mock.calls.at(-1)?.[0] as { start: string; end: string }
    expect(last().params.start).toBe(hookParams.start)
    expect(last().params.end).toBe(hookParams.end)
    // Cambiar el orden y desagrupar cambia lo que se exporta, en el acto.
    fireEvent.click(screen.getByRole("radio", { name: "Importe" }))
    fireEvent.click(screen.getByRole("switch", { name: /agrupar variantes/i }))
    expect(last().params).toEqual(expect.objectContaining({ order_by: "revenue", group_variants: false }))
  })

  it("cada fila del ranking enlaza al detalle en /estadisticas/productos/[id] (D12) conservando el filtro de sucursal", () => {
    nav.params = new URLSearchParams("branch=b-9")
    render(<EstadisticasPage />)
    const table = screen.getByRole("table", { name: /ranking/i })
    const link = within(table).getByRole("link", { name: /Remera/ })
    expect(link).toHaveAttribute("href", "/estadisticas/productos/p-parent?branch=b-9")
    expect(within(table).getByRole("link", { name: /Gorra/ })).toHaveAttribute("href", "/estadisticas/productos/p-simple?branch=b-9")
  })

  it("el panel de análisis con IA se monta con la ventana de la pantalla", () => {
    render(<EstadisticasPage />)
    expect(screen.getByTestId("ai-panel")).toBeInTheDocument()
    const props = aiPanelMock.mock.calls.at(-1)?.[0] as { start: string; end: string; branchId: string | null }
    const hookParams = useSalesEvolutionMock.mock.calls.at(-1)?.[0] as { start: string; end: string }
    expect(props.start).toBe(hookParams.start)
    expect(props.end).toBe(hookParams.end)
    expect(props.branchId).toBeNull()
  })
})
