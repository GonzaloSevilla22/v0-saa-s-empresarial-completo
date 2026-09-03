import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"

// edicion-preserva-contexto (F1/F2 §D11): el form de edición
//   1) prefillea branchId/canal desde editingOperation (antes arrancaba en
//      null ignorándolo — el payload de edición ni siquiera los incluía),
//   2) los reenvía siempre en el payload de edición (mismo criterio que
//      paymentMethodId — D3/D11),
//   3) se abre en solo lectura con un banner cuando editingOperation.isInvoiced
//      es true (F2), sin llegar a intentar el submit bloqueado por el backend.

const updateSaleOperationMock = vi.fn().mockResolvedValue(undefined)

// sucursal-guard-vaciado-auditoria (G3, task 7.5): SaleForm ahora usa
// useRouter() de next/navigation para el botón "Transferir stock" del toast
// de error — sin este mock, render() explota con "invariant expected app
// router to be mounted".
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: vi.fn(), updateSaleOperation: updateSaleOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({
  // Mock mínimo que expone el `value` recibido para poder aserirlo — el
  // widget real no importa acá, lo que importa es qué valor le llega.
  BranchSelect: ({ value }: { value: string | null }) => (
    <div data-testid="branch-select-value">{value ?? "null"}</div>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  // pos-banco-movimientos (D9): mock no-op — este archivo sólo ejercita
  // isEdit=true (donde BankAccountDestinationSelect no se monta, D8), pero
  // se exporta igual para no dejar un import roto latente si algún test
  // futuro cubre el modo alta.
  BankAccountDestinationSelect: () => null,
}))
// pagos-cableados-restantes (OQ-C/OQ-D): mocks de los hooks nuevos del form
// — sin esto, el import real de use-payment-methods dispara python-client
// (NEXT_PUBLIC_BACKEND_URL no definida en el entorno de test).
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => ({ paymentMethods: [] }) }))
// cobranzas-vencimientos: el form consulta el plazo por defecto de la cuenta
// para pre-cargar el vencimiento — sin mock, el hook real importa
// python-client, que tira al importar sin NEXT_PUBLIC_BACKEND_URL.
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))

vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
// A diferencia de sale-form-date-default.test.tsx, este mock SÍ renderiza
// footerContent (necesitamos el botón submit real para ejercitar el submit).
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

function makeSale(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "sale-1",
    date: "2026-08-20",
    productId: "prod-1",
    productName: "Producto Test",
    clientId: "client-1",
    clientName: "Cliente Test",
    quantity: 2,
    unitPrice: 100,
    total: 200,
    currency: "ARS",
    operationId: "op-1",
    unitId: "unit-kg",
    branchId: "branch-b",
    canal: "instagram",
    paymentMethodId: null,
    isInvoiced: false,
    ...overrides,
  }
}

function makeOperation(overrides: Partial<SaleOperation> = {}): SaleOperation {
  const item = makeSale()
  return {
    key: "op-1",
    operationId: "op-1",
    date: "2026-08-20",
    clientId: "client-1",
    clientName: "Cliente Test",
    currency: "ARS",
    items: [item],
    total: 200,
    isGrouped: false,
    paymentMethodId: null,
    branchId: "branch-b",
    canal: "instagram",
    unitId: "unit-kg",
    isInvoiced: false,
    isPaymentLocked: false,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false,
    ...overrides,
  }
}

describe("SaleForm — edición preserva contexto (branch/canal/unit + bloqueo fiscal)", () => {
  afterEach(() => {
    vi.clearAllMocks()
  })

  it("prefillea branchId desde editingOperation en vez de arrancar en null", () => {
    render(<SaleForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    expect(screen.getByTestId("branch-select-value").textContent).toBe("branch-b")
  })

  it("el payload de edición incluye branchId y canal vigentes (no se omiten)", async () => {
    render(<SaleForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    const submitButton = screen.getByRole("button", { name: /Guardar cambios/i })
    fireEvent.click(submitButton)

    await vi.waitFor(() => expect(updateSaleOperationMock).toHaveBeenCalledTimes(1))
    const call = updateSaleOperationMock.mock.calls[0][0]
    expect(call.meta.branchId).toBe("branch-b")
    expect(call.meta.canal).toBe("instagram")
  })

  it("el ítem del carrito conserva unitId al editar (antes se perdía — la línea nacía con unit_id NULL)", async () => {
    render(<SaleForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    const submitButton = screen.getByRole("button", { name: /Guardar cambios/i })
    fireEvent.click(submitButton)

    await vi.waitFor(() => expect(updateSaleOperationMock).toHaveBeenCalledTimes(1))
    const call = updateSaleOperationMock.mock.calls[0][0]
    expect(call.newItems[0].unitId).toBe("unit-kg")
  })

  it("sin isInvoiced, el form NO muestra el banner de bloqueo fiscal y el fieldset queda habilitado", () => {
    const { container } = render(
      <SaleForm onSuccess={() => {}} editingOperation={makeOperation({ isInvoiced: false })} />,
    )
    expect(screen.queryByRole("status")).toBeNull()
    const fieldset = container.querySelector("fieldset")
    expect(fieldset?.disabled).toBe(false)
  })

  it("F2: con isInvoiced=true, el form muestra el banner de bloqueo y deshabilita el fieldset y el submit", () => {
    const { container } = render(
      <SaleForm onSuccess={() => {}} editingOperation={makeOperation({ isInvoiced: true })} />,
    )
    const banner = screen.getByRole("status")
    expect(banner.textContent).toMatch(/comprobante fiscal emitido/i)
    expect(banner.textContent).toMatch(/nota de crédito/i)

    const fieldset = container.querySelector("fieldset")
    expect(fieldset?.disabled).toBe(true)

    const submitButton = screen.getByRole("button", { name: /No editable/i })
    expect(submitButton).toBeDisabled()
    expect(submitButton.getAttribute("aria-describedby")).toBe(banner.id)
  })

  it("F2: un submit programático sobre una operación facturada no llama a updateSaleOperation (defensa en profundidad)", async () => {
    const { container } = render(
      <SaleForm onSuccess={() => {}} editingOperation={makeOperation({ isInvoiced: true })} />,
    )
    const form = container.querySelector("form") as HTMLFormElement
    fireEvent.submit(form)
    await new Promise((r) => setTimeout(r, 0))
    expect(updateSaleOperationMock).not.toHaveBeenCalled()
  })
})
