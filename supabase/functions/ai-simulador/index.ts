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

    const { scenario_details } = await req.json()
    
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
        messages: [{ role: 'system', content: 'Simula el impacto de una decisión de negocio.' }, { role: 'user', content: `Simula lo siguiente: ${scenario_details}` }]
      }),
    })

    const aiData = await response.json()
    const content = aiData.choices?.[0]?.message?.content || 'Simulación generada.'

    // Atomic Postgres RPC handles limits, locking, telemetry and insertion securely
    const { data: insight, error: rpcError } = await supabaseClient.rpc('rpc_atomic_log_ai_insight', {
      p_user_id: user.id,
      p_type: 'simulation',
      p_content: content,
      p_source_function: 'ai-simulador'
    })

    if (rpcError) {
      if (rpcError.code === 'insufficient_privilege') throw new Error(`${rpcError.message} | 403`)
      if (rpcError.code === 'no_data_found') throw new Error(`${rpcError.message} | 404`)
      throw new Error(`${rpcError.message} | 500`)
    }

    return new Response(JSON.stringify(insight), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 })
  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : 'Unknown error'
    const parts = errorMsg.split(' | ')
    const status = parts.length > 1 ? parseInt(parts[1], 10) : 400
    const msg = parts[0]

    return new Response(JSON.stringify({ error: msg }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: status })
  }
})
