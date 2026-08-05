/**
 * usePurchases — filtro por centro de costo (cost-center-surface)
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 *
 * El listado de compras se pagina POR OPERACIÓN contra FastAPI, así que el
 * filtro tiene que viajar como query param `cost_center_id` y volver a la
 * página 0 — igual que las fechas.
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

const COST_CENTER_ID = "cc-1111"

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
})

describe("usePurchases — filtro por centro de costo", () => {
  it("sin filtro no manda cost_center_id", async () => {
    renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    expect(urls().every((u) => !u.includes("cost_center_id"))).toBe(true)
  })

  it("al seleccionar un centro lo manda como query param", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setCostCenterId(COST_CENTER_ID))

    await waitFor(() =>
      expect(urls().some((u) => u.includes(`cost_center_id=${COST_CENTER_ID}`))).toBe(true),
    )
  })

  it("TRIANGULATE: cambiar de centro vuelve a la página 0", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
      items: [], total: 200, page: 0, pages: 8,
    })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setPage(3))
    await waitFor(() => expect(result.current.meta.page).toBe(3))

    act(() => result.current.setCostCenterId(COST_CENTER_ID))

    await waitFor(() => expect(result.current.meta.page).toBe(0))
  })

  it("TRIANGULATE: el filtro se compone con el rango de fechas", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setDateFrom("2026-01-01"))
    act(() => result.current.setCostCenterId(COST_CENTER_ID))

    await waitFor(() => {
      const combined = urls().find(
        (u) => u.includes("date_from=2026-01-01") && u.includes(`cost_center_id=${COST_CENTER_ID}`),
      )
      expect(combined).toBeDefined()
    })
  })

  it("TRIANGULATE: volver a null deja de mandar el filtro", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setCostCenterId(COST_CENTER_ID))
    await waitFor(() =>
      expect(urls().some((u) => u.includes("cost_center_id"))).toBe(true),
    )

    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockClear()
    act(() => result.current.setCostCenterId(null))

    await waitFor(() => expect(result.current.costCenterId).toBeNull())
    // Volver a "Todos" no necesariamente refetchea (React Query sirve de caché
    // la query sin filtro que ya se había resuelto); lo que NO puede pasar es
    // que se siga pidiendo con el filtro puesto.
    await new Promise((r) => setTimeout(r, 30))
    expect(urls().some((u) => u.includes("cost_center_id"))).toBe(false)
  })

  it("clearFilters también limpia el centro de costo", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    act(() => result.current.setCostCenterId(COST_CENTER_ID))
    await waitFor(() => expect(result.current.costCenterId).toBe(COST_CENTER_ID))

    act(() => result.current.clearFilters())

    expect(result.current.costCenterId).toBeNull()
  })
})
