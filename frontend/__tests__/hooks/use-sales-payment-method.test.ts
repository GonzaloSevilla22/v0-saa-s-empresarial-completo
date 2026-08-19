/**
 * useSales — filtro y passthrough de forma de pago (metodos-pago-operaciones)
 * Espejo de use-purchases-payment-method.test.ts / use-purchases-cost-center.test.ts.
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

const PM_ID = "pm-2222"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const urls = () => (pythonClient.get as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]))

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
  ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
})

describe("useSales — filtro por forma de pago", () => {
  it("sin filtro no manda payment_method_id", async () => {
    renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    expect(urls().every((u) => !u.includes("payment_method_id"))).toBe(true)
  })

  it("al seleccionar una forma de pago la manda como query param", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setPaymentMethodId(PM_ID))

    await waitFor(() =>
      expect(urls().some((u) => u.includes(`payment_method_id=${PM_ID}`))).toBe(true),
    )
  })

  it("clearFilters también limpia la forma de pago", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setPaymentMethodId(PM_ID))
    await waitFor(() => expect(result.current.paymentMethodId).toBe(PM_ID))

    act(() => result.current.clearFilters())

    expect(result.current.paymentMethodId).toBeNull()
  })
})

describe("useSales — passthrough de payment_method_id en alta/edición", () => {
  it("addSaleOperation manda payment_method_id en el body", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addSaleOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: { idempotencyKey: "k1", clientId: null, date: "2026-08-19", currency: "ARS", orgId: "acc-1", paymentMethodId: PM_ID },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.payment_method_id).toBe(PM_ID)
  })

  it("updateSaleOperation con paymentMethodId AUSENTE del meta no incluye la clave en el body (D5: preserva)", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updateSaleOperation({
        saleIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: { clientId: null, date: "2026-08-19", currency: "ARS", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("payment_method_id" in body).toBe(false)
  })

  it("updateSaleOperation con paymentMethodId=null EXPLÍCITO desimputa (D5)", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updateSaleOperation({
        saleIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: { clientId: null, date: "2026-08-19", currency: "ARS", orgId: "acc-1", paymentMethodId: null },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("payment_method_id" in body).toBe(true)
    expect(body.payment_method_id).toBeNull()
  })

  it("updateSaleOperation con paymentMethodId=uuid reimputa", async () => {
    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updateSaleOperation({
        saleIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 }],
        meta: { clientId: null, date: "2026-08-19", currency: "ARS", orgId: "acc-1", paymentMethodId: PM_ID },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.payment_method_id).toBe(PM_ID)
  })
})
