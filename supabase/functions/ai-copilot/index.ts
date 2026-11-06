// ai-copilot — ia-copilot-v2 (tanda A).
//
// El Copiloto conversacional de SÓLO LECTURA (DEC-15: la IA vive en Edge Functions). Reemplaza a
// la ruta de Next `POST /api/ai/copilot`. Molde de ai-estadisticas: este archivo sólo cablea las
// dependencias reales; TODA la decisión (validar → reservar cuota → herramientas → modelo →
// registrar, topes, respuestas cerradas) vive en _shared/ai-copilot-core.ts, el catálogo de
// herramientas en _shared/ai-copilot-tools.ts y el prompt en _shared/ai-copilot-prompt.ts,
// todos puros y testeados desde vitest.
//
// Invariantes de este archivo:
//   - El cliente de Supabase se construye con la anon key + el `Authorization` del request: TODO
//     corre con el JWT del usuario (RLS y guards de membresía de las RPCs); NUNCA service role.
//   - La cuenta sale de `current_account_ids()` (resolveActiveAccountId), nunca del body.
//   - El texto de error del proveedor no sale de acá: se loguea con el prefijo [ai-copilot].
//   - Ningún camino escribe datos del negocio; la única escritura es el registro del turno.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { reserveAiUsage, type AiQuotaClient } from '../_shared/ai-quota.ts'
import { resolveActiveAccountId, type AccountResolutionClient } from '../_shared/reporting-canon.ts'
import {
  MODEL_CALL_TIMEOUT_MS,
  RPC_TIMEOUT_MS,
  createModelFailover,
  modelCandidates,
  resolveCopilotModel,
  runCopilotTurn,
  withTimeout,
  type CopilotDeps,
  type CopilotTurnRecord,
  type SendResult,
  type ToolCall,
} from '../_shared/ai-copilot-core.ts'
import { executeCopilotTool, type ToolDeps, type ToolRpcResult } from '../_shared/ai-copilot-tools.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json', ...extra },
    status,
  })
}

function log(level: 'info' | 'warn' | 'error', message: string) {
  const line = message.startsWith('[ai-copilot]') ? message : `[ai-copilot] ${message}`
  if (level === 'error') console.error(line)
  else if (level === 'warn') console.warn(line)
  else console.log(line)
}

interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }>
}

interface OpenAiChoiceMessage {
  content?: string | null
  tool_calls?: ToolCall[]
}

interface OpenAiResponse {
  choices?: Array<{ message?: OpenAiChoiceMessage }>
  usage?: { prompt_tokens?: number; completion_tokens?: number }
}

/** Una llamada HTTP a /v1/chat/completions, traducida a un resultado cerrado (sin throws). */
async function sendToOpenAi(apiKey: string, model: string, body: Record<string, unknown>, timeoutMs: number): Promise<SendResult> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), Math.min(timeoutMs, MODEL_CALL_TIMEOUT_MS))
  try {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
    if (!res.ok) {
      const raw = await res.text().catch(() => '')
      let message = raw
      try {
        const parsed = JSON.parse(raw) as { error?: { message?: string } }
        message = parsed?.error?.message || raw
      } catch { /* texto crudo */ }
      return { kind: 'http_error', status: res.status, message }
    }
    const data = await res.json() as OpenAiResponse
    const message = data.choices?.[0]?.message
    if (!message) return { kind: 'error', message: `respuesta sin choices (${model})` }
    return {
      kind: 'ok',
      message: { content: message.content ?? null, tool_calls: message.tool_calls },
      usage: data.usage && typeof data.usage.prompt_tokens === 'number' && typeof data.usage.completion_tokens === 'number'
        ? { prompt_tokens: data.usage.prompt_tokens, completion_tokens: data.usage.completion_tokens }
        : undefined,
    }
  } catch (err: unknown) {
    if (err instanceof DOMException && err.name === 'AbortError') return { kind: 'timeout' }
    return { kind: 'error', message: err instanceof Error ? err.message : String(err) }
  } finally {
    clearTimeout(timer)
  }
}

// ─── Modelo: allow-list + salto automático (se resuelve una vez por aislado) ──

const modelResolution = resolveCopilotModel(Deno.env.get('COPILOT_AI_MODEL'))
if (modelResolution.warning) log('warn', modelResolution.warning)

