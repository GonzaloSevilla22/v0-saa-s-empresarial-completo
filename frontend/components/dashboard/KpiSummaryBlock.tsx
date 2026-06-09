"use client"

import { TrendingUp, Share2, PackageX, Receipt, Tag } from "lucide-react"
import { KpiSummaryCard } from "@/components/dashboard/KpiSummaryCard"
import { useDashboardKpiSummary } from "@/hooks/data/use-dashboard-kpi-summary"
import {
  kpiDeltaPct,
  kpiBadgeTone,
  formatKpiDelta,
  formatKpiCurrency,
} from "@/lib/kpi-format"

// ─── Props ────────────────────────────────────────────────────────────────────

interface KpiSummaryBlockProps {
  /** Mes a mostrar (cualquier fecha dentro del mes). */
  periodDate: Date
  /** Filtro de sucursal activo (searchParam ?branch=). */
  branchId?: string | null
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * Bloque Resumen KPI (spec ALIADATA v1.1): 5 tarjetas mensuales con badge de
 * variación contra el mes anterior. Grilla 2 col mobile (5ta ancho completo),
 * 3 col tablet, 5 col web. "Margen por Canal" muestra "—" hasta la Fase B
 * (campo sales.canal pendiente de gate de governance).
 */
export function KpiSummaryBlock({ periodDate, branchId = null }: KpiSummaryBlockProps) {
  const { data, isLoading } = useDashboardKpiSummary(periodDate, branchId)

  // Sin datos del período (o cargando): todas las tarjetas muestran "—".
  // Ganancia $0 con 0 ventas se trata como "sin datos" (nada registrado),
  // pero $0 CON movimiento (p.ej. gastos que cancelan ingresos) sí se muestra.
  const empty = isLoading || data === null
  const noActivity = empty || (data.salesCount === 0 && data.netProfit === 0)

  const netDelta = empty ? null : kpiDeltaPct(data.netProfit, data.prevNetProfit)
  const ticketDelta = empty ? null : kpiDeltaPct(data.avgTicket, data.prevAvgTicket)
  const costDelta = empty ? null : kpiDeltaPct(data.costPerSale, data.prevCostPerSale)
  const stockDelta = empty
    ? null
    : kpiDeltaPct(data.stagnantStockCount, data.prevStagnantStockCount)

  return (
    <div
      data-testid="kpi-summary-block"
      className="grid gap-3 grid-cols-2 md:grid-cols-3 xl:grid-cols-5"
    >
      <KpiSummaryCard
        label="Ganancia Neta"
        value={noActivity ? "—" : formatKpiCurrency(data.netProfit)}
        badge={formatKpiDelta(netDelta)}
        tone={kpiBadgeTone(netDelta, "up_good")}
        icon={TrendingUp}
        iconColor="text-emerald-400"
      />
      <KpiSummaryCard
        label="Margen por Canal"
        value="—"
        badge="—"
        tone="yellow"
        icon={Share2}
        iconColor="text-violet-400"
      />
      <KpiSummaryCard
        label="Stock sin Rotación"
        value={empty ? "—" : formatKpiCurrency(data.stagnantStockValue)}
        badge={empty || data.stagnantStockCount == null ? "—" : `${data.stagnantStockCount} productos`}
        tone={kpiBadgeTone(stockDelta, "up_bad")}
        icon={PackageX}
        iconColor="text-amber-400"
      />
      <KpiSummaryCard
        label="Costo por Venta"
        value={empty ? "—" : formatKpiCurrency(data.costPerSale)}
        badge={formatKpiDelta(costDelta)}
        tone={kpiBadgeTone(costDelta, "up_bad")}
        icon={Receipt}
        iconColor="text-red-400"
      />
      <KpiSummaryCard
        label="Ticket Promedio"
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
