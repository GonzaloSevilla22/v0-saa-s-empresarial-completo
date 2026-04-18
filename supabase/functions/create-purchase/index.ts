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
    console.log('--- START PURCHASE FLOW ---')
    const payload = await req.json()
    console.log('1. Payload received:', JSON.stringify(payload))

    const authHeader = req.headers.get('Authorization')
    console.log('2. Auth Header present:', !!authHeader)

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader! } } }
    )

    // Admin client — used only to persist operation_id (bypasses RLS safely)
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 1. Validate Session
    console.log('3. Validating session...')
    const { data: { user }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !user) {
      console.error('Auth check failed:', userError)
      return new Response(JSON.stringify({ error: 'Unauthorized', details: userError }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }
    console.log('4. User ID:', user.id)

    const { product_id, amount, quantity, description, operation_id } = payload
    if (!product_id || amount === undefined || amount === null) {
      console.warn('5. Validation failed: missing product_id or amount')
      return new Response(JSON.stringify({ error: 'Faltan campos obligatorios' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // 3. Delegate to Atomic Postgres RPC
    console.log(`6. Executing RPC public.rpc_atomic_create_purchase...`)
    console.log(`   - Product: ${product_id}`)
    console.log(`   - Amount: ${amount}`)
    console.log(`   - Qty: ${quantity}`)
    console.log(`   - Desc: ${description || 'N/A'}`)

    const { data: purchase, error: rpcError } = await supabaseClient.rpc('rpc_atomic_create_purchase', {
      p_product_id: product_id,
      p_amount: amount,
      p_quantity: Math.max(1, quantity || 1),
      p_user_id: user.id,
      p_description: description || null
    })

    if (rpcError) {
      console.error('7. RPC ERROR DETECTED:', JSON.stringify(rpcError))
      let status = 500
      if (rpcError.code === 'P404') status = 404
      else if (rpcError.code === 'P403') status = 403
      else if (rpcError.code === 'P409') status = 409
      else if (rpcError.code === 'P400') status = 400

      return new Response(JSON.stringify({
        error: rpcError.message,
        code: rpcError.code,
        hint: rpcError.hint,
        details: rpcError.details
      }), {
        status: status,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // 8. Persist operation_id (cart grouping tag) — non-fatal if it fails
    if (operation_id && purchase?.id) {
      console.log(`8a. Tagging purchase ${purchase.id} with operation_id ${operation_id}`)
      const { error: tagError } = await adminClient
        .from('purchases')
        .update({ operation_id })
        .eq('id', purchase.id)
      if (tagError) {
        console.warn('8a. Failed to tag operation_id (non-fatal):', tagError.message)
      }
    }

    console.log('8. SUCCESS: Purchase ID', purchase.id)
    return new Response(JSON.stringify({ success: true, data: purchase }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (err: any) {
    console.error('--- CRITICAL EDGE ERROR ---')
    console.error(err)
    return new Response(JSON.stringify({
      error: err.message,
      stack: err.stack,
      hint: "Check server logs for internal trace"
    }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})
