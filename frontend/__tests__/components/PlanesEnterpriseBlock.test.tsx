/**
 * Tests de `/planes` con el bloque de contacto del tier Empresa — change
 * `plan-empresa-contacto`, design.md D3/D5.
 *
 * El bloque se monta como HERMANO de `PlanComparison` (después de él), nunca
 * dentro: el comparativo de 4 planes comprables no se toca. Sin
 * `ALIADATA_WHATSAPP_PHONE` configurada, el bloque no se renderiza y la
 * pantalla queda exactamente como estaba (D6).
 *
 * Mismo patrón de mock de `@/lib/supabase/server` que `FacturacionPage.test.tsx`.
 * `PlanComparison` NO se mockea: queremos verificar que sigue renderizando
 * sus 4 tarjetas con normalidad (task 6.3c) — solo se mockean sus
 * dependencias de red (`next/navigation`, `sonner`, `subscriptions-client`).
 *
 * Ciclo: RED (el bloque no existe) → GREEN → TRIANGULATE.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, cleanup, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("next/navigation", () => ({
  redirect: vi.fn(),
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}))

const createSubscriptionMock = vi.fn()
vi.mock("@/lib/api/subscriptions-client", () => ({
  createSubscription: (...args: unknown[]) => createSubscriptionMock(...args),
}))

const ACCOUNT_ROW = {
  billing_plan: "avanzado",
  billing_status: "active",
  trial_plan: null,
  trial_expires_at: null,
  billing_exempt: false,
}

const PLAN_LIMITS_ROWS = [
  { plan: "gratis", price_monthly: 0, max_users: 1, max_products: 100, max_clients: 50, max_suppliers: 20, max_operations_per_month: 100, history_days: 30, max_exports_per_month: 0, max_ai_queries_per_month: 5, max_ai_advice_per_month: 3, max_branches: 1, has_product_profitability: false, has_comparative_reports: false, has_price_suggestion: false, has_branches_module: false, has_monthly_analysis: false, internal_roles: "none" },
  { plan: "inicial", price_monthly: 24900, max_users: 2, max_products: 500, max_clients: 250, max_suppliers: 100, max_operations_per_month: 500, history_days: 365, max_exports_per_month: 3, max_ai_queries_per_month: 30, max_ai_advice_per_month: 15, max_branches: 1, has_product_profitability: false, has_comparative_reports: false, has_price_suggestion: false, has_branches_module: false, has_monthly_analysis: false, internal_roles: "none" },
  { plan: "avanzado", price_monthly: 34900, max_users: 5, max_products: 1500, max_clients: 1000, max_suppliers: 300, max_operations_per_month: 2000, history_days: 730, max_exports_per_month: 15, max_ai_queries_per_month: 120, max_ai_advice_per_month: 60, max_branches: 1, has_product_profitability: true, has_comparative_reports: true, has_price_suggestion: true, has_branches_module: false, has_monthly_analysis: false, internal_roles: "basic" },
  { plan: "pro", price_monthly: 69900, max_users: 10, max_products: 5000, max_clients: 5000, max_suppliers: 1000, max_operations_per_month: 6000, history_days: 1825, max_exports_per_month: 50, max_ai_queries_per_month: 300, max_ai_advice_per_month: 150, max_branches: 3, has_product_profitability: true, has_comparative_reports: true, has_price_suggestion: true, has_branches_module: true, has_monthly_analysis: true, internal_roles: "advanced" },
]

function makeQueryBuilder(table: string) {
  if (table === "account_members") {
    const resolved = { data: { account_id: "acc-1", accounts: ACCOUNT_ROW }, error: null }
    return {
      select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve(resolved) }) }),
    }
  }
  if (table === "plan_limits") {
    const resolved = { data: PLAN_LIMITS_ROWS, error: null }
    return {
      select: () => ({ order: () => Promise.resolve(resolved) }),
    }
  }
  throw new Error(`Unexpected table in test mock: ${table}`)
}

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => ({
    auth: { getUser: async () => ({ data: { user: { id: "user-1" } }, error: null }) },
    from: (table: string) => makeQueryBuilder(table),
  }),
}))

import PlanesPage from "@/app/(dashboard)/planes/page"
import { ENTERPRISE_TIER } from "@/lib/enterprise-tier"

const ORIGINAL_PHONE = process.env.ALIADATA_WHATSAPP_PHONE

beforeEach(() => {
  vi.clearAllMocks()
  global.fetch = vi.fn()
})

afterEach(() => {
  cleanup()
  if (ORIGINAL_PHONE === undefined) delete process.env.ALIADATA_WHATSAPP_PHONE
  else process.env.ALIADATA_WHATSAPP_PHONE = ORIGINAL_PHONE
})

describe("/planes — bloque de contacto Empresa", () => {
  // ── RED/GREEN: con la env var configurada, comparativo + bloque Empresa ────
  it("shows the 4-plan comparison and the Empresa block below it", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 2617 63-5174"

    render(await PlanesPage())

    // Comparativo intacto (4 tarjetas, "Plan actual" en Avanzado).
    expect(screen.getAllByText("Plan actual").length).toBeGreaterThan(0)

    // Bloque Empresa presente y con el CTA apuntando a wa.me.
    const block = screen.getByTestId("planes-enterprise-block")
    const link = within(block).getByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })
    expect(link.getAttribute("href")).toContain("https://wa.me/5492617635174")
  })

  // ── TRIANGULATE: sin la env var, solo el comparativo (D6) ──────────────────
  it("shows only the comparison when the phone variable is not configured", async () => {
    delete process.env.ALIADATA_WHATSAPP_PHONE

    render(await PlanesPage())

    expect(screen.getAllByText("Plan actual").length).toBeGreaterThan(0)
    expect(screen.queryByTestId("planes-enterprise-block")).toBeNull()
  })

  // ── TRIANGULATE (a): el CTA del bloque no dispara pagos ────────────────────
  it("clicking the Empresa CTA never calls fetch or createSubscription", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 2617 63-5174"

    render(await PlanesPage())

    const block = screen.getByTestId("planes-enterprise-block")
    const link = within(block).getByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })
    fireEvent.click(link)

    expect(createSubscriptionMock).not.toHaveBeenCalled()
    expect(global.fetch).not.toHaveBeenCalled()
  })

  // ── TRIANGULATE (b): el bloque nunca ofrece "plan actual" ni acciones de compra
  it("the Empresa block never shows 'plan actual' or contract/upgrade/downgrade actions", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 2617 63-5174"

    render(await PlanesPage())

    const block = screen.getByTestId("planes-enterprise-block")
    expect(within(block).queryByText(/plan actual/i)).toBeNull()
    expect(within(block).queryByText(/pasarme a|cancelar y bajar|seleccionar/i)).toBeNull()
  })

  // ── TRIANGULATE (c): PlanComparison sigue con sus 4 tarjetas y currentPlan ──
  it("PlanComparison still renders the 4 plan cards with the current plan highlighted", async () => {
    process.env.ALIADATA_WHATSAPP_PHONE = "+54 9 2617 63-5174"

    render(await PlanesPage())

    for (const name of ["Gratis", "Inicial", "Avanzado", "Pro"]) {
      expect(screen.getByRole("heading", { name })).toBeInTheDocument()
    }
    expect(screen.getAllByText("Plan actual").length).toBeGreaterThan(0)
  })
})
