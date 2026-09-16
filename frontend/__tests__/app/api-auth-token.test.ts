// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C, D1 y D19, tasks 19.1 a 19.4.
 *
 * Corre en el entorno **node**, no en jsdom, y eso es parte del test: en jsdom
 * auth-js detecta `window`, se cree un cliente de navegador y engancha
 * `visibilitychange` + `_emitInitialSession` — código que en producción no corre
 * nunca en un Route Handler y que acá sólo agregaría ruido y promesas colgadas.
 *
 * `GET /api/auth/token` es el **único** lugar donde el secreto que este change
 * protege vuelve a ser legible por el navegador. Es un `GET`, vive detrás del CDN
 * de Vercel y lo pide cada pestaña en cada carga de página. Todo lo que garantiza
 * es normativo, no implícito:
 *
 *  - entrega `access_token`, `expires_at` y `user`, y **nunca** el refresh token;
 *  - `Cache-Control: no-store` + `Vary: Cookie`, para que ningún intermediario
 *    pueda servir el token de un usuario a otro;
 *  - **jamás** emite `Access-Control-Allow-Origin`;
 *  - rechaza la petición cuando `Sec-Fetch-Site` está presente y no es
 *    `same-origin`;
 *  - aplica la **misma** decisión de inactividad que el middleware y, si la
 *    sesión está ociosa, **revoca** en vez de renovar (sin esto el manejador es un
 *    segundo camino de refresh server-side no gateado: una regresión del control
 *    de idle introducida por el change que viene a reforzarlo);
 *  - deduplica renovaciones concurrentes y no renueva si la petición ya llegó con
 *    credenciales frescas.
 *
 * El test corre contra el `createServerClient` **real**: lo que se dobla es la
 * red hacia GoTrue (`__tests__/lib/helpers/gotrue-double.ts`).
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
  USER_ID,
  gotrueDouble,
  jarWithSession,
  makeSession,
  type GoTrueDouble,
  type SessionJson,
} from "../lib/helpers/gotrue-double"

import { GET } from "@/app/api/auth/token/route"

const ORIGIN = "https://app.test"
const REFRESH_TOKEN = "refresh-token-secreto"

let gotrue: GoTrueDouble

function buildRequest(
  cookies: Record<string, string> = {},
  headers: Record<string, string> = {},
): NextRequest {
  const request = new NextRequest(new URL("/api/auth/token", ORIGIN), { headers })
  for (const [name, value] of Object.entries(cookies)) request.cookies.set(name, value)
  return request
}

/** Cookies de una sesión viva más una marca de actividad reciente. */
function activeJar(session: SessionJson): Record<string, string> {
  return {
    ...jarWithSession(session),
    [COOKIE_KEYS.LAST_ACTIVITY]: String(Date.now()),
  }
}

async function bodyOf(response: Response): Promise<Record<string, unknown>> {
  return (await response.clone().json()) as Record<string, unknown>
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SUPABASE_URL)
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ANON_KEY)
  gotrue = gotrueDouble({ refreshedSession: null })
  vi.stubGlobal("fetch", gotrue.fetch)
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

