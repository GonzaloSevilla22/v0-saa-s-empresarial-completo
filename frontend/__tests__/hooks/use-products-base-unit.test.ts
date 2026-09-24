/**
 * ventas-unidades-conversion (D10): `base_unit_id` viaja de punta a punta por
 * el hook — hasta este change no se mapeaba en la lectura (el catálogo mostraba
 * "uds" para todo y el selector nunca conocía la unidad del producto) ni se
 * enviaba en el alta/edición (el formulario la mandaba y se perdía acá).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useProducts } from "@/hooks/data/use-products"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"

const ROW = {
  id: "prod-kg",
  user_id: "user-1",
  name: "Tomate",
  category: "Verdulería",
  price: "1000",
  cost: "600",
  stock: "0.55",
  min_stock: 0.5,
  barcode: null,
  sku: "TOM-001",
  is_variant: false,
  stock_control_type: "tracked",
  created_at: "2026-09-24T00:00:00Z",
  base_unit_id: "u-kg",
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

describe("useProducts — base_unit_id", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("mapea base_unit_id → baseUnitId en la lectura (y undefined si falta)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([ROW, { ...ROW, id: "prod-none", base_unit_id: null }])
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.products).toHaveLength(2))
    expect(result.current.products[0].baseUnitId).toBe("u-kg")
    expect(result.current.products[0].minStock).toBe(0.5)
    expect(result.current.products[1].baseUnitId).toBeUndefined()
  })

  it("el alta envía base_unit_id (null cuando el producto no tiene unidad base)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValue(ROW)
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addProduct({
        name: "Tomate", category: "Verdulería", price: 1000, cost: 600, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
      })
    })
    expect(vi.mocked(pythonClient.post).mock.calls[0][1]).toMatchObject({ base_unit_id: "u-kg", min_stock: 0.5 })

    await act(async () => {
      await result.current.addProduct({
        name: "Bolsa", category: "Otros", price: 10, cost: 5, margin: 50,
        stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked",
      })
    })
    expect(vi.mocked(pythonClient.post).mock.calls[1][1]).toMatchObject({ base_unit_id: null })
  })

  it("la edición manda siempre el estado vigente: uuid asigna, ausencia desasigna", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.put).mockResolvedValue(ROW)
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.updateProduct({
        id: "prod-kg", name: "Tomate", category: "Verdulería", price: 1000, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
      })
    })
    expect(vi.mocked(pythonClient.put).mock.calls[0][1]).toMatchObject({ base_unit_id: "u-kg" })

    await act(async () => {
      await result.current.updateProduct({
        id: "prod-kg", name: "Tomate", category: "Verdulería", price: 1000, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked",
      })
    })
    expect(vi.mocked(pythonClient.put).mock.calls[1][1]).toMatchObject({ base_unit_id: null })
  })
})
