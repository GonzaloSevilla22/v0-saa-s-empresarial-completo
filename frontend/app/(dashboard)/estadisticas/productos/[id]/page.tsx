"use client"

/**
 * /estadisticas/productos/[id] — estadisticas-ventas E3 (tasks 9.4-9.6, D12).
 *
 * Detalle de UN producto: evolución de sus ventas por día / semana / mes en
 * el período y, cuando la fila del ranking agrupa variantes, el desglose por
 * miembro del grupo (cada variante y el producto base si vendió directo).
 * Se llega desde una fila del ranking de /estadisticas; vive DENTRO del
 * módulo (no en /productos/[id], que se leería como "editar producto") y
 * enlaza al producto en el catálogo (/productos?q=<sku|nombre>).
 *
 * Todo sale de rpc_product_sales_evolution vía GET
 * /reports/statistics/products/{id}: acá no se agrega nada. La tenencia la
 * resuelve el read-model (404 para un producto ajeno o inexistente → estado
 * de error, nunca un detalle vacío); el historial se recorta en el servidor
 * (D8) y el recorte se explica. El margen usa la cascada de costo canónica
 * con su cobertura declarada (D11); el detalle NO descuenta notas de crédito
 * (una NC no tiene producto atribuible, D7) y lo dice al pie.
 */

import { useMemo, useState } from "react"
import Link from "next/link"
import { useParams, useSearchParams } from "next/navigation"
import { subDays } from "date-fns"
import { ArrowLeft, BarChart3, ExternalLink, Hash, Package, Percent, TrendingUp } from "lucide-react"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useProductSalesEvolution } from "@/hooks/data/use-sales-statistics"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { DateButton, toISODate } from "@/components/shared/DateRangeButton"
import { BranchFilter } from "@/components/branches/BranchFilter"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { ReportTimeSeriesChart } from "@/components/charts/ReportTimeSeriesChart"
import { ReportBarChart } from "@/components/charts/ReportBarChart"
import { formatMoney, formatNumber } from "@/lib/format"
import {
  EVOLUTION_BUCKET_LABELS,
  defaultStatisticsRange,
  formatBucketLabel,
  formatBusinessDate,
  marginCell,
  productDetailHref,
  shareOf,
  type EvolutionBucket,
} from "@/lib/sales-statistics"

const BUCKETS: EvolutionBucket[] = ["day", "week", "month"]

function formatShare(value: number, total: number): string {
  const share = shareOf(value, total)
  return share === null ? "—" : `${share.toLocaleString("es-AR")} %`
}

