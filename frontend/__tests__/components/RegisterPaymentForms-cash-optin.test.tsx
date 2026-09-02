/**
 * RegisterPaymentForm / RegisterPaymentMadeForm — opt-in de caja
 * (caja-compras-cobranzas D2/D4/D5, task 11.1/11.2/11.3 RED->GREEN->
 * TRIANGULATE).
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

vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
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

describe("RegisterPaymentForm (cobro) — opt-in de caja", () => {
  it("con Efectivo (default) y sesión abierta: el checkbox aparece PRE-MARCADO", () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    render(<RegisterPaymentForm clientId="client-1" />)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    expect(checkbox).toHaveAttribute("data-state", "checked")
    expect(screen.getByText(/Registrar en caja/i)).toBeInTheDocument()
  })

  it("con Efectivo y SIN caja abierta: el motivo se muestra, nunca se oculta en silencio", () => {
    currentSessionMock = null
    setup()
    render(<RegisterPaymentForm clientId="client-1" />)

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("con método bancario: el bloque de caja NO se muestra (y el selector de cuenta sigue obligatorio)", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)

    await user.click(screen.getByRole("combobox", { name: /método de pago/i }))
    await user.click(await screen.findByRole("option", { name: "Transferencia" }))

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: /cuenta bancaria/i })).toBeInTheDocument()
  })

  it("elegible y tildado: el submit manda el id de la sesión abierta", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar cobro/i }))

    await waitFor(() => expect(registerPaymentMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMock.mock.calls[0][0].cashSessionId).toBe("session-abc12345")
  })

  it("elegible pero DESTILDADO: el submit manda null", async () => {
    currentSessionMock = { id: "session-abc12345" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)
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
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar cobro/i }))

    await waitFor(() => expect(registerPaymentMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMock.mock.calls[0][0].cashSessionId).toBeNull()
  })
})

describe("RegisterPaymentMadeForm (pago a proveedor) — opt-in de caja (espejo)", () => {
  it("con Efectivo y sesión abierta: el checkbox aparece PRE-MARCADO", () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    expect(checkbox).toHaveAttribute("data-state", "checked")
  })

  it("elegible y tildado: el submit manda el id de la sesión abierta", async () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)
    await fillAmount(user)
    await user.click(screen.getByRole("button", { name: /registrar pago/i }))

    await waitFor(() => expect(registerPaymentMadeMock).toHaveBeenCalledTimes(1))
    expect(registerPaymentMadeMock.mock.calls[0][0].cashSessionId).toBe("session-xyz98765")
  })

  it("con método bancario: el bloque de caja no se muestra", async () => {
    currentSessionMock = { id: "session-xyz98765" }
    setup()
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)

    await user.click(screen.getByRole("combobox", { name: /método de pago/i }))
    await user.click(await screen.findByRole("option", { name: "Transferencia" }))

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })
})
