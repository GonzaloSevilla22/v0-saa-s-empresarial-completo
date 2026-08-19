"use client"

import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { startOfMonth, subDays } from "date-fns"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from "recharts"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { formatMoney } from "@/lib/format"
import {
  mapPaymentMethodReportRow,
  sumPaymentMethodReport,
  type PaymentMethodReportRawRow,
} from "@/lib/payment-method-report"
import type { PaymentMethodReportRow } from "@/lib/types"
import { Wallet } from "lucide-react"

// Paleta de la serie, alineada con /reportes/centros-costo y /reportes/sucursal.
const COLORS = [
  "hsl(var(--primary))",
  "#60a5fa",
  "#34d399",
  "#f59e0b",
  "#f87171",
]

export default function FormasPagoReportPage() {
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const accountId = user?.accountId ?? null

  const today = new Date()
  const [dateFrom, setDateFrom] = useState<Date>(startOfMonth(today))
  const [dateTo,   setDateTo]   = useState<Date>(today)

  // El historial visible sigue la política de plan ya vigente en los otros
  // reportes; el reporte en sí NO está gateado (design.md D10).
  const minDate = subDays(today, limits?.historyDays ?? 30)

  const startISO = toISODate(dateFrom)
  const endISO = toISODate(dateTo)

  // metodos-pago-operaciones (task 4.6): a diferencia del reporte de centros
  // de costo (supabase.rpc directo), este reporte pasa por el backend
  // FastAPI — GET /reports/payment-methods sobre rpc_payment_method_report.
  const { data: rows = [], isLoading } = useQuery<PaymentMethodReportRow[]>({
    queryKey: queryKeys.paymentMethods.report(accountId, startISO, endISO),
    queryFn: async () => {
      const qs = new URLSearchParams({ start: startISO, end: endISO }).toString()
      const data = await pythonClient.get<PaymentMethodReportRawRow[]>(`/reports/payment-methods?${qs}`)
      return data.map(mapPaymentMethodReportRow)
    },
    enabled: !!accountId,
  })

  const totals = sumPaymentMethodReport(rows)

  const chartData = rows.map((r) => ({
    name:      r.name.length > 14 ? `${r.name.slice(0, 12)}…` : r.name,
    Vendido:   Math.round(r.totalSold),
    Comprado:  Math.round(r.totalPurchased),
  }))

  return (
    // min-w-0 en toda la cadena de flex items — ver el mismo comentario en
    // /reportes/centros-costo (tabla de varias columnas empujando el shell).
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Header ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Ventas y compras por forma de pago
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Cuánto se cobró y se pagó con cada forma de pago en el período. No
            descuenta notas de crédito: no tienen una forma de pago atribuible.
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
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Vendido vs Comprado por forma de pago</CardTitle>
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
                <Bar dataKey="Vendido" fill="hsl(var(--primary))" fillOpacity={0.85} radius={[0, 4, 4, 0]}>
                  {chartData.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} fillOpacity={0.85} />
                  ))}
                </Bar>
                <Bar dataKey="Comprado" fill="#60a5fa" fillOpacity={0.7} radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>

      {/* ── Tabla ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Detalle por forma de pago</CardTitle>
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
                  {/* En mobile se muestran solo Forma de pago y Vendido: 5
                      columnas en 375px obligan a scrollear el shell entero. */}
                  <tr className="border-b border-border bg-muted/40">
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">Forma de pago</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Vendido</th>
                    <th className="hidden sm:table-cell px-4 py-3 text-right font-medium text-muted-foreground">Comprado</th>
                    <th className="hidden sm:table-cell px-4 py-3 text-right font-medium text-muted-foreground">Operaciones</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row, i) => (
                    <tr key={row.id ?? "sin-especificar"} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span className={row.id === null ? "text-muted-foreground italic" : "font-medium"}>
                            {row.name}
                          </span>
                          {!row.isActive && (
                            <Badge variant="secondary" className="text-xs">Inactiva</Badge>
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums font-medium">{formatMoney(row.totalSold)}</td>
                      <td className="hidden sm:table-cell px-4 py-3 text-right tabular-nums">{formatMoney(row.totalPurchased)}</td>
                      <td className="hidden sm:table-cell px-4 py-3 text-right tabular-nums">{row.operationCount}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="border-t border-border font-semibold bg-muted/30">
                    <td className="px-4 py-3">Total del período</td>
                    <td className="px-4 py-3 text-right tabular-nums">{formatMoney(totals.totalSold)}</td>
                    <td className="hidden sm:table-cell px-4 py-3 text-right tabular-nums">{formatMoney(totals.totalPurchased)}</td>
                    <td className="hidden sm:table-cell px-4 py-3 text-right tabular-nums">{totals.operationCount}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <p className="text-xs text-muted-foreground">
        Las operaciones sin imputar aparecen como "Sin especificar", así el total de
        la tabla coincide con el período. Las ventas nacidas en el POS muestran la
        forma de pago declarada en la orden. Las formas de pago se crean y se dan
        de baja en Configuración → Formas de pago.
      </p>
    </div>
  )
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-10 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
        <Wallet className="h-6 w-6 text-muted-foreground" />
      </div>
      <div>
        <p className="text-sm font-medium text-foreground">Sin operaciones en el período seleccionado</p>
        <p className="text-sm text-muted-foreground mt-1 max-w-sm">
          Registrá ventas o compras en el rango de fechas elegido. Para separarlas por
          forma de pago, elegí una al cargarlas en el form de venta o de compra.
        </p>
      </div>
    </div>
  )
}
