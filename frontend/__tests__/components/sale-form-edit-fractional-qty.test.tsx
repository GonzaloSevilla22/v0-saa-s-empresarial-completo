/**
 * Corrección del PR #584 (hallazgo ALTO de la segunda revisión): al editar,
 * las líneas rehidratadas no traían step/minQty y `handleUpdateQty` hacía
 * `Math.max(item.minQty ?? 1, qty)` — bajar 0,45 kg a 0,40 kg lo SUBÍA en
 * silencio a 1 kg. El mínimo y el paso se derivan de la unidad de la línea
 * (o de la base del producto) con las mismas funciones que el alta.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale, UnitOfMeasure } from "@/lib/types"

// edicion-preserva-contexto (F1/F2 §D11): el form de edición
//   1) prefillea branchId/canal desde editingOperation (antes arrancaba en
//      null ignorándolo — el payload de edición ni siquiera los incluía),
//   2) los reenvía siempre en el payload de edición (mismo criterio que
//      paymentMethodId — D3/D11),
//   3) se abre en solo lectura con un banner cuando editingOperation.isFiscallyLocked
//      es true (F2), sin llegar a intentar el submit bloqueado por el backend.


const KG: UnitOfMeasure = { id: "unit-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const updateSaleOperationMock = vi.fn().mockResolvedValue({
  ok: true,
  operation_id: "op-1",
  voided_fiscal_document: null,
})

// venta-editable-sin-cae: los dos estados fiscales que importan en el form.
// `isFiscallyLocked` y `fiscal` los deriva el MISMO predicado del servidor, así
// que un fixture con uno y sin el otro no existe en producción.
const AUTHORIZED_FISCAL = {
  documentId: "fd-authorized",
  status: "authorized" as const,
  label: "0003-00000004",
  submittedToArca: true,
  frozen: false,
  voidable: false,
}
const PENDING_VOIDABLE_FISCAL = {
  documentId: "fd-pending",
  status: "pending_cae" as const,
  label: "0003-00000005",
  submittedToArca: false,
  frozen: false,
  voidable: true,
}

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
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [KG], unitsById: new Map([[KG.id, KG]]) }),
}))
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
vi.mock("@/components/shared/cart-item-list", () => ({
  CartItemList: ({
    items,
    onUpdateQty,
  }: {
    items: { id: string; quantity: number; minQty?: number; step?: number }[]
    onUpdateQty: (id: string, qty: number) => void
  }) => (
    <ul>
      {items.map((it) => (
        <li key={it.id}>
          <span data-testid="line-qty">{it.quantity}</span>
          <span data-testid="line-min">{String(it.minQty)}</span>
          <span data-testid="line-step">{String(it.step)}</span>
          <button type="button" onClick={() => onUpdateQty(it.id, 0.4)}>poner 0,4</button>
        </li>
      ))}
    </ul>
  ),
}))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
// A diferencia de sale-form-date-default.test.tsx, este mock SÍ renderiza
// footerContent (necesitamos el botón submit real para ejercitar el submit).
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children,
    listContent,
    footerContent,
  }: {
    children: React.ReactNode
    listContent?: React.ReactNode
    footerContent?: React.ReactNode
  }) => (
    <>
      {children}
      {listContent}
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
    quantity: 0.45,
    unitPrice: 100,
    total: 200,
    currency: "ARS",
    operationId: "op-1",
    unitId: "unit-kg",
    branchId: "branch-b",
    canal: "instagram",
    paymentMethodId: null,
    isFiscallyLocked: false,
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
    isFiscallyLocked: false,
    fiscal: null,
    isPaymentLocked: false,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false,
    ...overrides,
  }
}

describe("SaleForm — editar una línea fraccionaria respeta la unidad", () => {
  afterEach(() => vi.clearAllMocks())

  it("la línea rehidratada en kg expone el mínimo y el paso de la unidad (0.001)", () => {
    render(<SaleForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    expect(screen.getByTestId("line-min").textContent).toBe("0.001")
    expect(screen.getByTestId("line-step").textContent).toBe("0.001")
  })

  it("0,45 kg editado a 0,40 kg queda en 0,40 (antes se subía a 1)", async () => {
    render(<SaleForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    fireEvent.click(screen.getByRole("button", { name: "poner 0,4" }))
    expect(screen.getByTestId("line-qty").textContent).toBe("0.4")
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))
    await vi.waitFor(() => expect(updateSaleOperationMock).toHaveBeenCalledTimes(1))
    expect(updateSaleOperationMock.mock.calls[0][0].newItems[0].quantity).toBe(0.4)
  })
  it("triangulación: una línea sin unidad (discreta) sigue sin bajar de 1", () => {
    const op = makeOperation({ unitId: undefined, items: [makeSale({ unitId: undefined, quantity: 3 })] })
    render(<SaleForm onSuccess={() => {}} editingOperation={op} />)
    expect(screen.getByTestId("line-min").textContent).toBe("1")
    fireEvent.click(screen.getByRole("button", { name: "poner 0,4" }))
    expect(screen.getByTestId("line-qty").textContent).toBe("1")
  })
})
