/**
 * POST /api/billing/cancel
 * Programa la cancelación de la suscripción al final del período en curso.
 *
 * Deja `billing_status = 'cancelling'` y `plan_expires_at` a 30 días (MVP:
 * período fijo estimado; producción usaría el período real de la suscripción de
 * MercadoPago). El plan sigue activo hasta que `process_cancellations()` corre
 * en `plan_expires_at`.
 *
 * C-10 subscription-ui-upgrade-flow
 *
 * accounts-profiles-privilege-columns (2026-09-21, governance CRÍTICO): esta
 * ruta era el ÚNICO caller que escribía `public.accounts` por PostgREST con el
 * JWT del usuario (rol `authenticated`) — el mismo mecanismo con el que el
 * titular de una cuenta podía auto-otorgarse `billing_exempt` / `billing_plan`
 * / un trial eterno, porque la tabla tenía UPDATE a nivel TABLA y cero ACLs de
 * columna. La migración 20261053000001 le revoca ese privilegio, así que la
 * escritura pasa a `rpc_request_subscription_cancellation()`: SECURITY DEFINER,
 * SIN parámetros (ni plan ni fechas: las calcula la función) y exige ser el
 * TITULAR de la cuenta.
 *
 * De paso cierra el hallazgo A1-5 de la auditoría: antes la ruta sólo
 * comprobaba MEMBRESÍA y dejaba que la RLS filtrara, así que para un miembro no
 * titular el UPDATE afectaba 0 filas y la ruta respondía `{ok:true}` igual —
 * una confirmación de cancelación falsa. Ahora es un 403 explícito.
 *
 * Returns: { ok: true, expiresAt: string }
 */

import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

/** Lo que devuelve `rpc_request_subscription_cancellation()` (jsonb). */
interface CancellationResult {
  account_id: string
  from_plan: string
  plan_expires_at: string
}

function isCancellationResult(value: unknown): value is CancellationResult {
  if (typeof value !== 'object' || value === null) return false
  const v = value as Record<string, unknown>
  return (
    typeof v.account_id === 'string' &&
    typeof v.from_plan === 'string' &&
    typeof v.plan_expires_at === 'string'
  )
}

/**
 * ERRCODEs del guard de la RPC → status + mensaje. Los textos de P0400 y P0409
 * son los mismos que la ruta devolvía antes (el modal los muestra tal cual).
 */
const ERROR_BY_CODE: Record<string, { status: number; error: string }> = {
  P0401: { status: 401, error: 'No autorizado' },
  P0403: {
    status: 403,
    error: 'Solo el titular de la cuenta puede cancelar la suscripción',
  },
  P0404: { status: 404, error: 'Cuenta no encontrada' },
  P0400: { status: 400, error: 'No hay un plan pago activo para cancelar' },
  P0409: { status: 400, error: 'La cancelación ya está programada' },
}

export async function POST(): Promise<NextResponse> {
  try {
    const supabase = createClient()

    // ── Auth guard ────────────────────────────────────────────────────────────
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return NextResponse.json({ ok: false, error: 'No autorizado' }, { status: 401 })
    }

    // ── Programar la cancelación (la RPC resuelve cuenta, titularidad, plan,
    //    estado y fecha — la ruta no le pasa nada) ──────────────────────────────
    const { data, error: rpcError } = await supabase.rpc(
      'rpc_request_subscription_cancellation',
      {},
    )

    if (rpcError) {
      const mapped = ERROR_BY_CODE[rpcError.code]
      if (mapped) {
        return NextResponse.json({ ok: false, error: mapped.error }, { status: mapped.status })
      }
      console.error('[billing/cancel] RPC failed:', rpcError.code, rpcError.message)
      return NextResponse.json(
        { ok: false, error: 'Error al programar la cancelación' },
        { status: 500 },
      )
    }

    if (!isCancellationResult(data)) {
      console.error('[billing/cancel] Unexpected RPC payload:', data)
      return NextResponse.json(
        { ok: false, error: 'Error al programar la cancelación' },
        { status: 500 },
      )
    }

    const { account_id: accountId, from_plan: fromPlan, plan_expires_at: expiresAt } = data

    // ── Audit event ───────────────────────────────────────────────────────────
    await supabase.from('billing_events').insert({
      user_id: user.id,
      event_type: 'cancellation_requested',
      from_plan: fromPlan,
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
        subject: 'Tu suscripción fue cancelada — Aliadata',
        metadata: {
          plan: fromPlan,
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
