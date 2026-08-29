/**
 * Helper canónico de lectura de "suscripción viva" en `public.subscriptions`.
 *
 * planes-suscribirse-plan-vigente (D1/D2): extraído del patrón que
 * `/facturacion` ya usaba inline (`app/(dashboard)/facturacion/page.tsx`,
 * antes de este change) para que `/planes` lo reuse sin duplicar la
 * consulta — segunda ocurrencia idéntica en el repo, regla PO "lo nuevo
 * reusable nace en la capa canónica".
 *
 * El conjunto de estados considerados "vivos" DEBE ser exactamente el que
 * usa `find_live_subscription` en el backend
 * (`backend/repositories/subscriptions_repository.py`):
 *
 *   WHERE account_id = $1 AND status IN ('pending', 'authorized')
 *
 * Si este conjunto diverge del backend, la UI ofrece contrataciones que el
 * backend rechaza con 409 (falta un estado acá), o esconde el CTA sin
 * motivo (sobra un estado acá). No existe una constante compartida entre
 * Python y TypeScript — la duplicación es real y la vigila un test de
 * paridad por enumeración explícita (`__tests__/lib/billing/live-subscription.test.ts`).
 *
 * Se llama desde un Server Component (RLS SELECT por membresía de cuenta,
 * igual patrón que el resto de `/facturacion`), nunca desde el cliente —
 * ver D1 en design.md para por qué no se usa `getSubscriptionStatus()`.
 */

import type { SupabaseClient } from "@supabase/supabase-js"
import type { Plan } from "@/lib/types"

/** Único lugar donde este conjunto se declara del lado frontend (ver comentario de arriba). */
export const LIVE_SUBSCRIPTION_STATUSES = ["pending", "authorized"] as const

export type LiveSubscriptionStatus = (typeof LIVE_SUBSCRIPTION_STATUSES)[number]

export interface LiveSubscriptionRow {
  plan: Plan
  status: string
  next_payment_date: string | null
  retry_state: string
  amount: number | null
  currency: string
}

function isLiveStatus(status: string): status is LiveSubscriptionStatus {
  return (LIVE_SUBSCRIPTION_STATUSES as readonly string[]).includes(status)
}

/**
 * Devuelve la fila de suscripción viva de la cuenta, o `null` si no hay
 * ninguna. Nunca lanza: sin `accountId`, con error de Postgrest, o ante
 * cualquier excepción de red, degrada a `null` ("no viva") — la pantalla
 * de planes/facturación nunca debe caerse por esta lectura.
 *
 * Defensa en profundidad: además del filtro `.in()` en la consulta, vuelve
 * a chequear el `status` client-side antes de considerar la fila viva.
 */
export async function getLiveSubscription(
  supabase: SupabaseClient,
  accountId: string | null | undefined,
): Promise<LiveSubscriptionRow | null> {
  if (!accountId) {
    return null
  }

  try {
    const { data, error } = await supabase
      .from("subscriptions")
      .select("plan, status, next_payment_date, retry_state, amount, currency")
      .eq("account_id", accountId)
      .in("status", LIVE_SUBSCRIPTION_STATUSES as unknown as string[])
      .maybeSingle()

    if (error || !data) {
      return null
    }

    const row = data as LiveSubscriptionRow
    return isLiveStatus(row.status) ? row : null
  } catch {
    return null
  }
}
