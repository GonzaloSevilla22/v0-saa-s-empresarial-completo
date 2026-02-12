"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { InsightCard } from "@/components/ai/insight-card"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Sparkles, RefreshCw } from "lucide-react"
import { MAX_INSIGHTS_FREE } from "@/lib/constants"
import type { Insight } from "@/lib/types"

const extraInsights: Insight[] = [
  { id: "ix1", type: "oportunidad", priority: "alta", message: "Los fines de semana tus ventas bajan un 40%. Considera promociones especiales para sábados.", date: new Date().toISOString().split("T")[0] },
  { id: "ix2", type: "ahorro", priority: "media", message: "Podrías ahorrar $200/mes comprando Cable HDMI en lotes de 200 unidades. El proveedor ofrece 15% de descuento.", date: new Date().toISOString().split("T")[0] },
  { id: "ix3", type: "clientes", priority: "baja", message: "Valentina Ruiz no compra hace 90 días. Un cupón de descuento podría reactivarla.", date: new Date().toISOString().split("T")[0] },
]

export default function InsightsPage() {
  const { insights, addInsight } = useData()
  const { user } = useAuth()
  const [isGenerating, setIsGenerating] = useState(false)
  const [generated, setGenerated] = useState(0)

  const isFree = user?.plan === "free"
  const usedInsights = insights.length
  const atLimit = isFree && generated >= MAX_INSIGHTS_FREE

  function handleGenerate() {
    if (atLimit) return
    setIsGenerating(true)
    setTimeout(() => {
      const newInsight = extraInsights[generated % extraInsights.length]
      addInsight({ ...newInsight, id: `ig${Date.now()}` })
      setGenerated((prev) => prev + 1)
      setIsGenerating(false)
    }, 1500)
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Insights AI</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Recomendaciones inteligentes basadas en tus datos
          </p>
        </div>
        <div className="flex items-center gap-3">
          {isFree && (
            <span className="text-xs text-muted-foreground">
              {generated}/{MAX_INSIGHTS_FREE} generados
            </span>
          )}
          <Button
            onClick={handleGenerate}
            disabled={isGenerating || atLimit}
            size="sm"
          >
            {isGenerating ? (
              <RefreshCw className="h-4 w-4 mr-1 animate-spin" />
            ) : (
              <Sparkles className="h-4 w-4 mr-1" />
            )}
            Generar insights
          </Button>
        </div>
      </div>

      {atLimit && (
        <Card className="border-yellow-500/30 bg-yellow-500/5">
          <CardContent className="p-4">
            <p className="text-sm text-yellow-400">
              Alcanzaste el limite de {MAX_INSIGHTS_FREE} insights del plan gratuito. Actualiza a Pro para obtener insights ilimitados.
            </p>
          </CardContent>
        </Card>
      )}

      <div className="flex flex-col gap-3">
        {insights.map((insight) => (
          <InsightCard key={insight.id} insight={insight} />
        ))}
      </div>
    </div>
  )
}
