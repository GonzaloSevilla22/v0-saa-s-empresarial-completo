/**
 * PaymentMethodSelect — component tests (metodos-pago-operaciones, task 5.1).
 *
 * Radix Select no abre bien en jsdom (Portal + pointer capture), así que se
 * prueba lo observable sin abrir el dropdown: el trigger muestra el
 * placeholder "Sin especificar" cuando value=null, y el texto de apoyo D8
 * aparece/desaparece según el kind de la forma de pago seleccionada.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { PaymentMethodSelect, BankAccountDestinationSelect } from "@/components/payment-methods/PaymentMethodSelect"
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
const useBankAccountsMock = vi.fn()
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: (...args: unknown[]) => useBankAccountsMock(...args),
}))

beforeEach(() => {
  useBankAccountsMock.mockReturnValue({ data: [], isLoading: false, isError: false, error: null })
})

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

  it("qa-integral-modulos G10 (H8): el texto de apoyo de 'credit' en compra declara que SÍ carga la cuenta corriente del proveedor", () => {
    // compras-proveedor-cuenta-corriente (2026-08-23, PR #452) cablea el cargo
    // real — el texto viejo ("no genera un cargo") quedó mintiendo: el QA vio
    // el saldo pasar de $0 a $8.900 con la etiqueta que se declaraba inocua.
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="purchase" />)

    expect(
      screen.getByText(/carga la compra a la cuenta corriente del proveedor al confirmarla/),
    ).toBeInTheDocument()
    expect(screen.queryByText(/no genera un cargo/i)).not.toBeInTheDocument()
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

// ── cuentas-billetera-tipo (task 8.3): ícono por tipo en BankAccountDestinationSelect ─

describe("BankAccountDestinationSelect — ícono por account_kind", () => {
  it("distingue billetera de banco por ícono en las opciones", async () => {
    useBankAccountsMock.mockReturnValue({
      data: [
        { id: "ba-wallet", accountId: "a", name: "Mercado Pago", bankName: null, cbu: null, alias: "luzmin.mp", currency: "ARS", accountKind: "wallet", isActive: true },
        { id: "ba-bank", accountId: "a", name: "Cuenta corriente Galicia", bankName: "Banco Galicia", cbu: null, alias: null, currency: "ARS", accountKind: "bank", isActive: true },
      ],
      isLoading: false, isError: false, error: null,
    })
    const user = userEvent.setup()

    render(<BankAccountDestinationSelect paymentMethodKind="transfer" value={null} onChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox"))

    expect(document.querySelector(".lucide-wallet")).toBeTruthy()
    expect(document.querySelector(".lucide-landmark")).toBeTruthy()
  })
})

// ── gastos-forma-pago (D3/D5, tasks 10.2 y 10.3): contexto de GASTO ─────────

describe("PaymentMethodSelect — contexto de gasto (D3)", () => {
  it("NO ofrece las formas de pago de kind='credit': un gasto no tiene cuenta corriente", async () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
    const user = userEvent.setup()

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} context="expense" />)
    await user.click(screen.getByRole("combobox"))

    expect(await screen.findByRole("option", { name: /Efectivo/ })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: /Transferencia bancaria/ })).toBeInTheDocument()
    expect(screen.queryByRole("option", { name: /Cuenta corriente/ })).not.toBeInTheDocument()
  })

  it("CONTROL POSITIVO: en contexto de venta esa misma forma de pago SÍ se ofrece", async () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
    const user = userEvent.setup()

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} context="sale" />)
    await user.click(screen.getByRole("combobox"))

    // Sin este control, un filtro que escondiera TODAS las opciones también
    // pasaría el test de arriba.
    expect(await screen.findByRole("option", { name: /Cuenta corriente/ })).toBeInTheDocument()
  })

  it("el texto de apoyo de 'cash' en gasto anuncia que el egreso se registra salvo que se destilde", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="expense" />)

    expect(screen.getByText(/salvo que destildes/i)).toBeInTheDocument()
    // No debe filtrarse el texto de venta, que habla del POS.
    expect(screen.queryByText(/POS/)).not.toBeInTheDocument()
  })

  it("el texto de apoyo de 'credit' en gasto redirige a la compra a proveedor (D3)", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="expense" />)

    expect(screen.getByText(/compra a proveedor/i)).toBeInTheDocument()
    expect(screen.queryByText(/cuenta corriente del cliente/i)).not.toBeInTheDocument()
  })
})

describe("BankAccountDestinationSelect — modo obligatorio del gasto (D5 / OQ-2)", () => {
  const ACCOUNTS = [
    { id: "ba-1", accountId: "a", name: "Cuenta corriente Galicia", bankName: "Banco Galicia", cbu: null, alias: null, currency: "ARS", accountKind: "bank", isActive: true },
  ]

  it("required: el label dice (obligatorio) y NO se ofrece 'usar el destino configurado'", async () => {
    useBankAccountsMock.mockReturnValue({ data: ACCOUNTS, isLoading: false, isError: false, error: null })
    const user = userEvent.setup()

    render(<BankAccountDestinationSelect paymentMethodKind="transfer" value={null} onChange={vi.fn()} required />)

    expect(screen.getByText("(obligatorio)")).toBeInTheDocument()
    await user.click(screen.getByRole("combobox", { name: /cuenta bancaria/i }))
    expect(await screen.findByRole("option", { name: /Galicia/ })).toBeInTheDocument()
    // Con 0 de 37 catálogos con destino configurado, dejar esa opción sería
    // ofrecer el no-op silencioso que este change viene a cerrar.
    expect(screen.queryByRole("option", { name: /destino configurado/i })).not.toBeInTheDocument()
  })

  it("sin `required` conserva exactamente el comportamiento de venta y compra", async () => {
    useBankAccountsMock.mockReturnValue({ data: ACCOUNTS, isLoading: false, isError: false, error: null })
    const user = userEvent.setup()

    render(<BankAccountDestinationSelect paymentMethodKind="transfer" value={null} onChange={vi.fn()} />)

    expect(screen.getByText("(opcional)")).toBeInTheDocument()
    await user.click(screen.getByRole("combobox", { name: /cuenta bancaria/i }))
    expect(await screen.findByRole("option", { name: /destino configurado/i })).toBeInTheDocument()
  })

  it("sin cuentas activas y con showEmptyNotice: explica que el gasto no va a llegar a la conciliación", () => {
    useBankAccountsMock.mockReturnValue({ data: [], isLoading: false, isError: false, error: null })

    render(<BankAccountDestinationSelect paymentMethodKind="transfer" value={null} onChange={vi.fn()} required showEmptyNotice />)

    expect(screen.getByTestId("bank-accounts-empty-notice")).toBeInTheDocument()
    expect(screen.getByText(/no va a aparecer en la conciliación/i)).toBeInTheDocument()
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument()
  })

  it("sin cuentas activas y SIN showEmptyNotice: cero render, como en venta y compra", () => {
    useBankAccountsMock.mockReturnValue({ data: [], isLoading: false, isError: false, error: null })

    const { container } = render(<BankAccountDestinationSelect paymentMethodKind="transfer" value={null} onChange={vi.fn()} />)

    expect(container).toBeEmptyDOMElement()
  })
})

// ── cobranzas-catalogo-pagos (D2/D6, tasks 8.1-8.5): contexto de COBRANZA ───
// (cobro de cuenta corriente + pago a proveedor comparten el mismo contexto)

describe("PaymentMethodSelect — contexto de cobranza (D2/D6)", () => {
  it("NO ofrece las formas de pago de kind='credit': cobrar/pagar con cuenta corriente es circular", async () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
    const user = userEvent.setup()

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} context="collection" />)
    await user.click(screen.getByRole("combobox"))

    expect(await screen.findByRole("option", { name: /Efectivo/ })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: /Transferencia bancaria/ })).toBeInTheDocument()
    expect(screen.queryByRole("option", { name: /Cuenta corriente/ })).not.toBeInTheDocument()
  })

  it("el texto de apoyo de 'cash' en cobranza declara el opt-in PRE-MARCADO (no el de venta, que arranca destildado)", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-cash" onChange={vi.fn()} context="collection" />)

    expect(screen.getByText(/salvo que destildes/i)).toBeInTheDocument()
    // No debe reutilizar la redacción de venta, que nombra el POS y describe
    // un opt-in que arranca DESTILDADO.
    expect(screen.queryByText(/POS/)).not.toBeInTheDocument()
  })

  it("el texto de apoyo de 'credit' en cobranza explica por qué no está disponible, aunque el selector no lo ofrezca", () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })

    render(<PaymentMethodSelect value="pm-credit" onChange={vi.fn()} context="collection" />)

    expect(screen.getByText(/circular/i)).toBeInTheDocument()
  })

  it("las opciones de cobranza son IDÉNTICAS entre 'collection' usado para cobro y para pago — mismo contexto, mismo componente", async () => {
    usePaymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
    const user = userEvent.setup()

    const { unmount } = render(<PaymentMethodSelect value={null} onChange={vi.fn()} context="collection" />)
    await user.click(screen.getByRole("combobox"))
    const cobroOptions = screen.getAllByRole("option").map((o) => o.textContent)
    unmount()

    render(<PaymentMethodSelect value={null} onChange={vi.fn()} context="collection" />)
    await user.click(screen.getByRole("combobox"))
    const pagoOptions = screen.getAllByRole("option").map((o) => o.textContent)

    expect(cobroOptions).toEqual(pagoOptions)
  })
})
