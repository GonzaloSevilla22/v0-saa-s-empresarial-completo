/**
 * DashboardPage — 5ª tarjeta "Por cobrar" (cobranzas-panel, tasks 5.8/5.9).
 *
 * - La tarjeta se alimenta de useReceivablesSummary y enlaza a /cobranzas (D6/D7).
 * - La grilla diaria pasa a grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5.
 * - OQ-3: el filtro de sucursal NO altera el total por cobrar — la deuda es
 *   de la cuenta, no de la sucursal (useReceivablesSummary no recibe branch).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

let searchParams = new URLSearchParams("")
vi.mock("next/navigation", () => ({
  useSearchParams: () => searchParams,
  useRouter: () => ({ push: vi.fn() }),
}))

vi.mock("next/link", () => ({
  default: ({ href, children, className }: { href: string; children: React.ReactNode; className?: string }) => (
    <a href={href} className={className}>
      {children}
    </a>
  ),
}))

vi.mock("@/hooks/data/use-insights", () => ({
  useInsights: () => ({ insights: [], refreshInsights: vi.fn() }),
}))
vi.mock("@/hooks/data/use-critical-stock", () => ({
  useCriticalStock: () => ({ data: 0, isLoading: false }),
}))
vi.mock("@/hooks/use-greeting", () => ({
  useGreeting: () => ({ greeting: "Hola" }),
}))
vi.mock("@/hooks/three/useGoalMilestone", () => ({
  useGoalMilestone: () => null,
}))
vi.mock("@/components/three/Celebration3D", () => ({
  Celebration3D: () => null,
}))
vi.mock("@/components/dashboard/sales-chart", () => ({
  SalesChart: () => <div data-testid="sales-chart-stub" />,
}))
vi.mock("@/components/dashboard/ai-summary-card", () => ({
  AiSummaryCard: () => null,
}))
vi.mock("@/components/dashboard/recent-activity", () => ({
  RecentActivity: () => null,
}))
vi.mock("@/components/dashboard/ai-alerts", () => ({
  AiAlerts: () => null,
}))
vi.mock("@/lib/services/aiInsightService", () => ({
  aiInsightService: { generateInsights: vi.fn().mockResolvedValue(undefined) },
}))
// tablero-kpis-mes-vigente: las tarjetas financieras se alimentan de
// useDashboardFinancials (React Query + useAuth); acá no son el objeto bajo prueba.
vi.mock("@/hooks/data/use-dashboard-financials", () => ({
  useDashboardFinancials: () => ({
    data: { totalIncome: 0, totalExpenses: 0, totalPurchases: 0, netProfit: 0 },
    isLoading: false,
    isError: false,
  }),
}))
vi.mock("@/components/dashboard/TrialBanner", () => ({
  TrialBanner: () => null,
}))
vi.mock("@/components/branches/BranchFilter", () => ({
  BranchFilter: () => <div data-testid="branch-filter-stub" />,
}))
vi.mock("@/components/dashboard/KpiSummaryBlock", () => ({
  KpiSummaryBlock: () => <div data-testid="kpi-summary-block-stub" />,
}))
vi.mock("@/components/dashboard/PeriodFilter", () => ({
  PeriodFilter: () => null,
}))

const useReceivablesSummaryMock = vi.fn()
vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivablesSummary: () => useReceivablesSummaryMock(),
}))

import DashboardPage from "@/app/(dashboard)/dashboard/page"

describe("DashboardPage — KPI Por cobrar", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  beforeEach(() => {
    searchParams = new URLSearchParams("")
    useReceivablesSummaryMock.mockReset()
    useReceivablesSummaryMock.mockReturnValue({
      data: { totalReceivable: 567000, debtorCount: 11 },
      isLoading: false,
      isError: false,
    })
  })

  it("renderiza la 5ª tarjeta 'Por cobrar' alimentada por el resumen", () => {
    render(<DashboardPage />)
    expect(screen.getByText("Por cobrar")).toBeInTheDocument()
    expect(screen.getAllByText(/567\.000/).length).toBeGreaterThan(0)
  })

  // tablero-menu-pulido (P2): "Por cobrar" usa el formateador compartido del
  // Bloque Resumen (formatKpiCurrency) — no depende del idioma del navegador.
  it("el total se formatea es-AR con el formateador compartido, sin pasar por toLocaleString", () => {
    vi.spyOn(Number.prototype, "toLocaleString").mockImplementation(() => "CENTINELA")
    render(<DashboardPage />)

    const link = screen.getAllByRole("link").find((l) => l.getAttribute("href") === "/cobranzas")
    expect(link).toHaveTextContent("$567.000")
    expect(link?.textContent).not.toContain("CENTINELA")
  })

  // Decisión asentada en la ronda 1 de revisión (spec receivables-panel): el
  // indicador resume al peso, como el resto de la fila; /cobranzas conserva los
  // centavos. Con centavos (balanza, #599) puede diferir del panel en < $1.
  it("redondea al peso como el resto de la fila: 1234,50 se lee $1.235", () => {
    useReceivablesSummaryMock.mockReturnValue({
      data: { totalReceivable: 1234.5, debtorCount: 1 },
      isLoading: false,
      isError: false,
    })
    render(<DashboardPage />)

    const link = screen.getAllByRole("link").find((l) => l.getAttribute("href") === "/cobranzas")
    expect(link).toHaveTextContent("$1.235")
    expect(link?.textContent).not.toMatch(/1\.234,5/)
  })

  it("la tarjeta enlaza a /cobranzas (D7)", () => {
    render(<DashboardPage />)
    const links = screen.getAllByRole("link")
    const kpiLink = links.find((l) => l.getAttribute("href") === "/cobranzas")
    expect(kpiLink).toBeDefined()
    expect(kpiLink).toHaveTextContent("Por cobrar")
  })

  it("la grilla diaria pasa a 5 columnas en xl (D6)", () => {
    const { container } = render(<DashboardPage />)
    const grid = container.querySelector(".xl\\:grid-cols-5")
    expect(grid).not.toBeNull()
    expect(grid?.className).toContain("lg:grid-cols-3")
    expect(grid?.className).toContain("sm:grid-cols-2")
  })

  it("OQ-3: el filtro de sucursal no altera el total por cobrar", () => {
    searchParams = new URLSearchParams("branch=branch-99")
    render(<DashboardPage />)
    // El hook del resumen no recibe ningún argumento de sucursal…
    expect(useReceivablesSummaryMock).toHaveBeenCalled()
    for (const call of useReceivablesSummaryMock.mock.calls) {
      expect(call).toHaveLength(0)
    }
    // …y el total mostrado es el de la cuenta, intacto bajo el filtro.
    expect(screen.getAllByText(/567\.000/).length).toBeGreaterThan(0)
  })
})
