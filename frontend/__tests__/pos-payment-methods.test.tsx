/**
 * PosPage — catálogo de formas de pago (pos-catalogo-pagos, tasks 6.1/6.3/6.5)
 *
 * Mockea todas las dependencias de datos/UI pesadas — mismo patrón que
 * frontend/__tests__/components/sale-form-date-default.test.tsx. Cubre:
 *   (1) el POS renderiza las formas activas del catálogo (no el par
 *       hardcodeado cash/other), preseleccionando 'cash' de menor sort_order;
 *   (2) una cuenta sin formas activas muestra el aviso con enlace y sigue
 *       permitiendo cobrar;
 *   (3) kind='credit' sin cliente deshabilita el cobro y explica por qué;
 *       con cliente, muestra saldo actual y proyectado;
 *   (4) el chip/bloqueo de sesión de caja aparece SOLO cuando el kind
 *       resuelto es 'cash'.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"

const PM_CASH     = { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash" as const, isActive: true, sortOrder: 1, createdAt: "2026-01-01" }
const PM_TRANSFER = { id: "pm-transfer", accountId: "a", name: "Transferencia", kind: "transfer" as const, isActive: true, sortOrder: 2, createdAt: "2026-01-01" }
const PM_CREDIT   = { id: "pm-credit", accountId: "a", name: "Cuenta corriente", kind: "credit" as const, isActive: true, sortOrder: 3, createdAt: "2026-01-01" }

let paymentMethodsMockValue: { paymentMethods: typeof PM_CASH[]; isLoading: boolean } = {
  paymentMethods: [PM_CASH, PM_TRANSFER, PM_CREDIT],
  isLoading: false,
}
let customerAccountMockValue: { data: { balance: number } | null; isLoading: boolean } = {
  data: null,
  isLoading: false,
}
let currentSessionMockValue: { data: { id: string } | null; isLoading: boolean } = {
  data: { id: "sess-1" },
  isLoading: false,
}

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Uno" }] }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Casa Central" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: [{ id: "cb-1" }] }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => currentSessionMockValue,
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/hooks/use-idempotency-key", () => ({
  useIdempotencyKey: () => ({ idempotencyKey: "idem-1", resetIdempotencyKey: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({
  useQuickSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => paymentMethodsMockValue,
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => customerAccountMockValue,
}))
vi.mock("@/components/three/Celebration3D", () => ({ Celebration3D: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, listContent, footerContent }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{listContent}{footerContent}</>
  ),
}))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({ options, onValueChange }: { options: { value: string; label: string }[]; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Consumidor final</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))

import PosPage from "@/app/(dashboard)/ventas/pos/page"

beforeEach(() => {
  paymentMethodsMockValue = { paymentMethods: [PM_CASH, PM_TRANSFER, PM_CREDIT], isLoading: false }
  customerAccountMockValue = { data: null, isLoading: false }
  currentSessionMockValue = { data: { id: "sess-1" }, isLoading: false }
})

describe("PosPage — catálogo de formas de pago", () => {
  it("renderiza las formas activas del catálogo, con Efectivo preseleccionada", () => {
    render(<PosPage />)

    const cashButton = screen.getByRole("button", { name: "Efectivo" })
    expect(screen.getByRole("button", { name: "Transferencia" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Cuenta corriente" })).toBeInTheDocument()
    expect(cashButton).toHaveAttribute("aria-pressed", "true")
  })

  it("no ofrece los dos botones hardcodeados 'Efectivo/Otro' del vocabulario legacy", () => {
    render(<PosPage />)
    expect(screen.queryByRole("button", { name: "Otro / Transferencia" })).not.toBeInTheDocument()
  })

  it("cuenta sin formas de pago activas muestra el aviso con enlace al gestor", () => {
    paymentMethodsMockValue = { paymentMethods: [], isLoading: false }
    render(<PosPage />)

    expect(screen.getByText(/no hay formas de pago activas/i)).toBeInTheDocument()
    const link = screen.getByRole("link", { name: /configurar cat.logo/i })
    expect(link).toHaveAttribute("href", "/configuracion")
    // El cobro sigue habilitado (degradar, no fallar) — el botón no está
    // deshabilitado por falta de catálogo (solo por falta de items, ver form).
    const submit = screen.getByRole("button", { name: /cobrar/i })
    expect(submit).toBeDisabled() // sin items en el carrito, deshabilitado por eso — no por el catálogo vacío
  })

  it("elegir 'Cuenta corriente' sin cliente deshabilita el cobro y explica por qué", () => {
    render(<PosPage />)

    fireEvent.click(screen.getByRole("button", { name: "Cuenta corriente" }))

    expect(screen.getByText(/una venta a cuenta corriente se le carga a alguien/i)).toBeInTheDocument()
    const submit = screen.getByRole("button", { name: /cobrar/i })
    expect(submit).toBeDisabled()
  })

  it("elegir 'Cuenta corriente' con cliente muestra saldo actual y proyectado", () => {
    customerAccountMockValue = { data: { balance: 500 }, isLoading: false }
    render(<PosPage />)

    fireEvent.click(screen.getByRole("button", { name: "Cuenta corriente" }))
    fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: "client-1" } })

    expect(screen.getByText(/saldo actual.*500/i)).toBeInTheDocument()
    expect(screen.getByText(/después de esta venta/i)).toBeInTheDocument()
  })

  it("el chip de sesión de caja se muestra SOLO cuando el kind resuelto es 'cash'", () => {
    render(<PosPage />)
    // Default: Efectivo (cash) preseleccionada → chip de caja visible.
    expect(screen.getByText(/caja abierta/i)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Transferencia" }))
    expect(screen.queryByText(/caja abierta/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/sin caja abierta/i)).not.toBeInTheDocument()
  })

  it("elegir 'Cuenta corriente' oculta el chip de caja y no exige sesión", () => {
    currentSessionMockValue = { data: null, isLoading: false } // sin sesión abierta
    render(<PosPage />)

    fireEvent.click(screen.getByRole("button", { name: "Cuenta corriente" }))

    expect(screen.queryByText(/caja abierta/i)).not.toBeInTheDocument()
  })
})
