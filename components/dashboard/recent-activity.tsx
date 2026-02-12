"use client"

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useData } from "@/contexts/data-context"
import { ShoppingCart, Receipt } from "lucide-react"

export function RecentActivity() {
  const { sales, expenses } = useData()

  const recentSales = sales.slice(0, 4)
  const recentExpenses = expenses.slice(0, 2)

  const combined = [
    ...recentSales.map((s) => ({
      id: s.id,
      type: "venta" as const,
      description: `${s.productName} x${s.quantity}`,
      amount: s.total,
      date: s.date,
      detail: s.clientName,
    })),
    ...recentExpenses.map((e) => ({
      id: e.id,
      type: "gasto" as const,
      description: e.description,
      amount: e.amount,
      date: e.date,
      detail: e.category,
    })),
  ].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()).slice(0, 6)

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-card-foreground">
          Actividad reciente
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {combined.map((item) => (
          <div key={item.id} className="flex items-center gap-3">
            <div
              className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-md ${
                item.type === "venta" ? "bg-emerald-500/10" : "bg-red-500/10"
              }`}
            >
              {item.type === "venta" ? (
                <ShoppingCart className="h-4 w-4 text-emerald-400" />
              ) : (
                <Receipt className="h-4 w-4 text-red-400" />
              )}
            </div>
            <div className="flex flex-1 flex-col gap-0.5 min-w-0">
              <span className="text-sm text-card-foreground truncate">{item.description}</span>
              <span className="text-xs text-muted-foreground">{item.detail}</span>
            </div>
            <span
              className={`text-sm font-medium shrink-0 ${
                item.type === "venta" ? "text-emerald-400" : "text-red-400"
              }`}
            >
              {item.type === "venta" ? "+" : "-"}${item.amount}
            </span>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
