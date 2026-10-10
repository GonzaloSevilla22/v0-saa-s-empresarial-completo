/**
 * PosPage — la sucursal activa es la PRINCIPAL del servidor
 * (ventas-sucursal-por-defecto, D10, tarea 5.4).
 *
 * El POS tomaba `branches[0]` como "la principal": con esa sucursal busca la
 * caja y la sesión, arma el enlace «Ir a caja de …» y la manda EXPLÍCITA como
 * `branch_id`. Si la más antigua está CERRADA, el servidor la saltea
 * (`c26_default_branch` exige `status = 'active'`) pero el POS mandaba la cerrada
 * y `_c29_confirm_order_core` rechazaba la venta con `branch_closed`. Ahora usa
 * `resolveDefaultBranch`, el espejo del servidor.
 *
 * Mismas dependencias mockeadas que pos-operation-errors.test.tsx (ProductPicker
 * funcional para poder agregar al carrito y cobrar).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
const PRODUCT = {
  id: PRODUCT_ID, name: "Top Pupera Liso", category: "Ropa", cost: 100, price: 200,
  margin: 50, stock: 10, minStock: 1, isVariant: false,
}
const PM_CASH = { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash" as const, isActive: true, sortOrder: 1, createdAt: "2026-01-01" }

type BranchFixture = { id: string; name: string; isActive: boolean; status: "active" | "closed" }
const CERRADA: BranchFixture = { id: "b-cerrada", name: "Depósito viejo", isActive: true, status: "closed" }
const OPERATIVA: BranchFixture = { id: "b-operativa", name: "Centro", isActive: true, status: "active" }
const OTRA: BranchFixture = { id: "b-otra", name: "Showroom", isActive: true, status: "active" }

const { quickSaleMutateAsync, useCashboxesMock } = vi.hoisted(() => ({
  quickSaleMutateAsync: vi.fn(),
  useCashboxesMock: vi.fn(),
}))
let branchesMockValue: BranchFixture[] = []
let currentSessionMockValue: { data: { id: string } | null; isLoading: boolean } = { data: { id: "sess-1" }, isLoading: false }

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT] }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: branchesMockValue }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: (...args: unknown[]) => useCashboxesMock(...args) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => currentSessionMockValue }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/hooks/use-idempotency-key", () => ({
  useIdempotencyKey: () => ({ idempotencyKey: "idem-1", resetIdempotencyKey: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({
  useQuickSale: () => ({ mutateAsync: quickSaleMutateAsync, isPending: false }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [PM_CASH], isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null, isLoading: false }) }))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: FACTORY_SCALE_SETTINGS, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/components/three/Celebration3D", () => ({ Celebration3D: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ products, onValueChange }: { products: { id: string; name: string }[]; onValueChange: (id: string) => void }) => (
    <select aria-label="Producto" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Elegí un producto</option>
      {products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
    </select>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, listContent, footerContent }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{listContent}{footerContent}</>
  ),
}))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({ options, onValueChange }: { options: { value: string; label: string }[]; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Consumidor final</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))

import PosPage from "@/app/(dashboard)/ventas/pos/page"

beforeEach(() => {
  vi.clearAllMocks()
  branchesMockValue = []
  currentSessionMockValue = { data: { id: "sess-1" }, isLoading: false }
  useCashboxesMock.mockReturnValue({ data: [{ id: "cb-1" }] })
  quickSaleMutateAsync.mockResolvedValue({ sales_order_id: "so-1", total: "200", replayed: false })
})

function addProductToCart() {
  fireEvent.change(screen.getByLabelText("Producto"), { target: { value: PRODUCT_ID } })
  fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
}

describe("PosPage — la sucursal activa es la principal del servidor (D10)", () => {
  it("con la más antigua CERRADA, la caja se busca en la siguiente operativa y la venta la manda como branch_id", async () => {
    branchesMockValue = [CERRADA, OPERATIVA, OTRA]

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(quickSaleMutateAsync).toHaveBeenCalledTimes(1))
    expect(quickSaleMutateAsync.mock.calls[0][0].branch_id).toBe("b-operativa")
    expect(useCashboxesMock).toHaveBeenCalledWith("b-operativa")
    expect(useCashboxesMock).not.toHaveBeenCalledWith("b-cerrada")
  })

  it("sin ninguna cerrada: sigue siendo la primera de la lista (sin cambio de comportamiento)", async () => {
    branchesMockValue = [OPERATIVA, OTRA]

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(quickSaleMutateAsync).toHaveBeenCalledTimes(1))
    expect(quickSaleMutateAsync.mock.calls[0][0].branch_id).toBe("b-operativa")
  })

  it("el enlace «Ir a caja de …» (sin sesión abierta) apunta a la principal operativa, no a la cerrada", () => {
    branchesMockValue = [CERRADA, OPERATIVA]
    currentSessionMockValue = { data: null, isLoading: false }

    render(<PosPage />)

    const link = screen.getByRole("link", { name: /ir a caja de centro/i })
    expect(link).toHaveAttribute("href", "/sucursales/b-operativa/caja")
    expect(screen.queryByRole("link", { name: /depósito viejo/i })).not.toBeInTheDocument()
  })

  it("cuenta sin sucursales: no manda branch_id (el servidor resuelve o rechaza con no_branch_found)", async () => {
    branchesMockValue = []

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(quickSaleMutateAsync).toHaveBeenCalledTimes(1))
    expect(quickSaleMutateAsync.mock.calls[0][0].branch_id).toBeNull()
  })
})
