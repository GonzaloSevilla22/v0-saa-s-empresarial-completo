"use client"

import { useState, useMemo } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Slider } from "@/components/ui/slider"
import { Button } from "@/components/ui/button"
import { Sparkles, TrendingUp, DollarSign, Percent, Loader2, RefreshCw, AlertCircle, Clock } from "lucide-react"

// ── Constants ──────────────────────────────────────────────────────────────────

/** Client-side timeout: slightly above the Edge Function's own 25 s timeout
 *  so we always receive the server-side error message instead of a browser abort. */
const FRONTEND_TIMEOUT_MS = 30_000

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Maps raw server-side error strings to human-readable Spanish messages.
 * Falls back to the original string if no mapping matches.
 */
function friendlyError(raw: string): string {
  const r = raw.toLowerCase()
  if (r.includes('timeout') || r.includes('tardó demasiado'))
    return 'La IA tardó demasiado en responder. OpenAI puede estar con alta demanda — intentá en unos segundos.'
  if (r.includes('openai_api_key') || r.includes('missing openai'))
    return 'Configuración incompleta del servidor. Contactá al administrador.'
  if (r.includes('rate limit') || r.includes('429'))
    return 'Demasiadas consultas en poco tiempo. Esperá unos segundos e intentá nuevamente.'
  if (r.includes('sesión') || r.includes('no autorizado') || r.includes('401'))
    return 'Tu sesión expiró. Recargá la página e iniciá sesión de nuevo.'
  if (r.includes('network') || r.includes('failed to fetch') || r.includes('error de red'))
    return 'Error de conexión. Verificá tu internet e intentá nuevamente.'
  if (r.includes('tiempo de espera agotado'))
    return 'Tiempo de espera agotado (30 s). La IA puede estar ocupada — intentá nuevamente.'
  return raw
}

// ── Component ──────────────────────────────────────────────────────────────────

