/**
 * TDD tests para useDashboardFinancials (fix ad-hoc tablero-kpis-mes-vigente, D2).
 *
 * Mocks: @/lib/supabase/client (rpc) + @/contexts/auth-context (user).
 * Molde: use-dashboard-kpi-summary.test.ts.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useDashboardFinancials } from "@/hooks/data/use-dashboard-financials"

// ── Mocks ─────────────────────────────────────────────────────────────────────

const rpcMock = vi.fn()
let mockUser: { id: string } | null = { id: "user-1" }

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: rpcMock }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: mockUser }),
}))

// ── Fixtures ──────────────────────────────────────────────────────────────────

const SEPTEMBER = {
  from: "2026-09-01T00:00:00.000Z",
  to: "2026-09-30T23:59:59.999Z",
}

const AUGUST = {
  from: "2026-08-01T00:00:00.000Z",
  to: "2026-08-31T23:59:59.999Z",
}

const mockRpcRow = {
  total_income: "250000",
  total_expenses: "40000.5",
  total_purchases: "90000",
  net_profit: "119999.5",
}

function makeWrapperAndClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useDashboardFinancials", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockUser = { id: "user-1" }
  })

  it("devuelve los totales de la ventana mapeados a camelCase", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useDashboardFinancials(SEPTEMBER), { wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toEqual({
      totalIncome: 250000,
      totalExpenses: 40000.5,
      totalPurchases: 90000,
      netProfit: 119999.5,
    })
    expect(result.current.isError).toBe(false)
  })

  it("consulta el RPC con la ventana recibida (sin p_branch_id por default)", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })
    const { wrapper } = makeWrapperAndClient()

    renderHook(() => useDashboardFinancials(SEPTEMBER), { wrapper })

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_financials", {
      p_date_from: "2026-09-01T00:00:00.000Z",
      p_date_to: "2026-09-30T23:59:59.999Z",
    })
  })

  it("incluye p_branch_id cuando hay sucursal filtrada", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })
    const { wrapper } = makeWrapperAndClient()

    renderHook(() => useDashboardFinancials(SEPTEMBER, "branch-9"), { wrapper })

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    expect(rpcMock.mock.calls[0][1]).toMatchObject({ p_branch_id: "branch-9" })
  })

  it("la query key incluye usuario, from, to y sucursal", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })
    const { wrapper, queryClient } = makeWrapperAndClient()

    const { result } = renderHook(() => useDashboardFinancials(SEPTEMBER, "branch-9"), {
      wrapper,
    })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const keys = queryClient
      .getQueryCache()
      .getAll()
      .map((q) => q.queryKey)
    expect(keys).toEqual([
      [
        "dashboardFinancials",
        "user-1",
        "2026-09-01T00:00:00.000Z",
        "2026-09-30T23:59:59.999Z",
        "branch-9",
      ],
    ])
  })

  it("cambiar de período o de sucursal dispara una consulta nueva (keys distintas)", async () => {
    rpcMock.mockResolvedValue({ data: [mockRpcRow], error: null })
    const { wrapper } = makeWrapperAndClient()

    const { rerender } = renderHook(
      ({ range, branch }: { range: typeof SEPTEMBER; branch: string | null }) =>
        useDashboardFinancials(range, branch),
      { wrapper, initialProps: { range: SEPTEMBER, branch: null as string | null } },
    )
    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    rerender({ range: AUGUST, branch: null })
    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(2))
    expect(rpcMock.mock.calls[1][1]).toMatchObject({
      p_date_from: "2026-08-01T00:00:00.000Z",
      p_date_to: "2026-08-31T23:59:59.999Z",
    })

    rerender({ range: AUGUST, branch: "branch-9" })
    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(3))
    expect(rpcMock.mock.calls[2][1]).toMatchObject({ p_branch_id: "branch-9" })
  })

  it("no consulta nada mientras no hay usuario autenticado (enabled: !!user)", async () => {
    mockUser = null
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useDashboardFinancials(SEPTEMBER), { wrapper })

    // Una query deshabilitada nunca llega a ejecutar el queryFn.
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(rpcMock).not.toHaveBeenCalled()
    expect(result.current.data).toBeNull()
  })

  it("respuesta vacía del RPC → ceros (período sin datos), no null", async () => {
    rpcMock.mockResolvedValueOnce({ data: [], error: null })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useDashboardFinancials(SEPTEMBER), { wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data).toEqual({
      totalIncome: 0,
      totalExpenses: 0,
      totalPurchases: 0,
      netProfit: 0,
    })
  })

  it("si el RPC falla expone isError y data null (el consumidor degrada a $0)", async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: "boom" } })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useDashboardFinancials(SEPTEMBER), { wrapper })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeNull()
    expect(result.current.isLoading).toBe(false)
  })
})
