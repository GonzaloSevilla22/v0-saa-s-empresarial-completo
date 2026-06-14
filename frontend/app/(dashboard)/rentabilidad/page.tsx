"use client"

import { useState } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { usePlanGate } from "@/hooks/auth/use-plan-gate"
import { useProfitability } from "@/hooks/use-profitability"
import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell,
} from "recharts"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Sparkles, RefreshCw, Crown, TrendingUp } from "lucide-react"
import { toast } from "sonner"
import { PriceSuggestionModal } from "@/components/ai/PriceSuggestionModal"
import type { ProfitabilityInsight } from "@/lib/types"

// ─── Upgrade CTA ──────────────────────────────────────────────────────────────

function PlanGateFallback() {
  return (
    <div className="flex flex-col items-center justify-center gap-6 py-24 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-yellow-500/10">
        <Crown className="h-8 w-8 text-yellow-500" />
      </div>
      <div>
        <h2 className="text-xl font-bold text-foreground">Rentabilidad por Producto</h2>
        <p className="mt-2 text-sm text-muted-foreground max-w-sm">
          Descubrí qué productos generan más margen. Disponible a partir del plan{" "}
          <span className="font-semibold text-foreground">Avanzado</span>.
        </p>
      </div>
      <Button variant="default" className="bg-yellow-500 hover:bg-yellow-400 text-black font-semibold">
        <TrendingUp className="mr-2 h-4 w-4" />
        Actualizar a Avanzado
      </Button>
    </div>
  )
}

// ─── Number formatters ────────────────────────────────────────────────────────

const fmtARS = (n: number) =>
  new Intl.NumberFormat("es-AR", { style: "currency", currency: "ARS", maximumFractionDigits: 0 }).format(n)

const fmtPct = (n: number) => `${n.toFixed(1)}%`

// ─── Main page ────────────────────────────────────────────────────────────────

