"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { utcMonthRange, utcPrevMonthRange } from "@/lib/date-range"
import { fetchKpiSummary, type DashboardKpiSummary } from "@/lib/reporting/kpi-summary"

// kpi-ia-canonical-revenue (D7): el mapeo de la fila del RPC vive en
// lib/reporting/kpi-summary.ts — este hook es solo el cableado a React Query.
// Re-exportado para no romper a los importadores existentes del tipo.
export type { DashboardKpiSummary }

/**
 * KPIs mensuales del Bloque Resumen (Fase A): período del mes que contiene
 * `periodDate` + el mes anterior, en una sola llamada al RPC agregador.
 */
export function useDashboardKpiSummary(periodDate: Date, branchId: string | null = null) {
  const { user } = useAuth()
  const supabase = createClient()

  const { from, to } = utcMonthRange(periodDate)
  const { from: prevFrom, to: prevTo } = utcPrevMonthRange(periodDate)

  const query = useQuery({
    queryKey: ["dashboardKpiSummary", user?.id, from, branchId] as const,
    queryFn: (): Promise<DashboardKpiSummary | null> =>
      fetchKpiSummary(supabase, { from, to, prevFrom, prevTo, branchId }),
    staleTime: 5 * 60_000,
    enabled: !!user,
  })

  return {
    data: query.data ?? null,
    isLoading: query.isLoading,
    isError: query.isError,
    refetch: query.refetch,
  }
}
