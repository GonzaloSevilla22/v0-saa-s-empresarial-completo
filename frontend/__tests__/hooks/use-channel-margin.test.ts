/**
 * TDD tests for useChannelMargin (dashboard-kpi-summary-block, Fase B)
 * Mocks: @/lib/supabase/client (rpc) + @/contexts/auth-context (user)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useChannelMargin } from "@/hooks/data/use-channel-margin"

const rpcMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: rpcMock }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1" } }),
}))

const mockRpcRow = {
  channels: [
    { canal: "instagram", revenue: "50000", margin_pct: "34.0" },
    { canal: "mercadolibre", revenue: "80000", margin_pct: "18.0" },
  ],
  leader: "instagram",
  margin_pct: "24.5",
  prev_margin_pct: "21.0",
}

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

describe("useChannelMargin", () => {
  beforeEach(() => {
    rpcMock.mockReset()
  })

  it("mapea la fila del RPC (canales, líder y márgenes como números)", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })

    const { result } = renderHook(
      () => useChannelMargin(new Date(2026, 5, 15)),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toEqual({
      channels: [
        { canal: "instagram", revenue: 50000, margin_pct: 34 },
        { canal: "mercadolibre", revenue: 80000, margin_pct: 18 },
      ],
      leader: "instagram",
      marginPct: 24.5,
      prevMarginPct: 21,
    })
  })

  it("pasa la ventana UTC del mes y la del anterior al RPC", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })

    renderHook(() => useChannelMargin(new Date(2026, 5, 15)), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    expect(rpcMock).toHaveBeenCalledWith("rpc_dashboard_channel_margin", {
      p_from: "2026-06-01T00:00:00.000Z",
      p_to: "2026-06-30T23:59:59.999Z",
      p_prev_from: "2026-05-01T00:00:00.000Z",
      p_prev_to: "2026-05-31T23:59:59.999Z",
    })
  })

  it("sin ventas: channels vacío y leader null", async () => {
    rpcMock.mockResolvedValueOnce({
      data: [{ channels: [], leader: null, margin_pct: null, prev_margin_pct: null }],
      error: null,
    })

    const { result } = renderHook(
      () => useChannelMargin(new Date(2026, 5, 15)),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data?.channels).toEqual([])
    expect(result.current.data?.leader).toBeNull()
    expect(result.current.data?.marginPct).toBeNull()
  })
})
