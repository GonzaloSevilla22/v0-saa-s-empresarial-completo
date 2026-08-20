import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Purchase } from "@/lib/types"

// edicion-preserva-contexto (F1 §D11): espejo de sale-form-edit-context —
// PurchaseForm prefillea branchId desde editingOperation y lo reenvía en el
// payload de edición; unitId del ítem sobrevive el round-trip. F2 no aplica
// a compra (D6 — sin CAE propio), así que no hay banner/fieldset acá.

const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: vi.fn(), updatePurchaseOperation: updatePurchaseOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({ value }: { value: string | null }) => (
    <div data-testid="branch-select-value">{value ?? "null"}</div>
  ),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  // pos-banco-movimientos (D9): mock no-op, no ejercitado por este test
  // (edición no monta el selector de cuenta bancaria — D8).
  BankAccountDestinationSelect: () => null,
}))
// pos-banco-movimientos: PurchaseForm ahora llama a usePaymentMethods()
// directo (para resolver el kind de la forma elegida) — mock explícito en
// vez del useQuery real, que el mock estrecho de @tanstack/react-query de
// arriba no provee.
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children,
    footerContent,
  }: {
    children: React.ReactNode
    footerContent?: React.ReactNode
  }) => (
    <>
      {children}
      {footerContent}
    </>
  ),
}))

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "purchase-1",
    date: "2026-08-20",
    productId: "prod-1",
    productName: "Producto Test",
    quantity: 3,
    unitCost: 50,
    total: 150,
    operationId: "op-1",
    unitId: "unit-kg",
    branchId: "branch-b",
    paymentMethodId: null,
    ...overrides,
  }
}

function makeOperation(overrides: Partial<PurchaseOperation> = {}): PurchaseOperation {
  const item = makePurchase()
  return {
    key: "op-1",
    operationId: "op-1",
    date: "2026-08-20",
    items: [item],
    total: 150,
    description: "",
    isGrouped: false,
    paymentMethodId: null,
    branchId: "branch-b",
    unitId: "unit-kg",
    ...overrides,
  }
}

describe("PurchaseForm — edición preserva contexto (branch/unit)", () => {
  afterEach(() => {
    vi.clearAllMocks()
  })

  it("prefillea branchId desde editingOperation en vez de arrancar en null", () => {
    render(<PurchaseForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    expect(screen.getByTestId("branch-select-value").textContent).toBe("branch-b")
  })

  it("el payload de edición incluye branchId vigente", async () => {
    render(<PurchaseForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    const submitButton = screen.getByRole("button", { name: /Guardar cambios/i })
    fireEvent.click(submitButton)

    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = updatePurchaseOperationMock.mock.calls[0][0]
    expect(call.meta.branchId).toBe("branch-b")
  })

  it("el ítem del carrito conserva unitId al editar", async () => {
    render(<PurchaseForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    const submitButton = screen.getByRole("button", { name: /Guardar cambios/i })
    fireEvent.click(submitButton)

    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = updatePurchaseOperationMock.mock.calls[0][0]
    expect(call.newItems[0].unitId).toBe("unit-kg")
  })
})
