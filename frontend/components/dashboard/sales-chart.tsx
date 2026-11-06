"use client"

import { useMemo, useState } from "react"
import Link from "next/link"
import { subDays } from "date-fns"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { ReportTimeSeriesChart } from "@/components/charts/ReportTimeSeriesChart"
import { useSalesEvolution } from "@/hooks/data/use-sales-statistics"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import {
  alignComparisonSeries,
  chartBucketFor,
  chartPresetLabel,
  chartPresetRange,
  formatBucketLabel,
  formatBusinessDate,
  percentChange,
  type ChartPreset,
} from "@/lib/sales-statistics"
import { cn } from "@/lib/utils"

const PRESETS: { value: ChartPreset; label: string }[] = [
  { value: "7d", label: "7 días" },
  { value: "30d", label: "30 días" },
  { value: "90d", label: "90 días" },
  { value: "custom", label: "Personalizado" },
]

/** "YYYY-MM-DD" → Date local a medianoche, para los DateButton. */
function isoToLocalDate(iso: string): Date {
  const [y, m, d] = iso.split("-").map(Number)
  return new Date(y, m - 1, d)
}

interface SalesChartProps {
  /** Sucursal activa del Tablero (`?branch=`); `null` = todas. */
  branchId?: string | null
}

/**
 * tablero-explicable (D1-D3): gráfico de ventas del Tablero con rango
 * elegible (7 / 30 / 90 días o personalizado) y comparación con el período
 * anterior de igual longitud.
 *
 * Los datos salen del read-model canónico de /estadisticas
 * (useSalesEvolution → rpc_sales_evolution): neto de notas de crédito,
 * acotado por sucursal y recortado al historial del plan en el servidor. NO
 * se agregan ventas en el cliente. El selector de período mensual del
 * Tablero NO gobierna este gráfico: tiene su propio rango y su título lo dice.
 */
export function SalesChart({ branchId = null }: SalesChartProps) {
  const { limits } = usePlanLimits()
  const [preset, setPreset] = useState<ChartPreset>("7d")
  const [customRange, setCustomRange] = useState<{ start: string; end: string }>(() => chartPresetRange("7d"))

  const range = preset === "custom" ? customRange : chartPresetRange(preset)
  const bucket = chartBucketFor(range.start, range.end)

  const currentQuery = useSalesEvolution({ start: range.start, end: range.end, bucket, branchId })
  const current = currentQuery.data

  // D1: la RPC sólo devuelve los TOTALES del período anterior; los puntos
  // salen de una segunda lectura sobre previous.start/end, habilitada recién
  // cuando la primera respondió.
  const previousQuery = useSalesEvolution({
    start: current?.previous.start ?? range.start,
    end: current?.previous.end ?? range.end,
    bucket,
    branchId,
    enabled: !!current,
  })
  const previous = previousQuery.data

  // D3: la comparación sólo es honesta si el período anterior entero cae
  // dentro del historial del plan.
  const currentClamped = current?.window.clamped ?? false
  const previousClamped = previous?.window.clamped ?? false
  const comparable = !!current && !!previous && !currentClamped && !previousClamped

  const points = current?.points ?? []
  const aligned = comparable
    ? alignComparisonSeries(points.map((p) => p.netRevenue), (previous?.points ?? []).map((p) => p.netRevenue))
    : []
  const chartData = points.map((p, i) => ({
    label: formatBucketLabel(p.bucketStart, current?.bucket ?? bucket),
    value: p.netRevenue,
    ...(comparable && aligned[i] !== null ? { secondary: aligned[i] as number } : {}),
  }))

  const change = comparable ? percentChange(current.current.netRevenue, current.previous.netRevenue) : null

  const today = useMemo(() => new Date(), [])
  const minDate = subDays(today, limits?.historyDays ?? 30)
  const title = chartPresetLabel(preset, range.start, range.end)

  function selectPreset(next: ChartPreset) {
    if (next === "custom") setCustomRange({ start: range.start, end: range.end })
    setPreset(next)
  }

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-2">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div className="flex flex-col gap-0.5 min-w-0">
            <CardTitle className="text-sm font-medium text-card-foreground">{title}</CardTitle>
            {change !== null && (
              <span
                className={cn("text-xs font-medium", change >= 0 ? "text-success" : "text-destructive")}
              >
                {change >= 0 ? "+" : ""}
                {change}% vs. período anterior
              </span>
            )}
          </div>
          <ToggleGroup
            type="single"
            size="sm"
            variant="outline"
            value={preset}
            onValueChange={(v) => { if (v) selectPreset(v as ChartPreset) }}
            aria-label="Rango del gráfico de ventas"
            className="flex-wrap justify-end"
          >
            {PRESETS.map((p) => (
              <ToggleGroupItem key={p.value} value={p.value} aria-label={p.label} className="text-xs px-2.5">
                {p.label}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </div>
        {preset === "custom" && (
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <DateButton
              date={isoToLocalDate(customRange.start)}
              onSelect={(d) => setCustomRange((r) => ({ ...r, start: toISODate(d) }))}
              minDate={minDate}
              maxDate={isoToLocalDate(customRange.end)}
              label="Fecha desde"
            />
            <span className="text-xs text-muted-foreground">→</span>
            <DateButton
              date={isoToLocalDate(customRange.end)}
              onSelect={(d) => setCustomRange((r) => ({ ...r, end: toISODate(d) }))}
              minDate={isoToLocalDate(customRange.start)}
              maxDate={today}
              label="Fecha hasta"
            />
          </div>
        )}
      </CardHeader>
      <CardContent className="pb-4">
        {currentClamped && current && (
          <p role="status" className="mb-2 rounded-md border border-border bg-muted/40 px-3 py-2 text-xs text-foreground">
            Tu plan permite consultar {current.window.historyDays} días de historial: se muestran datos desde{" "}
            {formatBusinessDate(current.window.start)}.{" "}
            <Link href="/planes" className="font-medium text-primary underline underline-offset-2">
              Ver planes
            </Link>
          </p>
        )}
        {!currentClamped && previousClamped && (
          <p role="status" className="mb-2 rounded-md border border-border bg-muted/40 px-3 py-2 text-xs text-foreground">
            El período anterior queda fuera del historial de tu plan, así que no se compara.{" "}
            <Link href="/planes" className="font-medium text-primary underline underline-offset-2">
              Ver planes
            </Link>
          </p>
        )}
        {currentQuery.isError && (
          <p role="alert" className="mb-2 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            No pudimos cargar las ventas del período. Probá de nuevo en unos segundos.
          </p>
        )}
        <ReportTimeSeriesChart
          data={chartData}
          valueName="Ventas netas"
          secondaryName={comparable ? "Período anterior" : undefined}
          ariaLabel={`${title}. Ventas netas de notas de crédito${comparable ? ", con el período anterior de igual longitud" : ""}.`}
          height={250}
        />
      </CardContent>
    </Card>
  )
}
