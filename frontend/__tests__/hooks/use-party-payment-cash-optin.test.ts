/**
 * useRegisterPayment (cliente) / useRegisterPaymentMade (proveedor) —
 * passthrough de cashSessionId al body y las invalidaciones de caja tras el
 * cobro/pago — caja-compras-cobranzas (task 8.2/11.4 RED->GREEN).
 *
 * Mock: @/lib/api/python-client (mismo molde que use-purchases-cash-optin.test.ts)
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useRegisterPayment } from "@/hooks/data/use-customer-account"
import { useRegisterPaymentMade } from "@/hooks/data/use-supplier-account"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const CASH_SESSION_ID = "session-1234"

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
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({
    payment_id: "pay-1", customer_account_id: "ca-1", balance_after: "600.00", replayed: false, operation_id: "op-1",
  })
})

describe("useRegisterPayment — passthrough de cashSessionId (D2)", () => {
  it("manda cash_session_id en el body cuando se informa", async () => {
    const { wrapper } = makeWrapperWithClient()
    const { result } = renderHook(() => useRegisterPayment("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "k1", amount: 400, paymentMethodId: "pm-cash", cashSessionId: CASH_SESSION_ID,
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBe(CASH_SESSION_ID)
  })

  it("sin cashSessionId, el body no incluye la clave (contrato retrocompatible)", async () => {
    const { wrapper } = makeWrapperWithClient()
    const { result } = renderHook(() => useRegisterPayment("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ idempotencyKey: "k1", amount: 400, paymentMethodId: "pm-cash" })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("cash_session_id" in body).toBe(false)
  })

  it("invalida cashSessions y cashMovements además de customerAccounts (task 11.4)", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useRegisterPayment("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "k1", amount: 400, paymentMethodId: "pm-cash", cashSessionId: CASH_SESSION_ID,
      })
    })

    const keys = spy.mock.calls.map((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0])
    expect(keys).toContain("customerAccounts")
    expect(keys).toContain("cashSessions")
    expect(keys).toContain("cashMovements")
  })
})

describe("useRegisterPaymentMade — passthrough de cashSessionId (D5, espejo)", () => {
  beforeEach(() => {
    ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({
      payment_id: "pay-2", supplier_account_id: "sa-1", balance_after: "600.00", replayed: false, operation_id: "op-2",
    })
  })

  it("manda cash_session_id en el body cuando se informa", async () => {
    const { wrapper } = makeWrapperWithClient()
    const { result } = renderHook(() => useRegisterPaymentMade("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "k1", amount: 400, paymentMethodId: "pm-cash", cashSessionId: CASH_SESSION_ID,
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cash_session_id).toBe(CASH_SESSION_ID)
  })

  it("invalida cashSessions y cashMovements además de supplierAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useRegisterPaymentMade("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "k1", amount: 400, paymentMethodId: "pm-cash", cashSessionId: CASH_SESSION_ID,
      })
    })

    const keys = spy.mock.calls.map((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0])
    expect(keys).toContain("supplierAccounts")
    expect(keys).toContain("cashSessions")
    expect(keys).toContain("cashMovements")
  })
})
