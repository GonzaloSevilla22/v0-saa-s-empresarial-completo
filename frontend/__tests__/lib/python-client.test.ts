/**
 * v3-api-standards §6.2 — pythonClient.post acepta headers extra (Idempotency-Key).
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getSession: async () => ({
        data: { session: { access_token: "test-token" } },
      }),
    },
  }),
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
