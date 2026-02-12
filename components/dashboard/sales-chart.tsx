"use client"

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useData } from "@/contexts/data-context"
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts"

export function SalesChart() {
  const { getSalesByDay } = useData()
  const data = getSalesByDay(7)

  const chartData = data.map((d) => ({
    date: new Date(d.date).toLocaleDateString("es-AR", { weekday: "short", day: "numeric" }),
    ventas: d.total,
  }))

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-card-foreground">
          Ventas ultimos 7 dias
        </CardTitle>
      </CardHeader>
      <CardContent className="pb-4">
        <div className="h-[250px] w-full">
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={chartData} margin={{ top: 5, right: 10, left: -10, bottom: 0 }}>
              <defs>
                <linearGradient id="salesGradient" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="hsl(142 71% 45%)" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="hsl(142 71% 45%)" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="hsl(240 4% 16%)" />
              <XAxis
                dataKey="date"
                tick={{ fill: "hsl(240 5% 64.9%)", fontSize: 11 }}
                axisLine={{ stroke: "hsl(240 4% 16%)" }}
                tickLine={false}
              />
              <YAxis
                tick={{ fill: "hsl(240 5% 64.9%)", fontSize: 11 }}
                axisLine={false}
                tickLine={false}
                tickFormatter={(v) => `$${v}`}
              />
              <Tooltip
                contentStyle={{
                  backgroundColor: "hsl(240 6% 8%)",
                  border: "1px solid hsl(240 4% 16%)",
                  borderRadius: "8px",
                  color: "hsl(0 0% 98%)",
                  fontSize: 12,
                }}
                formatter={(value: number) => [`$${value}`, "Ventas"]}
              />
              <Area
                type="monotone"
                dataKey="ventas"
                stroke="hsl(142 71% 45%)"
                strokeWidth={2}
                fill="url(#salesGradient)"
              />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </CardContent>
    </Card>
  )
}
