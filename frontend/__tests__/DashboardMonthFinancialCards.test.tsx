/**
 * TDD tests para las tarjetas financieras del Tablero
 * (fix ad-hoc tablero-kpis-mes-vigente, D3/D4).
 *
 * Pedido del PO (2026-09-30): "Ventas hoy / Gastos hoy / Ganancia neta hoy"
 * pasan a calcularse y mostrarse sobre el MES vigente. Siguen el selector de
 * período (?period=YYYY-MM) y de sucursal (?branch=), igual que el Bloque
 * Resumen KPI de arriba. La ventana del DÍA se conserva sólo para lo que sigue
 * siendo "hoy": el footer del Resumen AI del día y la celebración de meta.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import DashboardPage from "@/app/(dashboard)/dashboard/page"
import type { DashboardFinancials } from "@/lib/reporting/dashboard-financials"
import { utcMonthRange } from "@/lib/date-range"

// ── Mock de next/navigation (?period= / ?branch=) ───────────────────────────

let searchParamsString = ""

vi.mock("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams(searchParamsString),
}))

// ── Mock del hook bajo prueba ────────────────────────────────────────────────

interface FinancialsHookState {
  data: DashboardFinancials | null
  isLoading: boolean
  isFetching?: boolean
  isError?: boolean
}

interface HookRange {
  from: string
  to: string
}

/** Una ventana de un solo día calendario (from y to caen el mismo día UTC). */
const isDayRange = (range: HookRange): boolean =>
  range.from.slice(0, 10) === range.to.slice(0, 10)

let monthState: FinancialsHookState
let dayState: FinancialsHookState

const useDashboardFinancialsMock = vi.fn((range: HookRange, _branchId: string | null) =>
  isDayRange(range) ? dayState : monthState,
)

vi.mock("@/hooks/data/use-dashboard-financials", () => ({
  useDashboardFinancials: (range: HookRange, branchId: string | null) =>
    useDashboardFinancialsMock(range, branchId),
}))

// ── Mocks del resto de dependencias de la página (fuera de alcance) ─────────

vi.mock("@/hooks/data/use-critical-stock", () => ({
  useCriticalStock: () => ({ data: 2, isLoading: false, isError: false }),
}))

vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivablesSummary: () => ({
    data: { totalReceivable: 21000 },
    isLoading: false,
    isError: false,
  }),
}))

vi.mock("@/hooks/data/use-insights", () => ({
  useInsights: () => ({ insights: [], refreshInsights: vi.fn() }),
}))

vi.mock("@/hooks/use-greeting", () => ({
  useGreeting: () => ({ greeting: "Buen día" }),
}))

const useGoalMilestoneMock = vi.fn(
  (_value: number, _thresholds: readonly number[], _isLoading: boolean) => null,
)
vi.mock("@/hooks/three/useGoalMilestone", () => ({
  useGoalMilestone: (value: number, thresholds: readonly number[], isLoading: boolean) =>
    useGoalMilestoneMock(value, thresholds, isLoading),
}))

vi.mock("@/components/three/Celebration3D", () => ({
  Celebration3D: () => null,
}))

vi.mock("@/components/dashboard/kpi-card", () => ({
  KpiCard: ({ title, value }: { title: string; value: string }) => (
    <div data-testid={`kpi-card-${title}`}>{value}</div>
  ),
}))

vi.mock("@/components/dashboard/ai-summary-card", () => ({
  AiSummaryCard: ({ todaySales, branchId }: { todaySales?: number; branchId?: string | null }) => (
    <div
      data-testid="ai-summary-card"
      data-today-sales={String(todaySales)}
      data-branch-id={String(branchId)}
    />
  ),
}))

