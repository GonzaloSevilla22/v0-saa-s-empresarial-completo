/**
 * TDD tests for useExpenses hook (C-18 frontend-decouple-datacontext)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 *
 * ── Safety net de `gastos-forma-pago` (D15, task 1.2b) ────────────────────
 * Este archivo es el safety net del hook que ese change reescribe. Cambiaron
 * DOS aserciones, las dos justificadas acá por escrito; el resto queda
 * intacto y la asercion de FONDO de cada una se conserva:
 *
 *  1. `returns mapped expenses when API responds` — el fixture pasa de lista
 *     plana al envelope `{items,total,page,pages}`. Es el BREAKING de API
 *     interna sancionado por D18/OQ-10: sin el envelope no hay forma de que
 *     `is_payment_locked` (derivado de cash_movements/bank_movements, NO una
 *     columna de `expenses`) llegue a cada fila del listado. Lo que el test
 *     verifica —que el hook mapea id/categoría/monto— no cambió.
 *  2. `addExpense calls POST /expenses …` — el payload suma los cuatro campos
 *     de imputación (`branch_id`, `payment_method_id`, `cash_session_id`,
 *     `bank_account_id`). `branch_id` en particular ES el bug pre-existente
 *     que el change cierra: el formulario lo mandaba y el hook lo descartaba
 *     (0 de 175 gastos de prod tienen sucursal). Se conserva la asercion de
 *     fondo: la URL, los campos originales y `cost_center_id: null` cuando no
 *     se informa.
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
    // gastos-forma-pago D18: envelope {items,total,page,pages} (ver cabecera).
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: mockExpenseRows, total: mockExpenseRows.length, page: 0, pages: 1,
    })

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
    expect(pythonClient.get).toHaveBeenCalledWith("/expenses?page=0&page_size=25")
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
    vi.mocked(pythonClient.get).mockResolvedValue({
      items: mockExpenseRows, total: mockExpenseRows.length, page: 0, pages: 1,
    })
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
      // gastos-forma-pago: los cuatro campos de imputación viajan siempre —
      // `branch_id` es el bug pre-existente que el change cierra.
      branch_id:         null,
      payment_method_id: null,
      cash_session_id:   null,
      bank_account_id:   null,
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
    vi.mocked(pythonClient.get).mockResolvedValue({
      items: mockExpenseRows, total: mockExpenseRows.length, page: 0, pages: 1,
    })
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
