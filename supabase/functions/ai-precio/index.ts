import { createClient } from 'jsr:@supabase/supabase-js@2'
import { checkAiQuota, incrementAiUsage, type AiQuotaClient } from '../_shared/ai-quota.ts'
import { resolveEffectivePlan } from '../_shared/effective-plan.ts'
// fix 3 (revisión adversarial, reutilización antes que repetición): la
// resolución de cuenta activa deja de reimplementarse acá — se migra a la
// misma `resolveActiveAccountId` de `_shared/reporting-canon.ts` que ya usan
// generate-export/ai-insights (Regla de Tres). Ver el comentario del call
// site más abajo por el único cambio de comportamiento real (desempate).
import { resolveActiveAccountId, type AccountResolutionClient } from '../_shared/reporting-canon.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const AI_TIMEOUT_MS = 25_000
const MIN_SALES_THRESHOLD = 3
const LOOKBACK_DAYS = 90

// ─── Types ────────────────────────────────────────────────────────────────────

interface SaleRow {
  week_key:  string
  avg_price: number
  qty:       number
}

interface ProductRow {
  id:    string
  name:  string
  price: number
  // productos-costo-nullable: el costo del catálogo es OPCIONAL. `null` =
  // no se cargó — la función NUNCA lo sustituye por cero ni lo estima.
  cost:  number | null
}

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

async function fetchWithTimeout(url: string, options: RequestInit): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), AI_TIMEOUT_MS)
  try {
    const res = await fetch(url, { ...options, signal: controller.signal })
    clearTimeout(timer)
    return res
  } catch (err: unknown) {
    clearTimeout(timer)
    throw err
  }
}

/**
 * Calculates implicit elasticity: Pearson correlation between weekly avg price
 * and weekly units sold. Returns a value in [-1, 1] or 0 if insufficient data.
 */
export function calculateElasticity(weeklyData: SaleRow[]): number {
  const n = weeklyData.length
  if (n < 2) return 0

  const prices = weeklyData.map((r) => r.avg_price)
  const qtys   = weeklyData.map((r) => r.qty)

  const meanP = prices.reduce((s, v) => s + v, 0) / n
  const meanQ = qtys.reduce((s, v) => s + v, 0) / n

  let num = 0, denP = 0, denQ = 0
  for (let i = 0; i < n; i++) {
    const dp = prices[i] - meanP
    const dq = qtys[i]   - meanQ
    num  += dp * dq
    denP += dp * dp
    denQ += dq * dq
  }

  const denom = Math.sqrt(denP * denQ)
  if (denom === 0) return 0
  return num / denom
}

/**
 * productos-costo-nullable (OQ-3): construye el prompt de sugerencia de
 * precio. Con `cost == null` (sin costo de catálogo) se OMITE la línea
 * "COSTO CATÁLOGO" y la instrucción de mantener el margen no negativo —
 * nunca se manda un costo cero ni una estimación propia (patrón
 * ai-canonical-metrics: omitir, jamás sustituir). Exportada como función
 * pura para que su contrato sea testeable sin runtime de Deno.
 */
