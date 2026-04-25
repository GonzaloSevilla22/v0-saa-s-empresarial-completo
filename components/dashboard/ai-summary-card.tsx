"use client"

import { useState, useEffect } from "react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Sparkles, RefreshCw } from "lucide-react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"

export function AiSummaryCard() {
  const { getTodaySales, getLowStockProducts } = useData()
  const [summary, setSummary] = useState("Cargando resumen inteligente...")
  const [isLoading, setIsLoading] = useState(false)

  const todaySales = getTodaySales()
  const lowStock = getLowStockProducts()

  async function handleRegenerate() {
    setIsLoading(true)
    const supabase = createClient()
    try {
      const { data, error } = await supabase.functions.invoke('ai-resumen', {
        body: { period: 'daily' },
      })

      if (error) throw error

      // ai-resumen returns { ok, data } where data is either:
      //   - an insights DB row  { content, type, ... }  (when RPC succeeds)
      //   - a raw OpenAI string                          (when RPC fails gracefully)
      const text: string =
        (typeof data?.data === 'string' ? data.data : data?.data?.content) ??
        "No se pudo generar el resumen en este momento."

      setSummary(text)
    } catch (err) {
      console.error('[AiSummaryCard] Error:', err)
      setSummary("Error al conectar con la IA de ALIADATA. Reintentá en unos minutos.")
    } finally {
      setIsLoading(false)
    }
  }

  // Initial load on mount
  useEffect(() => {
    handleRegenerate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <Card className="border-primary/20 bg-card relative overflow-hidden">
      <div className="absolute inset-0 bg-gradient-to-br from-primary/5 to-transparent pointer-events-none" />
      <CardHeader className="flex flex-row items-center justify-between pb-2 relative">
        <div className="flex items-center gap-2">
          <div className="flex h-7 w-7 items-center justify-center rounded-md bg-primary/20">
            <Sparkles className="h-4 w-4 text-primary" />
          </div>
          <CardTitle className="text-sm font-medium text-card-foreground">
            Resumen AI del día
          </CardTitle>
        </div>
        <Button
          variant="ghost"
          size="sm"
          onClick={handleRegenerate}
          disabled={isLoading}
          className="h-7 text-xs text-muted-foreground hover:text-foreground"
        >
          <RefreshCw className={`h-3 w-3 mr-1 ${isLoading ? "animate-spin" : ""}`} />
          Regenerar
        </Button>
      </CardHeader>
      <CardContent className="relative">
        <p className="text-sm text-muted-foreground leading-relaxed">
          {summary}
        </p>
        <div className="mt-3 flex items-center gap-4 text-xs text-muted-foreground/70">
          <span>Ventas hoy: <span className="text-primary font-medium">${todaySales}</span></span>
          <span>Stock bajo: <span className={`font-medium ${lowStock.length > 0 ? "text-red-400" : "text-emerald-400"}`}>{lowStock.length} productos</span></span>
        </div>
      </CardContent>
    </Card>
  )
}
