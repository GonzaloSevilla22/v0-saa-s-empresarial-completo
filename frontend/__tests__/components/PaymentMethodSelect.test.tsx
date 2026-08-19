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
  { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash", isActive: true, sortOrder: 1, createdAt: "2026-08-19T00:00:00Z" },
  { id: "pm-credit", accountId: "a", name: "Cuenta corriente", kind: "credit", isActive: true, sortOrder: 5, createdAt: "2026-08-19T00:00:00Z" },
  { id: "pm-transfer", accountId: "a", name: "Transferencia bancaria", kind: "transfer", isActive: true, sortOrder: 2, createdAt: "2026-08-19T00:00:00Z" },
]

const usePaymentMethodsMock = vi.fn()
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: (...args: unknown[]) => usePaymentMethodsMock(...args),
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

  it("D8: muestra el texto de apoyo de 'credit' cuando la forma de pago elegida es cuenta corriente", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="sale" />)

    expect(screen.getByText(/no genera un cargo en la cuenta corriente del cliente/)).toBeInTheDocument()
  })

  it("D8: el texto de apoyo de 'credit' para compras menciona al proveedor, no al cliente", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="purchase" />)

    expect(screen.getByText(/no genera un cargo en la cuenta corriente del proveedor/)).toBeInTheDocument()
  })

  it("D8: muestra el texto de apoyo de 'cash' cuando la forma de pago elegida es efectivo", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} />)

    expect(screen.getByText(/no requiere sesión de caja abierta/)).toBeInTheDocument()
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
