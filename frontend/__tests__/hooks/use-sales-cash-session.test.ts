/**
 * useSales — passthrough de cash_session_id en el alta (pagos-cableados-restantes,
 * OQ-C). Espejo de use-sales-payment-method.test.ts para el opt-in de caja.
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useSales } from "@/hooks/data/use-sales"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const SESSION_ID = "session-3333"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
})

describe("useSales — passthrough de cash_session_id en el alta (OQ-C)", () => {
  it("addSaleOperation con cashSessionId lo manda como cash_session_id en el body", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addSaleOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: {
          idempotencyKey: "k1", clientId: null, date: "2026-08-20", currency: "ARS", orgId: "acc-1",
          paymentMethodId: "pm-cash", cashSessionId: SESSION_ID,
        },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBe(SESSION_ID)
  })

  it("addSaleOperation sin cashSessionId manda cash_session_id null (D5: ausencia = no-op)", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addSaleOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: { idempotencyKey: "k2", clientId: null, date: "2026-08-20", currency: "ARS", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBeNull()
  })
})
