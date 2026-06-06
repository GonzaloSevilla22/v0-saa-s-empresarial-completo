/**
 * POST /api/billing/webhook
 * Receives MercadoPago payment notifications (IPN/Webhooks).
 *
 * Security: verifies HMAC-SHA256 signature from x-signature header.
 * Idempotency: skips processing if mercadopago_payment_id already exists.
 *
 * C-10 subscription-ui-upgrade-flow
 */

import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { getMp, Payment } from '@/lib/mercadopago'
import type { Plan } from '@/lib/types'

// Next.js App Router: disable body parsing so we can read raw bytes for HMAC
export const runtime = 'nodejs'

const PLAN_HIERARCHY: Plan[] = ['gratis', 'inicial', 'avanzado', 'pro']

// ── HMAC-SHA256 signature verification ───────────────────────────────────────

async function verifyMpSignature(
  rawBody: string,
  xSignature: string | null,
  xRequestId: string | null
): Promise<boolean> {
  const secret = process.env.MERCADOPAGO_WEBHOOK_SECRET
  if (!secret) {
    console.error('[billing/webhook] MERCADOPAGO_WEBHOOK_SECRET is not set')
    return false
  }

  if (!xSignature || !xRequestId) {
    return false
  }

  // MP sends: ts=<timestamp>,v1=<hmac>
  const parts = Object.fromEntries(
    xSignature.split(',').map((p) => p.split('=') as [string, string])
  )
  const ts = parts['ts']
  const v1 = parts['v1']
  if (!ts || !v1) return false

  // Signed template: id:<id>;request-id:<xRequestId>;ts:<ts>;
  // id is the data.id from the MP notification body
  let notificationId = ''
  try {
    const body = JSON.parse(rawBody) as { data?: { id?: string } }
    notificationId = body?.data?.id ?? ''
  } catch {
    return false
  }

  const signedTemplate = `id:${notificationId};request-id:${xRequestId};ts:${ts};`

  const encoder = new TextEncoder()
  const keyData = encoder.encode(secret)
  const messageData = encoder.encode(signedTemplate)

  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )

  const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData)
  const computed = Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')

  // Constant-time comparison
  if (computed.length !== v1.length) return false
  let mismatch = 0
  for (let i = 0; i < computed.length; i++) {
    mismatch |= computed.charCodeAt(i) ^ v1.charCodeAt(i)
  }
  return mismatch === 0
}

// ── Webhook handler ───────────────────────────────────────────────────────────

export async function POST(req: Request): Promise<NextResponse> {
  const rawBody = await req.text()

  // Verify MP signature
  const xSignature = req.headers.get('x-signature')
  const xRequestId = req.headers.get('x-request-id')

  const isValid = await verifyMpSignature(rawBody, xSignature, xRequestId)
  if (!isValid) {
    console.warn('[billing/webhook] Invalid signature — rejecting')
    return NextResponse.json({ ok: false, error: 'Firma inválida' }, { status: 401 })
  }

  let notification: { type?: string; data?: { id?: string } }
  try {
    notification = JSON.parse(rawBody)
  } catch {
    return NextResponse.json({ ok: false, error: 'Payload inválido' }, { status: 400 })
  }

  // We only process payment notifications
  if (notification.type !== 'payment' || !notification.data?.id) {
    return NextResponse.json({ ok: true, skipped: true })
  }

  const paymentId = String(notification.data.id)

  try {
    const supabase = createClient()

    // ── Idempotency check ────────────────────────────────────────────────────
    const { data: existing } = await supabase
      .from('billing_events')
      .select('id')
      .eq('mercadopago_payment_id', paymentId)
      .maybeSingle()

    if (existing) {
      console.log('[billing/webhook] Duplicate payment_id — idempotent skip:', paymentId)
      return NextResponse.json({ ok: true, idempotent: true })
    }

    // ── Fetch payment details from MP ────────────────────────────────────────
    const payment = new Payment(getMp())
    const paymentData = await payment.get({ id: paymentId })

    if (paymentData.status !== 'approved') {
      console.log('[billing/webhook] Payment not approved:', paymentData.status)
      return NextResponse.json({ ok: true, status: paymentData.status })
    }

    // external_reference format: "userId::plan"
    const externalRef = paymentData.external_reference ?? ''
    const [userId, plan] = externalRef.split('::') as [string, Plan]

    if (!userId || !plan || !PLAN_HIERARCHY.includes(plan)) {
      console.error('[billing/webhook] Invalid external_reference:', externalRef)
      return NextResponse.json({ ok: false, error: 'external_reference inválido' }, { status: 400 })
    }

    const amount = paymentData.transaction_amount ?? 0
    const preferenceId = paymentData.preference_id ?? null

    // ── Get the user's current account ──────────────────────────────────────
    const { data: memberRow } = await supabase
      .from('account_members')
      .select('account_id, accounts(billing_plan)')
      .eq('user_id', userId)
      .maybeSingle()

    if (!memberRow?.account_id) {
      console.error('[billing/webhook] No account found for user:', userId)
      return NextResponse.json({ ok: false, error: 'Cuenta no encontrada' }, { status: 404 })
    }

    const accountId = memberRow.account_id
    const fromPlan = (memberRow.accounts as unknown as { billing_plan: Plan } | null)?.billing_plan ?? 'gratis'

    // ── Update account plan ──────────────────────────────────────────────────
    const { error: updateError } = await supabase
      .from('accounts')
      .update({
        billing_plan: plan,
        billing_status: 'active',
        plan_expires_at: null,
      })
      .eq('id', accountId)

    if (updateError) {
      console.error('[billing/webhook] Failed to update account:', updateError)
      return NextResponse.json({ ok: false, error: 'Error al actualizar el plan' }, { status: 500 })
    }

    // ── Insert billing_events audit row ──────────────────────────────────────
    const { error: eventError } = await supabase
      .from('billing_events')
      .insert({
        user_id: userId,
        event_type: 'plan_upgraded',
        from_plan: fromPlan,
        to_plan: plan,
        reason: 'C-10 mercadopago-payment-approved',
        mercadopago_payment_id: paymentId,
        mercadopago_preference_id: preferenceId,
        amount,
        metadata: {
          account_id: accountId,
          payment_status: paymentData.status,
        },
      })

    if (eventError) {
      console.error('[billing/webhook] Failed to insert billing_event:', eventError)
      // Non-fatal: plan was already updated. Log and return success.
    }

    // ── Enqueue upgrade email notification ───────────────────────────────────
    const { data: profileData } = await supabase
      .from('profiles')
      .select('id')
      .eq('id', userId)
      .maybeSingle()

    if (profileData) {
      const { data: authUser } = await supabase.auth.admin.getUserById(userId)
      const recipientEmail = authUser?.user?.email
      if (recipientEmail) {
        await supabase.from('email_logs').insert({
          user_id: userId,
          event_type: 'plan_upgraded',
          recipient: recipientEmail,
          subject: `Tu plan ${plan.charAt(0).toUpperCase() + plan.slice(1)} está activo — EmprendeSmart`,
          metadata: {
            plan,
            amount,
            activated_at: new Date().toISOString(),
          },
        })
      }
    }

    console.log(`[billing/webhook] Upgraded user ${userId} from ${fromPlan} to ${plan}`)
    return NextResponse.json({ ok: true })

  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('[billing/webhook] Unhandled error:', message)
    return NextResponse.json({ ok: false, error: 'Error interno del servidor' }, { status: 500 })
  }
}
