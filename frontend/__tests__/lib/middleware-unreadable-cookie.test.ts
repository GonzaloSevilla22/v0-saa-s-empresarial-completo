/**
 * auth-hardening-jwt-cookies — Parte C. Revisión adversarial pre-merge (MAJOR: una
 * cookie `sb-*` ilegible era un 500 en **todas** las rutas).
 *
 * Una cookie `sb-*` cuyo cuerpo no sea base64url válido hace **lanzar** a la
 * librería (`Invalid UTF-8 sequence`, `@supabase/ssr/utils/base64url.js`), no
 * devolver `{ error }`. El manejador de token ya lo atajaba
 * (`app/api/auth/token/route.ts:171-178`) y su propio test lo dejó escrito:
 *
 *   > "El camino que la dispara primero es el `getUser()` del middleware, que
 *   > tampoco la ataja"
 *
 * El middleware corre en el 100% de los paths (matcher de `middleware.ts:29`), así
 * que la excepción era un **500 incluso en `/auth/login`**: la cookie es `HttpOnly`
 * —el usuario no la puede borrar desde JS— y `clearAuthUxCookies()` no toca `sb-*`.
 * Sin salida, con la app entera caída para ese navegador.
 *
 * Y la ventana de despliegue de la Parte C es un disparador plausible: el bundle
 * viejo escribiendo trozos por `document.cookie` mientras el servidor escribe la
 * cookie base ya marcada.
 *
 * El arreglo reusa la salida que ya existe para la sesión muerta: borrar todas las
 * `sb-*` y mandar al login (o, en `/api/**`, seguir sin redirect). Se autocura en
 * una petición.
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
  isCookieDeletion,
} from "./helpers/middleware-harness"
import { updateSession } from "@/lib/supabase/middleware"

const DEAD_JAR = { "sb-project-auth-token": "base64-no-es-utf8-válido" }

beforeEach(() => {
  resetHarness()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
  harness.getUserThrows = true
})

describe("updateSession — cookie de sesión ilegible", () => {
  it("una página protegida no devuelve 500: manda al login", async () => {
    const response = await updateSession(buildRequest("/caja", DEAD_JAR))

    expect(isRedirect(response)).toBe(true)
    expect(new URL(redirectTarget(response)!).pathname).toBe("/auth/login")
  })

  it("y borra las cookies de sesión, así el navegador se autocura en una petición", async () => {
    const response = await updateSession(buildRequest("/caja", DEAD_JAR))

    const sessionLines = response.headers
      .getSetCookie()
      .filter((line) => line.startsWith("sb-"))
    expect(sessionLines.length).toBeGreaterThan(0)
    for (const line of sessionLines) {
      expect(isCookieDeletion(line), `no es un borrado: ${line}`).toBe(true)
    }
  })

  it("`/auth/login` tampoco explota — es donde el usuario aterriza", async () => {
    // La ruta pública es el caso que hacía inescapable el problema: si el login
    // también es 500, el usuario no tiene ninguna pantalla desde donde recuperarse.
    const response = await updateSession(buildRequest("/auth/login", DEAD_JAR))

    expect(response.status).toBeLessThan(500)
    const sessionLines = response.headers
      .getSetCookie()
      .filter((line) => line.startsWith("sb-"))
    for (const line of sessionLines) {
      expect(isCookieDeletion(line), `no es un borrado: ${line}`).toBe(true)
    }
  })

  it("una ruta de API no recibe redirect, pero igual se le borran las cookies (D4)", async () => {
    const response = await updateSession(buildRequest("/api/ai/copilot", DEAD_JAR))

    expect(isRedirect(response)).toBe(false)
    const sessionLines = response.headers
      .getSetCookie()
      .filter((line) => line.startsWith("sb-"))
    expect(sessionLines.length).toBeGreaterThan(0)
    for (const line of sessionLines) {
      expect(isCookieDeletion(line), `no es un borrado: ${line}`).toBe(true)
    }
  })

  it("la CSP de la respuesta sigue puesta (la recuperación no puede costar la política)", async () => {
    const response = await updateSession(buildRequest("/caja", DEAD_JAR))

    const csp = response.headers.get("content-security-policy")
    expect(csp).toContain("'nonce-")
    expect(csp).toContain("frame-ancestors 'none'")
  })

  it("control: sin la excepción, la misma ruta con sesión válida se sirve normal", async () => {
    // Sin este control, los casos de arriba pasarían igual si el middleware
    // hubiera empezado a redirigir siempre.
    harness.getUserThrows = false
    harness.user = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }

    const response = await updateSession(
      buildRequest("/caja", { "auth:last-activity": String(Date.now()) }),
    )

    expect(isRedirect(response)).toBe(false)
  })
})
