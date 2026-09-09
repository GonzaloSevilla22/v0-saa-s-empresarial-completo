/**
 * cobranzas-vencimientos OQ-1 — useUpdateCustomerChargeDueDate /
 * useUpdateSupplierChargeDueDate.
 *
 * PATCH /customer-accounts/{clientId}/movements/{movementId}/due-date y
 * /supplier-accounts/{supplierId}/movements/{movementId}/due-date, con
 * due_date=null limpiando el vencimiento; invalida la cuenta corriente y
 * receivables/payables (el vencimiento reordena el aging FIFO).
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
    patch: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useUpdateCustomerChargeDueDate } from "@/hooks/data/use-customer-account"
import { useUpdateSupplierChargeDueDate } from "@/hooks/data/use-supplier-account"

const DUE_DATE_RESULT = {
  movement_id: "mov-1",
  due_date: "2026-10-15",
  previous_due_date: "2026-08-06",
}

function makeWrapperAndClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

describe("useUpdateCustomerChargeDueDate", () => {
  beforeEach(() => vi.clearAllMocks())

  it("invoca PATCH /customer-accounts/{clientId}/movements/{movementId}/due-date con due_date ISO", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValueOnce(DUE_DATE_RESULT)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useUpdateCustomerChargeDueDate("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        movementId: "mov-1", dueDate: "2026-10-15", reason: "corrección",
      })
    })

    expect(pythonClient.patch).toHaveBeenCalledWith(
      "/customer-accounts/client-1/movements/mov-1/due-date",
      { due_date: "2026-10-15", reason: "corrección" },
    )
  })

  it("dueDate=null viaja como null (limpia el vencimiento, no es un error)", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValueOnce({ ...DUE_DATE_RESULT, due_date: null })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useUpdateCustomerChargeDueDate("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ movementId: "mov-1", dueDate: null })
    })

    expect(pythonClient.patch).toHaveBeenCalledWith(
      "/customer-accounts/client-1/movements/mov-1/due-date",
      { due_date: null, reason: null },
    )
  })

  it("al confirmar, invalida la cuenta corriente del cliente y receivables", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValueOnce(DUE_DATE_RESULT)
    const { wrapper, queryClient } = makeWrapperAndClient()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useUpdateCustomerChargeDueDate("client-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ movementId: "mov-1", dueDate: "2026-10-15" })
    })

    const invalidatedKeys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(invalidatedKeys).toEqual(
      expect.arrayContaining([
        JSON.stringify(["customerAccounts", "client", "client-1"]),
        JSON.stringify(["receivables"]),
      ]),
    )
  })

  it("propaga el error del servidor (p.ej. cargo saldado, P0400 humanizado por el caller)", async () => {
    vi.mocked(pythonClient.patch).mockRejectedValueOnce(new Error("charge_fully_settled"))
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useUpdateCustomerChargeDueDate("client-1"), { wrapper })

    await expect(
      act(async () => {
        await result.current.mutateAsync({ movementId: "mov-1", dueDate: "2026-10-15" })
      }),
    ).rejects.toThrow("charge_fully_settled")
  })
})

describe("useUpdateSupplierChargeDueDate", () => {
  beforeEach(() => vi.clearAllMocks())

  it("invoca PATCH /supplier-accounts/{supplierId}/movements/{movementId}/due-date", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValueOnce(DUE_DATE_RESULT)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useUpdateSupplierChargeDueDate("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        movementId: "mov-1", dueDate: "2026-10-20", reason: "ajuste",
      })
    })

    expect(pythonClient.patch).toHaveBeenCalledWith(
      "/supplier-accounts/supplier-1/movements/mov-1/due-date",
      { due_date: "2026-10-20", reason: "ajuste" },
    )
  })

  it("al confirmar, invalida la cuenta corriente del proveedor y payables", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValueOnce(DUE_DATE_RESULT)
    const { wrapper, queryClient } = makeWrapperAndClient()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useUpdateSupplierChargeDueDate("supplier-1"), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ movementId: "mov-1", dueDate: "2026-10-20" })
    })

    const invalidatedKeys = invalidateSpy.mock.calls.map((c) => JSON.stringify(c[0]?.queryKey))
    expect(invalidatedKeys).toEqual(
      expect.arrayContaining([
        JSON.stringify(["supplierAccounts", "supplier", "supplier-1"]),
        JSON.stringify(["payables"]),
      ]),
    )
  })
})
