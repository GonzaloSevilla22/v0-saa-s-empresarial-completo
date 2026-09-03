"use client"

/**
 * /estadisticas — estadisticas-ventas E1 (tasks 4.4-4.10).
 *
 * Responde "qué se vende y cuándo": evolución de la facturación por
 * día/semana/mes con comparación contra el período anterior, y ranking de
 * productos por unidades / importe / margen con variantes agrupadas.
 *
 * Molde de /reportes/formas-pago (DateButton, Card, tabla overflow-x-auto con
 * tfoot, EmptyState, nota al pie). Disponible en todos los planes: el
 * historial se recorta en el SERVIDOR y la ventana aplicada llega en la
 * respuesta (D8) — acá sólo se explica el recorte.
 *
 * Lo que la pantalla declara, porque callarlo sería mentir por omisión:
 * - las líneas de servicio facturan pero no rankean (D6) → importe al pie;
 * - la evolución descuenta notas de crédito (como el Tablero) y el ranking
 *   no puede (una NC no tiene producto) (D7) → nota al pie;
 * - un margen sin costo es "—", nunca 0, y la cobertura parcial se marca (D11).
 */

import { useMemo, useState } from "react"
import { subDays } from "date-fns"
import { BarChart3, Hash, Package, TrendingUp } from "lucide-react"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useProductRanking, useSalesEvolution } from "@/hooks/data/use-sales-statistics"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { ReportTimeSeriesChart } from "@/components/charts/ReportTimeSeriesChart"
import { ReportBarChart } from "@/components/charts/ReportBarChart"
import { formatMoney, formatNumber } from "@/lib/format"
import {
  EVOLUTION_BUCKET_LABELS,
  RANKING_ORDER_LABELS,
  defaultStatisticsRange,
  formatBucketLabel,
  formatBusinessDate,
  marginCell,
  percentChange,
  type EvolutionBucket,
  type ProductRankingRow,
  type RankingOrder,
} from "@/lib/sales-statistics"

const RANKING_PAGE_SIZE = 25
const TOP_CHART_ROWS = 10

const BUCKETS: EvolutionBucket[] = ["day", "week", "month"]
const ORDERS: RankingOrder[] = ["units", "revenue", "margin"]

function rankingMetric(row: ProductRankingRow, orderBy: RankingOrder): number {
  if (orderBy === "units") return row.units
  if (orderBy === "revenue") return row.revenue
  return row.grossMargin ?? 0
}

