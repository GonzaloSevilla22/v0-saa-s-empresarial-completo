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
 * (Resumen IA del día y celebración de meta, que siguen siendo "hoy").
 *
 * `range` se recibe ya materializado (`utcMonthRange`/`utcDayRange` devuelven
 * strings) para que la query key dependa de valores primitivos estables, nunca
 * de un `Date` que se recrea en cada render.
 *
 * `refetchOnMount: "always"`: cada montaje del Tablero vuelve a consultar
 * (paridad con el `useEffect` que reemplaza). La venta del POS, la confirmación
 * de una orden y los gastos NO invalidan esta clave; con sólo `staleTime`,
 * volver al Tablero dentro de los 5 minutos mostraba el total anterior. El
 * valor cacheado queda visible mientras se refresca (sin parpadeo a "—").
 * `useDashboardKpiSummary` lleva la misma opción, para que la "Ganancia Neta"
 * del bloque y la "Ganancia neta del mes" de la fila nunca diverjan.
 *
 * `isFetching` distingue "hay un valor, pero está por cambiar": la celebración
 * de meta no debe tomar como línea base el valor cacheado de un remontaje.
 *
 * Si el refresco de un remontaje falla, React Query conserva la lectura
 * anterior en `data` junto con `isError`: el hook no la descarta (la
 * celebración la necesita estable) y cada consumidor decide cómo degradar — las
 * tarjetas del mes muestran `$0` (D3). `error` expone el detalle de PostgREST
 * para el registro.
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
    refetchOnMount: "always",
    enabled: !!user,
  })

  return {
    data: query.data ?? null,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    isError: query.isError,
    error: query.error,
    refetch: query.refetch,
  }
}
