/**
 * tablero-explicable (D6, task 3.2): la campana lista sólo las no leídas con
 * el total exacto, y descartar / marcar todas actualizan la pantalla de forma
 * optimista (sin esperar un resync), con rollback y aviso si la escritura falla.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { useNotifications } from "@/hooks/data/use-notifications"

const toastError = vi.fn()
vi.mock("sonner", () => ({ toast: { error: (...a: unknown[]) => toastError(...a) } }))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "account-1" } }),
}))

// ── Supabase mock con SELECT (cadena) y UPDATE (cadena + promesa controlable) ─

interface Row {
  id: string
  account_id: string
  branch_id: string | null
  type: string
  severity: string
  payload: Record<string, unknown>
  audience: string[]
  read: boolean
  created_at: string
  read_at: string | null
}

function row(i: number, over: Partial<Row> = {}): Row {
  return {
    id: `n-${i}`,
    account_id: "account-1",
    branch_id: null,
    type: "StockBelowMinimum",
    severity: "warning",
    payload: { product_id: "5f1c2b3e-8a4d-4c6e-9b7a-0123456789ab" },
    audience: ["user-1"],
    read: false,
    created_at: `2026-11-06T10:${String(59 - i).padStart(2, "0")}:00.000Z`,
    read_at: null,
    ...over,
  }
}

let serverRows: Row[] = []
let serverTotal = 0
const selectCalls: Array<{ columns: string; options: unknown }> = []
const selectEqCalls: Array<[string, unknown]> = []
const updateValues: unknown[] = []
const updateEqCalls: Array<[string, unknown]> = []
let updateGate: Promise<{ error: unknown }> = Promise.resolve({ error: null })

let realtimeCallback: ((payload: { new: Record<string, unknown> }) => void) | null = null

function selectChain() {
  const chain: Record<string, unknown> = {}
  chain.eq = vi.fn((col: string, val: unknown) => {
    selectEqCalls.push([col, val])
    return chain
  })
  chain.order = vi.fn(() => chain)
  chain.limit = vi.fn(() =>
    Promise.resolve({ data: serverRows, count: serverTotal, error: null }),
  )
  return chain
}

function updateChain() {
  const chain: Record<string, unknown> = {}
  chain.eq = vi.fn((col: string, val: unknown) => {
    updateEqCalls.push([col, val])
    return chain
  })
  chain.then = (resolve: (v: { error: unknown }) => unknown, reject?: (e: unknown) => unknown) =>
    updateGate.then(resolve, reject)
  return chain
}

const supabaseMock = {
  from: vi.fn(() => ({
    select: vi.fn((columns: string, options?: unknown) => {
      selectCalls.push({ columns, options })
      return selectChain()
    }),
    update: vi.fn((values: unknown) => {
      updateValues.push(values)
      return updateChain()
    }),
  })),
  channel: vi.fn(() => ({
    on: (_event: string, _cfg: unknown, cb: (p: { new: Record<string, unknown> }) => void) => {
      realtimeCallback = cb
      return { subscribe: vi.fn() }
    },
  })),
  removeChannel: vi.fn(),
}
vi.mock("@/lib/supabase/client", () => ({ createClient: () => supabaseMock }))

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client }, children)
}

function deferred<T>() {
  let resolve!: (v: T) => void
  const promise = new Promise<T>((r) => {
    resolve = r
  })
  return { promise, resolve }
}

beforeEach(() => {
  serverRows = Array.from({ length: 20 }, (_, i) => row(i))
  serverTotal = 270
  selectCalls.length = 0
  selectEqCalls.length = 0
  updateValues.length = 0
  updateEqCalls.length = 0
  updateGate = Promise.resolve({ error: null })
  realtimeCallback = null
  toastError.mockReset()
})

describe("useNotifications — sólo no leídas y total exacto", () => {
  it("pide las no leídas de la cuenta con count exacto", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(selectCalls[0].options).toEqual({ count: "exact" })
    expect(selectEqCalls).toContainEqual(["account_id", "account-1"])
    expect(selectEqCalls).toContainEqual(["read", false])
  })

  it("el badge es el count de la respuesta (270) aunque lleguen 20 filas", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.notifications).toHaveLength(20)
    expect(result.current.unreadCount).toBe(270)
  })

  it("sin count en la respuesta usa la cantidad de filas (compatibilidad)", async () => {
    serverRows = [row(0), row(1), row(2)]
    serverTotal = undefined as unknown as number
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.unreadCount).toBe(3)
  })
})

describe("useNotifications — markRead optimista", () => {
  it("quita la fila y baja el contador ANTES de que el UPDATE resuelva", async () => {
    const gate = deferred<{ error: unknown }>()
    updateGate = gate.promise
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => {
      result.current.markRead("n-3")
    })

    await waitFor(() => expect(result.current.notifications.some((n) => n.id === "n-3")).toBe(false))
    expect(result.current.notifications).toHaveLength(19)
    expect(result.current.unreadCount).toBe(269)
    // El UPDATE todavía no resolvió: el cambio fue optimista.
    expect(updateValues).toHaveLength(1)
    expect(updateValues[0]).toMatchObject({ read: true, read_at: expect.any(String) })
    expect(updateEqCalls).toContainEqual(["id", "n-3"])

    serverRows = serverRows.filter((r) => r.id !== "n-3")
    serverTotal = 269
    await act(async () => {
      gate.resolve({ error: null })
    })
  })

  it("si el UPDATE falla restaura la fila y el contador y avisa con un toast", async () => {
    updateGate = Promise.resolve({ error: { message: "boom" } })
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      result.current.markRead("n-3")
    })

    await waitFor(() => expect(toastError).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(result.current.notifications.some((n) => n.id === "n-3")).toBe(true))
    expect(result.current.unreadCount).toBe(270)
  })

  it("descartar una segunda notificación baja el contador una vez más", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    serverRows = serverRows.filter((r) => r.id !== "n-0" && r.id !== "n-1")
    serverTotal = 268
    await act(async () => {
      result.current.markRead("n-0")
      result.current.markRead("n-1")
    })

    await waitFor(() => expect(result.current.unreadCount).toBe(268))
    expect(result.current.notifications.some((n) => n.id === "n-0" || n.id === "n-1")).toBe(false)
  })
})

describe("useNotifications — markAllRead", () => {
  it("emite UN solo UPDATE acotado a la cuenta y a las no leídas, y vacía el panel", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    serverRows = []
    serverTotal = 0
    await act(async () => {
      result.current.markAllRead()
    })

    await waitFor(() => expect(result.current.notifications).toHaveLength(0))
    expect(result.current.unreadCount).toBe(0)
    expect(updateValues).toHaveLength(1)
    expect(updateValues[0]).toMatchObject({ read: true, read_at: expect.any(String) })
    expect(updateEqCalls).toContainEqual(["account_id", "account-1"])
    expect(updateEqCalls).toContainEqual(["read", false])
    expect(updateEqCalls.find(([c]) => c === "id")).toBeUndefined()
  })

  it("si falla restaura el panel y avisa", async () => {
    updateGate = Promise.resolve({ error: { message: "boom" } })
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      result.current.markAllRead()
    })

    await waitFor(() => expect(toastError).toHaveBeenCalled())
    await waitFor(() => expect(result.current.notifications).toHaveLength(20))
    expect(result.current.unreadCount).toBe(270)
  })
})

describe("useNotifications — Realtime", () => {
  it("un INSERT no leído se agrega arriba y suma al contador", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => {
      realtimeCallback?.({ new: row(99, { id: "n-new" }) as unknown as Record<string, unknown> })
    })

    await waitFor(() => expect(result.current.notifications[0].id).toBe("n-new"))
    expect(result.current.unreadCount).toBe(271)
    expect(result.current.notifications).toHaveLength(20)
  })

  it("un INSERT ya leído no entra al panel ni suma", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => {
      realtimeCallback?.({ new: row(99, { id: "n-read", read: true }) as unknown as Record<string, unknown> })
    })

    expect(result.current.notifications.some((n) => n.id === "n-read")).toBe(false)
    expect(result.current.unreadCount).toBe(270)
  })

  it("un INSERT repetido (mismo id) no duplica ni vuelve a sumar", async () => {
    const { result } = renderHook(() => useNotifications(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => {
      realtimeCallback?.({ new: row(0) as unknown as Record<string, unknown> })
    })

    expect(result.current.notifications).toHaveLength(20)
    expect(result.current.unreadCount).toBe(270)
  })
})
