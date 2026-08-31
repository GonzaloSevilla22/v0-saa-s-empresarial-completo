"use client"

import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { startOfMonth, subDays } from "date-fns"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useAuth } from "@/contexts/auth-context"
import { createClient } from "@/lib/supabase/client"
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from "recharts"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { Crown, MapPin } from "lucide-react"

// ─── Types ────────────────────────────────────────────────────────────────────

interface BranchReportRow {
  branch_id:       string | null
  branch_name:     string
  total_sales:     number
  total_expenses:  number
  operation_count: number
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const fmtARS  = (n: number) =>
  new Intl.NumberFormat("es-AR", { style: "currency", currency: "ARS", maximumFractionDigits: 0 }).format(n)

const toISO = toISODate

const COLORS = [
  "hsl(var(--primary))",
  "#60a5fa",
  "#34d399",
  "#f59e0b",
  "#f87171",
]

// ─── Plan gate ────────────────────────────────────────────────────────────────

function PlanGateFallback() {
  return (
    <div className="flex flex-col items-center justify-center gap-6 py-24 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-yellow-500/10">
        <Crown className="h-8 w-8 text-yellow-500" />
      </div>
      <div>
        <h2 className="text-xl font-bold text-foreground">Reporte por Sucursal</h2>
        <p className="mt-2 text-sm text-muted-foreground max-w-sm">
          Analizá el rendimiento de cada punto de venta. Disponible en el plan{" "}
          <span className="font-semibold text-foreground">PRO</span>.
        </p>
      </div>
      <Button variant="default" className="bg-yellow-500 hover:bg-yellow-400 text-black font-semibold">
        <MapPin className="mr-2 h-4 w-4" />
        Actualizar a PRO
      </Button>
    </div>
  )
}

// ─── Main page ────────────────────────────────────────────────────────────────

export default function SucursalReportPage() {
  const { limits, isLoading: gateLoading } = usePlanLimits()
  // qa-integral-modulos (G4/H4): el tenant se resuelve por el canon de
  // account_members (auth-context) — la lectura vieja de
  // user_metadata.account_id no la escribe NADA en ningún entorno, así que la
  // pantalla devolvía [] en silencio para todos los usuarios desde C-06.
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  const today = new Date()
  const [dateFrom, setDateFrom] = useState<Date>(startOfMonth(today))
  const [dateTo,   setDateTo]   = useState<Date>(today)

  const minDate = subDays(today, limits?.historyDays ?? 30)

  const { data: rows = [], isLoading, isError } = useQuery<BranchReportRow[]>({
    queryKey: ["branchReport", accountId, toISO(dateFrom), toISO(dateTo)],
    queryFn: async () => {
      const supabase = createClient()
      const { data, error } = await supabase.rpc("rpc_branch_report", {
        p_account_id: accountId!,
        p_start:      toISO(dateFrom),
        p_end:        toISO(dateTo),
      })

      if (error) throw new Error(error.message)
      return (data ?? []).map((r: Record<string, unknown>) => ({
        branch_id:       r.branch_id       as string | null,
        branch_name:     r.branch_name     as string,
        total_sales:     Number(r.total_sales    ?? 0),
        total_expenses:  Number(r.total_expenses ?? 0),
        operation_count: Number(r.operation_count ?? 0),
      }))
    },
    enabled: !!limits?.hasBranchesModule && !!accountId,
  })

  if (gateLoading) return null
  if (!limits?.hasBranchesModule) return <PlanGateFallback />

  const totals = rows.reduce(
    (acc, r) => ({
      sales:      acc.sales      + r.total_sales,
      expenses:   acc.expenses   + r.total_expenses,
      operations: acc.operations + r.operation_count,
    }),
    { sales: 0, expenses: 0, operations: 0 }
  )

  const chartData = rows.map(r => ({
    name:    r.branch_name.length > 14 ? `${r.branch_name.slice(0, 12)}…` : r.branch_name,
    Ventas:  Math.round(r.total_sales),
    Gastos:  Math.round(r.total_expenses),
  }))

  return (
    <div className="flex flex-col gap-6">
      {/* ── Header ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Reporte por Sucursal</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Rendimiento de cada punto de venta en el período seleccionado
          </p>
        </div>

        {/* Date range */}
        <div className="flex items-center gap-2">
          <DateButton date={dateFrom} onSelect={setDateFrom} minDate={minDate} maxDate={dateTo} />
          <span className="text-xs text-muted-foreground">→</span>
          <DateButton date={dateTo} onSelect={setDateTo} minDate={dateFrom} maxDate={today} />
        </div>
      </div>

      {/* ── Bar chart ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Ventas vs Gastos por Sucursal</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="h-56 flex items-center justify-center text-muted-foreground text-sm">
              Cargando...
            </div>
          ) : isError ? (
            // qa-integral-modulos (G4/H4): rama de error VISIBLE — sin ella,
            // un fallo de la RPC quedaba tapado como "Sin datos" en silencio.
            <div className="h-56 flex items-center justify-center px-4 text-center text-sm text-destructive">
              No se pudo cargar el reporte por sucursal. Probá de nuevo en unos
              segundos; si sigue fallando, avisanos.
            </div>
          ) : rows.length === 0 ? (
            <div className="h-56 flex items-center justify-center text-muted-foreground text-sm">
              Sin datos para el período seleccionado
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 16, top: 4 }}>
                <XAxis type="number" tickFormatter={(v) => `$${Math.round(v / 1000)}K`} tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="name" width={90} tick={{ fontSize: 12 }} />
                <Tooltip formatter={(v: number, name: string) => [fmtARS(v), name]} />
                <Bar dataKey="Ventas" fill="hsl(var(--primary))" fillOpacity={0.85} radius={[0, 4, 4, 0]}>
                  {chartData.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} fillOpacity={0.85} />
                  ))}
                </Bar>
                <Bar dataKey="Gastos" fill="#f87171" fillOpacity={0.7} radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>

      {/* ── Table ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Detalle por Sucursal</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading ? (
            <div className="p-6 text-center text-muted-foreground text-sm">Cargando...</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-muted/40">
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">Sucursal</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Ventas</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Gastos</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Operaciones</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row, i) => (
                    <tr key={row.branch_id ?? "null"} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                      <td className="px-4 py-3 font-medium">{row.branch_name}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{fmtARS(row.total_sales)}</td>
                      <td className="px-4 py-3 text-right tabular-nums text-red-400">{fmtARS(row.total_expenses)}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{row.operation_count}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="border-t border-border font-semibold bg-muted/30">
                    <td className="px-4 py-3">Total</td>
                    <td className="px-4 py-3 text-right tabular-nums">{fmtARS(totals.sales)}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-red-400">{fmtARS(totals.expenses)}</td>
                    <td className="px-4 py-3 text-right tabular-nums">{totals.operations}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
