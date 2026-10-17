/**
 * multiusuario-operativo tanda A (D4, D5, D6) — el `AuthProvider` resuelve la
 * CUENTA ACTIVA con la misma función que usan la base y FastAPI, y sabe cambiarla.
 *
 * Antes de este change el contexto ordenaba `account_members` por su cuenta (la
 * membresía más antigua): era uno de los cuatro criterios de "cuenta activa" que
 * convivían. Ahora lee `rpc_my_accounts()` — una fila por membresía, con la activa
 * marcada por `current_account_ids()` — y NUNCA toca `account_members`.
 *
 * Cubre:
 *  - la cuenta activa y sus datos de billing salen de la fila `is_active`;
 *  - `switchAccount`: persiste (`rpc_set_active_account`), renueva el token, limpia
 *    la caché, avisa a las otras pestañas y lleva al Tablero;
 *  - una pestaña que se entera del cambio (bus o 409) se resincroniza igual;
 *  - sin cuenta activa (token de una cuenta revocada): una renovación, y si
 *    persiste, pantalla de error con "Cerrar sesión".
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, act, fireEvent } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  refreshAccessToken: vi.fn(),
  clearAccessToken: vi.fn(),
  push: vi.fn(),
  replace: vi.fn(),
  router: null as unknown as { push: ReturnType<typeof vi.fn>; replace: ReturnType<typeof vi.fn> },
  announceAccountSwitched: vi.fn(),
  announceSignedIn: vi.fn(),
  announceSignedOut: vi.fn(),
  busHandlers: new Set<(event: string) => void>(),
  signOut: vi.fn(),
  refreshSessionAction: vi.fn(),
  toast: { success: vi.fn(), info: vi.fn(), error: vi.fn() },
  fromTables: [] as string[],
  // Lectura de EMERGENCIA de account_members (sólo la usa el fallback de rpc_my_accounts):
  // `undefined` = el test NO espera que se consulte (el doble lanza si alguien lo hace).
  membership: undefined as undefined | { data: unknown; error: unknown },
  membershipOrder: [] as unknown[][],
  warn: vi.fn(),
}))

vi.mock("@/app/auth/actions", () => ({
  signInWithPasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  signInWithMagicLinkAction: vi.fn().mockResolvedValue({ ok: true }),
  signUpAction: vi.fn().mockResolvedValue({ ok: true }),
  signOutAction: (...args: unknown[]) => h.signOut(...args),
  // Renovación FORZADA ante el proveedor (el hook emite el claim de la cuenta nueva sólo al emitir).
  refreshSessionAction: (...args: unknown[]) => h.refreshSessionAction(...args),
  updatePasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  requestEmailChangeAction: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock("@/lib/auth/access-token-store", () => ({
  refreshAccessToken: () => h.refreshAccessToken(),
  clearAccessToken: () => h.clearAccessToken(),
  subscribeToAccessToken: () => () => {},
}))

vi.mock("@/lib/auth/session-bus", () => ({
  announceAccountSwitched: () => h.announceAccountSwitched(),
  announceSignedIn: () => h.announceSignedIn(),
  announceSignedOut: () => h.announceSignedOut(),
  subscribeToSessionEvents: (handler: (event: string) => void) => {
    h.busHandlers.add(handler)
    return () => h.busHandlers.delete(handler)
  },
}))

// Identidad ESTABLE entre renders (el cliente real se cachea por pestaña): un doble
// nuevo en cada render cambia la identidad de `refreshSession` y el efecto del
// contexto reconsulta sin parar.
const clienteDoble = {
  from: (table: string) => {
    h.fromTables.push(table)
    if (table === "profiles") {
      return {
        select: () => ({
          eq: () => ({ single: () => Promise.resolve({ data: { plan: "pro", role: "user", name: "Usuaria" }, error: null }) }),
        }),
      }
    }
    if (table === "account_members" && h.membership !== undefined) {
      const result = h.membership
      const builder = {
        select: () => builder,
        eq: () => builder,
        order: (...args: unknown[]) => {
          h.membershipOrder.push(args)
          return builder
        },
        limit: () => builder,
        maybeSingle: () => Promise.resolve(result),
      }
      return builder
    }
    throw new Error(`Tabla no mockeada en este test: ${table} (el contexto NO debe consultar account_members)`)
  },
  rpc: (name: string, args?: unknown) => h.rpc(name, args),
}

vi.mock("@/lib/supabase/client", () => ({ createClient: () => clienteDoble }))
// Router ESTABLE entre renders: `useRouter()` real devuelve la misma identidad y el efecto del
// contexto depende de ella — un doble que devuelva un objeto nuevo por render la reconsulta sin parar.
h.router = { push: h.push, replace: h.replace }
vi.mock("next/navigation", () => ({ useRouter: () => h.router }))
vi.mock("sonner", () => ({ toast: h.toast }))

import { AuthProvider, useAuth } from "@/contexts/auth-context"
import { getDisplayedAccountId, resetActiveAccountStore, requestAccountResync } from "@/lib/auth/active-account-store"

interface Row {
  account_id: string
  is_active: boolean
  is_owner?: boolean
  member_role?: string
  roles?: string[]
  brand_display_name?: string | null
  owner_business_name?: string | null
  billing_plan?: string
  effective_plan?: string
  created_at?: string
}

function accountRow(r: Row) {
  return {
    is_owner: true,
    member_role: "owner",
    roles: ["owner"],
    brand_display_name: null,
    fiscal_nombre_fantasia: null,
    fiscal_razon_social: null,
    brand_legal_name: null,
    owner_business_name: null,
    billing_plan: "gratis",
    billing_status: "trialing",
    trial_plan: null,
    trial_started_at: null,
    trial_expires_at: null,
    plan_expires_at: null,
    billing_exempt: false,
    effective_plan: "gratis",
    created_at: "2026-01-01T00:00:00.000Z",
    ...r,
  }
}

let rows: ReturnType<typeof accountRow>[] = []
let queryClient: QueryClient

function Consumer() {
  const { user, accounts, switchAccount } = useAuth()
  return (
    <div>
      <span data-testid="account-id">{user?.accountId ?? ""}</span>
      <span data-testid="account-role">{user?.accountRole ?? ""}</span>
      <span data-testid="billing-plan">{user?.billingPlan ?? ""}</span>
      <span data-testid="account-count">{accounts.length}</span>
      <button onClick={() => void switchAccount("acc-a").catch(() => undefined)}>cambiar</button>
    </div>
  )
}

function renderWithAuth() {
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Consumer />
      </AuthProvider>
    </QueryClientProvider>,
  )
}

const ACTIVE_SESSION = {
  status: "active",
  token: "tok",
  expiresAt: Math.floor(Date.now() / 1000) + 3600,
  user: { id: "user-1", email: "u@test.com", name: null },
}

beforeEach(() => {
  rows = []
  h.rpc.mockReset().mockImplementation((name: string) => {
    if (name === "rpc_my_accounts") return Promise.resolve({ data: rows, error: null })
    if (name === "rpc_set_active_account") return Promise.resolve({ data: "acc-a", error: null })
    return Promise.resolve({ data: null, error: { message: `rpc no mockeada: ${name}` } })
  })
  h.refreshAccessToken.mockReset().mockResolvedValue(ACTIVE_SESSION)
  h.clearAccessToken.mockReset()
  h.push.mockReset()
  h.replace.mockReset()
  h.announceAccountSwitched.mockReset()
  h.announceSignedIn.mockReset()
  h.announceSignedOut.mockReset()
  h.busHandlers.clear()
  h.signOut.mockReset().mockResolvedValue({ ok: true })
  h.refreshSessionAction.mockReset().mockResolvedValue({ ok: true })
  h.toast.success.mockReset()
  h.toast.info.mockReset()
  h.toast.error.mockReset()
  h.fromTables.length = 0
  h.membership = undefined
  h.membershipOrder.length = 0
  h.warn.mockReset()
  vi.spyOn(console, "warn").mockImplementation((...args: unknown[]) => h.warn(...args))
  resetActiveAccountStore()
})

describe("auth-context — la cuenta activa sale de rpc_my_accounts()", () => {
  it("toma la cuenta y el billing de la fila ACTIVA, aunque no sea la más antigua", async () => {
    rows = [
      accountRow({ account_id: "acc-p", is_active: false, created_at: "2026-01-01T00:00:00.000Z" }),
      accountRow({
        account_id: "acc-a",
        is_active: true,
        is_owner: false,
        member_role: "member",
        roles: ["seller"],
        billing_plan: "avanzado",
        effective_plan: "avanzado",
        created_at: "2026-06-01T00:00:00.000Z",
      }),
    ]

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-a"))
    expect(screen.getByTestId("account-role").textContent).toBe("member")
    expect(screen.getByTestId("billing-plan").textContent).toBe("avanzado")
    expect(screen.getByTestId("account-count").textContent).toBe("2")
  })

  it("NO consulta account_members (el criterio de cuenta activa vive sólo en la base)", async () => {
    rows = [accountRow({ account_id: "acc-p", is_active: true })]

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-p"))
    expect(h.fromTables).not.toContain("account_members")
    expect(h.rpc).toHaveBeenCalledWith("rpc_my_accounts", undefined)
  })

  it("publica la cuenta que muestra la pantalla para que el cliente la declare en X-Account-Id", async () => {
    rows = [accountRow({ account_id: "acc-p", is_active: true })]

    renderWithAuth()

    await waitFor(() => expect(getDisplayedAccountId()).toBe("acc-p"))
  })

  it("sin ninguna membresía no falla: accountId vacío y sin pantalla de error (comportamiento previo)", async () => {
    rows = []

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-role").textContent).toBe("owner"))
    expect(screen.getByTestId("account-id").textContent).toBe("")
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})

describe("auth-context — switchAccount", () => {
  async function renderTwoAccounts() {
    rows = [
      accountRow({ account_id: "acc-p", is_active: true, brand_display_name: "Mi Kiosco" }),
      accountRow({ account_id: "acc-a", is_active: false, is_owner: false, member_role: "member", roles: ["seller"], brand_display_name: "Ferretería Roca" }),
    ]
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-p"))
  }

  /** La base ya cambió de cuenta: la lista que devuelve ahora marca la otra como activa. */
  function dbSwitchesTo(activeId: string) {
    h.rpc.mockImplementation((name: string) => {
      if (name === "rpc_set_active_account") {
        rows = rows.map((r) => ({ ...r, is_active: r.account_id === activeId }))
        return Promise.resolve({ data: activeId, error: null })
      }
      if (name === "rpc_my_accounts") return Promise.resolve({ data: rows, error: null })
      return Promise.resolve({ data: null, error: { message: `rpc no mockeada: ${name}` } })
    })
  }

  it("persiste, renueva el token, limpia la caché, avisa a las otras pestañas y lleva al Tablero", async () => {
    await renderTwoAccounts()
    dbSwitchesTo("acc-a")
    const clearSpy = vi.spyOn(queryClient, "clear")
    h.refreshAccessToken.mockClear()

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-a"))
    expect(h.rpc).toHaveBeenCalledWith("rpc_set_active_account", { p_account_id: "acc-a" })
    // El token se RENUEVA (forzado) para que sus claims describan la cuenta nueva.
    expect(h.refreshAccessToken).toHaveBeenCalled()
    // ... y la renovación es ANTE EL PROVEEDOR: el token handler sólo renueva un token por vencer,
    // y el claim `account_id` lo emite el hook al emitir. Releer el token vigente no cambia la cuenta.
    expect(h.refreshSessionAction).toHaveBeenCalledTimes(1)
    expect(clearSpy).toHaveBeenCalled()
    expect(h.announceAccountSwitched).toHaveBeenCalledTimes(1)
    expect(h.replace).toHaveBeenCalledWith("/dashboard")
    expect(h.toast.success).toHaveBeenCalledWith(expect.stringContaining("Ferretería Roca"))
    expect(getDisplayedAccountId()).toBe("acc-a")
  })

  it("el orden importa: la preferencia se guarda ANTES de renovar el token (si no, el hook emite la cuenta vieja)", async () => {
    await renderTwoAccounts()
    dbSwitchesTo("acc-a")
    const order: string[] = []
    const rpcImpl = h.rpc.getMockImplementation()!
    h.rpc.mockImplementation((name: string, args?: unknown) => {
      order.push(`rpc:${name}`)
      return rpcImpl(name, args)
    })
    h.refreshAccessToken.mockImplementation(() => {
      order.push("refreshToken")
      return Promise.resolve(ACTIVE_SESSION)
    })

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))
    await waitFor(() => expect(h.announceAccountSwitched).toHaveBeenCalled())

    expect(order.indexOf("rpc:rpc_set_active_account")).toBeGreaterThanOrEqual(0)
    expect(order.indexOf("rpc:rpc_set_active_account")).toBeLessThan(order.indexOf("refreshToken"))
  })

  it("el orden importa: preferencia -> renovación ante el proveedor -> lectura del token nuevo (un token leído antes lleva la cuenta vieja)", async () => {
    await renderTwoAccounts()
    dbSwitchesTo("acc-a")
    const order: string[] = []
    const rpcImpl = h.rpc.getMockImplementation()!
    h.rpc.mockImplementation((name: string, args?: unknown) => {
      if (name === "rpc_set_active_account") order.push("setActive")
      return rpcImpl(name, args)
    })
    h.refreshSessionAction.mockImplementation(() => {
      order.push("renewAtProvider")
      return Promise.resolve({ ok: true })
    })
    h.refreshAccessToken.mockImplementation(() => {
      order.push("readToken")
      return Promise.resolve(ACTIVE_SESSION)
    })

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))
    await waitFor(() => expect(h.announceAccountSwitched).toHaveBeenCalled())

    const setActive = order.indexOf("setActive")
    const renew = order.indexOf("renewAtProvider")
    const readAfter = order.indexOf("readToken", renew)
    expect(setActive).toBeGreaterThanOrEqual(0)
    expect(renew).toBeGreaterThan(setActive)
    expect(readAfter).toBeGreaterThan(renew)
  })

  it("si el proveedor no renueva el token, el cambio NO se da por hecho: avisa, recarga la lista y no anuncia nada", async () => {
    await renderTwoAccounts()
    dbSwitchesTo("acc-a")
    h.refreshSessionAction.mockResolvedValue({ ok: false, error: "Invalid Refresh Token" })
    const clearSpy = vi.spyOn(queryClient, "clear")

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))

    await waitFor(() => expect(h.toast.error).toHaveBeenCalled())
    expect(h.announceAccountSwitched).not.toHaveBeenCalled()
    expect(h.replace).not.toHaveBeenCalled()
    expect(h.toast.success).not.toHaveBeenCalled()
    expect(clearSpy).not.toHaveBeenCalled()
  })

  it("durante la transición NO declara cuenta (evita un 409 contra el propio token recién renovado)", async () => {
    await renderTwoAccounts()
    dbSwitchesTo("acc-a")
    const declared: (string | null)[] = []
    h.refreshAccessToken.mockImplementation(() => {
      declared.push(getDisplayedAccountId())
      return Promise.resolve(ACTIVE_SESSION)
    })

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))
    await waitFor(() => expect(h.announceAccountSwitched).toHaveBeenCalled())

    expect(declared.length).toBeGreaterThan(0)
    expect(declared.every((value) => value === null)).toBe(true)
  })

  it("si la base rechaza el cambio (membresía revocada entre medio) no limpia nada ni avisa, y recarga la lista", async () => {
    await renderTwoAccounts()
    h.rpc.mockImplementation((name: string) => {
      if (name === "rpc_set_active_account") return Promise.resolve({ data: null, error: { code: "P0404", message: "account_not_found" } })
      if (name === "rpc_my_accounts") return Promise.resolve({ data: rows, error: null })
      return Promise.resolve({ data: null, error: null })
    })
    const clearSpy = vi.spyOn(queryClient, "clear")
    h.rpc.mockClear()

    fireEvent.click(screen.getByRole("button", { name: "cambiar" }))

    await waitFor(() => expect(h.toast.error).toHaveBeenCalled())
    expect(clearSpy).not.toHaveBeenCalled()
    expect(h.announceAccountSwitched).not.toHaveBeenCalled()
    expect(h.replace).not.toHaveBeenCalled()
    // La lista se vuelve a leer (la cuenta pudo haber desaparecido).
    expect(h.rpc.mock.calls.some(([name]) => name === "rpc_my_accounts")).toBe(true)
    expect(screen.getByTestId("account-id").textContent).toBe("acc-p")
  })
})

