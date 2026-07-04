/**
 * TDD tests for useNotifications (v3-notifications-realtime, Grupo 6)
 * Mocks: @/lib/supabase/client (from/select + channel/postgres_changes) +
 * @/contexts/auth-context (user.accountId)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useNotifications } from "@/hooks/data/use-notifications"

const selectMock = vi.fn()
const orderMock = vi.fn()
const limitMock = vi.fn()
const eqMock = vi.fn()
const fromMock = vi.fn()

const channelOnMock = vi.fn()
const channelSubscribeMock = vi.fn()
const channelMock = vi.fn()
const removeChannelMock = vi.fn()

let realtimeCallback: ((payload: { new: Record<string, unknown> }) => void) | null = null
let subscribeStatusCallback: ((status: string) => void) | null = null

function buildQueryChain() {
  // from("notifications").select(...).eq("account_id", x).order(...).limit(...)
  const chain = {
    select: selectMock,
    eq: eqMock,
    order: orderMock,
    limit: limitMock,
  }
  selectMock.mockReturnValue(chain)
  eqMock.mockReturnValue(chain)
  orderMock.mockReturnValue(chain)
  return chain
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: fromMock,
    channel: channelMock,
    removeChannel: removeChannelMock,
  }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "account-1" } }),
}))

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const mockRow = {
  id: "notif-1",
  account_id: "account-1",
  branch_id: null,
  type: "QuoteAccepted",
  severity: "info",
  payload: { quote_id: "q-1" },
  audience: ["user-1"],
  read: false,
  created_at: "2026-07-04T10:00:00.000Z",
  read_at: null,
}

describe("useNotifications", () => {
  beforeEach(() => {
    fromMock.mockReset()
    selectMock.mockReset()
    eqMock.mockReset()
    orderMock.mockReset()
    limitMock.mockReset()
    channelMock.mockReset()
    channelOnMock.mockReset()
    channelSubscribeMock.mockReset()
    removeChannelMock.mockReset()
    realtimeCallback = null
    subscribeStatusCallback = null

    fromMock.mockImplementation(() => buildQueryChain())
    limitMock.mockResolvedValue({ data: [mockRow], error: null })

    channelOnMock.mockImplementation((_event, _config, cb) => {
      realtimeCallback = cb
      return { subscribe: channelSubscribeMock }
    })
    channelSubscribeMock.mockImplementation((cb?: (status: string) => void) => {
      subscribeStatusCallback = cb ?? null
      return { unsubscribe: vi.fn() }
    })
    channelMock.mockReturnValue({ on: channelOnMock })
  })

  it("fetch inicial devuelve la lista de notificaciones y el unread count", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.notifications).toHaveLength(1)
    expect(result.current.notifications[0].id).toBe("notif-1")
    expect(result.current.unreadCount).toBe(1)
  })

  it("un INSERT por Realtime agrega la notificación al cache y sube el badge", async () => {
    limitMock.mockResolvedValue({ data: [], error: null })

    const { result } = renderHook(() => useNotifications(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.notifications).toHaveLength(0)

    const newRow = { ...mockRow, id: "notif-2" }

    act(() => {
      realtimeCallback?.({ new: newRow })
    })

    await waitFor(() => expect(result.current.notifications).toHaveLength(1))
    expect(result.current.notifications[0].id).toBe("notif-2")
    expect(result.current.unreadCount).toBe(1)
  })

  it("dedupe por id: un INSERT repetido (mismo id) no duplica la lista", async () => {
    limitMock.mockResolvedValue({ data: [mockRow], error: null })

    const { result } = renderHook(() => useNotifications(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.notifications).toHaveLength(1))

    act(() => {
      realtimeCallback?.({ new: mockRow })
    })

    await waitFor(() => expect(result.current.notifications).toHaveLength(1))
  })
})
