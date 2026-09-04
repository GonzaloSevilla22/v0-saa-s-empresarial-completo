// ai-estadisticas — estadisticas-ventas E3 (grupo 10, tasks 10.1-10.4).
//
// Análisis en lenguaje natural de las estadísticas de ventas del período.
// Molde de ai-rentabilidad (DEC-15: la IA vive en Edge Functions, no en
// Python): auth con el JWT del usuario, checkAiQuota ANTES de OpenAI,
// gpt-4o-mini con timeout de 25 s y fallback, persistencia en `insights`,
// incrementAiUsage DESPUÉS y sólo si el insight se generó.
//
// Toda la decisión vive en _shared/ai-estadisticas-core.ts (puro, testeado
// desde vitest); este archivo sólo cablea las dependencias reales. Las
// cifras del prompt salen de los read-models canónicos del módulo leídos con
// el JWT del usuario — rpc_sales_evolution / rpc_product_ranking /
// rpc_sales_breakdown / rpc_sales_top_clients, que ya aplican el guard de
// membresía (P0401) y el clamp de historial por plan (D8) — NUNCA de una
// agregación escrita acá (reporting-invariants, "Enforcement de consumo").

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage } from '../_shared/ai-quota.ts'
import { parseBusinessDateRange, parseOptionalUuid } from '../_shared/statistics-params.ts'
import {
  ESTADISTICAS_INSIGHT_TYPE,
  runEstadisticasAnalysis,
  type BreakdownRow,
  type EstadisticasContext,
  type EvolutionRow,
  type ModelOutcome,
  type RankingRow,
  type TopClientRow,
} from '../_shared/ai-estadisticas-core.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const AI_TIMEOUT_MS = 25_000
const RANKING_TOP = 5
const CLIENTS_TOP = 5

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
    if (typeof e['code'] === 'string') return `DB error: ${e['code']}`
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
      console.warn('[ai-estadisticas] Retry, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[ai-estadisticas] Request received')

  try {
    // 1. Auth
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      console.error('[ai-estadisticas] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY' }, 500)
    }

    // 2. Parámetros: el período y la sucursal de la pantalla (mismos
    //    defaults que /estadisticas). Fuera de dominio → 400, antes de la cuota.
    const body: Record<string, unknown> = await req.json().catch(() => ({}))
    const range = parseBusinessDateRange(body, new Date())
    if (!range.ok) return jsonResponse({ ok: false, error: 'invalid_params', message: range.error }, 400)
    const branch = parseOptionalUuid(body, 'branch_id')
    if (!branch.ok) return jsonResponse({ ok: false, error: 'invalid_params', message: branch.error }, 400)
    const { start, end } = range.value
    const branchId = branch.value

    // 3. Cuenta activa — mismo criterio determinístico que
    //    backend/core/deps.py:get_account_id (membresía más antigua, por id).
    //    Las RPCs vuelven a verificar la membresía (P0401).
    const { data: membership } = await supabase
      .from('account_members')
      .select('account_id')
      .eq('user_id', user.id)
      .order('created_at', { ascending: true })
      .order('id', { ascending: true })
      .limit(1)
      .maybeSingle()
    const accountId = (membership as { account_id?: string } | null)?.account_id
    if (!accountId) return jsonResponse({ ok: false, error: 'no_active_account' }, 403)

    async function rpcRows<T>(fn: string, args: Record<string, unknown>): Promise<T[]> {
      const { data, error } = await supabase.rpc(fn, args)
      if (error) throw new Error(`${fn}: ${error.message}`)
      return (data ?? []) as T[]
    }

    // 4. Orquestación pura (cuota → contexto → modelo → persistir → cobrar).
    const result = await runEstadisticasAnalysis({
      checkQuota: () => checkAiQuota(supabase, user.id, 'queries'),

      fetchContext: async (): Promise<EstadisticasContext> => {
        const [evolution, rankingByUnits, rankingByRevenue, canal, weekday, topClients] = await Promise.all([
          rpcRows<EvolutionRow>('rpc_sales_evolution', {
            p_account_id: accountId, p_start: start, p_end: end, p_bucket: 'day', p_branch_id: branchId, p_canal: null,
          }),
          rpcRows<RankingRow>('rpc_product_ranking', {
            p_account_id: accountId, p_start: start, p_end: end, p_order_by: 'units', p_group_variants: true,
            p_branch_id: branchId, p_canal: null, p_limit: RANKING_TOP, p_offset: 0,
          }),
          rpcRows<RankingRow>('rpc_product_ranking', {
            p_account_id: accountId, p_start: start, p_end: end, p_order_by: 'revenue', p_group_variants: true,
            p_branch_id: branchId, p_canal: null, p_limit: RANKING_TOP, p_offset: 0,
          }),
          rpcRows<BreakdownRow>('rpc_sales_breakdown', {
            p_account_id: accountId, p_start: start, p_end: end, p_dimension: 'canal', p_branch_id: branchId, p_canal: null,
          }),
          rpcRows<BreakdownRow>('rpc_sales_breakdown', {
            p_account_id: accountId, p_start: start, p_end: end, p_dimension: 'weekday', p_branch_id: branchId, p_canal: null,
          }),
          rpcRows<TopClientRow>('rpc_sales_top_clients', {
            p_account_id: accountId, p_start: start, p_end: end, p_branch_id: branchId, p_limit: CLIENTS_TOP,
          }),
        ])
        // El prompt sólo necesita los totales; los buckets diarios no se usan
        // (y jamás se suman acá).
        return {
          evolution: evolution.filter((r) => r.period !== 'bucket'),
          rankingByUnits, rankingByRevenue, canal, weekday, topClients,
        }
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
                max_tokens: 600,
                temperature: 0.3,
              }),
            }
          )
          console.log('[ai-estadisticas] OpenAI status:', response.status)
          if (!response.ok) {
            const errRaw = await response.text().catch(() => '')
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
          console.error('[ai-estadisticas] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
          return isTimeout ? { kind: 'timeout' } : { kind: 'error', message: extractErrorMessage(aiErr) }
        }
      },

      persistInsight: async (insight: string) => {
        const { error: insertErr } = await supabase.from('insights').insert({
          user_id:    user.id,
          account_id: accountId,
          type:       ESTADISTICAS_INSIGHT_TYPE,
          priority:   'media',
          message:    insight,
        })
        if (insertErr) {
          console.error('[ai-estadisticas] DB insert error:', extractErrorMessage(insertErr))
          throw new Error(extractErrorMessage(insertErr))
        }
      },

      incrementUsage: () => incrementAiUsage(supabase, user.id, 'queries'),
    })

    console.log('[ai-estadisticas] Done:', result.status)
    return jsonResponse(result.body, result.status)

  } catch (err: unknown) {
    console.error('[ai-estadisticas] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
