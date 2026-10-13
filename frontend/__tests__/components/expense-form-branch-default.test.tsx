/**
 * ExpenseForm — la sucursal por defecto a la vista (compras-gastos-sucursal-por-defecto,
 * D9, tarea 5.2).
 *
 * El alta del gasto ya guardaba la sucursal PRINCIPAL cuando no se elegía ninguna
 * (`gastos-forma-pago` D6), pero el formulario seguía ofreciendo «Sin sucursal (general)»:
 * el rótulo mentía. Y la edición de un gasto sin sucursal (histórico) tampoco la completaba;
 * desde este change la RPC resuelve un nulo, informado o vigente, a la principal.
 *
 * El formulario deja de ofrecer la opción sin sucursal y muestra la principal ya elegida,
 * rotulada «(principal)», con su rótulo «Sucursal» dentro del selector. El estado sigue en
 * `null` hasta que el usuario elige otra y viaja `null`: el SERVIDOR resuelve la principal.
 *
 * Se monta el `BranchSelect` REAL con el Select de Radix real (mock de los hooks de plan y de
 * sucursales), a diferencia de expense-form-payment-effects, que lo sustituye.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import type { Branch, Expense } from "@/lib/types"

const addExpenseMock = vi.fn().mockResolvedValue(undefined)
const updateExpenseMock = vi.fn().mockResolvedValue(undefined)

function branch(overrides: Partial<Branch> & { id: string; name: string }): Branch {
  return {
    accountId: "acc-1",
    address: null,
    isActive: true,
    createdAt: "2026-01-01T00:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...overrides,
  }
}

const CENTRO = branch({ id: "b-centro", name: "Centro" })
const SHOWROOM = branch({ id: "b-show", name: "Showroom", createdAt: "2026-03-01T00:00:00Z" })

const usePlanLimitsMock = vi.fn()
const useBranchesMock = vi.fn()

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => usePlanLimitsMock() }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: addExpenseMock }),
  useUpdateExpense: () => ({ mutateAsync: updateExpenseMock }),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => <div data-testid="cc-select" /> }))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: null, isLoading: false }),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => <div data-testid="payment-method-select" />,
  BankAccountDestinationSelect: () => null,
}))

const HISTORICO: Expense = {
  id: "exp-1",
  date: "2026-08-20",
  category: "Servicios",
  description: "Luz",
  amount: 1500,
  branchId: null,
  costCenterId: null,
  paymentMethodId: null,
}

/** Completa los campos obligatorios por el mismo camino que el usuario (molde de
 *  expense-form-payment-effects: el Select de categoría es de Radix y abre en jsdom). */
async function fillRequired() {
  const user = userEvent.setup()
  fireEvent.change(screen.getByLabelText(/descripci[oó]n/i), { target: { value: "Luz de agosto" } })
  fireEvent.change(screen.getByLabelText(/monto/i), { target: { value: "1500" } })
  await user.click(screen.getByRole("combobox", { name: /categor[ií]a/i }))
  await user.click(await screen.findByRole("option", { name: "Servicios" }))
}

beforeEach(() => {
  vi.clearAllMocks()
  usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: true } })
  useBranchesMock.mockReturnValue({ branches: [CENTRO, SHOWROOM], isLoading: false, isError: false })
})

describe("ExpenseForm — el selector de sucursal muestra la principal (alta)", () => {
  it("muestra la principal rotulada «(principal)», sin «Sin sucursal (general)», con su rótulo «Sucursal»", async () => {
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)

    await user.click(trigger)
    const options = within(await screen.findByRole("listbox")).getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Centro (principal)", "Showroom"])
  })

  it("getByLabelText('Sucursal') encuentra el disparador (rótulo asociado por id)", () => {
    render(<ExpenseForm onSuccess={vi.fn()} />)

    expect(screen.getByLabelText("Sucursal")).toBe(screen.getByRole("combobox", { name: "Sucursal" }))
  })

  it("sin tocar el selector, el alta viaja con branchId null: el SERVIDOR resuelve la principal con datos vivos", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalledTimes(1))
    expect(addExpenseMock.mock.calls[0][0].branchId).toBeNull()
  })

  it("elegir otra sucursal manda su id", async () => {
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Showroom" }))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalledTimes(1))
    expect(addExpenseMock.mock.calls[0][0].branchId).toBe("b-show")
  })

  it("elegir la principal que ya se muestra no cambia el estado: sigue viajando null", async () => {
    const user = userEvent.setup()
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()

    await user.click(screen.getByRole("combobox", { name: "Sucursal" }))
    await user.click(await screen.findByRole("option", { name: "Centro (principal)" }))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalledTimes(1))
    expect(addExpenseMock.mock.calls[0][0].branchId).toBeNull()
  })

  it("cuenta sin el módulo de sucursales: ni selector ni rótulo (el servidor registra la principal)", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
    render(<ExpenseForm onSuccess={vi.fn()} />)

    expect(screen.queryByRole("combobox", { name: "Sucursal" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Sucursal")).not.toBeInTheDocument()
    expect(screen.queryByText(/sin sucursal/i)).not.toBeInTheDocument()
  })
})

describe("ExpenseForm — el selector de sucursal en la edición", () => {
  it("precarga la sucursal del gasto y la reenvía en el payload", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} initialData={{ ...HISTORICO, branchId: "b-show" }} />)

    expect(screen.getByRole("combobox", { name: "Sucursal" })).toHaveTextContent("Showroom")
    fireEvent.click(screen.getByRole("button", { name: /guardar cambios/i }))

    await waitFor(() => expect(updateExpenseMock).toHaveBeenCalledTimes(1))
    expect(updateExpenseMock.mock.calls[0][0].branchId).toBe("b-show")
  })

  it("un gasto histórico sin sucursal muestra la principal y viaja null: el servidor lo resuelve a la principal (D5)", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} initialData={HISTORICO} />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)
    fireEvent.click(screen.getByRole("button", { name: /guardar cambios/i }))

    await waitFor(() => expect(updateExpenseMock).toHaveBeenCalledTimes(1))
    expect(updateExpenseMock.mock.calls[0][0].branchId).toBeNull()
  })
})
