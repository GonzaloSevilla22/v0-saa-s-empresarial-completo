/**
 * stock-ledger-solo-rpc (tanda B, task 12.1) — /stock ofrece las acciones de AJUSTE
 * MANUAL sólo a quien puede ajustar stock (`CAN_STOCK`: owner, admin, stock).
 *
 * Contrato (spec branch-stock «La superficie de ajuste manual se ofrece sólo a quien
 * puede ajustar y exige el motivo»):
 *   - "Ajustar stock", la acción de ajuste por fila e "Importar ajuste" se deciden
 *     sobre el CONJUNTO de roles activos (`useOrgRole().roles`) con
 *     `hasCapability(roles, CAN_STOCK, rolesResolved)`;
 *   - mientras el conjunto no resolvió la decisión es optimista (la barrera real es
 *     la base: `insufficient_role`);
 *   - "Transferir" conserva su propia condición (OQ-3: sigue con `isWriter`) y el
 *     listado se sigue viendo siempre.
 */
import { describe, expect, it, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

type OrgRoleState = {
  role: string | null
  roles: string[]
  rolesResolved: boolean
  isWriter: boolean
  isLoading: boolean
}

const org = vi.hoisted(() => ({
  value: { role: "member", roles: ["seller"], rolesResolved: true, isWriter: true, isLoading: false } as OrgRoleState,
}))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => org.value }))
vi.mock("next/navigation", () => ({ useSearchParams: () => new URLSearchParams() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false, user: null }) }))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({
    products: [
      {
        id: "p1", name: "Tomate", category: "Verdulería", price: 1000, cost: 600, stock: 8, minStock: 2,
        createdAt: "2026-09-24T00:00:00Z", stockControlType: "tracked",
      },
    ],
  }),
}))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))
vi.mock("@/components/stock/stock-adjustment-modal", () => ({ StockAdjustmentModal: () => null }))
vi.mock("@/components/stock/stock-import-adjustment-dialog", () => ({ StockImportAdjustmentDialog: () => null }))
vi.mock("@/components/stock/stock-movements-panel", () => ({ StockMovementsPanel: () => null }))
vi.mock("@/components/stock/low-stock-alert", () => ({ LowStockAlert: () => null }))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/export/ExportButton", () => ({ ExportButton: () => null }))
vi.mock("@/components/branches/TransferStockAction", () => ({ TransferStockAction: () => null }))
vi.mock("@/components/stock/ProductBranchBreakdown", () => ({ ProductBranchBreakdown: () => null }))
vi.mock("@/components/forms/product-form", () => ({ ProductForm: () => null }))
// El DataTable real arrastra paginación/orden; acá sólo importa lo que cada columna
// "adjust" rinde por fila y que el listado se sigue mostrando.
vi.mock("@/components/data-table/data-table", () => ({
  DataTable: ({ data, columns }: { data: Array<{ id: string; name: string }>; columns: Array<{ key: string; cell: (row: never) => React.ReactNode }> }) => (
    <ul>
      {data.map((row) => (
        <li key={row.id} data-testid="inventory-row">
          <span>{row.name}</span>
          {columns.find((c) => c.key === "adjust")?.cell(row as never)}
        </li>
      ))}
    </ul>
  ),
}))

import StockPage from "@/app/(dashboard)/stock/page"

function setRoles(roles: string[], resolved = true) {
  org.value = { role: "member", roles, rolesResolved: resolved, isWriter: true, isLoading: false }
}

function adjustControls() {
  return {
    header: screen.queryAllByRole("button", { name: /^ajustar( stock)?$/i }),
    importar: screen.queryAllByRole("button", { name: /importar ajuste/i }),
    row: screen.queryAllByTitle("Ajustar stock"),
  }
}

describe("/stock — las acciones de ajuste sólo para quien puede ajustar (CAN_STOCK)", () => {
  beforeEach(() => setRoles(["seller"]))

  it.each([["seller"], ["cashier"], ["purchases"], ["accountant"], ["viewer"]])(
    "un miembro con rol %s no ve «Ajustar stock», la acción por fila ni «Importar ajuste»",
    (role) => {
      setRoles([role])
      render(<StockPage />)
      const c = adjustControls()
      expect(c.header).toHaveLength(0)
      expect(c.importar).toHaveLength(0)
      expect(c.row).toHaveLength(0)
    },
  )

  it("sigue viendo el listado de existencias (la lectura no depende del rol)", () => {
    setRoles(["seller"])
    render(<StockPage />)
    expect(screen.getByRole("heading", { name: "Stock" })).toBeInTheDocument()
    expect(screen.getAllByTestId("inventory-row")).toHaveLength(1)
    expect(screen.getByText("Tomate")).toBeInTheDocument()
  })

  it.each([["stock"], ["admin"], ["owner"]])("el rol %s ve las tres acciones", (role) => {
    setRoles([role])
    render(<StockPage />)
    const c = adjustControls()
    expect(c.header.length).toBeGreaterThan(0)
    expect(c.importar.length).toBeGreaterThan(0)
    expect(c.row).toHaveLength(1)
  })

  it("un vendedor que además es de depósito (roles [seller, stock]) ajusta: se decide sobre el CONJUNTO", () => {
    setRoles(["seller", "stock"])
    render(<StockPage />)
    expect(adjustControls().header.length).toBeGreaterThan(0)
  })

  it("con el conjunto de roles sin resolver las acciones son visibles (fail-open: la barrera real es la base)", () => {
    setRoles(["member"], false)
    render(<StockPage />)
    const c = adjustControls()
    expect(c.header.length).toBeGreaterThan(0)
    expect(c.importar.length).toBeGreaterThan(0)
    expect(c.row).toHaveLength(1)
  })

  it("el conjunto RESUELTO y vacío (sin ningún rol activo) no ajusta", () => {
    setRoles([], true)
    render(<StockPage />)
    expect(adjustControls().header).toHaveLength(0)
  })
})
