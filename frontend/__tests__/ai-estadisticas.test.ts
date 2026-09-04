/**
 * estadisticas-ventas E3 (grupo 10) — núcleo puro de la Edge Function
 * ai-estadisticas: supabase/functions/_shared/ai-estadisticas-core.ts.
 *
 * El handler (Deno.serve) sólo cablea dependencias reales; TODA la decisión
 * vive acá y se prueba con dobles inyectados (mismo patrón D5/D6 de
 * ai-quota.test.ts: importa el módulo REAL por ruta relativa):
 *
 * - 10.2: el contexto del prompt sale de las filas de los read-models
 *   canónicos tal cual (la fila `current` de la evolución, el ranking, el
 *   desglose por canal y día, el top de clientes) — nunca re-agregando
 *   buckets ni líneas en JS.
 * - 10.4 / 10.6: la cuota se verifica ANTES de leer nada y antes del modelo;
 *   con cuota agotada → 429 sin tocar el modelo. El contador se incrementa
 *   SÓLO cuando el insight se generó y persistió: timeout → fallback sin
 *   persistir ni incrementar; respuesta vacía → ídem; error HTTP → 502 ídem.
 * - 10.3: el tipo de insight es propio del módulo y coincide con el que el
 *   frontend lee (paridad con lib/sales-statistics.ts).
 *
 * Run: pnpm vitest run __tests__/ai-estadisticas.test.ts
 */

import { describe, it, expect, vi } from "vitest"
import {
  ESTADISTICAS_INSIGHT_TYPE,
  buildEstadisticasPrompt,
  parseInsightJson,
  runEstadisticasAnalysis,
  type AnalysisDeps,
  type EstadisticasContext,
} from "../../supabase/functions/_shared/ai-estadisticas-core"
import { STATISTICS_INSIGHT_TYPE } from "@/lib/sales-statistics"

const WINDOW = { window_start: "2026-08-05", window_end: "2026-09-03", history_days: 365, window_clamped: false }

function ctx(overrides: Partial<EstadisticasContext> = {}): EstadisticasContext {
  return {
    evolution: [
      // Los buckets NO suman lo mismo que `current` a propósito: si el prompt
      // dijera 999 en vez de 6050, estaría re-agregando buckets en JS.
      { period: "bucket", bucket_start: "2026-08-29", bucket_end: "2026-08-29", revenue: "999", credit_notes: "0", net_revenue: "999", units: "1", operations: 1, service_revenue: "0", ...WINDOW },
      { period: "current", bucket_start: "2026-08-05", bucket_end: "2026-09-03", revenue: "6050", credit_notes: "150", net_revenue: "5900", units: "11", operations: 6, service_revenue: "400", ...WINDOW },
      { period: "previous", bucket_start: "2026-07-06", bucket_end: "2026-08-04", revenue: "4000", credit_notes: "0", net_revenue: "4000", units: "8", operations: 5, service_revenue: "0", ...WINDOW },
    ],
    rankingByUnits: [
      { rank: 1, product_name: "Gorra", units: "5", revenue: "2350", operations: 3, is_group: false, variant_count: 0, gross_margin_pct: "36.17", cost_coverage_pct: "33.3" },
      { rank: 2, product_name: "Remera", units: "4", revenue: "2600", operations: 2, is_group: true, variant_count: 2, gross_margin_pct: null, cost_coverage_pct: "0" },
    ],
    rankingByRevenue: [
      { rank: 1, product_name: "Remera", units: "4", revenue: "2600", operations: 2, is_group: true, variant_count: 2, gross_margin_pct: null, cost_coverage_pct: "0" },
      { rank: 2, product_name: "Gorra", units: "5", revenue: "2350", operations: 3, is_group: false, variant_count: 0, gross_margin_pct: "36.17", cost_coverage_pct: "33.3" },
    ],
    canal: [
      { bucket_key: "local", bucket_label: "local", sort_order: 1, revenue: "2900", units: "4", operations: 2 },
      { bucket_key: null, bucket_label: "Sin canal", sort_order: 2, revenue: "3150", units: "7", operations: 4 },
    ],
    weekday: [
      { bucket_key: "1", bucket_label: "Lunes", sort_order: 1, revenue: "2500", units: "3", operations: 1 },
      { bucket_key: "6", bucket_label: "Sábado", sort_order: 6, revenue: "3550", units: "8", operations: 5 },
      { bucket_key: "3", bucket_label: "Miércoles", sort_order: 3, revenue: "0", units: "0", operations: 0 },
    ],
    topClients: [
      { row_kind: "client", rank: 1, client_name: "Ana Pérez", revenue: "2900", operations: 2 },
      { row_kind: "unassigned", rank: null, client_name: null, revenue: "500", operations: 1 },
    ],
    ...overrides,
  }
}

