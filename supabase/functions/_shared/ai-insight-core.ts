// Núcleo genérico de orquestación para las Edge Functions de "insight IA"
// (ai-estadisticas, ai-rentabilidad, …). Extraído de
// `_shared/ai-estadisticas-core.ts` (estadisticas-ventas E3) al generalizar
// para que ai-rentabilidad deje de cobrar cuota por un insight vacío o no
// persistido (candidato "alinear ai-rentabilidad con ai-estadisticas").
//
// Cada Edge Function define su propio contexto (`TContext`) y su propio
// `buildPrompt`/mensajes de fallback; ESTE módulo sólo fija el orden y el
// invariante de cobro, comunes a todas:
//
//   1. La cuota se verifica ANTES de leer dato alguno y antes del modelo.
//   2. El contador de uso se incrementa SÓLO cuando el insight se generó Y
//      se persistió; timeout, respuesta vacía, error del proveedor o fallo
//      al construir el prompt/persistir → sin incremento.
//
// TS puro, sin `Deno.*` a nivel módulo: deployable a Deno y testeable desde
// vitest (mismo patrón D5/D6 de ai-quota.ts).

export type PromptOutcome =
  | { ok: true; prompt: string }
  /** El caller decide status/body del rechazo (422 sin ventas, 500 datos
   *  incompletos, etc.) — cada módulo tiene sus propios mensajes. */
  | { ok: false; status: number; body: Record<string, unknown> }

export type ModelOutcome =
  | { kind: "ok"; content: string }
  | { kind: "timeout" }
  | { kind: "http_error"; status: number; message: string }
  | { kind: "error"; message: string }

export interface ParsedInsight {
  insight: string
  recommendations: string[]
}

/** Extrae {insight, recommendations} del contenido del modelo (con o sin
 *  fences ```json). Cualquier cosa que no encaje se degrada a vacío — el
 *  caller decide qué hacer con un insight vacío (fallback, sin cobrar). */
export function parseInsightJson(content: string): ParsedInsight {
  const cleaned = content.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim()
  let parsed: unknown
  try {
    parsed = JSON.parse(cleaned)
  } catch {
    return { insight: "", recommendations: [] }
  }
  const obj = (parsed && typeof parsed === "object" ? parsed : {}) as Record<string, unknown>
  const insight = typeof obj.insight === "string" ? obj.insight.trim() : ""
  const recommendations = Array.isArray(obj.recommendations)
    ? obj.recommendations.filter((r): r is string => typeof r === "string")
    : []
  return { insight, recommendations }
}

export interface AiInsightDeps<TContext> {
  /** checkAiQuota(supabase, userId, 'queries') — {allowed, body (429)}. */
  checkQuota(): Promise<{ allowed: boolean; body: unknown }>
  /** Las filas de los read-models canónicos, leídas con el JWT del usuario. */
  fetchContext(): Promise<TContext>
  /** Arma el prompt desde el contexto, o el rechazo (status+body) propio del módulo. */
  buildPrompt(ctx: TContext): PromptOutcome
  callModel(prompt: string): Promise<ModelOutcome>
  persistInsight(insight: string): Promise<void>
  incrementUsage(): Promise<void>
  /** Mensaje del fallback 200 cuando el modelo tarda demasiado. */
  fallbackTimeoutMessage: string
  /** Mensaje del fallback 200 cuando el modelo no devuelve un insight utilizable. */
  fallbackEmptyMessage: string
}

export interface AnalysisResult {
  status: number
  body: Record<string, unknown>
}

function fallback(message: string): AnalysisResult {
  return { status: 200, body: { ok: true, fallback: true, message } }
}

export async function runAiInsightAnalysis<TContext>(deps: AiInsightDeps<TContext>): Promise<AnalysisResult> {
  // 1. Cuota, antes de leer dato alguno.
  const quota = await deps.checkQuota()
  if (!quota.allowed) {
    const body = (quota.body && typeof quota.body === "object" ? quota.body : { ok: false, error: "quota_exceeded" }) as Record<string, unknown>
    return { status: 429, body }
  }

  // 2. Contexto desde los read-models canónicos del módulo.
  const ctx = await deps.fetchContext()
  const built = deps.buildPrompt(ctx)
  if (!built.ok) return { status: built.status, body: built.body }

  // 3. Modelo.
  const outcome = await deps.callModel(built.prompt)
  if (outcome.kind === "timeout") return fallback(deps.fallbackTimeoutMessage)
  if (outcome.kind === "http_error") {
    return { status: 502, body: { ok: false, error: `OpenAI error ${outcome.status}: ${outcome.message}` } }
  }
  if (outcome.kind === "error") return { status: 502, body: { ok: false, error: outcome.message } }

  const parsed = parseInsightJson(outcome.content)
  if (!parsed.insight) return fallback(deps.fallbackEmptyMessage)

  // 4. Persistir y, sólo entonces, cobrar. Si persistir falla, el análisis
  //    igual se devuelve (ya se generó) pero NO se incrementa el contador:
  //    no se cobra lo que no quedó guardado.
  try {
    await deps.persistInsight(parsed.insight)
  } catch {
    return { status: 200, body: { ok: true, data: parsed, persisted: false } }
  }
  await deps.incrementUsage()

  return { status: 200, body: { ok: true, data: parsed } }
}
