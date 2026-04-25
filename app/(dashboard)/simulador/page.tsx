"use client"

import { useState, useMemo } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Slider } from "@/components/ui/slider"
import { Button } from "@/components/ui/button"
import { Sparkles, TrendingUp, DollarSign, Percent, Loader2 } from "lucide-react"

export default function SimuladorPage() {
  const { products, sales } = useData()
  const [productId, setProductId] = useState(products[0]?.id || "")
  const [newPrice, setNewPrice] = useState(0)
  const [suggestion, setSuggestion] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(false)

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])

  const currentPrice = selectedProduct?.price || 0
  const cost = selectedProduct?.cost || 0
  const effectivePrice = newPrice || currentPrice

  const currentMargin = currentPrice > 0 ? ((currentPrice - cost) / currentPrice) * 100 : 0
  const newMargin = effectivePrice > 0 ? ((effectivePrice - cost) / effectivePrice) * 100 : 0

  const productSales = useMemo(
    () => sales.filter((s) => s.productId === productId),
    [sales, productId]
  )
  const avgQtyPerSale = productSales.length > 0
    ? productSales.reduce((acc, s) => acc + s.quantity, 0) / productSales.length
    : 1

  const currentRevenue = currentPrice * avgQtyPerSale * 30
  const projectedRevenue = effectivePrice * avgQtyPerSale * 30 * (effectivePrice > currentPrice ? 0.9 : 1.1)

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) setNewPrice(p.price)
    setSuggestion(null)
  }

  /**
   * Calls the real ai-simulador edge function with actual product data and
   * the proposed price change as the scenario. Replaces the previous fake
   * setTimeout + hardcoded cost*2.2 formula.
   */
  async function handleSuggest() {
    if (!selectedProduct) return
    setIsLoading(true)
    setSuggestion(null)

    const scenario =
      `Producto: "${selectedProduct.name}". ` +
      `Costo: $${cost}. ` +
      `Precio actual: $${currentPrice} (margen ${currentMargin.toFixed(0)}%). ` +
      `Precio propuesto: $${effectivePrice} (margen proyectado ${newMargin.toFixed(0)}%). ` +
      `Historial: ${productSales.length} ventas registradas, promedio ${avgQtyPerSale.toFixed(1)} unidades por venta. ` +
      `Ingreso mensual actual estimado: $${currentRevenue.toFixed(0)}. ` +
      `Proyección con nuevo precio: $${projectedRevenue.toFixed(0)}. ` +
      `¿Vale la pena este cambio de precio? ¿Cuál sería el precio óptimo y por qué? Sé concreto.`

    try {
      const supabase = createClient()
      const { data, error } = await supabase.functions.invoke('ai-simulador', {
        body: { scenario },
      })

      if (error) throw error

      // ai-simulador returns { ok, data } where data is either:
      //   - an insights DB row { content, ... }  (when RPC succeeds)
      //   - a raw OpenAI string                  (when RPC fails gracefully)
      const text: string =
        (typeof data?.data === 'string' ? data.data : data?.data?.content) ??
        "No se pudo generar la sugerencia en este momento."

      setSuggestion(text)
    } catch (err: any) {
      console.error('[Simulador] AI error:', err)
      setSuggestion(`Error al consultar la IA: ${err.message ?? 'sin detalles'}. Intentá nuevamente.`)
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Simulador de Precios</h1>
        <p className="text-sm text-muted-foreground mt-1">Experimentá con precios y consultá a la IA el impacto real en tu margen</p>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-2">
        <div className="flex flex-col gap-4">
          <Card className="border-border bg-card">
            <CardHeader className="pb-3">
              <CardTitle className="text-sm font-medium text-card-foreground">Configuración</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-5">
              <div className="flex flex-col gap-2">
                <Label className="text-foreground">Producto</Label>
                <Select value={productId} onValueChange={handleProductChange}>
                  <SelectTrigger className="bg-background border-border text-foreground">
                    <SelectValue placeholder="Seleccionar producto" />
                  </SelectTrigger>
                  <SelectContent className="bg-popover border-border">
                    {products.map((p) => (
                      <SelectItem key={p.id} value={p.id}>
                        {p.name} (${p.price})
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {selectedProduct && (
                <>
                  <div className="flex flex-col gap-3">
                    <div className="flex items-center justify-between">
                      <Label className="text-foreground">Nuevo precio</Label>
                      <span className="text-lg font-bold text-primary">${effectivePrice}</span>
                    </div>
                    <Slider
                      value={[effectivePrice]}
                      onValueChange={([v]) => setNewPrice(v)}
                      min={Math.max(1, cost)}
                      max={currentPrice * 3}
                      step={1}
                      className="w-full"
                    />
                    <div className="flex justify-between text-xs text-muted-foreground">
                      <span>${Math.max(1, cost)} (costo)</span>
                      <span>${currentPrice * 3}</span>
                    </div>
                  </div>

                  <Button
                    onClick={handleSuggest}
                    disabled={isLoading}
                    variant="outline"
                    className="border-primary/30 text-primary hover:bg-primary/10 hover:text-primary"
                  >
                    {isLoading ? (
                      <>
                        <Loader2 className="h-4 w-4 mr-1 animate-spin" />
                        Analizando con IA...
                      </>
                    ) : (
                      <>
                        <Sparkles className="h-4 w-4 mr-1" />
                        Pedir análisis IA
                      </>
                    )}
                  </Button>

                  {suggestion && (
                    <div className="rounded-lg border border-primary/20 bg-primary/5 p-3">
                      <p className="text-sm text-foreground leading-relaxed whitespace-pre-wrap">{suggestion}</p>
                    </div>
                  )}
                </>
              )}
            </CardContent>
          </Card>
        </div>

        {selectedProduct && (
          <div className="flex flex-col gap-4">
            <div className="grid gap-4 grid-cols-2">
              <Card className="border-border bg-card">
                <CardContent className="p-4 flex flex-col items-center gap-1">
                  <Percent className="h-5 w-5 text-muted-foreground mb-1" />
                  <span className="text-xs text-muted-foreground">Margen actual</span>
                  <span className="text-xl font-bold text-card-foreground">{currentMargin.toFixed(0)}%</span>
                </CardContent>
              </Card>
              <Card className="border-primary/20 bg-card">
                <CardContent className="p-4 flex flex-col items-center gap-1">
                  <Percent className="h-5 w-5 text-primary mb-1" />
                  <span className="text-xs text-muted-foreground">Nuevo margen</span>
                  <span className={`text-xl font-bold ${newMargin > currentMargin ? "text-emerald-400" : "text-red-400"}`}>
                    {newMargin.toFixed(0)}%
                  </span>
                </CardContent>
              </Card>
              <Card className="border-border bg-card">
                <CardContent className="p-4 flex flex-col items-center gap-1">
                  <DollarSign className="h-5 w-5 text-muted-foreground mb-1" />
                  <span className="text-xs text-muted-foreground">Ingreso mensual est.</span>
                  <span className="text-xl font-bold text-card-foreground">${currentRevenue.toFixed(0)}</span>
                </CardContent>
              </Card>
              <Card className="border-primary/20 bg-card">
                <CardContent className="p-4 flex flex-col items-center gap-1">
                  <TrendingUp className="h-5 w-5 text-primary mb-1" />
                  <span className="text-xs text-muted-foreground">Proyección</span>
                  <span className={`text-xl font-bold ${projectedRevenue > currentRevenue ? "text-emerald-400" : "text-red-400"}`}>
                    ${projectedRevenue.toFixed(0)}
                  </span>
                </CardContent>
              </Card>
            </div>

            <Card className="border-border bg-card">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm text-card-foreground">Escenarios</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="flex flex-col gap-2">
                  {[0.8, 0.9, 1.0, 1.1, 1.2].map((mult) => {
                    const scenarioPrice = Math.round(currentPrice * mult)
                    const scenarioMargin = scenarioPrice > 0 ? ((scenarioPrice - cost) / scenarioPrice) * 100 : 0
                    return (
                      <div key={mult} className="flex items-center justify-between rounded-md border border-border p-2">
                        <span className="text-sm text-card-foreground">${scenarioPrice}</span>
                        <span className="text-xs text-muted-foreground">{mult === 1.0 ? "Precio actual" : `${mult > 1 ? "+" : ""}${((mult - 1) * 100).toFixed(0)}%`}</span>
                        <span className={`text-sm font-medium ${scenarioMargin >= 50 ? "text-emerald-400" : scenarioMargin >= 30 ? "text-yellow-400" : "text-red-400"}`}>
                          {scenarioMargin.toFixed(0)}% margen
                        </span>
                      </div>
                    )
                  })}
                </div>
              </CardContent>
            </Card>
          </div>
        )}
      </div>
    </div>
  )
}
