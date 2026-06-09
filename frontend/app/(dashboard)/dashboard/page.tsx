"use client"

import { useEffect, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { useProducts } from "@/hooks/data/use-products"
import { useInsights } from "@/hooks/data/use-insights"
import { useGreeting } from "@/hooks/use-greeting"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { AiAlerts } from "@/components/dashboard/ai-alerts"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle } from "lucide-react"
import { aiInsightService } from "@/lib/services/aiInsightService"
import { createClient } from "@/lib/supabase/client"
import { TrialBanner } from "@/components/dashboard/TrialBanner"
import { BranchFilter } from "@/components/branches/BranchFilter"
import { utcDayRange } from "@/lib/date-range"

// ─── Types ────────────────────────────────────────────────────────────────────

interface DashboardFinancials {
  total_income:    number
  total_expenses:  number
  total_purchases: number
  net_profit:      number
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DashboardPage() {
  const { products }             = useProducts()
  const { insights, refreshInsights: refreshData } = useInsights()

  function getLowStockProducts() {
    return products.filter(p =>
      p.stockControlType !== "untracked" &&
      p.stockControlType !== "variant_only" &&
      p.minStock > 0 &&
      p.stock <= p.minStock
    )
  }
  const { greeting } = useGreeting()
  const searchParams = useSearchParams()
  const lowStock = getLowStockProducts()

  const branchId = searchParams.get("branch") ?? null

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

    const today = new Date().toISOString().split('T')[0]
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

  return (
    <div className="flex flex-col gap-6">
      <TrialBanner />

      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight text-balance">
            {greeting}
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Así está tu negocio hoy
          </p>
        </div>
        <BranchFilter />
      </div>

      <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          title="Ventas hoy"
          value={loadingKpis ? "—" : `$${todaySales.toLocaleString()}`}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos hoy"
          value={loadingKpis ? "—" : `$${todayExpenses.toLocaleString()}`}
          icon={TrendingDown}
          iconColor="text-red-400"
        />
        <KpiCard
          title="Ganancia neta"
          value={loadingKpis ? "—" : `$${netProfit.toLocaleString()}`}
          icon={TrendingUp}
        />
        <KpiCard
          title="Productos en alerta"
          value={lowStock.length.toString()}
          icon={AlertTriangle}
          iconColor="text-yellow-400"
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
