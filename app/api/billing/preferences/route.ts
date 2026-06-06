/**
 * POST /api/billing/preferences
 * Creates a MercadoPago Checkout Pro preference for the given plan.
 *
 * C-10 subscription-ui-upgrade-flow
 *
 * Body:   { plan: Plan }
 * Returns { preferenceId: string, initPoint: string }
 */

import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { mp, Preference } from '@/lib/mercadopago'
import type { Plan } from '@/lib/types'

const PLAN_HIERARCHY: Plan[] = ['gratis', 'inicial', 'avanzado', 'pro']

interface PreferenceRequestBody {
  plan: Plan
}

export async function POST(req: Request): Promise<NextResponse> {
  try {
    const supabase = createClient()

    // ── Auth guard ────────────────────────────────────────────────────────────
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return NextResponse.json({ ok: false, error: 'No autorizado' }, { status: 401 })
    }

    // ── Parse + validate body ─────────────────────────────────────────────────
    const body = await req.json().catch(() => ({})) as Partial<PreferenceRequestBody>
    const { plan } = body

    if (!plan || !PLAN_HIERARCHY.includes(plan)) {
      return NextResponse.json(
        { ok: false, error: `Plan inválido. Debe ser uno de: ${PLAN_HIERARCHY.join(', ')}` },
        { status: 400 }
      )
    }

    if (plan === 'gratis') {
      return NextResponse.json(
        { ok: false, error: 'No se puede crear una preferencia de pago para el plan Gratis' },
        { status: 400 }
      )
    }

    // ── Fetch price from plan_limits ──────────────────────────────────────────
    const { data: planData, error: planError } = await supabase
      .from('plan_limits')
      .select('plan, price_monthly, price_ars_annual')
      .eq('plan', plan)
      .single()

    if (planError || !planData) {
      console.error('[billing/preferences] Failed to fetch plan_limits:', planError)
      return NextResponse.json({ ok: false, error: 'Error al obtener información del plan' }, { status: 500 })
    }

    const appUrl = process.env.NEXT_PUBLIC_APP_URL ?? 'https://emprende-smart.vercel.app'

    // ── Create MercadoPago preference ─────────────────────────────────────────
    const preference = new Preference(mp)
    const result = await preference.create({
      body: {
        external_reference: `${user.id}::${plan}`,
        items: [
          {
            id: `plan-${plan}-monthly`,
            title: `EmprendeSmart — Plan ${plan.charAt(0).toUpperCase() + plan.slice(1)} (mensual)`,
            description: `Suscripción mensual al plan ${plan.charAt(0).toUpperCase() + plan.slice(1)} de EmprendeSmart`,
            quantity: 1,
            unit_price: planData.price_monthly,
            currency_id: 'ARS',
          },
        ],
        back_urls: {
          success: `${appUrl}/planes/success`,
          failure: `${appUrl}/planes/failure`,
          pending: `${appUrl}/planes/success`,
        },
        auto_return: 'approved',
        notification_url: `${appUrl}/api/billing/webhook`,
        metadata: {
          user_id: user.id,
          plan,
        },
      },
    })

    if (!result.id || !result.init_point) {
      console.error('[billing/preferences] MP preference missing id/init_point:', result)
      return NextResponse.json(
        { ok: false, error: 'MercadoPago no devolvió una preferencia válida' },
        { status: 502 }
      )
    }

    return NextResponse.json({
      ok: true,
      preferenceId: result.id,
      initPoint: result.init_point,
    })

  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('[billing/preferences] Unhandled error:', message)
    return NextResponse.json({ ok: false, error: 'Error interno del servidor' }, { status: 500 })
  }
}
