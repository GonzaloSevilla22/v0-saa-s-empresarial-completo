/**
 * useSales — filtro por operación (clientes-historial-fecha-enlace): el deep
 * link `/ventas?operation_id=` pre-filtra el listado a una sola operación.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useSales } from "@/hooks/data/use-sales"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const urls = () => (pythonClient.get as ReturnType<typeof vi.fn>).mock.calls.map((c) => String(c[0]))

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })
})

describe("useSales — filtro por operación", () => {
  it("sin operationId no manda operation_id", async () => {
    renderHook(() => useSales(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    expect(urls().every((u) => !u.includes("operation_id"))).toBe(true)
  })

  it("con operationId lo manda como query param", async () => {
    renderHook(() => useSales({ operationId: "op-77" }), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    expect(urls().some((u) => u.includes("operation_id=op-77"))).toBe(true)
  })

  it("al quitar el operationId vuelve al listado completo", async () => {
    const { rerender } = renderHook(
      ({ op }: { op: string | null }) => useSales({ operationId: op }),
      { wrapper: makeWrapper(), initialProps: { op: "op-77" as string | null } },
    )
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    rerender({ op: null })
    await waitFor(() => expect(urls().some((u) => !u.includes("operation_id"))).toBe(true))
  })
})
