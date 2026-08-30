/**
 * Accesibilidad — gastos-forma-pago (task 10.7). Molde:
 * `__tests__/a11y/proveedores.a11y.test.tsx`.
 *
 * Comportamiento real, no tautologías: cada campo del formulario de gasto
 * alcanzable por su label (`getByLabelText`), los dos selectores de Radix con
 * nombre accesible por rol, el checkbox del opt-in de caja con nombre propio
 * (un checkbox que mueve caja no puede ser un cuadrito sin nombre para un
 * lector de pantalla), el motivo del bloqueo anunciado como `role="note"` y el
 * texto de apoyo de la forma de pago ATADO al selector por `aria-describedby`
 * — si no está atado, el lector de pantalla nunca lo lee y la advertencia
 * "esto mueve plata" no existe para quien no ve la pantalla.
 *
 * Dos gaps reales encontrados y corregidos acá (RED → GREEN), los mismos que
 * el precedente de proveedores encontró en `supplier-form.tsx`:
 *   1. `PaymentMethodSelect`: el `Label` no tenía `htmlFor` ni el trigger `id`,
 *      así que el campo "Forma de pago" no era alcanzable por label.
 *   2. el texto de apoyo (D8/D3 — el que dice qué hace y qué NO hace la forma
 *      de pago elegida) no estaba asociado al control.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { ExpenseForm } from "@/components/forms/expense-form-v2"

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null
let bankAccountsMock: Array<{ id: string; name: string; isActive: boolean; accountKind: string }> = []

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: vi.fn() }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: bankAccountsMock, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: currentSessionMock, isLoading: false }),
}))

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

/** Elige una forma de pago por el combobox REAL (Radix abre en jsdom: setup.ts). */
async function selectPaymentMethod(user: ReturnType<typeof userEvent.setup>, name: string) {
  await user.click(screen.getByRole("combobox", { name: /forma de pago/i }))
  await user.click(await screen.findByRole("option", { name }))
}

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  currentSessionMock = null
  bankAccountsMock = []
})

describe("Accesibilidad — ExpenseForm (task 10.7)", () => {
  it("los cinco campos base son alcanzables por getByLabelText, incluidos los Select de Radix", () => {
    paymentMethodsMock = [PM_CASH]
    render(<ExpenseForm onSuccess={vi.fn()} />)

    expect(screen.getByLabelText(/^categor[ií]a$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^descripci[oó]n$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^monto$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^fecha$/i)).toBeInTheDocument()
    // RED antes del fix: el Label de PaymentMethodSelect no tenía htmlFor.
    expect(screen.getByLabelText(/forma de pago/i)).toBeInTheDocument()
  })

  it("Categoría y Forma de pago son comboboxes con nombre accesible, no texto suelto", () => {
    paymentMethodsMock = [PM_CASH]
    render(<ExpenseForm onSuccess={vi.fn()} />)

    expect(screen.getByRole("combobox", { name: /categor[ií]a/i })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: /forma de pago/i })).toBeInTheDocument()
  })

  it("el texto de apoyo de la forma de pago está ATADO al selector por aria-describedby", async () => {
    paymentMethodsMock = [PM_CASH]
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)

    await selectPaymentMethod(user, "Efectivo")

    const trigger = screen.getByRole("combobox", { name: /forma de pago/i })
    const describedBy = trigger.getAttribute("aria-describedby")
    expect(describedBy).toBeTruthy()
    // El texto tiene que ser EL de apoyo, no cualquier nodo: sin esto, el
    // aviso de "esto registra el egreso en la caja" no existe para quien usa
    // un lector de pantalla.
    const support = document.getElementById(describedBy as string)
    expect(support?.textContent).toMatch(/salvo que destildes/i)
  })

  it("el selector de cuenta bancaria tiene nombre accesible propio cuando se monta", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "bank" }]
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)

    await selectPaymentMethod(user, "Transferencia")

    expect(screen.getByRole("combobox", { name: /cuenta bancaria/i })).toBeInTheDocument()
  })

  it("el checkbox del opt-in de caja tiene nombre accesible: no es un cuadrito mudo", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)

    await selectPaymentMethod(user, "Efectivo")

    expect(screen.getByRole("checkbox", { name: /registrar en caja/i })).toBeInTheDocument()
  })

  it("cuando el opt-in no aplica, el motivo se anuncia como nota, no como texto decorativo", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)

    await selectPaymentMethod(user, "Efectivo")

    expect(screen.getByRole("note")).toHaveTextContent(/no hay caja abierta/i)
  })

  it("el input Descripción usa el ring de foco compartido del design system, no un outline custom", () => {
    paymentMethodsMock = [PM_CASH]
    render(<ExpenseForm onSuccess={vi.fn()} />)

    const input = screen.getByLabelText(/^descripci[oó]n$/i)
    expect(input.className).toMatch(/focus-visible:ring/)
  })
})
