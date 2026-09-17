/**
 * auth-hardening-jwt-cookies — Parte C, D18, task 19.4b (la mitad de pantalla).
 *
 * `/auth/verify-email` detectaba la verificación con cuatro operaciones del
 * cliente de navegador: `refreshSession()`, `getSession()` ×2 y
 * `onAuthStateChange`. Con `accessToken` configurado (19.6) las cuatro **lanzan**
 * (`supabase-js/index.mjs:389`), así que la pantalla que mira todo usuario nuevo
 * se quedaría en "Esperando confirmación…" para siempre.
 *
 * Acá se fija el reemplazo: la pantalla sondea `GET /api/auth/status` y ya no
 * toca `supabase.auth`. El candado de que no queda ninguna llamada residual es
 * `__tests__/lib/no-browser-auth-calls.test.ts` (19.7); lo que este archivo
 * prueba es que el mecanismo **nuevo** funciona de verdad.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act, waitFor } from "@testing-library/react"
import React from "react"

const pushMock = vi.fn()
const fetchMock = vi.fn()
/**
 * H-5: la pantalla fuerza la renovación de la sesión de la app por el contexto
 * antes de navegar. El doble es la función, no el objeto: `refreshSession` viaja en
 * la lista de dependencias de `handleVerified`, así que una identidad nueva por
 * render volvería a montar los efectos del sondeo y dejaría vacuas las aserciones
 * de "cuántas veces consultó".
 */
const refreshSessionMock = vi.fn<() => Promise<boolean>>()

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ refreshSession: refreshSessionMock }),
}))

vi.mock("@/app/auth/actions", () => ({
  resendVerificationEmailAction: vi.fn().mockResolvedValue({ ok: true }),
}))

// Objeto ESTABLE: `useRouter()` real lo es, y un doble que devuelva uno nuevo en
// cada render cambia la identidad de `checkVerification` y hace que el efecto de
// montaje vuelva a consultar en cada re-render. Eso convertía en vacua cualquier
// aserción sobre "cuántas veces consultó" (task 20.3).
const routerDoble = { push: pushMock }

vi.mock("next/navigation", () => ({
  useRouter: () => routerDoble,
  useSearchParams: () => new URLSearchParams(""),
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))

import VerifyEmailPage from "@/app/auth/verify-email/page"
import { FakeBroadcastChannel } from "../lib/fake-broadcast-channel"
import { closeSessionBus } from "@/lib/auth/session-bus"
import { createIdleTransport } from "@/lib/auth/idle-transport"

function statusResponse(body: Record<string, unknown>): Response {
  return {
    ok: true,
    status: 200,
    json: async () => body,
  } as unknown as Response
}

const SIN_VERIFICAR = { email: "susana@test.local", email_confirmed_at: null }
const VERIFICADO = { email: "susana@test.local", email_confirmed_at: "2026-09-16T12:00:00Z" }

/** URLs a las que la pantalla pidió algo. */
function requestedUrls(): string[] {
  return fetchMock.mock.calls.map(([url]) => String(url))
}

beforeEach(() => {
  pushMock.mockReset()
  // Por defecto, tras renovar hay sesión: es el caso frecuente (el usuario
  // confirmó en este mismo navegador).
  refreshSessionMock.mockReset().mockResolvedValue(true)
  fetchMock.mockReset().mockResolvedValue(statusResponse(SIN_VERIFICAR))
  vi.stubGlobal("fetch", fetchMock)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe("/auth/verify-email — sondeo contra GET /api/auth/status", () => {
  it("consulta el endpoint al montar", async () => {
    render(<VerifyEmailPage />)

    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(requestedUrls()[0]).toContain("/api/auth/status")
  })

  it("resuelve el email desde el endpoint cuando no viene en la URL", async () => {
    render(<VerifyEmailPage />)

    // Sin el `?email=`, el único lugar de donde puede salir es el servidor: antes
    // era un `getSession()` del navegador.
    expect(await screen.findByText("susana@test.local")).toBeInTheDocument()
  })

  it("con email_confirmed_at presente muestra el éxito y navega al dashboard", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))

    render(<VerifyEmailPage />)

    expect(await screen.findByText("Email verificado")).toBeInTheDocument()
    await act(async () => {
      vi.advanceTimersByTime(1600)
    })
    expect(pushMock).toHaveBeenCalledWith("/dashboard")
  })

  it("sin verificar sigue esperando y NO navega", async () => {
    render(<VerifyEmailPage />)

    expect(await screen.findByText(/esperando confirmación/i)).toBeInTheDocument()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("vuelve a consultar cada 4 s mientras no esté verificado", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    render(<VerifyEmailPage />)
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const iniciales = fetchMock.mock.calls.length

    await act(async () => {
      vi.advanceTimersByTime(4100)
    })

    expect(fetchMock.mock.calls.length).toBeGreaterThan(iniciales)
  })

  it("una respuesta con error no rompe la pantalla: sigue esperando", async () => {
    fetchMock.mockRejectedValue(new Error("red caída"))

    render(<VerifyEmailPage />)

    expect(await screen.findByText(/esperando confirmación/i)).toBeInTheDocument()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("la consulta viaja con las cookies del propio origen", async () => {
    render(<VerifyEmailPage />)
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())

    // Sin credenciales del mismo origen el endpoint no ve la cookie `HttpOnly` y
    // la pantalla nunca detectaría la verificación.
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit | undefined]
    expect(init?.credentials).toBe("same-origin")
    expect(init?.cache).toBe("no-store")
  })

  it("al volver a la pestaña vuelve a consultar", async () => {
    render(<VerifyEmailPage />)
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const iniciales = fetchMock.mock.calls.length

    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"))
    })

    expect(fetchMock.mock.calls.length).toBeGreaterThan(iniciales)
  })
})

