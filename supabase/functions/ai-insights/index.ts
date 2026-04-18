import { createClient } from 'jsr:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const AI_TIMEOUT_MS = 8000

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

function errorResponse(message: string, status = 500) {
  return jsonResponse({ ok: false, error: message }, status)
}

function fallbackResponse(message = 'No se pudo generar los consejos en este momento. Intentá de nuevo más tarde.') {
  return jsonResponse({ ok: true, fallback: true, message })
}

/** Fetch with AbortController timeout + retry. */
async function fetchWithTimeout(
  url: string,
  options: RequestInit,
  retries = 2
): Promise<Response> {
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
      console.warn('[ai-insights] Retry OpenAI call, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

/** Safely extract a string error message from anything. */
function extractErrorMessage(err: unknown): string {
  if (typeof err === 'string') return err
  if (err && typeof err === 'object') {
    const e = err as Record<string, unknown>
    if (typeof e['message'] === 'string') return e['message']
    if (typeof e['details'] === 'string') return e['details']
    if (typeof e['hint'] === 'string') return e['hint']
    if (typeof e['code'] === 'string') return `DB error code: ${e['code']}`
  }
  return 'Unknown error'
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  console.log('[ai-insights] Request received')

  try {
    // 1. Auth
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      console.error('[ai-insights] Auth failed:', userError?.message)
      return errorResponse('No autorizado', 401)
    }

    console.log('[ai-insights] Auth OK, userId hash present:', !!user.id)

    // 2. Validate OpenAI key early – fail fast with a REAL error (not a fallback)
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      console.error('[ai-insights] OPENAI_API_KEY secret not set in Supabase')
      return errorResponse('Missing OPENAI_API_KEY — set it via: supabase secrets set OPENAI_API_KEY=sk-...', 500)
    }

    // 3. Fetch business data
    const threeMonthsAgo = new Date()
    threeMonthsAgo.setMonth(threeMonthsAgo.getMonth() - 3)

    const [salesResult, productsResult, expensesResult, clientsResult] = await Promise.all([
      supabaseClient.from('sales').select('amount, quantity, date, product_id').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('products').select('id, name, stock, cost, price'),
      supabaseClient.from('expenses').select('amount, category, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('clients').select('name, id').limit(5)
    ])

    const sales = salesResult.data || []
    const products = productsResult.data || []
    const expenses = expensesResult.data || []
    const clients = clientsResult.data || []

    console.log('[ai-insights] Data fetched – sales:', sales.length, 'products:', products.length)

    const lowStock = products.filter((p: Record<string, unknown>) => Number(p.stock) < 5)
    const lowMargin = products.filter((p: Record<string, unknown>) => {
      const price = Number(p.price)
      const cost = Number(p.cost)
      return price > 0 && ((price - cost) / price) < 0.2
    })

    const prompt = `Analiza estos datos de mi negocio y genera 3 insights accionables.
DATOS:
- Ventas recientes: ${sales.length} transacciones.
- Gastos recientes: ${expenses.length} registros.
- Inventario Total: ${products.length} productos.
- Stock bajo (< 5 unidades): ${lowStock.map((p: Record<string, unknown>) => `${p.name} (${p.stock})`).join(', ') || 'Todo en orden'}.
- Margen bajo (< 20%): ${lowMargin.map((p: Record<string, unknown>) => p.name).join(', ') || 'Todo en orden'}.
- Clientes principales: ${clients.map((c: Record<string, unknown>) => c.name).join(', ') || 'Sin datos'}.

INSTRUCCIONES:
- Devuelve un JSON con la clave "insights" que contenga un array de objetos.
- Cada objeto debe tener: type ("ventas"|"stock"|"margen"|"producto"|"marketing"), priority ("alta"|"media"|"baja"), message (consejo accionable en español).
- Devuelve SOLO el JSON, sin texto adicional.`

    // 4. Call OpenAI with timeout + retry
    let insightsData: unknown[] = []
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
              { role: 'system', content: 'Eres un analista financiero experto. Generas insights estructurados en JSON.' },
              { role: 'user', content: prompt }
            ],
            response_format: { type: 'json_object' },
            max_tokens: 600,
          }),
        }
      )

      console.log('[ai-insights] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-insights] OpenAI error FULL body:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return errorResponse(`OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}`, 502)
      }

      const aiData = await response.json()
      const contentText: string = aiData?.choices?.[0]?.message?.content ?? ''

      if (!contentText) {
        console.warn('[ai-insights] Empty content from OpenAI')
        return fallbackResponse()
      }

      // Robust parse – strip markdown fences if model included them
      const cleaned = contentText.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      const parsed = JSON.parse(cleaned)
      insightsData = Array.isArray(parsed) ? parsed : (parsed.insights ?? [])
      console.log('[ai-insights] Parsed insights count:', insightsData.length)

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-insights] AI call failed FULL:', isTimeout ? 'TIMEOUT' : aiErr)
      return errorResponse(isTimeout ? 'OpenAI timeout (>8s)' : extractErrorMessage(aiErr), 502)
    }

    // 5. Persist to DB
    if (insightsData.length > 0) {
      const toInsert = insightsData.map((ins: unknown) => {
        const i = ins as Record<string, unknown>
        return {
          user_id: user.id,
          type: typeof i.type === 'string' ? i.type : 'general',
          priority: typeof i.priority === 'string' ? i.priority : 'media',
          message: typeof i.message === 'string' ? i.message : 'Sin mensaje',
        }
      })

      const { error: insertError } = await supabaseClient.from('ai_insights').insert(toInsert)
      if (insertError) {
        // Log the real DB error without crashing the response
        console.error('[ai-insights] DB insert error:', extractErrorMessage(insertError))
        // Still return the generated insights to the frontend even if persist failed
      }
    }

    console.log('[ai-insights] Success, count:', insightsData.length)
    return jsonResponse({ ok: true, count: insightsData.length, data: insightsData })

  } catch (err: unknown) {
    console.error('[ai-insights] Unhandled error FULL:', err)
    return errorResponse(extractErrorMessage(err) || 'Unknown error', 500)
  }
})
