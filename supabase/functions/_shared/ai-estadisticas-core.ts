// Núcleo puro de la Edge Function ai-estadisticas — estadisticas-ventas E3
// (grupo 10). El handler (ai-estadisticas/index.ts, Deno.serve) sólo cablea
// dependencias reales (Supabase, OpenAI) en `runEstadisticasAnalysis`; TODA
// la decisión vive acá y se prueba con dobles inyectados desde vitest
// (frontend/__tests__/ai-estadisticas.test.ts — patrón D5/D6 de ai-quota.ts).
//
// Invariantes (spec sales-statistics, "Análisis IA del módulo"):
//   · La cuota se verifica ANTES de leer dato alguno y antes del modelo.
//   · El contexto del prompt sale de las filas de los read-models canónicos
//     del módulo (rpc_sales_evolution `current`/`previous`, rpc_product_ranking,
//     rpc_sales_breakdown canal/weekday, rpc_sales_top_clients) TAL CUAL:
//     acá no se suman buckets, ni líneas, ni se recalcula nada
//     (reporting-invariants, "Enforcement de consumo").
//   · El contador de uso se incrementa SÓLO cuando el insight se generó Y se
//     persistió; timeout, respuesta vacía, error del proveedor o fallo al
//     persistir → sin incremento.
//   · El tipo de insight es propio del módulo y coincide con el que el
//     frontend lee (STATISTICS_INSIGHT_TYPE en lib/sales-statistics.ts).
//
// La orquestación (cuota → contexto → prompt → modelo → persistir → cobrar)
// es GENÉRICA y vive en `_shared/ai-insight-core.ts` (candidato "alinear
// ai-rentabilidad con ai-estadisticas" — ai-rentabilidad-core.ts la reusa
// con su propio contexto/prompt/mensajes). Este archivo conserva su API
// pública sin cambios (mismos nombres/formas — ver el test) y sólo delega.
//
// TS puro, sin `Deno.*` a nivel módulo: deployable a Deno y testeable.

import {
  parseInsightJson as sharedParseInsightJson,
  runAiInsightAnalysis,
  type AnalysisResult as SharedAnalysisResult,
  type ModelOutcome as SharedModelOutcome,
  type ParsedInsight as SharedParsedInsight,
} from "./ai-insight-core.ts"

export const ESTADISTICAS_INSIGHT_TYPE = "estadisticas"

// ─── Filas de los read-models (como las entrega supabase-js: numerics = string) ─

type Num = number | string | null | undefined

export interface StatisticsWindowRow {
  window_start: string
  window_end: string
  history_days: number
  window_clamped: boolean
}

export interface EvolutionRow extends StatisticsWindowRow {
  period: "bucket" | "current" | "previous"
  bucket_start: string
  bucket_end: string
  revenue: Num
  credit_notes: Num
  net_revenue: Num
  units: Num
  operations: Num
  service_revenue: Num
}

export interface RankingRow {
  rank: number
  product_name: string
  units: Num
  revenue: Num
  operations: Num
  is_group: boolean
  variant_count: number
  gross_margin_pct: Num
  cost_coverage_pct: Num
}

export interface BreakdownRow {
  bucket_key: string | null
  bucket_label: string
  sort_order: number
  revenue: Num
  units: Num
  operations: Num
}

export interface TopClientRow {
  row_kind: "client" | "unassigned"
  rank: number | null
  client_name: string | null
  revenue: Num
  operations: Num
}

export interface EstadisticasContext {
  evolution: EvolutionRow[]
  rankingByUnits: RankingRow[]
  rankingByRevenue: RankingRow[]
  canal: BreakdownRow[]
  weekday: BreakdownRow[]
  topClients: TopClientRow[]
}

// ─── Formato (es-AR) ──────────────────────────────────────────────────────────

function n(v: Num): number {
  const x = typeof v === "number" ? v : Number(v ?? 0)
  return Number.isFinite(x) ? x : 0
}

function money(v: Num): string {
  return `$${Math.round(n(v)).toLocaleString("es-AR")}`
}