// ── 19.1 ::never_returns_refresh_token ──────────────────────────────────────
describe("GET /api/auth/token — nunca entrega el refresh token", () => {
  it("devuelve access_token, expires_at y user", async () => {
    const session = makeSession({ refreshToken: REFRESH_TOKEN })
    const response = await GET(buildRequest(activeJar(session)))

    expect(response.status).toBe(200)
    const body = await bodyOf(response)
    expect(body.access_token).toBe(session.access_token)
    expect(body.expires_at).toBe(session.expires_at)
    expect(body.user).toMatchObject({ id: USER_ID, email: USER_EMAIL })
  })

  it("el cuerpo no contiene el refresh token bajo ningún nombre", async () => {
    const session = makeSession({ refreshToken: REFRESH_TOKEN })
    const response = await GET(buildRequest(activeJar(session)))

    // Dos aserciones distintas a propósito: una por el VALOR (que no se filtre
    // con otra clave) y otra por la CLAVE (que no aparezca un campo nuevo que
    // alguien agregue mañana).
    const raw = await response.clone().text()
    expect(raw).not.toContain(REFRESH_TOKEN)
    expect(raw).not.toMatch(/refresh/i)
  })

  it("y el detector no es vacuo: el refresh token SÍ está en la cookie de entrada", () => {
    const session = makeSession({ refreshToken: REFRESH_TOKEN })
    const cookieValue = jarWithSession(session)[SESSION_COOKIE]
    const decoded = Buffer.from(
      cookieValue.replace(/^base64-/, "").replace(/-/g, "+").replace(/_/g, "/"),
      "base64",
    ).toString("utf8")
    expect(decoded).toContain(REFRESH_TOKEN)
  })

  it("tampoco lo entrega en el cuerpo después de una renovación", async () => {
    const vencida = makeSession({ expiresInSeconds: -10, refreshToken: REFRESH_TOKEN })
    const rotada = makeSession({ refreshToken: "refresh-token-rotado" })
    gotrue = gotrueDouble({ refreshedSession: rotada })
    vi.stubGlobal("fetch", gotrue.fetch)

    const response = await GET(buildRequest(activeJar(vencida)))

    const raw = await response.clone().text()
    expect(raw).not.toContain(REFRESH_TOKEN)
    expect(raw).not.toContain("refresh-token-rotado")
    expect((await bodyOf(response)).access_token).toBe(rotada.access_token)
  })
})

