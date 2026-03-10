"use client"

import { useState, useEffect } from "react"
import { fairAdvisorService, FairRecommendation } from "@/lib/services/fairAdvisorService"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Sparkles, Package, DollarSign, AlertTriangle, TrendingUp, RefreshCw } from "lucide-react"
import { toast } from "sonner"

export default function FeriaIAPage() {
  const [recommendations, setRecommendations] = useState<FairRecommendation[] | null>(null)
  const [isLoading, setIsLoading] = useState(false)
  const [isRefreshing, setIsRefreshing] = useState(false)

  useEffect(() => {
    loadLastRecommendation()
  }, [])

  async function loadLastRecommendation() {
    setIsLoading(true)
    try {
      const last = await fairAdvisorService.getLastRecommendation()
      setRecommendations(last)
    } catch (error) {
      console.error("Error loading recommendation:", error)
    } finally {
      setIsLoading(false)
    }
  }

  async function handleGenerate() {
    setIsRefreshing(true)
    try {
      const data = await fairAdvisorService.generateFairRecommendation()
      setRecommendations(data)
      toast.success("¡Recomendación generada con éxito!")
    } catch (error) {
      console.error("Error generating recommendation:", error)
      toast.error("Hubo un error al generar la recomendación.")
    } finally {
      setIsRefreshing(false)
    }
  }

  return (
    <div className="flex flex-col gap-8 pb-10">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold text-foreground tracking-tight flex items-center gap-2">
            <Sparkles className="h-8 w-8 text-primary animate-pulse" />
            Asistente IA para Ferias
          </h1>
          <p className="text-muted-foreground mt-1">
            Recomendaciones inteligentes basadas en tus ventas, márgenes y stock actual.
          </p>
        </div>
        <Button 
          onClick={handleGenerate} 
          disabled={isRefreshing}
          className="bg-primary hover:bg-primary/90 text-primary-foreground shadow-lg shadow-primary/20 transition-all hover:scale-105"
        >
          {isRefreshing ? (
            <RefreshCw className="mr-2 h-4 w-4 animate-spin" />
          ) : (
            <Sparkles className="mr-2 h-4 w-4" />
          )}
          {recommendations ? "Actualizar Recomendación" : "Generar Recomendación"}
        </Button>
      </div>

      {isLoading ? (
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
          {[1, 2, 3].map((i) => (
            <div key={i} className="h-64 rounded-xl border border-border bg-card animate-pulse" />
          ))}
        </div>
      ) : recommendations && recommendations.length > 0 ? (
        <>
          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            {recommendations.map((item, index) => (
              <Card key={index} className="overflow-hidden border-border bg-card/50 backdrop-blur-sm hover:border-primary/50 transition-colors">
                <CardHeader className="pb-3">
                  <div className="flex justify-between items-start mb-2">
                    <Badge variant="secondary" className="bg-primary/10 text-primary border-primary/20">
                      Sugerencia AI
                    </Badge>
                    <TrendingUp className="h-5 w-5 text-emerald-500" />
                  </div>
                  <CardTitle className="text-xl font-bold text-card-foreground">
                    {item.product}
                  </CardTitle>
                  <CardDescription className="text-sm italic leading-tight mt-2 min-h-[3rem]">
                    "{item.reason}"
                  </CardDescription>
                </CardHeader>
                <CardContent className="grid grid-cols-2 gap-4 pt-4 border-t border-border/50 bg-primary/5">
                  <div className="flex flex-col gap-1">
                    <span className="text-[10px] uppercase font-bold text-muted-foreground tracking-wider">Unidades</span>
                    <div className="flex items-center gap-2">
                      <Package className="h-4 w-4 text-primary" />
                      <span className="text-lg font-bold text-card-foreground">{item.recommendedUnits}</span>
                    </div>
                  </div>
                  <div className="flex flex-col gap-1">
                    <span className="text-[10px] uppercase font-bold text-muted-foreground tracking-wider">Precio Sug.</span>
                    <div className="flex items-center gap-2">
                      <DollarSign className="h-4 w-4 text-primary" />
                      <span className="text-lg font-bold text-card-foreground">${item.suggestedPrice}</span>
                    </div>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>

          <Card className="border-amber-500/20 bg-amber-500/5">
            <CardHeader className="pb-2">
              <CardTitle className="text-amber-500 flex items-center gap-2 text-base">
                <AlertTriangle className="h-5 w-5" />
                Consideraciones para la Feria
              </CardTitle>
            </CardHeader>
            <CardContent>
              <ul className="list-disc list-inside space-y-2 text-sm text-muted-foreground">
                <li>Lleva cambio suficiente para transacciones en efectivo.</li>
                <li>Ten preparado tu QR de Mercado Pago en un lugar visible.</li>
                <li>Los precios sugeridos por la IA cubren tus costos básicos, pero recuerda considerar el costo del stand.</li>
                <li>Considera llevar stock adicional de tus productos más vendidos como "back up" si tienes espacio.</li>
              </ul>
            </CardContent>
          </Card>
        </>
      ) : (
        <div className="flex flex-col items-center justify-center py-20 text-center bg-card/30 rounded-3xl border border-dashed border-border">
          <div className="bg-primary/10 p-6 rounded-full mb-6">
            <Sparkles className="h-12 w-12 text-primary" />
          </div>
          <h2 className="text-2xl font-bold text-foreground">¿List@ para tu próxima feria?</h2>
          <p className="text-muted-foreground max-w-md mt-2 px-6">
            Presiona el botón para que nuestra IA analice tus datos y te diga qué productos te conviene llevar para maximizar tus ganancias.
          </p>
          <Button onClick={handleGenerate} disabled={isRefreshing} className="mt-8 px-8">
            {isRefreshing ? <RefreshCw className="mr-2 h-4 w-4 animate-spin" /> : <Sparkles className="mr-2 h-4 w-4" />}
            Empezar Análisis
          </Button>
        </div>
      )}
    </div>
  )
}