function pct1(v: Num): string {
  return `${n(v).toLocaleString("es-AR", { maximumFractionDigits: 1 })} %`
}

function changePct(current: number, previous: number): string {
  if (!previous) return "sin base de comparación"
  const p = Math.round(((current - previous) / previous) * 100)
  return `${p >= 0 ? "+" : ""}${p} %`
}

function rankingLine(r: RankingRow): string {
  const margin = r.gross_margin_pct === null || r.gross_margin_pct === undefined
    ? "margen s/d"
    : `margen ${pct1(r.gross_margin_pct)}${n(r.cost_coverage_pct) < 100 ? ` (${pct1(r.cost_coverage_pct)} de las líneas con costo)` : ""}`
  const group = r.is_group ? ` [agrupa ${r.variant_count} variante${r.variant_count === 1 ? "" : "s"}]` : ""
  return `${r.product_name}${group}: ${n(r.units).toLocaleString("es-AR")} uds, ${money(r.revenue)}, ${n(r.operations)} op., ${margin}`
}

function breakdownLine(r: BreakdownRow): string {
  return `${r.bucket_label}: ${money(r.revenue)} (${n(r.operations)} op.)`
}

// ─── Prompt ───────────────────────────────────────────────────────────────────

export type PromptBuildResult =
  | { ok: true; prompt: string }
  | { ok: false; reason: "no_sales" | "missing_totals" }

/**
 * Arma el contexto del modelo con las cifras de los read-models, tal cual
 * llegan. La fila `current` de la evolución es la ÚNICA fuente del total del
 * período (nunca la suma de los buckets); sin ella no se inventa nada.
 */
export function buildEstadisticasPrompt(ctx: EstadisticasContext): PromptBuildResult {
  const current = ctx.evolution.find((r) => r.period === "current")
  const previous = ctx.evolution.find((r) => r.period === "previous")
  if (!current) return { ok: false, reason: "missing_totals" }
  if (n(current.operations) === 0) return { ok: false, reason: "no_sales" }

  const netNow = n(current.net_revenue)
  const netPrev = previous ? n(previous.net_revenue) : 0

  const bestDays = [...ctx.weekday].sort((a, b) => n(b.revenue) - n(a.revenue))
  const clients = ctx.topClients.filter((r) => r.row_kind === "client")
  const unassigned = ctx.topClients.find((r) => r.row_kind === "unassigned")

  const blocks = [
    `PERÍODO: ${current.bucket_start} a ${current.bucket_end}${current.window_clamped ? ` (recortado al historial del plan: ${current.history_days} días)` : ""}`,
    `TOTALES DEL PERÍODO: facturación bruta ${money(current.revenue)}, notas de crédito ${money(current.credit_notes)}, facturación neta ${money(netNow)}, ${n(current.operations)} operaciones, ${n(current.units).toLocaleString("es-AR")} unidades, ${money(current.service_revenue)} en servicios sin producto.`,
    previous
      ? `PERÍODO ANTERIOR (${previous.bucket_start} a ${previous.bucket_end}): facturación neta ${money(netPrev)}, ${n(previous.operations)} operaciones → variación ${changePct(netNow, netPrev)}.`
      : "",
    ctx.rankingByUnits.length > 0
      ? `TOP PRODUCTOS POR UNIDADES:\n${ctx.rankingByUnits.map((r) => `  • ${rankingLine(r)}`).join("\n")}`
      : "",
    ctx.rankingByRevenue.length > 0
      ? `TOP PRODUCTOS POR IMPORTE:\n${ctx.rankingByRevenue.map((r) => `  • ${rankingLine(r)}`).join("\n")}`
      : "",
    ctx.canal.length > 0
      ? `POR CANAL (facturación bruta, sin restar notas de crédito):\n${ctx.canal.map((r) => `  • ${breakdownLine(r)}`).join("\n")}`
      : "",
    bestDays.length > 0
      ? `POR DÍA DE LA SEMANA (fecha de negocio):\n${bestDays.map((r) => `  • ${breakdownLine(r)}`).join("\n")}`
      : "",
    clients.length > 0 || unassigned
      ? `TOP CLIENTES:\n${clients.map((r) => `  • ${r.client_name ?? "Cliente no disponible"}: ${money(r.revenue)} (${n(r.operations)} op.)`).join("\n")}${
          unassigned ? `\n  • Ventas sin cliente asignado: ${money(unassigned.revenue)} (${n(unassigned.operations)} op.)` : ""
        }`
      : "",
  ].filter(Boolean)

  const prompt = `${blocks.join("\n\n")}

Analizá las estadísticas de ventas de este período. Identificá los hallazgos más importantes con datos concretos: qué se vende, cuándo, por dónde y a quién, y cómo se compara con el período anterior.

Devolvé un JSON con:
- "insight": string — síntesis ejecutiva de 2-3 oraciones con los números más relevantes
- "recommendations": string[] — exactamente 3 recomendaciones concretas y accionables

Devolvé SOLO el JSON.`

  return { ok: true, prompt }
}

