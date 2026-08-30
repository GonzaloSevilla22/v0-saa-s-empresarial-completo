/**
 * ExpenseForm — forma de pago, cuenta bancaria y opt-in de caja
 * (gastos-forma-pago, grupo 10). Molde: `sale-form-payment-effects.test.tsx`.
 *
 * El módulo Gastos no tenía NINGÚN test de formulario más allá del default de
 * fecha. Estos son los caminos que el change agrega y que mueven plata:
 *   10.1/10.3 el selector de cuenta bancaria se monta con el kind bancario y
 *             es OBLIGATORIO en gastos (OQ-2 firmada), con el aviso propio
 *             cuando la organización no tiene ninguna cuenta cargada;
 *   10.4/10.5 el bloque de caja aparece PRE-MARCADO cuando las tres
 *             condiciones se cumplen (OQ-1 firmada — asimetría deliberada con
 *             el formulario de venta), y muestra el motivo concreto cuando no;
 *   10.6      `cash_session_id` viaja SÓLO si el opt-in es elegible Y está
 *             tildado; en cualquier otro caso viaja `null`.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { argentinaToday } from "@/lib/date-range"
import { toast } from "sonner"

const addExpenseMock = vi.fn().mockResolvedValue(undefined)
const updateExpenseMock = vi.fn().mockResolvedValue(undefined)

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null
let bankAccountsMock: Array<{ id: string; name: string; isActive: boolean; accountKind: string }> = []

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: addExpenseMock }),
  useUpdateExpense: () => ({ mutateAsync: updateExpenseMock }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => <div data-testid="cc-select" /> }))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: bankAccountsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: currentSessionMock, isLoading: false }),
}))

// Los dos selectores del catálogo se stubean para poder manejar la selección
// sin pelear con el portal de Radix: lo que se prueba acá es el FORMULARIO
// (qué se monta, qué se pre-marca, qué se manda), no el interior del select
// — ese se prueba en PaymentMethodSelect.test.tsx contra el componente real.
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value, onChange, context }: { value: string | null; onChange: (v: string | null) => void; context?: string }) => (
    <div data-testid="payment-method-select" data-context={context}>
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>
          {pm.name}
        </button>
      ))}
      <span data-testid="pm-selected-value">{value ?? "null"}</span>
    </div>
  ),
  BankAccountDestinationSelect: ({
    paymentMethodKind, value, onChange, required, showEmptyNotice,
  }: {
    paymentMethodKind: string | null
    value: string | null
    onChange: (v: string | null) => void
    required?: boolean
    showEmptyNotice?: boolean
  }) => {
    if (!paymentMethodKind || !["transfer", "card", "check", "wallet"].includes(paymentMethodKind)) return null
    // Sin cuentas activas el componente real muestra el aviso (o nada, según
    // showEmptyNotice). Acá sólo se registra QUÉ props le manda el
    // formulario; el render real se prueba en PaymentMethodSelect.test.tsx.
    if (bankAccountsMock.length === 0) {
      return <div data-testid="bank-empty-notice-flag" data-show-empty-notice={showEmptyNotice ? "true" : "false"} />
    }
    return (
      <div data-testid="bank-select" data-required={required ? "true" : "false"}>
        <button type="button" data-testid="bank-option" onClick={() => onChange("bank-1")}>Cuenta 1</button>
        <span data-testid="bank-selected-value">{value ?? "null"}</span>
      </div>
    )
  },
}))

const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }
const PM_OTHER = { id: "pm-other", name: "Otro", kind: "other", isActive: true }

/** Completa los campos obligatorios por el mismo camino que el usuario.
 *  El importe entra acá porque desde el hallazgo del apply el formulario exige
 *  un monto POSITIVO: el alta con 0 se rechaza antes de salir (la RPC devuelve
 *  P0400 y la tabla tiene el CHECK). */
