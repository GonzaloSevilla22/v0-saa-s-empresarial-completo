// Verificador PURO de las evals del Copiloto — ia-copilot-v2 (tanda A, D12).
//
// La corrida real (scripts/ai/copilot-evals.ts) llama a la Edge Function desplegada con el JWT de
// una cuenta de prueba, ejecuta la RPC canónica de cada caso con el MISMO JWT para obtener el número
// esperado y usa este módulo para decidir si la respuesta lo contiene. Todo lo que no necesita clave
// vive acá y se prueba en vitest (frontend/__tests__/ai-copilot-evals.test.ts).
//
// TS puro, sin `Deno.*` a nivel de módulo.

import { artDateInfo } from "./ai-copilot-prompt.ts"

// ─── Tipos del set de casos ───────────────────────────────────────────────────

export interface EvalExtract {
  /** «<fila>.<columna>» sobre las filas que devuelve la RPC. */
  path?: string
  /** Suma de una columna sobre TODAS las filas. */
  sum?: string
  /** Ordena las filas descendente por esta columna antes de elegir la del `path`. */
  sort_desc?: string
  as: "money" | "integer" | "text"
}

export interface EvalRpcCheck {
  fn: string
  /** Sólo `rpc_dashboard_kpi_summary`: el script arma p_from/p_to y la ventana previa. */
  window?: { from: string; to: string }
  args?: Record<string, unknown>
  extract: EvalExtract
}

export interface EvalExpect {
  tools_any_of?: string[]
  rpc_check?: EvalRpcCheck
  must_contain_number?: boolean
  must_ask_clarification?: boolean
  must_refuse_write?: { tables: string[] }
}

export interface EvalCase {
  id: string
  group: "real" | "vague" | "followup" | "clarification" | "write"
  question: string
  history?: Array<{ role: "user" | "assistant"; content: string }>
  state?: unknown
  expect: EvalExpect
}

export interface EvalResponse {
  kind: string
  answer: string
  consulted: Array<{ tool: string; label: string }>
}

export interface Grade {
  pass: boolean
  skipped?: boolean
  numeric: boolean
  reason: string
}

// ─── Texto y montos ───────────────────────────────────────────────────────────

/** Minúsculas, sin tildes, sin ¿ ni ¡, espacios colapsados. */
export function normalizeText(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[¿¡]/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

const AMOUNT_RE = /\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:,\d+)?/g

/** Todos los números de la respuesta, en formato es-AR (punto de miles, coma decimal). */
export function parseAmounts(answer: string): number[] {
  const out: number[] = []
  for (const m of answer.match(AMOUNT_RE) ?? []) {
    const n = Number(m.replace(/\./g, "").replace(",", "."))
    if (Number.isFinite(n)) out.push(n)
  }
  return out
}

/** ¿Algún número de la respuesta coincide con el esperado, redondeado a peso entero (en valor absoluto)? */
export function answerHasAmount(answer: string, expected: number): boolean {
  const target = Math.round(Math.abs(expected))
  return parseAmounts(answer).some((n) => Math.round(Math.abs(n)) === target)
}

export function answerHasText(answer: string, expected: string): boolean {
  return normalizeText(answer).includes(normalizeText(expected))
}

const REFUSAL_PATTERNS: readonly RegExp[] = [
  /(s[oó]lo|solamente|[uú]nicamente)[^.]{0,40}(consult|ver |leer)/i,
  /no (puedo|podes|podés|se puede|logro|registro|anoto)[^.]{0,30}(registrar|anotar|cargar|crear|agregar|editar|borrar|eliminar)/i,
  /desde ac[aá][^.]{0,40}(no|s[oó]lo|solamente)/i,
]

/** ¿La respuesta se niega a registrar y explica que el asistente es de consulta? */
export function looksLikeRefusal(answer: string): boolean {
  return REFUSAL_PATTERNS.some((re) => re.test(answer))
}

// ─── Número esperado desde las filas de la RPC ────────────────────────────────

function toRecords(rows: unknown): Record<string, unknown>[] {
  return Array.isArray(rows) ? rows.filter((r): r is Record<string, unknown> => typeof r === "object" && r !== null && !Array.isArray(r)) : []
}

/** El valor esperado (número o texto) sin re-agregar: elige una fila o suma una columna. `null` = no hay con qué verificar. */
export function extractExpected(rows: unknown, extract: EvalExtract): number | string | null {
  let list = toRecords(rows)
  if (list.length === 0) return null
  const num = (v: unknown): number | null => (v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v))

  if (extract.sum) {
    const col = extract.sum
    const values = list.map((r) => num(r[col])).filter((n): n is number => n !== null)
    if (values.length === 0) return null
    const total = values.reduce((a, b) => a + b, 0)
    return extract.as === "integer" ? Math.round(total) : total
  }
  if (!extract.path) return null
  if (extract.sort_desc) {
    const col = extract.sort_desc
    list = [...list].sort((a, b) => (num(b[col]) ?? 0) - (num(a[col]) ?? 0))
  }
  const dot = extract.path.indexOf(".")
  const idx = Number(extract.path.slice(0, dot))
  const column = extract.path.slice(dot + 1)
  const cell = list[idx]?.[column]
  if (cell === null || cell === undefined) return null
  if (extract.as === "text") return String(cell)
  const n = num(cell)
  if (n === null) return null
  return extract.as === "integer" ? Math.round(n) : n
}

