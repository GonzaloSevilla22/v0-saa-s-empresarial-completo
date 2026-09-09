/**
 * filtro-canal-estadisticas (CLAUDE.md candidato "filtro de canal sin
 * superficie en /estadisticas"): los hooks de lectura del módulo pasan
 * `canal` a las consultas que lo soportan — evolución, ranking, desglose y
 * detalle de producto — igual que ya pasan `branchId`. `useTopClients` NO lo
 * soporta: la API (`GET /reports/statistics/clients`) no acepta el
 * parámetro, así que el hook nunca debe agregarlo a la querystring.
 *
 * Molde: __tests__/hooks/use-receivables.test.ts (mock de pythonClient +
 * auth-context, renderHook con QueryClientProvider).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "acc-1" } }),
}))

import { pythonClient } from "@/lib/api/python-client"
import {
  useSalesEvolution,
  useProductRanking,
  useSalesBreakdown,
  useTopClients,
  useProductSalesEvolution,
} from "@/hooks/data/use-sales-statistics"

const WINDOW = { start: "2026-08-01", end: "2026-08-31", history_days: 365, clamped: false }
const METRICS = { revenue: "0", credit_notes: "0", net_revenue: "0", units: "0", operations: 0, service_revenue: "0" }

function wrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

function lastUrl(): string {
  const calls = (pythonClient.get as ReturnType<typeof vi.fn>).mock.calls
  return calls[calls.length - 1][0] as string
}

describe("use-sales-statistics — filtro de canal", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("useSalesEvolution suma canal a la querystring cuando se pasa", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
      bucket: "day", window: WINDOW,
      points: [], current: { start: "2026-08-01", end: "2026-08-31", ...METRICS },
      previous: { start: "2026-07-01", end: "2026-07-31", ...METRICS },
    })
    const { result } = renderHook(
      () => useSalesEvolution({ start: "2026-08-01", end: "2026-08-31", bucket: "day", canal: "whatsapp" }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).toContain("canal=whatsapp")
  })

  it("useSalesEvolution no manda canal cuando es null (Todos)", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
      bucket: "day", window: WINDOW,
      points: [], current: { start: "2026-08-01", end: "2026-08-31", ...METRICS },
      previous: { start: "2026-07-01", end: "2026-07-31", ...METRICS },
    })
    const { result } = renderHook(
      () => useSalesEvolution({ start: "2026-08-01", end: "2026-08-31", bucket: "day", canal: null }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).not.toContain("canal=")
  })

  it("useProductRanking suma canal a la querystring", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({ items: [], total: 0, page: 0, pages: 0, window: WINDOW })
    const { result } = renderHook(
      () => useProductRanking({ start: "2026-08-01", end: "2026-08-31", orderBy: "units", groupVariants: true, canal: "mostrador" }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).toContain("canal=mostrador")
  })

  it("useSalesBreakdown suma canal a la querystring", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({ dimension: "branch", window: WINDOW, rows: [] })
    const { result } = renderHook(
      () => useSalesBreakdown({ start: "2026-08-01", end: "2026-08-31", dimension: "branch", canal: "instagram" }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).toContain("canal=instagram")
  })

  it("useProductSalesEvolution suma canal a la querystring", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
      product: {
        product_id: "p1", product_name: "Producto", sku: null, category: null,
        parent_id: null, parent_name: null, is_group: false, variant_count: 0,
      },
      bucket: "day", window: WINDOW, points: [], members: [],
      totals: { revenue: "0", units: "0", operations: 0, last_sale_date: null, gross_margin: "0", cost_coverage_pct: 100 },
    })
    const { result } = renderHook(
      () => useProductSalesEvolution({ productId: "p1", start: "2026-08-01", end: "2026-08-31", bucket: "day", canal: "whatsapp" }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).toContain("canal=whatsapp")
  })

  it("useTopClients NUNCA manda canal — la API no lo acepta", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
      window: WINDOW, items: [],
      unassigned: { revenue: "0", units: "0", operations: 0, last_sale_date: null },
      total_clients: 0,
    })
    const { result } = renderHook(
      // @ts-expect-error — canal no existe en UseTopClientsParams a propósito
      () => useTopClients({ start: "2026-08-01", end: "2026-08-31", canal: "whatsapp" }),
      { wrapper: wrapper() },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(lastUrl()).not.toContain("canal=")
  })
})
