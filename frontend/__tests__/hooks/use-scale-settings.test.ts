/**
 * balanza-etiquetas-pos (task 6.1) — RED→GREEN de `useScaleSettings` /
 * `useUpdateScaleSettings`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider, focusManager } from "@tanstack/react-query"
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
import { useScaleSettings, useUpdateScaleSettings } from "@/hooks/data/use-scale-settings"
import { queryKeys } from "@/lib/query-keys"
import { FACTORY_SCALE_SETTINGS, type ScaleSettings } from "@/lib/scale-layout"

const VALID_SETTINGS: ScaleSettings = {
  enabled: true,
  layouts: [
    { kind: "weighed", enabled: true, segments: [{ field: "fixed", digits: 2, value: "20" }, { field: "plu", digits: 4 }, { field: "amount", digits: 6, decimals: 2 }] },
    { kind: "unit", enabled: true, segments: [{ field: "fixed", digits: 2, value: "21" }, { field: "plu", digits: 4 }, { field: "amount", digits: 6, decimals: 2 }] },
    { kind: "multi", enabled: true, segments: [{ field: "fixed", digits: 2, value: "22" }, { field: "ignored", digits: 2 }, { field: "ignored", digits: 8 }] },
  ],
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const invalidate = vi.spyOn(queryClient, "invalidateQueries")
  return {
    queryClient,
    invalidate,
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
  }
}

beforeEach(() => vi.clearAllMocks())

describe("useScaleSettings", () => {
  it("GET /scale-settings y lo mapea a ScaleSettings", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(VALID_SETTINGS)
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useScaleSettings(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.settings).toEqual(VALID_SETTINGS)
    expect(pythonClient.get).toHaveBeenCalledWith("/scale-settings")
  })

  it("RED→GREEN: una respuesta inválida cae a FACTORY_SCALE_SETTINGS sin romper", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({ garbage: true })
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useScaleSettings(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.settings).toEqual(FACTORY_SCALE_SETTINGS)
  })

  it("TRIANGULATE: null también cae a FACTORY_SCALE_SETTINGS", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(null)
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useScaleSettings(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.settings).toEqual(FACTORY_SCALE_SETTINGS)
  })

  it("la query se configura con staleTime corto y refetch al volver el foco / montar", () => {
    const { Wrapper, queryClient } = makeWrapper()
    vi.mocked(pythonClient.get).mockResolvedValue(VALID_SETTINGS)
    renderHook(() => useScaleSettings(), { wrapper: Wrapper })
    const query = queryClient.getQueryCache().find({ queryKey: queryKeys.scaleSettings.detail() })
    // `Query.options` se tipa como `QueryOptions` (sin los campos de
    // observer) aunque en runtime lleva todo lo que pasó `useQuery` — de ahí
    // el cast puntual sólo para esta aserción.
    const options = query?.options as { staleTime?: number; refetchOnWindowFocus?: boolean; refetchOnMount?: boolean } | undefined
    expect(options?.staleTime).toBe(30 * 1000)
    expect(options?.refetchOnWindowFocus).toBe(true)
    expect(options?.refetchOnMount).toBe(true)
  })

  it("REFACTOR (comportamiento real): un cambio del servidor se ve al volver el foco a la ventana", async () => {
    const realNow = Date.now.bind(Date)
    let offset = 0
    vi.spyOn(Date, "now").mockImplementation(() => realNow() + offset)

    vi.mocked(pythonClient.get)
      .mockResolvedValueOnce(VALID_SETTINGS)
      .mockResolvedValueOnce({ ...VALID_SETTINGS, enabled: false })

    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useScaleSettings(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.settings.enabled).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledTimes(1)

    // Avanza el reloj más allá del staleTime (30s) y simula que la ventana
    // recupera el foco (focusManager es el mecanismo oficial de TanStack
    // Query para esto en tests — más confiable que despachar un Event real).
    offset = 31_000
    act(() => {
      focusManager.setFocused(false)
      focusManager.setFocused(true)
    })

    await waitFor(() => expect(pythonClient.get).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(result.current.settings.enabled).toBe(false))

    focusManager.setFocused(undefined)
  })
})

describe("useUpdateScaleSettings", () => {
  it("PUT /scale-settings e invalida la query", async () => {
    vi.mocked(pythonClient.put).mockResolvedValueOnce(VALID_SETTINGS)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUpdateScaleSettings(), { wrapper: Wrapper })

    await act(async () => { await result.current.mutateAsync(VALID_SETTINGS) })

    expect(pythonClient.put).toHaveBeenCalledWith("/scale-settings", VALID_SETTINGS)
    expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.scaleSettings.all() })
  })

  it("si el backend rechaza (403 de un seller), la mutación falla y no invalida", async () => {
    vi.mocked(pythonClient.put).mockRejectedValueOnce(new Error("Sin permiso"))
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUpdateScaleSettings(), { wrapper: Wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync(VALID_SETTINGS)).rejects.toThrow("Sin permiso")
    })
    expect(invalidate).not.toHaveBeenCalled()
  })
})
