/**
 * Regresión prod 2026-08-23: el cierre de caja fallaba SIEMPRE con
 * "Falta la clave de idempotencia" — `useCloseSession` nunca mandó el header
 * Idempotency-Key que v3-api-standards §4 (D5) volvió obligatorio en julio.
 * Síntoma acumulado: sesiones de caja abiertas desde el 17-07 que nadie pudo cerrar.
 */
import type { ReactNode } from "react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useCloseSession } from "@/hooks/data/use-cash-session"

const mockedPost = vi.mocked(pythonClient.post)

function wrapper({ children }: { children: ReactNode }) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

describe("useCloseSession — Idempotency-Key por header (v3-api-standards D5)", () => {
  beforeEach(() => {
    mockedPost.mockReset()
  })

  it("envía la clave como header Idempotency-Key y counted_balance en el body", async () => {
    mockedPost.mockResolvedValueOnce({ session_id: "s1", status: "closed" })
    const { result } = renderHook(() => useCloseSession(), { wrapper })

    await result.current.mutateAsync({
      sessionId: "s1",
      countedBalance: 10000,
      idempotencyKey: "11111111-2222-4333-8444-555555555555",
    })

    await waitFor(() => expect(mockedPost).toHaveBeenCalledTimes(1))
    const [path, body, headers] = mockedPost.mock.calls[0]
    expect(path).toBe("/sessions/s1/close")
    expect(body).toEqual({ counted_balance: 10000 })
    expect(headers).toEqual({ "Idempotency-Key": "11111111-2222-4333-8444-555555555555" })
  })

  it("un reintento con la misma clave manda exactamente el mismo header (replay, no duplicado)", async () => {
    mockedPost.mockRejectedValueOnce(new Error("network")).mockResolvedValueOnce({ session_id: "s1" })
    const { result } = renderHook(() => useCloseSession(), { wrapper })
    const args = { sessionId: "s1", countedBalance: 250.5, idempotencyKey: "same-key" }

    await expect(result.current.mutateAsync(args)).rejects.toThrow()
    await result.current.mutateAsync(args)

    expect(mockedPost).toHaveBeenCalledTimes(2)
    expect(mockedPost.mock.calls[0][2]).toEqual({ "Idempotency-Key": "same-key" })
    expect(mockedPost.mock.calls[1][2]).toEqual({ "Idempotency-Key": "same-key" })
  })
})
