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

// ── review B (FE-1/OQ-5 A): passthrough tri-estado de cost_center_id en la
// edición de una OPERACIÓN de compra — espejo exacto del bloque análogo de
// use-purchases-supplier.test.ts para supplier_id. DB + backend ya aceptan
// el contrato (OQ-5 opción A, batch A de este mismo change); lo que faltaba
// era que updatePurchaseOperationMutation siquiera conociera la clave.
describe("usePurchases — passthrough tri-estado de cost_center_id en la edición (OQ-5)", () => {
  it("costCenterId AUSENTE del meta no incluye la clave en el body (preserva el vigente)", async () => {
    ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("cost_center_id" in body).toBe(false)
  })

  it("costCenterId=null EXPLÍCITO desimputa", async () => {
    ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1", costCenterId: null },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("cost_center_id" in body).toBe(true)
    expect(body.cost_center_id).toBeNull()
  })

  it("costCenterId=uuid reimputa", async () => {
    ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1", costCenterId: COST_CENTER_ID },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.cost_center_id).toBe(COST_CENTER_ID)
  })
})
