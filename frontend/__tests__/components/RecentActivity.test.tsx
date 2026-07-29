/**
 * Tests for `RecentActivity` (components/dashboard/recent-activity.tsx),
 * task 1.10 of `v4-visual-3d-refresh` Fase A: apply the "entrada de listas"
 * 2D micro-animation (components/motion/MotionList) to the dashboard's
 * combined sales/expenses feed — classified `2d-motion` in
 * `frontend/docs/surface-matrix.md`.
 *
 * `useSales`/`useExpenses` are mocked (data hooks, not touched by this
 * task — task 1.10 forbids touching handlers/queries/mutations). The
 * existing-render assertions are the safety net; the motion assertions
 * follow the settled-state approach from FadeIn.test.tsx/MotionList.test.tsx.
 *
 * Cycle: RED (rows aren't animated yet) → GREEN → TRIANGULATE (existing
 * content still renders + new animation settles for multiple rows) →
 * REFACTOR.
 */

import { describe, it, expect, vi } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import type { Sale, Expense } from "@/lib/types"

const salesMock = vi.fn()
const expensesMock = vi.fn()

vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => salesMock(),
}))
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useExpenses: () => expensesMock(),
}))

const SALE: Sale = {
  id: "sale-1",
  date: "2026-07-29",
  productId: "p1",
  productName: "Remera",
  clientId: "c1",
  clientName: "Juana Perez",
  quantity: 2,
  unitPrice: 500,
  total: 1000,
  currency: "ARS",
}

const EXPENSE: Expense = {
  id: "exp-1",
  date: "2026-07-28",
  category: "Alquiler",
  description: "Alquiler local",
  amount: 300,
}

function setupHooks() {
  salesMock.mockReturnValue({ sales: [SALE] })
  expensesMock.mockReturnValue({ expenses: [EXPENSE] })
}

describe("RecentActivity", () => {
  it("still renders the combined sales/expenses feed (task 1.10 must not touch data hooks)", () => {
    setupHooks()
    render(<RecentActivity />)

    expect(screen.getByText("Remera x2")).toBeInTheDocument()
    expect(screen.getByText("Alquiler local")).toBeInTheDocument()
  })

  // ── RED/GREEN + TRIANGULATE: entrance animation settles for every row ──
  it("settles every activity row fully visible (entrada de listas, task 1.10)", async () => {
    setupHooks()
    render(<RecentActivity />)

    await waitFor(
      () => {
        expect(screen.getByText("Remera x2").closest('[style*="opacity"]')).toHaveStyle({
          opacity: "1",
        })
        expect(screen.getByText("Alquiler local").closest('[style*="opacity"]')).toHaveStyle({
          opacity: "1",
        })
      },
      { timeout: 2000 }
    )
  })
})
