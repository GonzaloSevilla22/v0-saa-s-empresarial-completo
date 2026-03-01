import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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

    // 1. Session check
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized | 401')

    // 2. Setup parameters for AI request context
    const threeMonthsAgo = new Date()
    threeMonthsAgo.setMonth(threeMonthsAgo.getMonth() - 3)

    // 3. Get Data (Sales, Expenses for the last 3 months)
    const [salesResult, expensesResult] = await Promise.all([
      supabaseClient.from('sales').select('amount, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('expenses').select('amount, category, date').gte('date', threeMonthsAgo.toISOString())
    ])

    const sales = salesResult.data || []
    const expenses = expensesResult.data || []

    const prompt = `Analiza los siguientes datos de los últimos 3 meses y dame 1 insight accionable corto:
    Ventas: ${JSON.stringify(sales)}
    Gastos: ${JSON.stringify(expenses)}`

    // 4. Call OpenAI API or Mock Fallback
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    let content = ''

    if (!openAiKey) {
      // Mock result for local development "wow" factor
      const mocks = [
        "Tus ventas han subido un 12% este mes. Considerá aumentar el stock de productos de electrónica.",
        "Detectamos un gasto inusual en logística. Podrías ahorrar un 5% renegociando con tu proveedor.",
        "Tus clientes más leales compran cada 15 días. Una promo de fidelidad podría aumentar tu frecuencia de venta."
      ]
      content = "[MOCK AI] " + mocks[Math.floor(Math.random() * mocks.length)]
    } else {
      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${openAiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          messages: [{ role: 'system', content: 'Eres un analista financiero experto para emprendedores pequeños. Responde con un análisis corto y una acción específica recomendada.' }, { role: 'user', content: prompt }]
        }),
      })

      const aiData = await response.json()
      content = aiData.choices?.[0]?.message?.content || 'No se pudo generar insight'
    }

    // 5. Atomic Postgres RPC handles limits, locking, telemetry and insertion securely
    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'general',
      p_content: content,
      p_source_function: 'ai-insights'
    })

    if (rpcError) {
      if (rpcError.code === 'insufficient_privilege') throw new Error(`${rpcError.message} | 403`)
      if (rpcError.code === 'no_data_found') throw new Error(`${rpcError.message} | 404`)
      throw new Error(`${rpcError.message} | 500`)
    }

    return new Response(JSON.stringify(insight), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : 'Unknown error'
    const parts = errorMsg.split(' | ')
    const status = parts.length > 1 ? parseInt(parts[1], 10) : 400
    const msg = parts[0]

    return new Response(JSON.stringify({ error: msg }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: status,
    })
  }
})
