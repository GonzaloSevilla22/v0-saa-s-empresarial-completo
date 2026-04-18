import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const AI_TIMEOUT_MS = 8000

// ─── Helpers (shared pattern across all edge functions) ───────────────────────

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

function fallbackResponse(message = 'No se pudo generar la recomendación. Intentá más tarde.') {
  return jsonResponse({ ok: true, fallback: true, message })
}

function extractErrorMessage(err: unknown): string {
  if (typeof err === 'string') return err
  if (err && typeof err === 'object') {
    const e = err as Record<string, unknown>
    if (typeof e['message'] === 'string') return e['message']
    if (typeof e['details'] === 'string') return e['details']
    if (typeof e['code'] === 'string') return `DB error code: ${e['code']}`
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
      console.warn('[fair-advisor] Retry, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Phase 3: Heavy payload guard ─────────────────────────────────────────────
// Feria payloads could include base64-encoded images or audio blobs sent by
// future clients. We detect and reject them early so the function never times out.
const PAYLOAD_LIMIT_BYTES = 1_000_000 // 1 MB

// ─── Handler ──────────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  console.log('[fair-advisor] Request received')

  try {
    // Phase 3: Check Content-Length header to guard against large payloads
    const contentLength = Number(req.headers.get('content-length') ?? '0')
    if (contentLength > PAYLOAD_LIMIT_BYTES) {
      console.warn('[fair-advisor] Payload too large:', contentLength, 'bytes — returning async response')
      return jsonResponse(
        { ok: true, processing: true, message: 'Payload grande detectado. Tu solicitud se procesará en espera.' },
        202
      )
    }

    // 1. Auth
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      console.error('[fair-advisor] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    console.log('[fair-advisor] Auth OK')

    // 2. Validate OpenAI key
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      console.error('[fair-advisor] OPENAI_API_KEY not set in Supabase secrets')
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY — set it via: supabase secrets set OPENAI_API_KEY=sk-...' }, 500)
    }

    // 3. Fetch business data
    const [salesResult, productsResult] = await Promise.all([
      supabaseClient.from('sales').select('quantity, product_id, date').order('date', { ascending: false }).limit(200),
      supabaseClient.from('products').select('id, name, stock, cost, price')
    ])

    const sales = salesResult.data || []
    const products = productsResult.data || []
    console.log('[fair-advisor] Data fetched – products:', products.length, 'sales:', sales.length)

    // 4. Compute product scores locally
    const productScores = products.map((p: Record<string, unknown>) => {
      const pSales = sales.filter((s: Record<string, unknown>) => s.product_id === p.id)
      const salesCount = pSales.reduce((acc: number, s: Record<string, unknown>) => acc + Number(s.quantity), 0)
      const price = Number(p.price)
      const cost = Number(p.cost)
      const margin = price > 0 ? ((price - cost) / price) * 100 : 0
      return {
        id: p.id,
        name: p.name,
        stock: p.stock,
        cost: p.cost,
        price: p.price,
        margin: margin.toFixed(1) + '%',
        salesVolume: salesCount,
        score: salesCount + (margin / 10) + (Number(p.stock) > 0 ? 5 : 0),
      }
    }).sort((a, b) => b.score - a.score)

    const prompt = `Analiza los siguientes productos y genera recomendaciones para una feria de emprendedores.

PRODUCTOS (ordenados por relevancia):
${JSON.stringify(productScores.slice(0, 15), null, 2)}

INSTRUCCIONES:
- Selecciona entre 3 y 5 productos ideales para la feria.
- Para cada uno indica: por qué llevarlo, cuántas unidades, precio sugerido.
- Devuelve un JSON con clave "recommendations" que sea un array de objetos con: product (string), reason (string), recommendedUnits (number), suggestedPrice (number).
- Devuelve SOLO el JSON.`

    // 5. Call OpenAI with timeout + retry
    let recommendations: unknown[] = []
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
              { role: 'system', content: 'Eres un experto asesor de ventas en eventos y ferias.' },
              { role: 'user', content: prompt }
            ],
            response_format: { type: 'json_object' },
            max_tokens: 600,
          }),
        }
      )

      console.log('[fair-advisor] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[fair-advisor] OpenAI error FULL body:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse({ ok: false, error: `OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}` }, 502)
      }

      const aiData = await response.json()
      const contentText: string = aiData?.choices?.[0]?.message?.content ?? ''
      const cleaned = contentText.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      const parsed = JSON.parse(cleaned)
      recommendations = Array.isArray(parsed) ? parsed : (parsed.recommendations ?? [])
      console.log('[fair-advisor] Parsed recommendations:', recommendations.length)

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[fair-advisor] AI call failed FULL:', isTimeout ? 'TIMEOUT' : aiErr)
      return jsonResponse({ ok: false, error: isTimeout ? 'OpenAI timeout (>8s)' : extractErrorMessage(aiErr) }, 502)
    }

    // 6. Persist to DB (error doesn't block the response)
    if (recommendations.length > 0) {
      const { error: insertError } = await supabaseClient
        .from('fair_recommendations')
        .insert({ user_id: user.id, recommendation: recommendations })
      if (insertError) {
        console.error('[fair-advisor] DB insert error:', extractErrorMessage(insertError))
      }
    }

    console.log('[fair-advisor] Success, count:', recommendations.length)
    return jsonResponse({ ok: true, data: recommendations })

  } catch (err: unknown) {
    console.error('[fair-advisor] Unhandled error FULL:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) || 'Unknown error' }, 500)
  }
})
