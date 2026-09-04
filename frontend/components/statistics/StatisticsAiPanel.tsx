"use client"

/**
 * estadisticas-ventas E3 (task 10.5) — "Analizar con IA" de /estadisticas.
 *
 * Botón con la cuota de consultas IA del plan (useAiUsage), estado de carga,
 * el panel del último insight persistido y las recomendaciones del análisis
 * recién generado. Molde del bloque de IA de /rentabilidad; la llamada vive
 * en hooks/data/use-statistics-ai.ts.
 *
 * Con la cuota agotada el botón se deshabilita y el motivo queda visible —
 * nunca un botón muerto sin explicación. El análisis se pide sobre el MISMO
 * período y la MISMA sucursal que la pantalla muestra.
 */

import { useState } from "react"
import { RefreshCw, Sparkles } from "lucide-react"
import { toast } from "sonner"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { useAiUsage } from "@/hooks/auth/use-ai-usage"
import { useAnalyzeStatistics, useLastStatisticsInsight } from "@/hooks/data/use-statistics-ai"

interface StatisticsAiPanelProps {
  /** "YYYY-MM-DD" (fecha de negocio). */
  start: string
  end: string
  branchId: string | null
}

const QUOTA_MESSAGE = "Alcanzaste el límite de consultas IA este mes."

export function StatisticsAiPanel({ start, end, branchId }: StatisticsAiPanelProps) {
  const { queriesRemaining, isLoading: usageLoading } = useAiUsage()
  const { data: lastInsight } = useLastStatisticsInsight()
  const analyze = useAnalyzeStatistics()
  const [recommendations, setRecommendations] = useState<string[]>([])

  const quotaExhausted = !usageLoading && queriesRemaining === 0
  const disabled = analyze.isPending || usageLoading || quotaExhausted

  async function handleAnalyze() {
    if (disabled) return
    try {
      const result = await analyze.mutateAsync({ start, end, branchId })
      switch (result.status) {
        case "ok":
          setRecommendations(result.recommendations)
          toast.success("Análisis de estadísticas generado")
          break
        case "quota_exceeded":
          toast.warning(QUOTA_MESSAGE)
          break
        case "fallback":
          toast.warning(result.message)
          break
        case "error":
          toast.error(result.message)
          break
      }
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error inesperado")
    }
  }

  return (
    <Card className="min-w-0 border-primary/20 bg-primary/5">
      <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-col gap-1">
          <CardTitle className="text-sm font-medium flex items-center gap-2">
            <Sparkles className="h-4 w-4 text-primary" aria-hidden="true" />
            Análisis con IA
          </CardTitle>
          <p className="text-xs text-muted-foreground">
            Un resumen en lenguaje claro de la evolución, el ranking, los canales, los días y los clientes del período,
            {" "}con recomendaciones concretas.
            {!usageLoading && !quotaExhausted && (
              <span className="ml-1 text-foreground">{queriesRemaining} {queriesRemaining === 1 ? "consulta IA restante" : "consultas IA restantes"}.</span>
            )}
          </p>
          {quotaExhausted && (
            <p className="text-xs text-warning" role="note">{QUOTA_MESSAGE} Se renueva el 1ro del mes próximo.</p>
          )}
        </div>
        <Button onClick={handleAnalyze} disabled={disabled} size="sm" className="shrink-0">
          {analyze.isPending ? (
            <>
              <RefreshCw className="h-4 w-4 mr-1 animate-spin" aria-hidden="true" />
              Analizando…
            </>
          ) : (
            <>
              <Sparkles className="h-4 w-4 mr-1" aria-hidden="true" />
              Analizar con IA
            </>
          )}
        </Button>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {lastInsight ? (
          <div className="flex flex-col gap-1">
            <p className="text-xs text-muted-foreground">
              <span className="font-medium text-foreground">Último análisis</span>
              {" · "}
              {new Date(lastInsight.createdAt).toLocaleDateString("es-AR")}
            </p>
            <p className="text-sm text-foreground">{lastInsight.message}</p>
          </div>
        ) : (
          <p className="text-sm text-muted-foreground">
            Todavía no hay un análisis de este módulo. Generá el primero con el botón.
          </p>
        )}
        {recommendations.length > 0 && (
          <ul aria-label="Recomendaciones" className="list-disc pl-5 text-sm text-foreground flex flex-col gap-1">
            {recommendations.map((r, i) => (
              <li key={i}>{r}</li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
