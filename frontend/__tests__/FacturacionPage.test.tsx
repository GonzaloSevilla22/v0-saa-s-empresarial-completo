/**
 * mp-real-subscriptions (D2bis, task 8.5/8.6) — /facturacion muestra el
 * estado REAL de la suscripción (RLS SELECT directo sobre
 * public.subscriptions, sin llamar al backend) cuando existe, y degrada
 * limpio (sin la sección) cuando no hay ninguna fila — palanca OFF.
 *
 * Mismo patrón de mock de @/lib/supabase/server que billing.test.ts.
 * Import estático de la página (no dinámico dentro de cada `it`) — el
 * árbol de FacturacionPage arrastra bastantes dependencias (BillingHistory,
 * CancelSubscriptionModal, date-fns, Radix) y el costo de transform/compile
 * de un import() dinámico DENTRO del test cuenta contra el timeout de ESE
 * test; importado arriba, ese costo cae en la fase de colección del
 * archivo, que tiene más margen.
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

// CancelSubscriptionModal (renderizado como hijo cuando canCancel=true) hace
// su propio fetch de estado — se mockea acá para que este test de la página
// no dependa de su comportamiento interno (ya cubierto en
// CancelSubscriptionModal.test.tsx).
vi.mock("@/lib/api/subscriptions-client", () => ({
  getSubscriptionStatus: async () => ({ enabled: false }),
  cancelSubscription: async () => ({ enabled: false }),
}))

const ACCOUNT_ROW = {
  billing_plan: "avanzado",
  billing_status: "active",
  trial_plan: null,
  trial_expires_at: null,
  plan_expires_at: null,
  created_at: "2026-01-01T00:00:00Z",
  billing_exempt: false,
}

let subscriptionData: Record<string, unknown> | null = null

function makeQueryBuilder(table: string) {
  const resolved =
    table === "account_members"
      ? { data: { account_id: "acc-1", accounts: ACCOUNT_ROW }, error: null }
      : table === "billing_events"
        ? { data: [], error: null }
        : table === "subscriptions"
          ? { data: subscriptionData, error: null }
          : { data: null, error: null }

  const builder: Record<string, unknown> = {
    select: () => builder,
    eq: () => builder,
    in: () => builder,
    order: () => builder,
    limit: () => Promise.resolve(resolved),
    maybeSingle: () => Promise.resolve(resolved),
  }
  return builder
}

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => ({
    auth: { getUser: async () => ({ data: { user: { id: "user-1" } }, error: null }) },
    from: (table: string) => makeQueryBuilder(table),
  }),
}))

import FacturacionPage from "@/app/(dashboard)/facturacion/page"

beforeEach(() => {
  subscriptionData = null
})

afterEach(() => {
  cleanup()
})

describe("FacturacionPage — estado de la suscripción real (task 8.5/8.6)", () => {
  it("cuenta sin suscripción real: no muestra la sección (degradación limpia, palanca OFF)", async () => {
    subscriptionData = null

    render(await FacturacionPage())

    expect(screen.queryByText("Suscripción recurrente")).not.toBeInTheDocument()
  })

  it("con suscripción autorizada: muestra estado y próximo cobro, sin el aviso de reintento", async () => {
    subscriptionData = {
      plan: "avanzado",
      status: "authorized",
      next_payment_date: "2026-09-15T12:00:00Z",
      retry_state: "none",
      amount: null,
      currency: "ARS",
    }

    render(await FacturacionPage())

    expect(screen.getByText("Suscripción recurrente")).toBeInTheDocument()
    expect(screen.getByText("Autorizada")).toBeInTheDocument()
    expect(screen.getByText(/15 de septiembre de 2026/i)).toBeInTheDocument()
    expect(screen.queryByText(/reintentando automáticamente/i)).not.toBeInTheDocument()
  })

  it("con cobro en reintento: muestra el aviso correspondiente", async () => {
    subscriptionData = {
      plan: "avanzado",
      status: "authorized",
      next_payment_date: "2026-09-15T12:00:00Z",
      retry_state: "retrying",
      amount: null,
      currency: "ARS",
    }

    render(await FacturacionPage())

    expect(screen.getByText(/reintentando automáticamente/i)).toBeInTheDocument()
  })
})