describe("paridad del tipo de insight (10.3)", () => {
  it("la Edge Function persiste con el mismo tipo que el frontend lee", () => {
    expect(ESTADISTICAS_INSIGHT_TYPE).toBe(STATISTICS_INSIGHT_TYPE)
    expect(ESTADISTICAS_INSIGHT_TYPE).toBe("estadisticas")
  })
})

describe("buildEstadisticasPrompt (10.2 — sólo cifras de los read-models)", () => {
  it("toma los totales de la fila `current` de la evolución, nunca sumando buckets", () => {
    const r = buildEstadisticasPrompt(ctx())
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.prompt).toContain("5.900")     // neto de `current`
    expect(r.prompt).toContain("6.050")     // bruto de `current`
    expect(r.prompt).not.toContain("999")   // el bucket no se re-agrega
    expect(r.prompt).toMatch(/6 operaciones/)
    expect(r.prompt).toMatch(/11 unidades/)
  })

  it("compara contra el período anterior con la variación en %", () => {
    const r = buildEstadisticasPrompt(ctx())
    if (!r.ok) throw new Error("expected ok")
    expect(r.prompt).toContain("4.000")
    expect(r.prompt).toMatch(/\+48\s?%/)  // (5900 − 4000) / 4000
  })

  it("incluye el ranking por unidades y por importe, el canal (con 'Sin canal'), el día de la semana y el top de clientes con el importe sin cliente", () => {
    const r = buildEstadisticasPrompt(ctx())
    if (!r.ok) throw new Error("expected ok")
    expect(r.prompt).toMatch(/Gorra.*5 uds/)
    expect(r.prompt).toMatch(/Remera.*2\.600/)
    expect(r.prompt).toContain("Sin canal")
    expect(r.prompt).toContain("Sábado")
    expect(r.prompt).toContain("Ana Pérez")
    expect(r.prompt).toMatch(/sin cliente.*500/i)
    // El período va explícito.
    expect(r.prompt).toContain("2026-08-05")
    expect(r.prompt).toContain("2026-09-03")
  })

  it("un margen ausente se dice como tal, nunca como 0 %", () => {
    const r = buildEstadisticasPrompt(ctx())
    if (!r.ok) throw new Error("expected ok")
    expect(r.prompt).toMatch(/Remera[^\n]*margen s\/d/)
    expect(r.prompt).not.toMatch(/Remera[^\n]*0[.,]0\s?%/)
  })

  it("sin ventas en el período (current.operations = 0) → no_sales", () => {
    const r = buildEstadisticasPrompt(ctx({
      evolution: [{ period: "current", bucket_start: "2026-08-05", bucket_end: "2026-09-03", revenue: "0", credit_notes: "0", net_revenue: "0", units: "0", operations: 0, service_revenue: "0", ...WINDOW }],
    }))
    expect(r).toEqual({ ok: false, reason: "no_sales" })
  })

  it("sin fila `current` → missing_totals (nunca se inventa el total)", () => {
    const r = buildEstadisticasPrompt(ctx({ evolution: [] }))
    expect(r).toEqual({ ok: false, reason: "missing_totals" })
  })
})

describe("parseInsightJson", () => {
  it("acepta el JSON limpio y el envuelto en fences ```json", () => {
    expect(parseInsightJson('{"insight":"Hola","recommendations":["a","b"]}')).toEqual({ insight: "Hola", recommendations: ["a", "b"] })
    expect(parseInsightJson('```json\n{"insight":"Hola","recommendations":["a"]}\n```')).toEqual({ insight: "Hola", recommendations: ["a"] })
  })

  it("normaliza recomendaciones inválidas a lista vacía y un JSON roto a insight vacío", () => {
    expect(parseInsightJson('{"insight":"x","recommendations":"no"}')).toEqual({ insight: "x", recommendations: [] })
    expect(parseInsightJson("no es json")).toEqual({ insight: "", recommendations: [] })
    expect(parseInsightJson('{"recommendations":[1,"ok",null]}')).toEqual({ insight: "", recommendations: ["ok"] })
  })
})

