/**
 * qa-integral-modulos G3 (H3) — /reportes/comparativo mostraba las 4
 * variaciones al revés y con el color invertido: los defaults de la página
 * (A = mes en curso, B = mes anterior) violaban el contrato (B−A)/A de
 * rpc_period_comparison, donde A es la BASE.
 *
 * El mock de usePeriodComparison IMPLEMENTA el contrato de la RPC sobre datos
 * sintéticos por mes: calcula (B−A)/A con los períodos que la página le pasa.
 * Así el test discrimina el signo de verdad — con los defaults viejos, los
 * gastos que SUBEN 30% se mostraban como "-23,1%" en verde (el bug exacto del
 * informe). Hoy no existía NINGÚN test de la página ni de la RPC.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { format, startOfMonth, endOfMonth, subMonths } from "date-fns"

// ─── Datos sintéticos por mes (la "base de datos" del contrato) ──────────────
// Mes anterior → mes en curso: ventas BAJAN, gastos SUBEN, compras BAJAN,
// operaciones SUBEN. Cubre series que suben y que bajan, con y sin
// invertColors (triangulación 3.4).
const PREV = { revenue: 10000, expenses: 10000, purchases: 8000, operations: 9 }
const CURR = { revenue: 9935, expenses: 13000, purchases: 7600, operations: 17 }

const capturedArgs: { aStart?: string; aEnd?: string; bStart?: string; bEnd?: string } = {}
let forceNullDeltas = false

function metricsFor(startISO: string) {
  const start = new Date(`${startISO}T00:00:00`)
  const now = new Date()
  const isCurrentMonth =
    start.getMonth() === now.getMonth() && start.getFullYear() === now.getFullYear()
  return isCurrentMonth ? CURR : PREV
}

function contractDelta(a: number, b: number): number | null {
  if (forceNullDeltas || a === 0) return null
  return ((b - a) / a) * 100
}

vi.mock("@/hooks/use-period-comparison", () => ({
  usePeriodComparison: (
    aStart: string | null,
    aEnd: string | null,
    bStart: string | null,
    bEnd: string | null,
  ) => {
    if (!aStart || !aEnd || !bStart || !bEnd) return { data: null, isLoading: false, isError: false }
    capturedArgs.aStart = aStart
    capturedArgs.aEnd = aEnd
    capturedArgs.bStart = bStart
    capturedArgs.bEnd = bEnd
    const a = metricsFor(aStart)
    const b = metricsFor(bStart)
    return {
      data: {
        period_a_revenue: a.revenue,
        period_a_expenses: a.expenses,
        period_a_purchases: a.purchases,
        period_a_operations: a.operations,
        period_b_revenue: b.revenue,
        period_b_expenses: b.expenses,
        period_b_purchases: b.purchases,
        period_b_operations: b.operations,
        // Contrato de rpc_period_comparison (20260606120000:104-111): (B−A)/A,
        // con A como base. NO tocar: es la fuente de verdad que el test fija.
        revenue_delta_pct: contractDelta(a.revenue, b.revenue),
        expenses_delta_pct: contractDelta(a.expenses, b.expenses),
        purchases_delta_pct: contractDelta(a.purchases, b.purchases),
        operations_delta_pct: contractDelta(a.operations, b.operations),
      },
      isLoading: false,
      isError: false,
      refetch: vi.fn(),
    }
  },
}))

vi.mock("@/hooks/auth/use-plan-gate", () => ({
  usePlanGate: () => ({ hasAccess: true, limits: { historyDays: 365 }, isLoading: false }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1" } }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), warning: vi.fn() },
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({
          order: () => ({
            limit: () => ({
              maybeSingle: async () => ({ data: null, error: null }),
            }),
          }),
        }),
      }),
    }),
    auth: { getSession: async () => ({ data: { session: null } }) },
  }),
}))

import ComparativoPage from "@/app/(dashboard)/reportes/comparativo/page"

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <ComparativoPage />
    </QueryClientProvider>,
  )
}

const toISO = (d: Date) => format(d, "yyyy-MM-dd")

beforeEach(() => {
  forceNullDeltas = false
  delete capturedArgs.aStart
  delete capturedArgs.aEnd
  delete capturedArgs.bStart
  delete capturedArgs.bEnd
})

describe("ComparativoPage — defaults respetan el contrato (B−A)/A de la RPC (G3/H3)", () => {
  it("pide la RPC con A = mes anterior (base) y B = mes en curso", () => {
    renderPage()
    const today = new Date()
    expect(capturedArgs.aStart).toBe(toISO(startOfMonth(subMonths(today, 1))))
    expect(capturedArgs.aEnd).toBe(toISO(endOfMonth(subMonths(today, 1))))
    expect(capturedArgs.bStart).toBe(toISO(startOfMonth(today)))
    expect(capturedArgs.bEnd).toBe(toISO(today))
  })

  it("gastos que SUBEN muestran signo positivo en rojo (el caso del informe: +30% real, no -23% verde)", () => {
    renderPage()
    const badge = screen.getByTestId("delta-badge-Gastos")
    expect(badge).toHaveTextContent("+30.0%")
    expect(badge.className).toContain("text-destructive")
    expect(badge.className).not.toContain("text-green-500")
  })

  it("ventas que BAJAN muestran signo negativo en rojo", () => {
    renderPage()
    const badge = screen.getByTestId("delta-badge-Ventas")
    expect(badge).toHaveTextContent("-0.7%")
    expect(badge.className).toContain("text-destructive")
  })

  it("compras que BAJAN muestran signo negativo en verde (invertColors: bajar es bueno, la doble inversión no se cancela)", () => {
    renderPage()
    const badge = screen.getByTestId("delta-badge-Compras")
    expect(badge).toHaveTextContent("-5.0%")
    expect(badge.className).toContain("text-green-500")
    expect(badge.className).not.toContain("text-destructive")
  })

  it("operaciones que SUBEN muestran signo positivo en verde", () => {
    renderPage()
    const badge = screen.getByTestId("delta-badge-Operaciones")
    expect(badge).toHaveTextContent("+88.9%")
    expect(badge.className).toContain("text-green-500")
  })

  it("delta NULL degrada a N/A en las 4 tarjetas", () => {
    forceNullDeltas = true
    renderPage()
    for (const label of ["Ventas", "Gastos", "Compras", "Operaciones"]) {
      expect(screen.getByTestId(`delta-badge-${label}`)).toHaveTextContent("N/A")
    }
  })

  it("rotula qué mide el badge: evolución del período A (base) al período B (3.3)", () => {
    renderPage()
    expect(
      screen.getByText(/evolución del período A \(base\) al período B/i),
    ).toBeInTheDocument()
    expect(screen.getByTestId("delta-badge-Gastos")).toHaveAttribute(
      "title",
      "Evolución de Gastos del período A al período B",
    )
  })
})
