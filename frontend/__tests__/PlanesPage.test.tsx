/**
 * planes-suscribirse-plan-vigente (grupo 5, D1/D2/D5) — `/planes` lee,
 * además del plan efectivo, si la cuenta tiene una suscripción viva
 * (vía el helper canónico `lib/billing/live-subscription.ts`, mismo patrón
 * que `/facturacion`) y el motivo de acceso (D5, derivado de campos crudos).
 *
 * Mismo patrón de mock de `@/lib/supabase/server` que `FacturacionPage.test.tsx`
 * y `PlanesEnterpriseBlock.test.tsx`.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, cleanup } from "@testing-library/react"
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

const BASE_ACCOUNT_ROW = {
  billing_plan: "avanzado",
  billing_status: "active",
  trial_plan: null as string | null,
  trial_expires_at: null as string | null,
  plan_expires_at: null as string | null,
  billing_exempt: false,
}

const PLAN_LIMITS_ROWS = [
  { plan: "gratis", price_monthly: 0, max_users: 1, max_products: 100, max_clients: 50, max_suppliers: 20, max_operations_per_month: 100, history_days: 30, max_exports_per_month: 0, max_ai_queries_per_month: 5, max_ai_advice_per_month: 3, max_branches: 1, has_product_profitability: false, has_comparative_reports: false, has_price_suggestion: false, has_branches_module: false, has_monthly_analysis: false, internal_roles: "none" },
  { plan: "inicial", price_monthly: 24900, max_users: 2, max_products: 500, max_clients: 250, max_suppliers: 100, max_operations_per_month: 500, history_days: 365, max_exports_per_month: 3, max_ai_queries_per_month: 30, max_ai_advice_per_month: 15, max_branches: 1, has_product_profitability: false, has_comparative_reports: false, has_price_suggestion: false, has_branches_module: false, has_monthly_analysis: false, internal_roles: "none" },
  { plan: "avanzado", price_monthly: 34900, max_users: 5, max_products: 1500, max_clients: 1000, max_suppliers: 300, max_operations_per_month: 2000, history_days: 730, max_exports_per_month: 15, max_ai_queries_per_month: 120, max_ai_advice_per_month: 60, max_branches: 1, has_product_profitability: true, has_comparative_reports: true, has_price_suggestion: true, has_branches_module: false, has_monthly_analysis: false, internal_roles: "basic" },
  { plan: "pro", price_monthly: 69900, max_users: 10, max_products: 5000, max_clients: 5000, max_suppliers: 1000, max_operations_per_month: 6000, history_days: 1825, max_exports_per_month: 50, max_ai_queries_per_month: 300, max_ai_advice_per_month: 150, max_branches: 3, has_product_profitability: true, has_comparative_reports: true, has_price_suggestion: true, has_branches_module: true, has_monthly_analysis: true, internal_roles: "advanced" },
]

let accountRow: typeof BASE_ACCOUNT_ROW = BASE_ACCOUNT_ROW
let subscriptionsResult: { data: unknown; error: unknown } = { data: null, error: null }

function makeQueryBuilder(table: string) {
  if (table === "account_members") {
    const resolved = { data: { account_id: "acc-1", accounts: accountRow }, error: null }
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
  if (table === "subscriptions") {
    const builder = {
      select: () => builder,
      eq: () => builder,
      in: () => builder,
      maybeSingle: () => Promise.resolve(subscriptionsResult),
    }
    return builder
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

beforeEach(() => {
  vi.clearAllMocks()
  global.fetch = vi.fn()
  accountRow = { ...BASE_ACCOUNT_ROW }
  subscriptionsResult = { data: null, error: null }
})

afterEach(() => {
  cleanup()
})

describe("/planes — liveness de suscripción y degradación (5.1/5.3)", () => {
  it("sin fila de suscripción: el tier vigente (avanzado) ofrece CTA de contratación", async () => {
    subscriptionsResult = { data: null, error: null }

    render(await PlanesPage())

    expect(screen.getByRole("button", { name: /suscribirme a avanzado/i })).toBeEnabled()
  })

  it("la lectura de suscripciones falla (error de Postgrest): degrada a 'sin suscripción viva', el comparativo se renderiza igual", async () => {
    subscriptionsResult = { data: null, error: { message: "boom" } }

    render(await PlanesPage())

    expect(screen.getByRole("button", { name: /suscribirme a avanzado/i })).toBeEnabled()
    for (const name of ["Gratis", "Inicial", "Avanzado", "Pro"]) {
      expect(screen.getByRole("heading", { name })).toBeInTheDocument()
    }
  })

  it("con suscripción viva del tier vigente: sin CTA de compra, aviso de suscripción activa (OQ-5)", async () => {
    subscriptionsResult = {
      data: {
        plan: "avanzado",
        status: "authorized",
        next_payment_date: "2026-09-15T12:00:00Z",
        retry_state: "none",
        amount: null,
        currency: "ARS",
      },
      error: null,
    }

    render(await PlanesPage())

    expect(screen.queryByRole("button", { name: /suscribirme|pasarme/i })).not.toBeInTheDocument()
    expect(screen.getByText(/ya tenés una suscripción activa/i)).toBeInTheDocument()
  })
})

describe("/planes — cuenta exenta (grupo 6, cableado desde la página)", () => {
  it("billing_exempt=true: muestra el aviso de cortesía y ningún CTA de compra", async () => {
    accountRow = { ...BASE_ACCOUNT_ROW, billing_exempt: true }

    render(await PlanesPage())

    expect(screen.getByTestId("billing-exempt-notice")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /suscribirme|pasarme/i })).not.toBeInTheDocument()
  })
})

describe("/planes — línea de contexto D5 (cableado desde la página)", () => {
  it("plan pago con vencimiento futuro (caso danielsevilla64): muestra la línea en la tarjeta del plan vigente", async () => {
    accountRow = {
      ...BASE_ACCOUNT_ROW,
      billing_plan: "pro",
      plan_expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
    }

    render(await PlanesPage())

    expect(screen.getByText(/vence el/i)).toBeInTheDocument()
  })

  it("trial vigente: muestra la línea del período de prueba en la tarjeta del plan vigente (task 6.3)", async () => {
    accountRow = {
      ...BASE_ACCOUNT_ROW,
      billing_plan: "gratis",
      trial_plan: "pro",
      trial_expires_at: new Date(Date.now() + 10 * 24 * 60 * 60 * 1000).toISOString(),
    }

    render(await PlanesPage())

    expect(screen.getByText(/período de prueba vence el/i)).toBeInTheDocument()
  })

  it("sin motivo aplicable (plan pago sin vencimiento próximo): no se renderiza ninguna línea de contexto (task 6.3)", async () => {
    accountRow = { ...BASE_ACCOUNT_ROW, billing_plan: "avanzado", plan_expires_at: null }

    render(await PlanesPage())

    expect(screen.queryByText(/vence el/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/sin cargo/i)).not.toBeInTheDocument()
  })
})
