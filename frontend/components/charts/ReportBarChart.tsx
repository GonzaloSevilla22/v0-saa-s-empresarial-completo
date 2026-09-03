"use client"

/**
 * estadisticas-ventas E1 (task 4.1, D13) — barras horizontales de los
 * reportes (una serie, una barra por categoría). Ver ReportTimeSeriesChart
 * para el porqué de la extracción y el contrato accesible.
 */

import { Bar, BarChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { REPORT_SERIES_COLORS } from "@/lib/report-chart-colors"
import { formatNumber } from "@/lib/format"

export interface ReportBarDatum {
  name: string
  value: number
}

export interface ReportBarChartProps {
  data: ReportBarDatum[]
  valueName: string
  ariaLabel: string
  /** Color de la serie — por defecto la serie "vendido" del sistema. */
  color?: string
  height?: number
  formatValue?: (value: number) => string
  /** Ancho reservado a los rótulos de categoría. */
  labelWidth?: number
}

const truncate = (s: string, max = 18) => (s.length > max ? `${s.slice(0, max - 1)}…` : s)

export function ReportBarChart({
  data,
  valueName,
  ariaLabel,
  color = REPORT_SERIES_COLORS.sold,
  height,
  formatValue = formatNumber,
  labelWidth = 120,
}: ReportBarChartProps) {
  const resolvedHeight = height ?? Math.max(160, 28 * data.length + 40)

  if (data.length === 0) {
    return (
      <div
        className="flex items-center justify-center text-sm text-muted-foreground"
        style={{ height: resolvedHeight }}
      >
        Sin datos para graficar
      </div>
    )
  }

  const chartData = data.map((d) => ({ ...d, label: truncate(d.name) }))

  return (
    <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height: resolvedHeight }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 24, top: 4, bottom: 4 }}>
          <XAxis type="number" tickFormatter={(v: number) => formatValue(v)} tick={{ fontSize: 11 }} />
          <YAxis type="category" dataKey="label" width={labelWidth} tick={{ fontSize: 12 }} />
          <Tooltip
            formatter={(v: number) => [formatValue(v), valueName]}
            labelFormatter={(_label: string, payload) => {
              const first = Array.isArray(payload) && payload.length > 0 ? payload[0] : null
              const original = first && typeof first.payload === "object" && first.payload !== null
                ? (first.payload as ReportBarDatum).name
                : String(_label)
              return original
            }}
          />
          <Bar dataKey="value" name={valueName} fill={color} fillOpacity={0.85} radius={[0, 4, 4, 0]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
