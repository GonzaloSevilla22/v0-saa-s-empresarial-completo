/**
 * SaleForm — opt-in de caja mientras la sesión CARGA (fix `caja-optin-carga`).
 *
 * En la venta el checkbox nace DESMARCADO y sólo aparece con la sesión resuelta, así
 * que acá no hay pérdida silenciosa como en compra/gasto/cobro (que nacen
 * pre-marcados): lo que se fija es la coherencia de la familia — mientras se
 * averigua dónde está la caja, el formulario avisa «Verificando la caja…» y no deja
 * confirmar una venta en efectivo; con la sesión resuelta (haya o no) se habilita.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"
import type { Product } from "@/lib/types"

const addSaleOperationMock = vi.fn().mockResolvedValue({ ok: true })

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

const REMERA: Product = {
  id: "p-remera", name: "Remera", category: "Ropa", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked",
}

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [REMERA], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Uno" }], addClient: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: addSaleOperationMock, updateSaleOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <button type="button" onClick={() => onValueChange("p-remera")}>elegir Remera</button>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({ options, onValueChange }: { options: { value: string; label: string }[]; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Consumidor final</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{footerContent}</>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: FACTORY_SCALE_SETTINGS, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }], isLoading: false }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (...args: unknown[]) => useCashboxesMock(...args),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ onChange }: { onChange: (v: string | null) => void }) => (
    <div>
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>
          {pm.name}
        </button>
      ))}
    </div>
  ),
  BankAccountDestinationSelect: () => null,
}))

const { SaleForm } = await import("@/components/forms/sale-form")

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

function mockCashLoading() {
  useCashboxesMock.mockReturnValue({ data: undefined, isLoading: true })
  useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: false })
}

function mockCashResolved(session: { id: string } | null) {
  useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
  useCurrentSessionMock.mockReturnValue({ data: session, isLoading: false })
}

function renderWithOneItem() {
  const view = render(<SaleForm onSuccess={vi.fn()} />)
  fireEvent.click(screen.getByRole("button", { name: "elegir Remera" }))
  fireEvent.click(screen.getByRole("button", { name: /Agregar al carrito/i }))
  fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: "client-1" } })
  return view
}

const confirmButton = () => screen.getByRole("button", { name: /confirmar venta/i })

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
})

describe("SaleForm — caja cargando (caja-optin-carga)", () => {
  it("efectivo con la caja cargando: avisa «Verificando la caja…» y NO deja confirmar", () => {
    paymentMethodsMock = [PM_CASH]
    mockCashLoading()
    renderWithOneItem()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    expect(screen.getByRole("status")).toHaveTextContent("Verificando la caja…")
    expect(confirmButton()).toBeDisabled()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })

  it("aunque el submit llegue igual (Enter), NO se registra la venta mientras carga", async () => {
    paymentMethodsMock = [PM_CASH]
    mockCashLoading()
    const { container } = renderWithOneItem()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    fireEvent.submit(container.querySelector("form") as HTMLFormElement)

    await new Promise((r) => setTimeout(r, 50))
    expect(addSaleOperationMock).not.toHaveBeenCalled()
  })

  it("al resolver CON sesión: se habilita; el checkbox nace DESMARCADO (asimetría de la venta) y tildado manda la sesión", async () => {
    paymentMethodsMock = [PM_CASH]
    mockCashLoading()
    const { rerender } = renderWithOneItem()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    expect(confirmButton()).toBeDisabled()

    mockCashResolved({ id: "session-resuelta-1" })
    rerender(<SaleForm onSuccess={vi.fn()} />)

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "unchecked")
    expect(confirmButton()).toBeEnabled()
    fireEvent.click(screen.getByRole("checkbox"))
    fireEvent.click(confirmButton())
    await waitFor(() => expect(addSaleOperationMock).toHaveBeenCalledTimes(1))
    expect(addSaleOperationMock.mock.calls[0][0].meta.cashSessionId).toBe("session-resuelta-1")
  })

  it("al resolver SIN sesión: se habilita (no bloquea para siempre) y la venta sale sin caja", async () => {
    paymentMethodsMock = [PM_CASH]
    mockCashLoading()
    const { rerender } = renderWithOneItem()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    expect(confirmButton()).toBeDisabled()

    mockCashResolved(null)
    rerender(<SaleForm onSuccess={vi.fn()} />)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(confirmButton()).toBeEnabled()
    fireEvent.click(confirmButton())
    await waitFor(() => expect(addSaleOperationMock).toHaveBeenCalledTimes(1))
    expect(addSaleOperationMock.mock.calls[0][0].meta.cashSessionId).toBeNull()
  })

  it("forma de pago que no es efectivo: no hay espera de caja", () => {
    paymentMethodsMock = [PM_TRANSFER]
    mockCashLoading()
    renderWithOneItem()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))

    expect(screen.queryByRole("status")).not.toBeInTheDocument()
    expect(confirmButton()).toBeEnabled()
  })
})
