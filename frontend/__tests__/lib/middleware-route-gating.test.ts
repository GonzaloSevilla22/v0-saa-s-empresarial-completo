/**
 * auth-hardening-jwt-cookies — D4, tasks 12.2 / 12.7 / 12.8.
 *
 * Primer test del repo que **ejecuta** `updateSession`. Antes de este change
 * ningún test lo importaba (auditoría 2026-09-14 §10), así que ni el gate por
 * sesión ni sus excepciones estaban fijados por nada.
 *
 * Lo que se fija acá:
 *  - una ruta del área autenticada sin sesión redirige al login con `next`;
 *  - `/api/**` NUNCA recibe redirect: el handler responde por su cuenta. Sin
 *    esto, "allow-list pública + protegido por defecto" devolvería HTML de
 *    login donde el consumidor espera JSON — y dejaría inutilizable el
 *    manejador de token de la Parte C;
 *  - `/auth/*`, la landing, `/legal/*` y `/dev-harness/*` (OQ-8) no se gatean.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import * as middlewareHarness from "./helpers/middleware-harness"
import {
  harness,
  resetHarness,
  buildRequest,
  isRedirect,
  redirectTarget,
} from "./helpers/middleware-harness"
import { updateSession } from "@/lib/supabase/middleware"

beforeEach(() => {
  resetHarness()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

// ── Los 12 árboles que estaban sin gate (F1) ───────────────────────────────
const PREVIOUSLY_UNGATED = [
  "/banco",
  "/caja",
  "/cobranzas",
  "/estadisticas",
  "/exportaciones",
  "/facturacion",
  "/finanzas/conciliacion",
  "/organizacion/roles",
  "/planes",
  "/rentabilidad",
  "/reportes/comparativo",
  "/sucursales",
]

describe("updateSession — gate por sesión", () => {
  it.each(PREVIOUSLY_UNGATED)(
    "%s sin sesión redirige a /auth/login conservando el destino",
    async (pathname) => {
      harness.user = null
      const response = await updateSession(buildRequest(pathname))

      expect(isRedirect(response)).toBe(true)
      const target = new URL(redirectTarget(response)!)
      expect(target.pathname).toBe("/auth/login")
      expect(target.searchParams.get("next")).toBe(pathname)
    },
  )

  it("una ruta que ya estaba gateada sigue gateada (no-regresión)", async () => {
    harness.user = null
    const response = await updateSession(buildRequest("/ventas"))
    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/auth/login")
  })

  it("con sesión verificada la ruta protegida se sirve", async () => {
    harness.user = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }
    const response = await updateSession(
      buildRequest("/caja", { "auth:last-activity": String(Date.now()) }),
    )
    expect(isRedirect(response)).toBe(false)
  })
})

// ── 12.7: /api/** nunca se redirige ────────────────────────────────────────
describe("updateSession — /api/** no recibe redirect", () => {
  it.each([
    "/api/auth/token",
    "/api/ai/copilot",
    "/api/billing/cancel",
    "/api/billing/preferences",
  ])("%s sin sesión NO recibe 307 al login", async (pathname) => {
    harness.user = null
    const response = await updateSession(buildRequest(pathname))

    expect(isRedirect(response)).toBe(false)
    expect(redirectTarget(response)).toBeNull()
  })

  it("tampoco con una sesión sin email confirmado (esa puerta también es un redirect)", async () => {
    harness.user = { id: "u1", email_confirmed_at: null }
    const response = await updateSession(buildRequest("/api/auth/token"))
    expect(isRedirect(response)).toBe(false)
  })

  // Hallazgo de la revisión adversarial de la Parte B: la purga de sesión
  // muerta corre ANTES de calcular la ruta y redirigía para cualquier path,
  // `/api/**` incluido — es decir, el propio manejador de token de la Parte C
  // habría recibido un 307 a HTML donde espera JSON, que es exactamente lo que
  // D4 declara que no puede pasar.
  // Se mide sobre `/api/ai/copilot` y no sobre `/api/auth/token`: desde la revisión
  // adversarial de la Parte C, `/api/auth/*` **no llega** a esta rama porque el
  // middleware la cortocircuita antes de `getUser()` (D19-5, ver
  // `middleware-api-auth-shortcircuit.test.ts`). La garantía de D4 que este caso
  // fija —purga sin redirect en `/api/**`— sigue aplicando a las demás rutas de
  // API, y el manejador de token borra sus propias cookies muertas
  // (`route.ts:170-182` devuelve "sin sesión" con las cookies que `_removeSession`
  // ya borró).
  it("la purga de sesión muerta NO redirige una ruta de API, pero igual borra las cookies", async () => {
    harness.user = null
    harness.authError = { message: "AuthApiError: Refresh Token Not Found" }

    const response = await updateSession(
      buildRequest("/api/ai/copilot", { "sb-project-auth-token": "base64-muerta" }),
    )

    expect(isRedirect(response)).toBe(false)
    expect(redirectTarget(response)).toBeNull()
    const sessionLines = response.headers
      .getSetCookie()
      .filter((line) => line.startsWith("sb-"))
    expect(sessionLines.length).toBeGreaterThan(0)
    for (const line of sessionLines) {
      expect(line, `no es un borrado: ${line}`).toMatch(/max-age=0|expires=thu, 01 jan 1970/i)
    }
  })

  it("contraste: la misma purga en una página SÍ redirige al login", async () => {
    harness.user = null
    harness.authError = { message: "AuthApiError: Refresh Token Not Found" }

    const response = await updateSession(
      buildRequest("/caja", { "sb-project-auth-token": "base64-muerta" }),
    )

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/auth/login")
  })

  it("contraste: la misma falta de sesión en una página SÍ redirige", async () => {
    harness.user = null
    const response = await updateSession(buildRequest("/caja"))
    expect(isRedirect(response)).toBe(true)
  })
})

// ── F3: el middleware construye el cliente con las opciones compartidas ────
describe("updateSession — atributos de cookie", () => {
  it("pasa `cookieOptions` al construir el cliente (no el default de la librería)", async () => {
    harness.user = null
    await updateSession(buildRequest("/caja"))

    // Lo que llegó al `createServerClient` real en producción, medido acá sobre
    // el doble: sin esto regía el default de `@supabase/ssr`, que NO tiene
    // clave `secure`.
    //
    // auth-hardening-jwt-cookies (Parte C, task 18.1): `httpOnly` pasa a `true`.
    // El middleware es **el** camino que rota las cookies en cada petición
    // autenticada, así que es el que efectivamente marca la sesión de un usuario
    // que ya estaba dentro: si acá llegara el default de la librería, la sesión
    // seguiría legible por JavaScript por más que el resto del change esté puesto.
    expect(middlewareHarness.lastCookieOptions).toBeDefined()
    expect(middlewareHarness.lastCookieOptions).toMatchObject({
      path: "/",
      sameSite: "lax",
      httpOnly: true,
    })
    expect(middlewareHarness.lastCookieOptions).toHaveProperty("secure")
  })
})

// ── D5: el middleware valida el destino de retorno con `safeNext()` ────────
describe("updateSession — destino de retorno del redirect de ruta de auth", () => {
  const CONFIRMED = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }

  it.each([
    "//evil.example",
    "https://evil.example/",
    "@evil.example/",
    "/\\evil.example",
    // Revisión adversarial (BLOCKER 1): el parser de URL borra estos tres
    // caracteres, así que `/\t/evil.example` colapsa en `//evil.example` dentro
    // de `new URL(next, request.url)` y salía del sitio con un 307.
    "/\t/evil.example",
    "/\n/evil.example",
    "/\r/evil.example",
  ])(
    "descarta %j y manda al dashboard",
    async (next) => {
      harness.user = CONFIRMED
      const response = await updateSession(
        buildRequest(`/auth/login?next=${encodeURIComponent(next)}`),
      )

      const target = new URL(redirectTarget(response)!)
      expect(target.origin).toBe("https://app.test")
      expect(target.pathname).toBe("/dashboard")
    },
  )

  it("conserva un destino interno", async () => {
    harness.user = CONFIRMED
    const response = await updateSession(buildRequest("/auth/login?next=%2Fcaja"))
    expect(new URL(redirectTarget(response)!).pathname).toBe("/caja")
  })

  it("conserva la query del destino interno", async () => {
    harness.user = CONFIRMED
    const response = await updateSession(
      buildRequest(
        `/auth/login?next=${encodeURIComponent("/reportes/comparativo?desde=2026-01-01")}`,
      ),
    )
    const target = new URL(redirectTarget(response)!)
    expect(target.pathname).toBe("/reportes/comparativo")
    expect(target.searchParams.get("desde")).toBe("2026-01-01")
  })
})

// ── 12.3 / 12.8: rutas públicas ────────────────────────────────────────────
describe("updateSession — rutas públicas", () => {
  it.each([
    "/",
    "/landing",
    "/legal/terminos",
    "/auth/login",
    "/auth/callback",
    "/auth/verify-email",
    "/dev-harness/shell",
  ])("%s sin sesión se sirve sin redirect", async (pathname) => {
    harness.user = null
    const response = await updateSession(buildRequest(pathname))
    expect(isRedirect(response)).toBe(false)
  })

  // 12.8 (OQ-8): las cinco suites de `e2e/harness/*.spec.ts` navegan anónimas a
  // estas rutas. Playwright no corre en esta verificación local (el paquete no
  // está instalado), así que se fija acá la propiedad de la que dependen: que
  // el middleware no las gatee. En producción esas páginas ya no existen —
  // cada una hace `notFound()` cuando `NODE_ENV === "production"`.
  it.each([
    "/dev-harness/bell",
    "/dev-harness/popover",
    "/dev-harness/shell",
    "/dev-harness/tablet-filters",
    "/dev-harness/expense-import",
  ])("%s (usada por e2e/harness) no se gatea", async (pathname) => {
    harness.user = null
    const response = await updateSession(buildRequest(pathname))
    expect(isRedirect(response)).toBe(false)
  })
})
