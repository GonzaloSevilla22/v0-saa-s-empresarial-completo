/**
 * RegisterPaymentForm / RegisterPaymentMadeForm — opt-in de caja
 * (caja-compras-cobranzas D2/D4/D5, task 11.1/11.2/11.3 RED->GREEN->
 * TRIANGULATE) + cobranzas-catalogo-pagos (D6/D11): el selector migró al
 * catálogo, así que ya NO hay un default "cash" implícito al montar — el
 * usuario elige explícitamente una forma de pago del catálogo, y D11 exige
 * que el opt-in de caja se derive del `kind` REAL de esa elección (no del
 * valor crudo del control), así que estos tests seleccionan "Efectivo"
 * antes de verificar el bloque — es, a la vez, el test de regresión de D11:
 * si el wiring del kind se rompiera, el checkbox jamás aparecería.
 *
 * Cuarto y quinto consumidor de useCashOptin (document="cobro",
 * requiresDate=false — D5: el cobro/pago no tiene fecha ni sucursal
 * propias, así que sólo dos condiciones aplican: método=efectivo y sesión
 * abierta).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { RegisterPaymentForm } from "@/components/customer-accounts/RegisterPaymentForm"
import { RegisterPaymentMadeForm } from "@/components/supplier-accounts/RegisterPaymentMadeForm"

const registerPaymentMock = vi.fn().mockResolvedValue({ replayed: false })
const registerPaymentMadeMock = vi.fn().mockResolvedValue({ replayed: false })
let currentSessionMock: { id: string } | null = null
const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

const paymentMethodsFixture = [
  { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash" as const, isActive: true, sortOrder: 1, createdAt: "2026-01-01", bankAccountId: null },
  { id: "pm-transfer", accountId: "a", name: "Transferencia", kind: "transfer" as const, isActive: true, sortOrder: 2, createdAt: "2026-01-01", bankAccountId: null },
]

// cobranzas-catalogo-pagos (D4): con cero cuentas bancarias activas,
// BankAccountDestinationSelect renderiza el aviso "no tenés cuentas
// cargadas" en vez del combobox — el test de "método bancario" necesita una
// cuenta real para poder verificar que el selector queda obligatorio.
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({
    data: [{ id: "ba-1", accountId: "a", name: "Banco Nación", bankName: "Banco Nación", cbu: null, alias: null, currency: "ARS", accountKind: "bank", isActive: true }],
    isLoading: false, isError: false, error: null,
  }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsFixture, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useRegisterPayment: () => ({ mutateAsync: registerPaymentMock }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useRegisterPaymentMade: () => ({ mutateAsync: registerPaymentMadeMock }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (...args: unknown[]) => useCashboxesMock(...args),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args),
}))

function setup() {
  useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
  useCurrentSessionMock.mockReturnValue({ data: currentSessionMock })
}

afterEach(() => {
  vi.clearAllMocks()
  currentSessionMock = null
})

async function fillAmount(user: ReturnType<typeof userEvent.setup>, value = "400") {
  await user.type(screen.getByLabelText(/importe/i), value)
}

async function selectCash(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("combobox", { name: /forma de pago/i }))
  await user.click(await screen.findByRole("option", { name: "Efectivo" }))
}

async function selectTransfer(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("combobox", { name: /forma de pago/i }))
  await user.click(await screen.findByRole("option", { name: "Transferencia" }))
}

describe("RegisterPaymentForm (cobro) — opt-in de caja", () => {
  it("sin elegir forma de pago: el bloque de caja no se ofrece (nada seleccionado todavía)", () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    render(<RegisterPaymentForm clientId="client-1" />)

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("al elegir Efectivo con sesión abierta: el checkbox aparece PRE-MARCADO (D11: el kind se deriva del catálogo)", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectCash(user)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    expect(checkbox).toHaveAttribute("data-state", "checked")
    // El texto de apoyo del selector TAMBIÉN dice "Registrar en caja" (entre
    // comillas, D6) — se matchea la etiqueta del checkbox por su frase
    // completa para no chocar con las dos apariciones.
    expect(screen.getByText(/Registrar en caja — sesión/i)).toBeInTheDocument()
  })

  it("Efectivo y SIN caja abierta: el motivo se muestra, nunca se oculta en silencio", async () => {
    currentSessionMock = null
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectCash(user)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("método bancario: el bloque de caja NO se muestra (y el selector de cuenta sigue obligatorio)", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectTransfer(user)

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: /cuenta bancaria/i })).toBeInTheDocument()
  })

  it("elegible y tildado: el submit manda el id de la sesión abierta", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectCash(user)
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar cobro/i }))

    await waitFor(() => expect(registerPaymentMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMock.mock.calls[0][0].cashSessionId).toBe("session-abc12345")
    expect(registerPaymentMock.mock.calls[0][0].paymentMethodId).toBe("pm-cash")
  })

  it("elegible pero DESTILDADO: el submit manda null", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectCash(user)
    await fillAmount(user)
    fireEvent.click(screen.getByRole("checkbox"))
    await user.click(screen.getByRole("button", { name: /registrar cobro/i }))

    await waitFor(() => expect(registerPaymentMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMock.mock.calls[0][0].cashSessionId).toBeNull()
  })

  it("sin caja abierta, el cobro puede registrarse igual (no bloquea)", async () => {
    currentSessionMock = null
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await selectCash(user)
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar cobro/i }))

    await waitFor(() => expect(registerPaymentMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMock.mock.calls[0][0].cashSessionId).toBeNull()
  })
})

describe("RegisterPaymentMadeForm (pago a proveedor) — opt-in de caja (espejo)", () => {
  it("al elegir Efectivo con sesión abierta: el checkbox aparece PRE-MARCADO", async () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)
    await selectCash(user)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    expect(checkbox).toHaveAttribute("data-state", "checked")
  })

  it("elegible y tildado: el submit manda el id de la sesión abierta", async () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)
    await selectCash(user)
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar pago/i }))

    await waitFor(() => expect(registerPaymentMadeMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMadeMock.mock.calls[0][0].cashSessionId).toBe("session-xyz98765")
    expect(registerPaymentMadeMock.mock.calls[0][0].paymentMethodId).toBe("pm-cash")
  })

  it("método bancario: el bloque de caja no se muestra", async () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)
    await selectTransfer(user)

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })
})
