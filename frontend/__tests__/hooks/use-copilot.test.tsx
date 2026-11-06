/**
 * ia-copilot-v2 (tanda B, grupo 7) — hooks del Copiloto v2: hooks/data/use-copilot.ts.
 *
 * - `askCopilot` (función pura sobre fetch): arma el request con `getAuthHeaders()`, y traduce cada
 *   forma CERRADA de la Edge Function `ai-copilot` (D2) a un resultado tipado; nunca expone texto
 *   crudo del proveedor.
 * - `useAskCopilot`: invalida `aiUsage` y el historial sólo en `answer`/`clarification`.
 * - `useCopilotHistory`: como máximo 50 turnos propios + la valoración de cada uno.
 * - `useSetAiFeedback`: RPC `rpc_set_ai_feedback`, optimista con rollback.
 *
 * Run: pnpm vitest run __tests__/hooks/use-copilot.test.tsx
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const supabaseMock = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }))
const resolveAccessTokenMock = vi.hoisted(() => vi.fn())
vi.mock("@/lib/supabase/client", () => ({ createClient: () => supabaseMock }))
vi.mock("@/lib/auth/access-token-store", () => ({ resolveAccessToken: () => resolveAccessTokenMock() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u-1", accountId: "a-1" } }) }))

import {
  askCopilot,
  useAskCopilot,
  useCopilotHistory,
  useSetAiFeedback,
  EMPTY_COPILOT_STATE,
  type CopilotAskInput,
  type CopilotHistoryTurn,
} from "@/hooks/data/use-copilot"
import { queryKeys } from "@/lib/query-keys"

const fetchMock = vi.fn()
const INPUT: CopilotAskInput = { question: "¿cuánto vendí hoy?", history: [], state: EMPTY_COPILOT_STATE, threadId: null }

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return { ok: status >= 200 && status < 300, status, headers: { get: (k: string) => headers[k] ?? null }, json: async () => body }
}
const ANSWER_BODY = {
  ok: true,
  kind: "answer",
  answer: "Hoy vendiste $12.000.",
  conversation_id: "c-1",
  consulted: [{ tool: "resumen_periodo", label: "ventas de hoy" }],
  state: { period: { start: "2026-11-06", end: "2026-11-06" }, product: null, client: null },
}

function wrapper(client: QueryClient) {
  return ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

beforeEach(() => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
  fetchMock.mockReset()
  resolveAccessTokenMock.mockReset()
  resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-abc" })
  supabaseMock.from.mockReset()
  supabaseMock.rpc.mockReset()
  vi.stubGlobal("fetch", fetchMock)
})
afterEach(() => vi.unstubAllGlobals())

describe("askCopilot — request", () => {
  it("POST a ai-copilot con el Bearer del helper y el cuerpo del contrato D2", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, ANSWER_BODY))
    await askCopilot({
      question: "¿y el mes pasado?",
      history: [
        { role: "user", content: "ventas de octubre" },
        { role: "assistant", content: "Vendiste $1.", consulted: ["ventas de octubre"] },
      ],
      state: { period: { start: "2026-10-01", end: "2026-10-31" }, product: null, client: null },
      threadId: "t-1",
    })
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://127.0.0.1:54321/functions/v1/ai-copilot")
    expect(init.method).toBe("POST")
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer tok-abc")
    expect(JSON.parse(String(init.body))).toEqual({
      question: "¿y el mes pasado?",
      history: [
        { role: "user", content: "ventas de octubre" },
        { role: "assistant", content: "Vendiste $1.", consulted: ["ventas de octubre"] },
      ],
      state: { period: { start: "2026-10-01", end: "2026-10-31" }, product: null, client: null },
      thread_id: "t-1",
    })
  })

  it("sin thread_id no lo manda", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, ANSWER_BODY))
    await askCopilot(INPUT)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).not.toHaveProperty("thread_id")
  })

  it("sin sesión devuelve error SIN llamar a la función", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "absent" })
    const r = await askCopilot(INPUT)
    expect(r.status).toBe("error")
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("sin URL de Supabase devuelve error sin llamar", async () => {
    delete process.env.NEXT_PUBLIC_SUPABASE_URL
    expect((await askCopilot(INPUT)).status).toBe("error")
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe("askCopilot — formas cerradas de respuesta", () => {
  it("answer → texto, conversation_id, consulted y estado de foco", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, ANSWER_BODY))
    expect(await askCopilot(INPUT)).toEqual({
      status: "answer",
      answer: "Hoy vendiste $12.000.",
      conversationId: "c-1",
      consulted: [{ tool: "resumen_periodo", label: "ventas de hoy" }],
      state: ANSWER_BODY.state,
    })
  })

  it("clarification → status clarification con el mismo cuerpo", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ...ANSWER_BODY, kind: "clarification", answer: "¿De qué producto?", consulted: [] }))
    const r = await askCopilot(INPUT)
    expect(r).toMatchObject({ status: "clarification", answer: "¿De qué producto?", consulted: [] })
  })

  it("un estado de foco inválido se descarta a vacío; consulted malformado se filtra", async () => {
    fetchMock.mockResolvedValue(
      jsonResponse(200, { ...ANSWER_BODY, state: { period: "ayer" }, consulted: [{ tool: "x", label: "ok" }, { tool: 3 }, "nada"], conversation_id: undefined }),
    )
    const r = await askCopilot(INPUT)
    expect(r).toMatchObject({ status: "answer", conversationId: null, state: EMPTY_COPILOT_STATE, consulted: [{ tool: "x", label: "ok" }] })
  })

  it("fallback → fallback (el texto es del cliente, no del servidor)", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, kind: "fallback", answer: "texto del servidor", conversation_id: "c-9" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "fallback", conversationId: "c-9" })
  })

  it("400 invalid_params → invalid con el mensaje de validación", async () => {
    fetchMock.mockResolvedValue(jsonResponse(400, { ok: false, error: "invalid_params", message: "question es obligatoria" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "invalid", message: "question es obligatoria" })
  })

  it("401 → unauthorized; 403 → no_account", async () => {
    fetchMock.mockResolvedValue(jsonResponse(401, { ok: false, error: "unauthorized" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "unauthorized" })
    fetchMock.mockResolvedValue(jsonResponse(403, { ok: false, error: "no_active_account" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "no_account" })
  })

  it("429 por cuota → quota_exceeded con resetAt, usadas y límite", async () => {
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "quota_exceeded", resetAt: "2026-12-01T03:00:00Z", used: 30, limit: 30 }))
    expect(await askCopilot(INPUT)).toEqual({ status: "quota_exceeded", resetAt: "2026-12-01T03:00:00Z", used: 30, limit: 30 })
  })

  it("429 por cuota sin datos numéricos → resetAt null y contadores null", async () => {
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "quota_exceeded" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "quota_exceeded", resetAt: null, used: null, limit: null })
  })

  it("429 por ráfaga → rate_limited con los segundos del cuerpo (o del header Retry-After)", async () => {
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "rate_limited", retryAfterSeconds: 40 }))
    expect(await askCopilot(INPUT)).toEqual({ status: "rate_limited", retryAfterSeconds: 40 })
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "rate_limited" }, { "Retry-After": "12" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "rate_limited", retryAfterSeconds: 12 })
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "rate_limited" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "rate_limited", retryAfterSeconds: 30 })
  })

  it("502 y 503 → unavailable, sin filtrar texto del proveedor", async () => {
    fetchMock.mockResolvedValue(jsonResponse(502, { ok: false, error: "ai_unavailable", detail: "OpenAI 500: secreto" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "unavailable" })
    fetchMock.mockResolvedValue(jsonResponse(503, { ok: false, error: "quota_unavailable" }))
    expect(await askCopilot(INPUT)).toEqual({ status: "unavailable" })
  })

  it("red caída (fetch rechaza) → offline", async () => {
    fetchMock.mockRejectedValue(new TypeError("Failed to fetch"))
    expect(await askCopilot(INPUT)).toEqual({ status: "offline" })
  })

  it("cualquier otro status o cuerpo ilegible → error genérico (sin el cuerpo)", async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, headers: { get: () => null }, json: async () => { throw new Error("no json") } })
    expect(await askCopilot(INPUT)).toEqual({ status: "error", message: "Error 500" })
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, kind: "answer" }))
    expect((await askCopilot(INPUT)).status).toBe("error")
  })
})

describe("useAskCopilot — invalidación", () => {
  const keysOf = (spy: { mock: { calls: unknown[][] } }) =>
    spy.mock.calls.map((c) => JSON.stringify((c[0] as { queryKey: unknown }).queryKey))

  it("en answer invalida el contador de uso y el historial", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, ANSWER_BODY))
    const client = new QueryClient()
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useAskCopilot(), { wrapper: wrapper(client) })
    expect((await result.current.mutateAsync(INPUT)).status).toBe("answer")
    const keys = keysOf(spy)
    expect(keys).toContain(JSON.stringify(["aiUsage", "u-1"]))
    expect(keys).toContain(JSON.stringify(queryKeys.copilot.history("a-1")))
  })

  it("en clarification también invalida (la repregunta consumió cuota)", async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ...ANSWER_BODY, kind: "clarification" }))
    const client = new QueryClient()
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useAskCopilot(), { wrapper: wrapper(client) })
    await result.current.mutateAsync(INPUT)
    expect(keysOf(spy)).toContain(JSON.stringify(["aiUsage", "u-1"]))
  })

  it("en cuota, ráfaga, fallback o error NO invalida nada", async () => {
    const client = new QueryClient()
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useAskCopilot(), { wrapper: wrapper(client) })
    for (const res of [
      jsonResponse(429, { ok: false, error: "quota_exceeded" }),
      jsonResponse(429, { ok: false, error: "rate_limited", retryAfterSeconds: 5 }),
      jsonResponse(200, { ok: true, kind: "fallback", answer: "x", conversation_id: null }),
      jsonResponse(502, { ok: false, error: "ai_unavailable" }),
    ]) {
      fetchMock.mockResolvedValueOnce(res)
      await result.current.mutateAsync(INPUT)
    }
    expect(spy).not.toHaveBeenCalled()
  })
})

type ChainMock = Record<string, ReturnType<typeof vi.fn>> & { then: (resolve: (v: unknown) => void) => void }

/** Cadena de supabase-js que resuelve (thenable) con `result` al final del encadenado. */
function chain(result: { data: unknown; error: unknown }): ChainMock {
  const c = {} as ChainMock
  for (const m of ["select", "eq", "in", "order", "limit"]) c[m] = vi.fn(() => c)
  c.then = (resolve: (v: unknown) => void) => resolve(result)
  return c
}

