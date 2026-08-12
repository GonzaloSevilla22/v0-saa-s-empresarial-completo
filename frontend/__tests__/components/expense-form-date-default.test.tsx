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
