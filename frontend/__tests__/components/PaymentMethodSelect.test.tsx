/**
 * PaymentMethodSelect — component tests (metodos-pago-operaciones, task 5.1).
 *
 * Radix Select no abre bien en jsdom (Portal + pointer capture), así que se
 * prueba lo observable sin abrir el dropdown: el trigger muestra el
 * placeholder "Sin especificar" cuando value=null, y el texto de apoyo D8
 * aparece/desaparece según el kind de la forma de pago seleccionada.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { PaymentMethodSelect } from "@/components/payment-methods/PaymentMethodSelect"
import type { PaymentMethod } from "@/lib/types"

const METHODS: PaymentMethod[] = [
  { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash", isActive: true, sortOrder: 1, createdAt: "2026-08-19T00:00:00Z", bankAccountId: null },
  { id: "pm-credit", accountId: "a", name: "Cuenta corriente", kind: "credit", isActive: true, sortOrder: 5, createdAt: "2026-08-19T00:00:00Z", bankAccountId: null },
  { id: "pm-transfer", accountId: "a", name: "Transferencia bancaria", kind: "transfer", isActive: true, sortOrder: 2, createdAt: "2026-08-19T00:00:00Z", bankAccountId: null },
]

const usePaymentMethodsMock = vi.fn()
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: (...args: unknown[]) => usePaymentMethodsMock(...args),
}))

// pos-banco-movimientos (D9): el módulo ahora también exporta
// BankAccountDestinationSelect, que importa useBankAccounts a nivel de
// módulo — sin mockearlo, el import real de use-bank-accounts.ts dispara el
// throw de arranque de python-client.ts (NEXT_PUBLIC_BACKEND_URL no
// definida en el entorno de CI). Ninguno de estos tests ejercita el
// selector de cuenta bancaria; sin cuentas por default alcanza.
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
}))

describe("PaymentMethodSelect", () => {
  it("muestra 'Sin especificar' cuando no hay valor seleccionado", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} />)

    expect(screen.getByText("Sin especificar")).toBeInTheDocument()
  })

  it("no muestra el texto de apoyo D8 cuando el valor es null", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} />)

    expect(screen.queryByText(/cuenta corriente del cliente/)).not.toBeInTheDocument()
    expect(screen.queryByText(/sesión de caja/)).not.toBeInTheDocument()
  })

  it("pagos-cableados-restantes (OQ-D): el texto de apoyo de 'credit' en venta declara que SÍ carga la cuenta corriente del cliente", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="sale" />)

    expect(screen.getByText(/carga la venta a la cuenta corriente del cliente al confirmarla/)).toBeInTheDocument()
  })

  it("D8: el texto de apoyo de 'credit' para compras menciona al proveedor, no al cliente", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="purchase" />)

    expect(screen.getByText(/no genera un cargo en la cuenta corriente del proveedor/)).toBeInTheDocument()
  })

  it("pos-catalogo-pagos D5: el texto de apoyo de 'cash' en venta nombra al POS como el camino automático", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="sale" />)

    expect(screen.getByText(/registra el movimiento de caja automáticamente/i)).toBeInTheDocument()
  })

  it("pagos-cableados-restantes (OQ-C): el texto de apoyo de 'cash' en venta menciona el opt-in del formulario y su condición", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="sale" />)

    expect(screen.getByText(/Registrar en caja/)).toBeInTheDocument()
    expect(screen.getByText(/sesión abierta hoy en la sucursal/i)).toBeInTheDocument()
  })

  it("pos-catalogo-pagos D5: el texto de apoyo de 'cash' en venta enlaza a /ventas/pos", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="sale" />)

    const link = screen.getByRole("link", { name: "POS" })
    expect(link).toHaveAttribute("href", "/ventas/pos")
  })

  it("pagos-cableados-restantes (OQ-E): el texto de apoyo de 'cash' en compra aclara que NO mueve caja (alcance recortado)", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="purchase" />)

    expect(screen.getByText(/No genera ningún movimiento de caja/i)).toBeInTheDocument()
  })

  it("no muestra texto de apoyo para 'transfer' (sin efecto declarado que aclarar)", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-transfer" onChange={vi.fn()} />)

    expect(screen.queryByText(/cuenta corriente/)).not.toBeInTheDocument()
    expect(screen.queryByText(/sesión de caja/)).not.toBeInTheDocument()
  })

  it("showSupportText=false suprime el texto de apoyo incluso con kind=credit (uso como filtro)", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} showSupportText={false} />)

    expect(screen.queryByText(/cuenta corriente del cliente/)).not.toBeInTheDocument()
  })

  it("muestra el label por defecto 'Forma de pago (opcional)' salvo que se oculte", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} />)

    expect(screen.getByText("Forma de pago")).toBeInTheDocument()
  })

  it("showLabel=false oculta el label", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} showLabel={false} />)

    expect(screen.queryByText("Forma de pago")).not.toBeInTheDocument()
  })
})
