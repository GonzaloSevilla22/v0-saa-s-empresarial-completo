/**
 * /reportes/formas-pago — la columna de gastos (gastos-forma-pago, D14).
 *
 * Escenario de spec `payment-method`: "La pantalla del reporte muestra la
 * columna de gastos" — la tabla incluye una columna de gastos junto a las de
 * ventas y compras Y los totales de la pantalla coinciden con los del
 * read-model. Hasta el hallazgo de la revisión adversarial del apply, la única
 * cobertura era la de `lib/payment-method-report.ts` (el mapper con datos
 * sintéticos): nada renderizaba la pantalla ni ejercitaba la cadena
 * `GET /reports/payment-methods` → mapper → tabla.
 *
 * Los importes son los MISMOS que fija el gate SQL en 6.2/6.4 (6000 + 7000 +
 * 800 = 13.800) para que las dos capas no puedan divergir en silencio.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get, post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acc-1" } }),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: 365 } }),
}))
// Recharts no mide en jsdom (ResponsiveContainer queda en 0×0): la serie del
// gráfico se verifica por los datos que la pantalla le pasa, no por el SVG.
vi.mock("recharts", () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Passthrough,
    BarChart: ({ data, children }: { data: unknown[]; children?: React.ReactNode }) => (
      <div data-testid="chart" data-series={JSON.stringify(data)}>{children}</div>
    ),
    Bar: ({ dataKey }: { dataKey: string }) => <div data-testid={`bar-${dataKey}`} />,
    XAxis: () => null,
    YAxis: () => null,
    Tooltip: () => null,
    Cell: () => null,
  }
})

import FormasPagoReportPage from "@/app/(dashboard)/reportes/formas-pago/page"

const ROWS = [
  {
    payment_method_id: "pm-cash", payment_method_name: "Efectivo",
    payment_method_kind: "cash", is_active: true,
    total_sold: 20000, total_purchased: 0, total_spent: 6000, operation_count: 4,
  },
  {
    payment_method_id: "pm-transfer", payment_method_name: "Transferencia",
    payment_method_kind: "transfer", is_active: true,
    total_sold: 0, total_purchased: 5000, total_spent: 7000, operation_count: 3,
  },
  {
    payment_method_id: null, payment_method_name: null,
    payment_method_kind: null, is_active: true,
    total_sold: 0, total_purchased: 0, total_spent: 800, operation_count: 1,
  },
]

function renderPage() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    React.createElement(
      QueryClientProvider,
      { client: queryClient },
      React.createElement(FormasPagoReportPage),
    ),
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  get.mockResolvedValue(ROWS)
})

describe("/reportes/formas-pago — columna de gastos (D14)", () => {
  it("la tabla trae la columna Gastado junto a Vendido y Comprado", async () => {
    renderPage()
    await waitFor(() => expect(screen.getByText("Efectivo")).toBeInTheDocument())

    for (const header of ["Vendido", "Comprado", "Gastado"]) {
      expect(screen.getByRole("columnheader", { name: header })).toBeInTheDocument()
    }
  })

  it("cada fila muestra su total gastado y el pie cierra contra el read-model", async () => {
    renderPage()
    await waitFor(() => expect(screen.getByText("Efectivo")).toBeInTheDocument())

    // Las tres filas del read-model, con el mismo criterio de agregación que
    // el gate SQL: 6000 + 7000 + 800 = 13.800.
    expect(screen.getAllByText(/\$\s?6\.000/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\$\s?7\.000/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\$\s?800/).length).toBeGreaterThan(0)

    const footer = screen.getByText("Total del período").closest("tr")!
    expect(footer.textContent).toMatch(/13\.800/)
  })

  it("la fila sin imputar se muestra y suma al total gastado", async () => {
    renderPage()
    await waitFor(() => expect(screen.getByText("Sin especificar")).toBeInTheDocument())
  })

  it("el gráfico recibe la serie Gastado con el valor de cada forma de pago", async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId("chart")).toBeInTheDocument())

    expect(screen.getByTestId("bar-Gastado")).toBeInTheDocument()
    const series = JSON.parse(screen.getByTestId("chart").getAttribute("data-series") ?? "[]")
    expect(series.map((s: { Gastado: number }) => s.Gastado)).toEqual([6000, 7000, 800])
  })

  it("una lectura sin total_spent degrada a 0 y no rompe la pantalla", async () => {
    // Ventana de deploy: backend viejo de 7 columnas. El mapper degrada a 0, no
    // a NaN — la tabla tiene que seguir cerrando.
    get.mockResolvedValue(ROWS.map(({ total_spent, ...rest }) => rest))
    renderPage()
    await waitFor(() => expect(screen.getByText("Efectivo")).toBeInTheDocument())

    const footer = screen.getByText("Total del período").closest("tr")!
    expect(footer.textContent).not.toMatch(/NaN/)
  })
})
