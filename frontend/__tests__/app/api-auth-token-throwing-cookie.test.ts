// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C, task 19.2 (la mitad que el cliente real
 * no deja testear en el mismo archivo).
 *
 * ── Hallazgo ────────────────────────────────────────────────────────────────
 *
 * Cuando una cookie `sb-*` llega con un cuerpo que **no** es base64url válido
 * —un chunk perdido, una escritura parcial, una cookie pisada por otro
 * subdominio— `@supabase/ssr` **lanza** al leerla en vez de devolver
 * `{ error }`:
 *
 *     Error: Invalid UTF-8 sequence
 *       at stringFromUTF8 (@supabase/ssr/dist/main/utils/base64url.js:200)
 *       at Object.getItem (@supabase/ssr/dist/main/cookies.js:254)
 *       at getItemAsync (@supabase/auth-js/.../helpers.js:129)
 *       at __loadSession (GoTrueClient.js:2322)
 *
 * Sin el `try` del manejador eso es un **500 en cada carga de página**: el
 * navegador se queda sin token y sin camino de recuperación, porque nada borra la
 * cookie envenenada. Una sesión ilegible tiene que ser una sesión ausente.
 *
 * Este archivo dobla `@supabase/ssr` en vez de usar el cliente real por una razón
 * concreta: con el cliente real, esa misma cookie hace rechazar además una
 * promesa **flotante** que `onAuthStateChange` lanza al construir el cliente
 * (`GoTrueClient.js:3385-3389` → `_emitInitialSession` → `__loadSession`).
 * Ningún `try` del manejador la alcanza y vitest la cuenta como error del
 * archivo. Queda anotado como riesgo de producción que este change **no** cierra:
 * en una función serverless esa rechazada flotante es una unhandled rejection del
 * proceso. El camino que la dispara primero es el `getUser()` del middleware, que
 * tampoco la ataja (`lib/supabase/middleware.ts:122-125`).
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { NextRequest } from "next/server"
import { COOKIE_KEYS } from "@/lib/cookies"

const UNREADABLE = new Error("Invalid UTF-8 sequence")

const getSessionMock = vi.fn()
const signOutMock = vi.fn()

vi.mock("@supabase/ssr", () => ({
  createServerClient: () => ({
    auth: { getSession: getSessionMock, signOut: signOutMock },
  }),
}))

import { GET } from "@/app/api/auth/token/route"

const SESSION_COOKIE = "sb-project-auth-token"

function buildRequest(cookies: Record<string, string>): NextRequest {
  const request = new NextRequest(new URL("/api/auth/token", "https://app.test"))
  for (const [name, value] of Object.entries(cookies)) request.cookies.set(name, value)
  return request
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key-de-prueba")
  getSessionMock.mockReset()
  signOutMock.mockReset().mockResolvedValue({ error: null })
  vi.spyOn(console, "warn").mockImplementation(() => {})
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

const activeJar = { [SESSION_COOKIE]: "cualquier-cosa", [COOKIE_KEYS.LAST_ACTIVITY]: String(Date.now()) }

describe("GET /api/auth/token — una cookie ilegible es una sesión ausente", () => {
  it("cuando la lectura de la sesión LANZA, responde 200 sin sesión", async () => {
    getSessionMock.mockRejectedValue(UNREADABLE)

    const response = await GET(buildRequest(activeJar))

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      access_token: null,
      expires_at: null,
      user: null,
    })
  })

  it("y no arrastra la excepción al caller (nada de 500)", async () => {
    getSessionMock.mockRejectedValue(UNREADABLE)
    await expect(GET(buildRequest(activeJar))).resolves.toBeDefined()
  })

  it("sigue declarando no-store aunque la cookie sea ilegible", async () => {
    getSessionMock.mockRejectedValue(UNREADABLE)
    const response = await GET(buildRequest(activeJar))
    expect(response.headers.get("Cache-Control")).toMatch(/no-store/)
  })

  it("el doble no es vacuo: con una sesión legible SÍ entrega token", async () => {
    getSessionMock.mockResolvedValue({
      data: {
        session: {
          // JWT sintético con `sub` legible: header.payload.firma
          access_token: `x.${Buffer.from(JSON.stringify({ sub: "u-1", email: "a@b.c" }))
            .toString("base64")
            .replace(/\+/g, "-")
            .replace(/\//g, "_")
            .replace(/=+$/, "")}.y`,
          expires_at: 1_800_000_000,
        },
      },
      error: null,
    })

    const body = (await (await GET(buildRequest(activeJar))).json()) as Record<string, unknown>

    expect(body.expires_at).toBe(1_800_000_000)
    expect(body.user).toEqual({ id: "u-1", email: "a@b.c" })
  })

  it("un access token sin `sub` legible entrega el token con user nulo", async () => {
    // El token es lo que el consumidor necesita; la identidad es un extra. Si el
    // payload no se puede decodificar, no se inventa un usuario.
    getSessionMock.mockResolvedValue({
      data: { session: { access_token: "no-es-un-jwt", expires_at: 1 } },
      error: null,
    })

    const body = (await (await GET(buildRequest(activeJar))).json()) as Record<string, unknown>

    expect(body.access_token).toBe("no-es-un-jwt")
    expect(body.user).toBeNull()
  })
})
