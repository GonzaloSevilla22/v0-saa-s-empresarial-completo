"use client"

/**
 * /estadisticas — estadisticas-ventas E1 (tasks 4.4-4.10) + E2 (tasks 7.1-7.5).
 *
 * Responde "qué se vende, cuándo, por dónde y a quién": evolución de la
 * facturación por día/semana/mes con comparación contra el período anterior,
 * desglose por canal y sucursal, patrón por día de la semana y horario de
 * carga, ranking de productos por unidades / importe / margen con variantes
 * agrupadas, ventas por categoría y top clientes.
 *
 * Molde de /reportes/formas-pago (DateButton, Card, tabla overflow-x-auto con
 * tfoot, EmptyState, nota al pie). Disponible en todos los planes: el
 * historial se recorta en el SERVIDOR y la ventana aplicada llega en la
 * respuesta (D8) — acá sólo se explica el recorte. El filtro de sucursal es
 * el BranchFilter compartido (URL ?branch=, como el Tablero) y viaja a
 * TODAS las consultas del módulo: lo aplica el helper canónico en la base,
 * uniforme y fail-closed.
 *
 * Lo que la pantalla declara, porque callarlo sería mentir por omisión:
 * - las líneas de servicio facturan pero no rankean (D6) → importe al pie;
 * - la evolución descuenta notas de crédito (como el Tablero); el ranking,
 *   los desgloses y el top de clientes no pueden (una NC no tiene producto,
 *   canal, sucursal, hora ni cliente atribuible) (D7) → nota al pie;
 * - un margen sin costo es "—", nunca 0, y la cobertura parcial se marca (D11);
 * - el horario es de CARGA de la operación, no de venta (OQ-1) → rótulo y
 *   salvedad visibles; las ventas sin cliente no compiten en el top y su
 *   importe se declara (OQ-2).
 */

