/**
 * TDD tests for useCriticalStock (kpi-critical-stock-dashboard, grupo 5 / D5)
 *
 * Mocks: @/lib/supabase/client (rpc) + @/contexts/auth-context (user)
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useCriticalStock } from "@/hooks/data/use-critical-stock"

const rpcMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: rpcMock }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1" } }),
}))

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

describe("useCriticalStock", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("branchId = null -> llama la RPC con p_branch_id: null y devuelve el agregado", async () => {
    rpcMock.mockResolvedValueOnce({ data: 4, error: null })

    const { result } = renderHook(() => useCriticalStock(null), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock", { p_branch_id: null })
    expect(result.current.data).toBe(4)
  })

  it("branchId = '<uuid>' -> devuelve el conteo de esa sucursal", async () => {
    rpcMock.mockResolvedValueOnce({ data: 1, error: null })

    const { result } = renderHook(() => useCriticalStock("branch-9"), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock", { p_branch_id: "branch-9" })
    expect(result.current.data).toBe(1)
  })

  it("cambio de branchId dispara un nuevo fetch (nueva queryKey)", async () => {
    rpcMock.mockResolvedValueOnce({ data: 4, error: null })
    rpcMock.mockResolvedValueOnce({ data: 1, error: null })

    const { result, rerender } = renderHook(
      ({ branchId }: { branchId: string | null }) => useCriticalStock(branchId),
      { wrapper: makeWrapper(), initialProps: { branchId: null } },
    )

    await waitFor(() => expect(result.current.data).toBe(4))

    rerender({ branchId: "branch-9" })

    await waitFor(() => expect(result.current.data).toBe(1))
    expect(rpcMock).toHaveBeenCalledTimes(2)
  })

  it("error del RPC -> data degrada a 0 sin propagar, y se registra en consola", async () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: "boom" } })

    const { result } = renderHook(() => useCriticalStock(null), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toBe(0)
    expect(consoleSpy).toHaveBeenCalled()

    consoleSpy.mockRestore()
  })
})
