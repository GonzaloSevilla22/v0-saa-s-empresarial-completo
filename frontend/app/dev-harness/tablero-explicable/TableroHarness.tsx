"use client"

/**
 * tablero-explicable (tasks 5.1/5.2) — arnés de la pasada visual del Tablero.
 *
 * Monta los componentes REALES del Tablero sin sesión ni backend:
 *   - `SalesChart` (rango 7/30/90/personalizado + comparación),
 *   - las tarjetas KPI reales (`KpiSummaryCard` / `KpiCard`) con su
 *     `explanation` — la grilla replica la de `/dashboard`,
 *   - `NotificationBell` (el panel real, con los hooks reales),
 *   - `AiSummaryCard` (la tarjeta real).
 *
 * Sin sesión los hooks quedan sin cuenta activa (`enabled: false`) y leen sólo
 * lo que hay en la caché de react-query: el arnés la siembra con las MISMAS
 * claves que usan los hooks sin usuario (`accountId = null`), igual que el
 * arnés de cupo de OCR. Las mutaciones (descartar / marcar todas) sí corren:
 * su actualización optimista opera sobre esa caché y el `UPDATE` a PostgREST
 * se intercepta. `window.fetch` hacia Supabase y el backend se intercepta
 * (patrón de EdicionDineroHarness): sin eso, en CI el backend responde 401 y
 * el transporte navega a /auth/login.
 *
 * Parámetros:
 *   ?theme=light|dark       clase `dark` en <html>, igual que next-themes.
 *   ?clamped=1              la comparación cae fuera del historial del plan.
 *   ?ai=loading|ok|429      estado del Resumen IA (default `ok`).
 */

import { useEffect, useState } from "react"
import { useQueryClient, type QueryClient } from "@tanstack/react-query"
import { AlertTriangle, DollarSign, HandCoins, PackageX, Receipt, Share2, Tag, TrendingDown, TrendingUp } from "lucide-react"
import { SalesChart } from "@/components/dashboard/sales-chart"
import { AiSummaryCard } from "@/components/dashboard/ai-summary-card"
import { NotificationBell } from "@/components/dashboard/NotificationBell"
import { KpiSummaryCard } from "@/components/dashboard/KpiSummaryCard"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { queryKeys } from "@/lib/query-keys"
import { argentinaToday } from "@/lib/date-range"
import {
  chartBucketFor,
  chartPresetRange,
  type EvolutionBucket,
  type SalesEvolution,
} from "@/lib/sales-statistics"
import type { KpiExplanationProp } from "@/components/dashboard/KpiExplainTrigger"
import type { DashboardKpiId } from "@/lib/dashboard-kpi-explanations"
import type { Notification, NotificationType, PlanLimits } from "@/lib/types"

type AiState = "loading" | "ok" | "429"

const STOCK_PRODUCT = "5f1c2b3e-8a4d-4c6e-9b7a-0123456789ab"
const BRANCH = "9a8b7c6d-1e2f-4a3b-8c5d-abcdef012345"

// ── Fixtures del gráfico ────────────────────────────────────────────────────

function addDays(iso: string, days: number): string {
  const [y, m, d] = iso.split("-").map(Number)
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10)
}

function bucketPoints(start: string, end: string, bucket: EvolutionBucket): string[] {
  const step = bucket === "day" ? 1 : bucket === "week" ? 7 : 30
  const keys: string[] = []
  for (let k = start; k <= end; k = addDays(k, step)) keys.push(k)
  return keys
}

function metrics(net: number, operations: number) {
  return { revenue: net, creditNotes: 0, netRevenue: net, units: operations, operations, serviceRevenue: 0 }
}

function evolutionFor(opts: {
  start: string
  end: string
  bucket: EvolutionBucket
  seed: number
  prev: { start: string; end: string; total: number }
  clamped?: boolean
}): SalesEvolution {
  const keys = bucketPoints(opts.start, opts.end, opts.bucket)
  const scale = opts.bucket === "day" ? 1 : opts.bucket === "week" ? 7 : 30
  const points = keys.map((k, i) => ({
    bucketStart: k,
    bucketEnd: k,
    ...metrics(Math.round((38_000 + ((i * 7919 + opts.seed) % 29_000)) * scale), 6 * scale),
  }))
  const total = points.reduce((a, p) => a + p.netRevenue, 0)
  return {
    bucket: opts.bucket,
    window: { start: opts.start, end: opts.end, historyDays: 365, clamped: opts.clamped ?? false },
    points,
    current: { start: opts.start, end: opts.end, ...metrics(total, points.length * 6 * scale) },
    previous: { start: opts.prev.start, end: opts.prev.end, ...metrics(opts.prev.total, 40) },
  }
}

