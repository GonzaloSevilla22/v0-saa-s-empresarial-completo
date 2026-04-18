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
    const payload = await req.json()
    const { product_id } = payload

    if (!product_id) {
      return new Response(JSON.stringify({ error: 'Falta el campo product_id' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // ── 1. Validate the requesting user ──────────────────────────────────────
    // Use the user's JWT to verify identity (anon client with user's Authorization)
    const authHeader = req.headers.get('Authorization')
    const supabaseUser = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader! } } }
    )

    const { data: { user }, error: userError } = await supabaseUser.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'No autenticado' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // ── 2. Service-role client (bypasses RLS for internal operations) ─────────
    // IMPORTANT: do NOT pass the user Authorization header here — that would
    // downgrade service_role to user-level permissions.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // ── 3. Ownership check ────────────────────────────────────────────────────
    const { data: product, error: ownerError } = await admin
      .from('products')
      .select('id, user_id')
      .eq('id', product_id)
      .single()

    if (ownerError || !product) {
      return new Response(JSON.stringify({ error: 'Producto no encontrado' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    if (product.user_id !== user.id) {
      return new Response(JSON.stringify({ error: 'Sin permiso para eliminar este producto' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // ── 4. Nullify all FK references (admin bypasses RLS & FK RESTRICT) ───────
    // These run as the service role, so they succeed regardless of FK mode.
    await admin.from('sales').update({ product_id: null }).eq('product_id', product_id)
    await admin.from('purchases').update({ product_id: null }).eq('product_id', product_id)
    await admin.from('products').update({ parent_id: null }).eq('parent_id', product_id)

    // ── 5. Delete the product (no FK blockers remain) ─────────────────────────
    const { error: deleteError } = await admin
      .from('products')
      .delete()
      .eq('id', product_id)

    if (deleteError) {
      console.error('Delete error:', deleteError)
      return new Response(JSON.stringify({ error: deleteError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (err: any) {
    console.error('Edge Function error:', err)
    return new Response(JSON.stringify({ error: err.message ?? 'Error inesperado' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})