export function buildPricePrompt(params: {
  productName: string
  price: number
  cost: number | null
  lookbackDays: number
  salesCount: number
  totalQty: number
  elasticity: number
  weeklyBlock: string
  fmt: (n: number) => string
}): string {
  const { productName, price, cost, lookbackDays, salesCount, totalQty, elasticity, weeklyBlock, fmt } = params
  const costLine = cost == null ? '' : `\nCOSTO CATÁLOGO: ${fmt(cost)}`
  const marginInstruction = cost == null
    ? ''
    : '\nTen en cuenta el costo del catálogo para que el margen no sea negativo.'

  return `PRODUCTO: ${productName}
PRECIO ACTUAL: ${fmt(price)}${costLine}
VENTAS ÚLTIMOS ${lookbackDays} DÍAS: ${salesCount} transacciones, ${totalQty.toFixed(0)} unidades
ELASTICIDAD IMPLÍCITA (correlación precio-cantidad): ${elasticity.toFixed(3)} (negativo = más ventas a precio menor)

VENTAS SEMANALES RECIENTES:
${weeklyBlock}

Basándote en estos datos reales, sugerí el precio óptimo para maximizar el ingreso total (no solo el margen).${marginInstruction}
Si la elasticidad es negativa y pronunciada (< -0.3), considerá bajar el precio para incrementar volumen.
Si la elasticidad es positiva o cercana a 0, el volumen no depende tanto del precio — priorizá margen.

Devolvé SOLO un JSON con:
- "suggested_price": number — precio sugerido en ARS (entero)${cost == null ? '' : `
- "margin_pct": number — margen proyectado con ese precio (porcentaje, 1 decimal)`}
- "argument": string — argumento narrativo en español rioplatense, 2-3 oraciones con números concretos`
}

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  console.log('[ai-precio] Request received')

  try {
    // 1. Auth — always use getUser() for server-side auth (RN project rule)
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user }, error: userError } = await supabase.auth.getUser()
    if (userError || !user) {
      console.error('[ai-precio] Auth failed:', userError?.message)
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401)
    }

    // Resolve account_id for tenancy-aware queries (C-19). billing-edge-
    // effective-plan (task 5.4): reemplaza el `.single()` que lanzaba si el
    // usuario pertenecía a 2+ cuentas por una regla determinista de
    // membresía más antigua. No hay una vía autorizada para pedirle el
    // account_id resuelto a `rpc_my_effective_plan()` (deliberado, D1: el RPC
    // solo devuelve el plan, nunca el identificador de cuenta), así que esta
    // función resuelve la cuenta por su cuenta, sobre la misma tabla
    // (account_members), para el mismo usuario.
    //
    // fix 3 (revisión adversarial, reutilización antes que repetición): deja
    // de reimplementar la resolución localmente (`resolveAccountId`,
    // desempate por `account_id`) y migra a la MISMA `resolveActiveAccountId`
    // de `_shared/reporting-canon.ts` que ya usan generate-export/ai-insights
    // (Regla de Tres) — desempate por `id` (la PK de `account_members`),
    // igual que `backend/core/deps.py:get_account_id`.
    //
    // Único cambio de comportamiento real: `rpc_my_effective_plan()`'s D2
    // desempata por `account_id` ASC, no por `id`; con 2+ membresías que
    // comparten el MISMO `created_at` exacto (0 usuarios hoy — tenancy es de
    // una sola cuenta, OQ-2), esta función y el gate de plan más abajo
    // podrían en teoría resolver cuentas distintas. Mismo tipo de divergencia
    // ya documentada entre `rpc_my_effective_plan()` y
    // `backend/core/deps.py:get_account_id` (v31-authz-token-hook, D4) — no
    // introducida por este fix, sólo migrada al mismo lado del desempate que
    // el resto del módulo de reporting.
    //
    // Cast acotado (no `any`): `SupabaseClient` real satisface la forma
    // estructural de `AccountResolutionClient` en runtime, pero su tipo
    // completo (con todos los overloads de `.from()`/`.rpc()`) dispara
    // TS2589 (profundidad de instanciación excesiva) al compararlo contra
    // una interfaz angosta — mismo patrón que `checkAiQuota`/`incrementAiUsage`
    // en ai-insights/ai-resumen (`_shared/ai-quota.ts`).
    const accountId = await resolveActiveAccountId(supabase as unknown as AccountResolutionClient, user.id)

    if (!accountId) {
      console.error('[ai-precio] No active account for user:', user.id)
      return jsonResponse({ ok: false, error: 'No se encontró cuenta activa' }, 403)
    }

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      return jsonResponse({ ok: false, error: 'Missing OPENAI_API_KEY' }, 500)
    }

    // 2. Plan check — flag canónico plan_limits.has_price_suggestion del plan
    // efectivo (D4). El plan efectivo se resuelve vía la definición normativa
    // de la DB (_shared/effective-plan.ts, billing-edge-effective-plan) — ya
    // NO se reimplementa la lógica de trial acá ni se lee profiles.
    const effectivePlan = await resolveEffectivePlan(supabase)

    const { data: priceLimits, error: priceLimitsErr } = await supabase
      .from('plan_limits')
      .select('has_price_suggestion')
      .eq('plan', effectivePlan)
      .single()

    if (priceLimitsErr || !priceLimits) {
      console.error('[ai-precio] plan_limits fetch error:', priceLimitsErr?.message)
      return jsonResponse({ ok: false, error: 'No se pudo verificar el plan' }, 500)
    }

    if (!priceLimits.has_price_suggestion) {
      console.warn('[ai-precio] Plan not allowed (has_price_suggestion=false):', effectivePlan)
      return jsonResponse(
        { ok: false, error: 'plan_required', required_plan: 'avanzado' },
        403
      )
    }

    // 3. Quota check
    // Cast acotado (no `any`): `AiQuotaClient` restates 5 overloaded members,
    // lo que dispara TS2589 al compararlo contra el `SupabaseClient` real
    // (mismo patrón que ai-insights/ai-resumen).
    const quota = await checkAiQuota(supabase as unknown as AiQuotaClient, user.id, 'queries')
    if (!quota.allowed) {
      console.warn('[ai-precio] Quota exceeded for user', user.id)
      return jsonResponse(quota.body, 429)
    }

    // 4. Parse product_id from body
    let productId: string | undefined
    try {
      const body = await req.json()
      if (typeof body?.product_id === 'string' && body.product_id.trim()) {
        productId = body.product_id.trim()
      }
    } catch (_) { /* no body */ }

    if (!productId) {
      return jsonResponse({ ok: false, error: 'product_id requerido' }, 400)
    }

    // 5. Fetch product data
    const { data: product, error: productErr } = await supabase
      .from('products')
      .select('id, name, price, cost')
      .eq('id', productId)
      .eq('account_id', accountId)
      .single()

    if (productErr || !product) {
      console.error('[ai-precio] Product fetch error:', productErr?.message)
      return jsonResponse({ ok: false, error: 'Producto no encontrado' }, 404)
    }

    const prod = product as ProductRow

    // 6. Fetch sales for this product in the last 90 days
    // C-20: leer desde v_sales_flat (LEFT JOIN sale_items) para que backfill + doble
    // escritura sean transparentes. Las columnas amount, quantity, date, product_id
    // son idénticas al shape anterior de sales.
    const cutoff = new Date()
    cutoff.setDate(cutoff.getDate() - LOOKBACK_DAYS)

    const { data: salesRows, error: salesErr } = await supabase
      .from('v_sales_flat')
      .select('amount, quantity, date')
      .eq('product_id', productId)
      .eq('account_id', accountId)
      .gte('date', cutoff.toISOString().slice(0, 10))

    if (salesErr) {
      console.error('[ai-precio] Sales fetch error:', salesErr.message)
      return jsonResponse({ ok: false, error: salesErr.message }, 500)
    }

    const items = (salesRows ?? []) as Array<{
      amount:   number   // unit price
      quantity: number
      date:     string
    }>

    // 7. Fallback: insufficient data (< 3 sales)
    if (items.length < MIN_SALES_THRESHOLD) {
      console.log('[ai-precio] Insufficient data:', items.length, 'sales')
      return jsonResponse({ ok: true, fallback: true, reason: 'insufficient_data' })
    }

    // 8. Group by ISO week and calculate per-week avg price & total qty
    const weekMap = new Map<string, { totalPrice: number; totalQty: number; count: number }>()
    for (const item of items) {
      const d    = new Date(item.date)
      const year = d.getFullYear()
      // ISO week number
      const startOfYear = new Date(year, 0, 1)
      const weekNum     = Math.ceil(
        ((d.getTime() - startOfYear.getTime()) / 86_400_000 + startOfYear.getDay() + 1) / 7
      )
      const key = `${year}-W${String(weekNum).padStart(2, '0')}`
      const cur = weekMap.get(key) ?? { totalPrice: 0, totalQty: 0, count: 0 }
      cur.totalPrice += item.amount * item.quantity
      cur.totalQty   += item.quantity
      cur.count      += 1
      weekMap.set(key, cur)
    }

    const weeklyData: SaleRow[] = Array.from(weekMap.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([week_key, v]) => ({
        week_key,
        avg_price: v.totalQty > 0 ? v.totalPrice / v.totalQty : 0,
        qty:       v.totalQty,
      }))

    const elasticity = calculateElasticity(weeklyData)
    const totalQty   = items.reduce((s, i) => s + i.quantity, 0)

    // 9. Build prompt
    const fmt     = (n: number) => `$${Math.round(n).toLocaleString('es-AR')}`
    const topWeeks = weeklyData.slice(-6)

    const weeklyBlock = topWeeks
      .map((w) => `  ${w.week_key}: precio ${fmt(w.avg_price)}, cant. ${w.qty.toFixed(0)}`)
      .join('\n')

    const hasCost = prod.cost != null
    const prompt = buildPricePrompt({
      productName: prod.name,
      price: prod.price,
      cost: prod.cost,
      lookbackDays: LOOKBACK_DAYS,
      salesCount: items.length,
      totalQty,
      elasticity,
      weeklyBlock,
      fmt,
    })

    // 10. Call OpenAI with timeout
    let suggestedPrice = 0
    // productos-costo-nullable (OQ-3): sin costo, el margen proyectado es
    // AUSENTE — nunca 0 (0 leería como "sin margen" cuando en realidad es
    // "no lo calculamos"), nunca inventado por el modelo pese a que el
    // prompt no lo pidió.
    let marginPct: number | null = hasCost ? 0 : null
    let argument       = ''

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
            model:           'gpt-4o-mini',
            messages: [
              {
                role:    'system',
                content: 'Sos un asesor de precios para emprendedores argentinos. Usá el español rioplatense. Sé directo y basate siempre en los datos del contexto. Devolvé SOLO el JSON solicitado, sin texto adicional.',
              },
              { role: 'user', content: prompt },
            ],
            response_format: { type: 'json_object' },
            max_tokens:      400,
            temperature:     0.2,
          }),
        }
      )

      console.log('[ai-precio] OpenAI status:', response.status)

      if (!response.ok) {
        const errRaw = await response.text().catch(() => '')
        console.error('[ai-precio] OpenAI error:', errRaw)
        let errParsed: Record<string, unknown> = {}
        try { errParsed = JSON.parse(errRaw) } catch (_) {}
        return jsonResponse(
          { ok: false, error: `OpenAI error ${response.status}: ${(errParsed?.error as Record<string, unknown>)?.message ?? errRaw}` },
          502
        )
      }

      const aiData  = await response.json()
      const content = aiData?.choices?.[0]?.message?.content ?? ''
      if (!content) {
        return jsonResponse({ ok: true, fallback: true, reason: 'timeout' })
      }

      const cleaned = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
      const parsed  = JSON.parse(cleaned)
      suggestedPrice = typeof parsed.suggested_price === 'number' ? parsed.suggested_price : 0
      // Sin costo, marginPct queda en null pase lo que pase — el prompt ni
      // siquiera pidió el campo (OQ-3); si el modelo lo manda igual, se ignora.
      if (hasCost) {
        marginPct = typeof parsed.margin_pct === 'number' ? parsed.margin_pct : 0
      }
      argument       = typeof parsed.argument        === 'string' ? parsed.argument        : ''

    } catch (aiErr: unknown) {
      const isTimeout = aiErr instanceof DOMException && aiErr.name === 'AbortError'
      console.error('[ai-precio] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
      if (isTimeout) {
        return jsonResponse({ ok: true, fallback: true, reason: 'timeout' })
      }
      return jsonResponse({ ok: false, error: extractErrorMessage(aiErr) }, 502)
    }

    // 11. Insert into insights + increment counter
    // Use the user's authed client; the BEFORE INSERT trigger fills account_id so the
    // account-based RLS WITH CHECK passes (C-24).
    const { error: insertErr } = await supabase
      .from('insights')
      .insert({
        user_id:  user.id,
        type:     'oportunidad',
        priority: 'alta',
        message:  hasCost
          ? `[Producto: ${prod.name}] Precio sugerido: $${suggestedPrice} (margen ${marginPct!.toFixed(1)}%). ${argument}`
          : `[Producto: ${prod.name}] Precio sugerido: $${suggestedPrice} (margen no considerado — sin costo cargado). ${argument}`,
      })

    if (insertErr) {
      console.error('[ai-precio] DB insert error:', extractErrorMessage(insertErr))
    }

    // Mismo cast acotado que `checkAiQuota` arriba (ver comentario).
    await incrementAiUsage(supabase as unknown as AiQuotaClient, user.id, 'queries')

    console.log('[ai-precio] Success for product:', productId, 'suggested:', suggestedPrice)
    return jsonResponse({
      ok:              true,
      suggested_price: suggestedPrice,
      margin_pct:      marginPct,
      argument,
      // productos-costo-nullable (OQ-3): declara explícitamente por qué el
      // margen no viene — el modal lo usa para explicarlo, no para adivinar.
      ...(hasCost ? {} : { margin_not_considered: true }),
    })

  } catch (err: unknown) {
    console.error('[ai-precio] Unhandled error:', err)
    return jsonResponse({ ok: false, error: extractErrorMessage(err) }, 500)
  }
})
