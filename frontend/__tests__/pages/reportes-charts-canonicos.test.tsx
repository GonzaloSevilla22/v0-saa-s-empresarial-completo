/**
 * migrar-reportes-a-charts-canonicos (CLAUDE.md ~L249, origen estadisticas-ventas
 * D13) — los tres reportes legacy (/reportes/formas-pago, /reportes/centros-costo,
 * /reportes/sucursal) dejan de dibujar su propio <BarChart> inline y montan el
 * componente canónico `ReportBarChart` (components/charts/ReportBarChart.tsx),
 * el mismo que ya usa /estadisticas.
 *
 * majors (3): la migración se verificó antes SÓLO por el contrato accesible
 * (role="img" + aria-label) — nunca se comprobó que los DATOS que llegan al
 * componente fueran los mismos que el <BarChart> bespoke dibujaba (las claves
 * de cada serie, sus colores fijos, y un valor conocido formateado igual que
 * antes). Este archivo stubea `ReportBarChart` (mismo patrón que
 * EstadisticasPage.test.tsx con ExportButton) y fija esas tres cosas.
 *
 * RED antes de la migración: el <BarChart> bespoke de cada página NO exponía
 * `role="img"` + `aria-label` — ReportBarChart sí, por contrato (ver
 * __tests__/components/report-charts.test.tsx). Este test falla contra la
 * implementación vieja y pasa sólo cuando la pantalla monta el componente
 * canónico con los datos mapeados.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { formatMoney } from "@/lib/format"
import { REPORT_SERIES_COLORS } from "@/lib/report-chart-colors"
import type { ReportBarChartProps } from "@/components/charts/ReportBarChart"

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
const rpcMock = vi.fn()

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get, post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: rpcMock }),
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acc-1" } }),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: 365, hasBranchesModule: true }, isLoading: false }),
}))

// majors (3a): stub que CAPTURA las props tal cual la pantalla se las manda —
// mismo patrón que EstadisticasPage.test.tsx con ExportButton. Conserva
// role="img"/aria-label (el contrato accesible que este archivo ya cubría)
// para no perder esa cobertura al migrar el test.
const chartMock = vi.fn()
vi.mock("@/components/charts/ReportBarChart", () => ({
  ReportBarChart: (props: ReportBarChartProps) => {
    chartMock(props)
    return <div role="img" aria-label={props.ariaLabel} data-testid="chart-stub" />
  },
}))

import FormasPagoReportPage from "@/app/(dashboard)/reportes/formas-pago/page"
import CentrosCostoReportPage from "@/app/(dashboard)/reportes/centros-costo/page"
import SucursalReportPage from "@/app/(dashboard)/reportes/sucursal/page"

function renderPage(Page: React.ComponentType) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <Page />
    </QueryClientProvider>,
  )
}

function lastChartProps(): ReportBarChartProps {
  return chartMock.mock.calls.at(-1)?.[0] as ReportBarChartProps
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("/reportes/formas-pago monta ReportBarChart con los datos, series y formato que dibujaba antes", () => {
  it("expone el gráfico como imagen con su rótulo, y las series Vendido/Comprado/Gastado con sus colores fijos", async () => {
    get.mockResolvedValue([
      {
        payment_method_id: "pm-cash", payment_method_name: "Efectivo",
        payment_method_kind: "cash", is_active: true,
        total_sold: 1000, total_purchased: 500, total_spent: 200, operation_count: 1,
      },
    ])
    renderPage(FormasPagoReportPage)
    await waitFor(() => expect(chartMock).toHaveBeenCalled())

    const props = lastChartProps()
    expect(props.ariaLabel).toBe("Vendido, comprado y gastado por forma de pago")
    expect(props.data).toEqual([{ name: "Efectivo", Vendido: 1000, Comprado: 500, Gastado: 200 }])
    expect(props.series).toEqual([
      { key: "Vendido", name: "Vendido", color: REPORT_SERIES_COLORS.sold },
      { key: "Comprado", name: "Comprado", color: REPORT_SERIES_COLORS.purchased },
      { key: "Gastado", name: "Gastado", color: REPORT_SERIES_COLORS.spent },
    ])
    // minors (6): el truncado se fija en 13 para conservar el render que
    // tenía el <BarChart> bespoke (`length > 14 → slice(0,12)+"…"`, 13
    // caracteres visibles).
    expect(props.truncateLength).toBe(13)
    // Un valor conocido formateado igual que antes de la migración.
    expect(props.formatValue?.(1000)).toBe(formatMoney(1000))
  })
})

describe("/reportes/centros-costo monta ReportBarChart con los datos, series y formato que dibujaba antes", () => {
  it("expone el gráfico como imagen con su rótulo, y las series Gastos/Compras con sus colores fijos", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { cost_center_id: "cc-1", cost_center_name: "Logística", total_expenses: 5000, total_purchases: 3000, operation_count: 4 },
      ],
      error: null,
    })
    renderPage(CentrosCostoReportPage)
    await waitFor(() => expect(chartMock).toHaveBeenCalled())

    const props = lastChartProps()
    expect(props.ariaLabel).toBe("Gastos vs Compras por centro de costo")
    expect(props.data).toEqual([{ name: "Logística", Gastos: 5000, Compras: 3000 }])
    expect(props.series).toEqual([
      { key: "Gastos", name: "Gastos", color: REPORT_SERIES_COLORS.spent },
      { key: "Compras", name: "Compras", color: REPORT_SERIES_COLORS.purchased },
    ])
    expect(props.truncateLength).toBe(13)
    expect(props.formatValue?.(5000)).toBe(formatMoney(5000))
  })
})

describe("/reportes/sucursal monta ReportBarChart con los datos, series y formato que dibujaba antes", () => {
  it("expone el gráfico como imagen con su rótulo, y las series Ventas/Gastos con sus colores fijos", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { branch_id: "b-1", branch_name: "Casa Central", total_sales: 324850, total_expenses: 1158787, operation_count: 25 },
      ],
      error: null,
    })
    renderPage(SucursalReportPage)
    await waitFor(() => expect(chartMock).toHaveBeenCalled())

    const props = lastChartProps()
    expect(props.ariaLabel).toBe("Ventas vs Gastos por sucursal")
    expect(props.data).toEqual([{ name: "Casa Central", Ventas: 324850, Gastos: 1158787 }])
    expect(props.series).toEqual([
      { key: "Ventas", name: "Ventas", color: REPORT_SERIES_COLORS.sold },
      { key: "Gastos", name: "Gastos", color: REPORT_SERIES_COLORS.spent },
    ])
    expect(props.truncateLength).toBe(13)
    // /reportes/sucursal usa su propio fmtARS (maximumFractionDigits: 0),
    // no lib/format#formatMoney — mismo formato Intl que dibujaba antes.
    const fmtARS = (n: number) =>
      new Intl.NumberFormat("es-AR", { style: "currency", currency: "ARS", maximumFractionDigits: 0 }).format(n)
    expect(props.formatValue?.(324850)).toBe(fmtARS(324850))
  })
})
