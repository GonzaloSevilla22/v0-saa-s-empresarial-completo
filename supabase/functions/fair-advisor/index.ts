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

    // 2. Get Data
    const [salesResult, productsResult] = await Promise.all([
      supabaseClient.from('sales').select('quantity, product_id, date').order('date', { ascending: false }).limit(200),
      supabaseClient.from('products').select('id, name, stock, cost, price')
    ])

    const sales = salesResult.data || []
    const products = productsResult.data || []

    // 3. Simple Scoring Logic in Edge (to help AI see trends)
    const productScores = products.map(p => {
      const pSales = sales.filter(s => s.product_id === p.id)
      const salesCount = pSales.reduce((acc, s) => acc + s.quantity, 0)
      const margin = p.price > 0 ? ((p.price - p.cost) / p.price) * 100 : 0
      
      return {
        id: p.id,
        name: p.name,
        stock: p.stock,
        cost: p.cost,
        price: p.price,
        margin: margin.toFixed(1) + '%',
        salesVolume: salesCount,
        score: salesCount + (margin / 10) + (p.stock > 0 ? 5 : 0) // Basic scoring
      }
    }).sort((a, b) => b.score - a.score)

    const prompt = `Analiza los siguientes productos de mi negocio y genera recomendaciones específicas para una feria de emprendedores.
    
    PRODUCTOS (Ordenados por relevancia sugerida):
    ${JSON.stringify(productScores.slice(0, 15), null, 2)}
    
    INSTRUCCIONES:
    - Selecciona entre 3 y 5 productos ideales para llevar a la feria.
    - Para cada producto, explica por qué es buena idea (basado en margen, stock o rotación).
    - Sugiere cuántas unidades llevar (considerando el stock actual).
    - Sugiere un precio de venta para la feria (puede ser el mismo o una oferta ligera).
    
    FORMATO DE RESPUESTA:
    - Devuelve un array JSON de objetos con estos campos:
      - product: (nombre del producto)
      - reason: (breve razón de por qué llevarlo)
      - recommendedUnits: (número entero)
      - suggestedPrice: (número entero)
    
    - No incluyas texto fuera del JSON.
    - Responde SOLO el array JSON.`

    // 4. Call OpenAI
    const openAiKey = Deno.env.get('OPENAI_API_KEY')
    if (!openAiKey) throw new Error('OpenAI key missing | 500')

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${openAiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          { role: 'system', content: 'Eres un experto asesor de ventas en eventos y ferias.' },
          { role: 'user', content: prompt }
        ],
        response_format: { type: "json_object" }
      }),
    })

    const aiData = await response.json()
    const contentText = aiData.choices?.[0]?.message?.content || '{"recommendations": []}'
    
    let recommendations;
    try {
      const parsed = JSON.parse(contentText);
      recommendations = Array.isArray(parsed) ? parsed : (parsed.recommendations || []);
    } catch (e) {
      console.error("Error parsing AI JSON:", e);
      recommendations = [];
    }

    // 5. Save to database
    if (recommendations.length > 0) {
      const { error: insertError } = await supabaseClient
        .from('fair_recommendations')
        .insert({
          user_id: user.id,
          recommendation: recommendations
        })

      if (insertError) throw insertError
    }

    return new Response(JSON.stringify(recommendations), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : 'Unknown error'
    return new Response(JSON.stringify({ error: errorMsg }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
