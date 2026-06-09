/**
 * TDD tests for useClients, usePurchases, useBranches, useStock, useOrganizations
 * (C-18 frontend-decouple-datacontext)
 *
 * Tests: happy path + cache invalidation (at least 2 per hook)
 * Mock: @/lib/api/python-client + @/lib/supabase/client (for branches/stock)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useClients } from "@/hooks/data/use-clients"
import { usePurchases } from "@/hooks/data/use-purchases"
import { useOrganization, useUpdateOrganization } from "@/hooks/data/use-organizations"

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    auth: {
      getUser:    vi.fn().mockResolvedValue({ data: { user: { id: "user-1" } }, error: null }),
      getSession: vi.fn().mockResolvedValue({ data: { session: null }, error: null }),
    },
    from: vi.fn().mockReturnValue({
      select: vi.fn().mockReturnThis(),
      eq:     vi.fn().mockReturnThis(),
      order:  vi.fn().mockReturnThis(),
      then:   vi.fn().mockResolvedValue({ data: [], error: null }),
    }),
    rpc: vi.fn().mockResolvedValue({ data: {}, error: null }),
  })),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: vi.fn(() => ({ user: { id: "user-1", accountId: "acct-1" } })),
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ── useClients ────────────────────────────────────────────────────────────────

describe("useClients", () => {
  beforeEach(() => vi.clearAllMocks())

  it("returns mapped clients from API", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      { id: "c-1", user_id: "u-1", name: "Ana García", email: "ana@test.com", phone: null, created_at: "2026-01-01T00:00:00Z" },
    ])

    const { result } = renderHook(() => useClients(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.clients).toHaveLength(1)
    expect(result.current.clients[0]).toMatchObject({
      id:    "c-1",
      name:  "Ana García",
      email: "ana@test.com",
      phone: "",
    })
  })

  it("addClient calls POST /clients and invalidates cache", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      id: "c-new", user_id: "u-1", name: "Nuevo Cliente", email: null, phone: null, created_at: "2026-01-15T00:00:00Z",
    })

    const { result } = renderHook(() => useClients(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addClient({
        name: "Nuevo Cliente", email: "", phone: "", status: "activo", lastPurchase: "-", totalSpent: 0,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/clients", expect.objectContaining({ name: "Nuevo Cliente" }))
    expect(pythonClient.get).toHaveBeenCalledTimes(2) // initial + after invalidation
  })

  it("deleteClient calls DELETE /clients/:id and re-fetches", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    const { result } = renderHook(() => useClients(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteClient("c-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/clients/c-1")
    expect(pythonClient.get).toHaveBeenCalledTimes(2)
  })
})

// ── usePurchases ──────────────────────────────────────────────────────────────

describe("usePurchases", () => {
  beforeEach(() => vi.clearAllMocks())

  it("returns mapped purchases from API", async () => {
    // Paginado por operaciones: el endpoint devuelve {items, total_operations}
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      items: [
        {
          id: "pur-1",
          date: "2026-01-10",
          product_id: "prod-1",
          product: { name: "Tela" },
          quantity: 5,
          amount: "200",
          total: "1000",
          operation_id: "op-1",
        },
      ],
      total_operations: 1,
    })

    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.purchases).toHaveLength(1)
    expect(result.current.purchases[0]).toMatchObject({
      id:          "pur-1",
      productName: "Tela",
      quantity:    5,
      unitCost:    200,
      total:       1000,
    })
  })

  it("addPurchaseOperation calls POST /purchases with correct payload", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total_operations: 0 })
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ operation_id: "op-new" })

    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{
          id: "cart-1", productId: "prod-1", productName: "Tela",
          unitCost: 200, quantity: 5, subtotal: 1000,
        }],
        meta: {
          idempotencyKey: "key-abc",
          date:           "2026-02-01",
          description:    "Compra mensual",
          branchId:       null,
          orgId:          "org-1",
        },
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/purchases", expect.objectContaining({
      idempotency_key: "key-abc",
      org_id:          "org-1",
    }))
    expect(pythonClient.get).toHaveBeenCalledTimes(2) // after invalidation
  })
})

// ── useOrganization ───────────────────────────────────────────────────────────

describe("useOrganization", () => {
  beforeEach(() => vi.clearAllMocks())

  it("returns organization data from API", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      id: "org-1",
      name: "Mi Empresa",
      created_at: "2026-01-01T00:00:00Z",
    })

    const { result } = renderHook(() => useOrganization("org-1"), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.organization).toMatchObject({ id: "org-1", name: "Mi Empresa" })
    expect(pythonClient.get).toHaveBeenCalledWith("/organizations/org-1")
  })

  it("does not fetch when orgId is null", async () => {
    const { result } = renderHook(() => useOrganization(null), { wrapper: makeWrapper() })

    // isLoading stays false because query is disabled
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).not.toHaveBeenCalled()
    expect(result.current.organization).toBe(null)
  })
})

describe("useUpdateOrganization", () => {
  beforeEach(() => vi.clearAllMocks())

  it("updateOrganization calls PUT /organizations/:orgId/settings", async () => {
    vi.mocked(pythonClient.put).mockResolvedValueOnce({
      id: "org-1", name: "Nuevo Nombre", created_at: "2026-01-01T00:00:00Z",
    })

    const { result } = renderHook(() => useUpdateOrganization(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.mutateAsync({ orgId: "org-1", payload: { name: "Nuevo Nombre" } })
    })

    expect(pythonClient.put).toHaveBeenCalledWith("/organizations/org-1/settings", { name: "Nuevo Nombre" })
  })
})
