/**
 * ExpenseForm — edición CON DINERO (edicion-operaciones-con-dinero, tanda C, 12.1/13.1).
 *
 * El gasto en efectivo o por transferencia ya se puede corregir (antes era inmutable, P0423): la edición compensa en la caja
 * y el banco según el plan del servidor. El formulario muestra el bloque de caja («Registrado en caja» marcado si hay huella)
 * y la cuenta bancaria, manda sus claves tri-estado sólo cuando cambian, agrega el motivo del cambio y confirma el plan.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { argentinaToday } from "@/lib/date-range"
import type { EditPreview, MoneyPlan } from "@/lib/money-plan"
import type { Expense } from "@/lib/types"

const updateMock = vi.fn()
const previewMock = vi.fn()
const toastSuccess = vi.fn()
const toastError = vi.fn()

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let sessionMock: { id: string } | null = null
let cashLoadingMock = false
let bankAccountsMock: Array<{ id: string; name: string; isActive: boolean; accountKind: string }> = []

vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: (...a: unknown[]) => updateMock(...a) }),
  previewExpenseEdit: (...a: unknown[]) => previewMock(...a),
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({ useBankAccounts: () => ({ data: bankAccountsMock, isLoading: false }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: cashLoadingMock ? undefined : [{ id: "cashbox-1" }], isLoading: cashLoadingMock }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: sessionMock, isLoading: false }) }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <div>
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>{pm.name}</button>
      ))}
      <span data-testid="pm-value">{value ?? "none"}</span>
    </div>
  ),
  BankAccountDestinationSelect: ({
    paymentMethodKind,
    value,
    onChange,
    required,
  }: {
    paymentMethodKind: string | null
    value: string | null
    onChange: (v: string | null) => void
    required?: boolean
  }) =>
    paymentMethodKind === "transfer" ? (
      <div data-testid="bank-select" data-required={required ? "true" : "false"}>
        <span data-testid="bank-value">{value ?? "default"}</span>
        <button type="button" onClick={() => onChange("ba-2")}>Cambiar cuenta</button>
      </div>
    ) : null,
}))

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

const EMPTY_PLAN: MoneyPlan = {
  writes_money: false,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}
const preview = (over: Partial<MoneyPlan> = {}): EditPreview => ({ dry_run: true, plan: { ...EMPTY_PLAN, ...over }, voided_fiscal_document: null })

function makeExpense(over: Partial<Expense> = {}): Expense {
  return {
    id: "exp-1",
    date: "2026-11-01",
    category: "Servicios",
    description: "Luz",
    amount: 1200,
    branchId: "branch-1",
    costCenterId: null,
    paymentMethodId: null,
    paymentMethodKind: null,
    ...over,
  }
}

function submit() {
  fireEvent.click(screen.getByRole("button", { name: /guardar cambios/i }))
}

beforeEach(() => {
  paymentMethodsMock = [PM_CASH, PM_TRANSFER]
  sessionMock = { id: "ses-0123456789" }
  cashLoadingMock = false
  bankAccountsMock = [{ id: "ba-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
  updateMock.mockResolvedValue({ id: "exp-1", money: null })
  previewMock.mockResolvedValue(preview())
})

afterEach(() => {
  vi.clearAllMocks()
})

describe("ExpenseForm — edición: bloques de dinero", () => {
  it("gasto en efectivo con movimiento de caja: 'Registrado en caja' TILDADO", () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash", hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "checked")
    expect(screen.getByText(/Registrado en caja/i)).toBeInTheDocument()
  })

  it("gasto en efectivo SIN movimiento de caja: el tilde nace DESMARCADO (el alta lo pre-marca; la edición parte de lo que hay)", () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ date: argentinaToday(), paymentMethodId: PM_CASH.id, paymentMethodKind: "cash" })}
      />,
    )
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "unchecked")
  })

  it("transferencia: el selector de cuenta bancaria aparece al editar, con la cuenta de la huella", () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_TRANSFER.id, paymentMethodKind: "transfer", hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    expect(screen.getByTestId("bank-value")).toHaveTextContent("ba-1")
    expect(screen.getByTestId("bank-select")).toHaveAttribute("data-required", "false")
  })

  it("pasar a transferencia desde otra forma de pago SIN cuenta elegida: la cuenta es obligatoria (como en el alta)", () => {
    render(
      <ExpenseForm onSuccess={vi.fn()} initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash" })} />,
    )
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    expect(screen.getByTestId("bank-select")).toHaveAttribute("data-required", "true")
  })

  it("hay un campo opcional «Motivo del cambio»; en el alta no", () => {
    const { unmount } = render(<ExpenseForm onSuccess={vi.fn()} initialData={makeExpense()} />)
    expect(screen.getByLabelText(/Motivo del cambio/i)).toBeInTheDocument()
    unmount()
    render(<ExpenseForm onSuccess={vi.fn()} />)
    expect(screen.queryByLabelText(/Motivo del cambio/i)).toBeNull()
  })

  it("caja cargando en la edición con efectivo: avisa y no deja confirmar", () => {
    cashLoadingMock = true
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash", hasCashMovement: true })}
      />,
    )
    expect(screen.getByRole("status")).toHaveTextContent("Verificando la caja…")
    expect(screen.getByRole("button", { name: /guardar cambios/i })).toBeDisabled()
  })
})

describe("ExpenseForm — edición: el payload manda las claves de dinero sólo cuando cambian", () => {
  async function saved() {
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    return updateMock.mock.calls[0][0] as { money?: Record<string, unknown> }
  }

  it("sin tocar nada: ninguna clave de dinero viaja", async () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash", hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    expect((await saved()).money ?? {}).toEqual({})
  })

  it("destildar 'Registrado en caja' manda cashSessionId null explícito", async () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash", hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    expect((await saved()).money).toEqual({ cashSessionId: null })
  })

  it("gasto de hoy sin huella: tildar manda la sesión abierta", async () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ date: argentinaToday(), paymentMethodId: PM_CASH.id, paymentMethodKind: "cash" })}
      />,
    )
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    expect((await saved()).money).toEqual({ cashSessionId: "ses-0123456789" })
  })

  it("cambiar la cuenta bancaria manda bankAccountId", async () => {
    render(
      <ExpenseForm
        onSuccess={vi.fn()}
        initialData={makeExpense({ paymentMethodId: PM_TRANSFER.id, paymentMethodKind: "transfer", hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    fireEvent.click(screen.getByRole("button", { name: "Cambiar cuenta" }))
    submit()
    expect((await saved()).money).toEqual({ bankAccountId: "ba-2" })
  })

  it("pasar a transferencia sin elegir cuenta: avisa antes de salir (P0412 del servidor es la autoridad)", async () => {
    render(
      <ExpenseForm onSuccess={vi.fn()} initialData={makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash" })} />,
    )
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    submit()
    await waitFor(() => expect(toastError).toHaveBeenCalled())
    expect(String(toastError.mock.calls[0][0])).toMatch(/cuenta bancaria/i)
    expect(updateMock).not.toHaveBeenCalled()
    expect(previewMock).not.toHaveBeenCalled()
  })

  it("el motivo del cambio se manda recortado", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} initialData={makeExpense()} />)
    fireEvent.change(screen.getByLabelText(/Motivo del cambio/i), { target: { value: " Importe mal cargado " } })
    submit()
    expect((await saved()).money).toEqual({ reason: "Importe mal cargado" })
  })
})

describe("ExpenseForm — edición: el plan del servidor", () => {
  const CASH_BACK = preview({
    writes_money: true,
    cash: {
      action: "both",
      register: { session_id: "s", cashbox_id: "b", amount: "-300.00", movement_type: "expense" },
      reverse: [{ cashbox_id: "b", session_id: "s", net: "-500.00", reference_id: "r", movement_type: "expense_reversal" }],
    },
  })
  const cashExpense = () =>
    makeExpense({ paymentMethodId: PM_CASH.id, paymentMethodKind: "cash", hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })

  it("sin dinero ni forma de pago: no pide vista previa", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} initialData={makeExpense()} />)
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock).not.toHaveBeenCalled()
  })

  it("con dinero registrado pide la vista previa con el MISMO payload que el guardado", async () => {
    render(<ExpenseForm onSuccess={vi.fn()} initialData={cashExpense()} />)
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock.mock.calls[0][0]).toEqual(updateMock.mock.calls[0][0])
  })

  it("si el plan escribe dinero abre la confirmación (compensa y registra en la caja) y guarda al confirmar", async () => {
    previewMock.mockResolvedValue(CASH_BACK)
    render(<ExpenseForm onSuccess={vi.fn()} initialData={cashExpense()} />)
    submit()
    expect(await screen.findByRole("alertdialog")).toBeInTheDocument()
    expect(screen.getAllByRole("listitem").length).toBeGreaterThanOrEqual(2)
    expect(updateMock).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: /confirmar y guardar/i }))
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
  })

  it("un plan con bloqueo (caja cerrada) muestra el motivo y no deja confirmar", async () => {
    previewMock.mockResolvedValue(
      preview({
        writes_money: true,
        blocks: [{ book: "cash", code: "P0426", token: "no_open_session_for_reversal", message: "no_open_session_for_reversal: x" }],
      }),
    )
    render(<ExpenseForm onSuccess={vi.fn()} initialData={cashExpense()} />)
    submit()
    expect((await screen.findByRole("alert")).textContent).toMatch(/abr[ií] la caja/i)
    expect(screen.getByRole("button", { name: /confirmar y guardar/i })).toBeDisabled()
  })

  it("el aviso posterior sale del plan que el servidor EJECUTÓ", async () => {
    updateMock.mockResolvedValue({ id: "exp-1", money: CASH_BACK.plan })
    render(<ExpenseForm onSuccess={vi.fn()} initialData={cashExpense()} />)
    submit()
    await waitFor(() => expect(toastSuccess).toHaveBeenCalled())
    expect(String(toastSuccess.mock.calls[0][0])).toMatch(/caja/i)
  })

  it("el rechazo del guardado se muestra humanizado, como edición", async () => {
    updateMock.mockRejectedValue(new Error("no_open_session_for_reversal: abrí la caja para poder corregir esta operación"))
    render(<ExpenseForm onSuccess={vi.fn()} initialData={cashExpense()} />)
    submit()
    await waitFor(() => expect(toastError).toHaveBeenCalled())
    const text = String(toastError.mock.calls[0][0])
    expect(text).not.toContain("no_open_session_for_reversal")
    expect(text).toMatch(/no se guard[oó] ning[uú]n cambio/i)
  })
})
