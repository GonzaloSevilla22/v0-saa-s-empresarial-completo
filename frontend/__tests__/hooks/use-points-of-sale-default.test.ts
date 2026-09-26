/**
 * punto-venta-seleccion (tasks 3.3/3.4) — usePointsOfSale expone `isDefault`
 * y dos mutaciones nuevas para marcar / quitar el predeterminado de la cuenta,
 * que invalidan la lista (el diálogo de emisión y la configuración leen de ahí).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    patch:  vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import {
  usePointsOfSale,
  useSetDefaultPointOfSale,
  useClearDefaultPointOfSale,
} from "@/hooks/data/use-points-of-sale"
import { queryKeys } from "@/lib/query-keys"

const ROW = {
  id: "pv-9999",
  fiscal_profile_id: "fp-1",
  account_id: "acc-1",
  branch_id: null,
  numero: 9999,
  is_active: true,
  is_default: true,
  created_at: "2026-09-26T00:00:00Z",
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const invalidate = vi.spyOn(queryClient, "invalidateQueries")
  return {
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
    invalidate,
  }
}

beforeEach(() => vi.clearAllMocks())

describe("usePointsOfSale — isDefault", () => {
  it("mapea is_default → isDefault", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([ROW, { ...ROW, id: "pv-3", numero: 3, is_default: false }])
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => usePointsOfSale(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.pointsOfSale).toHaveLength(2))
    expect(result.current.pointsOfSale.map((p) => p.isDefault)).toEqual([true, false])
  })

  it("TRIANGULATE: una fila sin is_default (backend anterior a la migración) queda en false", async () => {
    const { is_default: _omit, ...legacy } = ROW
    vi.mocked(pythonClient.get).mockResolvedValueOnce([legacy])
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => usePointsOfSale(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.pointsOfSale).toHaveLength(1))
    expect(result.current.pointsOfSale[0].isDefault).toBe(false)
  })
})

describe("useSetDefaultPointOfSale", () => {
  it("POST /fiscal/points-of-sale/{id}/default e invalida la lista", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(ROW)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useSetDefaultPointOfSale(), { wrapper: Wrapper })

    let returned: Awaited<ReturnType<typeof result.current.mutateAsync>> | undefined
    await act(async () => { returned = await result.current.mutateAsync("pv-9999") })

    expect(pythonClient.post).toHaveBeenCalledWith("/fiscal/points-of-sale/pv-9999/default", {})
    expect(returned?.isDefault).toBe(true)
    expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.pointsOfSale.all() })
  })

  it("si el backend rechaza (404/403), la mutación falla y no invalida", async () => {
    vi.mocked(pythonClient.post).mockRejectedValueOnce(new Error("No encontrado"))
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useSetDefaultPointOfSale(), { wrapper: Wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync("pv-x")).rejects.toThrow("No encontrado")
    })
    expect(invalidate).not.toHaveBeenCalled()
  })
})

describe("useClearDefaultPointOfSale", () => {
  it("DELETE /fiscal/points-of-sale/default e invalida la lista", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useClearDefaultPointOfSale(), { wrapper: Wrapper })

    await act(async () => { await result.current.mutateAsync() })

    expect(pythonClient.delete).toHaveBeenCalledWith("/fiscal/points-of-sale/default")
    expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.pointsOfSale.all() })
  })
})
