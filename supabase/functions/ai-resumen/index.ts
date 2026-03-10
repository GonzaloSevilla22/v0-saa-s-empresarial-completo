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

    const { period } = await req.json()

    // 3. Fetch Data based on Period
    const now = new Date()
    let startDate = new Date()
    if (period === 'weekly') startDate.setDate(now.getDate() - 7)
    else if (period === 'monthly') startDate.setMonth(now.getMonth() - 1)
    else startDate.setDate(now.getDate() - 1) // daily default

    const [salesResult, expensesResult] = await Promise.all([
      supabaseClient.from('sales').select('amount').gte('date', startDate.toISOString()),
      supabaseClient.from('expenses').select('amount').gte('date', startDate.toISOString())
    ])

    const totalSales = (salesResult.data || []).reduce((acc: number, s: any) => acc + Number(s.amount), 0)
    const totalExpenses = (expensesResult.data || []).reduce((acc: number, e: any) => acc + Number(e.amount), 0)
    const balance = totalSales - totalExpenses

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
            { role: 'system', content: 'Eres un asistente financiero profesional. Resume el periodo financiero basándote en los números provistos. Sé breve y directo.' },
            { role: 'user', content: `Resumen para el periodo ${period}: Ventas totales $${totalSales}, Gastos totales $${totalExpenses}, Balance neto $${balance}.` }
          ]
        }),
      })

      const aiData = await response.json()
      content = aiData.choices?.[0]?.message?.content || 'Resumen generado.'
    }

    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'general',
      p_content: content,
      p_source_function: 'ai-resumen'
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
