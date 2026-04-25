import { NextResponse } from 'next/server'
import { aiCopilotService } from '@/lib/services/aiCopilotService'
import { createClient } from '@/lib/supabase/server'

// ─── Helpers ────────────────────────────────────────────────────────────────

const AI_TIMEOUT_MS = 12000   // bumped from 8s — richer context query takes longer
const MAX_QUESTION_LENGTH = 1000
const MAX_HISTORY_TURNS = 6   // last 3 exchanges (user + assistant pairs)

/** Fetch wrapper with abort-based timeout and up to `retries` retries. */
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
  } catch (err: any) {
    clearTimeout(timer)
    if (retries > 0 && err.name !== 'AbortError') {
      console.warn('[Copilot] Retrying OpenAI call, retries left:', retries - 1)
      return fetchWithTimeout(url, options, retries - 1)
    }
    throw err
  }
}

// ─── Route handler ───────────────────────────────────────────────────────────

export async function POST(req: Request) {
  console.log('[Copilot] Request received')

  try {
    // ── Input validation ─────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}))
    const { question, history } = body

    if (!question || typeof question !== 'string' || question.trim().length === 0) {
      return NextResponse.json({ ok: false, error: 'Pregunta es requerida' }, { status: 400 })
    }

    if (question.length > MAX_QUESTION_LENGTH) {
      return NextResponse.json(
        { ok: false, error: `La pregunta no puede superar ${MAX_QUESTION_LENGTH} caracteres` },
        { status: 400 }
      )
    }

    const sanitizedQuestion = question.trim()
    console.log('[Copilot] Processing question, length:', sanitizedQuestion.length)

    const supabase = createClient()

    // ── Business context ─────────────────────────────────────────────────────
    const ctx = await aiCopilotService.getBusinessDataContext(supabase)
    console.log('[Copilot] Business context loaded, topProducts:', ctx.topProducts.length)

    // ── Pricing analysis (pure local logic – no external call) ───────────────
    const pricingAnalysis = aiCopilotService.analyzePricingInQuestion(sanitizedQuestion)

    // ── System prompt with rich ERP context ─────────────────────────────────
    const systemPrompt = `Eres ALIADATA Copilot, el asesor de negocios de un pequeño emprendedor argentino.
Tu trabajo es dar consejos claros, concretos y accionables basados EXCLUSIVAMENTE en los datos reales del negocio.
No inventes datos. Si no tenés información suficiente, decilo y pedí que el usuario te aporte más contexto.
Respondé siempre en español rioplatense, de forma directa y sin relleno.`

    const contextBlock = `
DATOS REALES DEL NEGOCIO (${ctx.period}):
- Ingresos por ventas: $${ctx.totalRevenue.toLocaleString()}
- Gastos operativos: $${ctx.totalExpenses.toLocaleString()}
- Compras / Abastecimiento: $${ctx.totalPurchases.toLocaleString()}
- Resultado neto: $${ctx.netProfit.toLocaleString()} (${ctx.netProfit >= 0 ? 'ganancia' : 'pérdida'})

TOP PRODUCTOS POR FACTURACIÓN:
${ctx.topProducts.length > 0
  ? ctx.topProducts.map(p => `  • ${p.name}: ${p.units} uds — $${p.revenue.toLocaleString()}`).join('\n')
  : '  Sin datos de ventas en el período'}

GASTOS POR CATEGORÍA:
${ctx.topExpenseCategories.length > 0 ? ctx.topExpenseCategories.map(c => `  • ${c}`).join('\n') : '  Sin gastos registrados'}

ALERTAS DE STOCK:
${ctx.lowStockProducts.length > 0 ? ctx.lowStockProducts.map(p => `  • ${p}`).join('\n') : '  Todo el stock está en orden'}

PRODUCTOS CON ALTO MARGEN (oportunidad):
${ctx.highMarginProducts.length > 0 ? ctx.highMarginProducts.map(p => `  • ${p}`).join('\n') : '  Sin productos de alto margen detectados'}

Catálogo total: ${ctx.totalProductCount} productos`

    // ── Optional pricing context ─────────────────────────────────────────────
    const pricingBlock = pricingAnalysis?.suggestions
      ? `
ANÁLISIS DE PRECIOS DETECTADO:
- Costo informado: $${pricingAnalysis.cost}
- Precio con margen 30%: $${pricingAnalysis.suggestions.margins[0].price}
- Precio con margen 40%: $${pricingAnalysis.suggestions.margins[1].price}
- Precio con margen 50%: $${pricingAnalysis.suggestions.margins[2].price}
- Consejo: ${pricingAnalysis.suggestions.recommendation}`
      : ''

    const userPrompt = `${contextBlock}${pricingBlock}

PREGUNTA DEL USUARIO:
"${sanitizedQuestion}"

Respondé de forma directa, breve y accionable. Si podés dar un número o acción concreta, dalo.`

    // ── Conversation history (last N turns for memory) ───────────────────────
    // history is an array of { role: 'user'|'assistant', content: string }
    const validHistory: Array<{ role: 'user' | 'assistant'; content: string }> = []
    if (Array.isArray(history)) {
      for (const msg of history.slice(-MAX_HISTORY_TURNS)) {
        if (
          msg &&
          typeof msg.content === 'string' &&
          (msg.role === 'user' || msg.role === 'assistant')
        ) {
          validHistory.push({ role: msg.role, content: msg.content.slice(0, 500) })
        }
      }
    }

    // ── OpenAI call ──────────────────────────────────────────────────────────
    console.log('[Copilot] Calling OpenAI, history turns:', validHistory.length)
    const openAiKey = process.env.OPENAI_API_KEY
    if (!openAiKey) {
      console.error('[Copilot] OPENAI_API_KEY is not set')
      return NextResponse.json(
        { ok: false, error: 'Missing OPENAI_API_KEY — configure it in Vercel environment variables' },
        { status: 500 }
      )
    }

    let answer: string

    try {
      const response = await fetchWithTimeout(
        'https://api.openai.com/v1/chat/completions',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${openAiKey}`,
          },
          body: JSON.stringify({
            model: 'gpt-4o-mini',
            messages: [
              { role: 'system', content: systemPrompt },
              // Include recent conversation turns for memory
              ...validHistory,
              { role: 'user', content: userPrompt },
            ],
            temperature: 0.6,   // slightly lower for more consistent/factual answers
            max_tokens: 600,    // bumped from 500 — context is richer
          }),
        }
      )

      console.log('[Copilot] OpenAI response status:', response.status)

      if (!response.ok) {
        const errBody = await response.json().catch(() => ({}))
        console.error('[Copilot] OpenAI error:', JSON.stringify(errBody))
        return NextResponse.json(
          { ok: false, error: `OpenAI error ${response.status}: ${errBody?.error?.message || errBody?.error?.code || JSON.stringify(errBody)}` },
          { status: 502 }
        )
      }

      const aiData = await response.json()
      answer = aiData.choices?.[0]?.message?.content ?? ''

      if (!answer) throw new Error('Empty AI response')

    } catch (aiErr: any) {
      const isTimeout = aiErr.name === 'AbortError'
      console.error('[Copilot] AI call failed:', isTimeout ? 'TIMEOUT' : aiErr)
      return NextResponse.json(
        { ok: false, error: isTimeout ? 'OpenAI timeout (>12s)' : (aiErr.message || String(aiErr)) },
        { status: 502 }
      )
    }

    // ── Persist conversation (non-blocking) ──────────────────────────────────
    aiCopilotService.saveConversation(supabase, sanitizedQuestion, answer).catch((err: any) => {
      console.error('[Copilot] Failed to save conversation:', err.message)
    })

    console.log('[Copilot] Success, answer length:', answer.length)
    return NextResponse.json({ ok: true, answer })

  } catch (error: any) {
    console.error('[Copilot] Unhandled error:', error)
    return NextResponse.json(
      { ok: false, error: error?.message || JSON.stringify(error) || 'Unknown error' },
      { status: 500 }
    )
  }
}
