import { NextResponse } from 'next/server'
import { aiCopilotService } from '@/lib/services/aiCopilotService'

export async function POST(req: Request) {
  try {
    const { question } = await req.json()

    if (!question) {
      return NextResponse.json({ error: "Pregunta es requerida" }, { status: 400 })
    }

    // 1. Get business data context
    const context = await aiCopilotService.getBusinessDataContext()

    // 2. Analyze if it's a pricing query
    const pricingAnalysis = aiCopilotService.analyzePricingInQuestion(question)

    // 3. Prepare the prompt
    let prompt = `
Eres un experto asesor de negocios para pequeños emprendedores.
El usuario tiene un pequeño negocio y vende productos.
Da consejos claros y prácticos. Sé conciso y accionable.

CONTEXTO DEL NEGOCIO:
- Productos destacados (Top 5): ${JSON.stringify(context.topProducts)}
- Ventas totales recientes: ${context.totalSalesRecent}
- Alerta Stock Bajo: ${context.recentLowStock.join(', ')}
- Gastos recientes: ${JSON.stringify(context.recentExpenses)}
`

    if (pricingAnalysis?.suggestions) {
      prompt += `
PRICING SUGGESTED (Usa estos datos si la pregunta es sobre precios):
- Costo detectado: $${pricingAnalysis.cost}
- Rangos sugeridos:
  * 30% margen -> $${pricingAnalysis.suggestions.margins[0].price}
  * 40% margen -> $${pricingAnalysis.suggestions.margins[1].price}
  * 50% margen -> $${pricingAnalysis.suggestions.margins[2].price}
- Recomendación: ${pricingAnalysis.suggestions.recommendation}
`
    }

    prompt += `
PREGUNTA DEL USUARIO:
"${question}"

Responde como un asesor experto. Si la pregunta es sobre precios y margins, usa los datos calculados arriba para dar una respuesta precisa y profesional.
`

    // 3. Call OpenAI
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          { role: 'system', content: 'Eres un asesor de negocios experto.' },
          { role: 'user', content: prompt }
        ],
        temperature: 0.7
      })
    })

    if (!response.ok) {
      const errorData = await response.json()
      console.error("OpenAI Error:", errorData)
      throw new Error("Error al consultar a la IA")
    }

    const aiData = await response.json()
    const answer = aiData.choices[0].message.content

    // 4. Store conversation
    await aiCopilotService.saveConversation(question, answer)

    return NextResponse.json({ answer })
  } catch (error: any) {
    console.error("Copilot API Error:", error)
    return NextResponse.json({ error: error.message || "Error interno" }, { status: 500 })
  }
}
