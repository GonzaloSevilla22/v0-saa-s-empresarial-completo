"use client"

import { useEffect, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { useInsights } from "@/hooks/data/use-insights"
import { useCriticalStock } from "@/hooks/data/use-critical-stock"
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
import { createClient } from "@/lib/supabase/client"
import { TrialBanner } from "@/components/dashboard/TrialBanner"
import { BranchFilter } from "@/components/branches/BranchFilter"
import { KpiSummaryBlock } from "@/components/dashboard/KpiSummaryBlock"
import { PeriodFilter } from "@/components/dashboard/PeriodFilter"
import { utcDayRange, parseMonthKey, argentinaToday } from "@/lib/date-range"

// ─── Types ────────────────────────────────────────────────────────────────────

interface DashboardFinancials {
  total_income:    number
  total_expenses:  number
  total_purchases: number
  net_profit:      number
}

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

  const [financials, setFinancials]     = useState<DashboardFinancials | null>(null)
  const [loadingKpis, setLoadingKpis]   = useState(true)

  // ── Server-side financial KPIs (no p_user_id — uses auth.uid() internally) ──
  useEffect(() => {
    const supabase = createClient()

    async function fetchFinancials() {
      setLoadingKpis(true)
      try {
        // Today's window — UTC calendar day, NOT browser-local midnight.
        // Sale/expense/purchase `date` rows are stored at midnight UTC keyed to a
        // calendar date; a local-midnight window (UTC-3 → 03:00Z) pushes every row
        // into the previous day's bucket and "ventas hoy" reads $0. See lib/date-range.ts.
        const { from: dateFrom, to: dateTo } = utcDayRange()

        const rpcParams: Record<string, string | null> = {
          p_date_from: dateFrom,
          p_date_to:   dateTo,
        }
        if (branchId) rpcParams.p_branch_id = branchId

        const { data, error } = await supabase.rpc('get_dashboard_financials', rpcParams)

        if (error) {
          console.error('[Dashboard] get_dashboard_financials error:', error.message)
        } else if (Array.isArray(data) && data.length > 0) {
          const row = data[0]
          setFinancials({
            total_income:    Number(row.total_income    ?? 0),
            total_expenses:  Number(row.total_expenses  ?? 0),
            total_purchases: Number(row.total_purchases ?? 0),
            net_profit:      Number(row.net_profit      ?? 0),
          })
        } else {
          // RPC returned empty (no data for today yet) — show zeros
          setFinancials({ total_income: 0, total_expenses: 0, total_purchases: 0, net_profit: 0 })
        }
      } catch (err) {
        console.error('[Dashboard] Unexpected KPI fetch error:', err)
      } finally {
        setLoadingKpis(false)
      }
    }

    fetchFinancials()
  }, [branchId])  // re-fetch when branch filter changes

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
  const todaySales    = financials?.total_income   ?? 0
  const todayExpenses = financials?.total_expenses ?? 0
  const netProfit     = financials?.net_profit     ?? 0

  // ── Celebración "meta alcanzada" (v4-visual-3d-refresh 3.6) ───────────────────
  // Puramente presentacional: deriva de `todaySales`/`loadingKpis`, que YA existen
  // (no toca el fetch ni las queries). `useGoalMilestone` nunca celebra la
  // primera lectura tras cargar (evita "festejar" en cada reload); solo un
  // incremento posterior que cruce un umbral, dentro de la misma sesión de página.
  const crossedMilestone = useGoalMilestone(todaySales, GOAL_MILESTONES, loadingKpis)

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
            Así está tu negocio hoy
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
          title="Ventas hoy"
          value={loadingKpis ? "—" : `$${todaySales.toLocaleString()}`}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos hoy"
          value={loadingKpis ? "—" : `$${todayExpenses.toLocaleString()}`}
          icon={TrendingDown}
          iconColor="text-destructive"
        />
        <KpiCard
          title="Ganancia neta hoy"
          value={loadingKpis ? "—" : `$${netProfit.toLocaleString()}`}
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
              : `$${(receivablesSummary?.totalReceivable ?? 0).toLocaleString("es-AR")}`
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
          <AiSummaryCard todaySales={todaySales} />
          <AiAlerts />
          <RecentActivity />
        </div>
      </div>
    </div>
  )
}
