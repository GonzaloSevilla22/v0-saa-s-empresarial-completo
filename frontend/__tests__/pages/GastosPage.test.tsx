/**
 * /gastos — listado (gastos-forma-pago, grupo 11).
 *
 * El módulo Gastos no tenía NINGÚN test de pantalla. Lo que se fija acá:
 *
 *  11.0 el origen de datos es el hook paginado del backend (D18) y NO
 *       `usePaginatedQuery({ table: "expenses" })` — por PostgREST directo no
 *       hay camino de datos para el lock, que es un derivado de los libros y
 *       no una columna de `expenses`. Los tres filtros que ya existían
 *       (búsqueda, fechas, centro de costo) siguen funcionando, ahora
 *       server-side.
 *  11.1 badge de forma de pago con el nombre que resuelve el BACKEND, en las
 *       dos variantes (mobile y desktop).
 *  11.1b una forma de pago dada de baja conserva su nombre visible en los
 *       gastos históricos.
 *  11.2 filtro por forma de pago como query param server-side.
 *  11.3 lock visible: "Editar" y "Eliminar" deshabilitados CON LA RAZÓN,
 *       derivada de los mismos predicados que evalúa el servidor.
 *  11.4 el diálogo de borrado enumera qué libro se va a compensar.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Expense } from "@/lib/types"

// ── Estado del hook, controlable por test ───────────────────────────────────
let expensesFixture: Expense[] = []
const setSearchMock = vi.fn()
const setDateFromMock = vi.fn()
const setDateToMock = vi.fn()
const setCostCenterIdMock = vi.fn()
const setPaymentMethodIdMock = vi.fn()
const deleteExpenseMock = vi.fn().mockResolvedValue(undefined)
const setPageMock = vi.fn()

vi.mock("@/hooks/data/use-expenses-query", () => ({
  useExpenses: () => ({
    expenses: expensesFixture,
    meta: { page: 0, pageSize: 25, totalCount: expensesFixture.length, pageCount: 1, from: 1, to: expensesFixture.length },
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
    search: "", setSearch: setSearchMock,
    dateFrom: "", setDateFrom: setDateFromMock,
    dateTo: "", setDateTo: setDateToMock,
    costCenterId: null, setCostCenterId: setCostCenterIdMock,
    paymentMethodId: null, setPaymentMethodId: setPaymentMethodIdMock,
    clearFilters: vi.fn(),
    setPage: setPageMock,
    setPageSize: vi.fn(),
    addExpense: vi.fn(), updateExpense: vi.fn(), deleteExpense: deleteExpenseMock,
    addExpenseMutation: { isPending: false },
    updateExpenseMutation: { isPending: false },
    deleteExpenseMutation: { isPending: false, mutateAsync: deleteExpenseMock },
  }),
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: vi.fn() }),
  useDeleteExpense: () => ({ mutateAsync: deleteExpenseMock }),
}))

// El listado NO debe seguir leyendo por PostgREST: si alguien vuelve a
// enchufar usePaginatedQuery, este mock lo delata (test 11.0).
const usePaginatedQueryMock = vi.fn(() => ({
  data: [], loading: false, error: null, search: "", setSearch: vi.fn(),
  dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
  clearFilters: vi.fn(), refetch: vi.fn(), setPage: vi.fn(), setPageSize: vi.fn(),
  meta: { page: 0, pageSize: 25, totalCount: 0, pageCount: 1, from: 0, to: 0 },
}))
vi.mock("@/hooks/use-paginated-query", () => ({
  usePaginatedQuery: (...args: unknown[]) => usePaginatedQueryMock(...(args as [])),
}))

vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false }) }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true }) }))
vi.mock("@/hooks/data/use-cost-centers", () => ({
  useCostCenters: () => ({ costCenters: [{ id: "cc-1", name: "Administración", code: "ADM" }] }),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({
  CostCenterSelect: ({ onChange }: { onChange: (v: string | null) => void }) => (
    <button type="button" data-testid="cc-filter" onClick={() => onChange("cc-1")}>centro</button>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ onChange, includeInactive }: { onChange: (v: string | null) => void; includeInactive?: boolean }) => (
    <button
      type="button"
      data-testid="pm-filter"
      data-include-inactive={includeInactive ? "true" : "false"}
      onClick={() => onChange("pm-transfer")}
    >
      forma de pago
    </button>
  ),
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/forms/expense-form-v2", () => ({ ExpenseForm: () => <div data-testid="expense-form" /> }))
vi.mock("@/components/gastos/expense-import-dialog", () => ({ ExpenseImportDialog: () => null }))
vi.mock("@/components/export/ExportButton", () => ({
  // El export por Edge Function (gateado por plan) es OTRO botón: se lo
  // distingue por nombre para no confundirlo con el CSV local de la página.
  ExportButton: () => <button type="button">Exportar gastos CSV</button>,
}))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
const exportToCSVMock = vi.fn()
vi.mock("@/lib/excel", () => ({ exportToCSV: (...args: unknown[]) => exportToCSVMock(...args) }))

import GastosPage from "@/app/(dashboard)/gastos/page"

const BASE: Expense = {
  id: "exp-1", date: "2026-08-20", category: "Servicios",
  description: "Luz de agosto", amount: 12000,
  paymentMethodId: "pm-cash", paymentMethodName: "Efectivo", paymentMethodKind: "cash",
  isPaymentLocked: false, hasCashMovement: false, hasBankMovement: false, isDeleteBlocked: false,
}

beforeEach(() => {
  vi.clearAllMocks()
  expensesFixture = [BASE]
})

// ── 11.0 ────────────────────────────────────────────────────────────────────

describe("/gastos — origen de datos (11.0, D18)", () => {
  it("NO lee por PostgREST: usePaginatedQuery no se monta más para expenses", () => {
    render(<GastosPage />)
    expect(usePaginatedQueryMock).not.toHaveBeenCalled()
  })

  it("renderiza las filas que devuelve el backend", () => {
    render(<GastosPage />)
    expect(screen.getAllByText("Luz de agosto").length).toBeGreaterThan(0)
  })

  it("los tres filtros que ya existían siguen funcionando, ahora server-side", async () => {
    const user = userEvent.setup()
    render(<GastosPage />)

    fireEvent.change(screen.getByPlaceholderText(/buscar descripci[oó]n/i), { target: { value: "luz" } })
    expect(setSearchMock).toHaveBeenCalledWith("luz")

    await user.click(screen.getByRole("button", { name: /filtrar fechas/i }))
    fireEvent.change(screen.getByLabelText(/desde/i), { target: { value: "2026-08-01" } })
    expect(setDateFromMock).toHaveBeenCalledWith("2026-08-01")
    fireEvent.change(screen.getByLabelText(/hasta/i), { target: { value: "2026-08-31" } })
    expect(setDateToMock).toHaveBeenCalledWith("2026-08-31")

    fireEvent.click(screen.getByTestId("cc-filter"))
    expect(setCostCenterIdMock).toHaveBeenCalledWith("cc-1")
  })
})

// ── 11.1 / 11.1b / 11.2 ─────────────────────────────────────────────────────

describe("/gastos — forma de pago (11.1, 11.1b, 11.2)", () => {
  it("muestra el badge con el nombre que resolvió el backend, en mobile y en desktop", () => {
    render(<GastosPage />)
    const badges = screen.getAllByTestId("payment-method-badge")
    // Las dos variantes del listado (la fila mobile y la desktop) se renderizan
    // siempre; la visibilidad la resuelve el breakpoint de Tailwind.
    expect(badges).toHaveLength(2)
    for (const b of badges) expect(b).toHaveTextContent("Efectivo")
  })

  it("un gasto sin imputar muestra 'Sin especificar', no una cápsula vacía", () => {
    expensesFixture = [{ ...BASE, paymentMethodId: null, paymentMethodName: null, paymentMethodKind: null }]
    render(<GastosPage />)
    for (const b of screen.getAllByTestId("payment-method-badge")) {
      expect(b).toHaveTextContent("Sin especificar")
    }
  })

  it("11.1b: una forma de pago dada de baja conserva su nombre visible, y el filtro la sigue ofreciendo", () => {
    expensesFixture = [{ ...BASE, paymentMethodName: "Cheque (dado de baja)" }]
    render(<GastosPage />)

    for (const b of screen.getAllByTestId("payment-method-badge")) {
      expect(b).toHaveTextContent("Cheque (dado de baja)")
    }
    // `includeInactive` es lo que sostiene el escenario: sin él, la forma
    // desaparecería del selector del filtro y el gasto histórico no sería
    // filtrable por la forma que efectivamente usó.
    expect(screen.getByTestId("pm-filter")).toHaveAttribute("data-include-inactive", "true")
  })

  it("11.2: el filtro por forma de pago va al hook (query param server-side)", () => {
    render(<GastosPage />)
    fireEvent.click(screen.getByTestId("pm-filter"))
    expect(setPaymentMethodIdMock).toHaveBeenCalledWith("pm-transfer")
  })
})

// ── 11.3 / 11.4 ─────────────────────────────────────────────────────────────

describe("/gastos — lock visible y borrado (11.3, 11.4)", () => {
  it("gasto sin dinero posteado: se puede editar y eliminar", () => {
    render(<GastosPage />)
    const rows = screen.getAllByTestId("expense-edit")
    for (const b of rows) expect(b).not.toBeDisabled()
    for (const b of screen.getAllByTestId("delete-operation-trigger")) expect(b).not.toBeDisabled()
  })

  it("11.3: con movimiento de caja, 'Editar' queda deshabilitado CON la razón (P0423 anticipado)", () => {
    expensesFixture = [{ ...BASE, isPaymentLocked: true, hasCashMovement: true }]
    render(<GastosPage />)

    const editar = screen.getAllByTestId("expense-edit")[0]
    expect(editar).toBeDisabled()
    expect(editar.getAttribute("aria-label") ?? "").toMatch(/caja|movimiento|no se puede editar/i)
  })

  it("11.3: con caja cerrada, 'Eliminar' queda deshabilitado CON la razón (P0426 anticipado)", () => {
    expensesFixture = [{ ...BASE, isPaymentLocked: true, hasCashMovement: true, isDeleteBlocked: true }]
    render(<GastosPage />)

    const blocked = screen.getAllByTestId("delete-operation-blocked")[0]
    expect(blocked).toBeDisabled()
    expect(blocked.getAttribute("aria-label") ?? "").toMatch(/caja/i)
  })

  it("CONTROL: el mismo gasto con la caja ABIERTA (isDeleteBlocked=false) sí se puede eliminar", () => {
    expensesFixture = [{ ...BASE, isPaymentLocked: true, hasCashMovement: true, isDeleteBlocked: false }]
    render(<GastosPage />)

    // Sin este control, un botón cableado a `disabled` pasaría el test anterior.
    expect(screen.queryAllByTestId("delete-operation-blocked")).toHaveLength(0)
    expect(screen.getAllByTestId("delete-operation-trigger").length).toBeGreaterThan(0)
  })

  it("11.4: el diálogo de borrado enumera qué libro se va a compensar", async () => {
    const user = userEvent.setup()
    expensesFixture = [{ ...BASE, hasCashMovement: true, hasBankMovement: true }]
    render(<GastosPage />)

    await user.click(screen.getAllByTestId("delete-operation-trigger")[0])

    const dialog = await screen.findByRole("alertdialog")
    expect(within(dialog).getByText(/se va a compensar/i)).toBeInTheDocument()
    expect(within(dialog).getByText(/caja/i)).toBeInTheDocument()
    expect(within(dialog).getByText(/bancario/i)).toBeInTheDocument()
  })

  it("11.4: sin dinero posteado el diálogo confirma sin enumerar nada", async () => {
    const user = userEvent.setup()
    render(<GastosPage />)

    await user.click(screen.getAllByTestId("delete-operation-trigger")[0])

    const dialog = await screen.findByRole("alertdialog")
    expect(within(dialog).queryByText(/se va a compensar/i)).not.toBeInTheDocument()
  })
})

// ── 11.5 ────────────────────────────────────────────────────────────────────

describe("/gastos — export local (11.5)", () => {
  it("el CSV local incluye la columna Forma de pago, con el mismo nombre que el badge", async () => {
    const user = userEvent.setup()
    expensesFixture = [BASE, { ...BASE, id: "exp-2", paymentMethodName: null }]
    render(<GastosPage />)

    await user.click(screen.getByRole("button", { name: /^exportar$/i }))

    expect(exportToCSVMock).toHaveBeenCalled()
    const [rows, columns] = exportToCSVMock.mock.calls[0] as [Record<string, unknown>[], { key: string; header: string }[]]
    expect(columns.map((c) => c.header)).toEqual(["Fecha", "Categoría", "Descripción", "Forma de pago", "Monto"])
    expect(rows[0].paymentMethodName).toBe("Efectivo")
    // El gasto sin imputar exporta el mismo literal que muestra el badge, no
    // una celda vacía que después nadie sabe leer.
    expect(rows[1].paymentMethodName).toBe("Sin especificar")
  })
})
