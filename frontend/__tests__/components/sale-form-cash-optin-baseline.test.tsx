/**
 * SaleForm — comportamiento VIGENTE del opt-in de caja (gastos-forma-pago,
 * task 8.4).
 *
 * 🛑 Este archivo se escribe ANTES de extraer `useCashOptin` de
 * `sale-form.tsx`. El formulario de venta está en producción y mueve caja:
 * la extracción tiene que ser una refactorización pura, y la única forma de
 * probarlo es fijar antes el comportamiento observable y exigir que estas
 * aserciones sobrevivan **sin cambiar una línea** (task 8.5).
 *
 * Lo que fija, y que `sale-form-payment-effects.test.tsx` NO cubría:
 *   · la TERCERA condición (fecha = hoy), que ese archivo no ejercita;
 *   · que el checkbox nace DESMARCADO en venta — la asimetría deliberada con
 *     el gasto, que nace pre-marcado (D1 / OQ-1). Si la extracción trajera
 *     el default del gasto al formulario de venta, 223 operaciones
 *     retroactivas se convertirían en diferencias de arqueo;
 *   · que los hooks de caja no se consultan mientras el kind no es efectivo
 *     (el `isCashSelected ? … : null` de los dos argumentos) — detalle que
 *     una extracción descuidada pierde y que sólo se ve en los argumentos
 *     con los que se llama a los hooks.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"
import { argentinaToday } from "@/lib/date-range"

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null

const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: vi.fn(), updateSaleOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{footerContent}</>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
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

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

function setup() {
  useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
  useCurrentSessionMock.mockReturnValue({ data: currentSessionMock, isLoading: false })
  return render(<SaleForm onSuccess={vi.fn()} />)
}

function pick(id: string) {
  fireEvent.click(screen.getByTestId(`pm-option-${id}`))
}

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  currentSessionMock = null
})

describe("SaleForm — opt-in de caja vigente (baseline previo a extraer useCashOptin)", () => {
  it("condición 1+2+3 cumplidas: aparece el checkbox y nace DESMARCADO (asimetría con el gasto)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_CASH.id)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    // El estado inicial es la mitad del contrato: `pagos-cableados-restantes`
    // D4 lo dejó desmarcado a propósito.
    expect(checkbox).toHaveAttribute("data-state", "unchecked")
    expect(screen.getByText(/Registrar en caja/i)).toBeInTheDocument()
  })

  it("el checkbox se puede marcar y desmarcar (no es decorativo)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_CASH.id)

    const checkbox = screen.getByRole("checkbox")
    fireEvent.click(checkbox)
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "checked")
    fireEvent.click(screen.getByRole("checkbox"))
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "unchecked")
  })

  it("condición 2 incumplida (sin sesión abierta): motivo visible, sin checkbox — nunca oculto en silencio", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    setup()
    pick(PM_CASH.id)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("condición 3 incumplida (fecha anterior a hoy): motivo propio, distinto del de caja cerrada", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    const { container } = setup()
    pick(PM_CASH.id)
    // Precondición: con la fecha de hoy el checkbox SÍ está — si no, el caso
    // pasaría por la razón equivocada.
    expect(screen.getByRole("checkbox")).toBeInTheDocument()

    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe(argentinaToday())
    fireEvent.change(dateInput, { target: { value: "2020-01-02" } })

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByText(/fechada hoy/i)).toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })

  it("condición 1 incumplida (kind no efectivo): no hay bloque de caja de ninguna clase", () => {
    paymentMethodsMock = [PM_TRANSFER]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_TRANSFER.id)

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/Registrar en caja/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })

  it("mientras el kind no es efectivo, NO consulta cajas ni sesión (los dos hooks reciben null)", () => {
    paymentMethodsMock = [PM_TRANSFER]
    setup()
    pick(PM_TRANSFER.id)

    expect(useCashboxesMock).toHaveBeenCalledWith(null)
    expect(useCurrentSessionMock).toHaveBeenCalledWith(null)
    expect(useCashboxesMock).not.toHaveBeenCalledWith("branch-1")
  })

  it("con kind efectivo consulta la sucursal EFECTIVA y la caja resuelta", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    setup()
    pick(PM_CASH.id)

    // La sucursal efectiva es la primera activa cuando el form no eligió una
    // (mismo fallback que c26_default_branch en la RPC).
    expect(useCashboxesMock).toHaveBeenCalledWith("branch-1")
    expect(useCurrentSessionMock).toHaveBeenCalledWith("cashbox-1")
  })
})
