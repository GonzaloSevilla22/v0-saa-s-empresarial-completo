"use client"

import { useEffect } from "react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Sparkles, RefreshCw } from "lucide-react"
import { useCriticalStock } from "@/hooks/data/use-critical-stock"
import { useAiDailySummary } from "@/hooks/data/use-ai-daily-summary"
import { aiSummaryErrorMessage } from "@/lib/ai-summary"
import { formatKpiCurrency } from "@/lib/kpi-format"

// ─── Props ────────────────────────────────────────────────────────────────────

interface AiSummaryCardProps {
  /** Today's total sales income — supplied by the parent dashboard page
   *  (fetched via get_dashboard_financials RPC). Defaults to 0. */
  todaySales?: number
  /** Sucursal activa del Tablero; `null` usa el agregado consciente de
   * sucursal del KPI canónico. */
  branchId?: string | null
}

// ─── Component ────────────────────────────────────────────────────────────────

export function AiSummaryCard({ todaySales = 0, branchId = null }: AiSummaryCardProps) {
  const { data: criticalStockCount } = useCriticalStock(branchId)

  // tablero-explicable (D7): el resumen es una consulta por cuenta y día
  // (cacheada en la sesión: volver al Tablero no gasta otra consulta de IA).
  // «Regenerar» es `refetch()`. El estado de carga es un estado propio, no un
  // texto de resumen provisorio.
  const { data: summary, error, isPending, isFetching, isError, refetch } = useAiDailySummary()
  const isLoading = isFetching || isPending

  useEffect(() => {
    if (error) console.error("[AiSummaryCard] Error:", error)
  }, [error])

  return (
    <Card className="border-primary/20 bg-card relative overflow-hidden">
      <div className="absolute inset-0 bg-gradient-to-br from-primary/5 to-transparent pointer-events-none" />
      <CardHeader className="flex flex-row items-center justify-between pb-2 relative">
        <div className="flex items-center gap-2">
          <div className="flex h-7 w-7 items-center justify-center rounded-md bg-primary/20">
            <Sparkles className="h-4 w-4 text-primary" />
          </div>
          <CardTitle className="text-sm font-medium text-card-foreground">
            Resumen IA del día
          </CardTitle>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => void refetch()}
          disabled={isFetching}
          className="h-7 text-xs text-muted-foreground hover:text-foreground"
        >
          <RefreshCw className={`h-3 w-3 mr-1 ${isFetching ? "animate-spin" : ""}`} />
          Regenerar
        </Button>
      </CardHeader>
      <CardContent className="relative">
        {isLoading ? (
          <div role="status" aria-live="polite" className="flex flex-col gap-2">
            <span className="flex items-center gap-2 text-sm text-muted-foreground">
              <RefreshCw className="h-3.5 w-3.5 shrink-0 animate-spin" aria-hidden="true" />
              Generando el resumen… suele tardar unos segundos
            </span>
            <span aria-hidden="true" className="h-3 w-full animate-pulse rounded bg-muted" />
            <span aria-hidden="true" className="h-3 w-2/3 animate-pulse rounded bg-muted" />
          </div>
        ) : isError ? (
          <p role="alert" className="text-sm text-destructive leading-relaxed">
            {aiSummaryErrorMessage(error)}
          </p>
        ) : (
          <p className="text-sm text-muted-foreground leading-relaxed">{summary}</p>
        )}
        <div className="mt-3 flex items-center gap-4 text-xs text-muted-foreground/70">
          <span>Ventas hoy: <span className="text-primary font-medium">{formatKpiCurrency(todaySales)}</span></span>
          <span>Stock bajo: <span className={`font-medium ${criticalStockCount > 0 ? "text-destructive" : "text-success"}`}>{criticalStockCount} productos</span></span>
        </div>
      </CardContent>
    </Card>
  )
}
