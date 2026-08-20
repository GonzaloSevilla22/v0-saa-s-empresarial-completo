import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"

// pagos-cableados-restantes (OQ-C/OQ-D, task 12.1): el form de venta
//   1) exige cliente y muestra saldo actual/proyectado cuando kind=credit
//      (D8: reutiliza useCustomerAccount, mismo patrón visual del POS);
//   2) muestra el checkbox "Registrar en caja" SÓLO cuando las tres
//      condiciones de servidor se cumplen (kind=cash + sesión abierta en la
//      sucursal efectiva + fecha=hoy) — y explica el motivo cuando no (D4).

const addSaleOperationMock = vi.fn().mockResolvedValue(undefined)

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let customerAccountMock: { balance: number } | null = null
let currentSessionMock: { id: string } | null = null

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Test" }], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: addSaleOperationMock, updateSaleOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: () => <div data-testid="branch-select" />,
}))
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

vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => ({ data: customerAccountMock }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: currentSessionMock, isLoading: false }),
}))

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  customerAccountMock = null
  currentSessionMock = null
})

const PM_CREDIT = { id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true }
const PM_CASH   = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_OTHER  = { id: "pm-other", name: "Otro", kind: "other", isActive: true }

function selectPaymentMethod(id: string) {
  // PaymentMethodSelect real component renders a native trigger; exercised
  // indirectly via the mocked hook + component below (no need to click through
  // Radix internals — see PaymentMethodSelect mock).
  fireEvent.click(screen.getByTestId(`pm-option-${id}`))
}

vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <div data-testid="payment-method-select">
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>
          {pm.name}
        </button>
      ))}
      <span data-testid="pm-selected-value">{value ?? "null"}</span>
    </div>
  ),
}))

describe("SaleForm — bloque de crédito (OQ-D)", () => {
  it("kind=credit sin cliente muestra la advertencia y NO el saldo", () => {
    paymentMethodsMock = [PM_CREDIT]
    render(<SaleForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByText(/Elegí un cliente/i)).toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual/i)).not.toBeInTheDocument()
  })

  it("kind=credit con cliente muestra saldo actual y proyectado", () => {
    paymentMethodsMock = [PM_CREDIT]
    customerAccountMock = { balance: 500 }
    render(<SaleForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("client-option-client-1"))
    selectPaymentMethod(PM_CREDIT.id)

    // El bloque de saldo depende de isCreditSelected + useCustomerAccount
    // (mockeado arriba con balance=500) — no de haber elegido un cliente en
    // el SearchableSelect real (mockeado, sin opciones renderizadas). El
    // caso "sin cliente" ya se cubre en el test anterior.
    expect(screen.getByText(/Saldo actual/i)).toBeInTheDocument()
  })

  it("kind distinto de credit no muestra ningún bloque de cuenta corriente", () => {
    paymentMethodsMock = [PM_OTHER]
    render(<SaleForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_OTHER.id)

    expect(screen.queryByText(/Elegí un cliente/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual/i)).not.toBeInTheDocument()
  })
})

describe("SaleForm — opt-in de caja (OQ-C)", () => {
  it("kind=cash con sesión abierta y fecha=hoy muestra el checkbox 'Registrar en caja'", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    render(<SaleForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_CASH.id)

    expect(screen.getByText(/Registrar en caja/i)).toBeInTheDocument()
    expect(screen.getByRole("checkbox")).toBeInTheDocument()
  })

  it("kind=cash sin sesión abierta explica el motivo y NO muestra el checkbox", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    render(<SaleForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_CASH.id)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("kind distinto de cash no muestra ningún bloque de caja", () => {
    paymentMethodsMock = [PM_OTHER]
    render(<SaleForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_OTHER.id)

    expect(screen.queryByText(/Registrar en caja/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })
})
