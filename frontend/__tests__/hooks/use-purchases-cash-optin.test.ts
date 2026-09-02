/**
 * usePurchases — passthrough de branch_id (D3, bug de la sucursal perdida)
 * y cash_session_id (D2, opt-in de caja) en el alta — caja-compras-cobranzas
 * (task 7.3/10.3 RED->GREEN).
 *
 * D3 es un bug preexistente medido en prod: 0 de 507 compras con branch_id
 * — el `meta` de addPurchaseOperation ya aceptaba `branchId` en su tipo,
 * pero el payload nunca lo incluía. Este test lo congela.
 *
 * Mock: @/lib/api/python-client (mismo molde que use-purchases-supplier.test.ts)
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { usePurchases } from "@/hooks/data/use-purchases"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const BRANCH_ID = "branch-1111"
const CASH_SESSION_ID = "session-2222"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

function makeWrapperWithClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
})

describe("usePurchases — passthrough de branch_id en el alta (D3)", () => {
  it("addPurchaseOperation manda branch_id en el body cuando el meta lo trae", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-09-01", description: "", orgId: "acc-1", branchId: BRANCH_ID },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.branch_id).toBe(BRANCH_ID)
  })

  it("sin branchId en el meta, el body manda NULL (compra sin sucursal, sin error — D3 scenario)", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-09-01", description: "", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.branch_id).toBeNull()
  })
})

describe("usePurchases — passthrough de cash_session_id en el alta (D2)", () => {
  it("addPurchaseOperation manda cash_session_id cuando el opt-in está tildado", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: {
          idempotencyKey: "k1", date: "2026-09-01", description: "", orgId: "acc-1",
          cashSessionId: CASH_SESSION_ID,
        },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBe(CASH_SESSION_ID)
  })

  it("sin cashSessionId en el meta, el body manda NULL (no-op, D2)", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-09-01", description: "", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBeNull()
  })
})

describe("usePurchases — invalida las query keys de caja tras crear una compra (task 10.5)", () => {
  it("addPurchaseOperation invalida cashSessions y cashMovements", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: {
          idempotencyKey: "k1", date: "2026-09-01", description: "", orgId: "acc-1",
          cashSessionId: CASH_SESSION_ID,
        },
      })
    })

    const keys = spy.mock.calls.map((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0])
    expect(keys).toContain("cashSessions")
    expect(keys).toContain("cashMovements")
  })
})
