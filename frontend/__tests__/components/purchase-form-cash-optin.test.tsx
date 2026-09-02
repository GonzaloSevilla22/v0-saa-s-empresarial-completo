/**
 * PurchaseForm — opt-in de caja (caja-compras-cobranzas D2/D4, task 10.1/
 * 10.2/10.4 RED->GREEN->TRIANGULATE).
 *
 * Espejo de expense-form-payment-effects.test.tsx (tercer consumidor del
 * mismo hook `useCashOptin`, D4): checkbox PRE-MARCADO cuando las tres
 * condiciones se cumplen, motivo visible (nunca oculto en silencio) cuando
 * alguna falla, y el payload de `addPurchaseOperation` lleva `cashSessionId`
 * sólo cuando el usuario lo deja tildado.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { argentinaToday } from "@/lib/date-range"

const addPurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null
const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: addPurchaseOperationMock, updatePurchaseOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
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
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (...args: unknown[]) => useCashboxesMock(...args),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args),
}))

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

function pick(id: string) {
  fireEvent.click(screen.getByTestId(`pm-option-${id}`))
}

function addOneItemToCart() {
  fireEvent.click(screen.getByTestId("product-option-prod-1"))
  fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
}

function setup() {
  useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
  useCurrentSessionMock.mockReturnValue({ data: currentSessionMock, isLoading: false })
  return render(<PurchaseForm onSuccess={vi.fn()} />)
}

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  currentSessionMock = null
})

describe("PurchaseForm — opt-in de caja (D2/D4)", () => {
  it("las tres condiciones cumplidas: el checkbox aparece PRE-MARCADO (alineado con el gasto, no con la venta)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_CASH.id)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    expect(checkbox).toHaveAttribute("data-state", "checked")
    expect(screen.getByText(/Registrar en caja/i)).toBeInTheDocument()
  })

  it("motivo 1 — kind no efectivo: no hay bloque de caja de ninguna clase", () => {
    paymentMethodsMock = [PM_TRANSFER]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_TRANSFER.id)

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/Registrar en caja/i)).not.toBeInTheDocument()
  })

  it("motivo 2 — sin caja abierta: el motivo se muestra, nunca se oculta en silencio", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    setup()
    pick(PM_CASH.id)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("motivo 3 — fecha distinta de hoy: motivo propio, distinto del de caja cerrada", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    const { container } = setup()
    pick(PM_CASH.id)
    expect(screen.getByRole("checkbox")).toBeInTheDocument() // precondición

    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe(argentinaToday())
    fireEvent.change(dateInput, { target: { value: "2020-01-02" } })

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByText(/compra fechada hoy/i)).toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })

  it("el checkbox se puede desmarcar (no es decorativo)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_CASH.id)

    fireEvent.click(screen.getByRole("checkbox"))
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "unchecked")
  })

  it("la edición NO ofrece el bloque de caja (D8: inmutable con caja posteada)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: currentSessionMock })
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={{
          key: "op-1", operationId: "op-1", date: "2026-08-20",
          items: [{ id: "p1", date: "2026-08-20", productId: "prod-1", productName: "X", quantity: 1, unitCost: 10, total: 10, operationId: "op-1" }],
          total: 10, description: "", isGrouped: false, paymentMethodId: PM_CASH.id, branchId: null, unitId: null,
          isPaymentLocked: false, hasAccountCharge: false, hasBankMovement: false,
          hasCashMovement: false, isDeleteBlocked: false,
          supplierId: null, supplierName: null, costCenterId: null,
        }}
      />,
    )

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/Registrar en caja/i)).not.toBeInTheDocument()
  })
})

describe("PurchaseForm — payload del opt-in de caja (D2)", () => {
  it("elegible y tildado: el alta manda el id de la sesión abierta", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    addOneItemToCart()
    pick(PM_CASH.id)
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.cashSessionId).toBe("session-abc12345")
  })

  it("elegible pero DESTILDADO: el alta manda null", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    addOneItemToCart()
    pick(PM_CASH.id)
    fireEvent.click(screen.getByRole("checkbox"))
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.cashSessionId).toBeNull()
  })

  it("NO elegible (sin caja abierta): el alta manda null aunque el kind sea efectivo", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    setup()
    addOneItemToCart()
    pick(PM_CASH.id)
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.cashSessionId).toBeNull()
  })

  it("kind no efectivo: el alta manda null sin ofrecer el opt-in", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    addOneItemToCart()
    pick(PM_TRANSFER.id)
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.cashSessionId).toBeNull()
  })
})
