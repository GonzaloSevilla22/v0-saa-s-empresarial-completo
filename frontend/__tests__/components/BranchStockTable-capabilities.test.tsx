/**
 * stock-ledger-solo-rpc (tanda B, task 12.4) — `BranchStockTable` (/sucursales/[id]/stock):
 *   - «Ajustar» se ofrece con `CAN_STOCK` (owner/admin/stock), decidido sobre el
 *     CONJUNTO de roles activos;
 *   - «Transferir» conserva su propia condición, `isWriter` (OQ-3: las transferencias
 *     no cambian de rol);
 *   - mientras el conjunto no resolvió, ambas son visibles (fail-open; la barrera
 *     real es la base).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { BranchStockTable } from "@/components/branches/BranchStockTable"

type OrgState = { role: string | null; roles: string[]; rolesResolved: boolean; isWriter: boolean; isLoading: boolean }

const org = vi.hoisted(() => ({
  value: { role: "member", roles: ["seller"], rolesResolved: true, isWriter: true, isLoading: false } as OrgState,
}))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => org.value }))
vi.mock("@/hooks/data/use-branch-stock", () => ({
  useBranchStock: () => ({
    isLoading: false,
    branchStock: [
      {
        id: "r1", accountId: "acc", productId: "p1", branchId: "b1", quantity: 10, minStock: 2,
        productName: "Tomate", productSku: null,
      },
    ],
  }),
}))
vi.mock("@/components/branches/AdjustStockModal", () => ({ AdjustStockModal: () => null }))
vi.mock("@/components/branches/TransferStockModal", () => ({ TransferStockModal: () => null }))

function setOrg(roles: string[], opts: { resolved?: boolean; isWriter?: boolean } = {}) {
  org.value = {
    role: "member",
    roles,
    rolesResolved: opts.resolved ?? true,
    isWriter: opts.isWriter ?? true,
    isLoading: false,
  }
}

const adjust = () => screen.queryByRole("button", { name: /ajustar stock de tomate/i })
const transfer = () => screen.queryByRole("button", { name: /transferir stock de tomate/i })

describe("BranchStockTable — acciones por capacidad", () => {
  beforeEach(() => setOrg(["seller"]))

  it.each([["seller"], ["cashier"], ["purchases"], ["accountant"]])(
    "un miembro %s (escritor, sin CAN_STOCK) ve «Transferir» pero NO «Ajustar»",
    (role) => {
      setOrg([role])
      render(<BranchStockTable branchId="b1" />)
      expect(adjust()).not.toBeInTheDocument()
      expect(transfer()).toBeInTheDocument()
    },
  )

  it.each([["stock"], ["admin"], ["owner"]])("el rol %s ve «Ajustar» y «Transferir»", (role) => {
    setOrg([role])
    render(<BranchStockTable branchId="b1" />)
    expect(adjust()).toBeInTheDocument()
    expect(transfer()).toBeInTheDocument()
  })

  it("un viewer (no escritor) no ve ninguna acción ni la columna «Acciones»", () => {
    setOrg(["viewer"], { isWriter: false })
    render(<BranchStockTable branchId="b1" />)
    expect(adjust()).not.toBeInTheDocument()
    expect(transfer()).not.toBeInTheDocument()
    expect(screen.queryByText("Acciones")).not.toBeInTheDocument()
  })

  it("con el conjunto sin resolver ve las dos acciones (fail-open)", () => {
    setOrg(["member"], { resolved: false })
    render(<BranchStockTable branchId="b1" />)
    expect(adjust()).toBeInTheDocument()
    expect(transfer()).toBeInTheDocument()
  })

  it("el listado se ve siempre: existencias y stock mínimo no dependen del rol", () => {
    setOrg(["seller"])
    render(<BranchStockTable branchId="b1" />)
    expect(screen.getByText("Tomate")).toBeInTheDocument()
    expect(screen.getByText("10")).toBeInTheDocument()
  })
})
