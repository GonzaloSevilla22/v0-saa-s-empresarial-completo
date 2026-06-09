/**
 * TDD tests for useDashboardKpiSummary (dashboard-kpi-summary-block, Fase A)
 *
 * Mocks: @/lib/supabase/client (rpc) + @/contexts/auth-context (user)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useDashboardKpiSummary } from "@/hooks/data/use-dashboard-kpi-summary"

// ── Mocks ─────────────────────────────────────────────────────────────────────

const rpcMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: rpcMock }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1" } }),
}))

// ── Fixtures ──────────────────────────────────────────────────────────────────

// Fila snake_case tal como la devuelve rpc_dashboard_kpi_summary (numerics como string)
const mockRpcRow = {
  net_profit: "184200",
  prev_net_profit: "164464.29",
  avg_ticket: "6820.00",
  prev_avg_ticket: "6500.00",
  cost_per_sale: "1240.00",
  prev_cost_per_sale: "1148.15",
  stagnant_stock_value: "41600",
  stagnant_stock_count: 23,
  prev_stagnant_stock_value: "39000",
  prev_stagnant_stock_count: 20,
  sales_count: 27,
  prev_sales_count: 31,
}

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("useDashboardKpiSummary", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("mapea la fila del RPC a números camelCase", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })

    const { result } = renderHook(
      () => useDashboardKpiSummary(new Date(2026, 5, 15)),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toEqual({
      netProfit: 184200,
      prevNetProfit: 164464.29,
      avgTicket: 6820,
      prevAvgTicket: 6500,
      costPerSale: 1240,
      prevCostPerSale: 1148.15,
      stagnantStockValue: 41600,
      stagnantStockCount: 23,
      prevStagnantStockValue: 39000,
      prevStagnantStockCount: 20,
      salesCount: 27,
      prevSalesCount: 31,
    })
  })

  it("pasa al RPC la ventana UTC del mes seleccionado y la del mes anterior", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })

    renderHook(() => useDashboardKpiSummary(new Date(2026, 5, 15)), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    expect(rpcMock).toHaveBeenCalledWith("rpc_dashboard_kpi_summary", {
      p_from: "2026-06-01T00:00:00.000Z",
      p_to: "2026-06-30T23:59:59.999Z",
      p_prev_from: "2026-05-01T00:00:00.000Z",
      p_prev_to: "2026-05-31T23:59:59.999Z",
    })
  })

  it("incluye p_branch_id cuando hay sucursal filtrada", async () => {
    rpcMock.mockResolvedValueOnce({ data: [mockRpcRow], error: null })

    renderHook(
      () => useDashboardKpiSummary(new Date(2026, 5, 15), "branch-9"),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))

    expect(rpcMock.mock.calls[0][1]).toMatchObject({ p_branch_id: "branch-9" })
  })

  it("devuelve data null cuando el RPC no trae filas", async () => {
    rpcMock.mockResolvedValueOnce({ data: [], error: null })

    const { result } = renderHook(
      () => useDashboardKpiSummary(new Date(2026, 5, 15)),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data).toBeNull()
  })

  it("preserva null en KPIs sin baseline (división por cero en el RPC)", async () => {
    rpcMock.mockResolvedValueOnce({
      data: [{ ...mockRpcRow, avg_ticket: null, cost_per_sale: null, sales_count: 0 }],
      error: null,
    })

    const { result } = renderHook(
      () => useDashboardKpiSummary(new Date(2026, 5, 15)),
      { wrapper: makeWrapper() },
    )

    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.data?.avgTicket).toBeNull()
    expect(result.current.data?.costPerSale).toBeNull()
    expect(result.current.data?.salesCount).toBe(0)
  })
})
