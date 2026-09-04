"use client"

/**
 * estadisticas-ventas E2 (tasks 7.1-7.3) — desglose del período por UNA
 * dimensión (canal / sucursal / día de la semana / horario de carga /
 * categoría): gráfico + tabla (la alternativa textual) + estados.
 *
 * Consulta su propia dimensión (useSalesBreakdown), así que sólo la pestaña
 * montada dispara la consulta. El tramo "Sin canal" / "Sin sucursal" /
 * "Sin categoría" llega del read-model con key null y se muestra como una
 * fila más — nunca se filtra ni se esconde al final: en producción es la
 * mayoría del dinero.
 *
 * `bandView` (sólo horario): agrupa las 24 horas en franjas EN EL CLIENTE
 * (D5) — sin re-consulta.
 */

import type { ReactNode } from "react"
import { ReportBarChart, type ReportBarOrientation } from "@/components/charts/ReportBarChart"
import { useSalesBreakdown } from "@/hooks/data/use-sales-statistics"
import { formatMoney, formatNumber } from "@/lib/format"
import {
  BREAKDOWN_DIMENSION_LABELS,
  breakdownChartLabel,
  breakdownRowLabel,
  groupHoursIntoBands,
  shareOf,
  sumBreakdown,
  type BreakdownDimension,
  type SalesBreakdownRow,
} from "@/lib/sales-statistics"

export interface DimensionBreakdownSectionProps {
  dimension: BreakdownDimension
  /** "YYYY-MM-DD" (fecha de negocio). */
  start: string
  end: string
  branchId: string | null
  /** aria-label de la tabla y del gráfico. */
  ariaLabel: string
  /** Horario: agrupar en franjas (presentación, D5). */
  bandView?: boolean
  /** Categoría: una operación puede abarcar varias categorías, así que la
   *  suma de operaciones de los tramos no es el total de operaciones. */
  operationsTotal?: boolean
  orientation?: ReportBarOrientation
  /** Cuántos tramos dibujar (la tabla siempre los muestra todos). */
  chartRows?: number
  footnote?: ReactNode
}

const MAX_CHART_ROWS = 12

export function DimensionBreakdownSection({
  dimension,
  start,
  end,
  branchId,
  ariaLabel,
  bandView = false,
  operationsTotal = true,
  orientation = "horizontal",
  chartRows = MAX_CHART_ROWS,
  footnote,
}: DimensionBreakdownSectionProps) {
  const query = useSalesBreakdown({ start, end, dimension, branchId })
  const label = BREAKDOWN_DIMENSION_LABELS[dimension].toLowerCase()

  if (query.isError) {
    return (
      <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
        No pudimos cargar el desglose por {label}. Probá de nuevo en unos segundos.
      </div>
    )
  }
  if (query.isLoading || !query.data) {
    return <div className="h-32 flex items-center justify-center text-muted-foreground text-sm">Cargando...</div>
  }

  const sourceRows: SalesBreakdownRow[] = query.data.rows
  const rows = bandView ? groupHoursIntoBands(sourceRows) : sourceRows
  const totals = sumBreakdown(rows)

  if (rows.length === 0 || (totals.revenue === 0 && totals.operations === 0)) {
    return (
      <p className="py-6 text-center text-sm text-muted-foreground">
        Sin ventas en el período para este desglose.
      </p>
    )
  }

  // Eje con rótulo corto (día abreviado / franja sin rango) para que en móvil
  // no se solape; el tooltip y la tabla conservan el rótulo completo.
  const chartData = rows.slice(0, orientation === "vertical" ? rows.length : chartRows).map((r) => ({
    name:        breakdownChartLabel(r, dimension, bandView),
    tooltipName: breakdownRowLabel(r, dimension),
    value:       r.revenue,
  }))

  return (
    <div className="flex flex-col gap-4 min-w-0">
      <ReportBarChart
        ariaLabel={`Gráfico: ${ariaLabel}`}
        valueName="Facturado"
        data={chartData}
        formatValue={formatMoney}
        orientation={orientation}
      />
      <div className="overflow-x-auto">
        <table className="w-full min-w-[560px] text-sm" aria-label={ariaLabel}>
          <thead>
            <tr className="border-b border-border bg-muted/40">
              <th className="px-4 py-2 text-left font-medium text-muted-foreground">{BREAKDOWN_DIMENSION_LABELS[dimension]}</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Facturado</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Participación</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
              <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => {
              const share = shareOf(r.revenue, totals.revenue)
              return (
                <tr key={r.key ?? "__none__"} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                  <td className={`px-4 py-2 ${r.key === null ? "italic" : ""}`}>{breakdownRowLabel(r, dimension)}</td>
                  <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(r.revenue)}</td>
                  <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">
                    {share === null ? "—" : `${share.toLocaleString("es-AR", { maximumFractionDigits: 1 })} %`}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatNumber(r.operations)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatNumber(r.units)}</td>
                </tr>
              )
            })}
          </tbody>
          <tfoot>
            <tr className="border-t border-border font-semibold bg-muted/30">
              <td className="px-4 py-2">Total</td>
              <td className="px-4 py-2 text-right tabular-nums">{formatMoney(totals.revenue)}</td>
              <td className="px-4 py-2 text-right tabular-nums">100 %</td>
              <td className="px-4 py-2 text-right tabular-nums" title={operationsTotal ? undefined : "Una operación puede abarcar varias categorías; la suma de los tramos no es el total de operaciones."}>
                {operationsTotal ? formatNumber(totals.operations) : "—"}
              </td>
              <td className="px-4 py-2 text-right tabular-nums">{formatNumber(totals.units)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      {footnote && <p className="text-xs text-muted-foreground">{footnote}</p>}
    </div>
  )
}
