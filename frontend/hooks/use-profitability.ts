"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import type { ProductProfitability } from "@/lib/types"

export function useProfitability(periodDays: number = 30) {
  const { user } = useAuth()
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["profitability", user?.id, periodDays] as const,
    queryFn: async (): Promise<ProductProfitability[]> => {
      const { data, error } = await supabase.rpc("rpc_product_profitability", {
        p_period_days: periodDays,
      })
      if (error) throw error
      return (data ?? []) as ProductProfitability[]
    },
    staleTime: 5 * 60_000, // 5 minutes
    enabled:   !!user,
  })

  return {
    data:      query.data ?? [],
    isLoading: query.isLoading,
    isError:   query.isError,
    refetch:   query.refetch,
  }
}
