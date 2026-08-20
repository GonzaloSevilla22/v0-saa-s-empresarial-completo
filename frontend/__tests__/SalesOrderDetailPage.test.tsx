/**
 * limpiezas-pagos-admin (G1b, task 5.4/5.5) — /ventas/ordenes/[id] muestra el
 * NOMBRE real de la forma de pago (vía payment_method_id -> payment_methods,
 * join embebido de PostgREST) en vez del binario
 * `payment_method === "cash" ? "Efectivo" : "Otro medio"` que la columna de
 * texto retirada hacía posible — ese binario no describía los 7 `kind` del
 * catálogo (p.ej. una orden en `wallet` se mostraba como "Otro medio").
 *
 * Mismo patrón de mock de @/lib/supabase/server que FacturacionPage.test.tsx.
 */
import React from "react"
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, cleanup } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("next/navigation", () => ({
  redirect: vi.fn(),
  notFound: vi.fn(() => {
    throw new Error("NEXT_NOT_FOUND")
  }),
}))

// DocumentTimeline es un Server Component ASYNC propio (hace su propio fetch
// de document_status_history) — se mockea para que este test de la página se
// enfoque en el nombre de la forma de pago, sin depender de su
// comportamiento interno (ya cubierto por document-timeline-utils.test.ts) ni
// de la resolución de componentes async embebidos fuera del pipeline RSC de
// Next (mismo criterio que FacturacionPage.test.tsx con CancelSubscriptionModal).
vi.mock("@/components/documentos/DocumentTimeline", () => ({
  DocumentTimeline: () => null,
}))

let orderRow: Record<string, unknown> | null = null

function makeQueryBuilder(table: string) {
  const resolved =
    table === "sales_orders"
      ? { data: orderRow, error: null }
      : table === "document_status_history"
        ? { data: [], error: null }
        : { data: null, error: null }

  const builder: Record<string, unknown> = {
    select: () => builder,
    eq: () => builder,
    order: () => Promise.resolve(resolved),
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

import SalesOrderDetailPage from "@/app/(dashboard)/ventas/ordenes/[id]/page"

afterEach(() => {
  cleanup()
  orderRow = null
})

describe("SalesOrderDetailPage — nombre real de la forma de pago (task 5.4/5.5)", () => {
  it("kind no binario (wallet): muestra el NOMBRE real, no 'Otro medio'", async () => {
    orderRow = {
      id: "so-1",
      status: "confirmed",
      payment_method_id: "pm-wallet-1",
      payment_methods: { name: "Billetera virtual", kind: "wallet" },
      total: "1500.00",
      created_at: "2026-08-20T12:00:00Z",
      fiscal_document_id: null,
    }

    render(
      await SalesOrderDetailPage({ params: Promise.resolve({ id: "so-1" }) })
    )

    expect(screen.getByText("Billetera virtual")).toBeInTheDocument()
    expect(screen.queryByText("Otro medio")).not.toBeInTheDocument()
    expect(screen.queryByText("Efectivo")).not.toBeInTheDocument()
  })

  it("kind cash: muestra el nombre sembrado ('Efectivo'), no un binario hardcodeado", async () => {
    orderRow = {
      id: "so-2",
      status: "confirmed",
      payment_method_id: "pm-cash-1",
      payment_methods: { name: "Efectivo", kind: "cash" },
      total: "500.00",
      created_at: "2026-08-20T12:00:00Z",
      fiscal_document_id: null,
    }

    render(
      await SalesOrderDetailPage({ params: Promise.resolve({ id: "so-2" }) })
    )

    expect(screen.getByText("Efectivo")).toBeInTheDocument()
  })

  it("sin imputación (payment_method_id NULL): muestra 'Sin especificar', sin error", async () => {
    orderRow = {
      id: "so-3",
      status: "draft",
      payment_method_id: null,
      payment_methods: null,
      total: "500.00",
      created_at: "2026-08-20T12:00:00Z",
      fiscal_document_id: null,
    }

    render(
      await SalesOrderDetailPage({ params: Promise.resolve({ id: "so-3" }) })
    )

    expect(screen.getByText("Sin especificar")).toBeInTheDocument()
  })
})
