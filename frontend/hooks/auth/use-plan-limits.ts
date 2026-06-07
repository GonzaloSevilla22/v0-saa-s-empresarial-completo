"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import type { Plan, PlanLimits } from "@/lib/types"
import { PLAN_LIMITS } from "@/lib/constants"

/**
 * Fetches plan limits from the `plan_limits` DB table for the user's effective plan.
 *
 * - Caches for 1 hour (limits rarely change).
 * - Falls back to static PLAN_LIMITS constants if the query fails.
 * - `plan_limits` has public RLS (anon + authenticated can SELECT).
 *
 * @example
 * const { limits, isLoading } = usePlanLimits()
 * if (products.length >= (limits?.maxProducts ?? 100)) { ... }
 */
export function usePlanLimits() {
  const { user } = useAuth()
  const effectivePlan = user?.effectivePlan ?? "gratis"
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["planLimits", effectivePlan] as const,
    queryFn: async (): Promise<PlanLimits> => {
      const { data, error } = await supabase
        .from("plan_limits")
        .select("*")
        .eq("plan", effectivePlan)
        .single()

      if (error || !data) {
        // Fallback to static constants if DB query fails
        const fallback = PLAN_LIMITS[effectivePlan as keyof typeof PLAN_LIMITS]
        if (fallback) {
          return {
            plan:                   effectivePlan,
            priceMonthly:           fallback.priceMonthly,
            maxUsers:               fallback.maxUsers,
            maxProducts:            fallback.maxProducts,
            maxClients:             fallback.maxClients,
            maxSuppliers:           fallback.maxSuppliers,
            maxOperationsPerMonth:  fallback.maxOperationsPerMonth,
            historyDays:            fallback.historyDays,
            maxExportsPerMonth:     fallback.maxExportsPerMonth,
            maxAiQueriesPerMonth:   fallback.maxAiQueriesPerMonth,
            maxAiAdvicePerMonth:    fallback.maxAiAdvicePerMonth,
            maxBranches:            fallback.maxBranches,
            hasProductProfitability: fallback.hasProductProfitability,
            hasComparativeReports:  fallback.hasComparativeReports,
            hasPriceSuggestion:     fallback.hasPriceSuggestion,
            hasBranchesModule:      fallback.hasBranchesModule,
            hasMonthlyAnalysis:     fallback.hasMonthlyAnalysis,
            internalRoles:          fallback.internalRoles,
          } satisfies PlanLimits
        }
        throw error ?? new Error("Plan limits not found")
      }

      return {
        plan:                   data.plan as Plan,
        priceMonthly:           Number(data.price_monthly),
        maxUsers:               data.max_users,
        maxProducts:            data.max_products,
        maxClients:             data.max_clients,
        maxSuppliers:           data.max_suppliers,
        maxOperationsPerMonth:  data.max_operations_per_month,
        historyDays:            data.history_days,
        maxExportsPerMonth:     data.max_exports_per_month,
        maxAiQueriesPerMonth:   data.max_ai_queries_per_month,
        maxAiAdvicePerMonth:    data.max_ai_advice_per_month,
        maxBranches:            data.max_branches,
        hasProductProfitability: data.has_product_profitability,
        hasComparativeReports:  data.has_comparative_reports,
        hasPriceSuggestion:     data.has_price_suggestion,
        hasBranchesModule:      data.has_branches_module,
        hasMonthlyAnalysis:     data.has_monthly_analysis,
        internalRoles:          data.internal_roles as PlanLimits["internalRoles"],
      } satisfies PlanLimits
    },
    staleTime:    3_600_000, // 1 hour — limits rarely change
    gcTime:       7_200_000, // keep in cache 2 hours
    retry:        1,
    enabled:      !!user,
  })

  return {
    limits:    query.data,
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}