describe("auth-context — una pestaña desfasada se resincroniza", () => {
  async function renderOneActive() {
    rows = [
      accountRow({ account_id: "acc-p", is_active: true, brand_display_name: "Mi Kiosco" }),
      accountRow({ account_id: "acc-a", is_active: false, brand_display_name: "Ferretería Roca" }),
    ]
    renderWithAuth()
    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-p"))
  }

  it("el aviso account:switched de otra pestaña: limpia la caché, re-resuelve la cuenta y va al Tablero", async () => {
    await renderOneActive()
    // La otra pestaña cambió: ahora la base marca a acc-a como activa.
    rows = rows.map((r) => ({ ...r, is_active: r.account_id === "acc-a" }))
    const clearSpy = vi.spyOn(queryClient, "clear")

    await act(async () => {
      for (const handler of [...h.busHandlers]) handler("account:switched")
    })

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-a"))
    expect(clearSpy).toHaveBeenCalled()
    expect(h.replace).toHaveBeenCalledWith("/dashboard")
    // Lo adoptado NO se reanuncia (lazo entre pestañas).
    expect(h.announceAccountSwitched).not.toHaveBeenCalled()
  })

  it("un 409 account_switched (pedido de resincronización del cliente HTTP) hace lo mismo y avisa al usuario", async () => {
    await renderOneActive()
    rows = rows.map((r) => ({ ...r, is_active: r.account_id === "acc-a" }))
    const clearSpy = vi.spyOn(queryClient, "clear")

    await act(async () => {
      await requestAccountResync("switched")
    })

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-a"))
    expect(clearSpy).toHaveBeenCalled()
    expect(h.replace).toHaveBeenCalledWith("/dashboard")
    expect(h.toast.info).toHaveBeenCalledWith(expect.stringContaining("Ferretería Roca"))
  })
})