vi.mock("@/components/dashboard/sales-chart", () => ({ SalesChart: () => null }))
vi.mock("@/components/dashboard/recent-activity", () => ({ RecentActivity: () => null }))
vi.mock("@/components/dashboard/ai-alerts", () => ({ AiAlerts: () => null }))
vi.mock("@/components/dashboard/TrialBanner", () => ({ TrialBanner: () => null }))
vi.mock("@/components/branches/BranchFilter", () => ({ BranchFilter: () => null }))
// El bloque se reemplaza por un espía de props: la fila y el bloque tienen que
// recibir la misma ventana y la misma sucursal (escenario "La ganancia neta del
// mes coincide con la del Bloque Resumen").
interface KpiSummaryBlockProps {
  periodDate: Date
  branchId: string | null
}
const kpiSummaryBlockMock = vi.fn((_props: KpiSummaryBlockProps) => null)
vi.mock("@/components/dashboard/KpiSummaryBlock", () => ({
  KpiSummaryBlock: (props: KpiSummaryBlockProps) => kpiSummaryBlockMock(props),
}))
vi.mock("@/components/dashboard/PeriodFilter", () => ({ PeriodFilter: () => null }))

vi.mock("@/lib/services/aiInsightService", () => ({
  aiInsightService: { generateInsights: vi.fn().mockResolvedValue(undefined) },
}))

// ── Fixtures ──────────────────────────────────────────────────────────────────

// Reloj fijo: 2026-09-15 12:00 ART (15:00Z) → mes vigente = septiembre 2026.
const NOW = new Date("2026-09-15T15:00:00.000Z")

const SEPTEMBER = { from: "2026-09-01T00:00:00.000Z", to: "2026-09-30T23:59:59.999Z" }
const AUGUST = { from: "2026-08-01T00:00:00.000Z", to: "2026-08-31T23:59:59.999Z" }
const JULY = { from: "2026-07-01T00:00:00.000Z", to: "2026-07-31T23:59:59.999Z" }
const TODAY = { from: "2026-09-15T00:00:00.000Z", to: "2026-09-15T23:59:59.999Z" }

// netProfit NO es income − expenses (las compras también restan): se asserta
// que la tarjeta muestra lo que devuelve el read-model, sin recalcular.
const MONTH_DATA: DashboardFinancials = {
  totalIncome: 750,
  totalExpenses: 120,
  totalPurchases: 200,
  netProfit: 430,
}

const DAY_DATA: DashboardFinancials = {
  totalIncome: 90,
  totalExpenses: 15,
  totalPurchases: 0,
  netProfit: 75,
}

const cardTestIds = (): string[] =>
  screen.getAllByTestId(/^kpi-card-/).map((el) => el.getAttribute("data-testid") as string)

/** Última llamada al hook con la ventana del MES (no la del día). */
function lastMonthCall(): [HookRange, string | null] {
  const monthCalls = useDashboardFinancialsMock.mock.calls.filter(([range]) => !isDayRange(range))
  const last = monthCalls[monthCalls.length - 1]
  if (!last) throw new Error("useDashboardFinancials no se llamó con la ventana del mes")
  return last
}

