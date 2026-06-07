/**
 * TDD tests for useSales hook (C-18 frontend-decouple-datacontext)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useSales } from "@/hooks/data/use-sales"

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

const mockSaleRows = [
  {
    id: "sale-1",
    date: "2026-01-15",
    product_id: "prod-1",
    product: { name: "Remera" },
    client_id: "client-1",
    client: { name: "Juan Pérez" },
    quantity: 2,
    amount: "1500",
    total: "3000",
    currency: "ARS",
    operation_id: "op-1",
  },
]

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const mockSaleCartItems = [
  {
    id:          "cart-1",
    productId:   "prod-1",
    productName: "Remera",
    unitPrice:   1500,
    quantity:    2,
    discount:    0,
    subtotal:    3000,
  },
]

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useSales", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  // ── RED → GREEN: hook returns mapped sales ──────────────────────────────
  it("returns mapped sales when API responds", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(mockSaleRows)

    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.sales).toHaveLength(1)
    expect(result.current.sales[0]).toMatchObject({
      id:          "sale-1",
      productName: "Remera",
      clientName:  "Juan Pérez",
      unitPrice:   1500,
      total:       3000,
      currency:    "ARS",
    })
    expect(pythonClient.get).toHaveBeenCalledWith("/sales")
  })

  // ── TRIANGULATE: empty sales list ───────────────────────────────────────
  it("returns empty array when no sales exist", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])

    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.sales).toEqual([])
  })

  // ── RED → GREEN: addSaleOperation calls POST /sales with correct payload ─
  it("addSaleOperation calls POST /sales with correct payload", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(mockSaleRows)
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      operation_id:   "op-new",
      operation_kind: "sale",
    })

    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addSaleOperation({
        items: mockSaleCartItems,
        meta: {
          idempotencyKey: "key-123",
          clientId:       "client-1",
          date:           "2026-02-01",
          currency:       "ARS",
          branchId:       null,
          orgId:          "org-1",
        },
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/sales", {
      idempotency_key: "key-123",
      org_id:          "org-1",
      date:            "2026-02-01",
      items: [{
        product_id: "prod-1",
        amount:     1500,
        quantity:   2,
        unit_id:    null,
      }],
    })
  })

  // ── TRIANGULATE: optimistic update appears before settle ────────────────
  it("addSaleOperation adds optimistic entry before settle", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])

    // Delay the POST to observe intermediate state
    let resolveMutation!: (v: unknown) => void
    vi.mocked(pythonClient.post).mockReturnValueOnce(
      new Promise(res => { resolveMutation = res })
    )

    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    // Start mutation but don't await
    let mutationPromise: Promise<unknown>
    act(() => {
      mutationPromise = result.current.addSaleOperation({
        items: mockSaleCartItems,
        meta: {
          idempotencyKey: "key-optimistic",
          clientId:       null,
          date:           "2026-02-01",
          currency:       "ARS",
          branchId:       null,
          orgId:          "org-1",
        },
      })
    })

    // Optimistic entries should be present before settling
    await waitFor(() => {
      expect(result.current.sales.some(s => s.id.startsWith("optimistic-"))).toBe(true)
    })

    // Resolve the mutation and check state after settle
    act(() => {
      resolveMutation({ operation_id: "op-settled", operation_kind: "sale" })
    })

    // After settle, get is called again to refetch
    await waitFor(() => {
      expect(pythonClient.get).toHaveBeenCalledTimes(2)
    })
  })

  // ── deleteSale calls DELETE /sales/:id ───────────────────────────────────
  it("deleteSale calls DELETE and invalidates", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(mockSaleRows)
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteSale("sale-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/sales/sale-1")
  })
})
