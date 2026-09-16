/**
 * auth-hardening-jwt-cookies — F3, tasks 15.1 / 15.2 / 15.3.
 *
 * Ninguno de los cuatro sitios que construyen cliente pasaba `cookieOptions`
 * (`lib/supabase/client.ts:4`, `server.ts:6`, `lib/supabase/middleware.ts:69`,
 * `app/auth/callback/route.ts:13`), así que regía el default de la librería:
 *
 *   { path: "/", sameSite: "lax", httpOnly: false, maxAge: 400 días }
 *   (@supabase/ssr/dist/main/utils/constants.js)
 *
 * **No hay clave `secure`**, y los serializadores sólo emiten el atributo si se
 * lo pasan. Resultado en producción: las cookies de sesión salían sin `Secure`,
 * mientras las cookies propias de la app **sí** lo llevaban
 * (`lib/cookies.ts:11`, `lib/supabase/middleware.ts:161`). Lo tapaba HSTS, que
 * está vivo, pero era una línea que faltaba.
 *
 * `httpOnly` sigue en `false` en esta parte a propósito: cambiarlo rompe el
 * Bearer de FastAPI hasta que exista el token handler (D16, Parte C).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { authCookieOptions } from "@/lib/supabase/cookie-options"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

afterEach(() => {
  vi.unstubAllEnvs()
})

describe("authCookieOptions — atributo Secure", () => {
  it("emite secure: true en producción", () => {
    vi.stubEnv("NODE_ENV", "production")
    expect(authCookieOptions().secure).toBe(true)
  })

  it("emite secure: false fuera de producción", () => {
    vi.stubEnv("NODE_ENV", "development")
    expect(authCookieOptions().secure).toBe(false)
  })

  it("también en test (el stack local no tiene TLS)", () => {
    vi.stubEnv("NODE_ENV", "test")
    expect(authCookieOptions().secure).toBe(false)
  })
})

describe("authCookieOptions — el resto de los atributos", () => {
  it("path=/ y SameSite=Lax", () => {
    const options = authCookieOptions()
    expect(options.path).toBe("/")
    expect(options.sameSite).toBe("lax")
  })

  it("httpOnly sigue en false en la Parte B (lo cambia la Parte C con el token handler)", () => {
    expect(authCookieOptions().httpOnly).toBe(false)
  })

  it("no fija maxAge ni name: conserva los defaults de la librería", () => {
    const options = authCookieOptions() as Record<string, unknown>
    expect(options.maxAge).toBeUndefined()
    expect(options.name).toBeUndefined()
  })
})

// ── 15.3 ::test_all_four_call_sites_share_the_options ──────────────────────
describe("los cuatro sitios que construyen cliente comparten la definición", () => {
  const CALL_SITES = [
    "lib/supabase/client.ts",
    "lib/supabase/server.ts",
    "lib/supabase/middleware.ts",
    "app/auth/callback/route.ts",
  ]

  it.each(CALL_SITES)("%s pasa cookieOptions: authCookieOptions()", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).toContain("cookieOptions: authCookieOptions()")
    expect(source).toContain("@/lib/supabase/cookie-options")
  })

  it.each(CALL_SITES)("%s no declara sus propios atributos de cookie de sesión", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    // Un objeto literal como valor de `cookieOptions` sería una segunda
    // definición: es exactamente lo que este candado prohíbe.
    expect(source).not.toMatch(/cookieOptions:\s*\{/)
  })

  it("el detector reconoce un literal (no es vacuo)", () => {
    const offending = "cookieOptions: { secure: true, sameSite: 'strict' },"
    expect(/cookieOptions:\s*\{/.test(offending)).toBe(true)
  })

  it("y el único sitio que declara los atributos es el módulo compartido", () => {
    const source = fs.readFileSync(path.join(FRONTEND, "lib/supabase/cookie-options.ts"), "utf8")
    expect(source).toContain("sameSite")
    expect(source).toContain("httpOnly")
  })
})
