/**
 * auth-hardening-jwt-cookies — Parte C, D3, grupo 21: CSP con nonce por petición.
 *
 * `script-src` llevaba `'unsafe-inline' 'unsafe-eval'` desde que se escribió el
 * archivo, con el comentario "loosen for Next.js hydration; tighten later with
 * nonces". Esto es ese "later": en producción la directiva pasa a
 * `'nonce-…' 'strict-dynamic'`, sin permisos en línea.
 *
 * ── Lo que este archivo existe para no dejar pasar ──────────────────────────
 *
 * Next **no lee `x-nonce`**: saca el nonce de sus propios scripts de arranque e
 * hidratación parseando el encabezado de **petición** `content-security-policy`
 * (`next/dist/server/app-render/app-render.js:150` → `getScriptNonceFromHeader`).
 * Y `'strict-dynamic'` **anula `'self'` y todos los hosts** de `script-src`. Las
 * dos cosas juntas significan que, si el encabezado de petición no viaja con el
 * mismo nonce que la respuesta, no hay un modo degradado: es **pantalla en blanco
 * en el 100% de las páginas de producción** (B1 de la revisión adversarial).
 *
 * El caso que más fácil se rompe es el de las peticiones **autenticadas**:
 * `setAll` reconstruye la respuesta con `NextResponse.next({ request })` cada vez
 * que rota cookies, y eso descarta cualquier encabezado de petición modificado.
 * Por eso `nonce_survives_a_cookie_rotating_setAll` no es un test de adorno.
 *
 * Cómo se observan los encabezados de la petición reenviada: `NextResponse.next({
 * request: { headers } })` los codifica en la respuesta como
 * `x-middleware-request-<nombre>` más la lista `x-middleware-override-headers`
 * (`next/dist/server/web/spec-extension/response.js:33-39`).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import {
  harness,
  resetHarness,
  buildRequest,
} from "./helpers/middleware-harness"
import {
  buildContentSecurityPolicy,
  generateCspNonce,
  updateSession,
} from "@/lib/supabase/middleware"

const ROTATED = {
  name: "sb-project-auth-token",
  value: "base64-rotado",
  options: { path: "/", sameSite: "lax" as const },
}

const CONFIRMED_USER = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }

function getDirective(csp: string, name: string): string | undefined {
  return csp
    .split(";")
    .map((d) => d.trim())
    .find((d) => d.startsWith(`${name} `) || d === name)
}

/** El nonce que declara una política, tal como lo lee Next. */
function nonceOf(csp: string | null | undefined): string | null {
  if (!csp) return null
  const match = getDirective(csp, "script-src")?.match(/'nonce-([^']+)'/)
  return match ? match[1] : null
}

