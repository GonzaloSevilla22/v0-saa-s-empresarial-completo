"use client"

import { useData } from "@/contexts/data-context"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { AiAlerts } from "@/components/dashboard/ai-alerts"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle } from "lucide-react"

import { useEffect, useState } from "react"
import { aiInsightService } from "@/lib/services/aiInsightService"
import { createClient } from "@/lib/supabase/client"

export default function DashboardPage() {
  const { insights, refreshData } = useData()

  const [kpis, setKpis] = useState({
    todaySales: 0,
    todayExpenses: 0,
    netProfit: 0,
    lowStockCount: 0,
  })
  const [loadingKpis, setLoadingKpis] = useState(true)

  useEffect(() => {
    const fetchKpis = async () => {
      setLoadingKpis(true)
      try {
        const supabase = createClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return

        const today = new Date()
        const dateFrom = new Date(today.setHours(0, 0, 0, 0)).toISOString()
        const dateTo = new Date(today.setHours(23, 59, 59, 999)).toISOString()

        const [financialsRes, stockRes] = await Promise.all([
          supabase.rpc('get_dashboard_financials', {
            p_user_id: user.id,
            p_date_from: dateFrom,
            p_date_to: dateTo
          }),
          supabase.rpc('get_dashboard_critical_stock', {
            p_user_id: user.id
          })
        ])

        const financials = financialsRes.data?.[0] || { total_income: 0, total_expenses: 0, net_profit: 0 }
        
        setKpis({
          todaySales: Number(financials.total_income || 0),
          todayExpenses: Number(financials.total_expenses || 0),
          netProfit: Number(financials.net_profit || 0),
          lowStockCount: Number(stockRes.data || 0)
        })
      } catch (err) {
        console.error("Error fetching dashboard KPIs:", err)
      } finally {
        setLoadingKpis(false)
      }
    }

    fetchKpis()
  }, [])

  // Auto-generate insights if none exist for today
  useEffect(() => {
    const today = new Date().toISOString().split('T')[0]
    const todaysInsights = insights.filter(i => i.date === today)
    
    if (todaysInsights.length === 0) {
      aiInsightService.generateInsights()
        .then(() => refreshData())
        .catch(err => console.error("Error auto-generating insights:", err))
    }
  }, [insights, refreshData])

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
          value={`$${kpis.todaySales.toLocaleString()}`}
          change={15}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos hoy"
          value={`$${kpis.todayExpenses.toLocaleString()}`}
          change={-8}
          icon={TrendingDown}
          iconColor="text-red-400"
        />
        <KpiCard
          title="Ganancia neta"
          value={`$${kpis.netProfit.toLocaleString()}`}
          change={12}
          icon={TrendingUp}
        />
        <KpiCard
          title="Productos en alerta"
          value={kpis.lowStockCount.toString()}
          icon={AlertTriangle}
          iconColor="text-yellow-400"
        />
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-7">
        <div className="lg:col-span-4">
          <SalesChart />
        </div>
        <div className="lg:col-span-3 flex flex-col gap-4">
          <AiSummaryCard todaySales={kpis.todaySales} lowStockCount={kpis.lowStockCount} />
          <AiAlerts />
          <RecentActivity />
        </div>
      </div>
    </div>
  )
}