/** Props del último render del Bloque Resumen KPI. */
function lastBlockProps(): KpiSummaryBlockProps {
  const calls = kpiSummaryBlockMock.mock.calls
  const last = calls[calls.length - 1]
  if (!last) throw new Error("KpiSummaryBlock no se renderizó")
  return last[0]
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Tablero — tarjetas financieras del mes vigente", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(NOW)
    searchParamsString = ""
    monthState = { data: MONTH_DATA, isLoading: false, isError: false }
    dayState = { data: DAY_DATA, isLoading: false, isError: false }
    useDashboardFinancialsMock.mockClear()
    useGoalMilestoneMock.mockClear()
    kpiSummaryBlockMock.mockClear()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  describe("títulos", () => {
    it("muestra Ventas/Gastos/Ganancia neta 'del mes' en lugar de 'hoy'", () => {
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toBeInTheDocument()
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toBeInTheDocument()
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toBeInTheDocument()
    })

    it("ninguna tarjeta de la fila conserva un título con 'hoy'", () => {
      render(<DashboardPage />)

      const ids = cardTestIds()
      expect(ids.filter((id) => /hoy/i.test(id))).toEqual([])
    })

    it("la fila conserva sus 5 tarjetas, en el mismo orden", () => {
      render(<DashboardPage />)

      expect(cardTestIds()).toEqual([
        "kpi-card-Ventas del mes",
        "kpi-card-Gastos del mes",
        "kpi-card-Ganancia neta del mes",
        "kpi-card-Productos en alerta",
        "kpi-card-Por cobrar",
      ])
    })
  })

  describe("valores", () => {
    it("muestra los totales del mes devueltos por el read-model (no los del día)", () => {
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toHaveTextContent("$750")
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toHaveTextContent("$120")
      // net_profit del RPC (430), NO income − expenses (630): las compras restan.
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent("$430")
    })

    it("formatea miles con toLocaleString, igual que antes", () => {
      monthState = {
        data: { totalIncome: 1234567, totalExpenses: 4321, totalPurchases: 0, netProfit: 99000 },
        isLoading: false,
        isError: false,
      }
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toHaveTextContent(
        `$${(1234567).toLocaleString()}`,
      )
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toHaveTextContent(
        `$${(4321).toLocaleString()}`,
      )
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent(
        `$${(99000).toLocaleString()}`,
      )
    })

    it("período sin datos muestra $0", () => {
      monthState = {
        data: { totalIncome: 0, totalExpenses: 0, totalPurchases: 0, netProfit: 0 },
        isLoading: false,
        isError: false,
      }
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toHaveTextContent("$0")
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toHaveTextContent("$0")
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent("$0")
    })

    it("una ganancia neta negativa se muestra con su signo", () => {
      monthState = {
        data: { totalIncome: 100, totalExpenses: 300, totalPurchases: 0, netProfit: -200 },
        isLoading: false,
        isError: false,
      }
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent(
        `$${(-200).toLocaleString()}`,
      )
    })

    it("mientras el mes carga, las tres tarjetas muestran —", () => {
      monthState = { data: null, isLoading: true, isError: false }
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toHaveTextContent("—")
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toHaveTextContent("—")
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent("—")
    })

    it("si el read-model falla, muestra $0, lo registra y el resto del Tablero renderiza", () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
      monthState = { data: null, isLoading: false, isError: true }
      render(<DashboardPage />)

      expect(screen.getByTestId("kpi-card-Ventas del mes")).toHaveTextContent("$0")
      expect(screen.getByTestId("kpi-card-Gastos del mes")).toHaveTextContent("$0")
      expect(screen.getByTestId("kpi-card-Ganancia neta del mes")).toHaveTextContent("$0")
      expect(errorSpy).toHaveBeenCalled()
      expect(screen.getByTestId("kpi-card-Productos en alerta")).toHaveTextContent("2")
    })
  })

  describe("ventana consultada", () => {
    it("sin ?period= usa el mes vigente (ART) y sin sucursal (null)", () => {
      render(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(SEPTEMBER, null)
    })

    it("con ?period=2026-08&branch=b1 consulta agosto para la sucursal b1", () => {
      searchParamsString = "period=2026-08&branch=b1"
      render(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(AUGUST, "b1")
    })

    it("?period= inválido cae al mes vigente (mismo fallback que el Bloque Resumen)", () => {
      searchParamsString = "period=basura"
      render(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(SEPTEMBER, null)
    })

    it("cambiar el período recalcula: la ventana del mes sigue al selector", () => {
      searchParamsString = "period=2026-08"
      const { rerender } = render(<DashboardPage />)
      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(AUGUST, null)

      searchParamsString = "period=2026-07"
      rerender(<DashboardPage />)

      const monthCalls = useDashboardFinancialsMock.mock.calls.filter(
        ([range]) => !isDayRange(range),
      )
      expect(monthCalls[monthCalls.length - 1]).toEqual([JULY, null])
    })

    it("el selector de sucursal sigue aplicando: cambiar ?branch= cambia la consulta", () => {
      const { rerender } = render(<DashboardPage />)
      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(SEPTEMBER, null)

      searchParamsString = "branch=branch-9"
      rerender(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(SEPTEMBER, "branch-9")
    })

    // Escenario de spec "La ganancia neta del mes coincide con la del Bloque
    // Resumen": la igualdad de importes la fija el gate SQL
    // (test_kpis_edge_cases.sql); lo que fija este test es que la página le
    // pase a las dos superficies la MISMA ventana y la MISMA sucursal.
    it("el Bloque Resumen y las tarjetas del mes reciben la misma ventana y sucursal (mes en curso)", () => {
      render(<DashboardPage />)

      const [monthRange, monthBranch] = lastMonthCall()
      const block = lastBlockProps()
      expect(monthRange).toEqual(SEPTEMBER)
      expect(utcMonthRange(block.periodDate)).toEqual(monthRange)
      expect(block.branchId).toBeNull()
      expect(monthBranch).toBeNull()
    })

    it("con ?period=2026-08&branch=b1 el Bloque Resumen y las tarjetas del mes siguen sincronizados", () => {
      searchParamsString = "period=2026-08&branch=b1"
      render(<DashboardPage />)

      const [monthRange, monthBranch] = lastMonthCall()
      const block = lastBlockProps()
      expect(monthRange).toEqual(AUGUST)
      expect(utcMonthRange(block.periodDate)).toEqual(monthRange)
      expect(block.branchId).toBe("b1")
      expect(monthBranch).toBe("b1")
    })
  })

  describe("lo que sigue siendo hoy (D4)", () => {
    it("el Resumen AI del día recibe las ventas de HOY, no las del mes", () => {
      render(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(TODAY, null)
      expect(screen.getByTestId("ai-summary-card")).toHaveAttribute("data-today-sales", "90")
    })

    it("el Resumen AI sigue la sucursal, y NO cambia con el selector de período", () => {
      searchParamsString = "period=2026-07&branch=b1"
      render(<DashboardPage />)

      expect(useDashboardFinancialsMock).toHaveBeenCalledWith(TODAY, "b1")
      expect(screen.getByTestId("ai-summary-card")).toHaveAttribute("data-today-sales", "90")
      expect(screen.getByTestId("ai-summary-card")).toHaveAttribute("data-branch-id", "b1")
    })

    it("la celebración de meta se evalúa contra las ventas de HOY y su carga", () => {
      dayState = { data: DAY_DATA, isLoading: true, isError: false }
      render(<DashboardPage />)

      const [value, thresholds, isLoading] = useGoalMilestoneMock.mock.calls[0]
      expect(value).toBe(90)
      expect(thresholds).toEqual([50_000, 100_000, 250_000, 500_000, 1_000_000])
      expect(isLoading).toBe(true)
    })

    it("si la ventana del día se está refrescando (valor cacheado a punto de cambiar), la celebración espera", () => {
      // Remontaje del Tablero con datos en caché: isLoading es false pero la
      // consulta está en curso. Tomar ese valor viejo como línea base haría
      // "festejar" al entrar una venta hecha en el POS mientras tanto
      // (useGoalMilestone nunca reporta la primera lectura).
      dayState = { data: DAY_DATA, isLoading: false, isFetching: true, isError: false }
      render(<DashboardPage />)

      const [value, , isLoading] = useGoalMilestoneMock.mock.calls[0]
      expect(value).toBe(90)
      expect(isLoading).toBe(true)
    })

    it("con la ventana del día resuelta y sin refresco en curso, la celebración queda habilitada", () => {
      dayState = { data: DAY_DATA, isLoading: false, isFetching: false, isError: false }
      render(<DashboardPage />)

      const [, , isLoading] = useGoalMilestoneMock.mock.calls[0]
      expect(isLoading).toBe(false)
    })

    it("sin datos del día, el Resumen AI recibe 0 (degradación, no NaN)", () => {
      dayState = { data: null, isLoading: false, isError: true }
      vi.spyOn(console, "error").mockImplementation(() => {})
      render(<DashboardPage />)

      expect(screen.getByTestId("ai-summary-card")).toHaveAttribute("data-today-sales", "0")
    })
  })
})
