/**
 * cobranzas-reverso (task 12.4): useReversePaymentReceived / useReversePaymentMade.
 *
 * DELETE /customer-accounts/payments/{id} y /supplier-accounts/payments/{id}
 * con motivo opcional por body; invalidan cuenta corriente + caja + banco +
 * KPIs del dashboard (task 12.3 — lección de compras-proveedor-cuenta-
 * corriente: invalidar en TODAS las mutaciones que postean en libros).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useReversePaymentReceived } from "@/hooks/data/use-customer-account"
import { useReversePaymentMade } from "@/hooks/data/use-supplier-account"

const REVERSAL_RESULT = {
  payment_id: "pay-1",
  reversed: true,
  account_movement_id: "mov-1",
  cash_reversal_id: "cash-1",
  bank_reversals: 0,
}

function makeWrapperAndClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

describe("useReversePaymentReceived", () => {
  beforeEach(() => vi.clearAllMocks())

  it("invoca DELETE /customer-accounts/payments/{id} con el motivo en el body", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(REVERSAL_RESULT)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useReversePaymentReceived("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1", reason: "cobro duplicado" })
    })

    expect(pythonClient.delete).toHaveBeenCalledWith(
      "/customer-accounts/payments/pay-1",
      { reason: "cobro duplicado" },
    )
  })

  it("sin motivo, el body lleva reason: null (no lo omite)", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(REVERSAL_RESULT)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useReversePaymentReceived("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1" })
    })

    expect(pythonClient.delete).toHaveBeenCalledWith(
      "/customer-accounts/payments/pay-1",
      { reason: null },
    )
  })

  it("al confirmar, invalida cuenta corriente + caja + banco + KPIs del dashboard", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(REVERSAL_RESULT)
    const { wrapper, queryClient } = makeWrapperAndClient()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useReversePaymentReceived("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1" })
    })

    const invalidatedKeys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(invalidatedKeys).toEqual(
      expect.arrayContaining([
        JSON.stringify(["customerAccounts", "client", "client-1"]),
        JSON.stringify(["cashSessions"]),
        JSON.stringify(["cashMovements"]),
        JSON.stringify(["bankAccounts"]),
        JSON.stringify(["dashboardKpiSummary"]),
      ]),
    )
  })

  it("propaga el error del servidor (p.ej. P0426 humanizado por el caller)", async () => {
    vi.mocked(pythonClient.delete).mockRejectedValueOnce(new Error("no_open_session_for_reversal"))
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useReversePaymentReceived("client-1"), { wrapper })

    await expect(
      act(async () => {
        await result.current.mutateAsync({ paymentId: "pay-1" })
      }),
    ).rejects.toThrow("no_open_session_for_reversal")
  })
})

describe("useReversePaymentMade", () => {
  beforeEach(() => vi.clearAllMocks())

  it("invoca DELETE /supplier-accounts/payments/{id}", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(REVERSAL_RESULT)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useReversePaymentMade("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1", reason: "pago duplicado" })
    })

    expect(pythonClient.delete).toHaveBeenCalledWith(
      "/supplier-accounts/payments/pay-1",
      { reason: "pago duplicado" },
    )
  })

  it("al confirmar, invalida cuenta corriente de proveedor + caja + banco + KPIs", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(REVERSAL_RESULT)
    const { wrapper, queryClient } = makeWrapperAndClient()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useReversePaymentMade("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1" })
    })

    const invalidatedKeys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(invalidatedKeys).toEqual(
      expect.arrayContaining([
        JSON.stringify(["supplierAccounts", "supplier", "supplier-1"]),
        JSON.stringify(["cashSessions"]),
        JSON.stringify(["cashMovements"]),
        JSON.stringify(["bankAccounts"]),
        JSON.stringify(["dashboardKpiSummary"]),
      ]),
    )
  })
})
