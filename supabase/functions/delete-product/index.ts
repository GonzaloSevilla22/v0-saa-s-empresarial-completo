import { createClient } from 'jsr:@supabase/supabase-js@2'

// ─── Helpers ────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

// ─── Main handler ────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS })
  }

  // Global try/catch — this function NEVER returns status 500 without a body
  try {

    // ── Step 1: Parse body ──────────────────────────────────────────────────
    let product_id: string | undefined
    try {
      const body = await req.json()
      product_id = body?.product_id
    } catch {
      console.error('[delete-product] Could not parse JSON body')
      return respond({ error: 'INVALID_BODY', message: 'Body must be valid JSON' }, 400)
    }

    console.log('[delete-product] product_id received:', product_id)

    // ── Step 2: Validate input ──────────────────────────────────────────────
    if (!product_id || typeof product_id !== 'string' || product_id.trim() === '') {
      return respond({ error: 'MISSING_ID', message: 'product_id es obligatorio' }, 400)
    }

    // ── Step 3: Verify user identity (anon key + user JWT) ──────────────────
    const authHeader = req.headers.get('Authorization') ?? ''
    const userClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: authData, error: authError } = await userClient.auth.getUser()
    if (authError || !authData?.user) {
      console.error('[delete-product] Auth error:', authError?.message ?? 'no user')
      return respond({ error: 'UNAUTHORIZED', message: 'Sesión inválida' }, 401)
    }

    const userId = authData.user.id
    console.log('[delete-product] User authenticated:', userId)

    // ── Step 4: Build SERVICE ROLE client (NO user JWT — critical) ──────────
    // Passing the user's JWT here would downgrade the client to user-level
    // permissions. We deliberately omit it so service_role bypasses RLS.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      // ← no Authorization header here
    )

    // ── Step 5: Fetch product and verify ownership ──────────────────────────
    const { data: product, error: fetchErr } = await admin
      .from('products')
      .select('id, user_id')
      .eq('id', product_id)
      .maybeSingle()        // never throws "0 rows" error

    console.log('[delete-product] Product fetch:', product, fetchErr)

    if (fetchErr) {
      console.error('[delete-product] Fetch error:', fetchErr.message)
      return respond({ error: 'FETCH_FAILED', message: fetchErr.message }, 500)
    }
    if (!product) {
      return respond({ error: 'NOT_FOUND', message: 'Producto no encontrado' }, 404)
    }
    if (product.user_id !== userId) {
      return respond({ error: 'FORBIDDEN', message: 'Sin permiso para eliminar este producto' }, 403)
    }

    // ── Step 6: Nullify all FK references (admin → bypasses RLS + RESTRICT) ─
    // We log warnings but do NOT abort — even if 0 rows are updated, that is OK.
    const { error: e1 } = await admin.from('sales').update({ product_id: null }).eq('product_id', product_id)
    console.log('[delete-product] sales nullify:', e1 ? `WARN: ${e1.message}` : 'ok')

    const { error: e2 } = await admin.from('purchases').update({ product_id: null }).eq('product_id', product_id)
    console.log('[delete-product] purchases nullify:', e2 ? `WARN: ${e2.message}` : 'ok')

    const { error: e3 } = await admin.from('products').update({ parent_id: null }).eq('parent_id', product_id)
    console.log('[delete-product] variants nullify:', e3 ? `WARN: ${e3.message}` : 'ok')

    // ── Step 7: Delete the product ──────────────────────────────────────────
    const { error: delErr } = await admin
      .from('products')
      .delete()
      .eq('id', product_id)

    console.log('[delete-product] Delete result:', delErr ?? 'OK')

    if (delErr) {
      console.error('[delete-product] Delete error code:', delErr.code, '| message:', delErr.message)

      // Foreign key still blocked after nullification attempt
      if (delErr.code === '23503') {
        return respond({
          error: 'PRODUCT_IN_USE',
          message: 'El producto tiene registros asociados que no pudieron limpiarse. Contactá soporte.',
        }, 409)
      }

      return respond({
        error: 'DELETE_FAILED',
        message: delErr.message ?? 'Error al eliminar el producto',
        code: delErr.code,
      }, 500)
    }

    // ── Step 8: Success ─────────────────────────────────────────────────────
    console.log('[delete-product] SUCCESS — product deleted:', product_id)
    return respond({ success: true })

  } catch (err: unknown) {
    // Absolute last resort — should never reach here, but guarantees a response
    const message = err instanceof Error ? err.message : String(err)
    console.error('[delete-product] UNCAUGHT ERROR:', message)
    return respond({ error: 'INTERNAL_ERROR', message }, 500)
  }
})
