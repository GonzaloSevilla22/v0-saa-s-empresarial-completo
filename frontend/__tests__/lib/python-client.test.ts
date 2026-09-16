/**
 * v3-api-standards §6.2 — pythonClient.post acepta headers extra (Idempotency-Key).
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

// auth-hardening-jwt-cookies (task 14.7): el doble de la sesión pasa a ser
// controlable por caso — hasta acá siempre devolvía un token, así que la rama
// "401 sin sesión" no era alcanzable.
const { getSessionMock } = vi.hoisted(() => ({
  getSessionMock: vi.fn(async () => ({
    data: { session: { access_token: "test-token" } as { access_token: string } | null },
  })),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getSession: getSessionMock } }),
}))

const mockFetch = vi.fn()
global.fetch = mockFetch as unknown as typeof fetch

function buildFetchResponse(body: unknown, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  } as Response)
}

// python-client.ts lee NEXT_PUBLIC_BACKEND_URL en el top-level del módulo y
// lanza si falta (guard de arranque real). vitest no carga .env.local como
// Next.js, así que se stubea la env var y se importa el módulo dinámicamente
// DESPUÉS de resetear el registro de módulos, para que la lectura del
// top-level vea el valor stubeado.
describe("pythonClient.post extra headers", () => {
  let pythonClient: typeof import("@/lib/api/python-client").pythonClient

  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "test-token" } } })
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000")
    ;({ pythonClient } = await import("@/lib/api/python-client"))
  })

  it("sends the extra headers merged with auth headers", async () => {
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.post("/sales", { foo: "bar" }, { "Idempotency-Key": "key-abc" })

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers).toMatchObject({
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
      "Idempotency-Key": "key-abc",
    })
  })

  it("works without extra headers (backward compatible)", async () => {
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.post("/sales", { foo: "bar" })

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers).toMatchObject({
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    })
    expect(init.headers["Idempotency-Key"]).toBeUndefined()
  })
})

// cobranzas-reverso (task 12.1): pythonClient.delete gana un body opcional
// para la anulación de un cobro/pago (motivo opcional por body, D9).
describe("pythonClient.delete optional body", () => {
  let pythonClient: typeof import("@/lib/api/python-client").pythonClient

  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000")
    ;({ pythonClient } = await import("@/lib/api/python-client"))
  })

  it("sends no body when omitted (backward compatible con los 9 llamadores existentes)", async () => {
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.delete("/expenses/exp-1")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.method).toBe("DELETE")
    expect(init.body).toBeUndefined()
  })

  it("sends a JSON body when provided", async () => {
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.delete("/customer-accounts/payments/pay-1", { reason: "cobro duplicado" })

    const [, init] = mockFetch.mock.calls[0]
    expect(init.method).toBe("DELETE")
    expect(JSON.parse(init.body)).toEqual({ reason: "cobro duplicado" })
  })
})

// ── auth-hardening-jwt-cookies (task 14.8) ─────────────────────────────────
// `python-client.ts:54` mergeaba `extraHeaders` DESPUÉS de los de auth, así
// que un caller podía sobrescribir `Authorization` — el orden se invierte y lo
// garantiza ahora `getAuthHeaders()`, no este call site.
describe("pythonClient — extraHeaders no puede sobrescribir Authorization", () => {
  let pythonClient: typeof import("@/lib/api/python-client").pythonClient

  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "token-real" } } })
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000")
    ;({ pythonClient } = await import("@/lib/api/python-client"))
  })

  it("conserva el token de la sesión aunque el caller mande el suyo", async () => {
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.post("/sales", { foo: "bar" }, {
      Authorization: "Bearer token-del-caller",
      "Idempotency-Key": "key-abc",
    })

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBe("Bearer token-real")
    expect(init.headers["Idempotency-Key"]).toBe("key-abc")
  })

  it("sin sesión no manda un Bearer vacío", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } })
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ ok: true }))

    await pythonClient.get("/sales")

    const [, init] = mockFetch.mock.calls[0]
    expect(init.headers.Authorization).toBeUndefined()
  })
})

// ── auth-hardening-jwt-cookies (task 14.7) ─────────────────────────────────
// ::401_without_session_navigates_to_login
describe("pythonClient — tratamiento del 401 (D7)", () => {
  let pythonClient: typeof import("@/lib/api/python-client").pythonClient
  let sessionNavigation: typeof import("@/lib/api/auth-headers").sessionNavigation

  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    vi.stubEnv("NEXT_PUBLIC_BACKEND_URL", "http://localhost:8000")
    ;({ pythonClient } = await import("@/lib/api/python-client"))
    ;({ sessionNavigation } = await import("@/lib/api/auth-headers"))
  })

  it("un 401 SIN sesión navega a /auth/login?reason=expired&next=…", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    window.history.pushState({}, "", "/caja")
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ detail: "no" }, 401))

    await expect(pythonClient.get("/cash-sessions")).rejects.toThrow()

    expect(assign).toHaveBeenCalledTimes(1)
    const url = new URL(assign.mock.calls[0][0], "https://app.test")
    expect(url.pathname).toBe("/auth/login")
    expect(url.searchParams.get("reason")).toBe("expired")
    expect(url.searchParams.get("next")).toBe("/caja")
  })

  it("un 401 CON sesión viva conserva el error y NO navega", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "token-vivo" } } })
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ detail: "no" }, 401))

    await expect(pythonClient.get("/cash-sessions")).rejects.toThrow(
      "No autorizado para esta operación.",
    )

    expect(assign).not.toHaveBeenCalled()
  })

  it("ya no recomienda recargar la página (esa recomendación no recuperaba nada)", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "token-vivo" } } })
    vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    mockFetch.mockResolvedValueOnce(buildFetchResponse({ detail: "no" }, 401))

    const error = await pythonClient
      .get("/cash-sessions")
      .then(() => null)
      .catch((e: unknown) => e as Error)

    expect(error).toBeInstanceOf(Error)
    expect(error!.message).not.toMatch(/recarg/i)
  })
})
