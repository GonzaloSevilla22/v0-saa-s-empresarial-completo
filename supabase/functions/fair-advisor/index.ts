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

    // 2. Resolve Company Context
    const { data: companyUser, error: coError } = await supabaseClient
      .from('company_users')
      .select('company_id')
      .eq('user_id', user.id)
      .limit(1)
      .single()

    if (coError || !companyUser) throw new Error('No company context found | 403')
    const companyId = companyUser.company_id

    // 3. Get Data (Sales Items, Product Variants/Stock)
    const [salesResult, productsResult] = await Promise.all([
      supabaseClient.from('sale_items')
        .select('quantity, variant_id, sale!inner(date, company_id)')
        .eq('sale.company_id', companyId)
        .order('sale(date)', { ascending: false })
        .limit(500),
      supabaseClient.from('product_variants')
        .select('id, price, cost, product!inner(name, company_id), inventory_stock(quantity)')
        .eq('product.company_id', companyId)
    ])

    const sales = salesResult.data || []
    const products = productsResult.data || []

    // 4. Scoring Logic using new schema
    const productScores = products.map((v: any) => {
      const pSales = sales.filter((s: any) => s.variant_id === v.id)
      const salesCount = pSales.reduce((acc: number, s: any) => acc + (s.quantity || 0), 0)
      const stock = (v.inventory_stock || []).reduce((acc: number, s: any) => acc + (s.quantity || 0), 0)
      const margin = v.price > 0 ? ((v.price - v.cost) / v.price) * 100 : 0
      
      return {
        id: v.id, // variant.id
        name: v.product?.name || 'Producto',
        stock,
        cost: v.cost,
        price: v.price,
        margin: margin.toFixed(1) + '%',
        salesVolume: salesCount,
        score: salesCount + (margin / 10) + (stock > 0 ? 5 : 0)
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
