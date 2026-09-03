/**
 * TDD tests para la tarjeta "Productos en alerta" del Tablero
 * (kpi-critical-stock-dashboard, grupo 6 / D1-D5).
 *
 * La tarjeta deja de recalcular sobre `products` (predicado inline
 * `getLowStockProducts`) y pasa a consumir `useCriticalStock(branchId)`,
 * respetando el selector `?branch=` como el resto del Tablero.
 */

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import DashboardPage from "@/app/(dashboard)/dashboard/page"

// ── Mock de next/navigation (?branch=) ──────────────────────────────────────

let searchParamsString = ""

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams(searchParamsString),
}))

// ── Mock del hook bajo prueba ────────────────────────────────────────────────

const useCriticalStockMock = vi.fn()
vi.mock("@/hooks/data/use-critical-stock", () => ({
  useCriticalStock: (...args: unknown[]) => useCriticalStockMock(...args),
}))

// ── Mocks del resto de dependencias de la página (fuera de alcance) ─────────

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [] }),
}))

vi.mock("@/hooks/data/use-insights", () => ({
  useInsights: () => ({ insights: [], refreshInsights: vi.fn() }),
}))

vi.mock("@/hooks/use-greeting", () => ({
  useGreeting: () => ({ greeting: "Buen día" }),
}))

vi.mock("@/hooks/three/useGoalMilestone", () => ({
  useGoalMilestone: () => null,
}))

vi.mock("@/components/three/Celebration3D", () => ({
  Celebration3D: () => null,
}))

vi.mock("@/components/dashboard/kpi-card", () => ({
  KpiCard: ({ title, value }: { title: string; value: string }) => (
    <div data-testid={`kpi-card-${title}`}>{value}</div>
  ),
}))

vi.mock("@/components/dashboard/sales-chart", () => ({ SalesChart: () => null }))
vi.mock("@/components/dashboard/ai-summary-card", () => ({ AiSummaryCard: () => null }))
vi.mock("@/components/dashboard/recent-activity", () => ({ RecentActivity: () => null }))
vi.mock("@/components/dashboard/ai-alerts", () => ({ AiAlerts: () => null }))
vi.mock("@/components/dashboard/TrialBanner", () => ({ TrialBanner: () => null }))
vi.mock("@/components/branches/BranchFilter", () => ({ BranchFilter: () => null }))
vi.mock("@/components/dashboard/KpiSummaryBlock", () => ({ KpiSummaryBlock: () => null }))
vi.mock("@/components/dashboard/PeriodFilter", () => ({ PeriodFilter: () => null }))
// cobranzas-panel: la 5ta tarjeta consume useReceivablesSummary via
// python-client, que lanza en import-time sin NEXT_PUBLIC_BACKEND_URL —
// mockear el hook mantiene este test enfocado en la tarjeta de stock.
vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivablesSummary: () => ({ data: null, isLoading: true, isError: false }),
}))

vi.mock("@/lib/services/aiInsightService", () => ({
  aiInsightService: { generateInsights: vi.fn().mockResolvedValue(undefined) },
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: vi.fn().mockResolvedValue({ data: [], error: null }),
  }),
}))

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Tablero — tarjeta Productos en alerta", () => {
  beforeEach(() => {
    useCriticalStockMock.mockReset()
    searchParamsString = ""
  })

  it("sin ?branch= consulta el hook con branchId null (agregado, D2)", () => {
    useCriticalStockMock.mockReturnValue({ data: 4, isLoading: false })
    render(<DashboardPage />)

    expect(useCriticalStockMock).toHaveBeenCalledWith(null)
    expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("4")
  })

  it("con ?branch=<uuid> consulta el hook con esa sucursal y muestra su conteo", () => {
    searchParamsString = "branch=branch-9"
    useCriticalStockMock.mockReturnValue({ data: 1, isLoading: false })
    render(<DashboardPage />)

    expect(useCriticalStockMock).toHaveBeenCalledWith("branch-9")
    expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("1")
  })

  it("cambiar el selector de sucursal vuelve a consultar el hook con el nuevo branchId", () => {
    useCriticalStockMock.mockReturnValue({ data: 4, isLoading: false })
    const { rerender } = render(<DashboardPage />)
    expect(useCriticalStockMock).toHaveBeenCalledWith(null)

    searchParamsString = "branch=branch-9"
    useCriticalStockMock.mockReturnValue({ data: 1, isLoading: false })
    rerender(<DashboardPage />)

    expect(useCriticalStockMock).toHaveBeenLastCalledWith("branch-9")
    expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("1")
  })

  it("mientras el KPI carga, muestra — igual que las otras tarjetas", () => {
    useCriticalStockMock.mockReturnValue({ data: 0, isLoading: true })
    render(<DashboardPage />)

    expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("—")
  })

  it("si el KPI falla, muestra 0 y el resto del Tablero sigue renderizando", () => {
    useCriticalStockMock.mockReturnValue({ data: 0, isLoading: false, isError: true })
    render(<DashboardPage />)

    expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("0")
    expect(screen.getByTestId("kpi-card-Ventas hoy")).toBeInTheDocument()
  })

  it("no reimplementa el predicado de criticidad (grep de regresión sobre el código fuente)", () => {
    const source = readFileSync(
      join(process.cwd(), "app/(dashboard)/dashboard/page.tsx"),
      "utf-8",
    )
    expect(source).not.toMatch(/getLowStockProducts/)
    expect(source).not.toMatch(/stock\s*<=\s*(p\.)?minStock/)
  })
})
