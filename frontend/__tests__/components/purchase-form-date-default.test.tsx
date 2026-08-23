import { describe, it, expect, vi, afterEach } from "vitest"
import { render } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"

// app-timezone-argentina, task 2.3: mismo default/`max` de fecha que
// SaleForm, ahora en PurchaseForm.

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({ usePurchases: () => ({ addPurchaseOperation: vi.fn(), updatePurchaseOperation: vi.fn() }) }))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: {} }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
// pos-banco-movimientos: ver comentario espejo en purchase-form-edit-context.test.tsx.
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
// compras-proveedor-cuenta-corriente (D10): PurchaseForm ahora llama a
// useSuppliers()/useSupplierAccount() directo — mock explícito para no
// disparar el pythonClient real (que revienta sin NEXT_PUBLIC_BACKEND_URL en
// este entorno de test).
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: [], addSupplier: vi.fn() }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({ data: null }),
}))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

describe("PurchaseForm — fecha por defecto (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART defaultea a HOY (día D), no a mañana (día UTC D+1)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    const { container } = render(<PurchaseForm onSuccess={() => {}} />)
    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe("2026-06-08")
    expect(dateInput.max).toBe("2026-06-08")
  })
})
