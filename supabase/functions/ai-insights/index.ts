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

    // 3. Get Data (Sales, Expenses, Low Stock, Top Clients)
    const [salesResult, expensesResult, stockResult, clientsResult] = await Promise.all([
      supabaseClient.from('sales').select('amount, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('expenses').select('amount, category, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('products').select('name, stock').lt('stock', 5).limit(5),
      supabaseClient.from('clients').select('name, id').limit(5)
    ])

    const sales = salesResult.data || []
    const expenses = expensesResult.data || []
    const lowStock = stockResult.data || []
    const clients = clientsResult.data || []

    const prompt = `Analiza estos datos de mi negocio:
    - Ventas recientes: ${sales.length} transacciones.
    - Gastos recientes: ${expenses.length} registros.
    - Stock bajo (< 5 unidades): ${lowStock.map(p => `${p.name} (${p.stock})`).join(', ') || 'Todo en orden'}.
    - Clientes principales (muestra): ${clients.map(c => c.name).join(', ')}.
    
    Dame 1 insight accionable corto.`

    // 4. Call OpenAI API or Data-driven Fallback
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    let content = ''

    if (!openAiKey) {
      if (lowStock.length > 0) {
        content = `Alerta de Stock: Tenés poco stock de ${lowStock[0].name}. Considerá reponer pronto.`
      } else if (sales.length > 0) {
        content = `Tus ventas están activas con ${sales.length} operaciones recientes. ¡Buen trabajo!`
      } else {
        content = "Tu negocio está en marcha. Registra más ventas para obtener mejores consejos."
      }
    } else {
      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${openAiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          messages: [{ role: 'system', content: 'Eres un analista financiero experto para emprendedores. Responde con un análisis corto y una acción específica.' }, { role: 'user', content: prompt }]
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
