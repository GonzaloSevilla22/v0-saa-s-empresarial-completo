/**
 * Corrección del PR #584 (hallazgo ALTO de la segunda revisión): al editar,
 * las líneas rehidratadas no traían step/minQty y `handleUpdateQty` hacía
 * `Math.max(item.minQty ?? 1, qty)` — bajar 0,45 kg a 0,40 kg lo SUBÍA en
 * silencio a 1 kg. El mínimo y el paso se derivan de la unidad de la línea
 * (o de la base del producto) con las mismas funciones que el alta.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Purchase, UnitOfMeasure } from "@/lib/types"

// edicion-preserva-contexto (F1 §D11): espejo de sale-form-edit-context —
// PurchaseForm prefillea branchId desde editingOperation y lo reenvía en el
// payload de edición; unitId del ítem sobrevive el round-trip. F2 no aplica
// a compra (D6 — sin CAE propio), así que no hay banner/fieldset acá.


const KG: UnitOfMeasure = { id: "unit-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

// productos-categorias-sku: purchase-form monta ProductCategorySelect en el alta
// inline de producto → use-product-categories → python-client (explota sin
// NEXT_PUBLIC_BACKEND_URL) y useOrgRole → react-query real (mockeado acá).
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn(), createProductCategoryMutation: { isPending: false } }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: vi.fn(), updatePurchaseOperation: updatePurchaseOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [KG], unitsById: new Map([[KG.id, KG]]) }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({ value }: { value: string | null }) => (
    <div data-testid="branch-select-value">{value ?? "null"}</div>
  ),
}))
// caja-compras-cobranzas: purchase-form.tsx ahora monta useCashOptin, que
// consulta useBranches/useCashboxes/useCurrentSession directo (no vía
// BranchSelect) — sin mockearlos, la cadena real llega a pythonClient y
// explota por falta de NEXT_PUBLIC_BACKEND_URL en el entorno de test.
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
// review B (FE-1/OQ-5 A): mock informativo (a diferencia de `() => null`)
// para poder verificar prefill + el patrón de "tocado" — value/onChange
// espejo del mock de BranchSelect de arriba.
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({
  CostCenterSelect: ({
    value,
    onChange,
  }: {
    value: string | null
    onChange: (v: string | null) => void
  }) => (
    <div>
      <div data-testid="cost-center-select-value">{value ?? "null"}</div>
      <button type="button" data-testid="cost-center-change" onClick={() => onChange("cc-2")}>
        cambiar
      </button>
      <button type="button" data-testid="cost-center-clear" onClick={() => onChange(null)}>
        limpiar
      </button>
    </div>
  ),
}))
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
// compras-proveedor-cuenta-corriente (D10): mismo motivo — mock explícito, no
// pythonClient real (que revienta sin NEXT_PUBLIC_BACKEND_URL en tests).
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: [], addSupplier: vi.fn() }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({ data: null }),
}))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
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

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "purchase-1",
    date: "2026-08-20",
    productId: "prod-1",
    productName: "Producto Test",
    quantity: 0.45,
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
    isPaymentLocked: false,
    hasAccountCharge: false,
    supplierId: null,
    supplierName: null,
    hasBankMovement: false,
    // caja-compras-cobranzas (D9): campos nuevos requeridos por PurchaseOperation.
    hasCashMovement: false,
    isDeleteBlocked: false,
    costCenterId: null,
    ...overrides,
  }
}

describe("PurchaseForm — editar una línea fraccionaria respeta la unidad", () => {
  afterEach(() => vi.clearAllMocks())

  it("la línea rehidratada en kg expone el mínimo y el paso de la unidad (0.001)", () => {
    render(<PurchaseForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    expect(screen.getByTestId("line-min").textContent).toBe("0.001")
    expect(screen.getByTestId("line-step").textContent).toBe("0.001")
  })

  it("0,45 kg editado a 0,40 kg queda en 0,40 (antes se subía a 1)", async () => {
    render(<PurchaseForm onSuccess={() => {}} editingOperation={makeOperation()} />)
    fireEvent.click(screen.getByRole("button", { name: "poner 0,4" }))
    expect(screen.getByTestId("line-qty").textContent).toBe("0.4")
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))
    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(updatePurchaseOperationMock.mock.calls[0][0].newItems[0].quantity).toBe(0.4)
  })
})
