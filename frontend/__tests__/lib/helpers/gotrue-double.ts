/**
 * Doble de GoTrue para los manejadores de ruta de sesión.
 *
 * auth-hardening-jwt-cookies, Parte C (grupo 19). `GET /api/auth/token` y
 * `GET /api/auth/status` son los dos únicos sitios donde el servidor lee la
 * cookie `HttpOnly` y decide qué entregarle al navegador. Testearlos con un
 * `createServerClient` **mockeado** no probaría nada de lo que importa: el
 * formato de la cookie, la renovación real, la rotación y los atributos con que
 * se reescribe salen todos de `@supabase/ssr` + `auth-js`, no de nuestro código.
 *
 * Por eso este módulo NO mockea la librería: dobla la **red** (`globalThis.fetch`
 * hacia GoTrue) y construye el tarro de cookies en el formato real, de modo que
 * el manejador corra contra el cliente de verdad.
 *
 * NO es un archivo de test (no matchea `*.test.ts`).
 *
 * Formato de la cookie de sesión, verificado en `node_modules`:
 *   nombre  `sb-<project-ref>-auth-token` (auth-js lo deriva de la URL cuando
 *           `cookieOptions.name` no está fijado — `createServerClient.js`)
 *   valor   `"base64-" + base64url(JSON.stringify(session))`
 *           (`@supabase/ssr/dist/main/cookies.js:7`, `:156-157`, `:310-311`)
 * y `_isValidSession` sólo exige `access_token` + `refresh_token` + `expires_at`
 * (`GoTrueClient.js:3765-3772`), así que se puede sembrar una sesión **vencida**
 * sin pasar por `setSession()` (que la renovaría antes de guardarla).
 */

export const SUPABASE_URL = "https://project.supabase.co"
export const ANON_KEY = "anon-key-de-prueba"
/** Derivado de SUPABASE_URL por auth-js: `sb-<ref>-auth-token`. */
export const SESSION_COOKIE = "sb-project-auth-token"

export const USER_ID = "11111111-1111-4111-8111-111111111111"
export const USER_EMAIL = "duenio@test.local"

// ── Piezas del protocolo ────────────────────────────────────────────────────

function base64url(raw: string): string {
  return Buffer.from(raw, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

export interface JwtClaims {
  sub?: string
  email?: string
  /** Segundos desde ahora hasta `exp`. Negativo = ya vencido. */
  expiresInSeconds?: number
  [claim: string]: unknown
}

/**
 * JWT sintético. La firma es basura a propósito: ni auth-js ni nuestro
 * manejador la verifican — auth-js sólo decodifica el payload para leer `exp`, y
 * quien valida de verdad la firma es PostgREST/FastAPI, del otro lado.
 */
export function makeJwt(claims: JwtClaims = {}): string {
  const { expiresInSeconds = 3600, sub = USER_ID, email = USER_EMAIL, ...extra } = claims
  const header = base64url(JSON.stringify({ alg: "ES256", typ: "JWT", kid: "kid-de-prueba" }))
  const payload = base64url(
    JSON.stringify({
      sub,
      email,
      aud: "authenticated",
      role: "authenticated",
      iss: `${SUPABASE_URL}/auth/v1`,
      exp: Math.floor(Date.now() / 1000) + expiresInSeconds,
      iat: Math.floor(Date.now() / 1000),
      ...extra,
    }),
  )
  return `${header}.${payload}.firma-sintetica`
}

export interface SessionJson {
  access_token: string
  refresh_token: string
  expires_at: number
  expires_in: number
  token_type: "bearer"
  user: Record<string, unknown>
}

export interface SessionInput {
  accessToken?: string
  refreshToken?: string
  /** Segundos desde ahora hasta el vencimiento del access token. */
  expiresInSeconds?: number
  userId?: string
  email?: string
  emailConfirmedAt?: string | null
}

export function makeUser(input: SessionInput = {}): Record<string, unknown> {
  return {
    id: input.userId ?? USER_ID,
    aud: "authenticated",
    role: "authenticated",
    email: input.email ?? USER_EMAIL,
    email_confirmed_at:
      input.emailConfirmedAt === undefined ? "2026-01-01T00:00:00Z" : input.emailConfirmedAt,
    app_metadata: {},
    user_metadata: {},
    created_at: "2026-01-01T00:00:00Z",
  }
}

export function makeSession(input: SessionInput = {}): SessionJson {
  const expiresInSeconds = input.expiresInSeconds ?? 3600
  return {
    access_token:
      input.accessToken ??
      makeJwt({ sub: input.userId, email: input.email, expiresInSeconds }),
    refresh_token: input.refreshToken ?? "refresh-token-secreto",
    expires_at: Math.floor(Date.now() / 1000) + expiresInSeconds,
    expires_in: expiresInSeconds,
    token_type: "bearer",
    user: makeUser(input),
  }
}

/** Tarro de cookies con esa sesión, en el formato real de `@supabase/ssr`. */
export function jarWithSession(session: SessionJson): Record<string, string> {
  return { [SESSION_COOKIE]: `base64-${base64url(JSON.stringify(session))}` }
}

// ── Doble de red ────────────────────────────────────────────────────────────

export interface GoTrueCall {
  url: string
  method: string
}

export interface GoTrueDoubleConfig {
  /** Sesión que devuelve el endpoint de refresh. `null` ⇒ responde 400. */
  refreshedSession?: SessionJson | null
  /** Usuario que devuelve `GET /auth/v1/user`. `null` ⇒ responde 401. */
  user?: Record<string, unknown> | null
  /** Demora artificial del refresh, para ejercitar concurrencia. */
  refreshDelayMs?: number
}

export interface GoTrueDouble {
  fetch: typeof globalThis.fetch
  calls: GoTrueCall[]
  refreshCalls(): GoTrueCall[]
  logoutCalls(): GoTrueCall[]
  userCalls(): GoTrueCall[]
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })

/**
 * `fetch` que responde como GoTrue a los tres endpoints que este camino usa:
 * refresh del token, cierre de sesión y lectura del usuario. Cualquier otra URL
 * **lanza**, para que un camino de red no previsto se vea en el test en vez de
 * pasar inadvertido.
 */
export function gotrueDouble(config: GoTrueDoubleConfig = {}): GoTrueDouble {
  const calls: GoTrueCall[] = []

  const impl = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url
    const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase()
    calls.push({ url, method })

    if (url.includes("/auth/v1/token") && url.includes("grant_type=refresh_token")) {
      if (config.refreshDelayMs) {
        await new Promise((resolve) => setTimeout(resolve, config.refreshDelayMs))
      }
      const refreshed = config.refreshedSession
      if (refreshed === null || refreshed === undefined) {
        return json({ error: "invalid_grant", error_description: "Refresh Token Not Found" }, 400)
      }
      return json(refreshed)
    }

    if (url.includes("/auth/v1/logout")) {
      return new Response(null, { status: 204 })
    }

    if (url.includes("/auth/v1/user")) {
      if (config.user === null) return json({ message: "invalid claim" }, 401)
      return json(config.user ?? makeUser())
    }

    throw new Error(`fetch no previsto en el doble de GoTrue: ${method} ${url}`)
  }

  const filterBy = (needle: string) => () => calls.filter((c) => c.url.includes(needle))

  return {
    fetch: impl as unknown as typeof globalThis.fetch,
    calls,
    refreshCalls: filterBy("grant_type=refresh_token"),
    logoutCalls: filterBy("/auth/v1/logout"),
    userCalls: () =>
      calls.filter((c) => c.url.includes("/auth/v1/user") && !c.url.includes("grant_type")),
  }
}
