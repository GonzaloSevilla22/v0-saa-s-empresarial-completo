/**
 * auth-context — H-5 del humo local del 2026-09-18: la sesión recién nacida se
 * adopta ANTES de que el llamador navegue.
 *
 * `lib/auth/access-token-store.ts` cachea a propósito el estado "no hay sesión"
 * (`absent`) para que cada página pública no dispare una tormenta de pedidos
 * contra `GET /api/auth/token` (regla 3 de su encabezado). La contracara es que
 * **quien sabe que la sesión acaba de nacer tiene que forzar la renovación**: el
 * login ya lo hacía (`signInWithPasswordAction` → `refreshSession()` →
 * `refreshAccessToken()` forzado → `router.push`), pero `register()` no.
 *
 * Síntoma medido en el primer render del dashboard de una cuenta recién
 * registrada (`humos/humo-final/R1-registro.txt`): "permission denied for
 * function get_dashboard_financials" + cuatro 401, porque las llamadas salieron
 * con la anon key — `getAccessToken()` resolvió `null` con el store todavía en
 * "sin sesión".
 *
 * Acá se fija el contrato del que depende el arreglo entero:
 *
 *  1. `register()` fuerza la renovación y no devuelve el control hasta que ocurrió.
 *  2. `refreshSession()` **informa** si tras renovar hay sesión viva — es lo que
 *     `/auth/verify-email` necesita para elegir entre `/dashboard` y `/auth/login`.
 *
 * El (2) no es un detalle de implementación: la suite de la pantalla mockea el
 * contexto, así que sin este archivo el valor de retorno sería una suposición.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/auth/access-token-store, @/app/auth/actions, @/lib/supabase/client,
 *       next/navigation
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { AuthProvider, useAuth } from "@/contexts/auth-context"

// ── Dobles ──────────────────────────────────────────────────────────────────

/** Las tres resoluciones del manejador del token, tal como las devuelve el store. */
type Resolucion =
  | {
      status: "active"
      token: string
      expiresAt: number | null
      user: { id: string; email: string | null; name: string | null }
    }
  | { status: "absent" }
  | { status: "unknown" }

const SIN_SESION: Resolucion = { status: "absent" }
const NO_SE_PUDO: Resolucion = { status: "unknown" }
const CON_SESION: Resolucion = {
  status: "active",
  token: "tok-recien-nacido",
  expiresAt: Math.floor(Date.now() / 1000) + 3600,
  user: { id: "user-nuevo", email: "nueva@test.local", name: "Nueva" },
}

/**
 * Bitácora de orden. Lo que el arreglo promete no es "se llama a las dos cosas",
 * es que la renovación ocurra **antes** de que el llamador pueda navegar: sin el
 * orden, la aserción no distingue el arreglo del defecto.
 */
const bitacora: string[] = []
let resolucion: Resolucion = SIN_SESION

const refreshAccessTokenMock = vi.fn(async (): Promise<Resolucion> => {
  bitacora.push("refresh")
  return resolucion
})
const signUpMock = vi.fn()

vi.mock("@/lib/auth/access-token-store", () => ({
  refreshAccessToken: () => refreshAccessTokenMock(),
  // task 20.3: el contexto monta el bus de sesión, que se apoya en el almacén del
  // token para anunciar sus renovaciones. Sin este doble el módulo real del bus no
  // resuelve su import y la suite entera muere en la recolección.
  subscribeToAccessToken: () => () => {},
}))

vi.mock("@/app/auth/actions", () => ({
  signUpAction: (...args: unknown[]) => signUpMock(...args),
  signInWithPasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  signInWithMagicLinkAction: vi.fn().mockResolvedValue({ ok: true }),
  signOutAction: vi.fn().mockResolvedValue({ ok: true }),
  updatePasswordAction: vi.fn().mockResolvedValue({ ok: true }),
  requestEmailChangeAction: vi.fn().mockResolvedValue({ ok: true }),
}))

/**
 * Cadena de PostgREST para `account_members`, con la forma real que recorre el
 * contexto (`eq/order/order/limit/maybeSingle`) — la misma del doble de
 * `auth-context-membership.test.tsx`. Sin `order` la rama con sesión viva muere en
 * el `catch` y el test no probaría nada.
 */
interface MembersChain {
  eq: () => MembersChain
  order: () => MembersChain
  limit: () => MembersChain
  maybeSingle: () => Promise<{ data: null; error: null }>
}

function membersChain(): MembersChain {
  const chain: MembersChain = {
    eq: () => chain,
    order: () => chain,
    limit: () => chain,
    maybeSingle: () => Promise.resolve({ data: null, error: null }),
  }
  return chain
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      if (table === "profiles") {
        return {
          select: () => ({
            eq: () => ({ single: () => Promise.resolve({ data: null, error: null }) }),
          }),
        }
      }
      if (table === "account_members") {
        return { select: () => ({ eq: () => membersChain() }) }
      }
      throw new Error(`Tabla no mockeada en este test: ${table}`)
    },
  }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
}))

// ── Consumidor ──────────────────────────────────────────────────────────────

