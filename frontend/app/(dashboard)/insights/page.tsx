"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { InsightCard } from "@/components/ai/insight-card"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Sparkles, RefreshCw } from "lucide-react"
import { MAX_INSIGHTS_FREE } from "@/lib/constants"
import { aiInsightService } from "@/lib/services/aiInsightService"
import { toast } from "sonner"

export default function InsightsPage() {
  const { insights, refreshData } = useData()
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const [isGenerating, setIsGenerating] = useState(false)

  // Real monthly AI-query quota from the plan; counter enforced server-side.
  const maxInsights  = limits?.maxAiQueriesPerMonth ?? MAX_INSIGHTS_FREE
  const usedInsights = user?.aiQueriesUsed ?? insights.length
  const atLimit = usedInsights >= maxInsights

  async function handleGenerate() {
    if (atLimit) return
    setIsGenerating(true)
    try {
      const result = await aiInsightService.generateInsights()
      if (result === null) {
        // Fallback or key not configured â€“ show friendly message, don't crash UI
        toast.warning("El asistente no estÃ¡ disponible en este momento. Intentalo mÃ¡s tarde.")
        return
      }
      await refreshData()
      toast.success("Consejos generados correctamente")
    } catch (error: any) {
      console.error('[Insights] Generate failed:', error.message)
      toast.error(error.message || "Error al generar consejos")
    } finally {
      setIsGenerating(false)
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Consejos AI</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Recomendaciones inteligentes basadas en tus datos
          </p>
        </div>
        <div className="flex items-center gap-3">
          <span className="text-xs text-muted-foreground">
            {usedInsights}/{maxInsights} consultas IA este mes
          </span>
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
            Generar consejos
          </Button>
        </div>
      </div>

      {atLimit && (
        <Card className="border-yellow-500/30 bg-yellow-500/5">
          <CardContent className="p-4">
            <p className="text-sm text-yellow-400">
              Alcanzaste el lÃ­mite de {MAX_INSIGHTS_FREE} consejos del plan gratuito. ActualizÃ¡ a Pro para obtener consejos ilimitados.
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