function limits(): PlanLimits {
  return {
    plan: "gratis",
    priceMonthly: 0,
    maxUsers: 1,
    maxProducts: 100,
    maxClients: 50,
    maxSuppliers: 20,
    maxOperationsPerMonth: 100,
    historyDays: 365,
    maxExportsPerMonth: 0,
    maxAiQueriesPerMonth: 5,
    maxAiAdvicePerMonth: 3,
    maxAiOcrPerMonth: 5,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none",
  }
}

function seedChart(queryClient: QueryClient, clamped: boolean) {
  for (const preset of ["7d", "30d", "90d"] as const) {
    const { start, end } = chartPresetRange(preset)
    const bucket = chartBucketFor(start, end)
    const days = preset === "7d" ? 7 : preset === "30d" ? 30 : 90
    const prev = { start: addDays(start, -days), end: addDays(start, -1) }
    const current = evolutionFor({ start, end, bucket, seed: days, prev: { ...prev, total: 0 } })
    // Total del período anterior ~ 12 % por debajo del actual → variación visible.
    const prevTotal = Math.round(current.current.netRevenue * 0.88)
    current.previous = { ...current.previous, netRevenue: prevTotal, revenue: prevTotal }
    queryClient.setQueryData(queryKeys.salesStatistics.evolution(null, start, end, bucket, null, null), current)
    queryClient.setQueryData(
      queryKeys.salesStatistics.evolution(null, prev.start, prev.end, bucket, null, null),
      evolutionFor({
        start: prev.start,
        end: prev.end,
        bucket,
        seed: days + 11_000,
        prev: { start: addDays(prev.start, -days), end: addDays(prev.start, -1), total: 0 },
        // `?clamped=1` sólo afecta a la comparación de 30 días (la de 7 queda sana).
        clamped: clamped && preset === "30d",
      }),
    )
  }
}

// ── Fixtures de la campana ──────────────────────────────────────────────────

const TYPES: NotificationType[] = ["StockBelowMinimum", "CashSessionClosed", "QuoteAccepted", "PayablesOverdueDigest"]

function makeNotifications(count: number): Notification[] {
  return Array.from({ length: count }, (_, i) => {
    const type = TYPES[i % TYPES.length]
    return {
      id: `notif-${i + 1}`,
      accountId: "acc-harness",
      branchId: null,
      type,
      severity: type === "StockBelowMinimum" ? "warning" : type === "CashSessionClosed" ? "urgent" : "info",
      payload:
        type === "StockBelowMinimum"
          ? { product_id: STOCK_PRODUCT, branch_id: BRANCH, current_qty: 2, min_qty: 5 }
          : type === "CashSessionClosed"
            ? { session_id: STOCK_PRODUCT, branch_id: BRANCH, difference: -150 }
            : {},
      read: false,
      createdAt: new Date(Date.now() - i * 17 * 60_000).toISOString(),
      readAt: null,
    } as Notification
  })
}

// ── Fetch simulado ──────────────────────────────────────────────────────────

/** Backend y PostgREST simulados: el arnés no tiene sesión ni servidor real. */
function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    const supabase = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "http://localhost:54321"
    if (url.startsWith(supabase)) {
      // UPDATE de «marcar leída»: PostgREST responde 204 sin cuerpo.
      return new Response(null, { status: 204 })
    }
    if (!(url.startsWith(backend) || url.startsWith("/api/"))) return original(input, init)
    return new Response(JSON.stringify([]), { status: 200, headers: { "Content-Type": "application/json" } })
  }
  return () => {
    window.fetch = original
  }
}

// ── Tarjetas ────────────────────────────────────────────────────────────────

