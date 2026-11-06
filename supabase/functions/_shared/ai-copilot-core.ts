// Núcleo puro de la Edge Function ai-copilot — ia-copilot-v2 (tanda A, D1/D2/D4/D8/D9/D10).
//
// El handler (ai-copilot/index.ts, Deno.serve) sólo cablea dependencias reales (cliente con el JWT
// del usuario, OpenAI, la lectura de `products`); TODA la decisión vive acá y se prueba con
// dobles inyectados desde vitest (frontend/__tests__/ai-copilot-core.test.ts):
//
//   validar → reservar cuota → armar mensajes → bucle de herramientas → respuesta → registrar
//
//   - La reserva de cuota ocurre UNA vez por pregunta, después de validar y ANTES de leer cualquier
//     dato o llamar al modelo; las rondas de herramientas no reservan aparte (el techo de costo lo
//     ponen los topes: 3 rondas, 8 llamadas, 700 tokens de salida, 45 s en total).
//   - El texto de error del proveedor NUNCA llega a la persona: se loguea y se contesta con una
//     forma cerrada (`ai_unavailable`, `fallback`, ...).
//   - Una reserva concedida no se devuelve aunque el modelo falle.
//   - El Copiloto es de sólo lectura: ninguna herramienta escribe; la única escritura de este
//     módulo es el registro de la conversación (`deps.record`).
//
// TS puro, sin `Deno.*` a nivel de módulo: deployable a Deno y testeable desde vitest.

import type { AiReservationResult } from "./ai-quota.ts"
import {
  COPILOT_TOOLS,
  type ConsultedItem,
  type CopilotToolDefinition,
  type FocusState,
  type ToolOutcome,
} from "./ai-copilot-tools.ts"
import {
  COPILOT_RESPONSE_SCHEMA,
  EMPTY_STATE,
  buildSystemPrompt,
  fitHistory,
  validateCopilotState,
  type CopilotState,
  type HistoryMessage,
} from "./ai-copilot-prompt.ts"
import { isUuid } from "./statistics-params.ts"

// ─── Constantes ───────────────────────────────────────────────────────────────

export const MAX_QUESTION_LENGTH = 1000
export const MAX_HISTORY_MESSAGES = 20
export const MAX_HISTORY_MESSAGE_LENGTH = 4000
export const MAX_TOOL_ROUNDS = 3
export const MAX_TOOL_CALLS = 8
export const TURN_TIMEOUT_MS = 45_000
export const MODEL_CALL_TIMEOUT_MS = 25_000
export const RPC_TIMEOUT_MS = 8_000
export const MAX_OUTPUT_TOKENS = 700
/** Un resultado de herramienta más largo que esto no vuelve al modelo (los topes de filas ya lo evitan). */
export const MAX_TOOL_RESULT_CHARS = 20_000

export const COPILOT_FALLBACK_MESSAGE = "No pude responder ahora. Probá de nuevo en un rato."

// ─── Modelo por variable con allow-list (D8) ──────────────────────────────────

/**
 * Task 0 corrida por el PO con la clave real (2026-11-06, `scripts/ai/verify-copilot-models.ts`):
 * `gpt-6.1-terra` y `gpt-6-luna` existen pero RECHAZAN las herramientas en /v1/chat/completions
 * («Function tools with reasoning_effort are not supported for gpt-6.1-terra in
 * /v1/chat/completions»), aun sin mandar `reasoning_effort`. Con herramientas sirven `gpt-5-mini`
 * (razonamiento, ~2,7 s), `gpt-4.1-mini` (~0,6 s) y `gpt-4o-mini` (~0,7 s). La familia 6 queda
 * fuera hasta migrar la función a la Responses API (candidato `copilot-responses-api`).
 */
export const COPILOT_ALLOWED_MODELS: readonly string[] = [
  "gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini",
]
export const COPILOT_DEFAULT_MODEL = "gpt-5-mini"
/**
 * Cadena de salto cuando OpenAI contesta que el modelo no existe o no sirve con herramientas: el
 * resuelto primero y después el resto de la allow-list en este orden. `gpt-4o-mini` es el último
 * recurso: es el que ya usan las demás funciones de IA.
 */
export const COPILOT_FALLBACK_ORDER: readonly string[] = [
  "gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini",
]

export interface ModelResolution {
  model: string
  warning?: string
}

