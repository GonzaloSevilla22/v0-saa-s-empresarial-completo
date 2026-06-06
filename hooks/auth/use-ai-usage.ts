"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "./use-plan-limits"

interface AiUsage {
  queriesUsed: number
  queriesRemaining: number
  adviceUsed: number
  adviceRemaining: number
  resetAt: string | null
  isLoading: boolean
}

export function useAiUsage(): AiUsage {
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["aiUsage", user?.id] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("ai_queries_used, ai_advice_used, usage_reset_at")
        .eq("id", user!.id)
        .single()

      if (error || !data) return { ai_queries_used: 0, ai_advice_used: 0, usage_reset_at: null }
      return data
    },
    staleTime: 30_000, // 30s — counters change on each AI call
    enabled:   !!user,
  })

  const queriesUsed = query.data?.ai_queries_used ?? 0
  const adviceUsed  = query.data?.ai_advice_used  ?? 0
  const maxQueries  = limits?.maxAiQueriesPerMonth ?? 0
  const maxAdvice   = limits?.maxAiAdvicePerMonth  ?? 0

  return {
    queriesUsed,
    queriesRemaining: Math.max(0, maxQueries - queriesUsed),
    adviceUsed,
    adviceRemaining:  Math.max(0, maxAdvice - adviceUsed),
    resetAt:          query.data?.usage_reset_at ?? null,
    isLoading:        query.isLoading,
  }
}
