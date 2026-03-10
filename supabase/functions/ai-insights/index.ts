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

    // 3. Get Data (Sales, Products/Inventory, Expenses, Top Clients)
    const [salesResult, productsResult, expensesResult, clientsResult] = await Promise.all([
      supabaseClient.from('sales').select('amount, quantity, date, product_id').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('products').select('id, name, stock, cost, price'),
      supabaseClient.from('expenses').select('amount, category, date').gte('date', threeMonthsAgo.toISOString()),
      supabaseClient.from('clients').select('name, id').limit(5)
    ])

    const sales = salesResult.data || []
    const products = productsResult.data || []
    const expenses = expensesResult.data || []
    const clients = clientsResult.data || []

    // Calculate some basic stats for the prompt
    const lowStock = products.filter(p => p.stock < 5)
    const lowMargin = products.filter(p => p.price > 0 && ((p.price - p.cost) / p.price) < 0.2)

    const prompt = `Analiza estos datos de mi negocio y genera 3 insights accionables.
    DATOS:
    - Ventas recientes: ${sales.length} transacciones.
    - Gastos recientes: ${expenses.length} registros.
    - Inventario Total: ${products.length} productos.
    - Stock bajo (< 5 unidades): ${lowStock.map(p => `${p.name} (${p.stock})`).join(', ') || 'Todo en orden'}.
    - Margen bajo (< 20%): ${lowMargin.map(p => p.name).join(', ') || 'Todo en orden'}.
    - Clientes principales (muestra): ${clients.map(c => c.name).join(', ')}.
    
    INSTRUCCIONES:
    - Devuelve un array JSON de objetos con estos campos: 
      - type: "ventas" | "stock" | "margen" | "producto" | "marketing"
      - priority: "alta" | "media" | "baja"
      - message: string (consejo corto y accionable en español)
    - Enfócate en tendencias, riesgos de stock y rentabilidad.
    - No incluyas explicaciones fuera del JSON.
    - Devuelve SOLO el array JSON.`

    // 4. Call OpenAI API
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) {
      throw new Error('Configuración incompleta: Falta la clave de API de OpenAI | 500')
    }

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${openAiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          { role: 'system', content: 'Eres un analista financiero experto. Generas insights estructurados en JSON.' },
          { role: 'user', content: prompt }
        ],
        response_format: { type: "json_object" }
      }),
    })

    const aiData = await response.json()
    const contentText = aiData.choices?.[0]?.message?.content || '{"insights": []}'
    
    let insightsData;
    try {
      const parsed = JSON.parse(contentText);
      insightsData = Array.isArray(parsed) ? parsed : (parsed.insights || []);
    } catch (e) {
      console.error("Error parsing AI JSON:", e);
      insightsData = [];
    }

    // 5. Save to database (Directly to ai_insights table)
    const insightsToInsert = insightsData.map((ins: any) => ({
      user_id: user.id,
      type: ins.type || 'general',
      priority: ins.priority || 'media',
      message: ins.message || 'Sin mensaje'
    }))

    if (insightsToInsert.length > 0) {
      const { error: insertError } = await supabaseClient
        .from('ai_insights')
        .insert(insightsToInsert)

      if (insertError) throw insertError
    }

    return new Response(JSON.stringify({ success: true, count: insightsToInsert.length }), {
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
