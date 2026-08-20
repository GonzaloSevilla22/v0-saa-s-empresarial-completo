/**
 * useQuickSale — passthrough de payment_method_id (pos-catalogo-pagos, task 5.1)
 * Espejo de use-sales-payment-method.test.ts.
 *
 * Ciclo: RED → GREEN
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useQuickSale, type QuickSaleInput } from "@/hooks/data/use-sales-orders"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:  vi.fn(),
    post: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const PM_ID      = "pm-cash-1"
const PRODUCT_ID = "prod-1"

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

function basePayload(overrides: Partial<QuickSaleInput> = {}): QuickSaleInput {
  return {
    idempotency_key: "idem-1",
    items: [{ product_id: PRODUCT_ID, quantity: 1, price: 100, subtotal: 100 }],
    payment_method: "other",
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({
    sales_order_id: "so-1",
    operation_id: "op-1",
    total: 100,
    fiscal_doc_id: null,
    replayed: false,
  })
})

describe("useQuickSale — payload de payment_method_id", () => {
  it("con payment_method_id lo incluye en el body del POST", async () => {
    const { result } = renderHook(() => useQuickSale(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.mutateAsync(
        basePayload({ payment_method: "cash", payment_method_id: PM_ID, cash_session_id: "sess-1" }),
      )
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.payment_method_id).toBe(PM_ID)
    expect(body.payment_method).toBe("cash")
  })

  it("sin método elegido cae al camino legacy con payment_method_id ausente/null", async () => {
    const { result } = renderHook(() => useQuickSale(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.mutateAsync(basePayload())
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.payment_method_id ?? null).toBeNull()
  })

  it("idempotency_key viaja por el header, no en el body", async () => {
    const { result } = renderHook(() => useQuickSale(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.mutateAsync(basePayload({ payment_method_id: PM_ID }))
    })

    const [, body, headers] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("idempotency_key" in body).toBe(false)
    expect(headers).toMatchObject({ "Idempotency-Key": "idem-1" })
  })
})