describe("auth-context — sin cuenta activa", () => {
  it("con membresías pero ninguna activa (token de una cuenta revocada): renueva el token UNA vez y, si persiste, muestra el error con 'Cerrar sesión'", async () => {
    rows = [
      accountRow({ account_id: "acc-p", is_active: false }),
      accountRow({ account_id: "acc-a", is_active: false }),
    ]

    renderWithAuth()

    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/cuenta activa/i)
    expect(screen.getByRole("button", { name: /cerrar sesión/i })).toBeInTheDocument()
    // Una renovación de recuperación además de la de la carga inicial — no un lazo.
    expect(h.refreshAccessToken.mock.calls.length).toBeLessThanOrEqual(3)
    // ... y la recuperación renueva ANTE EL PROVEEDOR (releer el mismo token no la arregla), una vez.
    expect(h.refreshSessionAction).toHaveBeenCalledTimes(1)
    // Nunca elige otra cuenta en silencio.
    expect(screen.queryByTestId("account-id")).not.toBeInTheDocument()
  })

  it("si tras renovar el token la cuenta activa aparece, no hay pantalla de error", async () => {
    rows = [accountRow({ account_id: "acc-p", is_active: false })]
    let calls = 0
    h.rpc.mockImplementation((name: string) => {
      if (name === "rpc_my_accounts") {
        calls += 1
        return Promise.resolve({ data: calls === 1 ? rows : [accountRow({ account_id: "acc-p", is_active: true })], error: null })
      }
      return Promise.resolve({ data: null, error: null })
    })

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-p"))
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    expect(h.refreshSessionAction).toHaveBeenCalledTimes(1)
  })

  it("'Cerrar sesión' de la pantalla de error cierra la sesión", async () => {
    rows = [accountRow({ account_id: "acc-p", is_active: false })]
    renderWithAuth()

    fireEvent.click(await screen.findByRole("button", { name: /cerrar sesión/i }))

    await waitFor(() => expect(h.signOut).toHaveBeenCalled())
  })
})

