"use client"

/**
 * estadisticas-ventas E2 (task 7.4, OQ-2) — top clientes del período.
 *
 * Las ventas sin cliente asignado NO compiten en el ranking (en producción
 * son más de un tercio de las líneas y ocuparían el primer puesto siempre sin
 * ser accionables); su importe se declara al pie, para que el usuario que
 * sume la tabla y la compare con la facturación del período no encuentre una
 * diferencia sin explicación.
 */

import { Users } from "lucide-react"
import { ReportBarChart } from "@/components/charts/ReportBarChart"
import { useTopClients } from "@/hooks/data/use-sales-statistics"
import { formatMoney, formatNumber } from "@/lib/format"
import { formatBusinessDate, shareOf } from "@/lib/sales-statistics"

export interface TopClientsSectionProps {
  start: string
  end: string
  branchId: string | null
  limit?: number
}

const TOP_CHART_ROWS = 10

export function TopClientsSection({ start, end, branchId, limit = 10 }: TopClientsSectionProps) {
  const query = useTopClients({ start, end, branchId, limit })

  if (query.isError) {
    return (
      <div role="alert" className="m-4 rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
        No pudimos cargar el top de clientes. Probá de nuevo en unos segundos.
      </div>
    )
  }
  if (query.isLoading || !query.data) {
    return <div className="p-6 h-32 flex items-center justify-center text-muted-foreground text-sm">Cargando...</div>
  }

  const { items, unassigned, totalClients } = query.data
  // Base de la participación: todo lo facturado en el período a clientes
  // identificados + lo no asignado — el mismo total que el resto del módulo.
  const periodRevenue = items.reduce((s, i) => s + i.revenue, 0) + unassigned.revenue

  if (items.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-10 text-center">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
          <Users className="h-6 w-6 text-muted-foreground" />
        </div>
        <div>
          <p className="text-sm font-medium text-foreground">Sin ventas a clientes identificados en el período</p>
          <p className="text-sm text-muted-foreground mt-1 max-w-sm">
            {unassigned.operations > 0
              ? `Hubo ${formatMoney(unassigned.revenue)} en ${formatNumber(unassigned.operations)} ${unassigned.operations === 1 ? "operación" : "operaciones"} sin cliente asignado.`
              : "Asigná el cliente al registrar la venta para verlo acá."}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4 min-w-0">
      <div className="px-4 pt-4">
        <ReportBarChart
          ariaLabel={`Gráfico: top ${Math.min(items.length, TOP_CHART_ROWS)} clientes por importe`}
          valueName="Facturado"
          data={items.slice(0, TOP_CHART_ROWS).map((i) => ({ name: i.clientName, value: i.revenue }))}
          formatValue={formatMoney}
        />
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[680px] text-sm" aria-label="Top clientes del período">
          <thead>
            <tr className="border-b border-border bg-muted/40">
              <th className="px-4 py-2 text-right font-medium text-muted-foreground w-12">#</th>
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">Cliente</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Facturado</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Participación</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Última compra</th>
            </tr>
          </thead>
          <tbody>
            {items.map((row, i) => {
              const share = shareOf(row.revenue, periodRevenue)
              return (
                <tr key={row.clientId ?? `rank-${row.rank}`} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                  <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">{row.rank}</td>
                  <td className={`px-4 py-2 font-medium ${row.clientId === null ? "italic text-muted-foreground" : ""}`}>{row.clientName}</td>
                  <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(row.revenue)}</td>
                  <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                    {share === null ? "—" : `${share.toLocaleString("es-AR", { maximumFractionDigits: 1 })} %`}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatNumber(row.operations)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatNumber(row.units)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{row.lastSaleDate ? formatBusinessDate(row.lastSaleDate) : "—"}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <p className="px-4 pb-4 text-xs text-muted-foreground">
        {formatNumber(totalClients)} {totalClients === 1 ? "cliente" : "clientes"} con compras en el período
        {items.length < totalClients ? ` (se muestran los ${items.length} primeros)` : ""}. Las ventas sin cliente asignado
        ({formatMoney(unassigned.revenue)} en {formatNumber(unassigned.operations)} {unassigned.operations === 1 ? "operación" : "operaciones"})
        no compiten en el ranking: sí forman parte de la facturación del período.
      </p>
    </div>
  )
}
