/**
 * Núcleo puro de la Edge Function ai-rentabilidad:
 * supabase/functions/_shared/ai-rentabilidad-core.ts.
 *
 * Candidato "alinear ai-rentabilidad con ai-estadisticas" (CLAUDE.md): antes
 * de este cambio, `ai-rentabilidad/index.ts` incrementaba el contador de uso
 * SIEMPRE que el análisis terminaba (incluso con `insight` vacío, e incluso
 * si `insight`.insert() fallaba en silencio — sólo se logueaba el error).
 * Este test fija el invariante correcto, igual al de ai-estadisticas: se
 * cobra SÓLO cuando el insight se generó Y se persistió.
 *
 * Run: pnpm vitest run __tests__/ai-rentabilidad.test.ts
 */

import { describe, it, expect, vi } from "vitest"
import {
  RENTABILIDAD_INSIGHT_TYPE,
  buildRentabilidadPrompt,
  runRentabilidadAnalysis,
  type AnalysisDeps,
  type ProfitabilityRow,
  type RentabilidadContext,
} from "../../supabase/functions/_shared/ai-rentabilidad-core"

function row(overrides: Partial<ProfitabilityRow> = {}): ProfitabilityRow {
  return {
    product_name: "Gorra",
    total_revenue: "2350",
    total_cost: "1500",
    gross_margin_pct: "36.17",
    units_sold: "5",
    ...overrides,
  }
}

function ctx(overrides: Partial<RentabilidadContext> = {}): RentabilidadContext {
  return { periodDays: 30, rows: [row()], ...overrides }
}

describe("RENTABILIDAD_INSIGHT_TYPE", () => {
  it("coincide con el tipo que insertaba la Edge Function ('margen')", () => {
    expect(RENTABILIDAD_INSIGHT_TYPE).toBe("margen")
  })
})

describe("buildRentabilidadPrompt", () => {
  it("arma el prompt con el período y el top de margen", () => {
    const r = buildRentabilidadPrompt(ctx())
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.prompt).toContain("últimos 30 días")
    expect(r.prompt).toContain("TOP MARGEN")
    expect(r.prompt).toMatch(/Gorra.*36\.2%/)
  })

  it("separa top 5 / bottom 5 cuando hay más de 5 productos", () => {
    const rows = Array.from({ length: 8 }, (_, i) =>
      row({ product_name: `P${i}`, gross_margin_pct: String(80 - i * 10) })
    )
    const r = buildRentabilidadPrompt(ctx({ rows }))
    if (!r.ok) throw new Error("expected ok")
    expect(r.prompt).toContain("TOP MARGEN")
    expect(r.prompt).toContain("BAJO MARGEN")
  })

  it("sin filas → rechazo 422 (nunca se inventa un análisis)", () => {
    const r = buildRentabilidadPrompt(ctx({ rows: [] }))
    expect(r).toEqual({ ok: false, status: 422, body: { ok: false, error: "Sin datos de ventas en el período seleccionado" } })
  })
})

function deps(overrides: Partial<AnalysisDeps> = {}) {
  const d = {
    checkQuota: vi.fn(async () => ({ allowed: true, body: null })),
    fetchContext: vi.fn(async () => ctx()),
    callModel: vi.fn(async () => ({ kind: "ok" as const, content: '{"insight":"La Gorra es lo más rentable.","recommendations":["a","b","c"]}' })),
    persistInsight: vi.fn(async () => {}),
    incrementUsage: vi.fn(async () => {}),
    ...overrides,
  }
  return d as AnalysisDeps & typeof d
}

