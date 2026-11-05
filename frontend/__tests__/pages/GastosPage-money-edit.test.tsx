/**
 * /gastos — superficie de la edición con dinero (edicion-operaciones-con-dinero, tanda C, 14.1/15.1). Espejo de
 * operations-list-money-edit para el listado de gastos:
 *
 *  · el lápiz de un gasto con dinero en la caja o el banco avisa que se va a ver qué se ajusta antes de guardar;
 *  · corregir dinero ya registrado es del dueño o un administrador (OQ-4): para otro rol "Editar" queda deshabilitado con el motivo,
 *    pero sólo si el gasto tiene dinero registrado;
 *  · cada gasto tiene su «Historial de cambios» (carga diferida).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import type { Expense } from "@/lib/types"

let expensesFixture: Expense[] = []
let rolesMock: string[] = ["owner"]
const historyMock = vi.fn()

vi.mock("@/hooks/data/use-operation-edit", () => ({
  useOperationEditHistory: (...a: unknown[]) => historyMock(...a),
}))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useExpenses: () => ({
    expenses: expensesFixture,
    meta: { page: 0, pageSize: 25, totalCount: expensesFixture.length, pageCount: 1, from: 1, to: expensesFixture.length },
    isLoading: false, isError: false, error: null, refetch: vi.fn(),
    search: "", setSearch: vi.fn(), dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(), paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(), setPage: vi.fn(), setPageSize: vi.fn(),
    addExpense: vi.fn(), updateExpense: vi.fn(), deleteExpense: vi.fn(),
    addExpenseMutation: { isPending: false }, updateExpenseMutation: { isPending: false },
    deleteExpenseMutation: { isPending: false, mutateAsync: vi.fn() },
  }),
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: vi.fn() }),
  useDeleteExpense: () => ({ mutateAsync: vi.fn() }),
}))
vi.mock("@/hooks/use-paginated-query", () => ({ usePaginatedQuery: vi.fn() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false }) }))
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ isWriter: true, roles: rolesMock, rolesResolved: true }),
}))
vi.mock("@/hooks/data/use-cost-centers", () => ({ useCostCenters: () => ({ costCenters: [] }) }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null, BankAccountDestinationSelect: () => null }))
vi.mock("@/components/forms/expense-form-v2", () => ({ ExpenseForm: () => <div data-testid="expense-form" /> }))
vi.mock("@/components/gastos/expense-import-dialog", () => ({ ExpenseImportDialog: () => null }))
vi.mock("@/components/export/ExportButton", () => ({ ExportButton: () => null }))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/lib/excel", () => ({ exportToCSV: vi.fn() }))

import GastosPage from "@/app/(dashboard)/gastos/page"

const BASE: Expense = {
  id: "exp-1", date: "2026-08-20", category: "Servicios", description: "Luz de agosto", amount: 12000,
  paymentMethodId: "pm-cash", paymentMethodName: "Efectivo", paymentMethodKind: "cash",
  hasCashMovement: false, hasBankMovement: false, isDeleteBlocked: false,
}

const MONEY_HINT = /tiene dinero registrado/i
const ADMIN_REASON = /due[ñn]o o un administrador/i

function editButtons(): HTMLElement[] {
  return screen.getAllByTestId("expense-edit")
}

beforeEach(() => {
  vi.clearAllMocks()
  rolesMock = ["owner"]
  expensesFixture = [BASE]
  historyMock.mockReturnValue({ data: undefined, isLoading: false, isError: false, refetch: vi.fn() })
})

describe("/gastos — el lápiz de un gasto con dinero registrado", () => {
  it.each([
    ["caja", { hasCashMovement: true }],
    ["banco", { hasBankMovement: true }],
  ])("con dinero en %s: avisa en el título que se va a ver qué se ajusta, y queda habilitado", (_libro, over) => {
    expensesFixture = [{ ...BASE, ...over }]
    render(<GastosPage />)
    for (const b of editButtons()) {
      expect(b).not.toBeDisabled()
      expect(b.getAttribute("title")).toMatch(MONEY_HINT)
      expect(b.getAttribute("title")).toMatch(/antes de guardar/i)
    }
  })

  it("sin dinero registrado: sin aviso", () => {
    render(<GastosPage />)
    for (const b of editButtons()) expect(b.getAttribute("title") ?? "").not.toMatch(MONEY_HINT)
  })

  it("un rol sin la capacidad de corregir dinero (OQ-4) no puede editar un gasto con dinero: queda deshabilitado con el motivo", () => {
    rolesMock = ["cashier"]
    expensesFixture = [{ ...BASE, hasCashMovement: true }]
    render(<GastosPage />)
    for (const b of editButtons()) {
      expect(b).toBeDisabled()
      expect(b.getAttribute("title")).toMatch(ADMIN_REASON)
      expect(b.getAttribute("aria-label")).toMatch(ADMIN_REASON)
    }
  })

  it("ese mismo rol edita un gasto SIN dinero registrado", () => {
    rolesMock = ["cashier"]
    render(<GastosPage />)
    for (const b of editButtons()) expect(b).not.toBeDisabled()
  })

  it("el administrador sí puede corregir dinero", () => {
    rolesMock = ["admin"]
    expensesFixture = [{ ...BASE, hasBankMovement: true }]
    render(<GastosPage />)
    for (const b of editButtons()) expect(b).not.toBeDisabled()
  })
})

describe("/gastos — Historial de cambios", () => {
  it("cada gasto ofrece su historial, cerrado y sin consultar nada hasta que se abre", () => {
    render(<GastosPage />)
    expect(historyMock).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: /historial de cambios/i }))
    expect(historyMock).toHaveBeenLastCalledWith("expense", "exp-1", true)
  })

  it("dos gastos, dos historiales independientes", () => {
    expensesFixture = [BASE, { ...BASE, id: "exp-2", description: "Gas" }]
    render(<GastosPage />)
    const toggles = screen.getAllByRole("button", { name: /historial de cambios/i })
    expect(toggles).toHaveLength(2)
    fireEvent.click(toggles[1])
    expect(historyMock).toHaveBeenLastCalledWith("expense", "exp-2", true)
  })
})
