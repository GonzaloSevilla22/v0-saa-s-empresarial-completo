// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C, D18, task 19.4b.
 *
 * `/auth/verify-email` es la pantalla que **todo usuario nuevo** mira, y sus
 * cuatro mecanismos morían con D1: `refreshSession()`, `getSession()` ×2 y
 * `onAuthStateChange` — con `accessToken` configurado los cuatro **lanzan**
 * (`supabase-js/index.mjs:389`). El reemplazo es este endpoint: lee la cookie
 * `HttpOnly`, consulta el estado del email **contra el proveedor** y devuelve
 * `{ email, email_confirmed_at }`. Ningún token.
 *
 * ── Desvío deliberado respecto de la letra de D18 ───────────────────────────
 *
 * D18 dice "**fuerza** una renovación contra el proveedor (que es la única forma
 * de observar un `email_confirmed_at` recién cambiado)". Se cumple el objetivo con
 * `getUser()`, no con `refreshSession()`, y es una mejora, no un atajo:
 *
 *  - `getUser()` pega a `GET /auth/v1/user` y devuelve la fila **actual** del
 *    usuario, así que ve el `email_confirmed_at` recién cambiado igual que un
 *    refresh — incluso cuando el enlace se abrió en **otro navegador**, donde la
 *    sesión de esta pestaña no cambió y un refresh no traería nada nuevo;
 *  - la pantalla sondea cada 4 s. Con `refreshSession()` eso son ~15 rotaciones
 *    de refresh token por minuto, justo el tráfico que D19-5 identifica como
 *    fuente de carreras perdidas contra el manejador de token. Un logout duro por
 *    una carrera en la pantalla de verificación sería el peor lugar posible.
 *
 * Lo que D18 rechaza —`getSession()` a secas, que se conforma con la cookie
 * cacheada— sigue rechazado: la aserción de no-vacuidad de este archivo es que el
 * endpoint **habla con el proveedor**.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { NextRequest } from "next/server"
import { COOKIE_KEYS } from "@/lib/cookies"
import { IDLE_TIMEOUT_MS } from "@/lib/auth/idle-config"
import {
  ANON_KEY,
  SESSION_COOKIE,
  SUPABASE_URL,
  USER_EMAIL,
  gotrueDouble,
  jarWithSession,
  makeSession,
  makeUser,
  type GoTrueDouble,
  type SessionJson,
} from "../lib/helpers/gotrue-double"

import { GET } from "@/app/api/auth/status/route"

let gotrue: GoTrueDouble

function buildRequest(
  cookies: Record<string, string> = {},
  headers: Record<string, string> = {},
): NextRequest {
  const request = new NextRequest(new URL("/api/auth/status", "https://app.test"), { headers })
  for (const [name, value] of Object.entries(cookies)) request.cookies.set(name, value)
  return request
}

function activeJar(session: SessionJson): Record<string, string> {
  return { ...jarWithSession(session), [COOKIE_KEYS.LAST_ACTIVITY]: String(Date.now()) }
}

async function bodyOf(response: Response): Promise<Record<string, unknown>> {
  return (await response.clone().json()) as Record<string, unknown>
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SUPABASE_URL)
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ANON_KEY)
  gotrue = gotrueDouble({ user: makeUser() })
  vi.stubGlobal("fetch", gotrue.fetch)
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

