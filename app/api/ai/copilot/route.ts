import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import {
  buildBusinessSnapshot,
  buildAdaptiveContext,
  AI_SYSTEM_PROMPT,
} from '@/lib/ai/buildBusinessSnapshot'
import { aiCopilotService } from '@/lib/services/aiCopilotService'

// ─── Config ──────────────────────────────────────────────────────────────────

const AI_TIMEOUT_MS     = 12_000
const MAX_QUESTION_LEN  = 1_000
const MAX_HISTORY_TURNS = 6

// ─── Helpers ─────────────────────────────────────────────────────────────────

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
    // ── Validación ────────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}))
    const { question, history } = body

    if (!question || typeof question !== 'string' || !question.trim()) {
      return NextResponse.json({ ok: false, error: 'Pregunta es requerida' }, { status: 400 })
    }
    if (question.length > MAX_QUESTION_LEN) {
      return NextResponse.json(
        { ok: false, error: `La pregunta no puede superar ${MAX_QUESTION_LEN} caracteres` },
        { status: 400 }
      )
    }

    const sanitized = question.trim()

    // ── OpenAI key ────────────────────────────────────────────────────────────
    const openAiKey = process.env.OPENAI_API_KEY
    if (!openAiKey) {
      console.error('[Copilot] OPENAI_API_KEY is not set in Vercel')
      return NextResponse.json(
        { ok: false, error: 'Missing OPENAI_API_KEY — configure it in Vercel environment variables' },
        { status: 500 }
      )
    }

    const supabase = createClient()

    // ── Snapshot de negocio (pre-calcula métricas server-side) ───────────────
    const snapshot = await buildBusinessSnapshot(supabase)
    console.log('[Copilot] Snapshot built, top products:', snapshot.productos.top_rentables.length)

    // ── Contexto adaptativo (solo lo relevante para la pregunta) ─────────────
    const context = buildAdaptiveContext(snapshot, sanitized)

    // ── Pricing analysis local (sin llamada extra a la IA) ───────────────────
    const pricingAnalysis = aiCopilotService.analyzePricingInQuestion(sanitized)
    const pricingBlock = pricingAnalysis?.suggestions
      ? `\nANÁLISIS DE PRECIOS:\n- Costo: $${pricingAnalysis.cost} | Margen 30%: $${pricingAnalysis.suggestions.margins[0].price} | 40%: $${pricingAnalysis.suggestions.margins[1].price} | 50%: $${pricingAnalysis.suggestions.margins[2].price}`
      : ''

    // ── Historial de conversación ─────────────────────────────────────────────
    const validHistory: Array<{ role: 'user' | 'assistant'; content: string }> = []
    if (Array.isArray(history)) {
      for (const msg of history.slice(-MAX_HISTORY_TURNS)) {
        if (msg && typeof msg.content === 'string' && (msg.role === 'user' || msg.role === 'assistant')) {
          validHistory.push({ role: msg.role, content: msg.content.slice(0, 500) })
        }
      }
    }

    // ── User prompt ───────────────────────────────────────────────────────────
    const userPrompt =
`${context}${pricingBlock}

PREGUNTA: "${sanitized}"

Respondé directo y accionable. Si podés dar un número concreto o una acción específica para HOY, dala.`

    // ── Llamada a OpenAI ──────────────────────────────────────────────────────
    console.log('[Copilot] Calling OpenAI, history turns:', validHistory.length)

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
              { role: 'system',    content: AI_SYSTEM_PROMPT },
              ...validHistory,
              { role: 'user',      content: userPrompt },
            ],
            temperature: 0.5,
            max_tokens:  600,
          }),
        }
      )

      console.log('[Copilot] OpenAI status:', response.status)

      if (!response.ok) {
        const errBody = await response.json().catch(() => ({}))
        console.error('[Copilot] OpenAI error:', JSON.stringify(errBody))
        return NextResponse.json(
          { ok: false, error: `OpenAI error ${response.status}: ${errBody?.error?.message || JSON.stringify(errBody)}` },
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

    // ── Persistir conversación (no bloquea la respuesta) ─────────────────────
    aiCopilotService.saveConversation(supabase, sanitized, answer).catch((err: any) => {
      console.error('[Copilot] Failed to save conversation:', err.message)
    })

    console.log('[Copilot] Success, answer length:', answer.length)
    return NextResponse.json({ ok: true, answer })

  } catch (error: any) {
    console.error('[Copilot] Unhandled error:', error)
    return NextResponse.json(
      { ok: false, error: error?.message || 'Unknown error' },
      { status: 500 }
    )
  }
}
