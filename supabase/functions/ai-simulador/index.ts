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

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized | 401')

    const { scenario } = await req.json()

    // 3. Fetch Context (Current Month)
    const firstDayOfMonth = new Date()
    firstDayOfMonth.setDate(1)
    firstDayOfMonth.setHours(0, 0, 0, 0)

    const [salesResult, expensesResult] = await Promise.all([
      supabaseClient.from('sales').select('amount').gte('date', firstDayOfMonth.toISOString()),
      supabaseClient.from('expenses').select('amount').gte('date', firstDayOfMonth.toISOString())
    ])

    const totalSales = (salesResult.data || []).reduce((acc: number, s: any) => acc + Number(s.amount), 0)
    const totalExpenses = (expensesResult.data || []).reduce((acc: number, e: any) => acc + Number(e.amount), 0)

    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    let content = ''

    if (!openAiKey) {
      throw new Error('Configuración incompleta: Falta la clave de API de OpenAI | 500')
    } else {
      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${openAiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          messages: [
            { role: 'system', content: 'Eres un simulador de estrategias de negocio. Analiza el impacto del escenario propuesto basándote en los números actuales del usuario.' },
            { role: 'user', content: `Escenario: ${scenario}. Datos actuales del mes: Ventas $${totalSales}, Gastos $${totalExpenses}.` }
          ]
        }),
      })

      const aiData = await response.json()
      content = aiData.choices?.[0]?.message?.content || 'Simulación generada.'
    }

    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'simulation',
      p_content: content,
      p_source_function: 'ai-simulador'
    })

    if (rpcError) {
      if (rpcError.code === 'insufficient_privilege') throw new Error(`${rpcError.message} | 403`)
      throw new Error(`${rpcError.message} | 500`)
    }

    return new Response(JSON.stringify(insight), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 })
  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : 'Unknown error'
    const parts = errorMsg.split(' | ')
    const status = parts.length > 1 ? parseInt(parts[1], 10) : 400
    return new Response(JSON.stringify({ error: parts[0] }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: status })
  }
})