beforeEach(() => {
  resetHarness()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

afterEach(() => {
  vi.unstubAllEnvs()
})

// ── 21.1 / 21.3 / 21.4 / 21.5 / 21.5b: la política ──────────────────────────

describe("buildContentSecurityPolicy — nonce y strict-dynamic", () => {
  it("production_script_src_has_no_unsafe: en producción hay nonce y strict-dynamic, y ningún permiso en línea", () => {
    vi.stubEnv("NODE_ENV", "production")

    const scriptSrc = getDirective(buildContentSecurityPolicy("N0NC3"), "script-src")

    expect(scriptSrc).toContain("'nonce-N0NC3'")
    expect(scriptSrc).toContain("'strict-dynamic'")
    expect(scriptSrc).not.toContain("'unsafe-inline'")
    expect(scriptSrc).not.toContain("'unsafe-eval'")
  })

  it("nonce_differs_per_request: dos nonces generados son distintos", () => {
    const primero = generateCspNonce()
    const segundo = generateCspNonce()

    expect(primero).not.toBe(segundo)
    // Un nonce tiene que ser imposible de adivinar y válido como valor de fuente:
    // base64 sin caracteres que rompan el parseo de la directiva.
    expect(primero.length).toBeGreaterThanOrEqual(22)
    expect(primero).toMatch(/^[A-Za-z0-9+/=]+$/)
  })

  it("unsafe_eval_survives_outside_production: fuera de producción se conserva", () => {
    vi.stubEnv("NODE_ENV", "development")

    const scriptSrc = getDirective(buildContentSecurityPolicy("N0NC3"), "script-src")

    // Las herramientas de desarrollo (Turbopack, HMR) evalúan código en runtime.
    expect(scriptSrc).toContain("'unsafe-eval'")
    // Y el nonce sigue estando: el mecanismo es el mismo en los dos entornos, así
    // que un dev no puede "funcionar" por un camino que producción no tiene.
    expect(scriptSrc).toContain("'nonce-N0NC3'")
  })

  it("style_src_keeps_unsafe_inline: los estilos en línea siguen permitidos", () => {
    vi.stubEnv("NODE_ENV", "production")

    // Tailwind y Radix inyectan estilos en runtime, y `components/ui/chart.tsx`
    // emite un `<style>` con `dangerouslySetInnerHTML`. Es `style-src`, no
    // `script-src`: quitarlo acá rompe gráficos y componentes sin ganar nada.
    expect(getDirective(buildContentSecurityPolicy("N0NC3"), "style-src"))
      .toBe("style-src 'self' 'unsafe-inline'")
  })

  it("turnstile_host_still_allowed: el host del captcha sigue en las tres directivas", () => {
    vi.stubEnv("NODE_ENV", "production")
    const csp = buildContentSecurityPolicy("N0NC3")

    // Sigue listado por compatibilidad con navegadores que ignoran
    // `'strict-dynamic'`; en los que lo soportan, Turnstile carga por propagación
    // de confianza desde un script con nonce.
    expect(getDirective(csp, "script-src")).toContain("https://challenges.cloudflare.com")
    expect(getDirective(csp, "connect-src")).toContain("https://challenges.cloudflare.com")
    expect(getDirective(csp, "frame-src")).toContain("https://challenges.cloudflare.com")
  })

  it("wasm_unsafe_eval_in_production: la instanciación de WebAssembly sigue habilitada", () => {
    vi.stubEnv("NODE_ENV", "production")

    // Retirar `'unsafe-eval'` retira también la única habilitación de
    // `WebAssembly.instantiate`. `'wasm-unsafe-eval'` no debilita nada relevante y
    // evita descubrir un 3D roto en producción.
    expect(getDirective(buildContentSecurityPolicy("N0NC3"), "script-src"))
      .toContain("'wasm-unsafe-eval'")
  })

  it("connect_src_allows_ws_outside_production: el Realtime del stack local habla `ws://`", () => {
    // Hallazgo REAL de la pasada visual del grupo 22, **preexistente** a este
    // change: el canal de Realtime del Supabase local es
    // `ws://127.0.0.1:54321/realtime/v1/websocket`, y `connect-src` listaba
    // `http://127.0.0.1:54321` (otro esquema) más `wss:` (otro esquema). El
    // navegador lo bloqueaba con "The action has been blocked", así que la campana
    // de notificaciones NUNCA funcionó en desarrollo local — y sin esto la
    // verificación de Realtime de la task 22.1 es imposible de hacer.
    //
    // En producción el proyecto es `https://…supabase.co`, su Realtime es `wss:` y
    // ya estaba permitido: `ws:` **no** se agrega ahí.
    vi.stubEnv("NODE_ENV", "development")
    const dev = getDirective(buildContentSecurityPolicy("N0NC3"), "connect-src")!.split(" ")
    expect(dev).toContain("ws:")
    expect(dev).toContain("wss:")

    vi.stubEnv("NODE_ENV", "production")
    const prod = getDirective(buildContentSecurityPolicy("N0NC3"), "connect-src")!.split(" ")
    expect(prod).not.toContain("ws:")
    expect(prod).toContain("wss:")
  })

  it("el resto de las directivas no se toca", () => {
    vi.stubEnv("NODE_ENV", "production")
    const csp = buildContentSecurityPolicy("N0NC3")

    expect(getDirective(csp, "default-src")).toBe("default-src 'self'")
    expect(getDirective(csp, "worker-src")).toBe("worker-src 'self' blob:")
    expect(getDirective(csp, "img-src")).toBe("img-src 'self' data: blob: https:")
    expect(getDirective(csp, "font-src")).toBe("font-src 'self' data:")
    expect(getDirective(csp, "frame-ancestors")).toBe("frame-ancestors 'none'")
  })
})

// ── 21.6 / 21.6b: cómo viaja el nonce ───────────────────────────────────────

describe("middleware — propagación del nonce", () => {
  /** Encabezados de la petición reenviada, tal como Next los codifica. */
  function forwardedHeader(response: Response, name: string): string | null {
    return response.headers.get(`x-middleware-request-${name}`)
  }

  function overriddenNames(response: Response): string[] {
    return (response.headers.get("x-middleware-override-headers") ?? "").split(",")
  }

  it("la petición reenviada lleva la política completa y el mismo nonce que la respuesta", async () => {
    harness.user = CONFIRMED_USER

    const response = await updateSession(buildRequest("/", {}))

    const requestCsp = forwardedHeader(response, "content-security-policy")
    const responseCsp = response.headers.get("content-security-policy")

    expect(requestCsp).toBeTruthy()
    expect(nonceOf(requestCsp)).toBeTruthy()
    // La identidad es el punto: Next firma sus scripts con el nonce del
    // encabezado de PETICIÓN, y el navegador los valida contra el de la RESPUESTA.
    expect(nonceOf(requestCsp)).toBe(nonceOf(responseCsp))
    expect(requestCsp).toBe(responseCsp)
    // `x-nonce` viaja también, para que la app pueda leerlo con `headers()`.
    expect(forwardedHeader(response, "x-nonce")).toBe(nonceOf(responseCsp))
    expect(overriddenNames(response)).toContain("content-security-policy")
    expect(overriddenNames(response)).toContain("x-nonce")
  })

  it("nonce_survives_a_cookie_rotating_setAll: rotar cookies no descarta el nonce de la petición", async () => {
    harness.user = CONFIRMED_USER
    harness.cookiesToRotate = [ROTATED]

    const response = await updateSession(
      buildRequest("/caja", { "sb-project-auth-token": "base64-viejo", "auth:last-activity": String(Date.now()) }),
    )

    // `setAll` reconstruyó la respuesta: es el camino de las peticiones
    // autenticadas, y el que descartaba los encabezados de petición modificados.
    const requestCsp = forwardedHeader(response, "content-security-policy")
    const responseCsp = response.headers.get("content-security-policy")

    expect(requestCsp).toBeTruthy()
    expect(nonceOf(requestCsp)).toBe(nonceOf(responseCsp))
    // Y la cookie rotada sigue emitiéndose: la propagación del nonce no puede
    // costar la renovación de la sesión.
    const rotada = response.headers.getSetCookie().find((line) => line.startsWith(`${ROTATED.name}=${ROTATED.value}`))
    expect(rotada).toBeDefined()
    // La cookie renovada también viaja en la petición reenviada (receta de
    // `@supabase/ssr`): copiar los encabezados ANTES de `cookies.set()` la perdería.
    expect(forwardedHeader(response, "cookie")).toContain(`${ROTATED.name}=${ROTATED.value}`)
  })

  it("nonce_differs_per_request: dos peticiones reciben nonces distintos", async () => {
    harness.user = CONFIRMED_USER

    const primera = await updateSession(buildRequest("/", {}))
    const segunda = await updateSession(buildRequest("/", {}))

    const a = nonceOf(primera.headers.get("content-security-policy"))
    const b = nonceOf(segunda.headers.get("content-security-policy"))

    expect(a).toBeTruthy()
    expect(b).toBeTruthy()
    expect(a).not.toBe(b)
  })

  it("las salidas por redirect también emiten la política con nonce", async () => {
    harness.user = null

    const response = await updateSession(buildRequest("/caja", {}))

    expect(response.status).toBeGreaterThanOrEqual(300)
    expect(nonceOf(response.headers.get("content-security-policy"))).toBeTruthy()
  })

  it("la purga de `/api/**` conserva la política con nonce", async () => {
    harness.user = null
    harness.authError = { message: "AuthApiError: Refresh Token Not Found" }

    const response = await updateSession(buildRequest("/api/auth/token", { "sb-project-auth-token": "muerta" }))

    expect(response.status).toBeLessThan(300)
    expect(nonceOf(response.headers.get("content-security-policy"))).toBeTruthy()
    expect(nonceOf(forwardedHeader(response, "content-security-policy"))).toBe(
      nonceOf(response.headers.get("content-security-policy")),
    )
  })
})
