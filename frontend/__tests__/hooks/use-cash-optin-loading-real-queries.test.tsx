/**
 * useCashOptin — `isLoading` contra TanStack Query REAL (fix `caja-optin-carga`).
 *
 * `use-cash-optin-loading.test.ts` mockea los tres hooks de datos: prueba la
 * lógica del hook, no que `isLoading` de las queries reales cubra el recorrido
 * completo. Acá se usan `useCashboxes` / `useCurrentSession` verdaderos con
 * `pythonClient.get` controlado a mano (promesas diferidas), para fijar lo que
 * el humo de la tanda B mostró en prod:
 *
 *   · mientras las cajas cargan → isLoading;
 *   · entre «cajas resueltas» y «sesión empezó a cargar» NO hay un render con
 *     isLoading=false y sin sesión (esa ventana es exactamente el defecto:
 *     un render así habilita confirmar sin caja);
 *   · con sesión → elegible; con 404 «No hay sesión» → no elegible y SIN
 *     isLoading (no se bloquea para siempre);
 *   · una query que falla no deja el estado en carga eterna.
 *
 * Sólo se mockea la capa HTTP (`pythonClient`) y `useBranches` (que depende de
 * Supabase + auth, ajeno a lo que se prueba).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useCashOptin, type CashOptinState } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"

interface Deferred<T> {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (reason: Error) => void
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (reason: Error) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

const getMock = vi.fn()

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: (...args: unknown[]) => getMock(...args) },
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }], isLoading: false }),
}))

const CASHBOX_ROW = { id: "cashbox-1", branch_id: "branch-1", name: "Caja", currency: "ARS", created_at: "2026-01-01" }
const SESSION_ROW = {
  id: "session-real-1",
  cashbox_id: "cashbox-1",
  status: "open",
  opening_balance: "0",
  closing_balance: null,
  counted_balance: null,
  expected_balance: null,
  difference: null,
  opened_by: "u1",
  closed_by: null,
  opened_at: "2026-10-16T10:00:00Z",
  closed_at: null,
  adjustments_total: "0",
}

function setup(kind: "cash" | "transfer" = "cash") {
  const cashboxes = deferred<unknown[]>()
  const session = deferred<unknown>()
  getMock.mockImplementation((url: string) => {
    if (url.endsWith("/cashboxes")) return cashboxes.promise
    if (url.endsWith("/current-session")) return session.promise
    return Promise.reject(new Error(`unexpected GET ${url}`))
  })

  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
  const renders: CashOptinState[] = []
  const hook = renderHook(
    () => {
      const state = useCashOptin({ kind, branchId: "branch-1", date: argentinaToday(), document: "compra" })
      renders.push(state)
      return state
    },
    { wrapper },
  )
  return { hook, renders, cashboxes, session }
}

afterEach(() => {
  vi.clearAllMocks()
})

describe("useCashOptin con TanStack Query real", () => {
  it("recorrido completo con sesión: carga → carga → elegible, sin ningún render intermedio 'cargado y sin sesión'", async () => {
    const { hook, renders, cashboxes, session } = setup()

    // Cajas cargando.
    expect(hook.result.current.isLoading).toBe(true)
    expect(hook.result.current.eligible).toBe(false)

    await act(async () => {
      cashboxes.resolve([CASHBOX_ROW])
    })
    // Cajas resueltas, la sesión todavía no volvió: sigue cargando.
    await waitFor(() => expect(hook.result.current.cashboxId).toBe("cashbox-1"))
    expect(hook.result.current.isLoading).toBe(true)
    expect(hook.result.current.eligible).toBe(false)

    await act(async () => {
      session.resolve(SESSION_ROW)
    })
    await waitFor(() => expect(hook.result.current.eligible).toBe(true))
    expect(hook.result.current.isLoading).toBe(false)
    expect(hook.result.current.session?.id).toBe("session-real-1")

    // El defecto: ningún render anterior al final estuvo "no cargando y sin sesión".
    const premature = renders.filter((r) => !r.isLoading && !r.session)
    expect(premature).toEqual([])
  })

  it("sin sesión abierta (404 'No hay sesión'): termina SIN isLoading y no elegible — no se bloquea para siempre", async () => {
    const { hook, renders, cashboxes, session } = setup()

    await act(async () => {
      cashboxes.resolve([CASHBOX_ROW])
    })
    await waitFor(() => expect(hook.result.current.cashboxId).toBe("cashbox-1"))
    expect(hook.result.current.isLoading).toBe(true)

    await act(async () => {
      session.reject(new Error("No hay sesión abierta para esta caja"))
    })
    await waitFor(() => expect(hook.result.current.isLoading).toBe(false))
    expect(hook.result.current.eligible).toBe(false)
    expect(hook.result.current.reason).toMatch(/no hay caja abierta/i)
    // Antes de resolverse, ningún render dijo "no cargando" con la caja ya conocida.
    const hasCashbox = renders.filter((r) => r.cashboxId !== null)
    const firstResolved = hasCashbox.findIndex((r) => !r.isLoading)
    expect(hasCashbox.slice(0, firstResolved).every((r) => r.isLoading)).toBe(true)
  })

  it("la sucursal no tiene caja (lista vacía): isLoading=false apenas resuelve, no queda esperando una sesión que no existe", async () => {
    const { hook, cashboxes } = setup()
    expect(hook.result.current.isLoading).toBe(true)

    await act(async () => {
      cashboxes.resolve([])
    })
    await waitFor(() => expect(hook.result.current.isLoading).toBe(false))
    expect(hook.result.current.cashboxId).toBeNull()
    expect(hook.result.current.eligible).toBe(false)
  })

  it("la consulta de cajas FALLA: deja de cargar (no queda un 'Verificando…' eterno)", async () => {
    const { hook, cashboxes } = setup()
    expect(hook.result.current.isLoading).toBe(true)

    await act(async () => {
      cashboxes.reject(new Error("boom"))
    })
    await waitFor(() => expect(hook.result.current.isLoading).toBe(false))
    expect(hook.result.current.eligible).toBe(false)
  })

  it("kind que no es efectivo: no dispara ninguna consulta y nunca carga", () => {
    const { hook } = setup("transfer")

    expect(hook.result.current.isLoading).toBe(false)
    expect(getMock).not.toHaveBeenCalled()
  })
})
