"use client"

import { useState, useMemo } from "react"
import { useQueryClient, useQuery } from "@tanstack/react-query"
import { format, startOfMonth, endOfMonth, subMonths, parseISO, isAfter, isBefore, subDays } from "date-fns"
import { es } from "date-fns/locale"
import { usePlanGate } from "@/hooks/auth/use-plan-gate"
import { usePeriodComparison } from "@/hooks/use-period-comparison"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Legend,
} from "recharts"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Calendar } from "@/components/ui/calendar"
import { Sparkles, RefreshCw, Crown, GitCompare, CalendarIcon, AlertTriangle } from "lucide-react"
import { toast } from "sonner"
import type { ComparativeInsight } from "@/lib/types"

// ─── Upgrade CTA ──────────────────────────────────────────────────────────────

function PlanGateFallback() {
  return (
    <div className="flex flex-col items-center justify-center gap-6 py-24 text-center">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-yellow-500/10">
        <Crown className="h-8 w-8 text-yellow-500" />
      </div>
      <div>
        <h2 className="text-xl font-bold text-foreground">Reportes Comparativos</h2>
        <p className="mt-2 text-sm text-muted-foreground max-w-sm">
          Compará tu desempeño entre períodos y detectá tendencias. Disponible a partir del plan{" "}
          <span className="font-semibold text-foreground">Avanzado</span>.
        </p>
      </div>
      <Button variant="default" className="bg-yellow-500 hover:bg-yellow-400 text-black font-semibold">
        <GitCompare className="mr-2 h-4 w-4" />
        Actualizar a Avanzado
      </Button>
    </div>
  )
}

// ─── Formatters ───────────────────────────────────────────────────────────────

const fmtARS = (n: number) =>
  new Intl.NumberFormat("es-AR", { style: "currency", currency: "ARS", maximumFractionDigits: 0 }).format(n)

const fmtDate = (d: Date) => format(d, "dd/MM/yyyy", { locale: es })

const toISO = (d: Date) => format(d, "yyyy-MM-dd")

// ─── Delta badge ──────────────────────────────────────────────────────────────

function DeltaBadge({ value, invertColors = false }: { value: number | null; invertColors?: boolean }) {
  if (value == null) return <Badge variant="secondary" className="text-xs">N/A</Badge>

  const isPositive = value > 0
  const isGood     = invertColors ? !isPositive : isPositive
  const label      = `${isPositive ? "+" : ""}${value.toFixed(1)}%`

  return (
    <Badge
      variant="outline"
      className={`text-xs font-semibold ${
        isGood
          ? "border-green-500/40 text-green-500 bg-green-500/10"
          : "border-destructive/40 text-destructive bg-destructive/10"
      }`}
    >
      {label}
    </Badge>
  )
}

// ─── Date picker ──────────────────────────────────────────────────────────────

function DateRangePicker({
  label,
  from,
  to,
  onFromChange,
  onToChange,
  minDate,
}: {
  label:        string
  from:         Date
  to:           Date
  onFromChange: (d: Date) => void
  onToChange:   (d: Date) => void
  minDate:      Date
}) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs font-medium text-muted-foreground uppercase tracking-wide">{label}</span>
      <div className="flex items-center gap-2">
        <Popover>
          <PopoverTrigger asChild>
            <Button variant="outline" size="sm" className="text-xs">
              <CalendarIcon className="h-3 w-3 mr-1" />
              {fmtDate(from)}
            </Button>
          </PopoverTrigger>
          <PopoverContent className="w-auto p-0" align="start">
            <Calendar
              mode="single"
              selected={from}
              onSelect={(d) => d && onFromChange(d)}
              disabled={(d) => isBefore(d, minDate) || isAfter(d, new Date())}
              initialFocus
            />
          </PopoverContent>
        </Popover>
        <span className="text-xs text-muted-foreground">→</span>
        <Popover>
          <PopoverTrigger asChild>
            <Button variant="outline" size="sm" className="text-xs">
              <CalendarIcon className="h-3 w-3 mr-1" />
              {fmtDate(to)}
            </Button>
          </PopoverTrigger>
          <PopoverContent className="w-auto p-0" align="start">
            <Calendar
              mode="single"
              selected={to}
              onSelect={(d) => d && onToChange(d)}
              disabled={(d) => isBefore(d, from) || isAfter(d, new Date())}
              initialFocus
            />
          </PopoverContent>
        </Popover>
      </div>
    </div>
  )
}

