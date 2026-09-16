/**
 * auth-hardening-jwt-cookies — F3, task 15.3b.
 *
 * §10 de la auditoría: no hay ningún test que assertee los atributos
 * (`Secure`/`HttpOnly`) de las cookies `sb-*`. Y un test que sólo mire la
 * constante `authCookieOptions()` pasa igual si un call site se olvida de
 * pasarla: lo que importa es el `Set-Cookie` **realmente emitido**.
 *
 * Este test maneja el `createServerClient` REAL de `@supabase/ssr` con un
 * almacén de cookies falso, fuerza una escritura de sesión y verifica los
 * atributos que llegan a la respuesta.
 */
import { describe, it, expect, afterEach, vi } from "vitest"
import { createServerClient } from "@supabase/ssr"
import { NextResponse } from "next/server"
import { authCookieOptions } from "@/lib/supabase/cookie-options"

const SUPABASE_URL = "https://project.supabase.co"
const ANON_KEY = "anon-key"

function base64url(value: object): string {
  return Buffer.from(JSON.stringify(value))
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

/** JWT sintético, sin firma válida: auth-js sólo lo decodifica para leer `exp`. */
function unexpiredJwt(): string {
  const header = base64url({ alg: "HS256", typ: "JWT" })
  const payload = base64url({
    sub: "11111111-1111-4111-8111-111111111111",
    aud: "authenticated",
    role: "authenticated",
    exp: Math.floor(Date.now() / 1000) + 3600,
  })
  return `${header}.${payload}.firma-sintetica`
}

const FAKE_USER = {
  id: "11111111-1111-4111-8111-111111111111",
  aud: "authenticated",
  role: "authenticated",
  email: "duenio@test.local",
  app_metadata: {},
  user_metadata: {},
  created_at: "2026-01-01T00:00:00Z",
}

/** Escribe una sesión con el cliente real y devuelve las líneas `Set-Cookie`. */
async function emittedSetCookieLines(
  // `null` = construir SIN `cookieOptions` (el estado que medía la auditoría).
  // El centinela no puede ser `undefined`: pasar `undefined` a un parámetro con
  // valor por defecto vuelve a aplicar el default.
  cookieOptions: ReturnType<typeof authCookieOptions> | null = authCookieOptions(),
): Promise<string[]> {
  const response = NextResponse.next()
  const jar: Record<string, string> = {}

  const supabase = createServerClient(SUPABASE_URL, ANON_KEY, {
    ...(cookieOptions ? { cookieOptions } : {}),
    cookies: {
      getAll() {
        return Object.entries(jar).map(([name, value]) => ({ name, value }))
      },
      setAll(cookiesToSet) {
        for (const { name, value, options } of cookiesToSet) {
          jar[name] = value
          response.cookies.set(name, value, options)
        }
      },
    },
    global: {
      // `_getUser` es la única llamada de red de este camino.
      fetch: async () =>
        new Response(JSON.stringify(FAKE_USER), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
    },
  })

  const { error } = await supabase.auth.setSession({
    access_token: unexpiredJwt(),
    refresh_token: "refresh-sintetico",
  })
  expect(error).toBeNull()

  return response.headers.getSetCookie().filter((line) => line.startsWith("sb-"))
}

afterEach(() => {
  vi.unstubAllEnvs()
})

describe("atributos realmente emitidos en el Set-Cookie de sesión", () => {
  it("escribe al menos una cookie de sesión", async () => {
    const lines = await emittedSetCookieLines()
    expect(lines.length).toBeGreaterThan(0)
  })

  it("Path=/ en todas", async () => {
    const lines = await emittedSetCookieLines()
    for (const line of lines) {
      expect(line, line).toMatch(/;\s*Path=\//i)
    }
  })

  it("SameSite=Lax en todas", async () => {
    const lines = await emittedSetCookieLines()
    for (const line of lines) {
      expect(line, line).toMatch(/;\s*SameSite=Lax/i)
    }
  })

  it("Secure en producción", async () => {
    vi.stubEnv("NODE_ENV", "production")
    const lines = await emittedSetCookieLines()
    for (const line of lines) {
      expect(line, line).toMatch(/;\s*Secure/i)
    }
  })

  it("sin Secure fuera de producción (el stack local no tiene TLS)", async () => {
    vi.stubEnv("NODE_ENV", "development")
    const lines = await emittedSetCookieLines()
    for (const line of lines) {
      expect(line, line).not.toMatch(/;\s*Secure/i)
    }
  })

  // ── El test no es vacuo: el `Secure` viene de NUESTRAS opciones ───────────
  it("sin cookieOptions el mismo camino NO emite Secure ni en producción", async () => {
    vi.stubEnv("NODE_ENV", "production")

    // Es el estado exacto que medía la auditoría: ninguno de los cuatro call
    // sites pasaba `cookieOptions`, así que regía el default de la librería,
    // que no tiene clave `secure`.
    const lines = await emittedSetCookieLines(null)

    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, line).not.toMatch(/;\s*Secure/i)
    }
  })

  it("SIN HttpOnly en la Parte B: el Bearer de FastAPI todavía sale de leerlas", async () => {
    // D16: ponerlo en true sin el token handler de la Parte C deja la app sin
    // forma de autenticarse contra el backend propio. Esta aserción es el
    // recordatorio ejecutable de que el cambio es de la Parte C, no un olvido.
    const lines = await emittedSetCookieLines()
    for (const line of lines) {
      expect(line, line).not.toMatch(/;\s*HttpOnly/i)
    }
  })
})
