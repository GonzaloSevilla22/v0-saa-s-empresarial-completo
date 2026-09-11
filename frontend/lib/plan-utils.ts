/**
 * Plan utilities — C-02 plan-gating-engine (updated C-05, billing-pro-trial)
 *
 * Centralizes plan hierarchy and effective-plan logic.
 * All gating checks should use these utilities instead of
 * hardcoded string comparisons.
 *
 * As of C-05: billing data is sourced from the `accounts` table (not profiles).
 * The auth context resolves billing state from the user's account membership
 * and populates User.billingPlan / trialPlan / trialExpiresAt / billingExempt
 * before calling getEffectivePlan. No changes needed here — the function
 * is agnostic to the source of the billing data.
 *
 * billing-pro-trial (D1/D3): this is the TypeScript MIRROR of the normative
 * SQL definition `public.get_effective_plan(account_id)`. It MUST implement
 * the exact same precedence and MUST NOT diverge — a shared parity test
 * (__tests__/plan-utils.test.ts, run against the same case table as the SQL
 * migration gate) verifies this on every change. In particular: this
 * function deliberately does NOT read `billingStatus` — the SQL definition
 * doesn't either (D1: a descriptive/cosmetic field can never gate access).
 */

import type { Plan } from "@/lib/types"

/** Ordered plan hierarchy: lower index = lower tier. */
export const PLAN_HIERARCHY: Plan[] = ["gratis", "inicial", "avanzado", "pro"]

function isValidPlan(value: unknown): value is Plan {
  return typeof value === "string" && (PLAN_HIERARCHY as string[]).includes(value)
}

export interface EffectivePlanInput {
  /** May be absent/invalid for a not-yet-provisioned account (fail-closed → 'gratis'). */
  billingPlan: Plan | null | undefined
  /** null (Account) or undefined (User, legacy) both mean "no active trial". */
  trialPlan?: Plan | null
  trialExpiresAt?: string | null
  /** billing-pro-trial (D4): exención de cortesía — precedencia máxima. */
  billingExempt?: boolean | null
}

/**
 * Returns the effective plan for a user/account. Mirrors the precedence of
 * `public.get_effective_plan(account_id)` (billing-pro-trial D1):
 *
 *   1. billingExempt vigente           → 'pro'
 *   2. trial vigente (trialExpiresAt > now, trialPlan set) → trialPlan
 *   3. billingPlan (si es un plan válido)
 *   4. cualquier otro caso             → 'gratis' (fail-closed)
 *
 * Nunca lee billingStatus: es un campo descriptivo (D6), no autoritativo —
 * leerlo para decidir acceso es exactamente el bug que este change cierra.
 */
export function getEffectivePlan(user: EffectivePlanInput): Plan {
  if (user.billingExempt) {
    return "pro"
  }

  const now = new Date()
  const trialActive =
    user.trialPlan != null &&
    user.trialExpiresAt != null &&
    new Date(user.trialExpiresAt) > now

  if (trialActive) {
    return user.trialPlan as Plan
  }

  return isValidPlan(user.billingPlan) ? user.billingPlan : "gratis"
}

/**
 * Returns true if effectivePlan meets or exceeds requiredPlan in the hierarchy.
 *
 * @example
 * planHasAccess("avanzado", "inicial") // true — avanzado >= inicial
 * planHasAccess("inicial", "avanzado") // false — inicial < avanzado
 * planHasAccess("pro", "pro")          // true — same plan
 */
export function planHasAccess(effectivePlan: Plan, requiredPlan: Plan): boolean {
  return PLAN_HIERARCHY.indexOf(effectivePlan) >= PLAN_HIERARCHY.indexOf(requiredPlan)
}

/**
 * Human-readable plan name for display.
 */
export const PLAN_DISPLAY_NAMES: Record<Plan, string> = {
  gratis:   "Gratis",
  inicial:  "Inicial",
  avanzado: "Avanzado",
  pro:      "Pro",
}

/**
 * Mensaje de rechazo por tope de productos del plan (revisión adversarial,
 * ronda 2, de `importador-gate-plan`) — molde de `newCategoryLimitMessage`
 * (`lib/import/validator.ts`). Antes de este helper, la oración vivía
 * literal y por separado en dos superficies que bloquean el MISMO límite
 * (`ProductRepository.count_by_org`, mismo predicado en las dos): el alta
 * de un producto a la vez y la importación por lote. Ahora sólo la
 * consume `ProductImportDialog` (el importador), porque la del alta de a
 * uno **vive en el backend**: `backend/services/products.py` (función
 * `create_product`, ~línea 93) devuelve el `HTTPException.detail` ya
 * armado como string — no hay ningún literal de cliente que reemplazar
 * ahí. Este comentario fija la equivalencia: si cambia la redacción acá,
 * cambiar también el f-string de esa línea (no hay forma automática de
 * sincronizar Python y TypeScript).
 */
export function planProductLimitMessage({ plan, limit }: { plan: string; limit: number }): string {
  return `Límite de productos alcanzado para el plan ${plan} (${limit} máx.). Borrá productos existentes o subí de plan.`
}
