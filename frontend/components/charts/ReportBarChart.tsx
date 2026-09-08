"use client"

/**
 * estadisticas-ventas E1 (task 4.1, D13) — barras de los reportes. Ver
 * ReportTimeSeriesChart para el porqué de la extracción y el contrato
 * accesible.
 *
 * E2: `orientation`. "horizontal" (por defecto) = barras acostadas, una por
 * fila, para rankings con rótulos largos (productos, clientes, canales);
 * "vertical" = columnas, para dimensiones temporales con muchos tramos
 * cortos (7 días, 24 horas) que acostadas ocuparían media pantalla.
 *
 * migrar-reportes-a-charts-canonicos: `series` — una barra por categoría,
 * VARIAS series por barra (p. ej. Vendido/Comprado/Gastado). Los tres
 * reportes legacy (/reportes/formas-pago, /reportes/centros-costo,
 * /reportes/sucursal) traían su propio <BarChart> multi-serie inline;
 * `valueName`/`color`/`value` (una sola serie, sin leyenda) queda intacto
 * para los consumidores de estadisticas-ventas que no la necesitan.
 */

import { Bar, BarChart, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts"
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

/** Una serie de un gráfico multi-serie — ver `series` en ReportBarChartProps. */
export interface ReportBarSeries {
  /** Clave del dato en cada fila de `data` (p. ej. "Vendido"). */
  key: string
  /** Rótulo de leyenda/tooltip — normalmente igual a `key`. */
  name: string
  color: string
}

/** Fila de un gráfico multi-serie: el rótulo de categoría + un valor por serie. */
export type ReportBarMultiDatum = { name: string; tooltipName?: string } & Record<string, number | string | undefined>

export interface ReportBarChartProps {
  /** Multi-serie: filas con una clave por `series[].key`. Una serie: `ReportBarDatum[]`. */
  data: ReportBarDatum[] | ReportBarMultiDatum[]
  /** Requerido cuando no se pasa `series` (una sola serie, sin leyenda). */
  valueName?: string
  ariaLabel: string
  /** Color de la serie única — por defecto la serie "vendido" del sistema. Ignorado si se pasa `series`. */
  color?: string
  /** Varias series por barra (Vendido/Comprado/Gastado, Gastos/Compras, …) — agrega leyenda. */
  series?: ReportBarSeries[]
  height?: number
  formatValue?: (value: number) => string
  /**
   * Formato del eje numérico cuando difiere del tooltip — p. ej. montos en
   * notación compacta ("$6K") en el eje contra el monto completo en el
   * tooltip. Por defecto usa `formatValue` (mismo formato en ambos).
   */
  formatAxisValue?: (value: number) => string
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
  series,
  height,
  formatValue = formatNumber,
  formatAxisValue = formatValue,
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

  // Multi-serie: una <Bar> por serie + leyenda. El color sigue a la ENTIDAD
  // (la serie), nunca a la fila — nunca <Cell> con paleta rotativa (skill de
  // dataviz; era el bug real: la paleta rotada colisionaba con el fill fijo
  // de otra serie, ver REPORT_SERIES_COLORS).
  const bars = series
    ? series.map((s) => (
        <Bar
          key={s.key}
          dataKey={s.key}
          name={s.name}
          fill={s.color}
          fillOpacity={0.85}
          radius={orientation === "vertical" ? [4, 4, 0, 0] : [0, 4, 4, 0]}
          isAnimationActive={false}
        />
      ))
    : [
        <Bar
          key="value"
          dataKey="value"
          name={valueName}
          fill={color}
          fillOpacity={0.85}
          radius={orientation === "vertical" ? [4, 4, 0, 0] : [0, 4, 4, 0]}
          isAnimationActive={false}
        />,
      ]

  if (orientation === "vertical") {
    return (
      <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height: resolvedHeight }}>
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={chartData} margin={{ left: 8, right: 16, top: 8, bottom: 4 }}>
            {/* preserveStartEnd: Recharts mide cada rótulo y omite los que se
                solaparían (24 horas en 300 px de móvil), conservando extremos. */}
            <XAxis dataKey="label" tick={{ fontSize: 11 }} interval="preserveStartEnd" minTickGap={6} />
            <YAxis type="number" tickFormatter={(v: number) => formatAxisValue(v)} tick={{ fontSize: 11 }} width={64} />
            <Tooltip formatter={(v: number, name: string) => [formatValue(v), name]} labelFormatter={tooltipLabel} />
            {series && <Legend wrapperStyle={{ fontSize: 12 }} />}
            {bars}
          </BarChart>
        </ResponsiveContainer>
      </div>
    )
  }

  return (
    <div role="img" aria-label={ariaLabel} className="min-w-0" style={{ height: resolvedHeight }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 24, top: 4, bottom: 4 }}>
          <XAxis type="number" tickFormatter={(v: number) => formatAxisValue(v)} tick={{ fontSize: 11 }} />
          <YAxis type="category" dataKey="label" width={labelWidth} tick={{ fontSize: 12 }} />
          <Tooltip formatter={(v: number, name: string) => [formatValue(v), name]} labelFormatter={tooltipLabel} />
          {series && <Legend wrapperStyle={{ fontSize: 12 }} />}
          {bars}
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