async function fillRequired() {
  const user = userEvent.setup()
  fireEvent.change(screen.getByLabelText(/descripci[oó]n/i), { target: { value: "Luz de agosto" } })
  fireEvent.change(screen.getByLabelText(/monto/i), { target: { value: "1500" } })
  // El Select de categoría es de Radix y SÍ abre en jsdom: `__tests__/setup.ts`
  // parchea hasPointerCapture/scrollIntoView (molde de RegisterPaymentForms).
  await user.click(screen.getByRole("combobox", { name: /categor[ií]a/i }))
  await user.click(await screen.findByRole("option", { name: "Servicios" }))
}

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  currentSessionMock = null
  bankAccountsMock = []
})

describe("ExpenseForm — selector de forma de pago (10.1/10.2)", () => {
  it("monta el selector con contexto de GASTO, no el de venta", () => {
    paymentMethodsMock = [PM_CASH]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    expect(screen.getByTestId("payment-method-select")).toHaveAttribute("data-context", "expense")
  })
})

describe("ExpenseForm — importe positivo (hallazgo del apply)", () => {
  it("no manda el alta con importe cero y avisa el motivo", async () => {
    // El servidor es la autoridad (P0400 en la RPC, CHECK en la tabla), pero
    // el `min={0}` del input deja pasar el cero y el usuario comería un error
    // crudo del backend. `NumericInput` renderiza "" cuando el valor es 0, así
    // que dejar el campo vacío manda exactamente este caso.
    paymentMethodsMock = [PM_OTHER]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    // Se vacía el monto a propósito: NumericInput manda 0 con el campo vacío.
    fireEvent.change(screen.getByLabelText(/monto/i), { target: { value: "" } })

    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(toast.error).toHaveBeenCalled())
    expect(String(vi.mocked(toast.error).mock.calls[0][0])).toMatch(/mayor a cero/i)
    expect(addExpenseMock).not.toHaveBeenCalled()
  })

  it("con importe positivo el alta sigue viajando (control positivo)", async () => {
    paymentMethodsMock = [PM_OTHER]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()

    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalledTimes(1))
    expect(addExpenseMock.mock.calls[0][0]).toMatchObject({ amount: 1500 })
  })
})

describe("ExpenseForm — cuenta bancaria (10.3, D5/OQ-2)", () => {
  it("kind bancario + cuentas activas: monta el selector y lo marca OBLIGATORIO", () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))

    const sel = screen.getByTestId("bank-select")
    expect(sel).toBeInTheDocument()
    expect(sel).toHaveAttribute("data-required", "true")
  })

  it("kind NO bancario: no monta el selector de cuenta", () => {
    paymentMethodsMock = [PM_CASH]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    expect(screen.queryByTestId("bank-select")).not.toBeInTheDocument()
  })

  it("organización SIN cuentas bancarias: pide el aviso en vez del selector (el gasto se guarda igual)", () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = []
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))

    // 33 de 37 cuentas de prod están en este caso: el gasto se guarda igual
    // (D5), pero el motivo no puede quedar en silencio — el formulario pide
    // el aviso explícitamente. El TEXTO del aviso se verifica contra el
    // componente real en PaymentMethodSelect.test.tsx.
    expect(screen.getByTestId("bank-empty-notice-flag")).toHaveAttribute("data-show-empty-notice", "true")
    expect(screen.queryByTestId("bank-select")).not.toBeInTheDocument()
  })

  it("sin cuentas bancarias el alta NO se bloquea: el guard es condicional (D5)", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = []
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0].bankAccountId).toBeNull()
  })

  it("bloquea el envío si falta la cuenta bancaria obligatoria, sin llegar a la API", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).not.toHaveBeenCalled())
  })

  it("con la cuenta elegida, el alta la manda en el payload", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    fireEvent.click(screen.getByTestId("bank-option"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0]).toMatchObject({
      paymentMethodId: "pm-transfer",
      bankAccountId: "bank-1",
      cashSessionId: null,
    })
  })
})