/** `COPILOT_AI_MODEL` contra la allow-list. Ausente = default sin ruido; fuera de la lista = default + advertencia. */
export function resolveCopilotModel(envValue: string | null | undefined): ModelResolution {
  const value = typeof envValue === "string" ? envValue.trim() : ""
  if (!value) return { model: COPILOT_DEFAULT_MODEL }
  if (COPILOT_ALLOWED_MODELS.includes(value)) return { model: value }
  return {
    model: COPILOT_DEFAULT_MODEL,
    warning: `COPILOT_AI_MODEL=${JSON.stringify(value)} fuera de la allow-list (${COPILOT_ALLOWED_MODELS.join(", ")}); se usa ${COPILOT_DEFAULT_MODEL}`,
  }
}

/** La cadena de modelos a probar: el resuelto y después el resto de COPILOT_FALLBACK_ORDER. */
export function modelCandidates(resolved: string): string[] {
  return [resolved, ...COPILOT_FALLBACK_ORDER.filter((m) => m !== resolved)]
}

export interface ModelParams {
  /** Parámetro del tope de salida que acepta el modelo. */
  outputParam: "max_completion_tokens" | "max_tokens"
  /** `null` = el modelo no acepta `temperature` (sólo el valor por defecto). */
  temperature: number | null
  /** El modelo acepta `response_format: json_schema` estricto junto con `tools`. */
  useJsonSchema: boolean
  /** Parámetros extra del modelo (p. ej. `reasoning_effort`). */
  extra: Record<string, unknown>
}

const CLASSIC: ModelParams = { outputParam: "max_tokens", temperature: 0.2, useJsonSchema: true, extra: {} }
const REASONING: ModelParams = { outputParam: "max_completion_tokens", temperature: null, useJsonSchema: true, extra: {} }

/**
 * Parámetros por modelo. Los modelos clásicos (`gpt-4o-mini`, `gpt-4.1-mini`) aceptan `max_tokens` y
 * `temperature`; la familia de razonamiento (`gpt-5-*`, `gpt-6-*`) sólo `max_completion_tokens` y no
 * `temperature`. La task 0 (verificación con la clave real) confirma o corrige esta tabla; mientras
 * tanto `adaptParamsFromError` corrige en caliente un 400 de parámetro y lo recuerda.
 */
export const COPILOT_MODEL_PARAMS: Record<string, ModelParams> = {
  "gpt-4o-mini": CLASSIC,
  "gpt-4.1-mini": CLASSIC,
  "gpt-5-mini": { ...REASONING, extra: { reasoning_effort: "minimal" } },
}

// ─── Tipos de la conversación con el modelo ───────────────────────────────────

export interface ToolCall {
  id: string
  type: "function"
  function: { name: string; arguments: string }
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool"
  content: string | null
  tool_calls?: ToolCall[]
  tool_call_id?: string
}

export interface ModelRequest {
  messages: ChatMessage[]
  /** `null` = llamada final: el modelo debe responder con lo que hay. */
  tools: readonly CopilotToolDefinition[] | null
  /** Pide la respuesta final como `json_schema` estricto. */
  jsonSchema: boolean
  timeoutMs: number
}

export interface ModelUsage {
  prompt_tokens: number
  completion_tokens: number
}

/** Resultado crudo de una llamada HTTP al proveedor (antes de saber qué modelo respondió). */
export type SendResult =
  | { kind: "ok"; message: { content: string | null; tool_calls?: ToolCall[] }; usage?: ModelUsage }
  | { kind: "timeout" }
  | { kind: "http_error"; status: number; message: string }
  | { kind: "error"; message: string }

export type ModelResult =
  | { kind: "ok"; model: string; message: { content: string | null; tool_calls?: ToolCall[] }; usage?: ModelUsage }
  | { kind: "timeout" }
  | { kind: "http_error"; status: number; message: string }
  | { kind: "error"; message: string }

/** Cuerpo del request a /v1/chat/completions para un modelo con sus parámetros. */
export function buildOpenAiBody(model: string, req: ModelRequest, params: ModelParams): Record<string, unknown> {
  const body: Record<string, unknown> = { model, messages: req.messages, [params.outputParam]: MAX_OUTPUT_TOKENS }
  if (params.temperature !== null) body.temperature = params.temperature
  for (const [k, v] of Object.entries(params.extra)) body[k] = v
  if (req.tools && req.tools.length > 0) {
    body.tools = req.tools
    body.tool_choice = "auto"
    body.parallel_tool_calls = true
  }
  if (req.jsonSchema && params.useJsonSchema) body.response_format = COPILOT_RESPONSE_SCHEMA
  return body
}

