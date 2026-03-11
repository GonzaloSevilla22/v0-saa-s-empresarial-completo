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

    // 2. Resolve Company Context
    const { data: companyUser, error: coError } = await supabaseClient
      .from('company_users')
      .select('company_id')
      .eq('user_id', user.id)
      .limit(1)
      .single()

    if (coError || !companyUser) throw new Error('No company context found | 403')
    const companyId = companyUser.company_id

    const { days_ahead } = await req.json()

    // 3. Fetch Historical Data (Last 30 days)
    const thirtyDaysAgo = new Date()
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)

    const { data: sales, error: salesError } = await supabaseClient
      .from('sale_items')
      .select('subtotal, sale!inner(date, company_id)')
      .eq('sale.company_id', companyId)
      .gte('sale.date', thirtyDaysAgo.toISOString())
      .order('sale(date)', { ascending: true })

    const totalSales = (sales || []).reduce((acc: number, s: any) => acc + Number(s.subtotal), 0)
    const avgDailySales = (sales && sales.length > 0) ? totalSales / 30 : 0

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
            { role: 'system', content: 'Eres un experto en predicción de ventas. Analiza el historial provisto y predice la tendencia para los próximos días.' },
            { role: 'user', content: `Historial de ventas (30 días): ${JSON.stringify(sales)}. Predice para los próximos ${days_ahead} días.` }
          ]
        }),
      })

      const aiData = await response.json()
      content = aiData.choices?.[0]?.message?.content || 'Predicción generada.'
    }

    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'prediction',
      p_content: content,
      p_source_function: 'ai-prediccion'
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
