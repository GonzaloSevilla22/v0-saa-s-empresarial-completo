"use client"

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useData } from "@/contexts/data-context"
import { AlertCircle, TrendingUp, TrendingDown, DollarSign, History, LineChart } from "lucide-react"

export function AiAlerts() {
    const { products, sales } = useData()

    // Business logic for alerts
    const marginAlerts = products.map(p => {
        const margin = p.price > 0 ? ((p.price - p.cost) / p.price) * 100 : 0

        if (margin < 20) {
            return {
                id: `margin-danger-${p.id}`,
                type: "danger",
                icon: TrendingDown,
                title: `Margen crítico: ${p.name}`,
                message: `Tu margen actual es de solo ${margin.toFixed(0)}%. Considerá subir el precio o renegociar costos.`,
            }
        }

        if (margin > 70) {
            return {
                id: `margin-info-${p.id}`,
                type: "info",
                icon: DollarSign,
                title: `Oportunidad: ${p.name}`,
                message: `Tenés un margen muy alto (${margin.toFixed(0)}%). Podrías bajar un poco el precio para ganar volumen.`,
            }
        }

        return null
    }).filter(Boolean)

    // 1. Stagnant Product Alert (No sales in 30 days)
    const stagnantAlerts = products.map(p => {
        const lastSale = sales.filter(s => s.productId === p.id)
            .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())[0]

        const thirtyDaysAgo = new Date()
        thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)

        if (lastSale && new Date(lastSale.date) < thirtyDaysAgo) {
            return {
                id: `stagnant-${p.id}`,
                type: "warning",
                icon: History,
                title: `Producto estancado: ${p.name}`,
                message: `Este producto no registra ventas hace más de 30 días. Revisá el precio o la exposición.`,
            }
        }
        return null
    }).filter(Boolean)

    // 2. Inflation Suggestion (Mock simulation)
    const inflationAlert = {
        id: "inflation-suggestion",
        type: "info",
        icon: LineChart,
        title: "Sugerencia Mensual: Ajuste por Inflación",
        message: "La inflación proyectada es del 4.5%. Recomendamos un ajuste preventivo del 5% en tus productos estrella para proteger tus márgenes.",
    }

    const allAlerts = [...marginAlerts, ...stagnantAlerts, inflationAlert].slice(0, 4)

    if (allAlerts.length === 0) return null

    return (
        <Card className="border-border bg-card">
            <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-card-foreground flex items-center gap-2">
                    <AlertCircle className="h-4 w-4 text-primary" />
                    Alertas de Rentabilidad
                </CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
                {allAlerts.map((alert: any) => (
                    <div key={alert.id} className="flex gap-3 rounded-lg border border-border p-3 bg-muted/30">
                        <div className={`p-2 rounded-md ${alert.type === 'danger' ? 'bg-red-500/10 text-red-400' :
                                alert.type === 'warning' ? 'bg-yellow-500/10 text-yellow-400' :
                                    'bg-blue-500/10 text-blue-400'
                            }`}>
                            <alert.icon className="h-4 w-4" />
                        </div>
                        <div className="flex flex-col gap-1">
                            <span className="text-sm font-semibold text-foreground">{alert.title}</span>
                            <p className="text-xs text-muted-foreground leading-relaxed">{alert.message}</p>
                        </div>
                    </div>
                ))}
            </CardContent>
        </Card>
    )
}