// ─── Main page ────────────────────────────────────────────────────────────────

export default function ComparativoPage() {
  const { user } = useAuth()
  const queryClient = useQueryClient()
  const supabase = createClient()

  const { hasAccess, limits, isLoading: gateLoading } = usePlanGate("avanzado")

  // Default: Período A = mes actual, Período B = mes anterior
  const today    = new Date()
  const minDate  = subDays(today, limits?.historyDays ?? 30)

  const [aFrom, setAFrom] = useState<Date>(startOfMonth(today))
  const [aTo,   setATo]   = useState<Date>(today)
  const [bFrom, setBFrom] = useState<Date>(startOfMonth(subMonths(today, 1)))
  const [bTo,   setBTo]   = useState<Date>(endOfMonth(subMonths(today, 1)))

  const aStart = toISO(aFrom)
  const aEnd   = toISO(aTo)
  const bStart = toISO(bFrom)
  const bEnd   = toISO(bTo)

  // Detect overlap: A and B share at least one day
  const periodsOverlap = useMemo(
    () => !isAfter(aFrom, bTo) && !isBefore(aTo, bFrom),
    [aFrom, aTo, bFrom, bTo]
  )

  const { data: comparison, isLoading: dataLoading } = usePeriodComparison(
    hasAccess ? aStart : null,
    hasAccess ? aEnd   : null,
    hasAccess ? bStart : null,
    hasAccess ? bEnd   : null,
  )

  const [isAnalyzing, setIsAnalyzing] = useState(false)

  // Last comparative insight
  const { data: lastInsight } = useQuery<ComparativeInsight | null>({
    queryKey: ["comparativeInsight", user?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("insights")
        .select("id, message, created_at")
        .eq("type", "comparativo")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      return data as ComparativeInsight | null
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
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-comparativo`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            period_a_start: aStart,
            period_a_end:   aEnd,
            period_b_start: bStart,
            period_b_end:   bEnd,
          }),
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

      await queryClient.invalidateQueries({ queryKey: ["comparativeInsight", user?.id] })
      toast.success("Análisis comparativo generado")
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error inesperado"
      toast.error(msg)
    } finally {
      setIsAnalyzing(false)
    }
  }

  if (gateLoading) return null
  if (!hasAccess)  return <PlanGateFallback />

  const c = comparison

  // Chart data for grouped bar chart
  const chartData = [
    {
      metric: "Ventas",
      "Período A": c ? Math.round(c.period_a_revenue)  : 0,
      "Período B": c ? Math.round(c.period_b_revenue)  : 0,
    },
    {
      metric: "Gastos",
      "Período A": c ? Math.round(c.period_a_expenses)  : 0,
      "Período B": c ? Math.round(c.period_b_expenses)  : 0,
    },
    {
      metric: "Compras",
      "Período A": c ? Math.round(c.period_a_purchases) : 0,
      "Período B": c ? Math.round(c.period_b_purchases) : 0,
    },
  ]

  const kpiCards = [
    {
      label:        "Ventas",
      valueA:       c?.period_a_revenue   ?? 0,
      valueB:       c?.period_b_revenue   ?? 0,
      delta:        c?.revenue_delta_pct  ?? null,
      invertColors: false,
      format:       fmtARS,
    },
    {
      label:        "Gastos",
      valueA:       c?.period_a_expenses  ?? 0,
      valueB:       c?.period_b_expenses  ?? 0,
      delta:        c?.expenses_delta_pct ?? null,
      invertColors: true,
      format:       fmtARS,
    },
    {
      label:        "Compras",
      valueA:       c?.period_a_purchases  ?? 0,
      valueB:       c?.period_b_purchases  ?? 0,
      delta:        c?.purchases_delta_pct ?? null,
      invertColors: true,
      format:       fmtARS,
    },
    {
      label:        "Operaciones",
      valueA:       c?.period_a_operations  ?? 0,
      valueB:       c?.period_b_operations  ?? 0,
      delta:        c?.operations_delta_pct ?? null,
      invertColors: false,
      format:       (n: number) => n.toString(),
    },
  ]

  return (
    <div className="flex flex-col gap-6">
      {/* ── Header ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Reporte Comparativo</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Comparación de métricas entre dos períodos
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

      {/* ── Period selectors ── */}
      <Card>
        <CardContent className="p-4">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:gap-8">
            <DateRangePicker
              label="Período A"
              from={aFrom}
              to={aTo}
              onFromChange={setAFrom}
              onToChange={setATo}
              minDate={minDate}
            />
            <div className="hidden sm:flex items-center text-muted-foreground">
              <span className="text-sm">vs</span>
            </div>
            <DateRangePicker
              label="Período B"
              from={bFrom}
              to={bTo}
              onFromChange={setBFrom}
              onToChange={setBTo}
              minDate={minDate}
            />
          </div>
        </CardContent>
      </Card>

      {/* ── Overlap warning ── */}
      {periodsOverlap && (
        <div className="flex items-center gap-2 rounded-lg border border-yellow-500/30 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-600 dark:text-yellow-400">
          <AlertTriangle className="h-4 w-4 shrink-0" />
          Los períodos seleccionados se superponen. Los datos son correctos pero la comparación puede ser menos útil.
        </div>
      )}

      {/* ── AI Insight panel ── */}
      {lastInsight ? (
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
      ) : (
        <Card className="border-dashed">
          <CardContent className="p-4 flex items-center gap-3 text-muted-foreground">
            <Sparkles className="h-4 w-4 shrink-0" />
            <p className="text-sm">Usá el análisis IA para obtener observaciones sobre la evolución de tu negocio.</p>
          </CardContent>
        </Card>
      )}

      {/* ── KPI cards ── */}
      <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
        {kpiCards.map(({ label, valueA, valueB, delta, invertColors, format }) => (
          <Card key={label}>
            <CardHeader className="pb-1">
              <CardTitle className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                {label}
              </CardTitle>
            </CardHeader>
            <CardContent className="pt-0 pb-4 flex flex-col gap-2">
              {dataLoading ? (
                <div className="h-8 bg-muted animate-pulse rounded" />
              ) : (
                <>
                  <div className="flex items-baseline gap-1">
                    <span className="text-xs text-muted-foreground">A</span>
                    <span className="text-sm font-semibold tabular-nums">{format(valueA)}</span>
                  </div>
                  <div className="flex items-center gap-2">
                    <div className="flex items-baseline gap-1">
                      <span className="text-xs text-muted-foreground">B</span>
                      <span className="text-sm font-semibold tabular-nums">{format(valueB)}</span>
                    </div>
                    <DeltaBadge value={delta} invertColors={invertColors} />
                  </div>
                </>
              )}
            </CardContent>
          </Card>
        ))}
      </div>

      {/* ── Grouped bar chart ── */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Comparación Visual</CardTitle>
        </CardHeader>
        <CardContent>
          {dataLoading ? (
            <div className="h-64 flex items-center justify-center text-muted-foreground text-sm">
              Cargando...
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={chartData} margin={{ left: 8, right: 8, top: 8 }}>
                <XAxis dataKey="metric" tick={{ fontSize: 12 }} />
                <YAxis
                  tickFormatter={(v) => `$${Math.round(v / 1000)}K`}
                  tick={{ fontSize: 11 }}
                  width={52}
                />
                <Tooltip
                  formatter={(v: number, name: string) => [fmtARS(v), name]}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Bar dataKey="Período A" fill="hsl(var(--primary))"     fillOpacity={0.7} radius={[4, 4, 0, 0]} />
                <Bar dataKey="Período B" fill="hsl(var(--primary))"     fillOpacity={1.0} radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