function Consumer() {
  const { register, refreshSession, isAuthenticated } = useAuth()
  const [resultado, setResultado] = React.useState("")
  return (
    <div>
      <span data-testid="autenticado">{isAuthenticated ? "si" : "no"}</span>
      <span data-testid="refresh-session">{resultado}</span>
      {/* Modela al llamador real (`app/auth/register/page.tsx`), que navega recién
          cuando `register()` resuelve. */}
      <button
        onClick={() => {
          void register("Nueva", "nueva@test.local", "Passw0rd!")
            .then(() => {
              bitacora.push("navigate")
            })
            // La pantalla real muestra el error en un toast y NO navega; acá basta
            // con anotarlo para que el caso de fallo pueda assertearlo.
            .catch(() => {
              bitacora.push("error")
            })
        }}
      >
        register-y-navegar
      </button>
      <button
        onClick={() => {
          void refreshSession().then((hay) => setResultado(hay ? "con-sesion" : "sin-sesion"))
        }}
      >
        refresh-session
      </button>
    </div>
  )
}

/**
 * Renderiza y espera la renovación **del montaje** (el contexto resuelve la
 * identidad al montar), y recién entonces limpia la bitácora: sin esto, la
 * renovación del montaje hace pasar por verde una bitácora que no tiene la del
 * registro.
 */
async function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Consumer />
      </AuthProvider>
    </QueryClientProvider>,
  )
  const boton = await screen.findByText("register-y-navegar")
  await waitFor(() => expect(bitacora).toContain("refresh"))
  bitacora.length = 0
  return boton
}

beforeEach(() => {
  bitacora.length = 0
  resolucion = SIN_SESION
  refreshAccessTokenMock.mockClear()
  signUpMock.mockReset().mockResolvedValue({ ok: true })
})

describe("auth-context register() — adopta la sesión recién nacida (H-5)", () => {
  it("fuerza la renovación del token ANTES de devolverle el control al llamador", async () => {
    const boton = await montar()

    fireEvent.click(boton)

    await waitFor(() => expect(bitacora).toContain("navigate"))
    // El orden es el arreglo: con la renovación después de la navegación, el
    // dashboard abre con la anon key y devuelve 401 (H-5).
    expect(bitacora).toEqual(["refresh", "navigate"])
  })

  it("(triangulate) con la confirmación de email apagada la sesión queda adoptada, no sólo pedida", async () => {
    const boton = await montar()
    // El montaje ocurrió en una página anónima: el store cacheó "no hay sesión".
    expect(screen.getByTestId("autenticado").textContent).toBe("no")

    // `signUpAction` deja sesión viva (entorno sin confirmación obligatoria).
    resolucion = CON_SESION
    fireEvent.click(boton)

    await waitFor(() => expect(screen.getByTestId("autenticado").textContent).toBe("si"))
    // Se miran las DOS primeras entradas, no la bitácora completa: adoptar la
    // sesión cambia el estado del proveedor, y como `refreshSession` se reconstruye
    // en cada render del proveedor (`createClient()` por render), su efecto de
    // montaje vuelve a resolver la identidad y anota una renovación más. Es
    // comportamiento preexistente del contexto —el login hace lo mismo— y ajeno a
    // este arreglo; lo que se fija acá es el ORDEN de la primera.
    expect(bitacora.slice(0, 2)).toEqual(["refresh", "navigate"])
  })

  it("(triangulate) con la confirmación encendida no hay sesión y el registro termina bien igual", async () => {
    const boton = await montar()
    resolucion = SIN_SESION

    fireEvent.click(boton)

    await waitFor(() => expect(bitacora).toContain("navigate"))
    // El destino del registro no cambia (`/auth/verify-email`, lo elige la
    // pantalla): lo único que este archivo fija es que renovar no rompa el camino
    // normal, donde todavía NO hay sesión.
    expect(screen.getByTestId("autenticado").textContent).toBe("no")
  })

  it("un error de la acción sigue abortando antes de tocar la sesión", async () => {
    signUpMock.mockResolvedValue({ ok: false, error: "User already registered" })
    const boton = await montar()

    fireEvent.click(boton)

    // No hay nada que adoptar: la cuenta no se creó. Y el llamador no navega,
    // porque `register()` lanza.
    await waitFor(() => expect(bitacora).toContain("error"))
    expect(bitacora).toEqual(["error"])
  })
})

describe("auth-context refreshSession() — informa si quedó sesión viva", () => {
  it("resuelve true cuando el manejador entrega un token activo", async () => {
    await montar()
    resolucion = CON_SESION

    fireEvent.click(screen.getByText("refresh-session"))

    await waitFor(() =>
      expect(screen.getByTestId("refresh-session").textContent).toBe("con-sesion"),
    )
  })

  it("(triangulate) resuelve false cuando el manejador dice que no hay sesión", async () => {
    await montar()
    resolucion = SIN_SESION

    fireEvent.click(screen.getByText("refresh-session"))

    await waitFor(() =>
      expect(screen.getByTestId("refresh-session").textContent).toBe("sin-sesion"),
    )
  })

  it("(triangulate) y también false cuando no se pudo averiguar (`unknown`)", async () => {
    // "No pude averiguarlo" no es "hay sesión": tratarlo como sesión viva es
    // exactamente el camino que deja al dashboard hablando con la anon key.
    await montar()
    resolucion = NO_SE_PUDO

    fireEvent.click(screen.getByText("refresh-session"))

    await waitFor(() =>
      expect(screen.getByTestId("refresh-session").textContent).toBe("sin-sesion"),
    )
  })

  it("fuerza la renovación en cada llamada (no lee lo cacheado)", async () => {
    await montar()
    refreshAccessTokenMock.mockClear()

    fireEvent.click(screen.getByText("refresh-session"))

    // `refreshAccessToken()` es la variante FORZADA del store: es lo único que
    // invalida un "no hay sesión" cacheado.
    await waitFor(() => expect(refreshAccessTokenMock).toHaveBeenCalledTimes(1))
  })
})