export default function EstadisticasPage() {
  const { limits } = usePlanLimits()

  const today = useMemo(() => new Date(), [])
  const defaults = useMemo(() => defaultStatisticsRange(today), [today])
  const [dateFrom, setDateFrom] = useState<Date>(defaults.from)
  const [dateTo, setDateTo] = useState<Date>(defaults.to)
  const [bucket, setBucket] = useState<EvolutionBucket>("day")
  const [orderBy, setOrderBy] = useState<RankingOrder>("units")
  const [groupVariants, setGroupVariants] = useState(true)
  const [page, setPage] = useState(0)

  // Cota visual del calendario según el plan (como los otros reportes); la
  // cota REAL la aplica el read-model (D8) aunque el cliente no coopere.
  const minDate = subDays(today, limits?.historyDays ?? 30)
  const startISO = toISODate(dateFrom)
  const endISO = toISODate(dateTo)

  const evolutionQuery = useSalesEvolution({ start: startISO, end: endISO, bucket })
  const rankingQuery = useProductRanking({
    start: startISO, end: endISO, orderBy, groupVariants, page, size: RANKING_PAGE_SIZE,
  })

  const evolution = evolutionQuery.data
  const ranking = rankingQuery.data

  const window = evolution?.window ?? ranking?.window ?? null
  const hasSales = (evolution?.current.operations ?? 0) > 0
  const chartData = (evolution?.points ?? []).map((p) => ({
    label: formatBucketLabel(p.bucketStart, evolution?.bucket ?? bucket),
    value: p.netRevenue,
  }))
  const topRows = (ranking?.items ?? []).slice(0, TOP_CHART_ROWS)
  const rankingChartData = topRows.map((r) => ({ name: r.productName, value: rankingMetric(r, orderBy) }))
  const rankingFormat = orderBy === "units" ? formatNumber : formatMoney

  const netChange = evolution ? percentChange(evolution.current.netRevenue, evolution.previous.netRevenue) : null
  const opsChange = evolution ? percentChange(evolution.current.operations, evolution.previous.operations) : null
  const unitsChange = evolution ? percentChange(evolution.current.units, evolution.previous.units) : null

  const changeOrigin = (from: Date) => {
    setDateFrom(from)
    setPage(0)
  }
  const changeEnd = (to: Date) => {
    setDateTo(to)
    setPage(0)
  }

  return (
    // min-w-0 en toda la cadena de flex items: una tabla de varias columnas
    // no debe empujar el shell (responsive-shell, qa-integral-modulos G2).
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Header ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Estadísticas de ventas</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Qué se vende y cuándo: evolución de la facturación y ranking de productos del período.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <DateButton date={dateFrom} onSelect={changeOrigin} minDate={minDate} maxDate={dateTo} label="Fecha desde" />
          <span className="text-xs text-muted-foreground">→</span>
          <DateButton date={dateTo} onSelect={changeEnd} minDate={dateFrom} maxDate={today} label="Fecha hasta" />
          <ToggleGroup
            type="single"
            size="sm"
            variant="outline"
            value={bucket}
            onValueChange={(v) => { if (v) setBucket(v as EvolutionBucket) }}
            aria-label="Granularidad de la evolución"
          >
            {BUCKETS.map((b) => (
              <ToggleGroupItem key={b} value={b} aria-label={EVOLUTION_BUCKET_LABELS[b]} className="text-xs px-3">
                {EVOLUTION_BUCKET_LABELS[b]}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </div>
      </div>

      {/* ── Aviso de recorte de historial (D8) ── */}
      {window?.clamped && (
        <div
          role="status"
          aria-label="Aviso de historial"
          className="rounded-md border border-border bg-muted/40 px-4 py-3 text-sm text-foreground"
        >
          Tu plan permite consultar {window.historyDays} días de historial: se muestran datos desde{" "}
          {formatBusinessDate(window.start)}. Para ver más atrás, ampliá tu plan.
        </div>
      )}

      {/* ── Estado de error global ── */}
      {evolutionQuery.isError && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          No pudimos cargar la evolución de ventas. Probá de nuevo en unos segundos.
        </div>
      )}

      {/* ── KPIs del período ── */}
      {evolution && (
        <div className="grid gap-4 sm:grid-cols-3">
          <KpiCard
            title="Facturación neta"
            value={formatMoney(evolution.current.netRevenue)}
            change={netChange ?? undefined}
            changeLabel="vs período anterior"
            icon={TrendingUp}
          />
          <KpiCard
            title="Operaciones"
            value={formatNumber(evolution.current.operations)}
            change={opsChange ?? undefined}
            changeLabel="vs período anterior"
            icon={Hash}
          />
          <KpiCard
            title="Unidades"
            value={formatNumber(evolution.current.units)}
            change={unitsChange ?? undefined}
            changeLabel="vs período anterior"
            icon={Package}
          />
        </div>
      )}

      {/* ── Evolución ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">
            Evolución de la facturación neta por {EVOLUTION_BUCKET_LABELS[bucket].toLowerCase()}
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 min-w-0">
          {evolutionQuery.isLoading ? (
            <Loading />
          ) : evolutionQuery.isError || !evolution ? (
            !evolutionQuery.isError && <Loading />
          ) : !hasSales ? (
            <EmptyState />
          ) : (
            <>
              <ReportTimeSeriesChart
                ariaLabel={`Evolución de la facturación neta por ${EVOLUTION_BUCKET_LABELS[bucket].toLowerCase()}`}
                valueName="Neto"
                data={chartData}
              />
              <div className="overflow-x-auto">
                <table className="w-full min-w-[640px] text-sm" aria-label="Evolución de ventas">
                  <thead>
                    <tr className="border-b border-border bg-muted/40">
                      <th className="px-4 py-2 text-left font-medium text-muted-foreground">{EVOLUTION_BUCKET_LABELS[bucket]}</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Facturado</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Notas de crédito</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Neto</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
                    </tr>
                  </thead>
                  <tbody>
                    {evolution.points.map((p, i) => (
                      <tr key={p.bucketStart} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                        <td className="px-4 py-2 tabular-nums">{formatBucketLabel(p.bucketStart, evolution.bucket)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{formatMoney(p.revenue)}</td>
                        <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">{formatMoney(p.creditNotes)}</td>
                        <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(p.netRevenue)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{formatNumber(p.operations)}</td>
                        <td className="px-4 py-2 text-right tabular-nums">{formatNumber(p.units)}</td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot>
                    <tr className="border-t border-border font-semibold bg-muted/30">
                      <td className="px-4 py-2">Totales del período</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.current.revenue)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.current.creditNotes)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.current.netRevenue)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatNumber(evolution.current.operations)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatNumber(evolution.current.units)}</td>
                    </tr>
                    <tr className="text-muted-foreground">
                      <td className="px-4 py-2">
                        Período anterior ({formatBusinessDate(evolution.previous.start)} → {formatBusinessDate(evolution.previous.end)})
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.previous.revenue)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.previous.creditNotes)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatMoney(evolution.previous.netRevenue)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatNumber(evolution.previous.operations)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatNumber(evolution.previous.units)}</td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            </>
          )}
        </CardContent>
      </Card>

      {/* ── Ranking de productos ── */}
      <Card className="min-w-0">
        <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <CardTitle className="text-sm font-medium">Ranking de productos por {RANKING_ORDER_LABELS[orderBy].toLowerCase()}</CardTitle>
          <div className="flex flex-wrap items-center gap-4">
            <ToggleGroup
              type="single"
              size="sm"
              variant="outline"
              value={orderBy}
              onValueChange={(v) => { if (v) { setOrderBy(v as RankingOrder); setPage(0) } }}
              aria-label="Ordenar el ranking por"
            >
              {ORDERS.map((o) => (
                <ToggleGroupItem key={o} value={o} aria-label={RANKING_ORDER_LABELS[o]} className="text-xs px-3">
                  {RANKING_ORDER_LABELS[o]}
                </ToggleGroupItem>
              ))}
            </ToggleGroup>
            <div className="flex items-center gap-2">
              <Switch
                id="group-variants"
                checked={groupVariants}
                onCheckedChange={(checked) => { setGroupVariants(checked); setPage(0) }}
              />
              <Label htmlFor="group-variants" className="text-xs">Agrupar variantes</Label>
            </div>
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-0 min-w-0">
          {rankingQuery.isError ? (
            <div role="alert" className="m-4 rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
              No pudimos cargar el ranking de productos. Probá de nuevo en unos segundos.
            </div>
          ) : rankingQuery.isLoading || !ranking ? (
            <div className="p-6"><Loading /></div>
          ) : ranking.items.length === 0 ? (
            <div className="p-6"><EmptyState /></div>
          ) : (
            <>
              <div className="px-4 pt-4">
                <ReportBarChart
                  ariaLabel={`Top ${topRows.length} productos por ${RANKING_ORDER_LABELS[orderBy].toLowerCase()}`}
                  valueName={RANKING_ORDER_LABELS[orderBy]}
                  data={rankingChartData}
                  formatValue={rankingFormat}
                />
              </div>
              <div className="overflow-x-auto">
                <table className="w-full min-w-[760px] text-sm" aria-label="Ranking de productos">
                  <thead>
                    <tr className="border-b border-border bg-muted/40">
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground w-12">#</th>
                      <th className="px-4 py-2 text-left font-medium text-muted-foreground">Producto</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Importe</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Margen</th>
                      <th className="px-4 py-2 text-right font-medium text-muted-foreground">Última venta</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ranking.items.map((row, i) => {
                      const margin = marginCell(row)
                      return (
                        <tr key={row.productId} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                          <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">{row.rank}</td>
                          <td className="px-4 py-2">
                            <div className="flex items-center gap-2 flex-wrap">
                              <span className="font-medium">{row.productName}</span>
                              {row.isGroup && (
                                <Badge variant="secondary" className="text-xs">
                                  {row.variantCount} {row.variantCount === 1 ? "variante" : "variantes"}
                                </Badge>
                              )}
                              {!row.isGroup && row.parentName && (
                                <span className="text-xs text-muted-foreground">variante de {row.parentName}</span>
                              )}
                            </div>
                          </td>
                          <td className="px-4 py-2 text-right tabular-nums">{formatNumber(row.units)}</td>
                          <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(row.revenue)}</td>
                          <td className="px-4 py-2 text-right tabular-nums">{formatNumber(row.operations)}</td>
                          <td className="px-4 py-2 text-right tabular-nums">
                            <div className="flex flex-col items-end">
                              <span>{margin.value}</span>
                              {margin.coverage && (
                                <span className="text-xs text-muted-foreground">{margin.coverage}</span>
                              )}
                            </div>
                          </td>
                          <td className="px-4 py-2 text-right tabular-nums">
                            {row.lastSaleDate ? formatBusinessDate(row.lastSaleDate) : "—"}
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
              {ranking.pages > 1 && (
                <div className="flex items-center justify-between px-4 pb-4">
                  <span className="text-xs text-muted-foreground">
                    Página {ranking.page + 1} de {ranking.pages} · {ranking.total} productos
                  </span>
                  <div className="flex gap-2">
                    <Button variant="outline" size="sm" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>
                      Anterior
                    </Button>
                    <Button variant="outline" size="sm" disabled={page + 1 >= ranking.pages} onClick={() => setPage((p) => p + 1)}>
                      Siguiente
                    </Button>
                  </div>
                </div>
              )}
            </>
          )}
        </CardContent>
      </Card>

      {/* ── Lo que queda fuera, dicho en voz alta (D6 / D7) ── */}
      {evolution && (
        <p className="text-xs text-muted-foreground">
          El ranking no incluye {formatMoney(evolution.current.serviceRevenue)} de líneas de servicio (ventas sin producto asociado), que sí forman parte de la facturación del período.
        </p>
      )}
      <p className="text-xs text-muted-foreground">
        La evolución y los totales descuentan las notas de crédito del período, igual que el Tablero. El ranking no descuenta notas de crédito: una nota de crédito no tiene un producto atribuible. El margen usa el costo congelado en cada venta y, sólo cuando falta, el costo actual del catálogo; la marca "% con costo" indica qué proporción de las líneas tiene costo congelado.
      </p>
    </div>
  )
}

function Loading() {
  return (
    <div className="h-40 flex items-center justify-center text-muted-foreground text-sm">
      Cargando...
    </div>
  )
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-10 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
        <BarChart3 className="h-6 w-6 text-muted-foreground" />
      </div>
      <div>
        <p className="text-sm font-medium text-foreground">Sin ventas en el período seleccionado</p>
        <p className="text-sm text-muted-foreground mt-1 max-w-sm">
          Registrá ventas en el rango de fechas elegido, o ampliá el rango, para ver la evolución y el ranking.
        </p>
      </div>
    </div>
  )
}
