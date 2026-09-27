/**
 * factura-fiscal-imprimible (D10, task 7.2) — /ventas/ordenes muestra el
 * estado REAL del comprobante al cargar.
 *
 * Bug preexistente: la página le pasaba `initialStatus="pending_cae"` FIJO al
 * badge, y Realtime sólo avisa cambios (no el estado inicial), así que una
 * orden ya autorizada se veía "En trámite" para siempre. Ahora el estado sale
 * del read model de `/sales-orders` y el bloque muestra el CAE.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { orders } = vi.hoisted(() => ({ orders: { rows: [] as Record<string, unknown>[] } }))

vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: vi.fn(), post: vi.fn() } }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const chan = { on: () => chan, subscribe: () => chan }
    return { channel: () => chan, removeChannel: vi.fn() }
  },
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { ivaCondition: "monotributista", delegacionAutorizada: true } }),
}))
vi.mock("@/hooks/data/use-points-of-sale", () => ({
  usePointsOfSale: () => ({ pointsOfSale: [], isLoading: false, isError: false }),
}))
vi.mock("@/hooks/data/use-sales-orders", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/hooks/data/use-sales-orders")>()
  return { ...actual, useSalesOrders: () => ({ data: orders.rows, isLoading: false, error: null }) }
})

import SalesOrdersPage from "@/app/(dashboard)/ventas/ordenes/page"

function renderPage() {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <SalesOrdersPage />
    </QueryClientProvider>,
  )
}

const base = {
  id: "so-1", status: "confirmed", total: "32500", created_at: "2026-09-25T15:34:00Z",
  fiscal_document_id: "fd-1", fiscal_punto_de_venta: 3, fiscal_number: 501,
  fiscal_comprobante_type: "factura_c",
}

describe("/ventas/ordenes — estado real del comprobante", () => {
  it("una orden autorizada muestra «Autorizado» y el CAE al cargar", () => {
    orders.rows = [{
      ...base, fiscal_document_status: "authorized", fiscal_cae: "71234567890123",
      fiscal_cae_due_date: "2026-10-05", fiscal_frozen: false,
    }]
    renderPage()

    expect(screen.getByText(/Autorizado/)).toBeInTheDocument()
    expect(screen.queryByText(/En trámite/)).toBeNull()
    expect(screen.getByText("Factura C 0003-00000501")).toBeInTheDocument()
    expect(screen.getByText("71234567890123")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /verificar en arca/i })).toBeInTheDocument()
  })

  it("una orden en trámite sigue «En trámite» y sin CAE", () => {
    orders.rows = [{ ...base, fiscal_document_status: "pending_cae", fiscal_cae: null, fiscal_cae_due_date: null }]
    renderPage()

    expect(screen.getByText(/En trámite/)).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /verificar en arca/i })).toBeNull()
  })

  it("una orden congelada lo dice", () => {
    orders.rows = [{ ...base, fiscal_document_status: "pending_cae", fiscal_frozen: true }]
    renderPage()

    expect(screen.getByText(/Congelado/)).toBeInTheDocument()
  })
})