describe("ExpenseForm — opt-in de caja (10.4/10.5, D1/OQ-1)", () => {
  it("las tres condiciones cumplidas: el checkbox aparece PRE-MARCADO (asimetría con la venta)", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toBeInTheDocument()
    // OQ-1 firmada por el PO: el gasto NO arrastra la deuda de las 223
    // operaciones históricas de venta (0 de 175 gastos tocaron caja jamás).
    expect(checkbox).toHaveAttribute("data-state", "checked")
  })

  it("motivo 1 — la forma de pago no es efectivo: no hay bloque de caja", () => {
    paymentMethodsMock = [PM_OTHER]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-other"))

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.queryByText(/Registrar en caja/i)).not.toBeInTheDocument()
  })

  it("motivo 2 — no hay caja abierta: se explica y NO se oculta en silencio", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    expect(screen.getByText(/no hay caja abierta/i)).toBeInTheDocument()
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
  })

  it("motivo 3 — el gasto no es de hoy: mensaje propio, distinto del de caja cerrada", () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    const { container } = render(<ExpenseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    expect(screen.getByRole("checkbox")).toBeInTheDocument() // precondición

    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe(argentinaToday())
    fireEvent.change(dateInput, { target: { value: "2020-01-02" } })

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    expect(screen.getByText(/un gasto fechado hoy/i)).toBeInTheDocument()
    expect(screen.queryByText(/no hay caja abierta/i)).not.toBeInTheDocument()
  })
})

describe("ExpenseForm — payload del opt-in (10.6)", () => {
  it("elegible y tildado: manda el id de la sesión abierta", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0]).toMatchObject({
      paymentMethodId: "pm-cash",
      cashSessionId: "session-abc12345",
      bankAccountId: null,
    })
  })

  it("elegible pero DESTILDADO: manda null — el gasto se paga de otro bolsillo", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    fireEvent.click(screen.getByRole("checkbox"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0].cashSessionId).toBeNull()
  })

  it("NO elegible (sin caja abierta): manda null aunque el kind sea efectivo", async () => {
    paymentMethodsMock = [PM_CASH]
    currentSessionMock = null
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0].cashSessionId).toBeNull()
  })

  it("cambiar de transferencia a efectivo no arrastra la cuenta bancaria elegida antes", async () => {
    paymentMethodsMock = [PM_TRANSFER, PM_CASH]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} />)
    await fillRequired()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    fireEvent.click(screen.getByTestId("bank-option"))
    // El selector se desmonta al cambiar de kind, pero el useState conserva el
    // valor: es el bug de prod 2026-08-24, cerrado por bankAccountForKind.
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))
    fireEvent.click(screen.getByRole("button", { name: /registrar gasto/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalled())
    expect(addExpenseMock.mock.calls[0][0].bankAccountId).toBeNull()
  })
})

describe("ExpenseForm — edición (D11/D13)", () => {
  const LOCKED = {
    id: "exp-1", date: "2026-01-15", category: "Servicios",
    description: "Luz", amount: 1200,
  }

  it("en edición no se ofrece ni opt-in de caja ni cuenta bancaria: la edición no postea movimientos", () => {
    paymentMethodsMock = [PM_CASH, PM_TRANSFER]
    bankAccountsMock = [{ id: "bank-1", name: "Cuenta 1", isActive: true, accountKind: "checking" }]
    currentSessionMock = { id: "session-abc12345" }
    render(<ExpenseForm onSuccess={vi.fn()} initialData={LOCKED} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-cash"))

    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    expect(screen.queryByTestId("bank-select")).not.toBeInTheDocument()
  })

  it("la edición manda la forma de pago junto con el resto del contexto", async () => {
    paymentMethodsMock = [PM_TRANSFER]
    render(<ExpenseForm onSuccess={vi.fn()} initialData={{ ...LOCKED, paymentMethodId: null }} />)
    fireEvent.click(screen.getByTestId("pm-option-pm-transfer"))
    fireEvent.click(screen.getByRole("button", { name: /guardar cambios/i }))

    await waitFor(() => expect(updateExpenseMock).toHaveBeenCalled())
    const payload = updateExpenseMock.mock.calls[0][0]
    expect(payload).toMatchObject({ id: "exp-1", paymentMethodId: "pm-transfer" })
    expect("cashSessionId" in payload).toBe(false)
    expect("bankAccountId" in payload).toBe(false)
  })
})
