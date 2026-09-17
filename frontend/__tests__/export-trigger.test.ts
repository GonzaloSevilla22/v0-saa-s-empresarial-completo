/**
 * estadisticas-ventas E3 (grupo 8) — `triggerExport` con parámetros.
 *
 * El export del ranking tiene que llevar a la Edge Function los MISMOS
 * parámetros que la pantalla muestra (período, orden, agrupación, sucursal):
 * sin ellos, generate-export aplicaría sus defaults y el archivo no
 * coincidiría con lo que el usuario está viendo. Los cinco tipos legacy
 * siguen viajando con `{ export_type }` solo — no cambia su contrato.
 *
 * Run: pnpm vitest run __tests__/export-trigger.test.ts
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

// auth-hardening-jwt-cookies (Parte C, tasks 19.8d/19.11): `triggerExport` ya no
// recibe el token por parámetro — lo arma `getAuthHeaders()` sobre el store (D21).
const resolveAccessTokenMock = vi.hoisted(() => vi.fn())
vi.mock("@/lib/auth/access-token-store", () => ({
  resolveAccessToken: () => resolveAccessTokenMock(),
}))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: null }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))

import { triggerExport } from "@/hooks/auth/use-export-usage"

const fetchMock = vi.fn()

describe("triggerExport (grupo 8)", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "http://127.0.0.1:54321"
    fetchMock.mockReset()
    fetchMock.mockResolvedValue({ json: async () => ({ ok: true, signedUrl: "https://x/y.csv" }) })
    resolveAccessTokenMock.mockReset()
    resolveAccessTokenMock.mockResolvedValue({ status: "active", token: "tok-123" })
    vi.stubGlobal("fetch", fetchMock)
  })
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("el ranking viaja con los parámetros de la pantalla en el body, en snake_case", async () => {
    const result = await triggerExport("product_ranking_csv", {
      start: "2026-08-01",
      end: "2026-08-31",
      order_by: "revenue",
      group_variants: false,
      branch_id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
    })

    expect(result.ok).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://127.0.0.1:54321/functions/v1/generate-export")
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer tok-123")
    expect(JSON.parse(String(init.body))).toEqual({
      export_type: "product_ranking_csv",
      start: "2026-08-01",
      end: "2026-08-31",
      order_by: "revenue",
      group_variants: false,
      branch_id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
    })
  })

  it("sin parámetros el body sigue siendo { export_type } — los tipos legacy no cambian de contrato", async () => {
    await triggerExport("sales_csv")
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({ export_type: "sales_csv" })
  })

  // ── Parte C, task 19.11 ────────────────────────────────────────────────────
  it("sin sesión NO llama a la Edge Function y lo dice con un código propio", async () => {
    // Antes esto mandaba `Bearer undefined` o un Bearer vacío según el caller. El
    // código propio existe para que las dos pantallas puedan decir "No autenticado"
    // en vez de mostrarle al usuario el nombre de un error interno.
    resolveAccessTokenMock.mockResolvedValue({ status: "absent" })

    expect(await triggerExport("sales_csv")).toEqual({ ok: false, error: "no_session" })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("una sucursal null viaja como null (sin filtro), no se omite ni se vuelve string", async () => {
    await triggerExport("product_ranking_csv", { start: "2026-08-01", end: "2026-08-31", order_by: "units", group_variants: true, branch_id: null })
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body)).branch_id).toBeNull()
  })
})
