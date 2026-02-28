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
    
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    let content = ''

    if (!openAiKey) {
      const mocks = [
        "Resumen del día: Ventas estables con un ligero incremento en la tarde. El stock de insumos básicos está en niveles saludables.",
        "Resumen semanal: Gran desempeño en la categoría calzado. Se recomienda monitorear gastos operativos fijos.",
        "Resumen mensual: Cierre de mes con balance positivo. El margen neto se mantuvo por encima del 25%."
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
          messages: [{ role: 'system', content: 'Eres un asistente financiero. Resume el periodo financiero de forma profesional.' }, { role: 'user', content: `Genera un resumen para el periodo ${period}` }]
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
