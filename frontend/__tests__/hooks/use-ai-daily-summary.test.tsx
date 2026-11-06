/**
 * tablero-explicable (D7, task 4.4): el Resumen IA del día vive en una consulta
 * por cuenta y día argentino — montar dos veces no gasta dos consultas de IA,
 * un remontaje con la llamada en vuelo recibe su resultado, «Regenerar» vuelve
 * a invocar, y un tope de 30 s cubre TODA la operación (nunca queda cargando
 * para siempre).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { useAiDailySummary } from "@/hooks/data/use-ai-daily-summary"
import { queryKeys } from "@/lib/query-keys"
import { argentinaToday } from "@/lib/date-range"
import { AiSummaryTimeoutError } from "@/lib/ai-summary"

const invokeMock = vi.fn()
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ functions: { invoke: invokeMock } }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "account-1" } }),
}))

function makeClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function wrapperFor(client: QueryClient) {
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client }, children)
}

const OK = { data: { ok: true, data: { id: "i-1", message: "Hoy vendiste $200." } }, error: null }

beforeEach(() => {
  invokeMock.mockReset()
})

afterEach(() => {
  vi.useRealTimers()
})

describe("useAiDailySummary", () => {
  it("usa la key queryKeys.aiSummary.daily(accountId, día argentino)", async () => {
    invokeMock.mockResolvedValue(OK)
    const client = makeClient()
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(client) })
    await waitFor(() => expect(result.current.data).toBe("Hoy vendiste $200."))

    const key = queryKeys.aiSummary.daily("account-1", argentinaToday())
    expect(client.getQueryCache().find({ queryKey: key })).toBeDefined()
  })

  it("invoca ai-resumen con el rango del día UTC y devuelve el texto de la fila (message)", async () => {
    invokeMock.mockResolvedValue(OK)
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })
    await waitFor(() => expect(result.current.data).toBe("Hoy vendiste $200."))

    expect(invokeMock).toHaveBeenCalledTimes(1)
    const [name, options] = invokeMock.mock.calls[0]
    expect(name).toBe("ai-resumen")
    expect(options.body).toMatchObject({ period: "daily", dateFrom: expect.any(String), dateTo: expect.any(String) })
  })

  it("montar dos veces en el mismo QueryClient invoca ai-resumen UNA sola vez", async () => {
    invokeMock.mockResolvedValue(OK)
    const client = makeClient()

    const first = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(client) })
    await waitFor(() => expect(first.result.current.data).toBe("Hoy vendiste $200."))
    first.unmount()

    const second = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(client) })
    expect(second.result.current.data).toBe("Hoy vendiste $200.")

    expect(invokeMock).toHaveBeenCalledTimes(1)
  })

  it("desmontar con la llamada en vuelo y volver a montar recibe el resultado de esa misma llamada", async () => {
    let resolveInvoke!: (v: unknown) => void
    invokeMock.mockReturnValue(
      new Promise((r) => {
        resolveInvoke = r
      }),
    )
    const client = makeClient()

    const first = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(client) })
    await waitFor(() => expect(invokeMock).toHaveBeenCalledTimes(1))
    first.unmount()

    const second = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(client) })
    expect(second.result.current.isFetching).toBe(true)

    await act(async () => {
      resolveInvoke(OK)
    })
    await waitFor(() => expect(second.result.current.data).toBe("Hoy vendiste $200."))
    expect(invokeMock).toHaveBeenCalledTimes(1)
  })

  it("refetch() (Regenerar) vuelve a invocar la función y muestra el texto nuevo", async () => {
    invokeMock.mockResolvedValueOnce(OK).mockResolvedValueOnce({
      data: { ok: true, data: "Resumen nuevo." },
      error: null,
    })
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })
    await waitFor(() => expect(result.current.data).toBe("Hoy vendiste $200."))

    await act(async () => {
      await result.current.refetch()
    })

    expect(invokeMock).toHaveBeenCalledTimes(2)
    await waitFor(() => expect(result.current.data).toBe("Resumen nuevo."))
  })

  it("una respuesta exitosa sin texto es un error legible, no un resumen en blanco", async () => {
    invokeMock.mockResolvedValue({ data: { ok: true, data: {} }, error: null })
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.data).toBeUndefined()
  })

  it("propaga el error de la función (p. ej. 429) para que la tarjeta lo mapee", async () => {
    invokeMock.mockResolvedValue({ data: null, error: { name: "FunctionsHttpError", context: { status: 429 } } })
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect((result.current.error as unknown as { context: { status: number } }).context.status).toBe(429)
  })

  it("con invoke que no resuelve, a los 30 s la query queda en error de tope", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    invokeMock.mockReturnValue(new Promise(() => {}))
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })

    await waitFor(() => expect(invokeMock).toHaveBeenCalledTimes(1))
    expect(result.current.isError).toBe(false)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000)
    })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.error).toBeInstanceOf(AiSummaryTimeoutError)
  })

  it("cualquier espera previa a invoke (p. ej. resolución del token) queda cubierta por el mismo tope", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    // invoke devuelve una promesa que nunca se asienta aunque se aborte su signal.
    invokeMock.mockImplementation(() => new Promise(() => {}))
    const { result } = renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })

    await waitFor(() => expect(invokeMock).toHaveBeenCalled())
    await act(async () => {
      await vi.advanceTimersByTimeAsync(29_000)
    })
    expect(result.current.isError).toBe(false)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_500)
    })
    await waitFor(() => expect(result.current.isError).toBe(true))
  })

  it("al vencer el tope aborta la petición (signal) para liberar la conexión", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    let captured: AbortSignal | undefined
    invokeMock.mockImplementation((_name: string, options: { signal?: AbortSignal }) => {
      captured = options.signal
      return new Promise(() => {})
    })
    renderHook(() => useAiDailySummary(), { wrapper: wrapperFor(makeClient()) })
    await waitFor(() => expect(captured).toBeDefined())
    expect(captured!.aborted).toBe(false)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000)
    })

    expect(captured!.aborted).toBe(true)
  })
})
