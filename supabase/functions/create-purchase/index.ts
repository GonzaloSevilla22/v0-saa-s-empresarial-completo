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

    // 1. Validate Session
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) throw new Error('Unauthorized')

    // 2. Parse Payload
    const { product_id, amount, quantity, date } = await req.json()
    if (!product_id || !amount) throw new Error('Missing required fields')

    // 3. Data Integrity & Ownership check
    const { data: product, error: productError } = await supabaseClient
      .from('products')
      .select('id, stock')
      .eq('id', product_id)
      .single()

    if (productError || !product) throw new Error('Product not found or access denied')

    // 4. Create Purchase
    const { data: purchase, error: purchaseError } = await supabaseClient
      .from('purchases')
      .insert({
        user_id: user.id,
        product_id: product_id,
        amount: amount,
        quantity: quantity || 1,
        date: date || new Date().toISOString()
      })
      .select()
      .single()

    if (purchaseError) throw purchaseError

    // Add stock
    await supabaseClient
      .from('products')
      .update({ stock: product.stock + (quantity || 1) })
      .eq('id', product_id)

    // Fire AARRR event
    await supabaseClient.from('analytics_events').insert({
      user_id: user.id,
      event_name: 'operation_created',
      event_data: { type: 'purchase', purchase_id: purchase.id }
    })

    // Check if it's the first operation
    const { data: existingFirstOp } = await supabaseClient
      .from('analytics_events')
      .select('id')
      .eq('user_id', user.id)
      .eq('event_name', 'first_operation')
      .limit(1)
      .maybeSingle()

    if (!existingFirstOp) {
      await supabaseClient.from('analytics_events').insert({
        user_id: user.id,
        event_name: 'first_operation',
        event_data: { type: 'purchase', purchase_id: purchase.id }
      })
    }

    return new Response(JSON.stringify(purchase), {
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
