/**
 * auth-hardening-jwt-cookies — D7 y D21, task 14.8.
 *
 * `lib/api/subscriptions-client.ts` es el transporte duplicado: tenía su propia
 * copia de "armar los encabezados" y ningún tratamiento del 401. Ahora delega
 * en `lib/api/auth-headers.ts` y recibe el mismo tratamiento que
 * `python-client`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

// auth-hardening-jwt-cookies (Parte C, tasks 19.7b/19.8f): el seam de la sesión
// pasa del cliente de navegador al store del token. El doble ya no puede ofrecer
// `auth`: con `accessToken` configurado `supabase.auth` LANZA
// (`supabase-js/index.mjs:389`), y un doble que lo siga ofreciendo deja la suite
// verde mientras producción explota. El store devuelve los TRES estados que el
// helper necesita, así que "la consulta lanzó" pasa a ser un valor de retorno.
const { resolveAccessTokenMock } = vi.hoisted(() => ({
  resolveAccessTokenMock: vi.fn(),
}))

vi.mock("@/lib/auth/access-token-store", () => ({
  resolveAccessToken: () => resolveAccessTokenMock(),
}))

const mockFetch = vi.fn()
global.fetch = mockFetch as unknown as typeof fetch

function response(body: unknown, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  } as Response)
}

describe("subscriptions-client — encabezados y 401", () => {
  let createSubscription: typeof import("@/lib/api/subscriptions-client").createSubscription
  let getSubscriptionStatus: typeof import("@/lib/api/subscriptions-client").getSubscriptionStatus
  let sessionNavigation: typeof import("@/lib/api/auth-headers").sessionNavigation

  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000")
    ;({ createSubscription, getSubscriptionStatus } = await import(
      "@/lib/api/subscriptions-client"
    ))
    ;({ sessionNavigation } = await import("@/lib/api/auth-headers"))
  })

  it("con token manda el encabezado", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-1" })
    mockFetch.mockReturnValueOnce(response({ init_point: "x" }))

    await createSubscription("pro")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBe("Bearer tok-1")
    expect(init.headers["Content-Type"]).toBe("application/json")
  })

  // ::omits_authorization_header_when_token_is_empty
  it("sin sesión NO manda `Bearer ` vacío: omite el encabezado", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "absent" })
    mockFetch.mockReturnValueOnce(response({ init_point: "x" }))

    await createSubscription("pro")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBeUndefined()
    expect(init.headers["Content-Type"]).toBe("application/json")
  })

  it("un 401 sin sesión navega al login con reason=expired", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "absent" })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockReturnValueOnce(response({ detail: "no" }, 401))

    await expect(getSubscriptionStatus()).rejects.toThrow()

    expect(assign).toHaveBeenCalledTimes(1)
    expect(assign.mock.calls[0][0]).toContain("reason=expired")
  })

  it("un 401 con sesión viva no navega", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-vivo" })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockReturnValueOnce(response({ detail: "no" }, 401))

    await expect(getSubscriptionStatus()).rejects.toThrow("No autorizado para esta operación.")

    expect(assign).not.toHaveBeenCalled()
  })

  it("el 503 de la palanca apagada sigue siendo 'no habilitado', no un error", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-1" })
    mockFetch.mockReturnValueOnce(response({}, 503))

    await expect(getSubscriptionStatus()).resolves.toEqual({ enabled: false })
  })

  it("el 404 sigue siendo 'sin suscripción', no un error", async () => {
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-1" })
    mockFetch.mockReturnValueOnce(response({}, 404))

    await expect(getSubscriptionStatus()).resolves.toEqual({ enabled: true, data: null })
  })
})
