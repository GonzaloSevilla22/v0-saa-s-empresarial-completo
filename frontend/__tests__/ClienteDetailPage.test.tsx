/**
 * clientes-frecuentes-historial — TDD tests para
 * frontend/app/(dashboard)/clientes/[id]/page.tsx (tasks 8.3/8.4/8.5).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

const useClientPurchasesMock = vi.fn()
vi.mock("@/hooks/data/use-client-activity", () => ({
  useClientPurchases: (id: string | null) => useClientPurchasesMock(id),
}))

import ClienteDetailPage from "@/app/(dashboard)/clientes/[id]/page"

const PURCHASES = [
  { operationId: "op-1", operationDate: "2026-08-01", itemCount: 3, total: 3000 },
]

const SUMMARY = {
  purchaseCount: 5,
  totalSpent: 15000,
  lastPurchaseDate: "2026-08-01",
  daysSinceLastPurchase: 13,
}

function defaultHookReturn() {
  return {
    purchases: PURCHASES,
    summary: SUMMARY,
    meta: { page: 0, pageSize: 25, totalCount: 5, pageCount: 1, from: 1, to: 5 },
    isLoading: false,
    isError: false,
    error: null,
    setPage: vi.fn(),
    setPageSize: vi.fn(),
    refetch: vi.fn(),
  }
}

describe("ClienteDetailPage", () => {
  beforeEach(() => {
    useClientPurchasesMock.mockReset()
    useClientPurchasesMock.mockReturnValue(defaultHookReturn())
  })

  it("renders the summary cards and the purchase history", async () => {
    render(await ClienteDetailPage({ params: Promise.resolve({ id: "client-1" }) } as any))
    expect(screen.getByText("5")).toBeInTheDocument() // purchase count
    expect(screen.getByText(/historial de compras/i)).toBeInTheDocument()
  })

  it("shows an error state when the fetch fails", async () => {
    useClientPurchasesMock.mockReturnValue({
      ...defaultHookReturn(),
      isError: true,
      error: "Error al cargar",
      purchases: [],
      summary: null,
    })
    render(await ClienteDetailPage({ params: Promise.resolve({ id: "client-1" }) } as any))
    expect(screen.getByText(/error al cargar/i)).toBeInTheDocument()
  })
})