export default function RentabilidadPage() {
  const { user } = useAuth()
  const queryClient = useQueryClient()
  const supabase = createClient()

  const { hasAccess, limits, isLoading: gateLoading } = usePlanGate("avanzado")
  const periodDays = limits?.historyDays ?? 30
  const { data: products, isLoading: dataLoading } = useProfitability(hasAccess ? periodDays : 0)

  const [isAnalyzing, setIsAnalyzing] = useState(false)

  // task 4.3: track which product's modal is open (only one at a time)
  const [priceSuggestionState, setPriceSuggestionState] = useState<{
    productId: string
    productName: string
  } | null>(null)

  // Last profitability insight
  const { data: lastInsight } = useQuery<ProfitabilityInsight | null>({
    queryKey: ["profitabilityInsight", user?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("insights")
        .select("id, message, created_at")
        .eq("type", "margen")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      return data as ProfitabilityInsight | null
    },
    staleTime: 30_000,
    enabled:   !!user && hasAccess,
  })

  async function handleAnalyze() {
    if (isAnalyzing) return
    setIsAnalyzing(true)
    try {
      const { data: session } = await supabase.auth.getSession()
      const token = session?.session?.access_token
      if (!token) throw new Error("Sin sesión activa")

      const res = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-rentabilidad`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ period_days: periodDays }),
        }
      )
      const json = await res.json()

      if (!res.ok) {
        if (res.status === 429) {
          toast.warning("Alcanzaste el límite de consultas IA este mes.")
        } else {
          toast.error(json?.error || "Error al generar el análisis")
        }
        return
      }

      if (json?.fallback) {
        toast.warning(json.message || "El análisis no estuvo disponible. Intentá de nuevo.")
        return
      }

      await queryClient.invalidateQueries({ queryKey: ["profitabilityInsight", user?.id] })
      toast.success("Análisis de rentabilidad generado")
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error inesperado"
      toast.error(msg)
    } finally {
      setIsAnalyzing(false)
    }
  }

  if (gateLoading) return null

  if (!hasAccess) return <PlanGateFallback />

  // Chart data: top 10 by gross_margin_pct
  const chartData = products
    .slice(0, 10)
    .map((p) => ({ name: p.product_name, margen: Number(p.gross_margin_pct) }))
    .reverse() // highest at top in horizontal chart

  return (
    <div className="flex flex-col gap-6">
      {/* ── Header ── */}
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Rentabilidad por Producto</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Margen bruto por SKU — últimos {periodDays} días
          </p>
        </div>
        <Button
          onClick={handleAnalyze}
          disabled={isAnalyzing || dataLoading}
          size="sm"
        >
          {isAnalyzing ? (
            <RefreshCw className="h-4 w-4 mr-1 animate-spin" />
          ) : (
            <Sparkles className="h-4 w-4 mr-1" />
          )}
          Analizar con IA
        </Button>
      </div>

      {/* ── AI Insight panel ── */}
      {lastInsight && (
        <Card className="border-primary/20 bg-primary/5">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium flex items-center gap-2">
              <Sparkles className="h-4 w-4 text-primary" />
              Último análisis IA
              <span className="text-xs text-muted-foreground font-normal ml-auto">
                {new Date(lastInsight.created_at).toLocaleDateString("es-AR")}
              </span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-foreground">{lastInsight.message}</p>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-2">
        {/* ── Bar chart ── */}
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium">Top 10 por Margen %</CardTitle>
          </CardHeader>
          <CardContent>
            {dataLoading ? (
              <div className="h-64 flex items-center justify-center text-muted-foreground text-sm">
                Cargando...
              </div>
            ) : chartData.length === 0 ? (
              <div className="h-64 flex items-center justify-center text-muted-foreground text-sm">
                Sin ventas en el período
              </div>
            ) : (
              <ResponsiveContainer width="100%" height={Math.max(chartData.length * 36, 200)}>
                <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 24 }}>
                  <XAxis type="number" tickFormatter={(v) => `${v}%`} tick={{ fontSize: 11 }} />
                  <YAxis
                    type="category"
                    dataKey="name"
                    width={120}
                    tick={{ fontSize: 11 }}
                    tickFormatter={(v: string) => v.length > 16 ? `${v.slice(0, 16)}…` : v}
                  />
                  <Tooltip formatter={(v: number) => [`${v.toFixed(1)}%`, "Margen"]} />
                  <Bar dataKey="margen" radius={[0, 4, 4, 0]}>
                    {chartData.map((entry, i) => (
                      <Cell
                        key={i}
                        fill={entry.margen >= 0 ? "hsl(var(--primary))" : "hsl(var(--destructive))"}
                        fillOpacity={0.8}
                      />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardContent>
        </Card>

        {/* ── Summary stats ── */}
        <div className="flex flex-col gap-4">
          {[
            {
              label: "Mejor margen",
              value: products[0]
                ? `${products[0].product_name} (${fmtPct(products[0].gross_margin_pct)})`
                : "—",
              variant: "default" as const,
            },
            {
              label: "Peor margen",
              value: products.length > 1
                ? `${products.at(-1)!.product_name} (${fmtPct(products.at(-1)!.gross_margin_pct)})`
                : "—",
              variant: "destructive" as const,
            },
            {
              label: "Total revenue período",
              value: fmtARS(products.reduce((s, p) => s + p.total_revenue, 0)),
              variant: "secondary" as const,
            },
            {
              label: "Productos analizados",
              value: `${products.length}`,
              variant: "secondary" as const,
            },
          ].map(({ label, value, variant }) => (
            <Card key={label}>
              <CardContent className="p-4 flex items-center justify-between">
                <span className="text-sm text-muted-foreground">{label}</span>
                <Badge variant={variant} className="text-xs max-w-[180px] truncate">{value}</Badge>
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      {/* ── Table ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Detalle por Producto</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {dataLoading ? (
            <div className="py-12 text-center text-sm text-muted-foreground">Cargando...</div>
          ) : products.length === 0 ? (
            <div className="py-12 text-center text-sm text-muted-foreground">
              Sin ventas en el período seleccionado
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Producto</TableHead>
                  <TableHead className="text-right">Ingresos</TableHead>
                  <TableHead className="text-right">Costo</TableHead>
                  <TableHead className="text-right">Margen %</TableHead>
                  <TableHead className="text-right">Unidades</TableHead>
                  {/* task 4.1: action column for price suggestion */}
                  <TableHead className="w-32" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {products.map((p) => (
                  <TableRow key={p.product_id}>
                    <TableCell className="font-medium max-w-[200px] truncate">{p.product_name}</TableCell>
                    <TableCell className="text-right tabular-nums">{fmtARS(p.total_revenue)}</TableCell>
                    <TableCell className="text-right tabular-nums">{fmtARS(p.total_cost)}</TableCell>
                    <TableCell className="text-right tabular-nums">
                      <span
                        className={
                          p.gross_margin_pct >= 30
                            ? "text-green-500"
                            : p.gross_margin_pct >= 10
                            ? "text-yellow-500"
                            : "text-destructive"
                        }
                      >
                        {fmtPct(p.gross_margin_pct)}
                      </span>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{Number(p.units_sold).toFixed(0)}</TableCell>
                    {/* task 4.1-4.2: action button for price suggestion */}
                    <TableCell>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="h-7 px-2 text-xs text-primary hover:text-primary hover:bg-primary/10"
                        onClick={() =>
                          setPriceSuggestionState({
                            productId:   p.product_id,
                            productName: p.product_name,
                          })
                        }
                        title="Sugerir precio IA"
                      >
                        <Sparkles className="h-3 w-3 mr-1" />
                        Precio IA
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* ── Price Suggestion Modal (task 4.2-4.3) ── */}
      {priceSuggestionState && (
        <PriceSuggestionModal
          productId={priceSuggestionState.productId}
          productName={priceSuggestionState.productName}
          isOpen={priceSuggestionState !== null}
          onClose={() => setPriceSuggestionState(null)}
        />
      )}
    </div>
  )
}