/**
 * ¿OpenAI dice que el modelo no existe (o no hay acceso), o que NO sirve con herramientas en este
 * endpoint («Function tools … are not supported for <modelo> in /v1/chat/completions», task 0)?
 * En los dos casos el modelo es inutilizable para el Copilot: se salta al siguiente. Los demás
 * 400/404 (un parámetro rechazado) NO cuentan: los corrige `adaptParamsFromError`.
 */
export function isUnknownModelError(status: number, message: string): boolean {
  if (status !== 404 && status !== 400) return false
  if (/model_not_found|invalid model|unknown model|no such model|model[\s\S]{0,80}(does not exist|not found|do not have access|decommissioned|deprecated)/i.test(message)) return true
  return /(function )?tools?[\s\S]{0,80}(not supported|unsupported)[\s\S]{0,80}(for|with) (this model|[\w.-]+ in \/v1\/)/i.test(message)
}

/**
 * Corrige los parámetros ante un 400 que se queja de un parámetro (el modelo no acepta `max_tokens`,
 * `temperature`, `response_format` o `reasoning_effort`). `null` si no entiende el error.
 */
export function adaptParamsFromError(status: number, message: string, params: ModelParams): ModelParams | null {
  if (status !== 400) return null
  const m = message.toLowerCase()
  const next: ModelParams = { ...params, extra: { ...params.extra } }
  let changed = false
  if (params.outputParam === "max_tokens" && m.includes("max_tokens") && /unsupported|not supported|max_completion_tokens/.test(m)) {
    next.outputParam = "max_completion_tokens"
    changed = true
  } else if (params.outputParam === "max_completion_tokens" && m.includes("max_completion_tokens") && /unsupported|not supported/.test(m)) {
    next.outputParam = "max_tokens"
    changed = true
  }
  if (params.temperature !== null && m.includes("temperature")) {
    next.temperature = null
    changed = true
  }
  if (params.useJsonSchema && /response_format|json_schema/.test(m)) {
    next.useJsonSchema = false
    changed = true
  }
  if ("reasoning_effort" in params.extra && m.includes("reasoning_effort")) {
    delete next.extra.reasoning_effort
    changed = true
  }
  return changed ? next : null
}

export interface ModelFailoverOptions {
  candidates: readonly string[]
  send: (model: string, body: Record<string, unknown>, timeoutMs: number) => Promise<SendResult>
  log: (level: "info" | "warn" | "error", message: string) => void
}

/**
 * Llamada al modelo con salto automático: si OpenAI dice que el modelo no existe pasa al siguiente de
 * la lista (y se queda en el que funcionó mientras viva el aislado); si un 400 se queja de un
 * parámetro, corrige y reintenta con el MISMO modelo (hasta 2 veces) y lo recuerda. Cualquier otro
 * error (500, timeout, red) NO salta de modelo.
 */
export function createModelFailover(opts: ModelFailoverOptions): (req: ModelRequest) => Promise<ModelResult> {
  let idx = 0
  const paramsByModel: Record<string, ModelParams> = {}

  return async (req) => {
    let last: ModelResult = { kind: "error", message: "sin modelos candidatos" }
    while (idx < opts.candidates.length) {
      const model = opts.candidates[idx]
      let attempts = 0
      let jumped = false
      while (true) {
        const params = paramsByModel[model] ?? COPILOT_MODEL_PARAMS[model] ?? CLASSIC
        const res = await opts.send(model, buildOpenAiBody(model, req, params), req.timeoutMs)
        if (res.kind === "ok") return { ...res, model }
        if (res.kind === "http_error") {
          if (isUnknownModelError(res.status, res.message)) {
            const next = opts.candidates[idx + 1]
            opts.log("warn", `[ai-copilot] el modelo ${model} no existe para esta clave o no sirve con herramientas (${res.status}); salto a ${next ?? "(ninguno)"}: ${res.message.slice(0, 120)}`)
            last = res
            idx++
            jumped = true
            break
          }
          const adapted = attempts < 2 ? adaptParamsFromError(res.status, res.message, params) : null
          if (adapted) {
            opts.log("warn", `[ai-copilot] el modelo ${model} rechazó un parámetro (${res.status}); reintento corrigiendo: ${res.message.slice(0, 160)}`)
            paramsByModel[model] = adapted
            attempts++
            continue
          }
        }
        return res
      }
      if (!jumped) break
    }
    idx = 0 // todos desconocidos: el próximo pedido vuelve a empezar por el primero
    return last
  }
}

