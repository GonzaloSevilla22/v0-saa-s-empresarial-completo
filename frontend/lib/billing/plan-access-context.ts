/**
 * planes-suscribirse-plan-vigente (D5) — línea de contexto del plan
 * efectivo: explica al usuario POR QUÉ se le ofrece pagar un plan que ya
 * está usando (cortesía / trial vigente / plan pago con vencimiento).
 *
 * Se deriva de los campos CRUDOS de la cuenta — NUNCA de `getEffectivePlan`
 * (D6): el espejo TypeScript no lee `plan_expires_at`, y usarlo acá
 * heredaría esa divergencia justo en el caso donde más importa (el aviso
 * de "tu plan vence" es exactamente lo que un `billing_plan` vencido no
 * debería mostrar).
 *
 * Precedencia idéntica a `getEffectivePlan` (billing-pro-trial D1):
 * cortesía > trial vigente > plan pago con vencimiento > sin motivo.
 */

import { format } from "date-fns"
import { es } from "date-fns/locale"
import type { Plan } from "@/lib/types"

export interface PlanAccessContextInput {
  billingExempt: boolean
  trialPlan: Plan | null
  trialExpiresAt: string | null
  billingPlan: Plan
  planExpiresAt: string | null
}

function formatDate(iso: string): string {
  return format(new Date(iso), "dd 'de' MMMM 'de' yyyy", { locale: es })
}

/**
 * Devuelve la línea de contexto a mostrar en la tarjeta del plan efectivo,
 * o `null` si no hay ningún motivo aplicable (plan pago sin vencimiento
 * próximo, sin trial ni exención).
 */
export function resolvePlanAccessContextLine(input: PlanAccessContextInput): string | null {
  const { billingExempt, trialPlan, trialExpiresAt, billingPlan, planExpiresAt } = input

  if (billingExempt) {
    return "Tenés acceso sin cargo a este plan."
  }

  const now = new Date()

  const trialActive = trialPlan != null && trialExpiresAt != null && new Date(trialExpiresAt) > now
  if (trialActive) {
    return `Tu período de prueba vence el ${formatDate(trialExpiresAt as string)}.`
  }

  const planExpiryActive = billingPlan !== "gratis" && planExpiresAt != null && new Date(planExpiresAt) > now
  if (planExpiryActive) {
    return `Tu acceso a este plan vence el ${formatDate(planExpiresAt as string)} si no te suscribís.`
  }

  return null
}
