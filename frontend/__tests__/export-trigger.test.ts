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
    vi.stubGlobal("fetch", fetchMock)
  })
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("el ranking viaja con los parámetros de la pantalla en el body, en snake_case", async () => {
    const result = await triggerExport("product_ranking_csv", "tok-123", {
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
    await triggerExport("sales_csv", "tok-123")
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({ export_type: "sales_csv" })
  })

  it("una sucursal null viaja como null (sin filtro), no se omite ni se vuelve string", async () => {
    await triggerExport("product_ranking_csv", "tok", { start: "2026-08-01", end: "2026-08-31", order_by: "units", group_variants: true, branch_id: null })
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body)).branch_id).toBeNull()
  })
})
