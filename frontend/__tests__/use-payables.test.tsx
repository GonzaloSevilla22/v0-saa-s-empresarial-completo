/**
 * cobranzas-vencimientos (tasks 8.5/8.6) — hooks del lado por pagar y
 * REGRESIÓN de invalidación: registrar/anular un pago a proveedor (y crear
 * una compra a crédito) debe invalidar también las claves de `payables` —
 * la Etapa A sólo cableó las de `receivables`, y sin esto la pestaña
 * "Por pagar" quedaría mostrando deuda ya pagada.
 *
 * Run: pnpm vitest run __tests__/use-payables.test.tsx
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { mockGet, mockPost, mockDelete } = vi.hoisted(() => ({
  mockGet: vi.fn(),
  mockPost: vi.fn(),
  mockDelete: vi.fn(),
}))

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: mockGet, post: mockPost, delete: mockDelete },
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }),
}))

import { usePayables, usePayablesSummary } from "@/hooks/data/use-payables"
import {
  useRegisterPaymentMade,
  useReversePaymentMade,
} from "@/hooks/data/use-supplier-account"
import { queryKeys } from "@/lib/query-keys"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")
  function Wrapper({ children }: { children: React.ReactNode }) {
    return React.createElement(QueryClientProvider, { client: queryClient }, children)
  }
  return { Wrapper, invalidateSpy }
}

beforeEach(() => {
  mockGet.mockReset()
  mockPost.mockReset()
  mockDelete.mockReset()
})

describe("usePayables (task 8.5)", () => {
  it("consulta /reports/payables con bucket y mapea al dominio", async () => {
    mockGet.mockResolvedValueOnce({
      items: [
        {
          supplier_id: "s1",
          supplier_name: "Proveedor Uno",
          balance: "800.00",
          overdue_total: "500.00",
          amount_current: "0",
          amount_overdue_1_30: "500.00",
          amount_overdue_31_60: "0",
          amount_overdue_60_plus: "0",
          amount_no_due_date: "300.00",
          oldest_due_date: "2026-08-23",
          days_overdue_max: 10,
        },
      ],
      total: 1,
      page: 0,
      pages: 1,
    })
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(
      () => usePayables({ bucket: "overdue" }),
      { wrapper: Wrapper },
    )

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(mockGet).toHaveBeenCalledWith(
      expect.stringContaining("/reports/payables?"),
    )
    expect(mockGet.mock.calls[0][0]).toContain("bucket=overdue")
    const row = result.current.data!.items[0]
    expect(row.supplierName).toBe("Proveedor Uno")
    expect(row.overdueTotal).toBe(500)
    expect(row.daysOverdueMax).toBe(10)
  })

  it("sin bucket no manda el parámetro", async () => {
    mockGet.mockResolvedValueOnce({ items: [], total: 0, page: 0, pages: 0 })
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => usePayables(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(mockGet.mock.calls[0][0]).not.toContain("bucket=")
  })
})

describe("usePayablesSummary (task 8.5)", () => {
  it("mapea el resumen con overdue_total", async () => {
    mockGet.mockResolvedValueOnce({
      total_payable: "800.00",
      overdue_total: "500.00",
      creditor_count: 1,
    })
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => usePayablesSummary(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual({
      totalPayable: 800,
      overdueTotal: 500,
      creditorCount: 1,
    })
  })
})

describe("invalidación de payables (task 8.6 — REGRESIÓN)", () => {
  it("registrar un pago a proveedor invalida payables.*", async () => {
    mockPost.mockResolvedValueOnce({
      payment_id: "p1",
      supplier_account_id: "sa1",
      balance_after: "300",
      replayed: false,
      operation_id: null,
    })
    const { Wrapper, invalidateSpy } = makeWrapper()
    const { result } = renderHook(() => useRegisterPaymentMade("s1"), {
      wrapper: Wrapper,
    })

    await result.current.mutateAsync({ idempotencyKey: "idem-1", amount: 500 })

    const keys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(keys).toContain(JSON.stringify(queryKeys.payables.all()))
  })

  it("anular un pago a proveedor invalida payables.*", async () => {
    mockDelete.mockResolvedValueOnce({
      payment_id: "p1",
      reversed: true,
      account_movement_id: "m1",
      cash_reversal_id: null,
      bank_reversals: 0,
    })
    const { Wrapper, invalidateSpy } = makeWrapper()
    const { result } = renderHook(() => useReversePaymentMade("s1"), {
      wrapper: Wrapper,
    })

    await result.current.mutateAsync({ paymentId: "p1" })

    const keys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(keys).toContain(JSON.stringify(queryKeys.payables.all()))
  })
})
