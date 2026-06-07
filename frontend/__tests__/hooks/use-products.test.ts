/**
 * TDD tests for useProducts hook (C-18 frontend-decouple-datacontext)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useProducts } from "@/hooks/data/use-products"
import { queryKeys } from "@/lib/query-keys"

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ──────────────────────────────────────────────────────────────────

const mockProductRows = [
  {
    id: "prod-1",
    user_id: "user-1",
    name: "Remera",
    category: "Ropa",
    price: "2000",
    cost: "1000",
    stock: "50",
    min_stock: 10,
    barcode: null,
    sku: "REM-001",
    is_variant: false,
    stock_control_type: "tracked",
    created_at: "2026-01-01T00:00:00Z",
  },
  {
    id: "prod-2",
    user_id: "user-1",
    name: "Pantalón",
    category: "Ropa",
    price: "3500",
    cost: "1800",
    stock: "30",
    min_stock: 5,
    barcode: "123456789",
    sku: null,
    is_variant: false,
    stock_control_type: "tracked",
    created_at: "2026-01-02T00:00:00Z",
  },
]

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useProducts", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // ── RED → GREEN: hook returns mapped products ────────────────────────────
  it("returns mapped products when API responds", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(mockProductRows)

    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.products).toHaveLength(2)
    expect(result.current.products[0]).toMatchObject({
      id:       "prod-1",
      name:     "Remera",
      category: "Ropa",
      price:    2000,
      cost:     1000,
      stock:    50,
      margin:   50, // (2000-1000)/2000 = 50%
    })
    expect(pythonClient.get).toHaveBeenCalledWith("/products")
  })

  // ── TRIANGULATE: product with null price/cost ─────────────────────────
  it("handles null price and cost gracefully", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([{
      ...mockProductRows[0],
      price: null,
      cost:  null,
    }])

    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.products[0].price).toBe(0)
    expect(result.current.products[0].cost).toBe(0)
    expect(result.current.products[0].margin).toBe(0)
  })

  // ── RED → GREEN: deleteProduct invalidates cache post-204 ───────────────
  it("deleteProduct calls DELETE /products/:id and invalidates cache", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(mockProductRows)
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteProduct("prod-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/products/prod-1")
    // Cache invalidated — get called again
    expect(pythonClient.get).toHaveBeenCalledTimes(2)
  })

  // ── TRIANGULATE: two hooks share the same cache entry (query key test) ──
  it("two useProducts instances share a single cache entry", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(mockProductRows)

    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })
    const wrapper = ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children)

    // Mount two separate hook instances
    const { result: r1 } = renderHook(() => useProducts(), { wrapper })
    const { result: r2 } = renderHook(() => useProducts(), { wrapper })

    await waitFor(() => {
      expect(r1.current.isLoading).toBe(false)
      expect(r2.current.isLoading).toBe(false)
    })

    // Both should return the same data
    expect(r1.current.products).toHaveLength(2)
    expect(r2.current.products).toHaveLength(2)

    // The query should only have been called ONCE (shared cache)
    expect(pythonClient.get).toHaveBeenCalledTimes(1)
    expect(pythonClient.get).toHaveBeenCalledWith("/products")

    // Verify both see the same key in cache
    const cachedData = queryClient.getQueryData(queryKeys.products.lists())
    expect(cachedData).toHaveLength(2)
  })
})
