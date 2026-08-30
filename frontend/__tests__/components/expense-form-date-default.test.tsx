import { describe, it, expect, vi, afterEach } from "vitest"
import { render } from "@testing-library/react"
import { ExpenseForm } from "@/components/forms/expense-form-v2"

// app-timezone-argentina, task 2.3: mismo default/`max` de fecha en
// ExpenseForm (expense-form-v2.tsx).

vi.mock("@/hooks/data/use-expenses-query", () => ({
  useAddExpense: () => ({ mutateAsync: vi.fn() }),
  useUpdateExpense: () => ({ mutateAsync: vi.fn() }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
// gastos-forma-pago (safety net D15): el formulario ahora monta el selector de
// forma de pago, el de cuenta bancaria y el bloque de opt-in de caja. Se suman
// SOLO los mocks de esos hooks — sin ellos el import real de use-payment-methods
// dispara el throw de arranque de python-client (NEXT_PUBLIC_BACKEND_URL no
// definida en el entorno de test). NINGUNA aserción de este archivo cambia: lo
// que verifica sigue siendo el <input type="date">.
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))

describe("ExpenseForm — fecha por defecto (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART defaultea a HOY (día D), no a mañana (día UTC D+1)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    const { container } = render(<ExpenseForm onSuccess={() => {}} />)
    const dateInput = container.querySelector('input[type="date"]') as HTMLInputElement
    expect(dateInput.value).toBe("2026-06-08")
    expect(dateInput.max).toBe("2026-06-08")
  })
})