export function TableroHarness() {
  const queryClient = useQueryClient()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
    const params = new URLSearchParams(window.location.search)
    document.documentElement.classList.toggle("dark", params.get("theme") === "dark")
    const ai = (params.get("ai") as AiState | null) ?? "ok"

    queryClient.setQueryData(["planLimits", "gratis"], limits())
    seedChart(queryClient, params.get("clamped") === "1")

    const notifications = makeNotifications(15)
    queryClient.setQueryData(queryKeys.notifications.all(), { items: notifications, total: 270 })

    const aiKey = queryKeys.aiSummary.daily(null, argentinaToday())
    if (ai === "ok") {
      queryClient.setQueryData(
        aiKey,
        "Hoy vendiste $184.200 en 27 operaciones, un 12 % más que el mismo día de la semana pasada. Tenés 3 productos en alerta de stock: conviene reponerlos antes del fin de semana.",
      )
    } else if (ai === "429") {
      queryClient
        .getQueryCache()
        .build(queryClient, { queryKey: aiKey })
        .setState({
          status: "error",
          fetchStatus: "idle",
          data: undefined,
          error: { name: "FunctionsHttpError", context: { status: 429 } } as unknown as Error,
          errorUpdateCount: 1,
        })
    }
    // `loading`: la consulta queda sin datos y deshabilitada (sin cuenta) → estado de carga.

    setReady(true)
    return uninstall
  }, [queryClient])

  const periodDate = new Date()
  const explain = (id: DashboardKpiId): KpiExplanationProp => ({
    id,
    context: { periodDate, branchName: "Centro" },
  })

  if (!ready) return null

  return (
    <main className="min-h-svh bg-background p-4 md:p-6 flex flex-col gap-6">
      <div className="flex items-center justify-between gap-2">
        <h1 className="text-lg font-semibold text-foreground">Arnés — Tablero explicable</h1>
        <div data-testid="campana">
          <NotificationBell />
        </div>
      </div>

      <section data-testid="kpi-block" className="grid gap-3 grid-cols-2 md:grid-cols-3 xl:grid-cols-5">
        <KpiSummaryCard label="Ganancia Neta" value="$184.200" badge="▲ +12%" tone="green" icon={TrendingUp} iconColor="text-success" secondaryLine="Cobrado: $152.000" explanation={explain("net_profit")} />
        <KpiSummaryCard label="Margen por Canal" value="IG 34% / ML 18%" badge="IG lidera" tone="yellow" icon={Share2} iconColor="text-violet-400" explanation={explain("channel_margin")} />
        <KpiSummaryCard label="Stock sin Rotación" value="$41.600" badge="23 productos" tone="red" icon={PackageX} iconColor="text-warning" secondaryLine="5 sin costo" explanation={explain("stagnant_stock")} />
        <KpiSummaryCard label="Costo por Venta" value="$1.240" badge="▲ +8%" tone="red" icon={Receipt} iconColor="text-destructive" explanation={explain("cost_per_sale")} />
        <KpiSummaryCard label="Ticket Promedio" value="$6.820" badge="▲ +5%" tone="yellow" icon={Tag} iconColor="text-sky-400" className="col-span-2 md:col-span-1 xl:col-span-1" explanation={explain("avg_ticket")} />
      </section>

      <section data-testid="month-row" className="grid gap-4 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
        <KpiCard title="Ventas del mes" value="$812.400" icon={DollarSign} explanation={explain("month_sales")} />
        <KpiCard title="Gastos del mes" value="$215.000" icon={TrendingDown} iconColor="text-destructive" explanation={explain("month_expenses")} />
        <KpiCard title="Ganancia neta del mes" value="$184.200" icon={TrendingUp} explanation={explain("month_net_profit")} />
        <KpiCard title="Productos en alerta" value="3" icon={AlertTriangle} iconColor="text-warning" explanation={explain("critical_stock")} />
        <KpiCard title="Por cobrar" value="$567.000" icon={HandCoins} iconColor="text-warning" href="/cobranzas" />
      </section>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-7">
        <div data-testid="chart" className="lg:col-span-4 min-w-0">
          <SalesChart />
        </div>
        <div data-testid="ai" className="lg:col-span-3 min-w-0">
          <AiSummaryCard todaySales={184200} />
        </div>
      </div>
    </main>
  )
}