// ── H-5 (humo local del 2026-09-18): renovar ANTES de entrar ─────────────────
//
// La pantalla detectaba la verificación y navegaba al dashboard **sin** forzar la
// renovación del access token en memoria. El store cachea a propósito el estado
// "no hay sesión" (regla 3 de `lib/auth/access-token-store.ts`), así que el primer
// render del dashboard de una cuenta nueva salía con la anon key: "permission
// denied for function get_dashboard_financials" más cuatro 401
// (`humos/humo-final/R1-registro.txt`). En producción, con la confirmación de email
// obligatoria, pasa cuando el usuario confirma el mail en OTRA pestaña del mismo
// navegador: `/auth/callback` escribe las cookies allá y esta pestaña —que sondea
// `/api/auth/status`— detecta la verificación con su store todavía en "sin sesión".
//
// Es transitorio (las cargas siguientes andan), y es la primerísima pantalla de
// todo usuario nuevo.

describe("/auth/verify-email — H-5: la sesión se renueva antes de navegar", () => {
  it("no navega hasta que la renovación terminó", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))
    let liberarRenovacion: (haySesion: boolean) => void = () => {}
    refreshSessionMock.mockImplementation(
      () =>
        new Promise<boolean>((resolve) => {
          liberarRenovacion = resolve
        }),
    )

    render(<VerifyEmailPage />)

    expect(await screen.findByText("Email verificado")).toBeInTheDocument()
    await waitFor(() => expect(refreshSessionMock).toHaveBeenCalled())

    // El cartel corre su tiempo completo y de sobra: la navegación sigue esperando
    // la renovación, que es todo el punto del arreglo.
    await act(async () => {
      vi.advanceTimersByTime(5000)
    })
    expect(pushMock).not.toHaveBeenCalled()

    await act(async () => {
      liberarRenovacion(true)
    })
    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/dashboard"))
  })

  it("con sesión tras renovar entra al dashboard", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))
    refreshSessionMock.mockResolvedValue(true)

    render(<VerifyEmailPage />)
    expect(await screen.findByText("Email verificado")).toBeInTheDocument()

    await act(async () => {
      vi.advanceTimersByTime(1600)
    })

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/dashboard"))
    expect(refreshSessionMock).toHaveBeenCalled()
  })

  it("(triangulate) sin sesión tras renovar va al login, conservando el cartel de éxito", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))
    // El caso real: el usuario abrió el enlace en otro dispositivo, así que ESTE
    // navegador no tiene cookies de sesión. Mandarlo al dashboard es mandarlo a una
    // pantalla que no puede leer nada.
    refreshSessionMock.mockResolvedValue(false)

    render(<VerifyEmailPage />)
    expect(await screen.findByText("Email verificado")).toBeInTheDocument()

    await act(async () => {
      vi.advanceTimersByTime(1600)
    })

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/auth/login"))
    expect(pushMock).not.toHaveBeenCalledWith("/dashboard")
    // La verificación SÍ ocurrió: el cartel es el de éxito, no un error.
    expect(screen.getByText("Email verificado")).toBeInTheDocument()
    // Y no promete un dashboard al que no va a llevar.
    expect(screen.getByText(/iniciá sesión/i)).toBeInTheDocument()
  })

  it("(triangulate) si la renovación falla no queda colgada en el cartel: va al login", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))
    // `refreshSession()` no rechaza por contrato (captura todo adentro), pero
    // quedarse para siempre en "Email verificado" —sin navegar nunca— sería el peor
    // modo de falla posible en la primerísima pantalla de una cuenta nueva. Y el
    // destino del rechazo no puede ser el dashboard: una renovación que no se pudo
    // confirmar no es una sesión viva, que es justo lo que H-5 cierra.
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})
    refreshSessionMock.mockRejectedValue(new Error("red caída"))

    render(<VerifyEmailPage />)
    expect(await screen.findByText("Email verificado")).toBeInTheDocument()

    await act(async () => {
      vi.advanceTimersByTime(1600)
    })

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/auth/login"))
    expect(pushMock).not.toHaveBeenCalledWith("/dashboard")
    // El cartel no promete un dashboard al que no va a llevar, igual que en el caso
    // de "no hay sesión".
    expect(screen.getByText(/iniciá sesión/i)).toBeInTheDocument()
    // El fallo no se traga en silencio: sin rastro, una renovación que rechaza
    // siempre se vería desde afuera como "este navegador no tenía sesión".
    expect(consoleError).toHaveBeenCalled()
    consoleError.mockRestore()
  })

  it("sin verificar no renueva nada (la renovación no es un efecto de montaje)", async () => {
    render(<VerifyEmailPage />)

    expect(await screen.findByText(/esperando confirmación/i)).toBeInTheDocument()
    expect(refreshSessionMock).not.toHaveBeenCalled()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("renueva una sola vez aunque el sondeo siga corriendo", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    fetchMock.mockResolvedValue(statusResponse(VERIFICADO))

    render(<VerifyEmailPage />)
    expect(await screen.findByText("Email verificado")).toBeInTheDocument()

    await act(async () => {
      vi.advanceTimersByTime(20_000)
    })

    // `redirectingRef` ya frenaba el sondeo; esto fija que la renovación no se
    // cuele por fuera de ese guard y dispare un pedido cada 4 s.
    expect(refreshSessionMock).toHaveBeenCalledTimes(1)
  })
})

