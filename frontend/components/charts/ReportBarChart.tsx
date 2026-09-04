"use client"

/**
 * estadisticas-ventas E1 (task 4.1, D13) — barras de los reportes (una serie,
 * una barra por categoría). Ver ReportTimeSeriesChart para el porqué de la
 * extracción y el contrato accesible.
 *
 * E2: `orientation`. "horizontal" (por defecto) = barras acostadas, una por
 * fila, para rankings con rótulos largos (productos, clientes, canales);
 * "vertical" = columnas, para dimensiones temporales con muchos tramos
 * cortos (7 días, 24 horas) que acostadas ocuparían media pantalla.
 */

import { Bar, BarChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
import { REPORT_SERIES_COLORS } from "@/lib/report-chart-colors"
import { formatNumber } from "@/lib/format"

export interface ReportBarDatum {
  /** Rótulo del eje (puede ser una forma corta). */
  name: string
  value: number
  /** Rótulo completo para el tooltip cuando `name` es una forma corta. */
  tooltipName?: string
}

export type ReportBarOrientation = "horizontal" | "vertical"

export interface ReportBarChartProps {
  data: ReportBarDatum[]
  valueName: string
  ariaLabel: string
  /** Color de la serie — por defecto la serie "vendido" del sistema. */
  color?: string
  height?: number
  formatValue?: (value: number) => string
  /** Ancho reservado a los rótulos de categoría (orientación horizontal). */
  labelWidth?: number
  orientation?: ReportBarOrientation
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
  orientation = "horizontal",
}: ReportBarChartProps) {
  const resolvedHeight = height ?? (orientation === "vertical" ? 240 : Math.max(160, 28 * data.length + 40))

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

  const chartData = data.map((d) => ({ ...d, label: orientation === "vertical" ? d.name : truncate(d.name) }))
  const tooltipLabel = (_label: string, payload: unknown) => {
    const first = Array.isArray(payload) && payload.length > 0 ? payload[0] : null
    const datum = first && typeof first === "object" && first !== null && "payload" in first
      && typeof (first as { payload: unknown }).payload === "object" && (first as { payload: unknown }).payload !== null
      ? ((first as { payload: ReportBarDatum }).payload)
      : null
    return datum ? (datum.tooltipName ?? datum.name) : String(_label)
  }

  if (orientation === "vertical") {
    return (
      <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height: resolvedHeight }}>
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={chartData} margin={{ left: 8, right: 16, top: 8, bottom: 4 }}>
            {/* preserveStartEnd: Recharts mide cada rótulo y omite los que se
                solaparían (24 horas en 300 px de móvil), conservando extremos. */}
            <XAxis dataKey="label" tick={{ fontSize: 11 }} interval="preserveStartEnd" minTickGap={6} />
            <YAxis type="number" tickFormatter={(v: number) => formatValue(v)} tick={{ fontSize: 11 }} width={64} />
            <Tooltip formatter={(v: number) => [formatValue(v), valueName]} labelFormatter={tooltipLabel} />
            <Bar dataKey="value" name={valueName} fill={color} fillOpacity={0.85} radius={[4, 4, 0, 0]} isAnimationActive={false} />
          </BarChart>
        </ResponsiveContainer>
      </div>
    )
  }

  return (
    <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height: resolvedHeight }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 24, top: 4, bottom: 4 }}>
          <XAxis type="number" tickFormatter={(v: number) => formatValue(v)} tick={{ fontSize: 11 }} />
          <YAxis type="category" dataKey="label" width={labelWidth} tick={{ fontSize: 12 }} />
          <Tooltip formatter={(v: number) => [formatValue(v), valueName]} labelFormatter={tooltipLabel} />
          <Bar dataKey="value" name={valueName} fill={color} fillOpacity={0.85} radius={[0, 4, 4, 0]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
