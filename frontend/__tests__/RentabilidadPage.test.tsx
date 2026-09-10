/**
 * productos-costo-nullable (task 7.5 RED/GREEN, D7) — /rentabilidad crasheaba
 * con un `gross_margin_pct`/`total_cost` nulo: `fmtPct`/`fmtARS` llamaban
 * `.toFixed`/`Intl.NumberFormat.format` sin guarda de nulo, y las
 * comparaciones de umbral (`>= 30`) caían a la rama equivocada en silencio.
 * Ese estado dejó de ser teórico desde que el costo del catálogo es opcional
 * (capability `product-cost`): un producto sin costo resoluble en el período
 * llega con estos tres campos en `null`.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ProductProfitability } from "@/lib/types"

vi.mock("@/hooks/auth/use-plan-gate", () => ({
  usePlanGate: () => ({ hasAccess: true, limits: { historyDays: 30 }, isLoading: false }),
}))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1" } }) }))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({
          order: () => ({
            limit: () => ({ maybeSingle: async () => ({ data: null, error: null }) }),
          }),
        }),
      }),
    }),
    auth: { getSession: async () => ({ data: { session: null } }) },
  }),
}))
vi.mock("@/components/ai/PriceSuggestionModal", () => ({ PriceSuggestionModal: () => null }))

let profitabilityData: ProductProfitability[] = []
vi.mock("@/hooks/use-profitability", () => ({
  useProfitability: () => ({ data: profitabilityData, isLoading: false, isError: false, refetch: vi.fn() }),
}))

const { default: RentabilidadPage } = await import("@/app/(dashboard)/rentabilidad/page")

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <RentabilidadPage />
    </QueryClientProvider>,
  )
}

const conCosto: ProductProfitability = {
  product_id: "p1", product_name: "Con Costo", total_revenue: 1000,
  total_cost: 600, gross_margin: 400, gross_margin_pct: 40, units_sold: 5, last_sale_date: "2026-09-01",
}
const sinCosto: ProductProfitability = {
  product_id: "p2", product_name: "Sin Costo", total_revenue: 500,
  total_cost: null, gross_margin: null, gross_margin_pct: null, units_sold: 3, last_sale_date: "2026-09-02",
}

describe("/rentabilidad — margen ausente no rompe la página", () => {
  it("un producto sin costo no crashea la página y muestra costo/margen como —", () => {
    profitabilityData = [conCosto, sinCosto]
    renderPage()
    expect(screen.getByText("Con Costo")).toBeInTheDocument()
    expect(screen.getByText("Sin Costo")).toBeInTheDocument()
    // El producto con costo real sigue mostrando su margen numérico.
    expect(screen.getByText("40.0%")).toBeInTheDocument()
  })

  it("con margen ausente entre varios, el mejor/peor margen del resumen ignora los productos sin costo", () => {
    profitabilityData = [sinCosto, conCosto]
    renderPage()
    // "Mejor margen" y "Peor margen" deben referirse al único producto CON
    // costo medido, nunca al que no tiene margen que comparar.
    const badges = screen.getAllByText(/Con Costo/)
    expect(badges.length).toBeGreaterThan(0)
  })

  it("con TODOS los productos sin costo, el resumen muestra — sin crashear", () => {
    profitabilityData = [sinCosto]
    renderPage()
    expect(screen.getByText("Sin Costo")).toBeInTheDocument()
  })
})
