"use client"

import { TrendingUp, Share2, PackageX, Receipt, Tag } from "lucide-react"
import { KpiSummaryCard } from "@/components/dashboard/KpiSummaryCard"
import { useDashboardKpiSummary } from "@/hooks/data/use-dashboard-kpi-summary"
import { useChannelMargin } from "@/hooks/data/use-channel-margin"
import type { KpiExplanationProp } from "@/components/dashboard/KpiExplainTrigger"
import type { DashboardKpiId } from "@/lib/dashboard-kpi-explanations"
import {
  kpiDeltaPct,
  kpiBadgeTone,
  formatKpiDelta,
  formatKpiCurrency,
  formatChannelMargin,
  channelLabel,
} from "@/lib/kpi-format"

// ─── Props ────────────────────────────────────────────────────────────────────

interface KpiSummaryBlockProps {
  /** Mes a mostrar (cualquier fecha dentro del mes). */
  periodDate: Date
  /** Filtro de sucursal activo (searchParam ?branch=). */
  branchId?: string | null
  /** Nombre de la sucursal activa (para el contexto de «de dónde sale»);
   *  `null` = todas. El Tablero lo resuelve una sola vez y lo comparte. */
  branchName?: string | null
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * Bloque Resumen KPI (spec ALIADATA v1.1): 5 tarjetas mensuales con badge de
 * variación contra el mes anterior. Grilla 2 col mobile (5ta ancho completo),
 * 3 col tablet, 5 col web.
 */
export function KpiSummaryBlock({ periodDate, branchId = null, branchName = null }: KpiSummaryBlockProps) {
  const { data, isLoading } = useDashboardKpiSummary(periodDate, branchId)
  const { data: channelData, isLoading: channelLoading } = useChannelMargin(periodDate, branchId)

  // Sin datos del período (o cargando): todas las tarjetas muestran "—".
  // Ganancia $0 con 0 ventas se trata como "sin datos" (nada registrado),
  // pero $0 CON movimiento (p.ej. gastos que cancelan ingresos) sí se muestra.
  const empty = isLoading || data === null
  const noActivity = empty || (data.salesCount === 0 && data.netProfit === 0)

  // v3-reporting-invariants (D8): línea "Cobrado: $X" solo cuando difiere de
  // lo facturado (percibido ≠ devengado — cuenta con movimientos de cta
  // cte). Con degradación: si el RPC todavía no expone las columnas nuevas
  // (ventana entre deploy de DB y de frontend), ambos son null y no se
  // muestra nada.
  const collectedLine =
    !empty &&
    data.collectedRevenue != null &&
    data.invoicedRevenue != null &&
    data.collectedRevenue !== data.invoicedRevenue
      ? `Cobrado: ${formatKpiCurrency(data.collectedRevenue)}`
      : null

  const netDelta = empty ? null : kpiDeltaPct(data.netProfit, data.prevNetProfit)
  const ticketDelta = empty ? null : kpiDeltaPct(data.avgTicket, data.prevAvgTicket)
  const costDelta = empty ? null : kpiDeltaPct(data.costPerSale, data.prevCostPerSale)
  const stockDelta = empty
    ? null
    : kpiDeltaPct(data.stagnantStockCount, data.prevStagnantStockCount)

  // Margen por Canal: valor "IG 34% / ML 18%", badge "IG lidera"; el tone
  // compara el margen TOTAL contra el mes anterior (up_good).
  const channelEmpty =
    channelLoading || channelData === null || channelData.channels.length === 0
  const marginDelta = channelEmpty
    ? null
    : kpiDeltaPct(channelData.marginPct, channelData.prevMarginPct)

  // tablero-explicable (D4): contexto vigente que el diálogo «de dónde sale»
  // muestra tal cual (mes del selector, sucursal activa).
  const explain = (id: DashboardKpiId): KpiExplanationProp => ({
    id,
    context: { periodDate, branchName },
  })

  return (
    <div
      data-testid="kpi-summary-block"
      className="grid gap-3 grid-cols-2 md:grid-cols-3 xl:grid-cols-5"
    >
      <KpiSummaryCard
        label="Ganancia Neta"
        explanation={explain("net_profit")}
        value={noActivity ? "—" : formatKpiCurrency(data.netProfit)}
        badge={formatKpiDelta(netDelta)}
        tone={kpiBadgeTone(netDelta, "up_good")}
        icon={TrendingUp}
        iconColor="text-success"
        secondaryLine={noActivity ? null : collectedLine}
      />
      <KpiSummaryCard
        label="Margen por Canal"
        explanation={explain("channel_margin")}
        value={channelEmpty ? "—" : formatChannelMargin(channelData.channels)}
        badge={
          channelEmpty || !channelData.leader
            ? "—"
            : `${channelLabel(channelData.leader)} lidera`
        }
        tone={kpiBadgeTone(marginDelta, "up_good")}
        icon={Share2}
        iconColor="text-violet-400"
      />
      <KpiSummaryCard
        label="Stock sin Rotación"
        explanation={explain("stagnant_stock")}
        value={empty ? "—" : formatKpiCurrency(data.stagnantStockValue)}
        badge={empty || data.stagnantStockCount == null ? "—" : `${data.stagnantStockCount} productos`}
        tone={kpiBadgeTone(stockDelta, "up_bad")}
        icon={PackageX}
        iconColor="text-warning"
        // productos-costo-nullable (OQ-2=a, hallazgo de revisión): la
        // disclosure va en la línea secundaria (min-w-0, sin nowrap), NUNCA
        // en el badge — "531 productos · 518 sin costo" desborda la tarjeta
        // a 375px (badge es whitespace-nowrap y no encoge). El valor ya suma
        // sólo los productos con costo (misma aritmética de siempre) — sin
        // esta cifra, ese total no es auditable por quien lo lee.
        secondaryLine={
          !empty && data.stagnantStockWithoutCostCount
            ? `${data.stagnantStockWithoutCostCount} sin costo`
            : null
        }
      />
      <KpiSummaryCard
        label="Costo por Venta"
        explanation={explain("cost_per_sale")}
        value={empty ? "—" : formatKpiCurrency(data.costPerSale)}
        badge={formatKpiDelta(costDelta)}
        tone={kpiBadgeTone(costDelta, "up_bad")}
        icon={Receipt}
        iconColor="text-destructive"
      />
      <KpiSummaryCard
        label="Ticket Promedio"
        explanation={explain("avg_ticket")}
        value={empty ? "—" : formatKpiCurrency(data.avgTicket)}
        badge={formatKpiDelta(ticketDelta)}
        tone={kpiBadgeTone(ticketDelta, "up_good")}
        icon={Tag}
        iconColor="text-sky-400"
        className="col-span-2 md:col-span-1 xl:col-span-1"
      />
    </div>
  )
}
