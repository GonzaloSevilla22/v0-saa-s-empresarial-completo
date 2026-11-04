/**
 * remitos-compra (tanda B, D11, tarea 7.9) — aviso contra la doble suma en el
 * FORMULARIO DE COMPRA.
 *
 * El escenario que justifica el change es "recibo con remito y la factura llega
 * después": "Nueva compra" crea una compra directa, que vuelve a SUMAR el stock. Al
 * elegir un proveedor con remitos de compra pendientes, el formulario avisa y manda
 * a convertirlos desde el remito. Es un AVISO: una compra directa puede ser
 * legítimamente otra mercadería, así que no bloquea el guardado.
 *
 * Invariantes bajo test:
 *  - sin proveedor elegido no hay aviso ni se consulta ningún remito;
 *  - con un proveedor con pendientes, aparece el aviso con el enlace a la pestaña De
 *    compra filtrada por ese proveedor; con uno sin pendientes, no;
 *  - cambiar de proveedor cambia el aviso; limpiar el proveedor lo quita;
 *  - el aviso NO bloquea: confirmar la compra sigue llamando al alta;
 *  - en la EDICIÓN de una compra no hay aviso (no suma stock de nuevo ni se consulta).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Purchase } from "@/lib/types"

const addPurchaseOperationMock = vi.fn().mockResolvedValue(undefined)
const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)
const useDeliveryNotesMock = vi.fn()

let suppliersMock: Array<{ id: string; name: string }> = []
/** Remitos de compra pendientes por proveedor (el mock responde según el filtro). */
let pendingBySupplier: Record<string, number> = {}

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }

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
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
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
    <>
      {children}
      {footerContent}
    </>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({ useSupplierAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    suppliers: suppliersMock,
    addSupplier: vi.fn(),
    isLoading: false,
    isError: false,
  }),
}))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNotes: (filters: { supplierId?: string }) => {
    useDeliveryNotesMock(filters)
    const total = filters.supplierId ? (pendingBySupplier[filters.supplierId] ?? 0) : 0
    return { data: { items: [], total } }
  },
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({
    options,
    onValueChange,
  }: {
    options: Array<{ value: string; label: string }>
    value: string
    onValueChange: (v: string) => void
  }) => (
    <div data-testid="searchable-select">
      {options.map((o) => (
        <button key={o.value} type="button" data-testid={`supplier-option-${o.value}`} onClick={() => onValueChange(o.value)}>
          {o.label}
        </button>
      ))}
      <button type="button" data-testid="supplier-clear" onClick={() => onValueChange("")}>
        limpiar proveedor
      </button>
    </div>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => <div data-testid="payment-method-select" />,
  BankAccountDestinationSelect: () => null,
}))

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "purchase-1", date: "2026-08-20", productId: "prod-1", productName: "Producto Test",
    quantity: 3, unitCost: 50, total: 150, operationId: "op-1",
    ...overrides,
  }
}

function makeOperation(overrides: Partial<PurchaseOperation> = {}): PurchaseOperation {
  return {
    key: "op-1", operationId: "op-1", date: "2026-08-20", items: [makePurchase()], total: 150,
    description: "", isGrouped: false, paymentMethodId: null, branchId: null, unitId: null,
    isPaymentLocked: false, hasAccountCharge: false, hasBankMovement: false,
    hasCashMovement: false, isDeleteBlocked: false,
    supplierId: null, supplierName: null, costCenterId: null,
    ...overrides,
  }
}

afterEach(() => {
  vi.clearAllMocks()
  suppliersMock = []
  pendingBySupplier = {}
})

describe("PurchaseForm — aviso contra la doble suma (remitos de compra pendientes)", () => {
  it("sin proveedor elegido no hay aviso y no se consulta ningún remito", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    pendingBySupplier = { "sup-1": 2 }
    render(<PurchaseForm onSuccess={vi.fn()} />)

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
    expect(useDeliveryNotesMock).not.toHaveBeenCalled()
  })

  it("al elegir un proveedor con remitos pendientes avisa y enlaza a la pestaña De compra de ese proveedor", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    pendingBySupplier = { "sup-1": 2 }
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))

    const note = screen.getByRole("note")
    expect(note).toHaveTextContent(/este proveedor tiene 2 remitos de compra pendientes/i)
    expect(note).toHaveTextContent(/convertilo desde el remito para no sumar el stock dos veces/i)
    expect(screen.getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?sentido=compra&estado=pendientes&proveedor=sup-1",
    )
    expect(useDeliveryNotesMock).toHaveBeenCalledWith(
      expect.objectContaining({ direction: "purchase", status: "issued", supplierId: "sup-1" }),
    )
  })

  it("un proveedor SIN remitos pendientes no muestra aviso", () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Mendoza" },
      { id: "sup-2", name: "Mayorista Sur" },
    ]
    pendingBySupplier = { "sup-1": 2 }
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-2"))

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
  })

  it("cambiar de proveedor cambia el aviso, y limpiar el proveedor lo quita", () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Mendoza" },
      { id: "sup-2", name: "Mayorista Sur" },
    ]
    pendingBySupplier = { "sup-1": 2, "sup-2": 1 }
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    expect(screen.getByRole("note")).toHaveTextContent(/2 remitos de compra pendientes/i)

    fireEvent.click(screen.getByTestId("supplier-option-sup-2"))
    expect(screen.getByRole("note")).toHaveTextContent(/1 remito de compra pendiente\./i)
    expect(screen.getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?sentido=compra&estado=pendientes&proveedor=sup-2",
    )

    fireEvent.click(screen.getByTestId("supplier-clear"))
    expect(screen.queryByRole("note")).not.toBeInTheDocument()
  })

  it("el aviso NO bloquea el guardado: confirmar la compra sigue llamando al alta", async () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    pendingBySupplier = { "sup-1": 2 }
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    expect(screen.getByRole("note")).toBeInTheDocument()
    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    const confirm = screen.getByRole("button", { name: /confirmar compra/i })
    expect(confirm).toBeEnabled()
    fireEvent.click(confirm)

    await vi.waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    expect(addPurchaseOperationMock.mock.calls[0][0].meta.supplierId).toBe("sup-1")
  })

  it("en la EDICIÓN de una compra no hay aviso ni se consulta ningún remito", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    pendingBySupplier = { "sup-1": 2 }
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })} />)

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
    expect(useDeliveryNotesMock).not.toHaveBeenCalled()
  })
})