describe("useCopilotHistory", () => {
  it("lee como máximo 50 turnos propios (descendente) y la valoración de cada uno; devuelve cronológico", async () => {
    const conv = chain({
      data: [
        { id: "c-2", question: "q2", answer: "a2", created_at: "2026-11-06T12:00:00Z", outcome: "answer" },
        { id: "c-1", question: "q1", answer: "a1", created_at: "2026-11-05T12:00:00Z", outcome: null },
      ],
      error: null,
    })
    const fb = chain({ data: [{ subject_id: "c-2", rating: "useful" }], error: null })
    supabaseMock.from.mockImplementation((t: string) => (t === "ai_conversations" ? conv : fb))
    const { result } = renderHook(() => useCopilotHistory(), { wrapper: wrapper(new QueryClient()) })

    await waitFor(() => expect(result.current.data).toBeDefined())
    expect(result.current.data).toEqual<CopilotHistoryTurn[]>([
      { id: "c-1", question: "q1", answer: "a1", createdAt: "2026-11-05T12:00:00Z", outcome: null, rating: null },
      { id: "c-2", question: "q2", answer: "a2", createdAt: "2026-11-06T12:00:00Z", outcome: "answer", rating: "useful" },
    ])
    expect(conv.eq).toHaveBeenCalledWith("user_id", "u-1")
    expect(conv.order).toHaveBeenCalledWith("created_at", { ascending: false })
    expect(conv.limit).toHaveBeenCalledWith(50)
    expect(conv.select).not.toHaveBeenCalledWith("*")
    expect(fb.eq).toHaveBeenCalledWith("subject_type", "copilot_answer")
    expect(fb.in).toHaveBeenCalledWith("subject_id", ["c-2", "c-1"])
  })

  it("sin turnos no consulta valoraciones", async () => {
    supabaseMock.from.mockImplementation(() => chain({ data: [], error: null }))
    const { result } = renderHook(() => useCopilotHistory(), { wrapper: wrapper(new QueryClient()) })
    await waitFor(() => expect(result.current.data).toEqual([]))
    expect(supabaseMock.from).toHaveBeenCalledTimes(1)
  })

  it("un error de lectura del historial se propaga como error de la query", async () => {
    supabaseMock.from.mockImplementation(() => chain({ data: null, error: new Error("boom") }))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(() => useCopilotHistory(), { wrapper: wrapper(client) })
    await waitFor(() => expect(result.current.isError).toBe(true))
  })

  it("si falla sólo la lectura de valoraciones, igual muestra el historial sin ellas", async () => {
    const conv = chain({ data: [{ id: "c-1", question: "q", answer: "a", created_at: "2026-11-05T12:00:00Z", outcome: "answer" }], error: null })
    const fb = chain({ data: null, error: new Error("rls") })
    supabaseMock.from.mockImplementation((t: string) => (t === "ai_conversations" ? conv : fb))
    const { result } = renderHook(() => useCopilotHistory(), { wrapper: wrapper(new QueryClient()) })
    await waitFor(() => expect(result.current.data?.[0]?.rating).toBeNull())
  })
})

