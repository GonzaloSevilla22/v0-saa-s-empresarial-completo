/**
 * mp-real-subscriptions follow-up (task 8.8) — TDD tests for
 * useAmbiguousSubscriptions() and useAccountSearch().
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client (mismo patrón que use-bank-accounts.test.ts)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import {
  useAmbiguousSubscriptions,
  useAccountSearch,
  useRecentSubscriptions,
} from "@/hooks/data/use-ambiguous-subscriptions"

// ── Mocks ─────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ──────────────────────────────────────────────────────────────

const AMBIGUOUS_ROW = {
  id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  preapproval_id: "mp-preapproval-XYZ",
  preapproval_plan_id: "mp-plan-pro",
  plan: "pro",
  ambiguous_reason: "no_match",
  amount: 69900,
  currency: "ARS",
  created_at: "2026-08-01T12:00:00Z",
}

const ACCOUNT_ROW = {
  account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  owner_email: "buyer@example.com",
  owner_name: "Buyer Test",
  billing_plan: "pro",
}

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return {
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
    queryClient,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

// ── useAmbiguousSubscriptions — list ────────────────────────────────────────

describe("useAmbiguousSubscriptions — list", () => {
  it("§1 RED: fetches and maps the ambiguous queue (snake_case → camelCase)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/payments/subscriptions/ambiguous")
    expect(result.current.data).toEqual([
      {
        id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        preapprovalId: "mp-preapproval-XYZ",
        preapprovalPlanId: "mp-plan-pro",
        plan: "pro",
        ambiguousReason: "no_match",
        amount: 69900,
        currency: "ARS",
        createdAt: "2026-08-01T12:00:00Z",
      },
    ])
  })

  it("§2 GREEN: empty queue maps to an empty array", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data).toEqual([])
  })

  it("§2 TRIANGULATE: a fetch error surfaces via isError", async () => {
    vi.mocked(pythonClient.get).mockRejectedValueOnce(new Error("500"))
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isError).toBe(true))
  })
})

// ── useAmbiguousSubscriptions — resolve ─────────────────────────────────────

describe("useAmbiguousSubscriptions — resolveSubscription", () => {
  it("§3 RED: posts account_id to the resolve endpoint", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ok: true })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.resolveSubscription({
        subscriptionId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      "/payments/subscriptions/ambiguous/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/resolve",
      { account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" },
    )
  })

  it("§4 GREEN: invalidates the ambiguous-queue query on success (row disappears on refresh)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ok: true })
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.resolveSubscription({
        subscriptionId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      })
    })

    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith(
        expect.objectContaining({ queryKey: ["ambiguousSubscriptions"] }),
      )
    })
  })

  it("§4 TRIANGULATE: a rejected resolve rejects the mutateAsync promise (caller shows the error)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockRejectedValueOnce(new Error("Ya fue resuelta"))
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await expect(
      result.current.resolveSubscription({
        subscriptionId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      }),
    ).rejects.toThrow("Ya fue resuelta")
  })
})

// ── useAccountSearch ─────────────────────────────────────────────────────────

describe("useAccountSearch", () => {
  it("§5 RED: does not query with less than 2 characters", async () => {
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAccountSearch("a"), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isFetching).toBe(false))
    expect(pythonClient.get).not.toHaveBeenCalled()
    expect(result.current.data).toBeUndefined()
  })

  it("§6 GREEN: queries and maps results once the query reaches 2 characters", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([ACCOUNT_ROW])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAccountSearch("bu"), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isFetching).toBe(false))
    expect(pythonClient.get).toHaveBeenCalledWith("/payments/accounts/search?q=bu")
    expect(result.current.data).toEqual([
      {
        accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        ownerEmail: "buyer@example.com",
        ownerName: "Buyer Test",
        billingPlan: "pro",
      },
    ])
  })

  it("§6 TRIANGULATE: trims whitespace before deciding whether to query and before encoding", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([ACCOUNT_ROW])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAccountSearch("  bu  "), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isFetching).toBe(false))
    expect(pythonClient.get).toHaveBeenCalledWith("/payments/accounts/search?q=bu")
  })
})

// ── useAmbiguousSubscriptions — discardSubscription (residuo (b)) ─────────

describe("useAmbiguousSubscriptions — discardSubscription", () => {
  it("§7 RED: posts the reason to the discard endpoint", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ id: AMBIGUOUS_ROW.id, status: "cancelled" })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.discardSubscription({
        subscriptionId: AMBIGUOUS_ROW.id,
        reason: "cancelado en MP, sin cuenta legítima",
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/payments/subscriptions/ambiguous/${AMBIGUOUS_ROW.id}/discard`,
      { reason: "cancelado en MP, sin cuenta legítima" },
    )
  })

  it("§7 GREEN: an omitted reason posts null (backend field is optional)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ id: AMBIGUOUS_ROW.id, status: "cancelled" })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.discardSubscription({ subscriptionId: AMBIGUOUS_ROW.id })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/payments/subscriptions/ambiguous/${AMBIGUOUS_ROW.id}/discard`,
      { reason: null },
    )
  })

  it("§8 GREEN: invalidates both the ambiguous queue AND the recent-subscriptions query", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ id: AMBIGUOUS_ROW.id, status: "cancelled" })
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.discardSubscription({ subscriptionId: AMBIGUOUS_ROW.id })
    })

    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith(
        expect.objectContaining({ queryKey: ["ambiguousSubscriptions"] }),
      )
      expect(invalidateSpy).toHaveBeenCalledWith(
        expect.objectContaining({ queryKey: ["recentSubscriptions"] }),
      )
    })
  })

  it("§8 TRIANGULATE: a rejected discard rejects the mutateAsync promise", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([AMBIGUOUS_ROW])
    vi.mocked(pythonClient.post).mockRejectedValueOnce(
      new Error("No hay una suscripción ambigua con ese id"),
    )
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useAmbiguousSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await expect(
      result.current.discardSubscription({ subscriptionId: AMBIGUOUS_ROW.id }),
    ).rejects.toThrow("No hay una suscripción ambigua con ese id")
  })
})

// ── useRecentSubscriptions — list + replaySubscriptionCharges ─────────────

const RECENT_ROW = {
  id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
  plan: "pro",
  status: "authorized",
  account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  account_name: "Buyer Test",
  next_payment_date: "2026-09-01T00:00:00Z",
  last_payment_status: "approved",
  retry_state: "none",
  updated_at: "2026-08-01T12:00:00Z",
}

describe("useRecentSubscriptions — list", () => {
  it("§9 RED: fetches with the default limit and maps snake_case → camelCase", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([RECENT_ROW])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useRecentSubscriptions(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/payments/subscriptions/recent?limit=20")
    expect(result.current.data).toEqual([
      {
        id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
        plan: "pro",
        status: "authorized",
        accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        accountName: "Buyer Test",
        nextPaymentDate: "2026-09-01T00:00:00Z",
        lastPaymentStatus: "approved",
        retryState: "none",
        updatedAt: "2026-08-01T12:00:00Z",
      },
    ])
  })

  it("§9 GREEN: a custom limit is passed through to the query string", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useRecentSubscriptions(5), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(pythonClient.get).toHaveBeenCalledWith("/payments/subscriptions/recent?limit=5")
  })

  it("§9 TRIANGULATE: a discarded row (null account) maps cleanly", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      { ...RECENT_ROW, status: "cancelled", account_id: null, account_name: null },
    ])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useRecentSubscriptions(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data?.[0].accountId).toBeNull()
    expect(result.current.data?.[0].accountName).toBeNull()
    expect(result.current.data?.[0].status).toBe("cancelled")
  })
})

describe("useRecentSubscriptions — replaySubscriptionCharges", () => {
  it("§10 RED: posts to the replay-charges endpoint with an empty body and maps the result", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([RECENT_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      ok: true, applied: ["7031580844"], already_applied: [],
    })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useRecentSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    let replayResult
    await act(async () => {
      replayResult = await result.current.replaySubscriptionCharges(RECENT_ROW.id)
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/payments/subscriptions/${RECENT_ROW.id}/replay-charges`,
      {},
    )
    expect(replayResult).toEqual({ ok: true, applied: ["7031580844"], alreadyApplied: [] })
  })

  it("§10 GREEN: invalidates the recent-subscriptions query on success", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([RECENT_ROW])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ok: true, applied: [], already_applied: [] })
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useRecentSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.replaySubscriptionCharges(RECENT_ROW.id)
    })

    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith(
        expect.objectContaining({ queryKey: ["recentSubscriptions"] }),
      )
    })
  })

  it("§10 TRIANGULATE: a rejected replay rejects the mutateAsync promise", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([RECENT_ROW])
    vi.mocked(pythonClient.post).mockRejectedValueOnce(new Error("Error al consultar MercadoPago"))
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useRecentSubscriptions(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await expect(
      result.current.replaySubscriptionCharges(RECENT_ROW.id),
    ).rejects.toThrow("Error al consultar MercadoPago")
  })
})
