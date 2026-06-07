"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import type { PeriodComparison } from "@/lib/types"

export function usePeriodComparison(
  aStart: string | null,
  aEnd:   string | null,
  bStart: string | null,
  bEnd:   string | null,
) {
  const { user } = useAuth()
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["periodComparison", user?.id, aStart, aEnd, bStart, bEnd] as const,
    queryFn: async (): Promise<PeriodComparison | null> => {
      const { data, error } = await supabase.rpc("rpc_period_comparison", {
        p_a_start: aStart!,
        p_a_end:   aEnd!,
        p_b_start: bStart!,
        p_b_end:   bEnd!,
      })
      if (error) throw error
      const rows = data as PeriodComparison[] | null
      return rows && rows.length > 0 ? rows[0] : null
    },
    staleTime: 5 * 60_000,
    enabled:   !!user && !!aStart && !!aEnd && !!bStart && !!bEnd,
  })

  return {
    data:      query.data ?? null,
    isLoading: query.isLoading,
    isError:   query.isError,
    refetch:   query.refetch,
  }
}