// ─── Placeholders ─────────────────────────────────────────────────────────────

/** Reemplaza los valores string que sean un placeholder de fecha ($today, $month_start, ...), en cualquier profundidad. */
export function resolvePlaceholders<T>(value: T, now: Date): T {
  const d = artDateInfo(now)
  const map: Record<string, string> = {
    $today: d.today, $yesterday: d.yesterday, $week_start: d.weekStart,
    $last_week_start: d.lastWeekStart, $last_week_end: d.lastWeekEnd,
    $month_start: d.monthStart, $last_month_start: d.lastMonthStart, $last_month_end: d.lastMonthEnd,
  }
  const walk = (v: unknown): unknown => {
    if (typeof v === "string") return map[v] ?? v
    if (Array.isArray(v)) return v.map(walk)
    if (typeof v === "object" && v !== null) {
      return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, walk(x)]))
    }
    return v
  }
  return walk(value) as T
}

// ─── Calificación de un caso ──────────────────────────────────────────────────

export function gradeCase(c: EvalCase, response: EvalResponse, expected: number | string | null, ctx: { rowsCreated?: number } = {}): Grade {
  const e = c.expect
  const numeric = e.rpc_check !== undefined

  if (e.must_ask_clarification) {
    const pass = response.kind === "clarification"
    return { pass, numeric: false, reason: pass ? "" : `se esperaba una repregunta y la respuesta fue kind=${response.kind}` }
  }

  if (e.must_refuse_write) {
    if ((ctx.rowsCreated ?? 0) > 0) return { pass: false, numeric: false, reason: `se crearon ${ctx.rowsCreated} filas en ${e.must_refuse_write.tables.join("/")}` }
    const refused = looksLikeRefusal(response.answer)
    return { pass: refused, numeric: false, reason: refused ? "" : "la respuesta no se niega a registrar" }
  }

  if (e.tools_any_of && e.tools_any_of.length > 0) {
    const used = response.consulted.map((x) => x.tool)
    if (!e.tools_any_of.some((t) => used.includes(t))) {
      return { pass: false, numeric, reason: `no usó ninguna herramienta esperada (${e.tools_any_of.join(", ")}); usó: ${used.join(", ") || "ninguna"}` }
    }
  }

  if (e.rpc_check) {
    if (expected === null) return { pass: true, skipped: true, numeric: true, reason: "la RPC no devolvió datos para verificar" }
    const ok = e.rpc_check.extract.as === "text"
      ? answerHasText(response.answer, String(expected))
      : answerHasAmount(response.answer, Number(expected))
    if (!ok) return { pass: false, numeric: true, reason: `no aparece «${expected}» en la respuesta` }
  }

  if (e.must_contain_number && parseAmounts(response.answer).length === 0) {
    return { pass: false, numeric, reason: "la respuesta no cita ningún número" }
  }

  return { pass: true, numeric, reason: "" }
}

// ─── Resumen de una corrida ───────────────────────────────────────────────────

export interface RunResult {
  id: string
  group: string
  pass: boolean
  skipped: boolean
  numeric: boolean
  latency_ms: number
  prompt_tokens: number
  completion_tokens: number
  reason: string
}

const mean = (xs: number[]): number => (xs.length === 0 ? 0 : Math.round(xs.reduce((a, b) => a + b, 0) / xs.length))

export function summarizeRun(run: { model: string; date: string; results: RunResult[] }): string {
  const evaluated = run.results.filter((r) => !r.skipped)
  const numeric = evaluated.filter((r) => r.numeric)
  const numericHits = numeric.filter((r) => r.pass).length
  const pct = numeric.length === 0 ? 0 : Math.round((numericHits / numeric.length) * 100)
  const group = (g: string) => run.results.filter((r) => r.group === g)
  const clar = group("clarification")
  const writes = group("write")
  const skipped = run.results.filter((r) => r.skipped).length
  const failures = run.results.filter((r) => !r.pass)

  const lines = [
    `# Evals del Copiloto — ${run.model} — ${run.date}`,
    "",
    `- Casos corridos: ${run.results.length}`,
    `- Aciertos numéricos: ${numericHits}/${numeric.length} (${pct}%)`,
    `- Repreguntas correctas: ${clar.filter((r) => r.pass).length}/${clar.length}`,
    `- Negativas correctas: ${writes.filter((r) => r.pass).length}/${writes.length}`,
    `- Omitidos (sin datos para verificar): ${skipped}`,
    `- Latencia media: ${mean(evaluated.map((r) => r.latency_ms))} ms`,
    `- Tokens medios por pregunta: ${mean(evaluated.map((r) => r.prompt_tokens))} de entrada / ${mean(evaluated.map((r) => r.completion_tokens))} de salida`,
    "",
    "## Fallas",
    "",
    ...(failures.length === 0 ? ["Ninguna."] : failures.map((r) => `- ${r.id} (${r.group}): ${r.reason}`)),
    "",
  ]
  return lines.join("\n")
}
