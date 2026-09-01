/**
 * qa-integral-modulos G12 (H16) — /reportes/centros-costo y /reportes/sucursal:
 * la primera serie usaba <Cell> con paleta rotativa por FILA, y esa paleta
 * incluye exactamente el color fijo de la otra serie ("Logística": Gastos y
 * Compras ambos azules; en sucursal COLORS[4]='#f87171' colisiona con el fill
 * de Gastos). Contrato: un color fijo por SERIE, sin Cells, con leyenda
 * (skill de dataviz: el color sigue a la entidad, nunca a su rango).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const rpcMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: rpcMock,
    auth: {
      getSession: async () => ({
        data: { session: { user: { id: "user-1", user_metadata: {} } } },
      }),
    },
  }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "acc-1" } }),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({
    limits: { hasBranchesModule: true, historyDays: 365 },
    isLoading: false,
  }),
}))

vi.mock("recharts", () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Passthrough,
    BarChart: ({ children }: { children?: React.ReactNode }) => (
      <div data-testid="chart">{children}</div>
    ),
    Bar: ({ dataKey, fill, children }: { dataKey: string; fill?: string; children?: React.ReactNode }) => (
      <div data-testid={`bar-${dataKey}`} data-fill={fill}>{children}</div>
    ),
    XAxis: () => null,
    YAxis: () => null,
    Tooltip: () => null,
    Legend: () => <div data-testid="legend" />,
    Cell: ({ fill }: { fill?: string }) => <div data-testid="cell" data-fill={fill} />,
  }
})

// Los dos módulos de página se importan ACÁ, no dentro del `it`: cada uno
// arrastra el kit de UI entero y su grafo tardaba ~4 s en importarse en una
// máquina libre — dentro del test eso consume el testTimeout de 20 s y con la
// suite completa en 8 workers se lo pasaba (clase H-3 del comentario de
// vitest.config.ts). Fuera del test, el costo cae en la fase de import del
// archivo, que no tiene ese techo. Los vi.mock de arriba se hoistean por
// encima de estos imports, así que siguen aplicando.
import CentrosCostoPage from "@/app/(dashboard)/reportes/centros-costo/page"
import SucursalPage from "@/app/(dashboard)/reportes/sucursal/page"

function renderPage(Page: React.ComponentType) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <Page />
    </QueryClientProvider>,
  )
}

async function expectFixedSeries(seriesKeys: string[]) {
  await waitFor(() => expect(screen.getByTestId("chart")).toBeInTheDocument())
  expect(screen.getByTestId("legend")).toBeInTheDocument()
  expect(screen.queryAllByTestId("cell")).toHaveLength(0)
  const fills = seriesKeys.map((k) => screen.getByTestId(`bar-${k}`).getAttribute("data-fill"))
  expect(new Set(fills).size).toBe(seriesKeys.length)
  for (const fill of fills) expect(fill).toBeTruthy()
}

beforeEach(() => {
  rpcMock.mockReset()
})

describe("/reportes/centros-costo — un color fijo por serie + leyenda (G12/H16)", () => {
  it("Gastos y Compras con fills propios y distintos, sin Cells, con leyenda", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { cost_center_id: "cc-1", cost_center_name: "Logística", total_expenses: 5000, total_purchases: 3000, operation_count: 4 },
        { cost_center_id: "cc-2", cost_center_name: "Ventas", total_expenses: 2000, total_purchases: 1000, operation_count: 2 },
      ],
      error: null,
    })
    renderPage(CentrosCostoPage)
    await expectFixedSeries(["Gastos", "Compras"])
  })
})

describe("/reportes/sucursal — un color fijo por serie + leyenda (G12/H16)", () => {
  it("Ventas y Gastos con fills propios y distintos, sin Cells, con leyenda", async () => {
    rpcMock.mockResolvedValue({
      data: [
        { branch_id: "b-1", branch_name: "Casa Central", total_sales: 324850, total_expenses: 1158787, operation_count: 25 },
        { branch_id: "b-2", branch_name: "Norte", total_sales: 1000, total_expenses: 500, operation_count: 2 },
      ],
      error: null,
    })
    renderPage(SucursalPage)
    await expectFixedSeries(["Ventas", "Gastos"])
  })
})