import { useMemo, useState } from "react"
import { useSearchParams } from "next/navigation"
import { subDays } from "date-fns"
import { BarChart3, Hash, Package, TrendingUp } from "lucide-react"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useProductRanking, useSalesEvolution } from "@/hooks/data/use-sales-statistics"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { BranchFilter } from "@/components/branches/BranchFilter"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { ReportTimeSeriesChart } from "@/components/charts/ReportTimeSeriesChart"
import { ReportBarChart } from "@/components/charts/ReportBarChart"
import { DimensionBreakdownSection } from "@/components/statistics/DimensionBreakdownSection"
import { TopClientsSection } from "@/components/statistics/TopClientsSection"
import { formatMoney, formatNumber } from "@/lib/format"
import {
  BREAKDOWN_DIMENSION_LABELS,
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

type HourView = "hour" | "band"
const HOUR_VIEW_LABELS: Record<HourView, string> = { hour: "Por hora", band: "Por franja" }

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
  const [hourView, setHourView] = useState<HourView>("hour")

  // E2: filtro de sucursal compartido (URL ?branch=, como el Tablero).
  const searchParams = useSearchParams()
  const branchId = searchParams.get("branch") ?? null

  // Cota visual del calendario según el plan (como los otros reportes); la
  // cota REAL la aplica el read-model (D8) aunque el cliente no coopere.
  const minDate = subDays(today, limits?.historyDays ?? 30)
  const startISO = toISODate(dateFrom)
  const endISO = toISODate(dateTo)

  const evolutionQuery = useSalesEvolution({ start: startISO, end: endISO, bucket, branchId })
  const rankingQuery = useProductRanking({
    start: startISO, end: endISO, orderBy, groupVariants, page, size: RANKING_PAGE_SIZE, branchId,
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
          <BranchFilter />
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

      {/* ── E2: por dónde se vende (canal / sucursal) ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Por dónde se vende</CardTitle>
        </CardHeader>
        <CardContent className="min-w-0">
          <Tabs defaultValue="canal">
            <TabsList aria-label="Dimensión del desglose">
              <TabsTrigger value="canal">Por canal</TabsTrigger>
              <TabsTrigger value="branch">Por sucursal</TabsTrigger>
            </TabsList>
            <TabsContent value="canal" className="mt-4">
              <DimensionBreakdownSection
                dimension="canal"
                start={startISO}
                end={endISO}
                branchId={branchId}
                ariaLabel="Desglose por canal"
              />
            </TabsContent>
            <TabsContent value="branch" className="mt-4">
              <DimensionBreakdownSection
                dimension="branch"
                start={startISO}
                end={endISO}
                branchId={branchId}
                ariaLabel="Desglose por sucursal"
                footnote={branchId ? "Con una sucursal filtrada, el desglose muestra sólo esa sucursal; las ventas sin sucursal asignada quedan fuera de todo el módulo mientras el filtro esté activo." : undefined}
              />
            </TabsContent>
          </Tabs>
        </CardContent>
      </Card>

      {/* ── E2: cuándo se vende (día de la semana / horario de carga) ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Cuándo se vende</CardTitle>
        </CardHeader>
        <CardContent className="min-w-0">
          <Tabs defaultValue="weekday">
            <TabsList aria-label="Patrón temporal">
              <TabsTrigger value="weekday">{BREAKDOWN_DIMENSION_LABELS.weekday}</TabsTrigger>
              <TabsTrigger value="hour">{BREAKDOWN_DIMENSION_LABELS.hour}</TabsTrigger>
            </TabsList>
            <TabsContent value="weekday" className="mt-4">
              <DimensionBreakdownSection
                dimension="weekday"
                start={startISO}
                end={endISO}
                branchId={branchId}
                ariaLabel="Ventas por día de la semana"
                orientation="vertical"
                footnote="Día de la semana de la fecha de negocio declarada en cada venta (lunes a domingo)."
              />
            </TabsContent>
            <TabsContent value="hour" className="mt-4 flex flex-col gap-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                {/* OQ-1: la salvedad va ANTES del gráfico, no en letra chica. */}
                <p role="note" className="text-sm text-muted-foreground max-w-prose">
                  <span className="font-medium text-foreground">Horario de carga de la operación, no es el horario de venta:</span>{" "}
                  coincide con la venta cuando se registra en el momento (mostrador) y no cuando se carga después.
                </p>
                <ToggleGroup
                  type="single"
                  size="sm"
                  variant="outline"
                  value={hourView}
                  onValueChange={(v) => { if (v) setHourView(v as HourView) }}
                  aria-label="Vista del horario"
                >
                  {(Object.keys(HOUR_VIEW_LABELS) as HourView[]).map((v) => (
                    <ToggleGroupItem key={v} value={v} aria-label={HOUR_VIEW_LABELS[v]} className="text-xs px-3">
                      {HOUR_VIEW_LABELS[v]}
                    </ToggleGroupItem>
                  ))}
                </ToggleGroup>
              </div>
              <DimensionBreakdownSection
                dimension="hour"
                start={startISO}
                end={endISO}
                branchId={branchId}
                ariaLabel="Ventas por horario de carga"
                orientation="vertical"
                bandView={hourView === "band"}
              />
            </TabsContent>
          </Tabs>
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

      {/* ── E2: ventas por categoría (product-ranking "Ranking por categoría") ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Ventas por categoría</CardTitle>
        </CardHeader>
        <CardContent className="min-w-0">
          <DimensionBreakdownSection
            dimension="category"
            start={startISO}
            end={endISO}
            branchId={branchId}
            ariaLabel="Ventas por categoría"
            operationsTotal={false}
            footnote={evolution
              ? `Categoría del catálogo de cada producto vendido; los productos sin categoría aparecen en su propio tramo. Las ventas sin producto asociado (${formatMoney(evolution.current.serviceRevenue)}) no tienen categoría y quedan fuera de este desglose; sí forman parte de la facturación del período.`
              : "Categoría del catálogo de cada producto vendido; los productos sin categoría aparecen en su propio tramo."}
          />
        </CardContent>
      </Card>

      {/* ── E2: top clientes (OQ-2) ── */}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Top clientes del período</CardTitle>
        </CardHeader>
        <CardContent className="p-0 min-w-0">
          <TopClientsSection start={startISO} end={endISO} branchId={branchId} />
        </CardContent>
      </Card>

      {/* ── Lo que queda fuera, dicho en voz alta (D6 / D7) ── */}
      {evolution && (
        <p className="text-xs text-muted-foreground">
          El ranking no incluye {formatMoney(evolution.current.serviceRevenue)} de líneas de servicio (ventas sin producto asociado), que sí forman parte de la facturación del período.
        </p>
      )}
      <p className="text-xs text-muted-foreground">
        La evolución y los totales descuentan las notas de crédito del período, igual que el Tablero. El ranking no descuenta notas de crédito: una nota de crédito no tiene un producto atribuible. Los desgloses por canal, sucursal, día de la semana, horario y categoría, y el top de clientes, tampoco descuentan notas de crédito (una nota de crédito no tiene canal, sucursal, hora ni cliente atribuible): la suma de sus tramos es la facturación bruta del período. El margen usa el costo congelado en cada venta y, sólo cuando falta, el costo actual del catálogo; la marca "% con costo" indica qué proporción de las líneas tiene costo congelado.
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