let failover: ReturnType<typeof createModelFailover> | null = null
function getFailover(apiKey: string) {
  if (!failover) {
    failover = createModelFailover({
      candidates: modelCandidates(modelResolution.model),
      send: (model, body, timeoutMs) => sendToOpenAi(apiKey, model, body, timeoutMs),
      log,
    })
  }
  return failover
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ ok: false, error: 'invalid_params', message: 'Método no permitido' }, 405)

  try {
    // 1. Auth con el JWT del usuario (sin service role).
    const authorization = req.headers.get('Authorization')
    if (!authorization) return jsonResponse({ ok: false, error: 'unauthorized' }, 401)
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authorization } } },
    )
    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) return jsonResponse({ ok: false, error: 'unauthorized' }, 401)

    // Sin clave del proveedor no se gasta cuota: es una falla de configuración, no del usuario.
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      log('error', 'falta OPENAI_API_KEY')
      return jsonResponse({ ok: false, error: 'ai_unavailable' }, 502)
    }

    // 2. Cuenta activa: la RPC canónica con el JWT del usuario. Nunca del body ni del modelo.
    const accountId = await resolveActiveAccountId(supabase as unknown as AccountResolutionClient)
    if (!accountId) return jsonResponse({ ok: false, error: 'no_active_account' }, 403)

    const rpcClient = supabase as unknown as RpcClient

    // 3. Dependencias reales del núcleo.
    const toolDeps: ToolDeps = {
      accountId,
      now: new Date(),
      rpc: async (fn, args): Promise<ToolRpcResult> => {
        const res = await withTimeout(rpcClient.rpc(fn, args), RPC_TIMEOUT_MS, fn)
        if (res.error) log('warn', `la RPC ${fn} falló: ${res.error.code ?? ''} ${res.error.message}`)
        return res
      },
      searchProducts: async (acc, text, limit): Promise<ToolRpcResult> => {
        // Filtro EXPLÍCITO por cuenta y sin borrados (la RLS es la red, no el único guard). El texto
        // ya viene limpio de comodines y separadores (sanitizeSearchText).
        const query = supabase
          .from('products')
          .select('id, name, sku')
          .eq('account_id', acc)
          .is('deleted_at', null)
          .or(`name.ilike.%${text}%,sku.ilike.%${text}%`)
          .order('name')
          .limit(limit)
        const res = await withTimeout(query, RPC_TIMEOUT_MS, 'products')
        if (res.error) log('warn', `la búsqueda de productos falló: ${res.error.code ?? ''} ${res.error.message}`)
        return { data: res.data, error: res.error ? { message: res.error.message, code: res.error.code } : null }
      },
    }

    const deps: CopilotDeps = {
      accountId,
      now: () => new Date(),
      nowMs: () => Date.now(),
      // Cast acotado (no `any`): `AiQuotaClient` restates varios miembros sobrecargados y dispara
      // TS2589 al compararlo con el SupabaseClient real (mismo patrón que ai-estadisticas).
      reserve: () => reserveAiUsage(supabase as unknown as AiQuotaClient, 'queries'),
      callModel: (r) => getFailover(openAiKey)(r),
      executeTool: (name, args) => executeCopilotTool({ ...toolDeps, now: new Date() }, name, args),
      record: async (row: CopilotTurnRecord) => {
        // Se ESPERA el insert (no un .catch silencioso): el conversation_id lo necesita la valoración.
        // Con account_id: la policy de INSERT exige `account_id IN current_account_ids()`; el guardado
        // viejo lo omitía y la RLS lo rechazaba en silencio.
        const { data, error } = await supabase
          .from('ai_conversations')
          .insert({
            user_id: user.id,
            account_id: accountId,
            question: row.question,
            answer: row.answer,
            model: row.model,
            tools_used: row.tools_used,
            latency_ms: row.latency_ms,
            prompt_tokens: row.prompt_tokens,
            completion_tokens: row.completion_tokens,
            outcome: row.outcome,
            thread_id: row.thread_id,
          })
          .select('id')
          .single()
        if (error) throw new Error(error.message)
        return (data as { id: string } | null)?.id ?? null
      },
      log,
    }

    // 4. El turno.
    const body: unknown = await req.json().catch(() => null)
    const result = await runCopilotTurn(deps, body)
    const extra: Record<string, string> = {}
    if (result.retryAfterSeconds !== undefined) extra['Retry-After'] = String(result.retryAfterSeconds)
    return jsonResponse(result.body, result.status, extra)
  } catch (err: unknown) {
    log('error', `error no controlado: ${err instanceof Error ? err.message : String(err)}`)
    return jsonResponse({ ok: false, error: 'ai_unavailable' }, 502)
  }
})