describe("auth-context — si rpc_my_accounts falla (ventana de despliegue) cae a la membresía más antigua", () => {
  // El caso real: Vercel publica el frontend apenas se mergea y `supabase db push` corre en otro job
  // del deploy; durante esos minutos `rpc_my_accounts` no existe (PGRST202) y quien recarga quedaba
  // con accountId "" y todas las pantallas rotas, sin aviso. El camino NORMAL sigue siendo la RPC;
  // esto es una salida de emergencia que resuelve la cuenta como antes de la tanda A.
  const OLDEST = {
    account_id: "acc-old",
    role: "owner",
    accounts: {
      billing_plan: "avanzado",
      billing_status: "active",
      trial_plan: null,
      trial_started_at: null,
      trial_expires_at: null,
      billing_exempt: false,
    },
  }

  function rpcFailsWith(error: unknown) {
    h.rpc.mockImplementation((name: string) => {
      if (name === "rpc_my_accounts") return Promise.resolve({ data: null, error })
      return Promise.resolve({ data: null, error: null })
    })
  }

  it("PGRST202 (la función todavía no existe): resuelve la cuenta de su membresía más antigua, la marca activa y avisa por consola", async () => {
    rpcFailsWith({ code: "PGRST202", message: "Could not find the function public.rpc_my_accounts without parameters" })
    h.membership = { data: OLDEST, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-old"))
    expect(screen.getByTestId("account-role").textContent).toBe("owner")
    expect(screen.getByTestId("billing-plan").textContent).toBe("avanzado")
    expect(screen.getByTestId("account-count").textContent).toBe("1")
    // La pantalla declara la cuenta resuelta (X-Account-Id) y no hay pantalla de error.
    expect(getDisplayedAccountId()).toBe("acc-old")
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    // Es un camino de emergencia: queda dicho en la consola, con la causa.
    expect(h.warn).toHaveBeenCalledWith(expect.stringContaining("rpc_my_accounts"), expect.anything())
    expect(h.warn.mock.calls.some(([message]) => /fallback/i.test(String(message)))).toBe(true)
  })

  it("lee la membresía más antigua por (created_at, id) — el criterio previo a la tanda A", async () => {
    rpcFailsWith({ code: "PGRST202", message: "no existe" })
    h.membership = { data: OLDEST, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-old"))
    expect(h.fromTables).toContain("account_members")
    expect(h.membershipOrder).toEqual([
      ["created_at", { ascending: true }],
      ["id", { ascending: true }],
    ])
  })

  it("un error genérico (red, 5xx de PostgREST) hace lo mismo: no es sólo PGRST202", async () => {
    rpcFailsWith({ message: "TypeError: Failed to fetch" })
    h.membership = { data: { ...OLDEST, account_id: "acc-net", role: "member" }, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-net"))
    expect(screen.getByTestId("account-role").textContent).toBe("member")
    expect(h.warn).toHaveBeenCalled()
  })

  it("si la llamada a la RPC RECHAZA (no devuelve un error), también cae al fallback en vez de romper la carga", async () => {
    h.rpc.mockImplementation((name: string) => {
      if (name === "rpc_my_accounts") return Promise.reject(new Error("network down"))
      return Promise.resolve({ data: null, error: null })
    })
    h.membership = { data: OLDEST, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-old"))
    expect(h.warn).toHaveBeenCalled()
  })

  it("si el fallback tampoco encuentra membresía, queda como hoy: sin cuenta, sin pantalla de error y sin romper", async () => {
    rpcFailsWith({ code: "PGRST202", message: "no existe" })
    h.membership = { data: null, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-count").textContent).toBe("0"))
    expect(screen.getByTestId("account-id").textContent).toBe("")
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("si el fallback TAMBIÉN falla, no lanza: sin cuenta y el aviso lo dice", async () => {
    rpcFailsWith({ code: "PGRST202", message: "no existe" })
    h.membership = { data: null, error: { message: "permission denied" } }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-count").textContent).toBe("0"))
    expect(screen.getByTestId("account-id").textContent).toBe("")
    expect(h.warn).toHaveBeenCalled()
  })

  it("con la RPC funcionando el fallback NO se consulta ni se avisa (el camino normal no cambia)", async () => {
    rows = [accountRow({ account_id: "acc-p", is_active: true, brand_display_name: "Mi Kiosco" })]
    // Aunque haya una membresía configurada, no debe leerse: la RPC manda.
    h.membership = { data: OLDEST, error: null }

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-p"))
    expect(h.fromTables).not.toContain("account_members")
    expect(h.warn.mock.calls.some(([message]) => /rpc_my_accounts/.test(String(message)))).toBe(false)
  })
})
