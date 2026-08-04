"use client"

import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { startOfMonth, subDays } from "date-fns"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { createClient } from "@/lib/supabase/client"
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from "recharts"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { formatMoney } from "@/lib/format"
import {
  mapCostCenterReportRow,
  sumCostCenterReport,
  type CostCenterReportRawRow,
} from "@/lib/cost-center-report"
import type { CostCenterReportRow } from "@/lib/types"
import { Tags } from "lucide-react"

// Paleta de la serie, alineada con /reportes/sucursal.
const COLORS = [
  "hsl(var(--primary))",
  "#60a5fa",
  "#34d399",
  "#f59e0b",
  "#f87171",
]

export default function CentrosCostoReportPage() {
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const accountId = user?.accountId ?? null

  const today = new Date()
  const [dateFrom, setDateFrom] = useState<Date>(startOfMonth(today))
  const [dateTo,   setDateTo]   = useState<Date>(today)

  // El historial visible sigue la política de plan ya vigente en los otros
  // reportes; el reporte en sí NO está gateado (design.md Decisión 7).
  const minDate = subDays(today, limits?.historyDays ?? 30)

  const { data: rows = [], isLoading } = useQuery<CostCenterReportRow[]>({
    queryKey: ["costCenterReport", accountId, toISODate(dateFrom), toISODate(dateTo)],
    queryFn: async () => {
      if (!accountId) return []
      const supabase = createClient()
      const { data, error } = await supabase.rpc("rpc_cost_center_report", {
        p_account_id: accountId,
        p_start:      toISODate(dateFrom),
        p_end:        toISODate(dateTo),
      })
      if (error) throw new Error(error.message)
      return ((data ?? []) as CostCenterReportRawRow[]).map(mapCostCenterReportRow)
    },
    enabled: !!accountId,
  })

  const totals = sumCostCenterReport(rows)

  const chartData = rows.map((r) => ({
    name:    r.name.length > 14 ? `${r.name.slice(0, 12)}…` : r.name,
    Gastos:  Math.round(r.totalExpenses),
    Compras: Math.round(r.totalPurchases),
  }))

  return (
    <div className="flex flex-col gap-6">
      {/* ── Header ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Costos por centro de costo
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Gastos y compras imputados a cada área o proyecto en el período. No incluye
            ventas: el centro de costo mide costos, no margen.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <DateButton
            date={dateFrom}
            onSelect={setDateFrom}
            minDate={minDate}
            maxDate={dateTo}
            label="Fecha desde"
          />
          <span className="text-xs text-muted-foreground">→</span>
          <DateButton
            date={dateTo}
            onSelect={setDateTo}
            minDate={dateFrom}
            maxDate={today}
            label="Fecha hasta"
          />
        </div>
      </div>

      {/* ── Gráfico ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Gastos vs Compras por centro</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="h-56 flex items-center justify-center text-muted-foreground text-sm">
              Cargando...
            </div>
          ) : rows.length === 0 ? (
            <EmptyState />
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 16, top: 4 }}>
                <XAxis type="number" tickFormatter={(v) => `$${Math.round(v / 1000)}K`} tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="name" width={110} tick={{ fontSize: 12 }} />
                <Tooltip formatter={(v: number, name: string) => [formatMoney(v), name]} />
                <Bar dataKey="Gastos" fill="hsl(var(--primary))" fillOpacity={0.85} radius={[0, 4, 4, 0]}>
                  {chartData.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} fillOpacity={0.85} />
                  ))}
                </Bar>
                <Bar dataKey="Compras" fill="#60a5fa" fillOpacity={0.7} radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>

      {/* ── Tabla ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Detalle por centro de costo</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading ? (
            <div className="p-6 text-center text-muted-foreground text-sm">Cargando...</div>
          ) : rows.length === 0 ? (
            <div className="p-6">
              <EmptyState />
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-muted/40">
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">Centro de costo</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Gastos</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Compras</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Costo total</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Operaciones</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row, i) => (
                    <tr key={row.id ?? "sin-imputar"} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span className={row.id === null ? "text-muted-foreground italic" : "font-medium"}>
                            {row.name}
                          </span>
                          {row.code && (
                            <Badge variant="outline" className="text-xs">{row.code}</Badge>
                          )}
                          {!row.isActive && (
                            <Badge variant="secondary" className="text-xs">Inactivo</Badge>
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">{formatMoney(row.totalExpenses)}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{formatMoney(row.totalPurchases)}</td>
                      <td className="px-4 py-3 text-right tabular-nums font-medium">{formatMoney(row.totalCost)}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{row.operationCount}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="border-t border-border font-semibold bg-muted/30">
                    <td className="px-4 py-3">Total del período</td>
                    <td className="px-4 py-3 text-right tabular-nums">{formatMoney(totals.totalExpenses)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">{formatMoney(totals.totalPurchases)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">{formatMoney(totals.totalCost)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">{totals.operationCount}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <p className="text-xs text-muted-foreground">
        Los costos sin imputar aparecen como “Sin centro de costo”, así el total de la
        tabla coincide con el costo del período. Los centros de costo se crean y se dan
        de baja en Configuración → Centros de costo.
      </p>
    </div>
  )
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-10 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
        <Tags className="h-6 w-6 text-muted-foreground" />
      </div>
      <div>
        <p className="text-sm font-medium text-foreground">Sin costos en el período seleccionado</p>
        <p className="text-sm text-muted-foreground mt-1 max-w-sm">
          Cargá gastos o compras en el rango de fechas elegido. Para separarlos por área,
          creá tus centros en Configuración → Centros de costo e imputalos al registrarlos.
        </p>
      </div>
    </div>
  )
}
