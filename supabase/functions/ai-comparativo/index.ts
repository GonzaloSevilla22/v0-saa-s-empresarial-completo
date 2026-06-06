import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage } from '../_shared/ai-quota.ts'

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

function fallbackResponse(msg = 'No se pudo generar el análisis comparativo. Intentá de nuevo más tarde.') {
  return jsonResponse({ ok: true, fallback: true, message: msg })
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
      console.warn('[ai-comparativo] Retry, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[ai-comparativo] Request received')

  try {
    // 1. Auth
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      console.error('[ai-comparativo] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY' }, 500)
    }

    // 2. Quota check
    const quota = await checkAiQuota(supabase, user.id, 'queries')
    if (!quota.allowed) {
      console.warn('[ai-comparativo] Quota exceeded for user', user.id)
      return jsonResponse(quota.body, 429)
    }

    // 3. Parse date ranges from body
    let periodAStart = '', periodAEnd = '', periodBStart = '', periodBEnd = ''
    try {
      const body = await req.json()
      periodAStart = String(body?.period_a_start ?? '')
      periodAEnd   = String(body?.period_a_end   ?? '')
      periodBStart = String(body?.period_b_start ?? '')
      periodBEnd   = String(body?.period_b_end   ?? '')
    } catch (_) { /* fall through */ }

    if (!periodAStart || !periodAEnd || !periodBStart || !periodBEnd) {
      return jsonResponse({ ok: false, error: 'Parámetros de período requeridos: period_a_start, period_a_end, period_b_start, period_b_end' }, 400)
    }

    // 4. Fetch comparison data via RPC
    const { data: rows, error: rpcErr } = await supabase.rpc('rpc_period_comparison', {
      p_a_start: periodAStart,
      p_a_end:   periodAEnd,
      p_b_start: periodBStart,
      p_b_end:   periodBEnd,
    })

    if (rpcErr) {
      console.error('[ai-comparativo] RPC error:', rpcErr.message)
      return jsonResponse({ ok: false, error: rpcErr.message }, 500)
    }

    const row = Array.isArray(rows) && rows.length > 0
      ? rows[0] as Record<string, unknown>
      : null

    if (!row) {
      return jsonResponse({ ok: false, error: 'Sin datos para los períodos seleccionados' }, 422)
    }

    console.log('[ai-comparativo] RPC data retrieved')

    // 5. Build prompt
    const fmt    = (n: unknown) => `$${Math.round(Number(n ?? 0)).toLocaleString('es-AR')}`
    const pctFmt = (n: unknown) => n == null ? 'N/A' : `${Number(n) > 0 ? '+' : ''}${Number(n).toFixed(1)}%`

    const contextBlock = `
PERÍODO A (${periodAStart} → ${periodAEnd}):
  • Ventas:    ${fmt(row.period_a_revenue)}
  • Gastos:    ${fmt(row.period_a_expenses)}
  • Compras:   ${fmt(row.period_a_purchases)}
  • Operaciones: ${row.period_a_operations}

PERÍODO B (${periodBStart} → ${periodBEnd}):
  • Ventas:    ${fmt(row.period_b_revenue)}  (${pctFmt(row.revenue_delta_pct)} vs período A)
  • Gastos:    ${fmt(row.period_b_expenses)}  (${pctFmt(row.expenses_delta_pct)} vs período A)
  • Compras:   ${fmt(row.period_b_purchases)}  (${pctFmt(row.purchases_delta_pct)} vs período A)
  • Operaciones: ${row.period_b_operations}  (${pctFmt(row.operations_delta_pct)} vs período A)
`.trim()

    const prompt = `${contextBlock}

Analizá la evolución del negocio entre estos dos períodos. Identificá los cambios más significativos con datos concretos.

Devolvé un JSON con:
- "insight": string — síntesis ejecutiva de 2-3 oraciones con los números más relevantes y su significado
- "recommendations": string[] — exactamente 3 recomendaciones concretas y accionables basadas en las variaciones

Devolvé SOLO el JSON.`

    // 6. Call OpenAI
    let insight = ''
    let recommendations: string[] = []

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

      console.log('[ai-comparativo] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-comparativo] OpenAI error:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse(
          { ok: false, error: `OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}` },
          502
        )
      }

      const aiData  = await response.json()
      const content = aiData?.choices?.[0]?.message?.content ?? ''
      if (!content) return fallbackResponse()

      const cleaned  = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      const parsed   = JSON.parse(cleaned)
      insight        = typeof parsed.insight        === 'string' ? parsed.insight        : ''
      recommendations = Array.isArray(parsed.recommendations)  ? parsed.recommendations : []
      console.log('[ai-comparativo] Parsed insight length:', insight.length)

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-comparativo] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
      if (isTimeout) return fallbackResponse('El análisis tardó demasiado. Intentá de nuevo.')
      return jsonResponse({ ok: false, error: extractErrorMessage(aiErr) }, 502)
    }

    // 7. Persist insight + increment quota
    if (insight) {
      const { error: insertErr } = await supabase.from('ai_insights').insert({
        user_id:  user.id,
        type:     'comparativo',
        priority: 'alta',
        message:  insight,
      })
      if (insertErr) console.error('[ai-comparativo] DB insert error:', extractErrorMessage(insertErr))
    }

    await incrementAiUsage(supabase, user.id, 'queries')

    console.log('[ai-comparativo] Success')
    return jsonResponse({ ok: true, data: { insight, recommendations } })

  } catch (err: unknown) {
    console.error('[ai-comparativo] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
