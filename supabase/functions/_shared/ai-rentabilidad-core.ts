// Núcleo puro de la Edge Function ai-rentabilidad (C-11 rentabilidad, molde
// original de las Edge Functions de IA). El handler
// (ai-rentabilidad/index.ts, Deno.serve) sólo cablea dependencias reales
// (Supabase, OpenAI); TODA la decisión vive acá y se prueba con dobles
// inyectados desde vitest (frontend/__tests__/ai-rentabilidad.test.ts —
// mismo patrón D5/D6 de ai-quota.ts).
//
// Alineado con ai-estadisticas-core.ts (candidato "alinear ai-rentabilidad
// con ai-estadisticas", CLAUDE.md): la orquestación genérica (cuota →
// contexto → prompt → modelo → persistir → cobrar SÓLO si se persistió)
// vive en `_shared/ai-insight-core.ts` — este módulo sólo define su propio
// contexto (`rpc_product_profitability`), su prompt y sus mensajes.
//
// TS puro, sin `Deno.*` a nivel módulo: deployable a Deno y testeable.

import {
  runAiInsightAnalysis,
  type AiInsightDeps,
  type AnalysisResult,
  type ModelOutcome,
  type ParsedInsight,
  type PromptOutcome,
} from "./ai-insight-core.ts"

export { parseInsightJson, type AnalysisResult, type ModelOutcome, type ParsedInsight } from "./ai-insight-core.ts"

export const RENTABILIDAD_INSIGHT_TYPE = "margen"

// ─── Filas del read-model (como las entrega supabase-js: numerics = string) ───

type Num = number | string | null | undefined

export interface ProfitabilityRow {
  product_name: string
  total_revenue: Num
  total_cost: Num
  gross_margin_pct: Num
  units_sold: Num
}

export interface RentabilidadContext {
  periodDays: number
  rows: ProfitabilityRow[]
}

// ─── Prompt ───────────────────────────────────────────────────────────────────

const fmt = (n: unknown) => `$${Math.round(Number(n)).toLocaleString("es-AR")}`
const pctFmt = (n: unknown) => `${Number(n).toFixed(1)}%`
// productos-costo-nullable: `total_cost`/`gross_margin_pct` pueden llegar
// `null` (ningún costo resoluble en el grupo, capability product-cost) —
// `fmt(null)`/`pctFmt(null)` fabricarían "$0"/"0.0%" en silencio. Se OMITE
// el par costo/margen del contexto en vez de sustituirlo (nunca inventar).
const fmtRow = (p: ProfitabilityRow) => {
  const base = `${p.product_name}: ingresos ${fmt(p.total_revenue)}`
  const hasCost = p.total_cost != null && p.gross_margin_pct != null
  const costPart = hasCost ? `, costo ${fmt(p.total_cost)}, margen ${pctFmt(p.gross_margin_pct)}` : ", sin costo cargado"
  return `${base}${costPart}, ${p.units_sold} uds`
}

/**
 * Arma el contexto del modelo con el top 5 / bottom 5 de margen bruto tal
 * cual los entrega `rpc_product_profitability` (ordenado DESC por
 * `gross_margin_pct`) — sin ventas en el período → rechazo 422.
 */
export function buildRentabilidadPrompt(ctx: RentabilidadContext): PromptOutcome {
  if (ctx.rows.length === 0) {
    return { ok: false, status: 422, body: { ok: false, error: "Sin datos de ventas en el período seleccionado" } }
  }

  const topProducts = ctx.rows.slice(0, 5)
  const bottomProducts = ctx.rows.length > 5 ? ctx.rows.slice(-5) : []

  const contextBlock = [
    `PERÍODO: últimos ${ctx.periodDays} días`,
    "",
    topProducts.length > 0
      ? `TOP MARGEN:\n${topProducts.map((p) => `  • ${fmtRow(p)}`).join("\n")}`
      : "",
    bottomProducts.length > 0
      ? `BAJO MARGEN:\n${bottomProducts.map((p) => `  • ${fmtRow(p)}`).join("\n")}`
      : "",
  ].filter(Boolean).join("\n")

  const prompt = `${contextBlock}

Analizá la rentabilidad de estos productos. Identificá los hallazgos más importantes con datos concretos.

Devolvé un JSON con:
- "insight": string — síntesis ejecutiva de 2-3 oraciones con los números más relevantes
- "recommendations": string[] — exactamente 3 recomendaciones concretas y accionables

Devolvé SOLO el JSON.`

  return { ok: true, prompt }
}

// ─── Orquestación ─────────────────────────────────────────────────────────────

export interface AnalysisDeps {
  /** checkAiQuota(supabase, userId, 'queries') — {allowed, body (429)}. */
  checkQuota(): Promise<{ allowed: boolean; body: unknown }>
  /** Las filas de `rpc_product_profitability` + el período pedido. */
  fetchContext(): Promise<RentabilidadContext>
  callModel(prompt: string): Promise<ModelOutcome>
  persistInsight(insight: string): Promise<void>
  incrementUsage(): Promise<void>
}

const FALLBACK_TIMEOUT = "El análisis tardó demasiado. Intentá de nuevo."
const FALLBACK_EMPTY = "No se pudo generar el análisis de rentabilidad. Intentá de nuevo más tarde."

export async function runRentabilidadAnalysis(deps: AnalysisDeps): Promise<AnalysisResult> {
  // Revisión adversarial (fix 12): los métodos de `deps` se envuelven en
  // lambdas (`() => deps.checkQuota()`) en vez de copiarse por referencia
  // (`checkQuota: deps.checkQuota`) — una referencia desatada pierde el
  // receptor original si `deps` es una instancia de clase cuyos métodos usan
  // `this` (el `this` efectivo pasaría a ser `genericDeps`, un objeto plano
  // sin el estado de la clase). Envolver conserva el `deps` capturado por
  // clausura como receptor, sin importar cómo esté implementado.
  const genericDeps: AiInsightDeps<RentabilidadContext> = {
    checkQuota: () => deps.checkQuota(),
    fetchContext: () => deps.fetchContext(),
    buildPrompt: buildRentabilidadPrompt,
    callModel: (prompt) => deps.callModel(prompt),
    persistInsight: (insight) => deps.persistInsight(insight),
    incrementUsage: () => deps.incrementUsage(),
    fallbackTimeoutMessage: FALLBACK_TIMEOUT,
    fallbackEmptyMessage: FALLBACK_EMPTY,
  }
  return runAiInsightAnalysis(genericDeps)
}