describe("runRentabilidadAnalysis", () => {
  it("cuota disponible → consulta el modelo, persiste el insight e incrementa el contador UNA vez", async () => {
    const d = deps()
    const r = await runRentabilidadAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toEqual({ ok: true, data: { insight: "La Gorra es lo más rentable.", recommendations: ["a", "b", "c"] } })
    expect(d.persistInsight).toHaveBeenCalledWith("La Gorra es lo más rentable.")
    expect(d.incrementUsage).toHaveBeenCalledTimes(1)
  })

  it("cuota agotada → 429 con el cuerpo de la cuota; no lee contexto, no consulta al modelo, no incrementa", async () => {
    const body = { ok: false, error: "quota_exceeded", used: 5, limit: 5, resetAt: null }
    const d = deps({ checkQuota: vi.fn(async () => ({ allowed: false, body })) })
    const r = await runRentabilidadAnalysis(d)
    expect(r).toEqual({ status: 429, body })
    expect(d.fetchContext).not.toHaveBeenCalled()
    expect(d.callModel).not.toHaveBeenCalled()
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("sin datos en el período → 422 antes de consultar al modelo, sin incrementar", async () => {
    const d = deps({ fetchContext: vi.fn(async () => ctx({ rows: [] })) })
    const r = await runRentabilidadAnalysis(d)
    expect(r.status).toBe(422)
    expect(d.callModel).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("timeout del modelo → 200 fallback, sin persistir ni incrementar", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "timeout" as const })) })
    const r = await runRentabilidadAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toMatchObject({ ok: true, fallback: true })
    expect(String(r.body.message)).toMatch(/tardó demasiado/)
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("el modelo responde sin insight utilizable → fallback, SIN incrementar (antes: se cobraba igual)", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "ok" as const, content: "{}" })) })
    const r = await runRentabilidadAnalysis(d)
    expect(r.body).toMatchObject({ ok: true, fallback: true })
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("error HTTP del proveedor → 502 con el detalle, sin persistir ni incrementar", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "http_error" as const, status: 500, message: "upstream" })) })
    const r = await runRentabilidadAnalysis(d)
    expect(r.status).toBe(502)
    expect(String(r.body.error)).toMatch(/500/)
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("si persistir falla, el análisis igual se devuelve pero el contador NO se incrementa (antes: se incrementaba igual, el error sólo se logueaba)", async () => {
    const d = deps({ persistInsight: vi.fn(async () => { throw new Error("db down") }) })
    const r = await runRentabilidadAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toMatchObject({ ok: true, data: { insight: "La Gorra es lo más rentable." } })
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })
})

// ─── fix 12 (revisión adversarial): no desatar los métodos de `deps` ────────
//
// `runRentabilidadAnalysis` arma `genericDeps` (el objeto que le pasa a
// `runAiInsightAnalysis`) copiando cada método de `deps` por REFERENCIA
// (`checkQuota: deps.checkQuota`) en vez de envolverlo en una lambda. Con un
// `deps` de objeto plano (como los dobles de arriba, hechos con `vi.fn`) esto
// no se nota porque esas funciones no usan `this`. Pero si `deps` es una
// instancia de clase cuyos métodos SÍ usan `this` (estado interno, un caso
// real y razonable de implementar las dependencias), la referencia desatada
// pierde el receptor original: al invocarse como `genericDeps.checkQuota()`
// el `this` es `genericDeps` (un objeto plano sin el estado de la clase), no
// la instancia — y explota.
class ClassBasedRentabilidadDeps implements AnalysisDeps {
  calls = { checkQuota: 0, fetchContext: 0, callModel: 0, persistInsight: [] as string[], incrementUsage: 0 }

  constructor(private ctxValue: RentabilidadContext, private modelContent: string) {}

  async checkQuota() {
    this.calls.checkQuota++
    return { allowed: true, body: null }
  }
  async fetchContext() {
    this.calls.fetchContext++
    return this.ctxValue
  }
  async callModel() {
    this.calls.callModel++
    return { kind: "ok" as const, content: this.modelContent }
  }
  async persistInsight(insight: string) {
    this.calls.persistInsight.push(insight)
  }
  async incrementUsage() {
    this.calls.incrementUsage++
  }
}

describe("runRentabilidadAnalysis con deps implementado como clase (fix 12)", () => {
  it("no lanza cuando los métodos de deps dependen de `this` (deps NO bindeado, pasado por referencia de método)", async () => {
    const d = new ClassBasedRentabilidadDeps(ctx(), '{"insight":"La Gorra es lo más rentable.","recommendations":["a","b","c"]}')

    const r = await runRentabilidadAnalysis(d)

    expect(r.status).toBe(200)
    expect(d.calls.checkQuota).toBe(1)
    expect(d.calls.fetchContext).toBe(1)
    expect(d.calls.callModel).toBe(1)
    expect(d.calls.persistInsight).toEqual(["La Gorra es lo más rentable."])
    expect(d.calls.incrementUsage).toBe(1)
  })
})
