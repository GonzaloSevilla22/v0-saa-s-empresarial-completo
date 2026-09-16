/**
 * auth-hardening-jwt-cookies — D5, task 13.2.
 *
 * `app/auth/callback/route.ts` concatenaba el `next` recibido a la URL base sin
 * validarlo (`` `${siteUrl}${next}` ``, `:9` y `:43`): un open redirect latente
 * —`@evil.example/` cambia el host del resultado— y, sobre todo, el contraste
 * con el middleware, que sí validaba. Ahora los dos consumen `safeNext()`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const exchangeCodeForSession = vi.fn()

vi.mock("@supabase/ssr", () => ({
  createServerClient: () => ({
    auth: { exchangeCodeForSession },
  }),
}))

vi.mock("next/headers", () => ({
  cookies: async () => ({
    getAll: () => [],
    set: () => {},
  }),
}))

import { NextRequest } from "next/server"
import { GET } from "@/app/auth/callback/route"

const ORIGIN = "https://app.test"

function callbackRequest(search: string): NextRequest {
  return new NextRequest(new URL(`/auth/callback${search}`, ORIGIN))
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
  exchangeCodeForSession.mockResolvedValue({ error: null })
})

describe("GET /auth/callback — el destino de retorno se valida", () => {
  it.each([
    "@evil.example/",
    "//evil.example",
    "https://evil.example/",
    "/\\evil.example",
    // Revisión adversarial (BLOCKER 1): tabulador, salto de línea y retorno de
    // carro los borra el parser de URL, así que colapsan en `//evil.example`.
    "/\t/evil.example",
    "/\n/evil.example",
    "/\r/evil.example",
  ])("descarta el destino externo %j y vuelve al dashboard", async (next) => {
    const response = await GET(
      callbackRequest(`?code=abc&next=${encodeURIComponent(next)}`),
    )

    const location = new URL(response.headers.get("location")!)
    expect(location.origin).toBe(ORIGIN)
    expect(location.pathname).toBe("/dashboard")
  })

  it("conserva un destino interno", async () => {
    const response = await GET(callbackRequest("?code=abc&next=%2Fcaja"))

    const location = new URL(response.headers.get("location")!)
    expect(location.origin).toBe(ORIGIN)
    expect(location.pathname).toBe("/caja")
  })

  it("sin `next` vuelve al dashboard", async () => {
    const response = await GET(callbackRequest("?code=abc"))

    expect(new URL(response.headers.get("location")!).pathname).toBe("/dashboard")
  })

  it("si el intercambio falla vuelve al login real con el error", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: { message: "bad code" } })

    const response = await GET(
      callbackRequest("?code=abc&next=%2F%2Fevil.example"),
    )

    const location = new URL(response.headers.get("location")!)
    expect(location.origin).toBe(ORIGIN)
    expect(location.pathname).toBe("/auth/login")
    expect(location.searchParams.get("error")).toBe("auth_callback_error")
  })

  it("sin `code` no intercambia nada y vuelve al login", async () => {
    const response = await GET(callbackRequest("?next=%2Fcaja"))

    expect(exchangeCodeForSession).not.toHaveBeenCalled()
    expect(new URL(response.headers.get("location")!).pathname).toBe("/auth/login")
  })
})
