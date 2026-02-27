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
    if (userError || !user) throw new Error('Unauthorized')

    // 2. Fetch Profile & Check limits
    const { data: profile, error: profileError } = await supabaseClient
      .from('profiles')
      .select('plan, insights_used, insights_reset_at')
      .eq('id', user.id)
      .single()

    if (profileError || !profile) throw new Error('Profile not found')

    // If it's a new month, we should reset insights_used. (For simplicity here, we assume a cron or trigger handles this, or we check date diff).
    if (profile.plan === 'free' && profile.insights_used >= 5) {
      throw new Error('Limit reached: MAX_INSIGHTS_MONTH is 5 for free plan')
    }

    // 3. Get Data (Sales, Expenses for the last 3 months)
    const threeMonthsAgo = new Date()
    threeMonthsAgo.setMonth(threeMonthsAgo.getMonth() - 3)

    const [salesResult, expensesResult] = await Promise.all([
      supabaseClient.from('sales').select('amount, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('expenses').select('amount, category, date').gte('date', threeMonthsAgo.toISOString())
    ])

    const sales = salesResult.data || []
    const expenses = expensesResult.data || []

    const prompt = `Analiza los siguientes datos de los últimos 3 meses y dame 1 insight accionable corto:
    Ventas: ${JSON.stringify(sales)}
    Gastos: ${JSON.stringify(expenses)}`

    // 4. Call OpenAI API directly
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) throw new Error('OpenAI key configured incorrectly')

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
    const content = aiData.choices?.[0]?.message?.content || 'No se pudo generar insight'

    // 5. Persist Insight
    const { data: insight, error: insightError } = await supabaseClient
      .from('insights')
      .insert({
        user_id: user.id,
        type: 'general',
        content: content,
        actionable: 'actionable_extracted_from_content'
      })
      .select()
      .single()

    if (insightError) throw insightError

    // Increment usage
    await supabaseClient
      .from('profiles')
      .update({ insights_used: profile.insights_used + 1 })
      .eq('id', user.id)

    // Fire AARRR Event (UMV reached!)
    await supabaseClient.from('analytics_events').insert({
      user_id: user.id,
      event_name: 'umv_reached',
      event_data: { type: 'insight_generated', insight_id: insight.id }
    })

    return new Response(JSON.stringify(insight), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
