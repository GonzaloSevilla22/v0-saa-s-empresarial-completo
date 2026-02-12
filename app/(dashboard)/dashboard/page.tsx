"use client"

import { useData } from "@/contexts/data-context"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { RecentActivity } from "@/components/dashboard/recent-activity"
import { DollarSign, TrendingDown, TrendingUp, AlertTriangle } from "lucide-react"

export default function DashboardPage() {
  const { getTodaySales, getTodayExpenses, getNetProfit, getLowStockProducts } = useData()

  const todaySales = getTodaySales()
  const todayExpenses = getTodayExpenses()
  const netProfit = getNetProfit()
  const lowStock = getLowStockProducts()

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight text-balance">
          Buen dia, Emprendedor
        </h1>
        <p className="text-sm text-muted-foreground mt-1">
          Asi esta tu negocio hoy
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
          <RecentActivity />
        </div>
      </div>
    </div>
  )
}
