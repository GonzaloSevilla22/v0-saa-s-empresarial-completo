/**
 * auth-hardening-jwt-cookies — D7 y D21, task 14.8.
 *
 * `lib/api/subscriptions-client.ts` es el transporte duplicado: tenía su propia
 * copia de "armar los encabezados" y ningún tratamiento del 401. Ahora delega
 * en `lib/api/auth-headers.ts` y recibe el mismo tratamiento que
 * `python-client`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const { getSessionMock } = vi.hoisted(() => ({
  getSessionMock: vi.fn(),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getSession: getSessionMock } }),
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
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok-1" } } })
    mockFetch.mockReturnValueOnce(response({ init_point: "x" }))

    await createSubscription("pro")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBe("Bearer tok-1")
    expect(init.headers["Content-Type"]).toBe("application/json")
  })

  // ::omits_authorization_header_when_token_is_empty
  it("sin sesión NO manda `Bearer ` vacío: omite el encabezado", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } })
    mockFetch.mockReturnValueOnce(response({ init_point: "x" }))

    await createSubscription("pro")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBeUndefined()
    expect(init.headers["Content-Type"]).toBe("application/json")
  })

  it("un 401 sin sesión navega al login con reason=expired", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockReturnValueOnce(response({ detail: "no" }, 401))

    await expect(getSubscriptionStatus()).rejects.toThrow()

    expect(assign).toHaveBeenCalledTimes(1)
    expect(assign.mock.calls[0][0]).toContain("reason=expired")
  })

  it("un 401 con sesión viva no navega", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok-vivo" } } })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockReturnValueOnce(response({ detail: "no" }, 401))

    await expect(getSubscriptionStatus()).rejects.toThrow("No autorizado para esta operación.")

    expect(assign).not.toHaveBeenCalled()
  })

  it("el 503 de la palanca apagada sigue siendo 'no habilitado', no un error", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok-1" } } })
    mockFetch.mockReturnValueOnce(response({}, 503))

    await expect(getSubscriptionStatus()).resolves.toEqual({ enabled: false })
  })

  it("el 404 sigue siendo 'sin suscripción', no un error", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok-1" } } })
    mockFetch.mockReturnValueOnce(response({}, 404))

    await expect(getSubscriptionStatus()).resolves.toEqual({ enabled: true, data: null })
  })
})
