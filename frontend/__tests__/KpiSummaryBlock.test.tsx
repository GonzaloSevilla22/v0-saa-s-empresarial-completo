/**
 * Tests del Bloque Resumen KPI (dashboard-kpi-summary-block, Fase A)
 * Specs: 5 tarjetas, valores reales formateados, badge por polaridad,
 * responsive (grilla 2/3/5, 5ta tarjeta full-width en mobile), "—" sin datos.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { KpiSummaryBlock } from "@/components/dashboard/KpiSummaryBlock"
import type { DashboardKpiSummary } from "@/hooks/data/use-dashboard-kpi-summary"

// ── Mocks de los hooks de datos ───────────────────────────────────────────────

const useDashboardKpiSummaryMock = vi.fn()
const useChannelMarginMock = vi.fn()

vi.mock("@/hooks/data/use-dashboard-kpi-summary", () => ({
  useDashboardKpiSummary: (...args: unknown[]) => useDashboardKpiSummaryMock(...args),
}))

vi.mock("@/hooks/data/use-channel-margin", () => ({
  useChannelMargin: (...args: unknown[]) => useChannelMarginMock(...args),
}))

const fullData: DashboardKpiSummary = {
  netProfit: 184200,
  prevNetProfit: 164464,     // +12% → verde (up_good)
  avgTicket: 6820,
  prevAvgTicket: 6500,       // +4.9% → amarillo (sin variación significativa)
  costPerSale: 1240,
  prevCostPerSale: 1148,     // +8% → rojo (up_bad: subir es malo)
  stagnantStockValue: 41600,
  stagnantStockCount: 23,
  prevStagnantStockCount: 20, // +15% → rojo (up_bad)
  prevStagnantStockValue: 39000,
  salesCount: 27,
  prevSalesCount: 31,
}

const channelData = {
  channels: [
    { canal: "instagram", revenue: 50000, margin_pct: 34 },
    { canal: "mercadolibre", revenue: 80000, margin_pct: 18 },
  ],
  leader: "instagram",
  marginPct: 24.5,
  prevMarginPct: 21, // +16.7% → verde (up_good)
}

beforeEach(() => {
  useDashboardKpiSummaryMock.mockReset()
  useChannelMarginMock.mockReset()
  // Default: sin datos de canal (tarjeta en "—", tone amarillo)
  useChannelMarginMock.mockReturnValue({ data: null, isLoading: false })
})

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("KpiSummaryBlock", () => {
  it("renderiza las 5 tarjetas KPI del spec", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    expect(screen.getByText("Ganancia Neta")).toBeInTheDocument()
    expect(screen.getByText("Margen por Canal")).toBeInTheDocument()
    expect(screen.getByText("Stock sin Rotación")).toBeInTheDocument()
    expect(screen.getByText("Costo por Venta")).toBeInTheDocument()
    expect(screen.getByText("Ticket Promedio")).toBeInTheDocument()
  })

  it("muestra los valores reales formateados", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    expect(screen.getByText("$184.200")).toBeInTheDocument()
    expect(screen.getByText("$6.820")).toBeInTheDocument()
    expect(screen.getByText("$1.240")).toBeInTheDocument()
    expect(screen.getByText("$41.600")).toBeInTheDocument()
    expect(screen.getByText("23 productos")).toBeInTheDocument()
  })

  it("colorea el badge según polaridad: ganancia sube=verde, costo sube=rojo, ticket ~igual=amarillo", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    const badges = screen.getAllByTestId("kpi-badge")
    const tones = badges.map(b => b.getAttribute("data-tone"))
    // Orden de tarjetas: Ganancia, Margen Canal, Stock, Costo, Ticket
    expect(tones[0]).toBe("green")   // Ganancia +12% (up_good)
    expect(tones[1]).toBe("yellow")  // Margen por Canal — sin datos de canal
    expect(tones[2]).toBe("red")     // Stock sin Rotación +15% (up_bad)
    expect(tones[3]).toBe("red")     // Costo por Venta +8% (up_bad)
    expect(tones[4]).toBe("yellow")  // Ticket +4.9% < umbral 5%
  })

  it("Margen por Canal muestra — cuando no hay datos de canal", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    const margenCard = screen.getByText("Margen por Canal").closest("[class*='rounded']")
    expect(margenCard?.textContent).toContain("—")
  })

  it("Margen por Canal muestra los 2 mejores canales y el líder (Fase B)", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    useChannelMarginMock.mockReturnValue({ data: channelData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    expect(screen.getByText("IG 34% / ML 18%")).toBeInTheDocument()
    expect(screen.getByText("IG lidera")).toBeInTheDocument()

    // Tone: margen total 24.5% vs 21% del mes anterior → +16.7% → verde (up_good)
    const badges = screen.getAllByTestId("kpi-badge")
    expect(badges[1].getAttribute("data-tone")).toBe("green")
  })

  it("pasa periodDate y branchId también al hook de canal", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    const date = new Date(2026, 4, 1)
    render(<KpiSummaryBlock periodDate={date} branchId="branch-7" />)

    expect(useChannelMarginMock).toHaveBeenCalledWith(date, "branch-7")
  })

  it("muestra — en todas las tarjetas cuando no hay datos del período", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: null, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    // 5 valores "—" + badges "—" (ninguna cifra)
    expect(screen.queryByText(/\$\d/)).toBeNull()
    expect(screen.getAllByText("—").length).toBeGreaterThanOrEqual(5)
  })

  it("trata $0 con 0 ventas como sin datos (Ganancia muestra —)", () => {
    useDashboardKpiSummaryMock.mockReturnValue({
      data: { ...fullData, netProfit: 0, salesCount: 0, avgTicket: null, costPerSale: null },
      isLoading: false,
    })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    expect(screen.queryByText("$0")).toBeNull()
  })

  it("la grilla es 2 col mobile / 3 tablet / 5 web y la 5ta tarjeta es full-width en mobile", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    render(<KpiSummaryBlock periodDate={new Date(2026, 5, 15)} />)

    const grid = screen.getByTestId("kpi-summary-block")
    expect(grid.className).toContain("grid-cols-2")
    expect(grid.className).toContain("md:grid-cols-3")
    expect(grid.className).toContain("xl:grid-cols-5")

    const ticketCard = screen.getByText("Ticket Promedio").closest("[class*='col-span-2']")
    expect(ticketCard).not.toBeNull()
  })

  it("pasa periodDate y branchId al hook de datos", () => {
    useDashboardKpiSummaryMock.mockReturnValue({ data: fullData, isLoading: false })
    const date = new Date(2026, 4, 1)
    render(<KpiSummaryBlock periodDate={date} branchId="branch-7" />)

    expect(useDashboardKpiSummaryMock).toHaveBeenCalledWith(date, "branch-7")
  })
})
