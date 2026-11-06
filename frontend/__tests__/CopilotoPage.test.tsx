/**
 * ia-copilot-v2 (tanda B, grupo 8) — pantalla /copiloto-ia sobre la Edge Function `ai-copilot`.
 *
 * Integración real de la pantalla + los componentes de components/copilot/ + los hooks de
 * hooks/data/use-copilot.ts; sólo se simulan los bordes: `fetch` (la Edge Function), el cliente de
 * Supabase (historial + RPC de valoración), la sesión y el contador de cuota.
 *
 * Run: pnpm vitest run __tests__/CopilotoPage.test.tsx
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor, fireEvent, act, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const supabaseMock = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }))
const resolveAccessTokenMock = vi.hoisted(() => vi.fn())
const usageMock = vi.hoisted(() => ({
  value: { queriesUsed: 5, queriesRemaining: 25, queriesLimit: 30, resetAt: null as string | null, isLoading: false },
}))
const toastMock = vi.hoisted(() => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn() }))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => supabaseMock }))
vi.mock("@/lib/auth/access-token-store", () => ({ resolveAccessToken: () => resolveAccessTokenMock() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u-1", accountId: "a-1" } }) }))
vi.mock("@/hooks/auth/use-ai-usage", () => ({ useAiUsage: () => usageMock.value }))
vi.mock("sonner", () => ({ toast: toastMock }))

import CopilotoPage from "@/app/(dashboard)/copiloto-ia/page"

const fetchMock = vi.fn()

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return { ok: status >= 200 && status < 300, status, headers: { get: (k: string) => headers[k] ?? null }, json: async () => body }
}
const answer = (over: Record<string, unknown> = {}) =>
  jsonResponse(200, {
    ok: true,
    kind: "answer",
    answer: "Hoy vendiste $12.000.",
    conversation_id: "c-1",
    consulted: [{ tool: "resumen_periodo", label: "ventas de hoy" }],
    state: { period: { start: "2026-11-06", end: "2026-11-06" }, product: null, client: null },
    ...over,
  })

type ChainMock = Record<string, ReturnType<typeof vi.fn>> & { then: (resolve: (v: unknown) => void) => void }
function chain(result: { data: unknown; error: unknown }): ChainMock {
  const c = {} as ChainMock
  for (const m of ["select", "eq", "in", "order", "limit"]) c[m] = vi.fn(() => c)
  c.then = (resolve: (v: unknown) => void) => resolve(result)
  return c
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <CopilotoPage />
    </QueryClientProvider>,
  )
}

const bodyOf = (call: number) => JSON.parse(String((fetchMock.mock.calls[call] as [string, RequestInit])[1].body)) as Record<string, unknown>
const input = () => screen.getByRole("textbox", { name: /consulta/i })

beforeEach(() => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
  fetchMock.mockReset()
  resolveAccessTokenMock.mockReset()
  resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-abc" })
  supabaseMock.from.mockReset()
  supabaseMock.from.mockImplementation(() => chain({ data: [], error: null }))
  supabaseMock.rpc.mockReset()
  supabaseMock.rpc.mockResolvedValue({ data: {}, error: null })
  toastMock.error.mockReset()
  usageMock.value = { queriesUsed: 5, queriesRemaining: 25, queriesLimit: 30, resetAt: null, isLoading: false }
  vi.stubGlobal("fetch", fetchMock)
})
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("/copiloto-ia — chat vacío y sugerencias", () => {
  it("muestra 6 sugerencias y al elegir una envía esa pregunta", async () => {
    fetchMock.mockResolvedValue(answer())
    renderPage()
    const group = await screen.findByRole("group", { name: /preguntas sugeridas/i })
    const buttons = within(group).getAllByRole("button")
    expect(buttons).toHaveLength(6)

    await userEvent.click(within(group).getByRole("button", { name: /cuánto vendí hoy/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1))
    expect(bodyOf(0).question).toMatch(/cuánto vendí hoy/i)
    expect(await screen.findByText("Hoy vendiste $12.000.")).toBeInTheDocument()
  })

  it("la respuesta trae el bloque «Miré: …» con lo consultado", async () => {
    fetchMock.mockResolvedValue(answer({ consulted: [{ tool: "a", label: "ventas de hoy" }, { tool: "b", label: "stock crítico" }] }))
    renderPage()
    await userEvent.type(input(), "¿cómo vengo?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    const block = await screen.findByText((_, el) => el?.tagName === "P" && /^Miré:\s*ventas de hoy · stock crítico$/.test(el.textContent ?? ""))
    expect(block).toBeInTheDocument()
  })

  it("una repregunta se muestra como mensaje del asistente", async () => {
    fetchMock.mockResolvedValue(answer({ kind: "clarification", answer: "¿De qué producto hablás?", consulted: [], conversation_id: "c-2" }))
    renderPage()
    await userEvent.type(input(), "¿cuánto stock queda?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    expect(await screen.findByText("¿De qué producto hablás?")).toBeInTheDocument()
    expect(screen.queryByText(/Miré:/)).not.toBeInTheDocument()
  })
})

describe("/copiloto-ia — valoración", () => {
  async function askOnce() {
    fetchMock.mockResolvedValue(answer())
    renderPage()
    await userEvent.type(input(), "¿cuánto vendí hoy?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await screen.findByText("Hoy vendiste $12.000.")
  }

  it("«Me sirvió» / «No me sirvió» con aria-pressed, toggle y RPC con el id de la conversación", async () => {
    await askOnce()
    const yes = screen.getByRole("button", { name: /^me sirvió/i })
    const no = screen.getByRole("button", { name: /^no me sirvió/i })
    expect(yes).toHaveAttribute("aria-pressed", "false")
    expect(no).toHaveAttribute("aria-pressed", "false")

    await userEvent.click(yes)
    expect(yes).toHaveAttribute("aria-pressed", "true")
    expect(supabaseMock.rpc).toHaveBeenLastCalledWith("rpc_set_ai_feedback", { p_subject_type: "copilot_answer", p_subject_id: "c-1", p_rating: "useful" })

    await userEvent.click(no)
    expect(yes).toHaveAttribute("aria-pressed", "false")
    expect(no).toHaveAttribute("aria-pressed", "true")
    expect(supabaseMock.rpc).toHaveBeenLastCalledWith("rpc_set_ai_feedback", { p_subject_type: "copilot_answer", p_subject_id: "c-1", p_rating: "not_useful" })

    await userEvent.click(no)
    expect(no).toHaveAttribute("aria-pressed", "false")
    expect(supabaseMock.rpc).toHaveBeenLastCalledWith("rpc_set_ai_feedback", { p_subject_type: "copilot_answer", p_subject_id: "c-1", p_rating: null })
  })

  it("si falla guardar la valoración avisa y vuelve al estado anterior", async () => {
    await askOnce()
    supabaseMock.rpc.mockResolvedValue({ data: null, error: { message: "boom" } })
    const yes = screen.getByRole("button", { name: /^me sirvió/i })
    await userEvent.click(yes)
    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith(expect.stringMatching(/valoración/i)))
    expect(yes).toHaveAttribute("aria-pressed", "false")
  })

  it("sin conversation_id (no se pudo guardar) no hay botones de valoración", async () => {
    fetchMock.mockResolvedValue(answer({ conversation_id: null }))
    renderPage()
    await userEvent.type(input(), "hola")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await screen.findByText("Hoy vendiste $12.000.")
    expect(screen.queryByRole("button", { name: /^me sirvió/i })).not.toBeInTheDocument()
  })
})

describe("/copiloto-ia — cuota", () => {
  it("muestra «Te quedan N consultas este mes» (singular con 1)", () => {
    renderPage()
    expect(screen.getByText("Te quedan 25 consultas este mes")).toBeInTheDocument()
  })

  it("con 1 consulta usa el singular", () => {
    usageMock.value = { ...usageMock.value, queriesUsed: 29, queriesRemaining: 1 }
    renderPage()
    expect(screen.getByText("Te queda 1 consulta este mes")).toBeInTheDocument()
  })

  it("en 0 deshabilita el envío y explica la renovación", () => {
    usageMock.value = { ...usageMock.value, queriesUsed: 30, queriesRemaining: 0 }
    renderPage()
    expect(input()).toBeDisabled()
    expect(screen.getByRole("button", { name: /enviar/i })).toBeDisabled()
    expect(screen.getByText(/Usaste tus 30 consultas del mes\. Se renuevan el 1 de /)).toBeInTheDocument()
  })

  it("mientras el plan no cargó (límite 0) NO bloquea el envío", () => {
    usageMock.value = { queriesUsed: 0, queriesRemaining: 0, queriesLimit: 0, resetAt: null, isLoading: false }
    renderPage()
    expect(input()).not.toBeDisabled()
  })

  it("un 429 por cuota agotada bloquea el input con el aviso y no deja la pregunta perdida", async () => {
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "quota_exceeded", resetAt: "2026-12-01T00:00:00Z", used: 30, limit: 30 }))
    renderPage()
    await userEvent.type(input(), "¿cuánto vendí?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    expect(await screen.findByText(/Usaste tus 30 consultas del mes\. Se renuevan el 1 de diciembre/)).toBeInTheDocument()
    expect(input()).toBeDisabled()
    expect(input()).toHaveValue("¿cuánto vendí?")
  })
})

describe("/copiloto-ia — errores legibles", () => {
  const cases: Array<[string, () => void, RegExp]> = [
    ["502", () => fetchMock.mockResolvedValue(jsonResponse(502, { ok: false, error: "ai_unavailable", detail: "OpenAI exploded sk-123" })), /No pude responder ahora/],
    ["503", () => fetchMock.mockResolvedValue(jsonResponse(503, { ok: false, error: "quota_unavailable" })), /No pude responder ahora/],
    ["fallback", () => fetchMock.mockResolvedValue(jsonResponse(200, { ok: true, kind: "fallback", answer: "texto del servidor", conversation_id: "c-9" })), /No pude responder ahora/],
    ["sin conexión", () => fetchMock.mockRejectedValue(new TypeError("Failed to fetch")), /conexión/i],
    ["sesión vencida", () => fetchMock.mockResolvedValue(jsonResponse(401, { ok: false, error: "unauthorized" })), /sesión/i],
  ]
  it.each(cases)("%s → aviso legible, sin texto del proveedor, y la pregunta vuelve al campo", async (_name, arrange, expected) => {
    arrange()
    renderPage()
    await userEvent.type(input(), "¿cuánto vendí?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(expected)
    expect(alert.textContent).not.toMatch(/openai|sk-123|texto del servidor|failed to fetch/i)
    expect(input()).toHaveValue("¿cuánto vendí?")
  })
})

describe("/copiloto-ia — ráfaga y progreso (reloj simulado)", () => {
  it("429 por ráfaga: «Esperá N segundos» con cuenta regresiva y el envío vuelve al llegar a 0", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(jsonResponse(429, { ok: false, error: "rate_limited", retryAfterSeconds: 3 }))
    renderPage()
    fireEvent.change(input(), { target: { value: "otra" } })
    fireEvent.click(screen.getByRole("button", { name: /enviar/i }))

    expect(await screen.findByText(/Esperá 3 segundos/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /enviar/i })).toBeDisabled()
    await act(async () => { await vi.advanceTimersByTimeAsync(1000) })
    expect(screen.getByText(/Esperá 2 segundos/)).toBeInTheDocument()
    await act(async () => { await vi.advanceTimersByTimeAsync(2000) })
    expect(screen.queryByText(/Esperá/)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /enviar/i })).not.toBeDisabled()
  })

  it("mientras espera muestra pasos: «Consultando tus datos…» a los 2 s y «Sigo buscando…» a los 15 s", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockReturnValue(new Promise(() => {}))
    renderPage()
    fireEvent.change(input(), { target: { value: "¿cómo vengo?" } })
    fireEvent.click(screen.getByRole("button", { name: /enviar/i }))

    const status = await screen.findByRole("status", { name: /progreso/i })
    expect(status).toHaveTextContent(/Pensando/)
    await act(async () => { await vi.advanceTimersByTimeAsync(2100) })
    expect(status).toHaveTextContent(/Consultando tus datos/)
    await act(async () => { await vi.advanceTimersByTimeAsync(13_000) })
    expect(status).toHaveTextContent(/Sigo buscando/)
  })
})

describe("/copiloto-ia — memoria, foco y nueva conversación", () => {
  it("la repregunta manda el historial visible (con «consulté»), el estado de foco y el mismo thread_id", async () => {
    fetchMock.mockResolvedValueOnce(answer())
    fetchMock.mockResolvedValueOnce(answer({ answer: "En octubre vendiste $1.", conversation_id: "c-2" }))
    renderPage()
    await userEvent.type(input(), "¿cuánto vendí hoy?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await screen.findByText("Hoy vendiste $12.000.")
    await userEvent.type(input(), "¿y el mes pasado?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await screen.findByText("En octubre vendiste $1.")

    const first = bodyOf(0)
    const second = bodyOf(1)
    expect(first.history).toEqual([])
    expect(second.history).toEqual([
      { role: "user", content: "¿cuánto vendí hoy?" },
      { role: "assistant", content: "Hoy vendiste $12.000.", consulted: ["ventas de hoy"] },
    ])
    expect(second.state).toEqual({ period: { start: "2026-11-06", end: "2026-11-06" }, product: null, client: null })
    expect(typeof second.thread_id).toBe("string")
    expect(second.thread_id).toBe(first.thread_id)
  })

  it("«Nueva conversación» reinicia historial enviado, thread_id y estado de foco", async () => {
    fetchMock.mockResolvedValue(answer())
    renderPage()
    await userEvent.type(input(), "¿cuánto vendí hoy?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await screen.findByText("Hoy vendiste $12.000.")

    await userEvent.click(screen.getByRole("button", { name: /nueva conversación/i }))
    expect(screen.queryByText("Hoy vendiste $12.000.")).not.toBeInTheDocument()

    await userEvent.type(input(), "¿y ayer?")
    await userEvent.click(screen.getByRole("button", { name: /enviar/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    const second = bodyOf(1)
    expect(second.history).toEqual([])
    expect(second.state).toEqual({ period: null, product: null, client: null })
    expect(second.thread_id).not.toBe(bodyOf(0).thread_id)
  })

  it("el historial guardado aparece arriba, separado de la conversación en curso, con su valoración", async () => {
    supabaseMock.from.mockImplementation((t: string) =>
      t === "ai_conversations"
        ? chain({ data: [{ id: "c-old", question: "¿qué vendí ayer?", answer: "Ayer $500.", created_at: "2026-11-05T12:00:00Z", outcome: "answer" }], error: null })
        : chain({ data: [{ subject_id: "c-old", rating: "useful" }], error: null }),
    )
    renderPage()
    expect(await screen.findByText("Ayer $500.")).toBeInTheDocument()
    expect(screen.getByText("¿qué vendí ayer?")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: /conversaciones anteriores/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /^me sirvió/i })).toHaveAttribute("aria-pressed", "true")
  })
})
