// ai-rentabilidad — análisis de margen por producto (C-11 rentabilidad).
//
// Auth con el JWT del usuario, checkAiQuota ANTES de OpenAI, gpt-4o-mini con
// timeout de 25 s y fallback, persistencia en `insights`, incrementAiUsage
// DESPUÉS y sólo si el insight se generó Y se persistió.
//
// Toda la decisión vive en _shared/ai-rentabilidad-core.ts (puro, testeado
// desde vitest — frontend/__tests__/ai-rentabilidad.test.ts); este archivo
// sólo cablea las dependencias reales. La orquestación (cuota → contexto →
// modelo → persistir → cobrar) es la misma que usa ai-estadisticas, vía
// `_shared/ai-insight-core.ts` (candidato "alinear ai-rentabilidad con
// ai-estadisticas", CLAUDE.md) — antes de este cambio se cobraba cuota
// aunque el insight viniera vacío o la persistencia fallara en silencio.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage, type AiQuotaClient } from '../_shared/ai-quota.ts'
import {
  RENTABILIDAD_INSIGHT_TYPE,
  runRentabilidadAnalysis,
  type ModelOutcome,
  type ProfitabilityRow,
  type RentabilidadContext,
} from '../_shared/ai-rentabilidad-core.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const AI_TIMEOUT_MS = 25_000

// ─── Helpers ──────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

function extractErrorMessage(err: unknown): string {
  if (typeof err === 'string') return err
  if (err && typeof err === 'object') {
    const e = err as Record<string, unknown>
    if (typeof e['message'] === 'string') return e['message']
    if (typeof e['details'] === 'string') return e['details']
    if (typeof e['code']    === 'string') return `DB error: ${e['code']}`
  }
  return 'Unknown error'
}

async function fetchWithTimeout(url: string, options: RequestInit, retries = 2): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), AI_TIMEOUT_MS)
  try {
    const res = await fetch(url, { ...options, signal: controller.signal })
    clearTimeout(timer)
    return res
  } catch (err: unknown) {
    clearTimeout(timer)
    const isAbort = err instanceof DOMException && err.name === 'AbortError'
    if (retries > 0 && !isAbort) {
      console.warn('[ai-rentabilidad] Retry, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[ai-rentabilidad] Request received')

  try {
    // 1. Auth
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      console.error('[ai-rentabilidad] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY' }, 500)
    }

    // 2. Parse period_days from body
    let periodDays = 30
    try {
      const body = await req.json()
      if (typeof body?.period_days === 'number' && body.period_days > 0) {
        periodDays = Math.min(body.period_days, 365)
      }
    } catch (_) { /* use default */ }

    // 3. Orquestación pura (cuota → contexto → modelo → persistir → cobrar).
    const result = await runRentabilidadAnalysis({
      // Cast acotado (no `any`): `AiQuotaClient` restates 5 overloaded members,
      // lo que dispara TS2589 al compararlo contra el `SupabaseClient` real
      // (mismo patrón que ai-insights/ai-resumen/ai-precio/ai-comparativo/
      // ai-prediccion/ai-simulador/fair-advisor).
      checkQuota: () => checkAiQuota(supabase as unknown as AiQuotaClient, user.id, 'queries'),

      fetchContext: async (): Promise<RentabilidadContext> => {
        const { data: products, error: rpcErr } = await supabase.rpc('rpc_product_profitability', {
          p_period_days: periodDays,
        })
        if (rpcErr) throw new Error(rpcErr.message)
        const rows = (products ?? []) as ProfitabilityRow[]
        console.log('[ai-rentabilidad] Data:', rows.length, 'products')
        return { periodDays, rows }
      },

      callModel: async (prompt: string): Promise<ModelOutcome> => {
        try {
          const response = await fetchWithTimeout(
            'https://api.openai.com/v1/chat/completions',
            {
              method: 'POST',
              headers: {
                'Authorization': `Bearer ${openAiKey}`,
                'Content-Type': 'application/json',
              },
              body: JSON.stringify({
                model: 'gpt-4o-mini',
                messages: [
                  {
                    role: 'system',
                    content: 'Sos un consultor de negocios para emprendedores argentinos. Usá el español rioplatense. Sé directo y accionable. Siempre citá números reales del contexto.',
                  },
                  { role: 'user', content: prompt },
                ],
                response_format: { type: 'json_object' },
                max_tokens: 500,
                temperature: 0.3,
              }),
            }
          )

          console.log('[ai-rentabilidad] OpenAI status:', response.status)

          if (!response.ok) {
            const errRaw = await response.text().catch(() => '')
            console.error('[ai-rentabilidad] OpenAI error:', errRaw)
            let message = errRaw
            try {
              const parsed = JSON.parse(errRaw) as { error?: { message?: string } }
              message = parsed?.error?.message || errRaw
            } catch { /* texto crudo */ }
            return { kind: 'http_error', status: response.status, message }
          }

          const aiData = await response.json() as { choices?: Array<{ message?: { content?: string } }> }
          return { kind: 'ok', content: aiData?.choices?.[0]?.message?.content ?? '' }
        } catch (aiErr: unknown) {
          const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
          console.error('[ai-rentabilidad] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
          return isTimeout ? { kind: 'timeout' } : { kind: 'error', message: extractErrorMessage(aiErr) }
        }
      },

      persistInsight: async (insight: string) => {
        const { error: insertErr } = await supabase.from('insights').insert({
          user_id:  user.id,
          type:     RENTABILIDAD_INSIGHT_TYPE,
          priority: 'alta',
          message:  insight,
        })
        if (insertErr) {
          console.error('[ai-rentabilidad] DB insert error:', extractErrorMessage(insertErr))
          throw new Error(extractErrorMessage(insertErr))
        }
      },

      // Mismo cast acotado que `checkQuota` arriba (ver comentario).
      incrementUsage: () => incrementAiUsage(supabase as unknown as AiQuotaClient, user.id, 'queries'),
    })

    console.log('[ai-rentabilidad] Done:', result.status)
    return jsonResponse(result.body, result.status)

  } catch (err: unknown) {
    console.error('[ai-rentabilidad] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
