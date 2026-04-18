import { NextResponse } from 'next/server'
import { aiCopilotService } from '@/lib/services/aiCopilotService'
import { createClient } from '@/lib/supabase/server'

// ─── Helpers ────────────────────────────────────────────────────────────────

const AI_TIMEOUT_MS = 8000
const MAX_QUESTION_LENGTH = 1000

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
    // Phase 7 – Input validation
    const body = await req.json().catch(() => ({}))
    const { question } = body

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

    // 1. Business context
    const context = await aiCopilotService.getBusinessDataContext(supabase)
    console.log('[Copilot] Business context loaded, products:', context.topProducts.length)

    // 2. Pricing analysis (pure local logic – no external call)
    const pricingAnalysis = aiCopilotService.analyzePricingInQuestion(sanitizedQuestion)

    // 3. Build prompt
    let prompt = `Eres un experto asesor de negocios para pequeños emprendedores.
El usuario tiene un pequeño negocio y vende productos.
Da consejos claros y prácticos. Sé conciso y accionable.

CONTEXTO DEL NEGOCIO:
- Productos destacados (Top 5): ${JSON.stringify(context.topProducts)}
- Ventas totales recientes: ${context.totalSalesRecent}
- Alerta Stock Bajo: ${context.recentLowStock.join(', ') || 'Ninguna'}
- Gastos recientes: ${context.recentExpenses.length} registros
`

    if (pricingAnalysis?.suggestions) {
      prompt += `
PRICING SUGGESTED:
- Costo detectado: $${pricingAnalysis.cost}
- 30% margen -> $${pricingAnalysis.suggestions.margins[0].price}
- 40% margen -> $${pricingAnalysis.suggestions.margins[1].price}
- 50% margen -> $${pricingAnalysis.suggestions.margins[2].price}
- Recomendación: ${pricingAnalysis.suggestions.recommendation}
`
    }

    prompt += `\nPREGUNTA DEL USUARIO:\n"${sanitizedQuestion}"\n\nResponde como un asesor experto, breve y accionable.`

    // 4. OpenAI call with timeout + retry
    console.log('[Copilot] Calling OpenAI...')
    const openAiKey = process.env.OPENAI_API_KEY
    if (!openAiKey) {
      console.error('[Copilot] OPENAI_API_KEY is not set in environment')
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
              { role: 'system', content: 'Eres un asesor de negocios experto.' },
              { role: 'user', content: prompt }
            ],
            temperature: 0.7,
            max_tokens: 500,
          }),
        }
      )

      console.log('[Copilot] OpenAI response status:', response.status)

      if (!response.ok) {
        const errBody = await response.json().catch(() => ({}))
        console.error('[Copilot] OpenAI error FULL:', JSON.stringify(errBody))
        return NextResponse.json(
          { ok: false, error: `OpenAI error ${response.status}: ${errBody?.error?.message || errBody?.error?.code || JSON.stringify(errBody)}` },
          { status: 502 }
        )
      }

      const aiData = await response.json()
      answer = aiData.choices?.[0]?.message?.content ?? ''

      if (!answer) {
        throw new Error('Empty AI response')
      }
    } catch (aiErr: any) {
      const isTimeout = aiErr.name === 'AbortError'
      console.error('[Copilot] AI call failed FULL:', isTimeout ? 'TIMEOUT' : aiErr)
      return NextResponse.json(
        { ok: false, error: isTimeout ? 'OpenAI timeout (>8s)' : (aiErr.message || String(aiErr)) },
        { status: 502 }
      )
    }

    // 5. Persist conversation (non-blocking – failure doesn't affect response)
    aiCopilotService.saveConversation(supabase, sanitizedQuestion, answer).catch((saveErr: any) => {
      console.error('[Copilot] Failed to save conversation:', saveErr.message)
    })

    console.log('[Copilot] Success, answer length:', answer.length)
    return NextResponse.json({ ok: true, answer })

  } catch (error: any) {
    console.error('[Copilot] Unhandled error FULL:', error)
    return NextResponse.json(
      { ok: false, error: error?.message || JSON.stringify(error) || 'Unknown error' },
      { status: 500 }
    )
  }
}