export default function ProductoEstadisticasPage() {
  const params = useParams<{ id: string | string[] }>()
  const productId = Array.isArray(params?.id) ? params.id[0] ?? "" : params?.id ?? ""
  const searchParams = useSearchParams()
  const branchId = searchParams.get("branch") ?? null
  const { limits } = usePlanLimits()

  const today = useMemo(() => new Date(), [])
  const defaults = useMemo(() => defaultStatisticsRange(today), [today])
  const [dateFrom, setDateFrom] = useState<Date>(defaults.from)
  const [dateTo, setDateTo] = useState<Date>(defaults.to)
  const [bucket, setBucket] = useState<EvolutionBucket>("day")

  const minDate = subDays(today, limits?.historyDays ?? 30)
  const startISO = toISODate(dateFrom)
  const endISO = toISODate(dateTo)

  const query = useProductSalesEvolution({ productId, start: startISO, end: endISO, bucket, branchId })
  const detail = query.data

  const backHref = branchId ? `/estadisticas?branch=${encodeURIComponent(branchId)}` : "/estadisticas"
  const hasSales = (detail?.totals.operations ?? 0) > 0
  const margin = detail ? marginCell(detail.totals) : null
  const chartData = (detail?.points ?? []).map((p) => ({
    label: formatBucketLabel(p.bucketStart, detail?.bucket ?? bucket),
    value: p.revenue,
  }))
  const membersChart = (detail?.members ?? []).map((m) => ({ name: m.productName, value: m.revenue }))
  const catalogHref = detail
    ? `/productos?q=${encodeURIComponent(detail.product.sku ?? detail.product.productName)}`
    : "/productos"

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Camino de vuelta + cabecera ── */}
      <div className="flex flex-col gap-3">
        <Link
          href={backHref}
          className="inline-flex w-fit items-center gap-1 text-sm text-muted-foreground hover:text-foreground underline-offset-4 hover:underline"
        >
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          Volver a Estadísticas
        </Link>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            {detail ? (
              <>
                <h1 className="text-2xl font-bold text-foreground tracking-tight break-words">{detail.product.productName}</h1>
                <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
                  {detail.product.sku && <span className="font-mono text-xs">{detail.product.sku}</span>}
                  {detail.product.category && <Badge variant="outline">{detail.product.category}</Badge>}
                  {detail.product.isGroup && (
                    <Badge variant="secondary" className="text-xs">
                      {detail.product.variantCount} {detail.product.variantCount === 1 ? "variante" : "variantes"}
                    </Badge>
                  )}
                  {detail.product.parentId && (
                    <span className="text-xs">
                      variante de{" "}
                      <Link
                        href={productDetailHref(detail.product.parentId, branchId)}
                        className="text-foreground underline-offset-4 hover:underline"
                      >
                        {detail.product.parentName ?? "su producto base"}
                      </Link>
                    </span>
                  )}
                  <Button asChild variant="ghost" size="sm" className="h-7 px-2 text-xs">
                    <Link href={catalogHref}>
                      <ExternalLink className="h-3.5 w-3.5 mr-1" aria-hidden="true" />
                      Ver en el catálogo
                    </Link>
                  </Button>
                </div>
              </>
            ) : (
              <h1 className="text-2xl font-bold text-foreground tracking-tight">
                {query.isError ? "Producto" : "Cargando producto…"}
              </h1>
            )}
            <p className="text-sm text-muted-foreground mt-1">
              Evolución de las ventas de este producto en el período, con el detalle de cada variante cuando agrupa.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <DateButton date={dateFrom} onSelect={setDateFrom} minDate={minDate} maxDate={dateTo} label="Fecha desde" />
            <span className="text-xs text-muted-foreground">→</span>
            <DateButton date={dateTo} onSelect={setDateTo} minDate={dateFrom} maxDate={today} label="Fecha hasta" />
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
      </div>

      {/* ── Aviso de recorte de historial (D8) ── */}
      {detail?.window.clamped && (
        <div
          role="status"
          aria-label="Aviso de historial"
          className="rounded-md border border-border bg-muted/40 px-4 py-3 text-sm text-foreground"
        >
          Tu plan permite consultar {detail.window.historyDays} días de historial: se muestran datos desde{" "}
          {formatBusinessDate(detail.window.start)}. Para ver más atrás, ampliá tu plan.
        </div>
      )}

      {/* ── Error (incluido el 404 de un producto ajeno / inexistente) ── */}
      {query.isError && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          No pudimos cargar el detalle del producto. Puede que no exista en tu catálogo o que la consulta haya fallado; volvé a Estadísticas y probá de nuevo.
        </div>
      )}

      {query.isLoading && !detail && <Loading />}

      {detail && (
        <>
          {/* ── KPIs del período ── */}
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <KpiCard title="Facturado" value={formatMoney(detail.totals.revenue)} icon={TrendingUp} />
            <KpiCard title="Unidades" value={formatNumber(detail.totals.units)} icon={Package} />
            <KpiCard title="Operaciones" value={formatNumber(detail.totals.operations)} icon={Hash} />
            <KpiCard
              title="Margen bruto"
              value={margin?.value ?? "—"}
              caption={margin?.coverage ?? undefined}
              icon={Percent}
            />
          </div>

          {/* ── Evolución ── */}
          <Card className="min-w-0">
            <CardHeader>
              <CardTitle className="text-sm font-medium">
                Evolución de las ventas por {EVOLUTION_BUCKET_LABELS[bucket].toLowerCase()}
              </CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-4 min-w-0">
              {!hasSales ? (
                <EmptyState />
              ) : (
                <>
                  <ReportTimeSeriesChart
                    ariaLabel={`Evolución de las ventas de ${detail.product.productName} por ${EVOLUTION_BUCKET_LABELS[bucket].toLowerCase()}`}
                    valueName="Importe"
                    data={chartData}
                  />
                  <div className="overflow-x-auto">
                    <table className="w-full min-w-[560px] text-sm" aria-label="Evolución de ventas del producto">
                      <thead>
                        <tr className="border-b border-border bg-muted/40">
                          <th className="px-4 py-2 text-left font-medium text-muted-foreground">{EVOLUTION_BUCKET_LABELS[bucket]}</th>
                          <th className="px-4 py-2 text-right font-medium text-muted-foreground">Importe</th>
                          <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
                          <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
                          <th className="px-4 py-2 text-right font-medium text-muted-foreground">Margen</th>
                        </tr>
                      </thead>
                      <tbody>
                        {detail.points.map((p, i) => {
                          const m = marginCell(p)
                          return (
                            <tr key={p.bucketStart} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                              <td className="px-4 py-2 tabular-nums">{formatBucketLabel(p.bucketStart, detail.bucket)}</td>
                              <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(p.revenue)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{formatNumber(p.units)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">{formatNumber(p.operations)}</td>
                              <td className="px-4 py-2 text-right tabular-nums">
                                <div className="flex flex-col items-end">
                                  <span>{m.value}</span>
                                  {m.coverage && <span className="text-xs text-muted-foreground">{m.coverage}</span>}
                                </div>
                              </td>
                            </tr>
                          )
                        })}
                      </tbody>
                      <tfoot>
                        <tr className="border-t border-border font-semibold bg-muted/30">
                          <td className="px-4 py-2">Totales del período</td>
                          <td className="px-4 py-2 text-right tabular-nums">{formatMoney(detail.totals.revenue)}</td>
                          <td className="px-4 py-2 text-right tabular-nums">{formatNumber(detail.totals.units)}</td>
                          <td className="px-4 py-2 text-right tabular-nums">{formatNumber(detail.totals.operations)}</td>
                          <td className="px-4 py-2 text-right tabular-nums">{margin?.value ?? "—"}</td>
                        </tr>
                      </tfoot>
                    </table>
                  </div>
                </>
              )}
            </CardContent>
          </Card>

          {/* ── Desglose por variante (sólo cuando el producto agrupa) ── */}
          {detail.product.isGroup && hasSales && (
            <Card className="min-w-0">
              <CardHeader>
                <CardTitle className="text-sm font-medium">Desglose por variante</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-4 p-0 min-w-0">
                <div className="px-4 pt-4">
                  <ReportBarChart
                    ariaLabel={`Importe por variante de ${detail.product.productName}`}
                    valueName="Importe"
                    data={membersChart}
                    formatValue={formatMoney}
                  />
                </div>
                <div className="overflow-x-auto">
                  <table className="w-full min-w-[640px] text-sm" aria-label="Ventas por variante">
                    <thead>
                      <tr className="border-b border-border bg-muted/40">
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground w-12">#</th>
                        <th className="px-4 py-2 text-left font-medium text-muted-foreground">Variante</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Unidades</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Importe</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Participación</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Operaciones</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Margen</th>
                        <th className="px-4 py-2 text-right font-medium text-muted-foreground">Última venta</th>
                      </tr>
                    </thead>
                    <tbody>
                      {detail.members.map((m, i) => {
                        const mm = marginCell(m)
                        const isHead = m.productId === detail.product.productId
                        return (
                          <tr key={m.productId} className={i % 2 === 0 ? "" : "bg-muted/20"}>
                            <td className="px-4 py-2 text-right tabular-nums text-muted-foreground">{m.rank}</td>
                            <td className="px-4 py-2">
                              <div className="flex items-center gap-2 flex-wrap">
                                {isHead ? (
                                  <span className="font-medium">{m.productName}</span>
                                ) : (
                                  <Link
                                    href={productDetailHref(m.productId, branchId)}
                                    className="font-medium text-foreground underline-offset-4 hover:underline focus-visible:underline"
                                  >
                                    {m.productName}
                                  </Link>
                                )}
                                {isHead && <span className="text-xs text-muted-foreground">producto base, vendido directo</span>}
                              </div>
                            </td>
                            <td className="px-4 py-2 text-right tabular-nums">{formatNumber(m.units)}</td>
                            <td className="px-4 py-2 text-right tabular-nums font-medium">{formatMoney(m.revenue)}</td>
                            <td className="px-4 py-2 text-right tabular-nums">{formatShare(m.revenue, detail.totals.revenue)}</td>
                            <td className="px-4 py-2 text-right tabular-nums">{formatNumber(m.operations)}</td>
                            <td className="px-4 py-2 text-right tabular-nums">
                              <div className="flex flex-col items-end">
                                <span>{mm.value}</span>
                                {mm.coverage && <span className="text-xs text-muted-foreground">{mm.coverage}</span>}
                              </div>
                            </td>
                            <td className="px-4 py-2 text-right tabular-nums">
                              {m.lastSaleDate ? formatBusinessDate(m.lastSaleDate) : "—"}
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              </CardContent>
            </Card>
          )}

          {/* ── Lo que queda fuera, dicho en voz alta (D7 / D11) ── */}
          <p className="text-xs text-muted-foreground">
            Este detalle no descuenta notas de crédito: una nota de crédito no tiene un producto atribuible, así que la facturación de este producto es bruta (la evolución del módulo y el Tablero sí las descuentan). El margen usa el costo congelado en cada venta y, sólo cuando falta, el costo actual del catálogo; la marca "% con costo" indica qué proporción de las líneas tiene costo congelado.
          </p>
        </>
      )}
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
        <p className="text-sm font-medium text-foreground">Sin ventas de este producto en el período seleccionado</p>
        <p className="text-sm text-muted-foreground mt-1 max-w-sm">
          Ampliá el rango de fechas o quitá el filtro de sucursal para ver su evolución.
        </p>
      </div>
    </div>
  )
}
