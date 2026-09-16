/**
 * auth-hardening-jwt-cookies — D5, tasks 13.5 y 13.6.
 *
 * El middleware escribe las cookies de sesión renovadas sobre `supabaseResponse`
 * (a través de `setAll`), pero cada salida por redirect construye su **propia**
 * `NextResponse` y no las copiaba. Hoy es autocurativo —el redirect vuelve a
 * entrar por el matcher dentro de la ventana de `refresh_token_reuse_interval`—
 * pero la receta de `@supabase/ssr` es copiarlas.
 *
 * La copia es para los redirects que **no** cierran la sesión (B3 de la revisión
 * adversarial). Las dos ramas cuyo trabajo ES destruirla —la purga de la sesión
 * muerta y el corte por inactividad— no reciben copia: reponerles encima las
 * cookies recién escritas desactivaría en silencio la recuperación de
 * "Refresh Token Not Found" y el propio corte por inactividad.
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

const ROTATED = {
  name: "sb-project-auth-token",
  value: "base64-rotado",
  options: { path: "/", sameSite: "lax" as const },
}

const STALE_SESSION_COOKIE = { "sb-project-auth-token": "base64-viejo" }

const CONFIRMED_USER = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }
const FRESH_ACTIVITY = () => String(Date.now())
const STALE_ACTIVITY = () => String(Date.now() - IDLE_TIMEOUT_MS - 1_000)

beforeEach(() => {
  resetHarness()
  harness.cookiesToRotate = [ROTATED]
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

function rotatedCookieLine(response: Response): string | undefined {
  return sessionCookieLines(response).find((line) =>
    line.startsWith(`${ROTATED.name}=${ROTATED.value}`),
  )
}

// ── 13.5: los redirects NO destructivos conservan la renovación ────────────
describe("redirects no destructivos — conservan las cookies renovadas", () => {
  it("email sin confirmar", async () => {
    harness.user = { id: "u1", email_confirmed_at: null }

    const response = await updateSession(
      buildRequest("/caja", { ...STALE_SESSION_COOKIE, "auth:last-activity": FRESH_ACTIVITY() }),
    )

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/auth/verify-email")
    expect(rotatedCookieLine(response)).toBeDefined()
  })

  it("bounce de admin (usuario sin rol admin en /admin)", async () => {
    harness.user = CONFIRMED_USER
    harness.profileRole = "user"

    const response = await updateSession(
      buildRequest("/admin", { ...STALE_SESSION_COOKIE, "auth:last-activity": FRESH_ACTIVITY() }),
    )

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/dashboard")
    expect(rotatedCookieLine(response)).toBeDefined()
  })

  it("usuario autenticado que pide una ruta de auth", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/auth/login", STALE_SESSION_COOKIE),
    )

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/dashboard")
    expect(rotatedCookieLine(response)).toBeDefined()
  })

  it("la salida ordinaria (sin redirect) también las lleva — no-regresión", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/caja", { ...STALE_SESSION_COOKIE, "auth:last-activity": FRESH_ACTIVITY() }),
    )

    expect(isRedirect(response)).toBe(false)
    expect(rotatedCookieLine(response)).toBeDefined()
  })
})

// ── 13.6 (test negativo, obligatorio) ──────────────────────────────────────
describe("redirects destructivos — NO reponen ninguna cookie de sesión", () => {
  it("purga de sesión muerta (Refresh Token Not Found)", async () => {
    harness.user = null
    harness.authError = { message: "AuthApiError: Refresh Token Not Found" }

    const response = await updateSession(buildRequest("/caja", STALE_SESSION_COOKIE))

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/auth/login")

    const lines = sessionCookieLines(response)
    expect(lines.length).toBeGreaterThan(0) // el borrado sí se emite
    for (const line of lines) {
      expect(line, `no es un borrado: ${line}`).toSatisfy(isCookieDeletion)
    }
    expect(rotatedCookieLine(response)).toBeUndefined()
  })

  it("corte por inactividad del servidor", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/caja", {
        ...STALE_SESSION_COOKIE,
        "auth:last-activity": STALE_ACTIVITY(),
      }),
    )

    expect(isRedirect(response)).toBe(true)
    const target = new URL(redirectTarget(response)!)
    expect(target.pathname).toBe("/auth/login")
    expect(target.searchParams.get("reason")).toBe("idle")

    const lines = sessionCookieLines(response)
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, `no es un borrado: ${line}`).toSatisfy(isCookieDeletion)
    }
    expect(rotatedCookieLine(response)).toBeUndefined()
  })

  it("el corte por inactividad también borra las cookies de experiencia", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/caja", {
        ...STALE_SESSION_COOKIE,
        "auth:last-activity": STALE_ACTIVITY(),
        "tenant:active": "acc-1",
      }),
    )

    const all = response.headers.getSetCookie()
    const lastActivity = all.find((l) => l.startsWith("auth:last-activity="))
    const tenant = all.find((l) => l.startsWith("tenant:active="))
    expect(lastActivity).toBeDefined()
    expect(tenant).toBeDefined()
    expect(isCookieDeletion(lastActivity!)).toBe(true)
    expect(isCookieDeletion(tenant!)).toBe(true)
  })
})
