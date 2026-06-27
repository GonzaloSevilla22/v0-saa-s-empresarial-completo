/**
 * TDD tests for useExpenses hook (C-18 frontend-decouple-datacontext)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useExpenses } from "@/hooks/data/use-expenses-query"
import type { Expense } from "@/lib/types"

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ──────────────────────────────────────────────────────────────────

const mockExpenseRows = [
  {
    id: "exp-1",
    user_id: "user-1",
    category: "Alquiler",
    amount: "5000",
    description: "Alquiler enero",
    date: "2026-01-15",
    created_at: "2026-01-15T10:00:00Z",
  },
  {
    id: "exp-2",
    user_id: "user-1",
    category: "Servicios",
    amount: "1200",
    description: null,
    date: "2026-01-20",
    created_at: "2026-01-20T10:00:00Z",
  },
]

const expectedExpenses: Expense[] = [
  { id: "exp-1", date: "2026-01-15", category: "Alquiler", description: "Alquiler enero", amount: 5000 },
  { id: "exp-2", date: "2026-01-20", category: "Servicios", description: "", amount: 1200 },
]

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useExpenses", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // ── RED → GREEN: hook returns data correctly ─────────────────────────────
  it("returns mapped expenses when API responds", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(mockExpenseRows)

    const { result } = renderHook(() => useExpenses(), { wrapper: makeWrapper() })

    expect(result.current.isLoading).toBe(true)

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false)
    })

    expect(result.current.expenses).toHaveLength(2)
    expect(result.current.expenses[0]).toMatchObject({
      id:       "exp-1",
      category: "Alquiler",
      amount:   5000,
    })
    expect(pythonClient.get).toHaveBeenCalledWith("/expenses")
  })

  // ── TRIANGULATE: empty list ─────────────────────────────────────────────
  it("returns empty array when API returns no expenses", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])

    const { result } = renderHook(() => useExpenses(), { wrapper: makeWrapper() })

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false)
    })

    expect(result.current.expenses).toEqual([])
    expect(result.current.isError).toBe(false)
  })

  // ── RED → GREEN: addExpense invalidates cache ────────────────────────────
  it("addExpense calls POST /expenses and invalidates cache", async () => {
    // Initial list fetch
    vi.mocked(pythonClient.get).mockResolvedValue(mockExpenseRows)
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      id: "exp-3",
      user_id: "user-1",
      category: "Marketing",
      amount: "800",
      description: "Redes sociales",
      date: "2026-02-01",
      created_at: "2026-02-01T10:00:00Z",
    })

    const { result } = renderHook(() => useExpenses(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addExpense({
        date:        "2026-02-01",
        category:    "Marketing",
        description: "Redes sociales",
        amount:      800,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/expenses", {
      category:        "Marketing",
      description:     "Redes sociales",
      amount:          800,
      date:            "2026-02-01",
      // cost-center-dimension: null when not provided
      cost_center_id:  null,
    })
    // get should be called again after invalidation
    expect(pythonClient.get).toHaveBeenCalledTimes(2)
  })

  // ── TRIANGULATE: error 503 propagates as error state ────────────────────
  it("sets isError when API throws", async () => {
    vi.mocked(pythonClient.get).mockRejectedValueOnce(new Error("503 Service Unavailable"))

    const { result } = renderHook(() => useExpenses(), { wrapper: makeWrapper() })

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false)
    })

    expect(result.current.isError).toBe(true)
    expect(result.current.expenses).toEqual([])
  })

  // ── deleteExpense invalidates cache ─────────────────────────────────────
  it("deleteExpense calls DELETE /expenses/:id and re-fetches", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(mockExpenseRows)
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    const { result } = renderHook(() => useExpenses(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteExpense("exp-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/expenses/exp-1")
    expect(pythonClient.get).toHaveBeenCalledTimes(2)
  })
})
