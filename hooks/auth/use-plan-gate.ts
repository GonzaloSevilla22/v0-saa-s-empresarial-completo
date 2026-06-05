"use client"

import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { planHasAccess } from "@/lib/plan-utils"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanGateResult {
  /** Whether the user's effective plan meets or exceeds requiredPlan. */
  hasAccess: boolean
  /** The user's current effective plan (considering active trials). */
  effectivePlan: Plan
  /** Live plan limits from the DB (undefined while loading). */
  limits: PlanLimits | undefined
  /** True while plan limits are still loading. */
  isLoading: boolean
}

/**
 * Gating hook for a feature requiring a minimum plan.
 *
 * @example
 * const { hasAccess } = usePlanGate("avanzado")
 * if (!hasAccess) return <UpgradeCTA requiredPlan="avanzado" />
 */
export function usePlanGate(requiredPlan: Plan): PlanGateResult {
  const { user } = useAuth()
  const { limits, isLoading } = usePlanLimits()
  const effectivePlan = user?.effectivePlan ?? "gratis"

  return {
    hasAccess: planHasAccess(effectivePlan, requiredPlan),
    effectivePlan,
    limits,
    isLoading,
  }
}
