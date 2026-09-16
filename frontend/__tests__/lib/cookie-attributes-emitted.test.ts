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

/** Cliente de servidor real sobre un tarro de cookies de mentira. */
function serverClientOn(
  jar: Record<string, string>,
  response: ReturnType<typeof NextResponse.next>,
  // `null` = construir SIN `cookieOptions` (el estado que medía la auditoría).
  // El centinela no puede ser `undefined`: pasar `undefined` a un parámetro con
  // valor por defecto vuelve a aplicar el default.
  cookieOptions: ReturnType<typeof authCookieOptions> | null = authCookieOptions(),
) {
  return createServerClient(SUPABASE_URL, ANON_KEY, {
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
}

/** Escribe una sesión con el cliente real y devuelve las líneas `Set-Cookie`. */
async function emittedSetCookieLines(
  cookieOptions: ReturnType<typeof authCookieOptions> | null = authCookieOptions(),
): Promise<string[]> {
  const response = NextResponse.next()
  const jar: Record<string, string> = {}

  const supabase = serverClientOn(jar, response, cookieOptions)

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

  // ── 18.1, la mitad que importa: el atributo REALMENTE emitido ────────────
  //
  // Parte C (D1). El objeto de opciones puede decir `httpOnly: true` y el
  // `Set-Cookie` salir sin el atributo si un call site no pasa las opciones:
  // eso es justo lo que este archivo existe para detectar (15.3b). La aserción
  // se invierte respecto de la Parte B porque el token handler del grupo 19
  // reemplaza la lectura desde el navegador.
  it("HttpOnly en todas las cookies de sesión", async () => {
    const lines = await emittedSetCookieLines()
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, line).toMatch(/;\s*HttpOnly/i)
    }
  })

  // ── 18.6 ::existing_session_survives_the_switch ──────────────────────────
  //
  // El requisito duro de D1: **una carga de página nueva después del deploy no
  // pide credenciales**. Lo que lo garantiza es que ni el nombre ni el contenido
  // de las cookies cambian — sólo los atributos—, así que una sesión escrita por
  // el bundle anterior (sin `HttpOnly`) la sigue leyendo el servidor nuevo, que
  // la reescribe marcada en la primera rotación.
  //
  // La aserción se escribe así y **no** como "cero re-login forzado" absoluto:
  // una pestaña que quedó abierta con el bundle viejo sí pierde
  // `document.cookie` y termina en `/auth/login`. Eso está en la tabla de
  // riesgos y su mitigación es la ventana de deploy (task 24.8), no código.
  it("una sesión escrita ANTES del cambio sigue siendo válida después", async () => {
    // 1. Sesión escrita como la escribía la Parte B: sin `cookieOptions`.
    const jar: Record<string, string> = {}
    const before = serverClientOn(jar, NextResponse.next(), null)
    const written = await before.auth.setSession({
      access_token: unexpiredJwt(),
      refresh_token: "refresh-sintetico",
    })
    expect(written.error).toBeNull()
    const legacyNames = Object.keys(jar)
    expect(legacyNames.length).toBeGreaterThan(0)

    // 2. El servidor nuevo (con httpOnly) lee ESE tarro tal cual.
    const afterResponse = NextResponse.next()
    const after = serverClientOn(jar, afterResponse)
    const { data, error } = await after.auth.getUser()

    expect(error).toBeNull()
    expect(data.user?.id).toBe(FAKE_USER.id)

    // 3. Y los nombres no cambiaron: la cookie es la misma, no una nueva.
    expect(Object.keys(jar)).toEqual(legacyNames)
  })

  it("el test anterior no es vacuo: con el tarro VACÍO no hay usuario", async () => {
    // El `fetch` del arnés devuelve el usuario siempre, así que sin este control
    // no se sabría si la sesión salió de la cookie heredada o del doble de red.
    const { data, error } = await serverClientOn({}, NextResponse.next()).auth.getUser()

    expect(data.user).toBeNull()
    expect(error).not.toBeNull()
  })

  it("y al reescribirla el servidor nuevo la marca HttpOnly", async () => {
    const jar: Record<string, string> = {}
    await serverClientOn(jar, NextResponse.next(), null).auth.setSession({
      access_token: unexpiredJwt(),
      refresh_token: "refresh-sintetico",
    })

    // La rotación real la dispara un refresh; acá se fuerza la reescritura con
    // el mismo camino de escritura que usa el refresh (`setSession`), que es lo
    // que este archivo puede observar sin un GoTrue de verdad.
    const response = NextResponse.next()
    await serverClientOn(jar, response).auth.setSession({
      access_token: unexpiredJwt(),
      refresh_token: "refresh-sintetico-rotado",
    })

    const lines = response.headers.getSetCookie().filter((line) => line.startsWith("sb-"))
    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, line).toMatch(/;\s*HttpOnly/i)
    }
  })

  it("sin cookieOptions el mismo camino NO emite HttpOnly (el atributo es nuestro)", async () => {
    // Control negativo hermano del de `Secure`: el default de la librería
    // declara `httpOnly: false`, así que el atributo sale de NUESTRA
    // definición y no de la librería. Sin este control, el test de arriba
    // pasaría igual si `@supabase/ssr` decidiera marcarlas por su cuenta.
    const lines = await emittedSetCookieLines(null)

    expect(lines.length).toBeGreaterThan(0)
    for (const line of lines) {
      expect(line, line).not.toMatch(/;\s*HttpOnly/i)
    }
  })
})
