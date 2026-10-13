/**
 * PurchaseForm — la sucursal por defecto a la vista (compras-gastos-sucursal-por-defecto,
 * D9, tarea 5.1).
 *
 * Una compra registrada sin sucursal elegida se guarda con la sucursal PRINCIPAL (la RPC
 * resuelve `COALESCE(p_branch_id, c26_default_branch)`), así que el formulario deja de
 * ofrecer «Sin sucursal (general)» y muestra la principal ya elegida, rotulada «(principal)»,
 * con su rótulo «Sucursal» dentro del selector. El estado del formulario NO cambia: sigue en
 * `null` hasta que el usuario elige otra y viaja `null`, y el SERVIDOR resuelve la principal con
 * datos vivos (el selector sólo MUESTRA lo que el servidor va a guardar).
 *
 * A diferencia de purchase-form-cash-optin / purchase-form-edit-context (que sustituyen
 * `BranchSelect`), acá se monta el `BranchSelect` REAL con el Select de Radix real: hace falta
 * para probar el rótulo, la lista y la ausencia de la opción sin sucursal. Se mockean los
 * hooks de plan y de sucursales. El caso del opt-in de caja fija la otra mitad del contrato:
 * el formulario ofrece la sesión de la principal PRE-MARCADA con la sucursal en `null`, y desde
 * este change el servidor la acepta (antes de este change la rechazaba siempre con
 * `cash_optin_requires_open_session`; lo prueba el bloque (6) del gate SQL).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Branch } from "@/lib/types"

const addPurchaseOperationMock = vi.fn().mockResolvedValue(undefined)
const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }

function branch(overrides: Partial<Branch> & { id: string; name: string }): Branch {
  return {
    accountId: "acc-1",
    address: null,
    isActive: true,
    createdAt: "2026-01-01T00:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...overrides,
  }
}

const CENTRO = branch({ id: "b-centro", name: "Centro" })
const SHOWROOM = branch({ id: "b-show", name: "Showroom", createdAt: "2026-03-01T00:00:00Z" })

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null
const usePlanLimitsMock = vi.fn()
const useBranchesMock = vi.fn()

vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => usePlanLimitsMock() }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: currentSessionMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn(), createProductCategoryMutation: { isPending: false } }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: addPurchaseOperationMock, updatePurchaseOperation: updatePurchaseOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({
    products,
    onValueChange,
  }: {
    products: Array<{ id: string; name: string }>
    onValueChange: (v: string) => void
  }) => (
    <div data-testid="product-picker">
      {products.map((p) => (
        <button key={p.id} type="button" data-testid={`product-option-${p.id}`} onClick={() => onValueChange(p.id)}>
          {p.name}
        </button>
      ))}
    </div>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{footerContent}</>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({ useSupplierAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: [], addSupplier: vi.fn(), isLoading: false, isError: false }),
}))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ onChange }: { onChange: (v: string | null) => void }) => (
    <div>
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>
          {pm.name}
        </button>
      ))}
    </div>
  ),
  BankAccountDestinationSelect: () => null,
}))

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }

function makeOperation(overrides: Partial<PurchaseOperation> = {}): PurchaseOperation {
  return {
    key: "op-1",
    operationId: "op-1",
    date: "2026-08-20",
    items: [
      {
        id: "purchase-1",
        date: "2026-08-20",
        productId: "prod-1",
        productName: "Insumo Test",
        quantity: 3,
        unitCost: 50,
        total: 150,
        operationId: "op-1",
        unitId: "unit-kg",
        branchId: "b-show",
        paymentMethodId: null,
      },
    ],
    total: 150,
    description: "",
    isGrouped: false,
    paymentMethodId: null,
    branchId: "b-show",
    unitId: "unit-kg",
    isPaymentLocked: false,
    hasAccountCharge: false,
    supplierId: null,
    supplierName: null,
    hasBankMovement: false,
    hasCashMovement: false,
    isDeleteBlocked: false,
    costCenterId: null,
    ...overrides,
  }
}

function addOneItemToCart() {
  fireEvent.click(screen.getByTestId("product-option-prod-1"))
  fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
}

beforeEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  currentSessionMock = null
  usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: true } })
  useBranchesMock.mockReturnValue({ branches: [CENTRO, SHOWROOM], isLoading: false, isError: false })
})

describe("PurchaseForm — el selector de sucursal muestra la principal (alta)", () => {
  it("muestra la principal rotulada «(principal)», sin «Sin sucursal (general)», con su rótulo «Sucursal»", async () => {
    const user = userEvent.setup()
    render(<PurchaseForm onSuccess={vi.fn()} />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)

    await user.click(trigger)
    const options = within(await screen.findByRole("listbox")).getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Centro (principal)", "Showroom"])
  })

  it("getByLabelText('Sucursal') encuentra el disparador (rótulo asociado por id)", () => {
    render(<PurchaseForm onSuccess={vi.fn()} />)

    expect(screen.getByLabelText("Sucursal")).toBe(screen.getByRole("combobox", { name: "Sucursal" }))
  })

  it("sin tocar el selector, el alta viaja con branchId null: el SERVIDOR resuelve la principal con datos vivos", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} />)
    addOneItemToCart()
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.branchId).toBeNull()
  })

  it("elegir otra sucursal manda su id", async () => {
    const user = userEvent.setup()
    render(<PurchaseForm onSuccess={vi.fn()} />)
    addOneItemToCart()

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Showroom" }))
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.branchId).toBe("b-show")
  })

  it("elegir la principal que ya se muestra no cambia el estado: sigue viajando null", async () => {
    const user = userEvent.setup()
    render(<PurchaseForm onSuccess={vi.fn()} />)
    addOneItemToCart()

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Centro (principal)" }))
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.branchId).toBeNull()
  })

  it("con la más antigua CERRADA, la principal mostrada es la siguiente operativa (espejo de c26_default_branch)", () => {
    const cerrada = branch({ id: "b-cerrada", name: "Depósito viejo", status: "closed", createdAt: "2025-06-01T00:00:00Z" })
    useBranchesMock.mockReturnValue({ branches: [cerrada, CENTRO, SHOWROOM], isLoading: false, isError: false })
    render(<PurchaseForm onSuccess={vi.fn()} />)

    expect(screen.getByRole("combobox", { name: "Sucursal" })).toHaveTextContent("Centro (principal)")
  })

  it("cuenta sin el módulo de sucursales: ni selector ni rótulo (el servidor registra la principal)", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
    render(<PurchaseForm onSuccess={vi.fn()} />)

    expect(screen.queryByRole("combobox", { name: "Sucursal" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Sucursal")).not.toBeInTheDocument()
    expect(screen.queryByText(/sin sucursal/i)).not.toBeInTheDocument()
  })
})

describe("PurchaseForm — el selector de sucursal en la edición", () => {
  it("precarga la sucursal de la compra y la reenvía en el payload", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)

    expect(screen.getByRole("combobox", { name: "Sucursal" })).toHaveTextContent("Showroom")
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))

    await waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(updatePurchaseOperationMock.mock.calls[0][0].meta.branchId).toBe("b-show")
  })

  it("una compra histórica sin sucursal muestra la principal y viaja null: el servidor la resuelve a la principal (D5)", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ branchId: null })} />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))

    await waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(updatePurchaseOperationMock.mock.calls[0][0].meta.branchId).toBeNull()
  })
})

describe("PurchaseForm — regresión del opt-in de caja con la sucursal en null", () => {
  it("compra en efectivo sin sucursal elegida: ofrece la sesión de la principal PRE-MARCADA y la manda junto con branchId null", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-principal" }
    render(<PurchaseForm onSuccess={vi.fn()} />)
    addOneItemToCart()
    fireEvent.click(screen.getByTestId(`pm-option-${PM_CASH.id}`))

    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "checked")
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    const meta = addPurchaseOperationMock.mock.calls[0][0].meta
    expect(meta.branchId).toBeNull()
    expect(meta.cashSessionId).toBe("session-principal")
  })
})
