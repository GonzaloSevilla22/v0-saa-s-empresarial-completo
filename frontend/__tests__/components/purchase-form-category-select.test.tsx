/**
 * productos-categorias-sku — PurchaseForm: el alta inline de producto ofrece
 * el MISMO catálogo por el MISMO componente selector (task 12.2 RED → 12.3).
 *
 * Mocks espejo de purchase-form-supplier.test.tsx.
 */

import React from "react"
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { PurchaseForm } from "@/components/forms/purchase-form"

const addProductMock = vi.fn()
const addPurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT], addProduct: addProductMock }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: addPurchaseOperationMock, updatePurchaseOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => <div data-testid="product-picker" /> }))
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
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }) }))
vi.mock("@/hooks/data/use-supplier-account", () => ({ useSupplierAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: [], addSupplier: vi.fn(), isLoading: false, isError: false }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => <div data-testid="searchable-select" /> }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => <div data-testid="payment-method-select" />,
  BankAccountDestinationSelect: () => null,
}))
// El MISMO componente selector que el formulario de producto — mockeado
// liviano (su contrato tiene tests propios en ProductCategorySelect.test.tsx).
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select
      data-testid="category-select"
      aria-label="Categoría"
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value || null)}
    >
      <option value="">Categoría</option>
      <option value="cat-ropa">Ropa</option>
      <option value="cat-ferre">Ferretería</option>
    </select>
  ),
}))

afterEach(() => {
  vi.clearAllMocks()
})

describe("PurchaseForm — alta inline de producto con el catálogo de categorías (12.2/12.3)", () => {
  it("el alta inline ofrece el catálogo por ProductCategorySelect y envía categoryId", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByRole("button", { name: /nuevo producto/i }))
    expect(screen.getByTestId("category-select")).toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText(/nombre del producto/i), { target: { value: "Tornillos" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ferre" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    expect(addProductMock.mock.calls[0][0]).toEqual(
      expect.objectContaining({ name: "Tornillos", categoryId: "cat-ferre", isVariant: false }),
    )
  })

  it("sin categoría elegida no crea el producto", async () => {
    const { toast } = await import("sonner")
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByRole("button", { name: /nuevo producto/i }))
    fireEvent.change(screen.getByPlaceholderText(/nombre del producto/i), { target: { value: "Tornillos" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    expect(addProductMock).not.toHaveBeenCalled()
    expect(toast.error).toHaveBeenCalledWith(expect.stringMatching(/categoría/i))
  })
})
