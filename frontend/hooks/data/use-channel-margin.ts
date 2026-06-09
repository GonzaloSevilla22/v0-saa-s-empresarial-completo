"use client"

import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { utcMonthRange, utcPrevMonthRange } from "@/lib/date-range"
import type { ChannelMarginEntry } from "@/lib/kpi-format"

// ─── Types ────────────────────────────────────────────────────────────────────

export interface ChannelMargin {
  /** Canales del período ordenados por margen desc (solo con ingresos). */
  channels: ChannelMarginEntry[]
  /** Canal con mejor margen (null sin ventas en el período). */
  leader: string | null
  /** Margen total del período y del anterior (tone del badge, up_good). */
  marginPct: number | null
  prevMarginPct: number | null
}

interface RpcRow {
  channels: ChannelMarginEntry[] | null
  leader: string | null
  margin_pct: string | number | null
  prev_margin_pct: string | number | null
}

const num = (v: string | number | null | undefined): number | null =>
  v == null ? null : Number(v)

// ─── Hook ─────────────────────────────────────────────────────────────────────

/** Margen neto por canal del mes de `periodDate` (Fase B del Bloque Resumen KPI). */
export function useChannelMargin(periodDate: Date, branchId: string | null = null) {
  const { user } = useAuth()
  const supabase = createClient()

  const { from, to } = utcMonthRange(periodDate)
  const { from: prevFrom, to: prevTo } = utcPrevMonthRange(periodDate)

  const query = useQuery({
    queryKey: ["channelMargin", user?.id, from, branchId] as const,
    queryFn: async (): Promise<ChannelMargin | null> => {
      const params: Record<string, string> = {
        p_from: from,
        p_to: to,
        p_prev_from: prevFrom,
        p_prev_to: prevTo,
      }
      if (branchId) params.p_branch_id = branchId

      const { data, error } = await supabase.rpc("rpc_dashboard_channel_margin", params)
      if (error) throw error

      const rows = data as RpcRow[] | null
      const row = rows && rows.length > 0 ? rows[0] : null
      if (!row) return null

      return {
        channels: (row.channels ?? []).map(c => ({
          canal: c.canal,
          revenue: Number(c.revenue),
          margin_pct: num(c.margin_pct),
        })),
        leader: row.leader ?? null,
        marginPct: num(row.margin_pct),
        prevMarginPct: num(row.prev_margin_pct),
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
