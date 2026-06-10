import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage } from '../_shared/ai-quota.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// OpenAI gpt-4o-mini can take 6–15 s under load. 25 s gives ample room
// while staying well within Supabase Edge Function's 60 s hard limit.
// Previous value of 10_000 ms caused 502s visible in production logs.
const AI_TIMEOUT_MS = 25_000

// ─── Helpers ──────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}

function fallbackResponse(msg = 'No se pudo generar los consejos en este momento. Intentá de nuevo más tarde.') {
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
      console.warn('[ai-insights] Retry, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[ai-insights] Request received')

  try {
    // ── Auth ──────────────────────────────────────────────────────────────────
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      console.error('[ai-insights] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      console.error('[ai-insights] OPENAI_API_KEY not set')
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY' }, 500)
    }

    // ── Plan quota check (C-02) — reject before any OpenAI cost ───────────────
    const quota = await checkAiQuota(supabase, user.id, 'queries')
    if (!quota.allowed) {
      console.warn('[ai-insights] Quota exceeded for user', user.id)
      return jsonResponse(quota.body, 429)
    }

    // ── Fetch data (período actual + anterior para comparativa) ───────────────
    const now   = new Date()
    const d30   = new Date(now); d30.setDate(now.getDate() - 30)
    const d60   = new Date(now); d60.setDate(now.getDate() - 60)
    const d30Str = d30.toISOString().split('T')[0]
    const d60Str = d60.toISOString().split('T')[0]

    // C-20: leer desde v_sales_flat (columnas planas desde sale_items) en lugar de sales
    const [salesRes, prevSalesRes, productsRes, expensesRes, rotationRes] = await Promise.all([
      supabase.from('v_sales_flat').select('amount, quantity, date, product_id').gte('date', d30Str),
      supabase.from('v_sales_flat').select('amount').gte('date', d60Str).lt('date', d30Str),
      supabase.from('products').select('id, name, price, cost, stock, min_stock').limit(50),
      supabase.from('expenses').select('amount, category').gte('date', d30Str),
      supabase.from('v_sales_flat').select('product_id, date').gte('date', d60Str).order('date', { ascending: false }),
    ])

    const sales    = salesRes.data    ?? []
    const prevSale = prevSalesRes.data ?? []
    const products = productsRes.data  ?? []
    const expenses = expensesRes.data  ?? []

    console.log('[ai-insights] Data fetched – sales:', sales.length, 'products:', products.length)

    // ── Pre-calcular métricas ─────────────────────────────────────────────────

    const totalRevenue  = sales.reduce((s: number, r: any) => s + Number(r.amount), 0)
    const prevRevenue   = prevSale.reduce((s: number, r: any) => s + Number(r.amount), 0)
    const totalExpenses = expenses.reduce((s: number, r: any) => s + Number(r.amount), 0)
    const netProfit     = totalRevenue - totalExpenses
    const margenNeto    = totalRevenue > 0
      ? Math.round(((totalRevenue - totalExpenses) / totalRevenue) * 100)
      : 0
    const vsPrev = prevRevenue > 0
      ? `${totalRevenue >= prevRevenue ? '+' : ''}${Math.round(((totalRevenue - prevRevenue) / prevRevenue) * 100)}%`
      : 'sin datos previos'

    // Top productos por revenue
    // C-20: s.products ya no viene del embedded join (v_sales_flat no expone FK embebida)
    // → buscar info del producto desde productsRes ya fetched
    const productMap = new Map<string, { name: string; cost: number; price: number }>(
      products.map((p: any) => [p.id, { name: p.name, cost: Number(p.cost ?? 0), price: Number(p.price ?? 0) }])
    )
    const salesByProduct = new Map<string, { nombre: string; revenue: number; units: number; cost: number; price: number }>()
    for (const s of sales) {
      const pid = s.product_id
      if (!pid) continue
      const p   = productMap.get(pid)
      const cur = salesByProduct.get(pid) ?? { nombre: p?.name ?? '?', revenue: 0, units: 0, cost: p?.cost ?? 0, price: p?.price ?? 0 }
      salesByProduct.set(pid, { ...cur, revenue: cur.revenue + Number(s.amount), units: cur.units + Number(s.quantity) })
    }
    const topProducts = [...salesByProduct.values()]
      .sort((a, b) => b.revenue - a.revenue)
      .slice(0, 5)
      .map(p => `${p.nombre}: $${Math.round(p.revenue).toLocaleString()} (${p.units} uds, ${p.price > 0 ? Math.round(((p.price - p.cost) / p.price) * 100) : 0}% margen)`)

    // Sin rotación
    const lastSaleDate = new Map<string, string>()
    for (const s of rotationRes.data ?? []) {
      if (s.product_id && !lastSaleDate.has(s.product_id)) lastSaleDate.set(s.product_id, s.date)
    }
    const avgDailyUnits = new Map<string, number>()
    for (const [pid, d] of salesByProduct) avgDailyUnits.set(pid, d.units / 30)

    const sinRotacion = products
      .filter((p: any) => Number(p.stock) > 0)
      .map((p: any) => {
        const last = lastSaleDate.get(p.id)
        const dias = last ? Math.floor((now.getTime() - new Date(last).getTime()) / 86_400_000) : 61
        return { p, dias }
      })
      .filter(({ dias }: any) => dias >= 30)
      .sort((a: any, b: any) => b.dias - a.dias)
      .slice(0, 4)
      .map(({ p, dias }: any) =>
        `${p.name}: ${p.stock} uds, ${dias} días sin vender, $${Math.round(p.stock * Number(p.cost)).toLocaleString()} inmovilizado`
      )

    // Stock crítico
    const stockCritico = products
      .filter((p: any) => Number(p.stock) <= Number(p.min_stock ?? 5))
      .slice(0, 4)
      .map((p: any) => {
        const avg  = avgDailyUnits.get(p.id) ?? 0
        const dias = avg > 0 ? Math.round(Number(p.stock) / avg) : 99
        return `${p.name}: ${p.stock} uds (mín ${p.min_stock ?? 5}), ~${dias} días restantes`
      })

    // Margen bajo
    const margenBajo = products
      .filter((p: any) => Number(p.price) > 0 && (Number(p.price) - Number(p.cost)) / Number(p.price) < 0.2)
      .slice(0, 4)
      .map((p: any) => `${p.name}: ${Math.round(((Number(p.price) - Number(p.cost)) / Number(p.price)) * 100)}% margen (costo $${p.cost} → precio $${p.price})`)

    // Gasto top
    const expByCategory = new Map<string, number>()
    for (const e of expenses) {
      const cat = (e.category as string) ?? 'Sin categoría'
      expByCategory.set(cat, (expByCategory.get(cat) ?? 0) + Number(e.amount))
    }
    const topCat = [...expByCategory.entries()].sort((a, b) => b[1] - a[1])[0]
    const categoriaTop = topCat ? `${topCat[0]}: $${Math.round(topCat[1]).toLocaleString()}` : 'Sin gastos'

    // ── Prompt optimizado ─────────────────────────────────────────────────────

    const contextBlock = [
      `PERÍODO (últimos 30 días):`,
      `- Ventas: $${Math.round(totalRevenue).toLocaleString()} (${vsPrev} vs período anterior)`,
      `- Gastos: $${Math.round(totalExpenses).toLocaleString()} | Margen neto: ${margenNeto}%`,
      `- Top gasto: ${categoriaTop}`,
      '',
      topProducts.length > 0 ? `TOP PRODUCTOS:\n${topProducts.map(p => `  • ${p}`).join('\n')}` : '',
      sinRotacion.length > 0 ? `SIN ROTACIÓN (≥30 días sin vender):\n${sinRotacion.map((p: string) => `  • ${p}`).join('\n')}` : '',
      stockCritico.length > 0 ? `STOCK CRÍTICO:\n${stockCritico.map((p: string) => `  • ${p}`).join('\n')}` : '',
      margenBajo.length > 0 ? `MARGEN BAJO (<20%):\n${margenBajo.map((p: string) => `  • ${p}`).join('\n')}` : '',
    ].filter(Boolean).join('\n')

    const prompt = `${contextBlock}

Identificá los problemas u oportunidades REALES que ves en estos datos.
Solo generá un insight si hay evidencia concreta en los números. Máximo 4.

Devolvé un JSON con clave "insights": array de objetos con:
- type: "ventas"|"stock"|"margen"|"rotacion"|"oportunidad"
- priority: "alta"|"media"|"baja"
- message: qué está pasando + por qué (1 oración, con número específico)
- action: qué hacer HOY (concreto y accionable)
- data_point: el número exacto del contexto que justifica el insight

Devolvé SOLO el JSON.`

    // ── OpenAI ────────────────────────────────────────────────────────────────
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
              {
                role: 'system',
                content: `Sos un consultor de negocios especializado en emprendimientos argentinos.
REGLAS:
1. Cada insight DEBE citar un número real del contexto
2. PROHIBIDO dar consejos genéricos sin sustento en datos
3. Si no hay problema real, no fuerces insights vacíos
4. Español rioplatense, directo`,
              },
              { role: 'user', content: prompt },
            ],
            response_format: { type: 'json_object' },
            max_tokens: 700,
            temperature: 0.4,
          }),
        }
      )

      console.log('[ai-insights] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-insights] OpenAI error:', errRaw)
        let errParsed: any = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse({ ok: false, error: `OpenAI error ${response.status}: ${errParsed?.error?.message || errRaw}` }, 502)
      }

      const aiData    = await response.json()
      const content   = aiData?.choices?.[0]?.message?.content ?? ''
      if (!content) { console.warn('[ai-insights] Empty content'); return fallbackResponse() }

      const cleaned   = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      const parsed    = JSON.parse(cleaned)
      insightsData    = Array.isArray(parsed) ? parsed : (parsed.insights ?? [])
      console.log('[ai-insights] Parsed insights:', insightsData.length)

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-insights] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
      return jsonResponse({ ok: false, error: isTimeout ? 'OpenAI timeout' : extractErrorMessage(aiErr) }, 502)
    }

    // ── Persistir ─────────────────────────────────────────────────────────────
    if (insightsData.length > 0) {
      const toInsert = insightsData.map((ins: unknown) => {
        const i = ins as Record<string, unknown>
        return {
          user_id:  user.id,
          type:     typeof i.type     === 'string' ? i.type     : 'general',
          priority: typeof i.priority === 'string' ? i.priority : 'media',
          message:  typeof i.message  === 'string'
            ? `${i.message}${i.action ? ` → ${i.action}` : ''}`
            : 'Sin mensaje',
        }
      })
      const { error: insertError } = await supabase.from('ai_insights').insert(toInsert)
      if (insertError) console.error('[ai-insights] DB insert error:', extractErrorMessage(insertError))
    }

    // ── Consume one AI query from the monthly quota (C-02) ────────────────────
    await incrementAiUsage(supabase, user.id, 'queries')

    console.log('[ai-insights] Success, count:', insightsData.length)
    return jsonResponse({ ok: true, count: insightsData.length, data: insightsData })

  } catch (err: unknown) {
    console.error('[ai-insights] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
