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
import { ExpenseJournalStatusBadge } from "@/components/gastos/ExpenseJournalStatusBadge"

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let currentSessionMock: { id: string } | null = null
let bankAccountsMock: Array<{ id: string; name: string; isActive: boolean; accountKind: string }> = []

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: vi.fn() }),
  // importador-gastos-transaccional (task 8.10): ExpenseImportDialog usa
  // este hook — se declara en el MISMO vi.mock (un solo factory por
  // especificador de módulo en todo el archivo; un segundo `vi.mock` para
  // la misma ruta pisaría a éste en vez de fusionarse).
  useImportExpenses: () => ({
    importMutation: { mutateAsync: vi.fn().mockResolvedValue({
      committed: false, importId: null, imported: 0, errors: [], notices: [], replayed: false, dryRun: true,
    }) },
    invalidateLedgers: vi.fn(),
  }),
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
// importador-gastos-transaccional (task 8.10): el diálogo hashea el archivo
// con `hashFileSHA256` (`lib/bank-statement-parser.ts`, vía
// `crypto.subtle.digest` sobre `File.arrayBuffer()`) antes de simular la
// importación. En jsdom de CI ese `arrayBuffer()` no devuelve algo que
// `SubtleCrypto.digest` acepte (`ERR_INVALID_ARG_TYPE` real en CI, ver
// `expense-import-dialog-review-findings.test.tsx` / `-invalidation` /
// `-no-payment-method`, que mockean esto mismo por el mismo motivo) — sin
// este mock la simulación nunca resuelve y el badge "OK" jamás aparece.
vi.mock("@/lib/bank-statement-parser", () => ({
  hashFileSHA256: vi.fn().mockResolvedValue("hash-fixed-for-test"),
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

// ── importador-gastos-transaccional (task 8.10) ─────────────────────────────
//
// Este archivo ya mockea `BranchSelect`/`CostCenterSelect` a `() => null`
// (arriba, para los tests de `ExpenseForm`) — así que estos tests verifican
// lo que SÍ queda real en este entorno: `PaymentMethodSelect` y
// `BankAccountDestinationSelect` (sólo su hook `useBankAccounts` está
// mockeado, ya declarado arriba), más la estructura propia del diálogo.

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

describe("Accesibilidad — ExpenseImportDialog (task 8.10)", () => {
  it("el selector de forma de pago por defecto (PaymentMethodSelect real) es alcanzable por getByLabelText", () => {
    paymentMethodsMock = [PM_CASH]
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    expect(screen.getByLabelText(/forma de pago por defecto/i)).toBeInTheDocument()
  })

  it("el input de archivo tiene un label asociado (drop zone) alcanzable por getByLabelText", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    expect(screen.getByLabelText(/hacé clic o arrastrá tu archivo csv/i)).toBeInTheDocument()
  })

  it("los estados de fila del paso 2 se comunican por TEXTO (OK/Aviso/Error), no sólo por color", async () => {
    const { fireEvent, waitFor } = await import("@testing-library/react")
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const csv = ["Descripción;Categoría;Monto;Fecha", "Alquiler;Alquiler;1000;2026-05-01"].join("\n")
    const input = document.getElementById("csv-expense-upload") as HTMLInputElement
    fireEvent.change(input, { target: { files: [new File([csv], "gastos.csv", { type: "text/csv" })] } })

    // Esperar a que la simulación (mockeada al tope del archivo, sin
    // errores/avisos) RESUELVA y a que el badge concreto de la fila válida
    // se muestre — antes se aceptaba la alternancia
    // `/OK|Aviso|Error|Validando/i` contra TODO el body, que también pasa
    // con "Validando…" (el propio `StatusBadge` en loading) sin probar que
    // el estado final se comunica por texto.
    await waitFor(() => expect(screen.getByText("OK")).toBeInTheDocument())
    // El badge de estado por fila (paso 2) es texto real ("OK"), no un
    // cuadrito de color sin nombre accesible.
    expect(screen.getByText("OK")).toBeInTheDocument()
  })
})

/**
 * asiento-contable-gastos (task 9.8): el estado contable tiene nombre
 * accesible y el enlace al diario es alcanzable por teclado.
 */
describe("Accesibilidad — ExpenseJournalStatusBadge (task 9.8)", () => {
  it("el estado 'asentado' es un link con nombre accesible (Tab lo alcanza)", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" hasJournalEntry />)
    const link = screen.getByRole("link", { name: /asentado/i })
    // Un <a href> real es alcanzable por teclado sin tabIndex adicional —
    // se afirma la ausencia de tabIndex=-1, que lo sacaría del orden de tabulación.
    expect(link.getAttribute("tabindex")).not.toBe("-1")
    expect(link).toHaveAccessibleName(/asentado/i)
  })

  it("los estados 'pendiente' y 'sin asiento' tienen nombre accesible propio, sin prometer un enlace", () => {
    // Un <span> sin rol interactivo no "hereda" el texto visible como nombre
    // accesible (Name-from-content sólo aplica a roles como link/button): su
    // nombre accesible es el `title`, que además es MÁS descriptivo — dice
    // "se registra en unos minutos" en vez de sólo "pendiente". Se afirma que
    // el nombre accesible existe y comunica lo mismo que el texto visible.
    const { unmount } = render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    const pendiente = screen.getByText(/pendiente/i)
    expect(pendiente).toHaveAccessibleName(/en unos minutos/i)
    expect(pendiente.tagName).not.toBe("A")
    unmount()

    render(<ExpenseJournalStatusBadge expenseId="e1" />)
    const sinAsiento = screen.getByText(/sin asiento/i)
    expect(sinAsiento).toHaveAccessibleName(/anterior/i)
    expect(sinAsiento.tagName).not.toBe("A")
  })
})