function deps(overrides: Partial<AnalysisDeps> = {}) {
  const d = {
    checkQuota: vi.fn(async () => ({ allowed: true, body: null })),
    fetchContext: vi.fn(async () => ctx()),
    callModel: vi.fn(async () => ({ kind: "ok" as const, content: '{"insight":"Los sábados venden más.","recommendations":["a","b","c"]}' })),
    persistInsight: vi.fn(async () => {}),
    incrementUsage: vi.fn(async () => {}),
    ...overrides,
  }
  return d as AnalysisDeps & typeof d
}

describe("runEstadisticasAnalysis (10.4 / 10.6)", () => {
  it("cuota disponible → consulta el modelo, persiste el insight e incrementa el contador UNA vez", async () => {
    const d = deps()
    const r = await runEstadisticasAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toEqual({ ok: true, data: { insight: "Los sábados venden más.", recommendations: ["a", "b", "c"] } })
    expect(d.persistInsight).toHaveBeenCalledWith("Los sábados venden más.")
    expect(d.incrementUsage).toHaveBeenCalledTimes(1)
    // El modelo recibe el prompt con las cifras canónicas.
    expect(String(vi.mocked(d.callModel).mock.calls[0][0])).toContain("5.900")
  })

  it("cuota agotada → 429 con el cuerpo de la cuota; no lee contexto, no consulta al modelo, no incrementa", async () => {
    const body = { ok: false, error: "quota_exceeded", used: 5, limit: 5, resetAt: null }
    const d = deps({ checkQuota: vi.fn(async () => ({ allowed: false, body })) })
    const r = await runEstadisticasAnalysis(d)
    expect(r).toEqual({ status: 429, body })
    expect(d.fetchContext).not.toHaveBeenCalled()
    expect(d.callModel).not.toHaveBeenCalled()
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("timeout del modelo → 200 fallback, sin persistir ni incrementar", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "timeout" as const })) })
    const r = await runEstadisticasAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toMatchObject({ ok: true, fallback: true })
    expect(String(r.body.message)).toMatch(/tardó demasiado/)
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("el modelo responde pero sin insight utilizable → fallback, sin persistir ni incrementar", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "ok" as const, content: "{}" })) })
    const r = await runEstadisticasAnalysis(d)
    expect(r.body).toMatchObject({ ok: true, fallback: true })
    expect(d.persistInsight).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("error HTTP del proveedor → 502 con el detalle, sin persistir ni incrementar", async () => {
    const d = deps({ callModel: vi.fn(async () => ({ kind: "http_error" as const, status: 500, message: "upstream" })) })
    const r = await runEstadisticasAnalysis(d)
    expect(r.status).toBe(502)
    expect(String(r.body.error)).toMatch(/500/)
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("sin ventas en el período → 422 antes de consultar al modelo", async () => {
    const d = deps({
      fetchContext: vi.fn(async () => ctx({
        evolution: [{ period: "current", bucket_start: "2026-08-05", bucket_end: "2026-09-03", revenue: "0", credit_notes: "0", net_revenue: "0", units: "0", operations: 0, service_revenue: "0", ...WINDOW }],
      })),
    })
    const r = await runEstadisticasAnalysis(d)
    expect(r.status).toBe(422)
    expect(d.callModel).not.toHaveBeenCalled()
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })

  it("si persistir falla, el análisis igual se devuelve pero el contador NO se incrementa (no se cobró lo que no quedó)", async () => {
    const d = deps({ persistInsight: vi.fn(async () => { throw new Error("db down") }) })
    const r = await runEstadisticasAnalysis(d)
    expect(r.status).toBe(200)
    expect(r.body).toMatchObject({ ok: true, data: { insight: "Los sábados venden más." } })
    expect(d.incrementUsage).not.toHaveBeenCalled()
  })
})
