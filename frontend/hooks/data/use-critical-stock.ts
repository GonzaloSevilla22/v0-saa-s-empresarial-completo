"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { fetchCriticalStockCount } from "@/lib/reporting/critical-stock"

/**
 * KPI de stock crítico consciente de sucursal (kpi-critical-stock-dashboard,
 * D5): consume `get_dashboard_critical_stock(p_branch_id)` — la definición
 * canónica, la misma que usa `check_branch_low_stock` (RN-23) — en vez de
 * recalcular el predicado sobre `products` en el cliente.
 *
 * `branchId = null` → agregado consciente de sucursal (D2): un producto
 * crítico en alguna sucursal con umbral, aunque el filtro no esté activo.
 *
 * Degrada a 0 + `console.error` si el RPC falla (D5 risk mitigation): un
 * fallo del KPI no debe romper el resto del Tablero.
 */
export function useCriticalStock(branchId: string | null = null) {
  const { user } = useAuth()
  const supabase = createClient()

  const query = useQuery({
    queryKey: ["criticalStock", user?.id, branchId] as const,
    queryFn: async (): Promise<number> => {
      try {
        return await fetchCriticalStockCount(supabase, branchId)
      } catch (err) {
        console.error("[useCriticalStock] get_dashboard_critical_stock error:", err)
        return 0
      }
    },
    staleTime: 45_000,
    enabled: !!user,
  })

  return {
    data: query.data ?? 0,
    isLoading: query.isLoading,
    isError: query.isError,
    refetch: query.refetch,
  }
}
