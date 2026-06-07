/**
 * Plan utilities — C-02 plan-gating-engine (updated C-05)
 *
 * Centralizes plan hierarchy and effective-plan logic.
 * All gating checks should use these utilities instead of
 * hardcoded string comparisons.
 *
 * As of C-05: billing data is sourced from the `accounts` table (not profiles).
 * The auth context resolves billing state from the user's account membership
 * and populates User.billingPlan / billingStatus / trialPlan / trialExpiresAt
 * before calling getEffectivePlan. No changes needed here — the function
 * is agnostic to the source of the billing data.
 */

import type { Plan, User } from "@/lib/types"

/** Ordered plan hierarchy: lower index = lower tier. */
export const PLAN_HIERARCHY: Plan[] = ["gratis", "inicial", "avanzado", "pro"]

/**
 * Returns the effective plan for a user.
 * If a trial is active (billing_status='trialing', trial_plan set, trial not expired),
 * the trial plan is returned. Otherwise, billing_plan is used.
 *
 * As of C-05: input values are resolved from the user's account (accounts table),
 * not from profiles. The caller (auth-context) handles this resolution.
 */
export function getEffectivePlan(user: Pick<User, "billingPlan" | "billingStatus" | "trialPlan" | "trialExpiresAt">): Plan {
  const now = new Date()
  const trialActive =
    user.billingStatus === "trialing" &&
    user.trialPlan != null &&
    user.trialExpiresAt != null &&
    new Date(user.trialExpiresAt) > now

  return trialActive ? (user.trialPlan as Plan) : user.billingPlan
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
