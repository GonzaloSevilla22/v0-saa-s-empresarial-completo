"use client"

/**
 * estadisticas-ventas E1 (task 4.1, D13) — serie temporal de los reportes.
 *
 * Extraído a components/charts/ porque tres reportes ya repetían el mismo
 * gráfico inline y este change suma cuatro más (Regla de Tres cumplida). Los
 * consume sólo la superficie nueva: migrar /reportes/* queda como candidato.
 *
 * Contrato: color por SERIE (REPORT_SERIES_COLORS — nunca paleta rotativa
 * por punto), `role="img"` + aria-label para lectores de pantalla, y la
 * tabla que acompaña al gráfico en la pantalla es la alternativa textual.
 */

import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts"
import { REPORT_SERIES_COLORS } from "@/lib/report-chart-colors"
import { formatMoney } from "@/lib/format"

export interface ReportTimeSeriesPoint {
  label: string
  value: number
  /** Serie secundaria opcional (p. ej. facturación bruta junto a la neta). */
  secondary?: number
}

export interface ReportTimeSeriesChartProps {
  data: ReportTimeSeriesPoint[]
  /** Nombre de la serie principal (leyenda y tooltip). */
  valueName: string
  secondaryName?: string
  ariaLabel: string
  height?: number
  formatValue?: (value: number) => string
}

const compactMoney = (v: number) => (Math.abs(v) >= 1000 ? `$${Math.round(v / 1000)}K` : `$${Math.round(v)}`)

export function ReportTimeSeriesChart({
  data,
  valueName,
  secondaryName,
  ariaLabel,
  height = 260,
  formatValue = formatMoney,
}: ReportTimeSeriesChartProps) {
  if (data.length === 0) {
    return (
      <div
        className="flex items-center justify-center text-sm text-muted-foreground"
        style={{ height }}
      >
        Sin datos para graficar
      </div>
    )
  }

  return (
    <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={data} margin={{ left: 8, right: 16, top: 8, bottom: 4 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" />
          <XAxis dataKey="label" tick={{ fontSize: 11 }} interval="preserveStartEnd" minTickGap={24} />
          <YAxis tickFormatter={compactMoney} tick={{ fontSize: 11 }} width={56} />
          <Tooltip formatter={(v: number, name: string) => [formatValue(v), name]} />
          {secondaryName && <Legend wrapperStyle={{ fontSize: 12 }} />}
          <Line
            type="monotone"
            dataKey="value"
            name={valueName}
            stroke={REPORT_SERIES_COLORS.sold}
            strokeWidth={2}
            dot={data.length <= 45}
            activeDot={{ r: 4 }}
            isAnimationActive={false}
          />
          {secondaryName && (
            <Line
              type="monotone"
              dataKey="secondary"
              name={secondaryName}
              stroke={REPORT_SERIES_COLORS.purchased}
              strokeWidth={1.5}
              strokeDasharray="4 3"
              dot={false}
              isAnimationActive={false}
            />
          )}
        </LineChart>
      </ResponsiveContainer>
    </div>
  )
}