/** Rechaza si `promise` no resuelve en `ms` (RPC de herramienta: 8 s). */
export function withTimeout<T>(promise: PromiseLike<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label}: timeout de ${ms} ms`)), ms)
    Promise.resolve(promise).then(
      (v) => { clearTimeout(timer); resolve(v) },
      (e) => { clearTimeout(timer); reject(e) },
    )
  })
}

// ─── Dependencias y resultado del turno ───────────────────────────────────────

export type Outcome = "answer" | "clarification" | "fallback" | "error"

export interface ToolUsed {
  name: string
  ok: boolean
  rows: number
  ms: number
}

export interface CopilotTurnRecord {
  question: string
  answer: string
  model: string | null
  tools_used: ToolUsed[]
  latency_ms: number
  prompt_tokens: number
  completion_tokens: number
  outcome: Outcome
  thread_id: string | null
}

export interface CopilotDeps {
  accountId: string
  now: () => Date
  nowMs: () => number
  /** `rpc_reserve_ai_usage('queries')` con el cliente del usuario. */
  reserve: () => Promise<AiReservationResult>
  callModel: (req: ModelRequest) => Promise<ModelResult>
  executeTool: (name: string, args: unknown) => Promise<ToolOutcome>
  /** Inserta en `ai_conversations` (con `account_id`) y devuelve el id; `null` o una excepción = no se pudo. */
  record: (row: CopilotTurnRecord) => Promise<string | null>
  log: (level: "info" | "warn" | "error", message: string) => void
}

export interface CopilotResponse {
  status: number
  body: Record<string, unknown>
  /** Valor del header `Retry-After` (sólo en 429 por ráfaga). */
  retryAfterSeconds?: number
}

// ─── Validación del cuerpo ────────────────────────────────────────────────────

interface ParsedRequest {
  question: string
  history: HistoryMessage[]
  state: CopilotState
  threadId: string | null
}

type ParseResult = { ok: true; value: ParsedRequest } | { ok: false; message: string }

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}

export function parseCopilotRequest(raw: unknown): ParseResult {
  if (!isRecord(raw)) return { ok: false, message: "El cuerpo debe ser un objeto JSON" }
  const question = typeof raw.question === "string" ? raw.question.trim() : ""
  if (question.length === 0) return { ok: false, message: "question es obligatoria" }
  if (question.length > MAX_QUESTION_LENGTH) return { ok: false, message: `question no puede superar ${MAX_QUESTION_LENGTH} caracteres` }

  const history: HistoryMessage[] = []
  if (raw.history !== undefined && raw.history !== null) {
    if (!Array.isArray(raw.history)) return { ok: false, message: "history debe ser un arreglo" }
    if (raw.history.length > MAX_HISTORY_MESSAGES) return { ok: false, message: `history no puede superar ${MAX_HISTORY_MESSAGES} mensajes` }
    for (const item of raw.history) {
      if (!isRecord(item) || (item.role !== "user" && item.role !== "assistant")) {
        return { ok: false, message: "cada mensaje de history necesita role user o assistant" }
      }
      if (typeof item.content !== "string" || item.content.trim().length === 0) {
        return { ok: false, message: "cada mensaje de history necesita content" }
      }
      if (item.content.length > MAX_HISTORY_MESSAGE_LENGTH) {
        return { ok: false, message: `un mensaje de history supera ${MAX_HISTORY_MESSAGE_LENGTH} caracteres` }
      }
      const consulted = Array.isArray(item.consulted)
        ? item.consulted.filter((c): c is string => typeof c === "string" && c.length > 0 && c.length <= 200).slice(0, 8)
        : undefined
      history.push({ role: item.role, content: item.content, ...(consulted && consulted.length > 0 ? { consulted } : {}) })
    }
  }

  let threadId: string | null = null
  if (raw.thread_id !== undefined && raw.thread_id !== null) {
    if (!isUuid(raw.thread_id)) return { ok: false, message: "thread_id debe ser un uuid" }
    threadId = raw.thread_id
  }

  return { ok: true, value: { question, history, state: validateCopilotState(raw.state), threadId } }
}

// ─── Respuesta final ──────────────────────────────────────────────────────────

interface FinalAnswer {
  kind: "answer" | "clarification"
  answer: string
  modelState: CopilotState
}

function parseFinalContent(content: string): FinalAnswer | null {
  const text = content.trim()
  if (text.length === 0) return null
  try {
    const parsed: unknown = JSON.parse(text)
    if (isRecord(parsed) && typeof parsed.answer === "string" && parsed.answer.trim().length > 0) {
      const kind = parsed.kind === "clarification" ? "clarification" : "answer"
      return { kind, answer: parsed.answer.trim(), modelState: validateCopilotState(parsed.state) }
    }
  } catch { /* texto libre */ }
  return { kind: "answer", answer: text, modelState: { ...EMPTY_STATE } }
}

const hasAny = (s: CopilotState): boolean => s.period !== null || s.product !== null || s.client !== null

/** D7: lo que el modelo devuelva y sea válido; lo que falte, del foco de las herramientas y del estado previo. */
function mergeState(model: CopilotState, derived: CopilotState): CopilotState {
  if (!hasAny(model)) return derived
  return {
    period: model.period ?? derived.period,
    product: model.product ?? derived.product,
    client: model.client ?? derived.client,
  }
}

function applyFocus(base: CopilotState, focus: Partial<FocusState>): CopilotState {
  return {
    period: focus.period ?? base.period,
    product: focus.product ?? base.product,
    client: focus.client ?? base.client,
  }
}

function parseArgs(raw: string): { ok: true; value: unknown } | { ok: false } {
  if (raw.trim().length === 0) return { ok: true, value: {} }
  try {
    return { ok: true, value: JSON.parse(raw) as unknown }
  } catch {
    return { ok: false }
  }
}

function toolMessage(callId: string, result: Record<string, unknown>): ChatMessage {
  let content = JSON.stringify(result)
  if (content.length > MAX_TOOL_RESULT_CHARS) content = JSON.stringify({ error: "resultado_demasiado_grande" })
  return { role: "tool", tool_call_id: callId, content }
}

// ─── El turno ─────────────────────────────────────────────────────────────────

export async function runCopilotTurn(deps: CopilotDeps, rawBody: unknown): Promise<CopilotResponse> {
  // 1. Validar (400 antes de gastar cuota).
  const parsed = parseCopilotRequest(rawBody)
  if (!parsed.ok) return { status: 400, body: { ok: false, error: "invalid_params", message: parsed.message } }
  const { question, history, state: priorState, threadId } = parsed.value

  // 2. Reservar UNA unidad de cuota, antes de leer nada o llamar al modelo.
  const reservation = await deps.reserve()
  if (reservation.kind === "denied") {
    return { status: reservation.status, body: reservation.body, retryAfterSeconds: reservation.retryAfterSeconds }
  }
  if (reservation.kind === "unavailable") return { status: reservation.status, body: reservation.body }

  // 3. Mensajes: system (fecha de hoy + foco), memoria corta recortada, pregunta.
  const startMs = deps.nowMs()
  const messages: ChatMessage[] = [
    { role: "system", content: buildSystemPrompt({ now: deps.now(), state: priorState }) },
    ...fitHistory(history).map((m): ChatMessage => ({ role: m.role, content: m.content })),
    { role: "user", content: question },
  ]

  const toolsUsed: ToolUsed[] = []
  const consulted: ConsultedItem[] = []
  let derived: CopilotState = { ...priorState }
  let rounds = 0
  let calls = 0
  let promptTokens = 0
  let completionTokens = 0
  let model: string | null = null

  const finish = async (
    outcome: Outcome,
    answer: string,
    response: (conversationId: string | null) => CopilotResponse,
  ): Promise<CopilotResponse> => {
    let id: string | null = null
    try {
      id = await deps.record({
        question, answer, model, tools_used: toolsUsed, latency_ms: Math.max(1, deps.nowMs() - startMs),
        prompt_tokens: promptTokens, completion_tokens: completionTokens, outcome, thread_id: threadId,
      })
      if (id === null) deps.log("error", "[ai-copilot] no se pudo registrar la conversación (sin id)")
    } catch (err) {
      deps.log("error", `[ai-copilot] no se pudo registrar la conversación: ${err instanceof Error ? err.message : String(err)}`)
    }
    return response(id)
  }

  const fallback = () =>
    finish("fallback", COPILOT_FALLBACK_MESSAGE, (id) => ({
      status: 200,
      body: { ok: true, kind: "fallback", answer: COPILOT_FALLBACK_MESSAGE, conversation_id: id },
    }))

  // 4. Bucle de herramientas.
  while (true) {
    const remaining = TURN_TIMEOUT_MS - (deps.nowMs() - startMs)
    if (remaining <= 0) {
      deps.log("warn", "[ai-copilot] tiempo total del turno vencido")
      return fallback()
    }
    const finalCall = rounds >= MAX_TOOL_ROUNDS || calls >= MAX_TOOL_CALLS
    const result = await deps.callModel({
      messages,
      tools: finalCall ? null : COPILOT_TOOLS,
      jsonSchema: true,
      timeoutMs: Math.min(MODEL_CALL_TIMEOUT_MS, remaining),
    })

    if (result.kind === "timeout") {
      deps.log("warn", "[ai-copilot] timeout de la llamada al modelo")
      return fallback()
    }
    if (result.kind === "http_error" || result.kind === "error") {
      const detail = result.kind === "http_error" ? `HTTP ${result.status}: ${result.message}` : result.message
      deps.log("error", `[ai-copilot] error del proveedor: ${detail}`)
      return finish("error", "", () => ({ status: 502, body: { ok: false, error: "ai_unavailable" } }))
    }

    model = result.model
    if (result.usage) {
      promptTokens += result.usage.prompt_tokens
      completionTokens += result.usage.completion_tokens
    }
    const toolCalls = result.message.tool_calls ?? []

    if (toolCalls.length === 0) {
      const final = parseFinalContent(result.message.content ?? "")
      if (!final) {
        deps.log("warn", "[ai-copilot] respuesta vacía del modelo")
        return fallback()
      }
      const state = mergeState(final.modelState, derived)
      return finish(final.kind, final.answer, (id) => ({
        status: 200,
        body: { ok: true, kind: final.kind, answer: final.answer, conversation_id: id, consulted, state },
      }))
    }

    if (finalCall) {
      // Pidió herramientas aunque no se le ofrecieron: no hay respuesta que dar.
      deps.log("warn", "[ai-copilot] el modelo siguió pidiendo herramientas en la llamada final")
      return fallback()
    }

    // Ronda con herramientas: el mensaje del asistente y un mensaje `tool` por cada llamada.
    messages.push({ role: "assistant", content: result.message.content ?? null, tool_calls: toolCalls })
    const allowed = Math.max(0, MAX_TOOL_CALLS - calls)
    const toRun = toolCalls.slice(0, allowed)
    const overflow = toolCalls.slice(allowed)
    calls += toRun.length
    rounds++

    const outcomes = await Promise.all(toRun.map(async (call) => {
      const t0 = deps.nowMs()
      const args = parseArgs(call.function.arguments)
      let out: ToolOutcome
      if (!args.ok) {
        out = { result: { error: "argumento_invalido", detalle: "los argumentos no son un JSON válido" }, ok: false, rows: 0, consulted: null, focus: {} }
      } else {
        try {
          out = await deps.executeTool(call.function.name, args.value)
        } catch (err) {
          deps.log("error", `[ai-copilot] la herramienta ${call.function.name} lanzó: ${err instanceof Error ? err.message : String(err)}`)
          out = { result: { error: "no_disponible" }, ok: false, rows: 0, consulted: null, focus: {} }
        }
      }
      if (!out.ok && out.result.error === "no_disponible") {
        deps.log("warn", `[ai-copilot] la herramienta ${call.function.name} no estuvo disponible`)
      }
      return { call, out, ms: Math.max(0, deps.nowMs() - t0) }
    }))

    for (const { call, out, ms } of outcomes) {
      toolsUsed.push({ name: call.function.name, ok: out.ok, rows: out.rows, ms })
      if (out.consulted && !consulted.some((c) => c.label === out.consulted?.label)) consulted.push(out.consulted)
      derived = applyFocus(derived, out.focus)
      messages.push(toolMessage(call.id, out.result))
    }
    for (const call of overflow) {
      messages.push(toolMessage(call.id, { error: "tope_de_llamadas" }))
    }
  }
}
