/**
 * POST /api/billing/cancel
 * Schedules a subscription cancellation at end of the current billing period.
 *
 * Sets billing_status = 'cancelling' and plan_expires_at to 30 days from now
 * (MVP: fixed period; production would use MP subscription period data).
 * The plan remains active until process_cancellations() runs on plan_expires_at.
 *
 * C-10 subscription-ui-upgrade-flow
 *
 * Returns: { ok: true, expiresAt: string }
 */

import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export async function POST(): Promise<NextResponse> {
  try {
    const supabase = createClient()

    // ── Auth guard ────────────────────────────────────────────────────────────
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return NextResponse.json({ ok: false, error: 'No autorizado' }, { status: 401 })
    }

    // ── Get account ───────────────────────────────────────────────────────────
    const { data: memberRow } = await supabase
      .from('account_members')
      .select('account_id, accounts(billing_plan, billing_status)')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!memberRow?.account_id) {
      return NextResponse.json({ ok: false, error: 'Cuenta no encontrada' }, { status: 404 })
    }

    const accountId = memberRow.account_id
    const account = memberRow.accounts as unknown as { billing_plan: string; billing_status: string } | null

    // Only paid active plans can be cancelled
    if (!account || account.billing_plan === 'gratis') {
      return NextResponse.json(
        { ok: false, error: 'No hay un plan pago activo para cancelar' },
        { status: 400 }
      )
    }

    if (account.billing_status === 'cancelling') {
      return NextResponse.json(
        { ok: false, error: 'La cancelación ya está programada' },
        { status: 400 }
      )
    }

    // plan_expires_at = 30 days from now (MVP: simulates end of billing period)
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()

    // ── Mark as cancelling ────────────────────────────────────────────────────
    const { error: updateError } = await supabase
      .from('accounts')
      .update({
        billing_status: 'cancelling',
        plan_expires_at: expiresAt,
      })
      .eq('id', accountId)

    if (updateError) {
      console.error('[billing/cancel] Failed to update account:', updateError)
      return NextResponse.json({ ok: false, error: 'Error al programar la cancelación' }, { status: 500 })
    }

    // ── Audit event ───────────────────────────────────────────────────────────
    await supabase.from('billing_events').insert({
      user_id: user.id,
      event_type: 'cancellation_requested',
      from_plan: account.billing_plan,
      to_plan: 'gratis',
      reason: 'C-10 user-requested-cancellation',
      metadata: {
        account_id: accountId,
        plan_expires_at: expiresAt,
      },
    })

    // ── Enqueue downgrade email ───────────────────────────────────────────────
    if (user.email) {
      await supabase.from('email_logs').insert({
        user_id: user.id,
        event_type: 'plan_downgraded',
        recipient: user.email,
        subject: 'Tu suscripción fue cancelada — EmprendeSmart',
        metadata: {
          plan: account.billing_plan,
          plan_expires_at: expiresAt,
          reason: 'user_requested',
        },
      })
    }

    return NextResponse.json({ ok: true, expiresAt })

  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('[billing/cancel] Unhandled error:', message)
    return NextResponse.json({ ok: false, error: 'Error interno del servidor' }, { status: 500 })
  }
}
