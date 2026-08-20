import { describe, it, expect, vi, afterEach } from "vitest"
import { render } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"

// app-timezone-argentina, task 2.2: el default y el `max` del selector de
// fecha deben resolver al día ARGENTINO, no al día UTC del server. Este test
// mockea todas las dependencias de datos/UI pesadas del formulario — lo único
// bajo prueba es el <input type="date"> que el componente renderiza inline.

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ addSaleOperation: vi.fn(), updateSaleOperation: vi.fn() }) }))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: {} }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
// pagos-cableados-restantes (OQ-C/OQ-D): mocks de los hooks nuevos del form
// — sin esto, el import real de use-payment-methods dispara python-client
// (NEXT_PUBLIC_BACKEND_URL no definida en el entorno de test).
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => ({ paymentMethods: [] }) }))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

describe("SaleForm — fecha por defecto (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART defaultea a HOY (día D), no a mañana (día UTC D+1)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun — UTC ya rolleó a 9/jun
    const { container } = render(<SaleForm onSuccess={() => {}} />)
    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe("2026-06-08")
    expect(dateInput.max).toBe("2026-06-08")
  })
})
