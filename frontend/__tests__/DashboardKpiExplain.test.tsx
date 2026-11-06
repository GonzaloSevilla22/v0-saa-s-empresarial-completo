/**
 * DashboardPage — tarjetas del mes explicables (tablero-explicable, task 2.5).
 *
 * Las 4 tarjetas del mes (Ventas, Gastos, Ganancia neta, Productos en alerta)
 * abren «de dónde sale» con el mes y la sucursal vigentes; «Por cobrar»
 * conserva su enlace a /cobranzas y NO abre ningún diálogo.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
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
  SalesChart: ({ branchId }: { branchId?: string | null }) => (
    <div data-testid="sales-chart-stub" data-branch={branchId ?? ""} />
  ),
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
  KpiSummaryBlock: ({ branchName }: { branchName?: string | null }) => (
    <div data-testid="kpi-summary-block-stub" data-branch-name={branchName ?? ""} />
  ),
}))
vi.mock("@/hooks/data/use-active-branch-name", () => ({
  useActiveBranchName: (id: string | null) => (id ? "Centro" : null),
}))
vi.mock("@/components/dashboard/PeriodFilter", () => ({
  PeriodFilter: () => null,
}))

const useReceivablesSummaryMock = vi.fn()
vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivablesSummary: () => useReceivablesSummaryMock(),
}))

import DashboardPage from "@/app/(dashboard)/dashboard/page"

describe("DashboardPage — tarjetas del mes explicables", () => {
  beforeEach(() => {
    searchParams = new URLSearchParams("period=2026-10&branch=branch-1")
    useReceivablesSummaryMock.mockReset()
    useReceivablesSummaryMock.mockReturnValue({
      data: { totalReceivable: 567000, debtorCount: 11 },
      isLoading: false,
      isError: false,
    })
  })

  it("las 4 tarjetas del mes son botones que abren su diálogo", () => {
    render(<DashboardPage />)
    for (const t of ["Ventas del mes", "Gastos del mes", "Ganancia neta del mes", "Productos en alerta"]) {
      expect(screen.getByRole("button", { name: new RegExp(`^${t}: .*Ver de dónde sale$`) })).toBeInTheDocument()
    }
  })

  it("«Ganancia neta del mes» abre con el mes del selector y la sucursal activa", async () => {
    const user = userEvent.setup()
    render(<DashboardPage />)

    await user.click(screen.getByRole("button", { name: /^Ganancia neta del mes/ }))

    const dialog = await screen.findByRole("dialog", { name: "Ganancia neta del mes" })
    expect(within(dialog).getByText("Mes: octubre de 2026 (hora de Argentina)")).toBeInTheDocument()
    expect(within(dialog).getByText("Sucursal: Centro")).toBeInTheDocument()
    expect(within(dialog).getByText(/Ventas del mes − Gastos del mes − Compras del mes/)).toBeInTheDocument()
  })

  it("«Productos en alerta» dice que es de ahora aunque haya un mes elegido", async () => {
    const user = userEvent.setup()
    render(<DashboardPage />)

    await user.click(screen.getByRole("button", { name: /^Productos en alerta/ }))

    const dialog = await screen.findByRole("dialog", { name: "Productos en alerta" })
    expect(within(dialog).getByText(/Es una foto de ahora/)).toBeInTheDocument()
  })

  it("«Por cobrar» sigue siendo un enlace a /cobranzas y no abre diálogo", async () => {
    const user = userEvent.setup()
    render(<DashboardPage />)

    expect(screen.queryByRole("button", { name: /Por cobrar/ })).not.toBeInTheDocument()
    const link = screen.getAllByRole("link").find((l) => l.getAttribute("href") === "/cobranzas")
    expect(link).toBeDefined()
    await user.click(link!)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("el bloque superior recibe el nombre de la sucursal activa", () => {
    render(<DashboardPage />)
    expect(screen.getByTestId("kpi-summary-block-stub")).toHaveAttribute("data-branch-name", "Centro")
  })

  it("sin sucursal elegida el bloque superior recibe null (todas)", () => {
    searchParams = new URLSearchParams("")
    render(<DashboardPage />)
    expect(screen.getByTestId("kpi-summary-block-stub")).toHaveAttribute("data-branch-name", "")
  })
})
