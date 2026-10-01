"use client"

import { useEffect, useRef } from "react"
import { useSearchParams } from "next/navigation"
import { useInsights } from "@/hooks/data/use-insights"
import { useCriticalStock } from "@/hooks/data/use-critical-stock"
import { useDashboardFinancials } from "@/hooks/data/use-dashboard-financials"
import { useGreeting } from "@/hooks/use-greeting"
import { useGoalMilestone } from "@/hooks/three/useGoalMilestone"
import { Celebration3D } from "@/components/three/Celebration3D"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { AiAlerts } from "@/components/dashboard/ai-alerts"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle, HandCoins } from "lucide-react"
import { useReceivablesSummary } from "@/hooks/data/use-receivables"
import { aiInsightService } from "@/lib/services/aiInsightService"
import { TrialBanner } from "@/components/dashboard/TrialBanner"
import { BranchFilter } from "@/components/branches/BranchFilter"
import { KpiSummaryBlock } from "@/components/dashboard/KpiSummaryBlock"
import { PeriodFilter } from "@/components/dashboard/PeriodFilter"
import { utcDayRange, utcMonthRange, parseMonthKey, argentinaToday } from "@/lib/date-range"
import { formatKpiCurrency } from "@/lib/kpi-format"

// Celebración "meta alcanzada" (v4-visual-3d-refresh 3.6) — umbrales redondos
// de "ventas hoy". Referencia estable a nivel de módulo (useGoalMilestone la
// usa como dependencia de efecto).
const GOAL_MILESTONES = [50_000, 100_000, 250_000, 500_000, 1_000_000] as const

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DashboardPage() {
  const { insights, refreshInsights: refreshData } = useInsights()

  const { greeting } = useGreeting()
  const searchParams = useSearchParams()

  const branchId = searchParams.get("branch") ?? null

  // kpi-critical-stock-dashboard (D1/D5): la tarjeta "Productos en alerta"
  // consume la RPC canónica get_dashboard_critical_stock(p_branch_id) — no
  // recalcula el predicado de criticidad sobre `products` en el cliente.
  // branchId = null ⇒ agregado consciente de sucursal (D2).
  const { data: criticalStockCount, isLoading: loadingCriticalStock } = useCriticalStock(branchId)
  // cobranzas-panel (D6/OQ-3): total por cobrar de la CUENTA — un stock al
  // instante, no un flujo del período. No recibe branchId: customer_accounts
  // no referencia sucursal, y repartir el saldo entre las ventas que lo
  // formaron es el aging de la Etapa B.
  const { data: receivablesSummary, isLoading: loadingReceivables } = useReceivablesSummary()
  // Período del Bloque Resumen KPI (?period=YYYY-MM, mes en curso por defecto).
  const periodDate = parseMonthKey(searchParams.get("period"))

  // ── Tarjetas financieras del MES (tablero-kpis-mes-vigente, D3) ─────────────
  // "Ventas / Gastos / Ganancia neta del mes": get_dashboard_financials sobre la
  // ventana del mes del selector de período y la sucursal activa — la misma
  // ventana, cuenta y sucursal que el Bloque Resumen de arriba, así que la
  // "Ganancia neta del mes" coincide con su "Ganancia Neta" (spec
  // reporting-invariants). `monthRange` son strings (utcMonthRange): la query
  // key nunca depende del `Date` de `periodDate`, que se recrea en cada render.
  // Ventana UTC del mes calendario, NO medianoche local del navegador: las filas
  // de ventas/gastos/compras se guardan a medianoche UTC. Ver lib/date-range.ts.
  const monthRange = utcMonthRange(periodDate)
  const {
    data: monthFinancials,
    isLoading: loadingMonth,
    isError: monthError,
    error: monthErr,
  } = useDashboardFinancials(monthRange, branchId)

  // ── "Hoy" (D4) ──────────────────────────────────────────────────────────────
  // Lo único del Tablero que sigue siendo del DÍA: el footer "Ventas hoy" del
  // Resumen IA del día y la celebración de meta (umbrales de ventas del día).
  // Ventana del día argentino materializada a medianoche UTC (utcDayRange).
  const {
    data: dayFinancials,
    isLoading: loadingDay,
    isFetching: fetchingDay,
    error: dayErr,
  } = useDashboardFinancials(utcDayRange(), branchId)

  // Un fallo del read-model degrada a $0 (paridad con la tarjeta de stock
  // crítico) y no rompe el resto del Tablero; queda registrado con el detalle
  // de PostgREST (p. ej. "permission denied for function …"). Dependen del
  // objeto de error: se registra una vez por fallo, no en cada render.
  useEffect(() => {
    if (monthErr) {
      console.error("[Dashboard] get_dashboard_financials (mes del período) falló:", monthErr.message)
    }
  }, [monthErr])
  useEffect(() => {
    if (dayErr) {
      console.error("[Dashboard] get_dashboard_financials (día) falló:", dayErr.message)
    }
  }, [dayErr])

  // ── Auto-generate AI insights if none exist for today ────────────────────────
  // Guard ref prevents double-execution (StrictMode) and error-retry loops.
  // Without it: generate → refreshData → insights changes → effect fires again → loop.
  const generateAttempted = useRef(false)

  useEffect(() => {
    if (generateAttempted.current) return
    generateAttempted.current = true

    // app-timezone-argentina (task 3.1): "hoy" es el día argentino, no el
    // día UTC del server — a las 22:00 ART el día UTC ya rolleó a mañana.
    const today = argentinaToday()
    const todaysInsights = insights.filter(i => i.date === today)

    if (todaysInsights.length === 0) {
      aiInsightService.generateInsights()
        .then(() => refreshData())
        .catch(err => console.error("Error auto-generating insights:", err))
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])  // intentionally empty — one-time check on mount after initial data load

  // ── Derived display values ───────────────────────────────────────────────────
  // En error → $0 aunque haya una lectura anterior en caché (D3): si el refresco
  // de un remontaje falla, React Query conserva el `data` viejo con isError, y
  // la fila no sigue mostrando un total que no se pudo confirmar.
  const monthSales     = monthError ? 0 : monthFinancials?.totalIncome ?? 0
  const monthExpenses  = monthError ? 0 : monthFinancials?.totalExpenses ?? 0
  const monthNetProfit = monthError ? 0 : monthFinancials?.netProfit ?? 0
  const todaySales     = dayFinancials?.totalIncome ?? 0

  // ── Celebración "meta alcanzada" (v4-visual-3d-refresh 3.6) ───────────────────
  // Puramente presentacional: deriva de `todaySales` (la ventana del DÍA, D4 —
  // los umbrales son de "ventas hoy", no del mes). `useGoalMilestone` nunca
  // celebra la primera lectura tras cargar (evita "festejar" en cada reload);
  // solo un incremento posterior que cruce un umbral, dentro de la misma sesión
  // de página. "Cargando" incluye el refresco en curso: al volver al Tablero la
  // consulta muestra el valor cacheado (isLoading=false) mientras trae el nuevo
  // (refetchOnMount), y ese valor viejo no puede ser la línea base.
  const crossedMilestone = useGoalMilestone(
    todaySales,
    GOAL_MILESTONES,
    loadingDay || fetchingDay,
  )

  return (
    <div className="flex flex-col gap-6">
      <TrialBanner />

      <Celebration3D
        key={crossedMilestone ?? "none"}
        show={crossedMilestone !== null}
        variant="goal"
      />

      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight text-balance">
            {greeting}
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Así está tu negocio
          </p>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <PeriodFilter />
          <BranchFilter />
        </div>
      </div>

      {/* Bloque Resumen KPI (spec ALIADATA v1.1) — SIEMPRE arriba del contenido
          existente (Consejos IA / AiSummaryCard quedan más abajo, sin moverse). */}
      <KpiSummaryBlock periodDate={periodDate} branchId={branchId} />

      {/* cobranzas-panel (D6): 5 tarjetas — espejo del breakpoint del bloque
          mensual (md:grid-cols-3 xl:grid-cols-5): 5 tarjetas a 1024px quedan
          ilegibles. */}
      <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
        <KpiCard
          title="Ventas del mes"
          value={loadingMonth ? "—" : formatKpiCurrency(monthSales)}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos del mes"
          value={loadingMonth ? "—" : formatKpiCurrency(monthExpenses)}
          icon={TrendingDown}
          iconColor="text-destructive"
        />
        <KpiCard
          title="Ganancia neta del mes"
          value={loadingMonth ? "—" : formatKpiCurrency(monthNetProfit)}
          icon={TrendingUp}
        />
        <KpiCard
          title="Productos en alerta"
          value={loadingCriticalStock ? "—" : criticalStockCount.toString()}
          icon={AlertTriangle}
          iconColor="text-warning"
        />
        {/* cobranzas-panel: stock de la cuenta (no respeta BranchFilter, OQ-3)
            enlazado al panel de deudores (D7). */}
        <KpiCard
          title="Por cobrar"
          value={
            loadingReceivables
              ? "—"
              : formatKpiCurrency(receivablesSummary?.totalReceivable ?? 0)
          }
          icon={HandCoins}
          iconColor="text-warning"
          href="/cobranzas"
        />
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-7">
        <div className="lg:col-span-4">
          <SalesChart />
        </div>
        <div className="lg:col-span-3 flex flex-col gap-4">
          <AiSummaryCard todaySales={todaySales} branchId={branchId} />
          <AiAlerts />
          <RecentActivity />
        </div>
      </div>
    </div>
  )
}
