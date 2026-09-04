/**
 * ProductoEstadisticasPage — /estadisticas/productos/[id] (estadisticas-ventas
 * E3, tasks 9.4-9.6, D12). Molde de EstadisticasPage.test.tsx: hooks de datos
 * mockeados, se asserta la superficie.
 *
 * Invariantes bajo test:
 * - Cabecera con nombre, SKU, categoría, badge de variantes y enlace al
 *   catálogo (/productos?q=…) — nunca a /productos/[id].
 * - Camino de vuelta al módulo conservando el filtro de sucursal.
 * - Grupo: tabla de miembros con participación; standalone: sin esa tabla.
 * - Variante pedida directamente: su padre como contexto, enlazado a SU
 *   detalle.
 * - Sin ventas en el período: estado vacío explicativo, distinto del error.
 * - Error (404 ajeno / inexistente incluido): alerta visible + vuelta al módulo.
 * - Granularidad conmutable: re-consulta con bucket=week.
 * - Aviso de recorte de historial (D8) y margen "—" sin costo (D11).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

const useProductSalesEvolutionMock = vi.fn()
vi.mock("@/hooks/data/use-sales-statistics", () => ({
  useProductSalesEvolution: (params: unknown) => useProductSalesEvolutionMock(params),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: 365 }, isLoading: false }),
}))
const nav = vi.hoisted(() => ({ params: new URLSearchParams(), id: "p-parent" }))
vi.mock("next/navigation", () => ({
  useSearchParams: () => nav.params,
  useParams: () => ({ id: nav.id }),
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}))
vi.mock("@/components/branches/BranchFilter", () => ({
  BranchFilter: () => <div data-testid="branch-filter" />,
}))
vi.mock("@/components/charts/ReportTimeSeriesChart", () => ({
  ReportTimeSeriesChart: ({ ariaLabel }: { ariaLabel: string }) => <div data-testid="timeseries-stub">{ariaLabel}</div>,
}))
vi.mock("@/components/charts/ReportBarChart", () => ({
  ReportBarChart: ({ ariaLabel, data }: { ariaLabel: string; data: { name: string }[] }) => (
    <div data-testid="bar-stub">{ariaLabel}:{data.map((d) => d.name).join(",")}</div>
  ),
}))

import ProductoEstadisticasPage from "@/app/(dashboard)/estadisticas/productos/[id]/page"

const WINDOW = { start: "2026-08-05", end: "2026-09-03", historyDays: 365, clamped: false }

function metrics(over: Partial<Record<string, number | string | null>> = {}) {
  return {
    units: 5, revenue: 4300, operations: 4, totalCost: 750, grossMargin: 3550, grossMarginPct: 82.56,
    costCoveragePct: 25, lastSaleDate: "2026-08-31", ...over,
  }
}

function detail(overrides: Record<string, unknown> = {}) {
  return {
    product: { productId: "p-parent", productName: "Remera", sku: "REM-001", category: "Ropa", parentId: null, parentName: null, isGroup: true, variantCount: 2 },
    bucket: "day",
    window: WINDOW,
    totals: metrics(),
    points: [
      { bucketStart: "2026-08-30", bucketEnd: "2026-08-30", ...metrics({ units: 1, revenue: 500, operations: 1, grossMargin: 450, costCoveragePct: 0 }) },
      { bucketStart: "2026-08-31", bucketEnd: "2026-08-31", ...metrics({ units: 3, revenue: 3000, operations: 2, grossMargin: 2400, costCoveragePct: 50 }) },
    ],
    members: [
      { rank: 1, productId: "p-v1", productName: "Remera M", sku: "REM-001-M", ...metrics({ units: 3, revenue: 3000, operations: 2, grossMargin: 2400, costCoveragePct: 50 }) },
      { rank: 2, productId: "p-parent", productName: "Remera", sku: "REM-001", ...metrics({ units: 1, revenue: 800, operations: 1, grossMargin: 700, costCoveragePct: 0 }) },
      { rank: 3, productId: "p-v2", productName: "Remera L", sku: "REM-001-L", ...metrics({ units: 1, revenue: 500, operations: 1, grossMargin: 450, costCoveragePct: 0 }) },
    ],
    ...overrides,
  }
}

function ret(overrides: Record<string, unknown> = {}) {
  return { data: detail(), isLoading: false, isError: false, error: null, ...overrides }
}

describe("ProductoEstadisticasPage", () => {
  beforeEach(() => {
    useProductSalesEvolutionMock.mockReset()
    useProductSalesEvolutionMock.mockReturnValue(ret())
    nav.params = new URLSearchParams()
    nav.id = "p-parent"
  })

  it("consulta el detalle del producto de la URL con el período, la granularidad y la sucursal", () => {
    nav.params = new URLSearchParams("branch=b-9")
    render(<ProductoEstadisticasPage />)
    expect(useProductSalesEvolutionMock).toHaveBeenLastCalledWith(
      expect.objectContaining({ productId: "p-parent", bucket: "day", branchId: "b-9" }),
    )
    const params = useProductSalesEvolutionMock.mock.calls.at(-1)?.[0] as { start: string; end: string }
    expect(params.start).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(params.end).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })

  it("cabecera: nombre, SKU, categoría, badge de variantes y enlace al catálogo (nunca /productos/[id])", () => {
    render(<ProductoEstadisticasPage />)
    expect(screen.getByRole("heading", { level: 1, name: "Remera" })).toBeInTheDocument()
    expect(screen.getByText("REM-001")).toBeInTheDocument()
    expect(screen.getByText("Ropa")).toBeInTheDocument()
    expect(screen.getByText("2 variantes")).toBeInTheDocument()
    const catalog = screen.getByRole("link", { name: /ver en el catálogo/i })
    expect(catalog).toHaveAttribute("href", "/productos?q=REM-001")
    expect(catalog.getAttribute("href")).not.toMatch(/^\/productos\/p-parent/)
  })

  it("vuelve al módulo conservando el filtro de sucursal", () => {
    nav.params = new URLSearchParams("branch=b-9")
    render(<ProductoEstadisticasPage />)
    expect(screen.getByRole("link", { name: /volver a estadísticas/i })).toHaveAttribute("href", "/estadisticas?branch=b-9")
  })

  it("KPIs del período y tabla de evolución con un punto por intervalo y totales", () => {
    render(<ProductoEstadisticasPage />)
    expect(screen.getByText("Facturado")).toBeInTheDocument()
    // D11: la cobertura parcial del margen se declara junto al valor.
    expect(screen.getByText("Margen bruto").closest("div")).toHaveTextContent("25% con costo")
    const table = screen.getByRole("table", { name: /evolución/i })
    expect(within(table).getAllByRole("row")).toHaveLength(1 + 2 + 1)
    expect(within(table).getByText("30/08")).toBeInTheDocument()
    expect(within(table).getByText("Totales del período")).toBeInTheDocument()
  })

  it("grupo: tabla de miembros con participación, el padre vendido directo señalado y cada variante enlazada a su detalle", () => {
    render(<ProductoEstadisticasPage />)
    const table = screen.getByRole("table", { name: /variante/i })
    const rows = within(table).getAllByRole("row")
    expect(rows).toHaveLength(1 + 3)
    expect(within(table).getByRole("link", { name: /Remera M/ })).toHaveAttribute("href", "/estadisticas/productos/p-v1")
    // Participación de Remera M: 3000 / 4300 = 69,8 %
    expect(within(table).getByText(/69,8\s?%/)).toBeInTheDocument()
    expect(within(table).getByText(/producto base/i)).toBeInTheDocument()
  })

  it("standalone (sin variantes): no hay tabla de miembros ni badge", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({
      data: detail({
        product: { productId: "p-solo", productName: "Gorra", sku: null, category: null, parentId: null, parentName: null, isGroup: false, variantCount: 0 },
        members: [{ rank: 1, productId: "p-solo", productName: "Gorra", sku: null, ...metrics() }],
      }),
    }))
    render(<ProductoEstadisticasPage />)
    expect(screen.queryByRole("table", { name: /variante/i })).not.toBeInTheDocument()
    expect(screen.queryByText(/variantes/)).not.toBeInTheDocument()
    // Sin SKU el enlace al catálogo busca por nombre.
    expect(screen.getByRole("link", { name: /ver en el catálogo/i })).toHaveAttribute("href", "/productos?q=Gorra")
  })

  it("variante pedida directamente: su padre como contexto, enlazado al detalle del padre", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({
      data: detail({
        product: { productId: "p-v1", productName: "Remera M", sku: "REM-001-M", category: "Ropa", parentId: "p-parent", parentName: "Remera", isGroup: false, variantCount: 0 },
        members: [],
      }),
    }))
    render(<ProductoEstadisticasPage />)
    expect(screen.getByText(/variante de/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Remera" })).toHaveAttribute("href", "/estadisticas/productos/p-parent")
  })

  it("sin ventas en el período: estado vacío explicativo, distinto del error", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({
      data: detail({
        totals: metrics({ units: 0, revenue: 0, operations: 0, totalCost: null, grossMargin: null, grossMarginPct: null, costCoveragePct: null, lastSaleDate: null }),
        points: [{ bucketStart: "2026-08-30", bucketEnd: "2026-08-30", ...metrics({ units: 0, revenue: 0, operations: 0, grossMargin: null, costCoveragePct: null }) }],
        members: [],
      }),
    }))
    render(<ProductoEstadisticasPage />)
    expect(screen.getByText(/sin ventas de este producto en el período/i)).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    // La cabecera sigue: el producto existe aunque no haya vendido.
    expect(screen.getByRole("heading", { level: 1, name: "Remera" })).toBeInTheDocument()
  })

  it("fallo de carga (incluido el 404 de un producto ajeno): alerta visible y vuelta al módulo", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({ data: undefined, isError: true, error: new Error("Product not found") }))
    render(<ProductoEstadisticasPage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no pudimos cargar el detalle/i)
    expect(screen.getByRole("link", { name: /volver a estadísticas/i })).toBeInTheDocument()
    expect(screen.queryByText(/sin ventas de este producto/i)).not.toBeInTheDocument()
  })

  it("cambiar la granularidad re-consulta con bucket=week", () => {
    render(<ProductoEstadisticasPage />)
    fireEvent.click(screen.getByRole("radio", { name: "Semana" }))
    expect(useProductSalesEvolutionMock).toHaveBeenLastCalledWith(expect.objectContaining({ bucket: "week" }))
  })

  it("muestra el aviso de recorte de historial cuando la ventana aplicada difiere (D8)", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({ data: detail({ window: { ...WINDOW, clamped: true, historyDays: 30 } }) }))
    render(<ProductoEstadisticasPage />)
    expect(screen.getByRole("status", { name: /aviso de historial/i })).toHaveTextContent(/30 días/)
  })

  it("margen sin costo se muestra como '—' (nunca 0) y la cobertura parcial se declara (D11)", () => {
    useProductSalesEvolutionMock.mockReturnValue(ret({
      data: detail({ totals: metrics({ totalCost: null, grossMargin: null, grossMarginPct: null, costCoveragePct: null }) }),
    }))
    render(<ProductoEstadisticasPage />)
    const margin = screen.getByText("Margen bruto").closest("div")
    expect(margin).toHaveTextContent("—")
    expect(margin).not.toHaveTextContent(/\$\s?0/)
  })

  it("declara que el detalle no descuenta notas de crédito", () => {
    render(<ProductoEstadisticasPage />)
    expect(screen.getByText(/no descuenta notas de crédito/i)).toBeInTheDocument()
  })
})