// ── task 20.3: la segunda suscripción a `onAuthStateChange` pasa al bus ───────
//
// Esta pantalla tenía la otra de las dos suscripciones que el change retira
// (`app/auth/verify-email/page.tsx:113`). El sondeo de 4 s es el mecanismo
// PRINCIPAL de detección (D18) y no cambia; lo que el bus agrega es que un evento
// de sesión de otra pestaña se mire **ya**, sin esperar el próximo tic.

describe("/auth/verify-email — bus de eventos de sesión (task 20.3)", () => {
  beforeEach(() => {
    vi.stubGlobal("BroadcastChannel", FakeBroadcastChannel)
    FakeBroadcastChannel.reset()
    closeSessionBus()
  })

  afterEach(() => {
    closeSessionBus()
    FakeBroadcastChannel.reset()
  })

  /** Sólo las consultas de estado: el bus también pide el token, y esa no cuenta. */
  function statusCalls(): number {
    return requestedUrls().filter((url) => url.includes("/api/auth/status")).length
  }

  it("un evento de sesión de otra pestaña dispara una consulta inmediata de estado", async () => {
    render(<VerifyEmailPage />)
    await waitFor(() => expect(statusCalls()).toBeGreaterThan(0))
    const antes = statusCalls()

    const peer = createIdleTransport()
    peer.post({ type: "session:signed-in" })

    await waitFor(() => expect(statusCalls()).toBeGreaterThan(antes))

    peer.close()
  })

  it("un mensaje del temporizador de inactividad no dispara nada acá", async () => {
    render(<VerifyEmailPage />)
    await waitFor(() => expect(statusCalls()).toBeGreaterThan(0))
    const antes = statusCalls()

    const peer = createIdleTransport()
    peer.postActivity(Date.now())
    peer.postLogout()
    await new Promise((resolve) => setTimeout(resolve, 10))

    // `activity` y `logout` son del temporizador: esta pantalla no los interpreta.
    expect(statusCalls()).toBe(antes)

    peer.close()
  })
})
