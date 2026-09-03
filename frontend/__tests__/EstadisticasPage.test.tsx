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
vi.mock("@/hooks/data/use-sales-statistics", () => ({
  useSalesEvolution: (params: unknown) => useSalesEvolutionMock(params),
  useProductRanking: (params: unknown) => useProductRankingMock(params),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: 365 }, isLoading: false }),
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

describe("EstadisticasPage", () => {
  beforeEach(() => {
    useSalesEvolutionMock.mockReset()
    useProductRankingMock.mockReset()
    useSalesEvolutionMock.mockReturnValue(evolutionReturn())
    useProductRankingMock.mockReturnValue(ranking())
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
})