export type ParsedInsight = SharedParsedInsight

/** Extrae {insight, recommendations} del contenido del modelo (con o sin
 *  fences ```json). Cualquier cosa que no encaje se degrada a vacío — el
 *  caller decide qué hacer con un insight vacío (fallback, sin cobrar).
 *  Re-exporta el parser genérico de `ai-insight-core.ts` bajo el nombre que
 *  este módulo ya publicaba. */
export const parseInsightJson = sharedParseInsightJson

// ─── Orquestación ─────────────────────────────────────────────────────────────
// Delega en el orquestador genérico (`ai-insight-core.ts`); acá sólo se traduce
// `buildEstadisticasPrompt` a la forma que ese orquestador espera (prompt u
// rechazo con status/body propios de este módulo) y se fijan los mensajes de
// fallback. Ver ese archivo para el invariante de cobro (cuota → contexto →
// modelo → persistir → cobrar SÓLO si se persistió).

export type ModelOutcome = SharedModelOutcome

export interface AnalysisDeps {
  /** checkAiQuota(supabase, userId, 'queries') — {allowed, body (429)}. */
  checkQuota(): Promise<{ allowed: boolean; body: unknown }>
  /** Las filas de los read-models canónicos, leídas con el JWT del usuario. */
  fetchContext(): Promise<EstadisticasContext>
  callModel(prompt: string): Promise<ModelOutcome>
  persistInsight(insight: string): Promise<void>
  incrementUsage(): Promise<void>
}

export type AnalysisResult = SharedAnalysisResult

const FALLBACK_TIMEOUT = "El análisis tardó demasiado. Intentá de nuevo."
const FALLBACK_EMPTY = "No se pudo generar el análisis de estadísticas. Intentá de nuevo más tarde."

export async function runEstadisticasAnalysis(deps: AnalysisDeps): Promise<AnalysisResult> {
  // Revisión adversarial (fix 12): los métodos de `deps` se envuelven en
  // lambdas en vez de copiarse por referencia (`checkQuota: deps.checkQuota`)
  // — ver el mismo comentario en `ai-rentabilidad-core.ts`: una referencia
  // desatada pierde el receptor original si `deps` es una instancia de clase
  // cuyos métodos usan `this`.
  return runAiInsightAnalysis<EstadisticasContext>({
    checkQuota: () => deps.checkQuota(),
    fetchContext: () => deps.fetchContext(),
    buildPrompt: (ctx) => {
      const built = buildEstadisticasPrompt(ctx)
      if (built.ok) return built
      if (built.reason === "no_sales") {
        return { ok: false, status: 422, body: { ok: false, error: "Sin ventas en el período seleccionado" } }
      }
      return { ok: false, status: 500, body: { ok: false, error: "El read-model de evolución no devolvió los totales del período" } }
    },
    callModel: (prompt) => deps.callModel(prompt),
    persistInsight: (insight) => deps.persistInsight(insight),
    incrementUsage: () => deps.incrementUsage(),
    fallbackTimeoutMessage: FALLBACK_TIMEOUT,
    fallbackEmptyMessage: FALLBACK_EMPTY,
  })
}