describe("GET /api/auth/status — estado de verificación, sin tokens", () => {
  it("devuelve email y email_confirmed_at", async () => {
    const response = await GET(buildRequest(activeJar(makeSession())))

    expect(response.status).toBe(200)
    expect(await bodyOf(response)).toEqual({
      email: USER_EMAIL,
      email_confirmed_at: "2026-01-01T00:00:00Z",
    })
  })

  it("devuelve email_confirmed_at nulo cuando todavía no verificó", async () => {
    gotrue = gotrueDouble({ user: makeUser({ emailConfirmedAt: null }) })
    vi.stubGlobal("fetch", gotrue.fetch)

    const body = await bodyOf(await GET(buildRequest(activeJar(makeSession()))))

    expect(body.email_confirmed_at).toBeNull()
    expect(body.email).toBe(USER_EMAIL)
  })

  it("el cuerpo NO contiene ningún token", async () => {
    const session = makeSession({ refreshToken: "refresh-token-secreto" })
    const raw = await (await GET(buildRequest(activeJar(session)))).text()

    expect(raw).not.toContain("refresh-token-secreto")
    expect(raw).not.toContain(session.access_token)
    expect(raw).not.toMatch(/token/i)
  })

  // ── La razón de existir del endpoint: habla con el proveedor ──────────────
  it("consulta al proveedor en vez de conformarse con la cookie", async () => {
    // Sin esta aserción, una implementación que lea `getSession()` y devuelva el
    // `email_confirmed_at` del JWT cacheado pasaría todos los tests de arriba —
    // y nunca vería la verificación recién hecha, que es el único caso que esta
    // pantalla tiene que detectar.
    await GET(buildRequest(activeJar(makeSession())))
    expect(gotrue.userCalls()).toHaveLength(1)
  })

  it("y refleja el estado del proveedor aunque el JWT de la cookie diga otra cosa", async () => {
    // Exactamente el caso real: el usuario abrió el enlace de verificación (quizá
    // en otro navegador), así que la fila cambió pero el token de esta pestaña
    // sigue siendo el de antes.
    const cookieSinVerificar = makeSession({ emailConfirmedAt: null })
    gotrue = gotrueDouble({ user: makeUser({ emailConfirmedAt: "2026-09-16T12:00:00Z" }) })
    vi.stubGlobal("fetch", gotrue.fetch)

    const body = await bodyOf(await GET(buildRequest(activeJar(cookieSinVerificar))))

    expect(body.email_confirmed_at).toBe("2026-09-16T12:00:00Z")
  })

  it("sin sesión responde 200 con los dos campos nulos", async () => {
    const response = await GET(buildRequest())

    expect(response.status).toBe(200)
    expect(await bodyOf(response)).toEqual({ email: null, email_confirmed_at: null })
    expect(gotrue.calls).toEqual([])
  })

  it("con el token rechazado por el proveedor responde los dos campos nulos", async () => {
    gotrue = gotrueDouble({ user: null, refreshedSession: null })
    vi.stubGlobal("fetch", gotrue.fetch)

    const body = await bodyOf(await GET(buildRequest(activeJar(makeSession()))))

    expect(body).toEqual({ email: null, email_confirmed_at: null })
  })
})

describe("GET /api/auth/status — mismas garantías de transporte que el token handler", () => {
  it("declara no-store y Vary: Cookie", async () => {
    const response = await GET(buildRequest(activeJar(makeSession())))
    expect(response.headers.get("Cache-Control")).toMatch(/no-store/)
    expect(response.headers.get("Vary")).toMatch(/Cookie/i)
  })

  it("nunca emite Access-Control-Allow-Origin", async () => {
    const response = await GET(
      buildRequest(activeJar(makeSession()), { Origin: "https://atacante.example" }),
    )
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull()
  })

  it("rechaza la lectura cross-site (acá se filtraría el email, que es PII)", async () => {
    const response = await GET(
      buildRequest(activeJar(makeSession()), { "Sec-Fetch-Site": "cross-site" }),
    )

    expect(response.status).toBe(403)
    expect(await bodyOf(response)).toEqual({ email: null, email_confirmed_at: null })
    expect(gotrue.calls).toEqual([])
  })

  it("con same-origin responde normalmente", async () => {
    const response = await GET(
      buildRequest(activeJar(makeSession()), { "Sec-Fetch-Site": "same-origin" }),
    )
    expect(response.status).toBe(200)
    expect((await bodyOf(response)).email).toBe(USER_EMAIL)
  })
})

describe("GET /api/auth/status — una sola decisión de inactividad en el servidor", () => {
  it("con la sesión ociosa revoca y no informa nada", async () => {
    const idleJar = {
      ...jarWithSession(makeSession()),
      [COOKIE_KEYS.LAST_ACTIVITY]: String(Date.now() - IDLE_TIMEOUT_MS - 1000),
    }

    const response = await GET(buildRequest(idleJar))

    expect(await bodyOf(response)).toEqual({ email: null, email_confirmed_at: null })
    expect(gotrue.logoutCalls()).toHaveLength(1)
    expect(gotrue.userCalls()).toEqual([])
    const deletions = response.headers.getSetCookie().filter((l) => l.startsWith(SESSION_COOKIE))
    expect(deletions.length).toBeGreaterThan(0)
  })

  it("sin la cookie de actividad NO corta: es el caso del usuario recién registrado", async () => {
    // `IdleTimeoutProvider` sólo se monta dentro del dashboard, así que un
    // usuario que acaba de registrarse llega acá **sin** marca de actividad.
    // Tratar la ausencia como inactividad le cerraría la sesión justo mientras
    // verifica (`evaluateIdle` ⇒ "seed", Decision 6).
    const response = await GET(buildRequest(jarWithSession(makeSession())))

    expect((await bodyOf(response)).email).toBe(USER_EMAIL)
    expect(gotrue.logoutCalls()).toEqual([])
  })
})
