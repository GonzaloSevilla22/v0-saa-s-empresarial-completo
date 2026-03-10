"use client"

import { useData } from "@/contexts/data-context"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { AiAlerts } from "@/components/dashboard/ai-alerts"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle } from "lucide-react"

import { useEffect } from "react"
import { aiInsightService } from "@/lib/services/aiInsightService"

export default function DashboardPage() {
  const { getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts, insights, refreshData } = useData()

  const todaySales = getTodaySales()
  const todayExpenses = getTodayExpenses()
  const netProfit = getNetProfit()
  const lowStock = getLowStockProducts()

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
          value={`$${todaySales.toLocaleString()}`}
          change={15}
          icon={DollarSign}
        />
        <KpiCard
          title="Gastos hoy"
          value={`$${todayExpenses.toLocaleString()}`}
          change={-8}
          icon={TrendingDown}
          iconColor="text-red-400"
        />
        <KpiCard
          title="Ganancia neta"
          value={`$${netProfit.toLocaleString()}`}
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
          <AiSummaryCard />
          <AiAlerts />
          <RecentActivity />
        </div>
      </div>
    </div>
  )
}
