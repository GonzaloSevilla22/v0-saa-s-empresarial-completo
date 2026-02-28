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
    if (userError || !user) throw new Error('Unauthorized | 401')

    // 2. Parse payload
    const { client_id, product_id, amount, quantity } = await req.json()
    if (!product_id || !amount) throw new Error('Missing required fields | 400')

    // 3. Delegate to Atomic Postgres RPC
    // This handles stock verification, FOR UPDATE row locking, inserting the sale, 
    // and correctly pushing timeline telemetry safely under a single DB transaction.
    const { data: sale, error: rpcError } = await supabaseClient.rpc('rpc_atomic_create_sale', {
      p_client_id: client_id || null,
      p_product_id: product_id,
      p_amount: amount,
      p_quantity: quantity || 1,
      p_user_id: user.id
    })

    if (rpcError) {
      if (rpcError.code === 'no_data_found') throw new Error(`${rpcError.message} | 404`)
      if (rpcError.code === 'integrity_constraint_violation') throw new Error(`${rpcError.message} | 409`)
      throw new Error(`${rpcError.message} | 500`)
    }

    return new Response(JSON.stringify(sale), {
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
