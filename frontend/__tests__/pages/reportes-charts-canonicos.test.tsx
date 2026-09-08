/**
 * migrar-reportes-a-charts-canonicos (CLAUDE.md ~L249, origen estadisticas-ventas
 * D13) — los tres reportes legacy (/reportes/formas-pago, /reportes/centros-costo,
 * /reportes/sucursal) dejan de dibujar su propio <BarChart> inline y montan el
 * componente canónico `ReportBarChart` (components/charts/ReportBarChart.tsx),
 * el mismo que ya usa /estadisticas.
 *
 * RED antes de la migración: el <BarChart> bespoke de cada página NO exponía
 * `role="img"` + `aria-label` — ReportBarChart sí, por contrato (ver
 * __tests__/components/report-charts.test.tsx). Este test falla contra la
 * implementación vieja y pasa sólo cuando la pantalla monta el componente
 * canónico con los datos mapeados.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

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

beforeEach(() => {
  vi.clearAllMocks()
})

describe("/reportes/formas-pago monta ReportBarChart (contrato accesible role=img)", () => {
  it("expone el gráfico como imagen con su rótulo", async () => {
    get.mockResolvedValue([
      {
        payment_method_id: "pm-cash", payment_method_name: "Efectivo",
        payment_method_kind: "cash", is_active: true,
        total_sold: 1000, total_purchased: 0, total_spent: 0, operation_count: 1,
      },
    ])
    renderPage(FormasPagoReportPage)
    await waitFor(() =>
      expect(
        screen.getByRole("img", { name: "Vendido, comprado y gastado por forma de pago" }),
      ).toBeInTheDocument(),
    )
  })
})

describe("/reportes/centros-costo monta ReportBarChart (contrato accesible role=img)", () => {
  it("expone el gráfico como imagen con su rótulo", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { cost_center_id: "cc-1", cost_center_name: "Logística", total_expenses: 5000, total_purchases: 3000, operation_count: 4 },
      ],
      error: null,
    })
    renderPage(CentrosCostoReportPage)
    await waitFor(() =>
      expect(
        screen.getByRole("img", { name: "Gastos vs Compras por centro de costo" }),
      ).toBeInTheDocument(),
    )
  })
})

describe("/reportes/sucursal monta ReportBarChart (contrato accesible role=img)", () => {
  it("expone el gráfico como imagen con su rótulo", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { branch_id: "b-1", branch_name: "Casa Central", total_sales: 324850, total_expenses: 1158787, operation_count: 25 },
      ],
      error: null,
    })
    renderPage(SucursalReportPage)
    await waitFor(() =>
      expect(
        screen.getByRole("img", { name: "Ventas vs Gastos por sucursal" }),
      ).toBeInTheDocument(),
    )
  })
})
