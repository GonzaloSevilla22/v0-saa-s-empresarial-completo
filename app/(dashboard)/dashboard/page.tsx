"use client"

import { useEffect, useRef, useState } from "react"
import { useData } from "@/contexts/data-context"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { AiAlerts } from "@/components/dashboard/ai-alerts"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle } from "lucide-react"
import { aiInsightService } from "@/lib/services/aiInsightService"
import { createClient } from "@/lib/supabase/client"

// ─── Types ────────────────────────────────────────────────────────────────────

interface DashboardFinancials {
  total_income:    number
  total_expenses:  number
  total_purchases: number
  net_profit:      number
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DashboardPage() {
  const { getLowStockProducts, insights, refreshData } = useData()
  const lowStock = getLowStockProducts()

  const [financials, setFinancials]     = useState<DashboardFinancials | null>(null)
  const [loadingKpis, setLoadingKpis]   = useState(true)

  // ── Server-side financial KPIs (no p_user_id — uses auth.uid() internally) ──
  useEffect(() => {
    const supabase = createClient()

    async function fetchFinancials() {
      setLoadingKpis(true)
      try {
        // Today's window in local ISO strings
        const now      = new Date()
        const dateFrom = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0, 0).toISOString()
        const dateTo   = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59, 999).toISOString()

        const { data, error } = await supabase.rpc('get_dashboard_financials', {
          p_date_from: dateFrom,
          p_date_to:   dateTo,
        })

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
  }, [])  // intentionally runs once on mount; data is for "today" which doesn't change mid-session

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
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight text-balance">
          Buen día, Emprendedor
        </h1>
        <p className="text-sm text-muted-foreground mt-1">
          Así está tu negocio hoy
        </p>
      </div>

      <div className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          title="Ventas hoy"
          value={loadingKpis ? "—" : `$${todaySales.toLocaleString()}`}
          change={15}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos hoy"
          value={loadingKpis ? "—" : `$${todayExpenses.toLocaleString()}`}
          change={-8}
          icon={TrendingDown}
          iconColor="text-red-400"
        />
        <KpiCard
          title="Ganancia neta"
          value={loadingKpis ? "—" : `$${netProfit.toLocaleString()}`}
          change={12}
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
