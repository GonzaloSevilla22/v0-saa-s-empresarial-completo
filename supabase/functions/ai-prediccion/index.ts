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
    if (userError || !user) throw new Error('Unauthorized')

    const { data: profile } = await supabaseClient.from('profiles').select('*').eq('id', user.id).single()
    if (profile?.plan === 'free' && profile.insights_used >= 5) {
      throw new Error('Limit reached: MAX_INSIGHTS_MONTH is 5 for free plan')
    }

    const { days_ahead } = await req.json()
    
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) throw new Error('OpenAI key required')

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${openAiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [{ role: 'system', content: 'Predice ventas futuras basadas en histórico.' }, { role: 'user', content: `Predice para los próximos ${days_ahead} días.` }]
      }),
    })

    const aiData = await response.json()
    const content = aiData.choices?.[0]?.message?.content || 'Predicción generada.'

    // Persist
    const { data: insight, error: insightError } = await supabaseClient
      .from('insights')
      .insert({ user_id: user.id, type: 'prediction', content: content, actionable: 'Preparar stock' })
      .select().single()

    if (insightError) throw insightError

    return new Response(JSON.stringify(insight), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 })
  }
})
