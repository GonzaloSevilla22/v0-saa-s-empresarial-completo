/**
 * clientes-frecuentes-historial — TDD tests para
 * frontend/hooks/data/use-client-activity.ts (tasks 6.1 RED / 6.3 TRIANGULATE).
 *
 * Mock: @/lib/api/python-client — mismo patrón que use-sales.test.ts.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useClientActivityList, useClientPurchases } from "@/hooks/data/use-client-activity"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const ACTIVITY_ROW = {
  id: "client-1",
  name: "Acme Corp",
  email: "acme@example.com",
  phone: "+54 261 555-1234",
  tax_id: null,
  iva_condition: null,
  legal_name: null,
  created_at: "2024-01-10T09:00:00",
  purchase_count: 5,
  purchase_count_90d: "3", // numeric de Postgres puede llegar como string
  total_spent: "15000.50",
  last_purchase_date: "2026-08-01",
  days_since_last_purchase: "13",
  activity_status: "frecuente" as const,
}

describe("useClientActivityList", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("returns mapped clients with activity aggregates", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: [ACTIVITY_ROW],
      total: 1,
      page: 0,
      pages: 1,
    })

    const { result } = renderHook(() => useClientActivityList(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.clients).toHaveLength(1)
    expect(result.current.clients[0]).toMatchObject({
      id: "client-1",
      name: "Acme Corp",
      activityStatus: "frecuente",
      purchaseCount: 5,
      purchaseCount90d: 3,
      totalSpent: 15000.5,
      daysSinceLastPurchase: 13,
    })
    expect(pythonClient.get).toHaveBeenCalledWith(
      "/clients/activity?page=0&size=25&sort=name&sort_dir=asc"
    )
  })

  // ── 6.3 TRIANGULATE: respuesta vacía ─────────────────────────────────────
  it("returns empty array when there are no clients", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({ items: [], total: 0, page: 0, pages: 0 })

    const { result } = renderHook(() => useClientActivityList(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.clients).toEqual([])
    expect(result.current.meta.totalCount).toBe(0)
  })

  // ── 6.3 TRIANGULATE: cliente sin compras (last_purchase_date nulo) ───────
  it("maps a client without purchases with null date fields", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: [{
        ...ACTIVITY_ROW,
        purchase_count: 0,
        purchase_count_90d: 0,
        total_spent: "0",
        last_purchase_date: null,
        days_since_last_purchase: null,
        activity_status: "sin_compras",
      }],
      total: 1,
      page: 0,
      pages: 1,
    })

    const { result } = renderHook(() => useClientActivityList(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.clients[0]).toMatchObject({
      activityStatus: "sin_compras",
      lastPurchaseDate: null,
      daysSinceLastPurchase: null,
      totalSpent: 0,
    })
  })

  it("search resets to page 0 and is sent as a query param", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })

    const { result } = renderHook(() => useClientActivityList(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => result.current.setSearch("acme"))

    await waitFor(() =>
      expect(pythonClient.get).toHaveBeenLastCalledWith(
        expect.stringContaining("search=acme")
      )
    )
  })

  it("setActivityStatus sends activity_status as a query param", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })

    const { result } = renderHook(() => useClientActivityList(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => result.current.setActivityStatus("inactivo"))

    await waitFor(() =>
      expect(pythonClient.get).toHaveBeenLastCalledWith(
        expect.stringContaining("activity_status=inactivo")
      )
    )
  })
})

describe("useClientPurchases", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  const PURCHASE_ROW = {
    operation_id: "op-1",
    operation_date: "2026-08-01",
    item_count: "3",
    total: "3000.00",
  }

  it("returns mapped purchases and summary", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: [PURCHASE_ROW],
      total: 1,
      page: 0,
      pages: 1,
      summary: {
        purchase_count: 5,
        total_spent: "15000.50",
        last_purchase_date: "2026-08-01",
        days_since_last_purchase: 13,
      },
    })

    const { result } = renderHook(() => useClientPurchases("client-1"), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.purchases).toHaveLength(1)
    expect(result.current.purchases[0]).toMatchObject({
      operationId: "op-1",
      itemCount: 3,
      total: 3000,
    })
    expect(result.current.summary).toMatchObject({
      purchaseCount: 5,
      totalSpent: 15000.5,
      daysSinceLastPurchase: 13,
    })
  })

  // ── 6.3 TRIANGULATE: cliente sin compras ─────────────────────────────────
  it("maps an empty purchase history with a zeroed summary", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: [],
      total: 0,
      page: 0,
      pages: 0,
      summary: {
        purchase_count: 0,
        total_spent: 0,
        last_purchase_date: null,
        days_since_last_purchase: null,
      },
    })

    const { result } = renderHook(() => useClientPurchases("client-2"), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.purchases).toEqual([])
    expect(result.current.summary).toMatchObject({
      purchaseCount: 0,
      lastPurchaseDate: null,
      daysSinceLastPurchase: null,
    })
  })

  it("does not fetch when clientId is null", async () => {
    const { result } = renderHook(() => useClientPurchases(null), { wrapper: makeWrapper() })

    expect(result.current.isLoading).toBe(false)
    expect(pythonClient.get).not.toHaveBeenCalled()
  })

  // ── 8.7: el resumen no cambia al paginar el historial ────────────────────
  it("keeps the summary stable across pages while the items change", async () => {
    const SUMMARY = {
      purchase_count: 30,
      total_spent: "90000",
      last_purchase_date: "2026-08-01",
      days_since_last_purchase: 13,
    }
    vi.mocked(pythonClient.get)
      .mockResolvedValueOnce({
        items: [{ ...PURCHASE_ROW, operation_id: "op-page0" }],
        total: 30, page: 0, pages: 2, summary: SUMMARY,
      })
      .mockResolvedValueOnce({
        items: [{ ...PURCHASE_ROW, operation_id: "op-page1" }],
        total: 30, page: 1, pages: 2, summary: SUMMARY,
      })

    const { result } = renderHook(() => useClientPurchases("client-1"), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.purchases[0].operationId).toBe("op-page0")
    const summaryPage0 = result.current.summary

    act(() => result.current.setPage(1))
    await waitFor(() => expect(result.current.purchases[0]?.operationId).toBe("op-page1"))

    expect(result.current.summary).toEqual(summaryPage0)
  })
})