describe("useSetAiFeedback", () => {
  const turn = (rating: CopilotHistoryTurn["rating"]): CopilotHistoryTurn => ({
    id: "c-1", question: "q", answer: "a", createdAt: "2026-11-05T12:00:00Z", outcome: "answer", rating,
  })

  it("llama a rpc_set_ai_feedback con el tipo copilot_answer y actualiza el historial de forma optimista", async () => {
    let release: (v: unknown) => void = () => {}
    supabaseMock.rpc.mockReturnValue(new Promise((r) => { release = r }))
    const client = new QueryClient()
    client.setQueryData(queryKeys.copilot.history("a-1"), [turn(null)])
    const { result } = renderHook(() => useSetAiFeedback(), { wrapper: wrapper(client) })

    act(() => { result.current.mutate({ conversationId: "c-1", rating: "useful" }) })
    await waitFor(() =>
      expect((client.getQueryData(queryKeys.copilot.history("a-1")) as CopilotHistoryTurn[])[0].rating).toBe("useful"),
    )
    expect(supabaseMock.rpc).toHaveBeenCalledWith("rpc_set_ai_feedback", {
      p_subject_type: "copilot_answer", p_subject_id: "c-1", p_rating: "useful",
    })
    await act(async () => { release({ data: { subject_type: "copilot_answer", subject_id: "c-1", rating: "useful" }, error: null }) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
  })

  it("rating null (toggle) manda p_rating null y limpia la valoración", async () => {
    supabaseMock.rpc.mockResolvedValue({ data: { subject_type: "copilot_answer", subject_id: "c-1", rating: null }, error: null })
    const client = new QueryClient()
    client.setQueryData(queryKeys.copilot.history("a-1"), [turn("not_useful")])
    const { result } = renderHook(() => useSetAiFeedback(), { wrapper: wrapper(client) })
    await act(async () => { await result.current.mutateAsync({ conversationId: "c-1", rating: null }) })
    expect(supabaseMock.rpc).toHaveBeenCalledWith("rpc_set_ai_feedback", {
      p_subject_type: "copilot_answer", p_subject_id: "c-1", p_rating: null,
    })
    expect((client.getQueryData(queryKeys.copilot.history("a-1")) as CopilotHistoryTurn[])[0].rating).toBeNull()
  })

  it("si la RPC falla revierte al valor anterior y propaga el error", async () => {
    supabaseMock.rpc.mockResolvedValue({ data: null, error: { message: "P0404" } })
    const client = new QueryClient()
    client.setQueryData(queryKeys.copilot.history("a-1"), [turn("useful")])
    const { result } = renderHook(() => useSetAiFeedback(), { wrapper: wrapper(client) })
    await act(async () => {
      await expect(result.current.mutateAsync({ conversationId: "c-1", rating: "not_useful" })).rejects.toBeDefined()
    })
    expect((client.getQueryData(queryKeys.copilot.history("a-1")) as CopilotHistoryTurn[])[0].rating).toBe("useful")
  })

  it("sin historial en caché igual llama a la RPC (la respuesta viva todavía no se leyó)", async () => {
    supabaseMock.rpc.mockResolvedValue({ data: {}, error: null })
    const { result } = renderHook(() => useSetAiFeedback(), { wrapper: wrapper(new QueryClient()) })
    await act(async () => { await result.current.mutateAsync({ conversationId: "c-7", rating: "useful" }) })
    expect(supabaseMock.rpc).toHaveBeenCalledTimes(1)
  })
})
