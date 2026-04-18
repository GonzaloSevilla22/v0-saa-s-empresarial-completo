import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const AI_TIMEOUT_MS = 8000

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

serve(async (req) => {
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
      console.error('[ai-resumen] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    console.log('[ai-resumen] Auth OK')

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      console.error('[ai-resumen] OPENAI_API_KEY not set in Supabase secrets')
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY — set it via: supabase secrets set OPENAI_API_KEY=sk-...' }, 500)
    }

    const body = await req.json().catch(() => ({}))
    const { period } = body

    // 3. Fetch Data based on Period
    const now = new Date()
    let startDate = new Date()
    if (period === 'weekly') startDate.setDate(now.getDate() - 7)
    else if (period === 'monthly') startDate.setMonth(now.getMonth() - 1)
    else startDate.setDate(now.getDate() - 1) // daily default

    const [salesResult, expensesResult] = await Promise.all([
      supabaseClient.from('sales').select('amount').gte('date', startDate.toISOString()),
      supabaseClient.from('expenses').select('amount').gte('date', startDate.toISOString())
    ])

    const totalSales = (salesResult.data || []).reduce((acc: number, s: any) => acc + Number(s.amount), 0)
    const totalExpenses = (expensesResult.data || []).reduce((acc: number, e: any) => acc + Number(e.amount), 0)
    const balance = totalSales - totalExpenses

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
              { role: 'system', content: 'Eres un asistente financiero profesional. Resume el periodo financiero basándote en los números provistos. Sé breve y directo.' },
              { role: 'user', content: `Resumen para el periodo ${period ?? 'daily'}: Ventas totales $${totalSales}, Gastos totales $${totalExpenses}, Balance neto $${balance}.` }
            ],
            max_tokens: 400,
          }),
        }
      )
      console.log('[ai-resumen] OpenAI status:', response.status)
      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-resumen] OpenAI error FULL body:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse({ ok: false, error: `OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}` }, 502)
      }
      const aiData = await response.json()
      content = aiData?.choices?.[0]?.message?.content || 'Resumen generado.'
    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-resumen] AI call failed FULL:', isTimeout ? 'TIMEOUT' : aiErr)
      return jsonResponse({ ok: false, error: isTimeout ? 'OpenAI timeout (>8s)' : extractErrorMessage(aiErr) }, 502)
    }

    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'general',
      p_content: content,
      p_source_function: 'ai-resumen'
    })

    if (rpcError) {
      console.error('[ai-resumen] RPC error:', extractErrorMessage(rpcError))
      return jsonResponse({ ok: true, data: content })
    }

    console.log('[ai-resumen] Success')
    return jsonResponse({ ok: true, data: insight })

  } catch (err: unknown) {
    console.error('[ai-resumen] Unhandled error FULL:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) || 'Unknown error' }, 500)
  }
})
