import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage } from '../_shared/ai-quota.ts'
import {
  fetchKpiSummary,
  sumLineRevenue,
  previousWindow,
  type SaleRevenueRow,
} from '../_shared/reporting-canon.ts'
import { argentinaDaysAgoIso } from '../_shared/argentina-time.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// OpenAI gpt-4o-mini can take 6–15 s under load. 25 s gives ample room
// while staying well within Supabase Edge Function's 60 s hard limit.
const AI_TIMEOUT_MS = 25_000

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
    if (retries > 0 && !isAbort) return fetchWithTimeout(url, options, retries - 1)
    throw err
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      console.error('[ai-prediccion] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    console.log('[ai-prediccion] Auth OK')

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      console.error('[ai-prediccion] OPENAI_API_KEY not set in Supabase secrets')
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY — set it via: supabase secrets set OPENAI_API_KEY=sk-...' }, 500)
    }

    // ── Plan quota check (C-02) — reject before any OpenAI cost ───────────────
    const quota = await checkAiQuota(supabaseClient, user.id, 'queries')
    if (!quota.allowed) {
      console.warn('[ai-prediccion] Quota exceeded for user', user.id)
      return jsonResponse(quota.body, 429)
    }

    const body = await req.json().catch(() => ({}))
    const { days_ahead } = body

    // 3. Fetch Historical Data (Last 30 days) — kpi-ia-canonical-revenue (D1/D2)
    const now = new Date()
    const thirtyDaysAgo = new Date()
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)

    const nowIso = now.toISOString()
    const fromIso = thirtyDaysAgo.toISOString()
    const { from: prevFromIso, to: prevToIso } = previousWindow(fromIso, nowIso)

    // app-timezone-argentina (task 4.2): la ventana de LECTURA (`.gte`) se
    // ancla al día argentino de `now` — a las 21:00-23:59 ART el día UTC ya
    // rolleó y dejaba afuera la venta más reciente. fromIso/nowIso (arriba,
    // ventana del RPC canónico) NO se tocan: duración exacta de 30 días,
    // agnóstica de huso (D1/D2 kpi-ia-canonical-revenue).
    const fromDateIso = argentinaDaysAgoIso(30, now)

    // `total` se agrega — es además la fuente del camino degradado (D4).
    const { data: sales, error: salesError } = await supabaseClient
      .from('sales')
      .select('amount, total, date')
      .gte('date', fromDateIso)
      .order('date', { ascending: true })

    // kpi-ia-canonical-revenue (D1/D4): ventas desde el canon; si el RPC
    // falla, se degrada a la suma de línea local sobre las filas ya fetched.
    let invoicedRevenue: number | null = null
    try {
      const summary = await fetchKpiSummary(supabaseClient, {
        from: fromIso,
        to: nowIso,
        prevFrom: prevFromIso,
        prevTo: prevToIso,
      })
      if (summary) invoicedRevenue = summary.invoicedRevenue
    } catch (err) {
      console.error('[ai-prediccion] rpc_dashboard_kpi_summary falló, degradando a ingresos locales:', err)
    }

    const totalSales = invoicedRevenue ?? sumLineRevenue((sales ?? []) as SaleRevenueRow[])
    const avgDailySales = totalSales / 30

    let content = ''
    try {
      const response = await fetchWithTimeout(
        'https://api.openai.com/v1/chat/completions',
        {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${openAiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            model: 'gpt-4o-mini',
            messages: [
              { role: 'system', content: 'Eres un experto en predicción de ventas. Analiza el historial provisto y predice la tendencia para los próximos días.' },
              { role: 'user', content: `Historial de ventas (últimos 30 días, ${sales?.length ?? 0} registros). Promedio diario: $${avgDailySales.toFixed(2)}. Predice para los próximos ${days_ahead ?? 7} días.` }
            ],
            max_tokens: 400,
          }),
        }
      )
      console.log('[ai-prediccion] OpenAI status:', response.status)
      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-prediccion] OpenAI error FULL body:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse({ ok: false, error: `OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}` }, 502)
      }
      const aiData = await response.json()
      content = aiData?.choices?.[0]?.message?.content || 'Predicción generada.'
    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-prediccion] AI call failed FULL:', isTimeout ? 'TIMEOUT' : aiErr)
      return jsonResponse({ ok: false, error: isTimeout ? 'OpenAI tardó demasiado — intentá nuevamente en unos segundos' : extractErrorMessage(aiErr) }, 502)
    }

    // OpenAI call succeeded — consume one AI query from the monthly quota (C-02).
    await incrementAiUsage(supabaseClient, user.id, 'queries')

    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      // p_user_id removed: RPC uses auth.uid() internally (security hardening)
      p_type: 'prediction',
      p_content: content,
      p_source_function: 'ai-prediccion'
    })

    if (rpcError) {
      console.error('[ai-prediccion] RPC error:', extractErrorMessage(rpcError))
      // Return the prediction text even if logging failed
      return jsonResponse({ ok: true, data: content })
    }

    console.log('[ai-prediccion] Success')
    return jsonResponse({ ok: true, data: insight })

  } catch (err: unknown) {
    console.error('[ai-prediccion] Unhandled error FULL:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) || 'Unknown error' }, 500)
  }
})
