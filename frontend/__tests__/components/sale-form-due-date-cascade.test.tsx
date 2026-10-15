import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

// remitos-compra (tanda B, 7.3) — caracterización del bloque «Vencimiento» de la
// venta a crédito al EXTRAER su cascada a `useDueDateCascade`
// (hooks/use-due-date-cascade.ts): el campo se pre-carga con el plazo del cliente
// (o el de la cuenta) contado desde la fecha de la venta, se puede editar y el
// texto de apoyo dice de dónde salió. La lógica de la cascada tiene su propio test
// (use-due-date-cascade.test.ts); acá se prueba que el formulario sigue mostrándola.

let collectionDefaultDays: number | null = null
let clientTermsDays: number | null = null

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({
    clients: [{ id: "client-1", name: "Cliente Test", paymentTermsDays: clientTermsDays }],
    addClient: vi.fn(),
  }),
}))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: vi.fn().mockResolvedValue(undefined), updateSaleOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({
    options,
    onValueChange,
  }: {
    options: Array<{ value: string; label: string }>
    onValueChange: (v: string) => void
  }) => (
    <div data-testid="searchable-select">
      {options.map((o) => (
        <button key={o.value} type="button" data-testid={`client-option-${o.value}`} onClick={() => onValueChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  ),
}))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>
      {children}
      {footerContent}
    </>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({
    paymentMethods: [{ id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true }],
    isLoading: false,
  }),
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: collectionDefaultDays }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: FACTORY_SCALE_SETTINGS, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: { balance: 0 } }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null, isLoading: false }) }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ onChange }: { onChange: (v: string | null) => void }) => (
    <button type="button" data-testid="pick-credit" onClick={() => onChange("pm-credit")}>
      Cuenta corriente
    </button>
  ),
  BankAccountDestinationSelect: () => null,
}))

afterEach(() => {
  vi.clearAllMocks()
  collectionDefaultDays = null
  clientTermsDays = null
})

function openCreditSaleFor() {
  render(<SaleForm onSuccess={vi.fn()} />)
  fireEvent.click(screen.getByTestId("client-option-client-1"))
  fireEvent.click(screen.getByTestId("pick-credit"))
}

function setSaleDate(value: string) {
  const input = document.querySelector('input[type="date"]') as HTMLInputElement
  fireEvent.change(input, { target: { value } })
}

describe("SaleForm — vencimiento de la venta a crédito (cascada extraída)", () => {
  it("con el plazo del cliente, pre-carga fecha + plazo y lo explica", () => {
    clientTermsDays = 20
    openCreditSaleFor()
    setSaleDate("2026-10-10")

    const due = screen.getByLabelText("Vencimiento") as HTMLInputElement
    expect(due.value).toBe("2026-10-30")
    expect(screen.getByText("Resuelto por el plazo del cliente (20 días).")).toBeTruthy()
  })

  it("sin plazo del cliente usa el de la cuenta", () => {
    collectionDefaultDays = 30
    openCreditSaleFor()
    setSaleDate("2026-10-10")

    expect((screen.getByLabelText("Vencimiento") as HTMLInputElement).value).toBe("2026-11-09")
    expect(screen.getByText("Resuelto por el plazo de la cuenta (30 días).")).toBeTruthy()
  })

  it("sin ningún plazo el campo queda vacío y avisa que el cargo nace sin vencimiento", () => {
    openCreditSaleFor()
    setSaleDate("2026-10-10")

    expect((screen.getByLabelText("Vencimiento") as HTMLInputElement).value).toBe("")
    expect(screen.getByText(/Sin plazo configurado: el cargo nace sin vencimiento/)).toBeTruthy()
  })

  it("editarlo lo fija: un cambio de fecha ya no lo pisa y el texto dice que fue elegido", () => {
    clientTermsDays = 20
    openCreditSaleFor()
    setSaleDate("2026-10-10")
    fireEvent.change(screen.getByLabelText("Vencimiento"), { target: { value: "2026-12-01" } })
    setSaleDate("2026-10-12")

    expect((screen.getByLabelText("Vencimiento") as HTMLInputElement).value).toBe("2026-12-01")
    expect(screen.getByText("Vencimiento elegido para esta venta.")).toBeTruthy()
  })

  it("mientras no se toca, sigue a la fecha de la venta", () => {
    clientTermsDays = 20
    openCreditSaleFor()
    setSaleDate("2026-10-10")
    setSaleDate("2026-10-12")

    expect((screen.getByLabelText("Vencimiento") as HTMLInputElement).value).toBe("2026-11-01")
  })
})
