/**
 * estadisticas-ventas E3 (grupo 10) — hooks del análisis con IA del módulo:
 * hooks/data/use-statistics-ai.ts.
 *
 * - `analyzeStatistics` (función pura sobre fetch): manda a ai-estadisticas
 *   el período y la sucursal de la pantalla; traduce 429 → quota_exceeded,
 *   `fallback: true` → fallback (sin insight), error HTTP → error, y el
 *   éxito → insight + recomendaciones.
 * - `useAnalyzeStatistics`: al éxito invalida el último insight y el
 *   contador de uso (`aiUsage`); en fallback / cuota NO invalida nada (no se
 *   generó insight ni se consumió cuota).
 * - `useLastStatisticsInsight`: lee `insights` con el tipo propio del módulo.
 *
 * Run: pnpm vitest run __tests__/use-statistics-ai.test.tsx
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const supabaseMock = vi.hoisted(() => ({
  auth: { getSession: vi.fn(async () => ({ data: { session: { access_token: "tok-abc" } } })) },
  from: vi.fn(),
}))
vi.mock("@/lib/supabase/client", () => ({ createClient: () => supabaseMock }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u-1", accountId: "a-1" } }) }))

import {
  analyzeStatistics,
  useAnalyzeStatistics,
  useLastStatisticsInsight,
} from "@/hooks/data/use-statistics-ai"
import { queryKeys } from "@/lib/query-keys"
import { STATISTICS_INSIGHT_TYPE } from "@/lib/sales-statistics"

const fetchMock = vi.fn()
const INPUT = { start: "2026-08-01", end: "2026-08-31", branchId: "b-9" }

function jsonResponse(status: number, body: unknown) {
  return { ok: status >= 200 && status < 300, status, json: async () => body }
}

describe("analyzeStatistics (fetch a ai-estadisticas)", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
    fetchMock.mockReset()
    vi.stubGlobal("fetch", fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  it("manda período y sucursal de la pantalla con el token de la sesión", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, data: { insight: "Vendés más los sábados.", recommendations: ["a", "b", "c"] } }))
    const r = await analyzeStatistics(INPUT, "tok-abc")
    expect(r).toEqual({ status: "ok", insight: "Vendés más los sábados.", recommendations: ["a", "b", "c"] })
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://127.0.0.1:54321/functions/v1/ai-estadisticas")
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer tok-abc")
    expect(JSON.parse(String(init.body))).toEqual({ start: "2026-08-01", end: "2026-08-31", branch_id: "b-9" })
  })

  it("429 → quota_exceeded", async () => {
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "quota_exceeded", used: 5, limit: 5 }))
    expect(await analyzeStatistics(INPUT, "t")).toEqual({ status: "quota_exceeded" })
  })

  it("fallback (el modelo no respondió a tiempo) → fallback con su mensaje, sin insight", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, fallback: true, message: "El análisis tardó demasiado. Intentá de nuevo." }))
    expect(await analyzeStatistics(INPUT, "t")).toEqual({ status: "fallback", message: "El análisis tardó demasiado. Intentá de nuevo." })
  })

  it("error HTTP → error con el detalle del servidor; 422 sin ventas también", async () => {
    fetchMock.mockResolvedValue(jsonResponse(422, { ok: false, error: "Sin ventas en el período seleccionado" }))
    expect(await analyzeStatistics(INPUT, "t")).toEqual({ status: "error", message: "Sin ventas en el período seleccionado" })
  })

  it("una respuesta ok sin recomendaciones válidas las normaliza a lista vacía", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, data: { insight: "x", recommendations: "no-array" } }))
    expect(await analyzeStatistics(INPUT, "t")).toEqual({ status: "ok", insight: "x", recommendations: [] })
  })
})

function wrapper(client: QueryClient) {
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

describe("useAnalyzeStatistics (invalidación sólo cuando se generó el insight)", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
    fetchMock.mockReset()
    vi.stubGlobal("fetch", fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  it("al éxito invalida el último insight y el contador de uso de IA", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, data: { insight: "ok", recommendations: [] } }))
    const client = new QueryClient()
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useAnalyzeStatistics(), { wrapper: wrapper(client) })

    const r = await result.current.mutateAsync(INPUT)
    expect(r.status).toBe("ok")
    await waitFor(() => expect(spy).toHaveBeenCalled())
    const keys = spy.mock.calls.map((c) => JSON.stringify((c[0] as { queryKey: unknown }).queryKey))
    expect(keys).toContain(JSON.stringify(queryKeys.salesStatistics.aiInsight("u-1")))
    expect(keys).toContain(JSON.stringify(["aiUsage", "u-1"]))
  })

  it("en fallback o cuota agotada NO invalida nada: ni se generó insight ni se consumió cuota", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, fallback: true, message: "tarde" }))
    const client = new QueryClient()
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useAnalyzeStatistics(), { wrapper: wrapper(client) })
    expect((await result.current.mutateAsync(INPUT)).status).toBe("fallback")

    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "quota_exceeded" }))
    expect((await result.current.mutateAsync(INPUT)).status).toBe("quota_exceeded")
    expect(spy).not.toHaveBeenCalled()
  })

  it("sin sesión activa devuelve error sin llamar a la Edge Function", async () => {
    supabaseMock.auth.getSession.mockResolvedValueOnce({ data: { session: null } } as never)
    const client = new QueryClient()
    const { result } = renderHook(() => useAnalyzeStatistics(), { wrapper: wrapper(client) })
    const r = await result.current.mutateAsync(INPUT)
    expect(r.status).toBe("error")
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe("useLastStatisticsInsight", () => {
  it("lee el último insight del tipo propio del módulo, el más reciente primero", async () => {
    const chain = {
      select: vi.fn(() => chain),
      eq: vi.fn(() => chain),
      order: vi.fn(() => chain),
      limit: vi.fn(() => chain),
      maybeSingle: vi.fn(async () => ({ data: { id: "i-1", message: "Insight", created_at: "2026-09-04T10:00:00Z" }, error: null })),
    }
    supabaseMock.from.mockReturnValue(chain)
    const client = new QueryClient()
    const { result } = renderHook(() => useLastStatisticsInsight(), { wrapper: wrapper(client) })

    await waitFor(() => expect(result.current.data).toEqual({ id: "i-1", message: "Insight", createdAt: "2026-09-04T10:00:00Z" }))
    expect(supabaseMock.from).toHaveBeenCalledWith("insights")
    expect(chain.eq).toHaveBeenCalledWith("type", STATISTICS_INSIGHT_TYPE)
    expect(chain.order).toHaveBeenCalledWith("created_at", { ascending: false })
  })
})
