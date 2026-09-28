/**
 * balanza-etiquetas-pos (task 6.2): `scale_plu` viaja de punta a punta por
 * `useProducts` con la misma regla tri-estado que `baseUnitId`/`cost` —
 * ausente en el `PUT` conserva, un número asigna, `null` desasigna.
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
  id: "prod-tomate",
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
  scale_plu: 261,
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

describe("useProducts — scale_plu (D2)", () => {
  beforeEach(() => vi.clearAllMocks())

  it("mapea scale_plu → scalePlu en la lectura (null si falta o es ausente)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([ROW, { ...ROW, id: "prod-sin-plu", scale_plu: null }])
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.products).toHaveLength(2))
    expect(result.current.products[0].scalePlu).toBe(261)
    expect(result.current.products[1].scalePlu).toBeNull()
  })

  it("TRIANGULATE: una base sin la migración (scale_plu ausente del todo) degrada a null, no rompe", async () => {
    const { scale_plu: _omit, ...legacyRow } = ROW
    vi.mocked(pythonClient.get).mockResolvedValue([legacyRow])
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.products).toHaveLength(1))
    expect(result.current.products[0].scalePlu).toBeNull()
  })

  it("el alta envía scale_plu (null cuando el producto no tiene código de balanza)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValue(ROW)
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addProduct({
        name: "Tomate", category: "Verdulería", price: 1000, cost: 600, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked", scalePlu: 261,
      })
    })
    expect(vi.mocked(pythonClient.post).mock.calls[0][1]).toMatchObject({ scale_plu: 261 })

    await act(async () => {
      await result.current.addProduct({
        name: "Bolsa", category: "Otros", price: 10, cost: 5, margin: 50,
        stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked",
      })
    })
    expect(vi.mocked(pythonClient.post).mock.calls[1][1]).toMatchObject({ scale_plu: null })
  })

  it("la edición es tri-estado por ausencia: un número asigna, la ausencia omite el campo (conserva)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.put).mockResolvedValue(ROW)
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.updateProduct({
        id: "prod-tomate", name: "Tomate", category: "Verdulería", price: 1000, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked", scalePlu: 261,
      })
    })
    expect(vi.mocked(pythonClient.put).mock.calls[0][1]).toMatchObject({ scale_plu: 261 })

    await act(async () => {
      await result.current.updateProduct({
        id: "prod-tomate", name: "Tomate", category: "Verdulería", price: 1000, margin: 40,
        stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked",
      })
    })
    expect(vi.mocked(pythonClient.put).mock.calls[1][1]).not.toHaveProperty("scale_plu")
  })

  it("TRIANGULATE: scalePlu null en la edición viaja como scale_plu: null (desasigna, no se omite)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.put).mockResolvedValue({ ...ROW, scale_plu: null })
    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.updateProduct({
        id: "prod-tomate", name: "Tomate", category: "Verdulería", price: 1000, margin: 40,
        stock: 0, minStock: 0, isVariant: false, stockControlType: "tracked", scalePlu: null,
      })
    })
    const [path, body] = vi.mocked(pythonClient.put).mock.calls[0]
    expect(path).toBe("/products/prod-tomate")
    expect(body).toHaveProperty("scale_plu", null)
  })
})
