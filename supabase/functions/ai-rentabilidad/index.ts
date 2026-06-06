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

function fallbackResponse(msg = 'No se pudo generar el análisis de rentabilidad. Intentá de nuevo más tarde.') {
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

    // 2. Quota check
    const quota = await checkAiQuota(supabase, user.id, 'queries')
    if (!quota.allowed) {
      console.warn('[ai-rentabilidad] Quota exceeded for user', user.id)
      return jsonResponse(quota.body, 429)
    }

    // 3. Parse period_days from body
    let periodDays = 30
    try {
      const body = await req.json()
      if (typeof body?.period_days === 'number' && body.period_days > 0) {
        periodDays = Math.min(body.period_days, 365)
      }
    } catch (_) { /* use default */ }

    // 4. Fetch profitability data via RPC
    const { data: products, error: rpcErr } = await supabase.rpc('rpc_product_profitability', {
      p_period_days: periodDays,
    })

    if (rpcErr) {
      console.error('[ai-rentabilidad] RPC error:', rpcErr.message)
      return jsonResponse({ ok: false, error: rpcErr.message }, 500)
    }

    const rows = (products ?? []) as Array<Record<string, unknown>>

    if (rows.length === 0) {
      return jsonResponse({ ok: false, error: 'Sin datos de ventas en el período seleccionado' }, 422)
    }

    // RPC returns rows sorted DESC by gross_margin_pct → top 5 are the first 5
    const topProducts    = rows.slice(0, 5)
    const bottomProducts = rows.length > 5 ? rows.slice(-5) : []

    console.log('[ai-rentabilidad] Data:', rows.length, 'products, top:', topProducts.length, 'bottom:', bottomProducts.length)

    // 5. Build prompt
    const fmt    = (n: unknown) => `$${Math.round(Number(n)).toLocaleString('es-AR')}`
    const pctFmt = (n: unknown) => `${Number(n).toFixed(1)}%`
    const fmtRow = (p: Record<string, unknown>) =>
      `${p.product_name}: ingresos ${fmt(p.total_revenue)}, costo ${fmt(p.total_cost)}, margen ${pctFmt(p.gross_margin_pct)}, ${p.units_sold} uds`

    const contextBlock = [
      `PERÍODO: últimos ${periodDays} días`,
      '',
      topProducts.length > 0
        ? `TOP MARGEN:\n${topProducts.map(p => `  • ${fmtRow(p)}`).join('\n')}`
        : '',
      bottomProducts.length > 0
        ? `BAJO MARGEN:\n${bottomProducts.map(p => `  • ${fmtRow(p)}`).join('\n')}`
        : '',
    ].filter(Boolean).join('\n')

    const prompt = `${contextBlock}

Analizá la rentabilidad de estos productos. Identificá los hallazgos más importantes con datos concretos.

Devolvé un JSON con:
- "insight": string — síntesis ejecutiva de 2-3 oraciones con los números más relevantes
- "recommendations": string[] — exactamente 3 recomendaciones concretas y accionables

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
            max_tokens: 500,
            temperature: 0.3,
          }),
        }
      )

      console.log('[ai-rentabilidad] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-rentabilidad] OpenAI error:', errRaw)
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
      console.log('[ai-rentabilidad] Parsed insight length:', insight.length)

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-rentabilidad] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
      if (isTimeout) return fallbackResponse('El análisis tardó demasiado. Intentá de nuevo.')
      return jsonResponse({ ok: false, error: extractErrorMessage(aiErr) }, 502)
    }

    // 7. Persist insight + increment quota
    if (insight) {
      const { error: insertErr } = await supabase.from('ai_insights').insert({
        user_id:  user.id,
        type:     'margen',
        priority: 'alta',
        message:  insight,
      })
      if (insertErr) console.error('[ai-rentabilidad] DB insert error:', extractErrorMessage(insertErr))
    }

    await incrementAiUsage(supabase, user.id, 'queries')

    console.log('[ai-rentabilidad] Success')
    return jsonResponse({ ok: true, data: { insight, recommendations } })

  } catch (err: unknown) {
    console.error('[ai-rentabilidad] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
