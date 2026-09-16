/**
 * auth-hardening-jwt-cookies — D6, task 14.5.
 *
 * La rama idle del middleware borraba las cookies `sb-*` y redirigía, pero la
 * sesión **seguía viva en GoTrue**: no había un solo `signOut` en
 * `lib/supabase/middleware.ts` (auditoría 2026-09-14 §3). Su refresh token
 * quedaba utilizable desde cualquier copia que se hubiera hecho — exactamente
 * el caso que el resto de este change pretende volver imposible de explotar.
 * Cerrarlo del lado del emisor es gratis.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import {
  harness,
  resetHarness,
  buildRequest,
  isRedirect,
  redirectTarget,
  sessionCookieLines,
  isCookieDeletion,
} from "./helpers/middleware-harness"
import { updateSession } from "@/lib/supabase/middleware"
import { IDLE_TIMEOUT_MS } from "@/lib/auth/idle-config"

const CONFIRMED_USER = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }
const SESSION_COOKIE = { "sb-project-auth-token": "base64-vivo" }
const staleActivity = () => String(Date.now() - IDLE_TIMEOUT_MS - 1_000)
const freshActivity = () => String(Date.now())

beforeEach(() => {
  resetHarness()
  // Sin esto, un `vi.spyOn(console, "warn")` de un caso anterior sigue vivo y su
  // historial se acumula: el control negativo de la revocación fallida lo
  // detectó (veía 2 llamadas de los casos previos).
  vi.restoreAllMocks()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

describe("corte por inactividad del servidor — revoca contra el proveedor", () => {
  it("llama a signOut", async () => {
    harness.user = CONFIRMED_USER

    await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(harness.signOutCalls).toHaveLength(1)
  })

  it("con alcance local: el corte por inactividad de un dispositivo no cierra los otros", async () => {
    harness.user = CONFIRMED_USER

    await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(harness.signOutCalls[0]).toEqual({ scope: "local" })
  })

  it("revoca ANTES de emitir los borrados de cookies", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    // La revocación ocurrió durante la petición…
    expect(harness.events).toEqual(["getUser", "signOut"])
    // …y la respuesta que sale sólo lleva borrados de sesión.
    const lines = sessionCookieLines(response)
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, `no es un borrado: ${line}`).toSatisfy(isCookieDeletion)
    }
  })

  it("si el proveedor falla, el cierre sigue: redirige y borra igual", async () => {
    harness.user = CONFIRMED_USER
    harness.signOutRejects = true

    const response = await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(harness.signOutCalls).toHaveLength(1)
    expect(isRedirect(response)).toBe(true)
    const target = new URL(redirectTarget(response)!)
    expect(target.pathname).toBe("/auth/login")
    expect(target.searchParams.get("reason")).toBe("idle")

    // El borrado de cookies no puede quedar condicionado a que GoTrue conteste:
    // si lo estuviera, una caída del proveedor dejaría la sesión abierta en el
    // navegador sin ningún corte.
    const lines = sessionCookieLines(response)
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, `no es un borrado: ${line}`).toSatisfy(isCookieDeletion)
    }
  })
})

// ── Revisión adversarial (MINOR 3) ─────────────────────────────────────────
// El `try/catch` cubría sólo el caso en que `signOut` **lanza**, y auth-js no
// lanza en el caso normal de fallo: `_signOut` se come 401/403/404 y **devuelve**
// `{ error }` para el resto (p. ej. un 5xx de GoTrue). Sin destructurar ese
// error, la sesión quedaba viva en el emisor sin una sola línea de log —
// justo el estado que D6 existe para cerrar. `performIdleLogout` sí inspecciona
// el error y loguea: el contraste vivía dentro del mismo change.
describe("corte por inactividad — una revocación fallida no queda en silencio", () => {
  it("avisa cuando el proveedor devuelve error sin lanzar", async () => {
    harness.user = CONFIRMED_USER
    harness.signOutReturnsError = true
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(warn).toHaveBeenCalled()
    const logueado = warn.mock.calls.flat().map(String).join(" ")
    expect(logueado).toMatch(/503|Service Unavailable/)
  })

  it("y borra y redirige igual: el corte no queda condicionado al proveedor", async () => {
    harness.user = CONFIRMED_USER
    harness.signOutReturnsError = true
    vi.spyOn(console, "warn").mockImplementation(() => {})

    const response = await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(isRedirect(response)).toBe(true)
    const lines = sessionCookieLines(response)
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, `no es un borrado: ${line}`).toSatisfy(isCookieDeletion)
    }
  })

  it("control negativo: una revocación exitosa NO emite ninguna advertencia", async () => {
    harness.user = CONFIRMED_USER
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": staleActivity() }),
    )

    expect(harness.signOutCalls).toHaveLength(1)
    expect(warn).not.toHaveBeenCalled()
  })
})

describe("no se revoca fuera del corte por inactividad", () => {
  it("una sesión activa no dispara signOut", async () => {
    harness.user = CONFIRMED_USER

    await updateSession(
      buildRequest("/caja", { ...SESSION_COOKIE, "auth:last-activity": freshActivity() }),
    )

    expect(harness.signOutCalls).toHaveLength(0)
  })

  it("una petición sin sesión tampoco (no hay nada que revocar)", async () => {
    harness.user = null

    await updateSession(buildRequest("/caja"))

    expect(harness.signOutCalls).toHaveLength(0)
  })

  it("la purga de sesión muerta tampoco: su refresh token ya no existe", async () => {
    harness.user = null
    harness.authError = { message: "AuthApiError: Refresh Token Not Found" }

    await updateSession(buildRequest("/caja", SESSION_COOKIE))

    expect(harness.signOutCalls).toHaveLength(0)
  })

  it("la primera visita sin cookie de actividad siembra en vez de cerrar", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(buildRequest("/caja", SESSION_COOKIE))

    expect(harness.signOutCalls).toHaveLength(0)
    expect(isRedirect(response)).toBe(false)
  })
})