export default function SimuladorPage() {
  const { products, sales } = useData()
  const [productId,  setProductId]  = useState(products[0]?.id || "")
  const [newPrice,   setNewPrice]   = useState(0)
  const [suggestion, setSuggestion] = useState<string | null>(null)
  const [errorMsg,   setErrorMsg]   = useState<string | null>(null)
  const [isLoading,  setIsLoading]  = useState(false)
  const [isSlow,     setIsSlow]     = useState(false)   // shows "still working…" hint after 10 s

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])

  const currentPrice = selectedProduct?.price || 0
  const cost         = selectedProduct?.cost  || 0
  const effectivePrice = newPrice || currentPrice

  const currentMargin  = currentPrice  > 0 ? ((currentPrice  - cost) / currentPrice)  * 100 : 0
  const newMargin      = effectivePrice > 0 ? ((effectivePrice - cost) / effectivePrice) * 100 : 0

  const productSales = useMemo(
    () => sales.filter((s) => s.productId === productId),
    [sales, productId],
  )
  const avgQtyPerSale = productSales.length > 0
    ? productSales.reduce((acc, s) => acc + s.quantity, 0) / productSales.length
    : 1

  const currentRevenue   = currentPrice   * avgQtyPerSale * 30
  const projectedRevenue = effectivePrice * avgQtyPerSale * 30 * (effectivePrice > currentPrice ? 0.9 : 1.1)

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) setNewPrice(p.price)
    setSuggestion(null)
    setErrorMsg(null)
  }

  // ── AI request ───────────────────────────────────────────────────────────────
  async function handleSuggest() {
    if (!selectedProduct) return

    setIsLoading(true)
    setSuggestion(null)
    setErrorMsg(null)
    setIsSlow(false)

    // "Still working…" hint after 10 s so the user knows we haven't frozen
    const slowTimer = setTimeout(() => setIsSlow(true), 10_000)

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
      const { data: { session } } = await supabase.auth.getSession()

      if (!session?.access_token) {
        throw new Error('Tu sesión expiró. Recargá la página e iniciá sesión de nuevo.')
      }

      // Use fetch directly instead of supabase.functions.invoke so we can:
      //  1. Read the actual error body (invoke swallows it as a generic message)
      //  2. Apply our own client-side timeout
      const controller = new AbortController()
      const timeoutId  = setTimeout(() => controller.abort(), FRONTEND_TIMEOUT_MS)

      let response: Response
      try {
        response = await fetch(
          `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-simulador`,
          {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${session.access_token}`,
              'apikey':         process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
              'Content-Type':   'application/json',
            },
            body:   JSON.stringify({ scenario }),
            signal: controller.signal,
          },
        )
      } catch (fetchErr: any) {
        const isAbort = fetchErr?.name === 'AbortError'
        throw new Error(
          isAbort
            ? 'Tiempo de espera agotado (30 s). La IA puede estar ocupada — intentá nuevamente.'
            : 'Error de red al conectar con el servidor.',
        )
      } finally {
        clearTimeout(timeoutId)
      }

      // Non-2xx: read the real error from the body
      if (!response.ok) {
        let serverError = `Error del servidor (${response.status})`
        try {
          const body = await response.json()
          if (typeof body?.error === 'string') serverError = body.error
        } catch { /* body not JSON — keep generic */ }
        throw new Error(serverError)
      }

      const body = await response.json()

      // ai-simulador returns { ok, data } where data is either:
      //   - a DB insight row  { content, … }  (when RPC succeeds)
      //   - a raw string                       (when RPC fails gracefully)
      const text: string =
        (typeof body?.data === 'string' ? body.data : body?.data?.content) ??
        'No se pudo generar la sugerencia en este momento.'

      setSuggestion(text)

    } catch (err: any) {
      console.error('[Simulador] AI error:', err)
      setErrorMsg(friendlyError(err.message ?? 'Error desconocido'))
    } finally {
      clearTimeout(slowTimer)
      setIsSlow(false)
      setIsLoading(false)
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Simulador de Precios</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Experimentá con precios y consultá a la IA el impacto real en tu margen
        </p>
      </div>

      <div className="grid gap-6 grid-cols-1 lg:grid-cols-2">
        <div className="flex flex-col gap-4">
          <Card className="border-border bg-card">
            <CardHeader className="pb-3">
              <CardTitle className="text-sm font-medium text-card-foreground">Configuración</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-5">
              {/* Product selector */}
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
                  {/* Price slider */}
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

                  {/* CTA button */}
                  <Button
                    onClick={handleSuggest}
                    disabled={isLoading}
                    variant="outline"
                    className="border-primary/30 text-primary hover:bg-primary/10 hover:text-primary"
                  >
                    {isLoading ? (
                      <>
                        <Loader2 className="h-4 w-4 mr-1 animate-spin" />
                        Analizando con IA…
                      </>
                    ) : (
                      <>
                        <Sparkles className="h-4 w-4 mr-1" />
                        Pedir análisis IA
                      </>
                    )}
                  </Button>

                  {/* "Still working" hint after 10 s */}
                  {isSlow && isLoading && (
                    <div className="flex items-center gap-2 text-xs text-muted-foreground">
                      <Clock className="h-3.5 w-3.5 shrink-0 animate-pulse" />
                      OpenAI puede tardar hasta 25 segundos en períodos de alta demanda…
                    </div>
                  )}

                  {/* AI suggestion */}
                  {suggestion && (
                    <div className="rounded-lg border border-primary/20 bg-primary/5 p-3">
                      <p className="text-sm text-foreground leading-relaxed whitespace-pre-wrap">
                        {suggestion}
                      </p>
                    </div>
                  )}

                  {/* Error state with retry */}
                  {errorMsg && (
                    <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 flex flex-col gap-2">
                      <div className="flex items-start gap-2">
                        <AlertCircle className="h-4 w-4 text-destructive shrink-0 mt-0.5" />
                        <p className="text-sm text-destructive leading-relaxed">{errorMsg}</p>
                      </div>
                      <Button
                        variant="outline"
                        size="sm"
                        onClick={handleSuggest}
                        className="self-start border-destructive/30 text-destructive hover:bg-destructive/10 gap-1.5"
                      >
                        <RefreshCw className="h-3.5 w-3.5" />
                        Reintentar
                      </Button>
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
                    const scenarioPrice  = Math.round(currentPrice * mult)
                    const scenarioMargin = scenarioPrice > 0 ? ((scenarioPrice - cost) / scenarioPrice) * 100 : 0
                    return (
                      <div key={mult} className="flex items-center justify-between rounded-md border border-border p-2">
                        <span className="text-sm text-card-foreground">${scenarioPrice}</span>
                        <span className="text-xs text-muted-foreground">
                          {mult === 1.0 ? "Precio actual" : `${mult > 1 ? "+" : ""}${((mult - 1) * 100).toFixed(0)}%`}
                        </span>
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
