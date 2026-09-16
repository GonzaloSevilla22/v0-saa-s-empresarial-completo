/**
 * auth-hardening-jwt-cookies — D6, task 14.6.
 *
 * El bounce del **primer** re-login después de un cierre por inactividad
 * (fila 5 de §8 de la auditoría): `performIdleLogout` borraba sólo
 * `tenant:active`, así que `auth:last-activity` sobrevivía con `max-age` de una
 * semana (`lib/cookies.ts:43`). En el reingreso el middleware la leía vencida,
 * entraba en la rama idle y **descartaba las cookies `sb-*` recién emitidas**
 * por el login. El usuario tenía que iniciar sesión dos veces.
 *
 * Era autocurativo al segundo intento —esa misma respuesta borra la cookie—
 * pero el primer intento se perdía.
 *
 * Este test recorre los dos lados: el cierre por inactividad borra de verdad la
 * cookie de actividad (módulo real de cookies, `document.cookie` de jsdom), y
 * el middleware con esa cookie ausente deja pasar en el primer intento.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const signOutMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { signOut: signOutMock } }),
}))

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import { performIdleLogout } from "@/lib/auth/idle-logout"
import { updateSession } from "@/lib/supabase/middleware"
import { COOKIE_KEYS, setCookie, getClientCookie } from "@/lib/cookies"
import { IDLE_TIMEOUT_MS } from "@/lib/auth/idle-config"
import {
  harness,
  resetHarness,
  buildRequest,
  isRedirect,
  redirectTarget,
} from "./helpers/middleware-harness"

const CONFIRMED_USER = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }
const FRESH_SESSION_COOKIE = { "sb-project-auth-token": "base64-recien-emitida" }
const staleActivity = () => String(Date.now() - IDLE_TIMEOUT_MS - 1_000)

beforeEach(() => {
  resetHarness()
  signOutMock.mockReset().mockResolvedValue({ error: null })
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

describe("re-login inmediato tras un cierre por inactividad", () => {
  it("el cierre por inactividad borra de verdad la cookie de actividad", async () => {
    setCookie(COOKIE_KEYS.LAST_ACTIVITY, staleActivity())
    expect(getClientCookie(COOKIE_KEYS.LAST_ACTIVITY)).not.toBeNull()

    await performIdleLogout({ push: vi.fn() }, "/caja")

    expect(getClientCookie(COOKIE_KEYS.LAST_ACTIVITY)).toBeNull()
  })

  it("con la cookie de actividad ya borrada, la primera navegación NO rebota", async () => {
    harness.user = CONFIRMED_USER

    // Estado del navegador después del re-login: cookies de sesión frescas y
    // ninguna cookie de actividad (la borró el cierre por inactividad).
    const response = await updateSession(buildRequest("/caja", FRESH_SESSION_COOKIE))

    expect(isRedirect(response)).toBe(false)
    // Y el middleware siembra la línea de base para la petición siguiente.
    const seeded = response.headers
      .getSetCookie()
      .find((line) => line.startsWith(`${COOKIE_KEYS.LAST_ACTIVITY}=`))
    expect(seeded).toBeDefined()
    expect(seeded).not.toMatch(/max-age=0/i)
  })

  it("contraste — si la cookie vencida sobreviviera, el primer intento SÍ rebotaría", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(
      buildRequest("/caja", {
        ...FRESH_SESSION_COOKIE,
        [COOKIE_KEYS.LAST_ACTIVITY]: staleActivity(),
      }),
    )

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).searchParams.get("reason")).toBe("idle")
  })

  it("la segunda navegación tampoco rebota (la sembrada es fresca)", async () => {
    harness.user = CONFIRMED_USER

    const first = await updateSession(buildRequest("/caja", FRESH_SESSION_COOKIE))
    const seededLine = first.headers
      .getSetCookie()
      .find((line) => line.startsWith(`${COOKIE_KEYS.LAST_ACTIVITY}=`))!
    const seededValue = seededLine.split(";")[0].split("=")[1]

    const second = await updateSession(
      buildRequest("/caja", {
        ...FRESH_SESSION_COOKIE,
        [COOKIE_KEYS.LAST_ACTIVITY]: seededValue,
      }),
    )

    expect(isRedirect(second)).toBe(false)
  })
})
