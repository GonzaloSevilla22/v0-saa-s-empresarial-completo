"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { utcMonthRange, utcPrevMonthRange } from "@/lib/date-range"

// ─── Types ────────────────────────────────────────────────────────────────────

/** Fila de rpc_dashboard_kpi_summary mapeada a camelCase. Los KPIs de ratio
 *  (ticket, costo/venta) son null cuando el período no tiene ventas. */
export interface DashboardKpiSummary {
  netProfit: number | null
  prevNetProfit: number | null
  avgTicket: number | null
  prevAvgTicket: number | null
  costPerSale: number | null
  prevCostPerSale: number | null
  stagnantStockValue: number | null
  stagnantStockCount: number | null
  prevStagnantStockValue: number | null
  prevStagnantStockCount: number | null
  salesCount: number
  prevSalesCount: number
}

interface RpcRow {
  net_profit: string | number | null
  prev_net_profit: string | number | null
  avg_ticket: string | number | null
  prev_avg_ticket: string | number | null
  cost_per_sale: string | number | null
  prev_cost_per_sale: string | number | null
  stagnant_stock_value: string | number | null
  stagnant_stock_count: number | null
  prev_stagnant_stock_value: string | number | null
  prev_stagnant_stock_count: number | null
  sales_count: number | null
  prev_sales_count: number | null
}

const num = (v: string | number | null | undefined): number | null =>
  v == null ? null : Number(v)

// ─── Hook ─────────────────────────────────────────────────────────────────────

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
    queryFn: async (): Promise<DashboardKpiSummary | null> => {
      const params: Record<string, string> = {
        p_from: from,
        p_to: to,
        p_prev_from: prevFrom,
        p_prev_to: prevTo,
      }
      if (branchId) params.p_branch_id = branchId

      const { data, error } = await supabase.rpc("rpc_dashboard_kpi_summary", params)
      if (error) throw error

      const rows = data as RpcRow[] | null
      const row = rows && rows.length > 0 ? rows[0] : null
      if (!row) return null

      return {
        netProfit: num(row.net_profit),
        prevNetProfit: num(row.prev_net_profit),
        avgTicket: num(row.avg_ticket),
        prevAvgTicket: num(row.prev_avg_ticket),
        costPerSale: num(row.cost_per_sale),
        prevCostPerSale: num(row.prev_cost_per_sale),
        stagnantStockValue: num(row.stagnant_stock_value),
        stagnantStockCount: num(row.stagnant_stock_count),
        prevStagnantStockValue: num(row.prev_stagnant_stock_value),
        prevStagnantStockCount: num(row.prev_stagnant_stock_count),
        salesCount: Number(row.sales_count ?? 0),
        prevSalesCount: Number(row.prev_sales_count ?? 0),
      }
    },
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