// ── 19.2 ::returns_no_session_when_cookie_absent ────────────────────────────
describe("GET /api/auth/token — sin cookie válida no entrega token", () => {
  it("sin ninguna cookie responde una sesión vacía, no un error", async () => {
    const response = await GET(buildRequest())

    // 200 y no 401 a propósito: un visitante anónimo de una página pública
    // también pide este endpoint (el callback de supabase-js se dispara igual),
    // y eso es un estado esperado, no un fallo.
    expect(response.status).toBe(200)
    expect(await bodyOf(response)).toEqual({
      access_token: null,
      expires_at: null,
      user: null,
    })
  })

  it("no llama a GoTrue cuando no hay nada que renovar", async () => {
    await GET(buildRequest())
    expect(gotrue.calls).toEqual([])
  })

  it("con una cookie que decodifica pero no es una sesión tampoco entrega token", async () => {
    // `base64-` + base64url("no soy una sesión"): la librería lo decodifica, ve
    // que no pasa `_isValidSession` y descarta la sesión.
    const noEsSesion = Buffer.from("no soy una sesion", "utf8")
      .toString("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "")
    const response = await GET(buildRequest({ [SESSION_COOKIE]: `base64-${noEsSesion}` }))

    expect(response.status).toBe(200)
    expect((await bodyOf(response)).access_token).toBeNull()
  })

  // El caso de la cookie **corrupta** (cuerpo que no es base64url válido, con el
  // que la librería **lanza** en vez de devolver `{ error }`) vive en
  // `api-auth-token-throwing-cookie.test.ts` y no acá: con el cliente real, esa
  // cookie también hace rechazar una promesa **flotante** de
  // `onAuthStateChange` → `_emitInitialSession` (`GoTrueClient.js:3385-3389`)
  // que ningún `try` del manejador puede alcanzar, y vitest la cuenta como error
  // del archivo. Ver el hallazgo anotado en ese archivo.

  it("con el refresh rechazado por el proveedor tampoco entrega token", async () => {
    // `refreshedSession: null` ⇒ el doble responde 400 invalid_grant, que es lo
    // que GoTrue contesta a un refresh token ya rotado o revocado.
    const vencida = makeSession({ expiresInSeconds: -10 })
    const response = await GET(buildRequest(activeJar(vencida)))

    expect(gotrue.refreshCalls()).toHaveLength(1)
    expect((await bodyOf(response)).access_token).toBeNull()
  })
})

// ── 19.3 ::refresh_rotates_cookies ──────────────────────────────────────────
describe("GET /api/auth/token — la renovación reescribe las cookies rotadas", () => {
  it("emite las cookies nuevas con las opciones compartidas", async () => {
    const vencida = makeSession({ expiresInSeconds: -10 })
    const rotada = makeSession({ refreshToken: "refresh-token-rotado" })
    gotrue = gotrueDouble({ refreshedSession: rotada })
    vi.stubGlobal("fetch", gotrue.fetch)
    vi.stubEnv("NODE_ENV", "production")

    const response = await GET(buildRequest(activeJar(vencida)))

    const lines = response.headers.getSetCookie().filter((l) => l.startsWith("sb-"))
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      // Los atributos salen de `authCookieOptions()`, la única definición.
      expect(line, line).toMatch(/;\s*HttpOnly/i)
      expect(line, line).toMatch(/;\s*SameSite=Lax/i)
      expect(line, line).toMatch(/;\s*Secure/i)
      expect(line, line).toMatch(/;\s*Path=\//i)
    }
  })

  it("el access token del cuerpo es el nuevo, no el vencido", async () => {
    const vencida = makeSession({ expiresInSeconds: -10 })
    const rotada = makeSession({ refreshToken: "refresh-token-rotado" })
    gotrue = gotrueDouble({ refreshedSession: rotada })
    vi.stubGlobal("fetch", gotrue.fetch)

    const body = await bodyOf(await GET(buildRequest(activeJar(vencida))))

    expect(body.access_token).toBe(rotada.access_token)
    expect(body.access_token).not.toBe(vencida.access_token)
  })

  // ── Segunda mitad de 19.3e ────────────────────────────────────────────────
  it("NO renueva cuando la petición ya trae credenciales frescas", async () => {
    // El middleware corre antes de este manejador en la misma petición y su
    // `getUser()` ya renovó: las cookies frescas viajan en el request. Volver a
    // renovar acá presentaría un refresh token ya usado — la carrera que en
    // producción es un logout duro en medio de una venta.
    const fresca = makeSession({ expiresInSeconds: 3600 })
    const response = await GET(buildRequest(activeJar(fresca)))

    expect(gotrue.refreshCalls()).toEqual([])
    expect((await bodyOf(response)).access_token).toBe(fresca.access_token)
    expect(response.headers.getSetCookie().filter((l) => l.startsWith("sb-"))).toEqual([])
  })
})

// ── 19.3b ::sends_no_store_and_varies_on_cookie / ::never_sends_acao ────────
describe("GET /api/auth/token — no cacheable y sin CORS", () => {
  const scenarios: [string, () => NextRequest][] = [
    ["con sesión viva", () => buildRequest(activeJar(makeSession()))],
    ["sin sesión", () => buildRequest()],
    [
      "rechazada por cross-site",
      () => buildRequest(activeJar(makeSession()), { "Sec-Fetch-Site": "cross-site" }),
    ],
  ]

  it.each(scenarios)("%s declara Cache-Control: no-store", async (_name, build) => {
    const response = await GET(build())
    expect(response.headers.get("Cache-Control")).toMatch(/no-store/)
  })

  it.each(scenarios)("%s declara Vary: Cookie", async (_name, build) => {
    const response = await GET(build())
    expect(response.headers.get("Vary")).toMatch(/Cookie/i)
  })

  it.each(scenarios)("%s NO emite Access-Control-Allow-Origin", async (_name, build) => {
    const response = await GET(build())
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull()
    expect(response.headers.get("Access-Control-Allow-Credentials")).toBeNull()
  })

  it("tampoco lo emite cuando la petición trae un Origin ajeno", async () => {
    const response = await GET(
      buildRequest(activeJar(makeSession()), { Origin: "https://atacante.example" }),
    )
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull()
  })

  it("el módulo no exporta OPTIONS: no hay preflight que habilite CORS", async () => {
    const mod = await import("@/app/api/auth/token/route")
    expect("OPTIONS" in mod).toBe(false)
  })
})

// ── 19.3c ::rejects_cross_site_requests ─────────────────────────────────────
describe("GET /api/auth/token — sólo same-origin", () => {
  it.each(["cross-site", "same-site", "none"])(
    "con Sec-Fetch-Site: %s rechaza sin entregar token",
    async (value) => {
      const response = await GET(
        buildRequest(activeJar(makeSession()), { "Sec-Fetch-Site": value }),
      )

      expect(response.status).toBe(403)
      expect(await bodyOf(response)).toEqual({
        access_token: null,
        expires_at: null,
        user: null,
      })
      // Y no toca la sesión: rechazar no es cerrar.
      expect(gotrue.calls).toEqual([])
      expect(response.headers.getSetCookie()).toEqual([])
    },
  )

  it("con Sec-Fetch-Site: same-origin entrega el token", async () => {
    const session = makeSession()
    const response = await GET(
      buildRequest(activeJar(session), { "Sec-Fetch-Site": "same-origin" }),
    )

    expect(response.status).toBe(200)
    expect((await bodyOf(response)).access_token).toBe(session.access_token)
  })

  it("sin el encabezado entrega el token (hay navegadores que no lo mandan)", async () => {
    const session = makeSession()
    const response = await GET(buildRequest(activeJar(session)))

    expect(response.status).toBe(200)
    expect((await bodyOf(response)).access_token).toBe(session.access_token)
  })
})

// ── 19.3d ::idle_session_is_revoked_not_refreshed ───────────────────────────
describe("GET /api/auth/token — la inactividad revoca, no renueva", () => {
  /** Marca de actividad fuera del umbral, con el MISMO umbral del middleware. */
  const idleJar = (session: SessionJson) => ({
    ...jarWithSession(session),
    [COOKIE_KEYS.LAST_ACTIVITY]: String(Date.now() - IDLE_TIMEOUT_MS - 1000),
  })

  it("con la sesión ociosa no entrega token", async () => {
    const response = await GET(buildRequest(idleJar(makeSession())))
    expect(await bodyOf(response)).toEqual({
      access_token: null,
      expires_at: null,
      user: null,
    })
  })

  it("con la sesión ociosa y el token vencido no le devuelve la sesión al navegador", async () => {
    const rotada = makeSession()
    gotrue = gotrueDouble({ refreshedSession: rotada })
    vi.stubGlobal("fetch", gotrue.fetch)

    const response = await GET(
      buildRequest(idleJar(makeSession({ expiresInSeconds: -10 }))),
    )

    // Ésta es la aserción que evita la regresión que D19-4 nombra, y hay que
    // escribirla sobre el EFECTO, no sobre el tráfico de red. Con el access
    // token vencido, `signOut()` renueva primero para tener un token con el que
    // revocar (`_useSession` → `_callRefreshToken`): una llamada de refresh en
    // esta rama es inevitable y **no** deja la sesión viva, porque el `signOut`
    // que la sigue revoca el refresh token rotado. Lo que sí sería la regresión
    // —y lo que se fija acá— es que el manejador le devuelva un token o le
    // reponga la cookie rotada a una pestaña de fondo de un usuario ausente.
    expect((await bodyOf(response)).access_token).toBeNull()

    const rotaciones = response.headers
      .getSetCookie()
      .filter((line) => line.startsWith("sb-") && !/max-age=0|expires=thu, 01 jan 1970/i.test(line))
    expect(rotaciones, `la respuesta repuso la sesión: ${rotaciones.join(" | ")}`).toEqual([])
    expect(gotrue.logoutCalls()).toHaveLength(1)
  })

  it("con la sesión ociosa y el token VIVO no renueva nada", async () => {
    // El caso real: 20 minutos de inactividad con un token de una hora. Acá no
    // hay ninguna excusa para tocar el endpoint de refresh.
    gotrue = gotrueDouble({ refreshedSession: makeSession() })
    vi.stubGlobal("fetch", gotrue.fetch)

    await GET(buildRequest(idleJar(makeSession({ expiresInSeconds: 3600 }))))

    expect(gotrue.refreshCalls()).toEqual([])
    expect(gotrue.logoutCalls()).toHaveLength(1)
  })

  it("revoca del lado del servidor y borra las cookies de sesión", async () => {
    const response = await GET(buildRequest(idleJar(makeSession())))

    expect(gotrue.logoutCalls()).toHaveLength(1)
    const deletions = response.headers
      .getSetCookie()
      .filter((l) => l.startsWith(SESSION_COOKIE))
    expect(deletions.length).toBeGreaterThan(0)
    for (const line of deletions) {
      expect(line, line).toMatch(/max-age=0|expires=thu, 01 jan 1970/i)
    }
  })

  it("borra también la marca de actividad y la cuenta activa", async () => {
    const response = await GET(buildRequest(idleJar(makeSession())))
    const lines = response.headers.getSetCookie().join("\n")
    expect(lines).toContain(COOKIE_KEYS.LAST_ACTIVITY)
    expect(lines).toContain(COOKIE_KEYS.TENANT)
  })

  it("con actividad reciente sí entrega el token (el gate no es un bloqueo fijo)", async () => {
    const session = makeSession()
    const response = await GET(buildRequest(activeJar(session)))

    expect((await bodyOf(response)).access_token).toBe(session.access_token)
    expect(gotrue.logoutCalls()).toEqual([])
  })

  it("sin la cookie de actividad NO corta: ausente se siembra, no se cierra", async () => {
    // `evaluateIdle` devuelve "seed" para una cookie ausente o ilegible
    // (Decision 6 de idle-server-enforcement): tratar la ausencia como
    // inactividad cerraría la sesión de la primera carga de página.
    const session = makeSession()
    const response = await GET(buildRequest(jarWithSession(session)))

    expect((await bodyOf(response)).access_token).toBe(session.access_token)
    expect(gotrue.logoutCalls()).toEqual([])
  })
})

// ── 19.3e ::concurrent_requests_refresh_once ────────────────────────────────
describe("GET /api/auth/token — una sola renovación para pedidos concurrentes", () => {
  it("dos pedidos con el mismo token vencido renuevan una vez", async () => {
    const vencida = makeSession({ expiresInSeconds: -10 })
    const rotada = makeSession({ refreshToken: "refresh-token-rotado" })
    gotrue = gotrueDouble({ refreshedSession: rotada, refreshDelayMs: 20 })
    vi.stubGlobal("fetch", gotrue.fetch)

    const [a, b] = await Promise.all([
      GET(buildRequest(activeJar(vencida))),
      GET(buildRequest(activeJar(vencida))),
    ])

    expect(gotrue.refreshCalls()).toHaveLength(1)
    expect((await bodyOf(a)).access_token).toBe(rotada.access_token)
    expect((await bodyOf(b)).access_token).toBe(rotada.access_token)
  })

  it("las dos respuestas emiten las cookies rotadas (ninguna se queda sin ellas)", async () => {
    const vencida = makeSession({ expiresInSeconds: -10 })
    gotrue = gotrueDouble({ refreshedSession: makeSession(), refreshDelayMs: 20 })
    vi.stubGlobal("fetch", gotrue.fetch)

    const responses = await Promise.all([
      GET(buildRequest(activeJar(vencida))),
      GET(buildRequest(activeJar(vencida))),
    ])

    for (const response of responses) {
      expect(
        response.headers.getSetCookie().filter((l) => l.startsWith("sb-")).length,
      ).toBeGreaterThan(0)
    }
  })

  it("dos sesiones DISTINTAS renuevan cada una por su cuenta", async () => {
    // Control de no-vacuidad del dedupe: si la clave fuera global en vez de por
    // sesión, la segunda cuenta recibiría el token de la primera.
    const unaVencida = makeSession({ expiresInSeconds: -10, refreshToken: "refresh-a" })
    const otraVencida = makeSession({
      expiresInSeconds: -10,
      refreshToken: "refresh-b",
      userId: "22222222-2222-4222-8222-222222222222",
    })
    gotrue = gotrueDouble({ refreshedSession: makeSession(), refreshDelayMs: 20 })
    vi.stubGlobal("fetch", gotrue.fetch)

    await Promise.all([
      GET(buildRequest(activeJar(unaVencida))),
      GET(buildRequest(activeJar(otraVencida))),
    ])

    expect(gotrue.refreshCalls()).toHaveLength(2)
  })

  it("una renovación posterior NO reusa la promesa ya resuelta", async () => {
    // El dedupe es por promesa *en vuelo*: si quedara cacheada, el manejador
    // devolvería para siempre el primer token que le tocó.
    const vencida = makeSession({ expiresInSeconds: -10 })
    gotrue = gotrueDouble({ refreshedSession: makeSession() })
    vi.stubGlobal("fetch", gotrue.fetch)

    await GET(buildRequest(activeJar(vencida)))
    await GET(buildRequest(activeJar(vencida)))

    expect(gotrue.refreshCalls()).toHaveLength(2)
  })
})
