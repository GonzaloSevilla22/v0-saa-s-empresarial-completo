"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import type { IsoRange } from "@/lib/date-range"
import {
  fetchDashboardFinancials,
  type DashboardFinancials,
} from "@/lib/reporting/dashboard-financials"

export type { DashboardFinancials }

/**
 * Ingresos / gastos / compras / ganancia neta de una ventana arbitraria
 * (`get_dashboard_financials`) — tablero-kpis-mes-vigente.
 *
 * El Tablero lo usa dos veces: con la ventana del MES del selector de período
 * (las tarjetas "Ventas/Gastos/Ganancia neta del mes") y con la del DÍA
 * (Resumen AI del día y celebración de meta, que siguen siendo "hoy").
 *
 * `range` se recibe ya materializado (`utcMonthRange`/`utcDayRange` devuelven
 * strings) para que la query key dependa de valores primitivos estables, nunca
 * de un `Date` que se recrea en cada render.
 */
export function useDashboardFinancials(range: IsoRange, branchId: string | null = null) {
  const { user } = useAuth()
  const supabase = createClient()

  const { from, to } = range

  const query = useQuery({
    queryKey: ["dashboardFinancials", user?.id, from, to, branchId] as const,
    queryFn: (): Promise<DashboardFinancials> =>
      fetchDashboardFinancials(supabase, { from, to, branchId }),
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
