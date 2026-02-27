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

    // 1. Get User Session
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    // 2. Parse payload
    const { client_id, product_id, amount, quantity, date } = await req.json()
    if (!product_id || !amount) throw new Error('Missing required fields')

    // 3. User & Plan limits check (Zero Trust Validation Server-side)
    // - A user has a max limit of 20 products for free plan. Though this is for products, 
    //   for create-sale we could check if they have reached the limit of sales per month for a free plan if applicable.
    // For this MVP, we enforce basic data integrity.

    // Get the product to adjust stock and check ownership
    const { data: product, error: productError } = await supabaseClient
      .from('products')
      .select('id, stock')
      .eq('id', product_id)
      .single()

    if (productError || !product) throw new Error('Product not found or access denied')

    // In a real transactional system we would use a DB function. Here we orchestrate.
    const { data: sale, error: saleError } = await supabaseClient
      .from('sales')
      .insert({
        user_id: user.id,
        client_id: client_id || null,
        product_id: product_id,
        amount: amount,
        quantity: quantity || 1,
        date: date || new Date().toISOString()
      })
      .select()
      .single()

    if (saleError) throw saleError

    // Deduct stock
    await supabaseClient
      .from('products')
      .update({ stock: product.stock - (quantity || 1) })
      .eq('id', product_id)

    // Fire AARRR Analytics Event
    await supabaseClient.from('analytics_events').insert({
      user_id: user.id,
      event_name: 'first_operation_created',
      event_data: { type: 'sale', sale_id: sale.id }
    })

    return new Response(JSON.stringify(sale), {
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
