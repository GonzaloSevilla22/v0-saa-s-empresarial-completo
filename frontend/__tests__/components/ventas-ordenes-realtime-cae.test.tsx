/**
 * factura-fiscal-imprimible (red team, minor c) — /ventas/ordenes refresca el
 * comprobante cuando Realtime lo pasa a `authorized`.
 *
 * Antes: el badge cambiaba a «Autorizado» por Realtime, pero el CAE, su
 * vencimiento y «Verificar en ARCA» salen del read model de `/sales-orders`,
 * que nadie volvía a pedir — no aparecían hasta recargar la página (en
 * /ventas sí refrescaba, vía `onStatusChange`). Ahora la página vuelve a pedir
 * la lista al cambiar el estado y el bloque muestra el CAE sin recargar.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

type RealtimeHandler = (payload: { new: Record<string, unknown> }) => void

const { rt, getMock } = vi.hoisted(() => ({
  rt: { handlers: [] as RealtimeHandler[] },
  getMock: vi.fn(),
}))

vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: getMock, post: vi.fn() } }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const chan = {
      on: (_type: string, _filter: unknown, handler: RealtimeHandler) => {
        rt.handlers.push(handler)
        return chan
      },
      subscribe: () => chan,
    }
    return { channel: () => chan, removeChannel: vi.fn() }
  },
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { ivaCondition: "monotributista", delegacionAutorizada: true } }),
}))
vi.mock("@/hooks/data/use-points-of-sale", () => ({
  usePointsOfSale: () => ({ pointsOfSale: [], isLoading: false, isError: false }),
}))

import SalesOrdersPage from "@/app/(dashboard)/ventas/ordenes/page"

const base = {
  id: "so-1", account_id: "acc-1", branch_id: "br-1", client_id: null, source_quote_id: null,
  status: "confirmed", payment_method: "cash", total: "32500", sale_operation_id: "op-1",
  created_by: "u-1", created_at: "2026-09-25T15:34:00Z", items: [],
  fiscal_document_id: "fd-1", fiscal_punto_de_venta: 3, fiscal_number: 501,
  fiscal_comprobante_type: "factura_c", fiscal_frozen: false,
}
const pending = { ...base, fiscal_document_status: "pending_cae", fiscal_cae: null, fiscal_cae_due_date: null }
const authorized = {
  ...base, fiscal_document_status: "authorized", fiscal_cae: "71234567890123", fiscal_cae_due_date: "2026-10-05",
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <SalesOrdersPage />
    </QueryClientProvider>,
  )
}

describe("/ventas/ordenes — Realtime autoriza el comprobante", () => {
  beforeEach(() => {
    rt.handlers = []
    getMock.mockReset()
  })

  it("al pasar a «Autorizado» vuelve a pedir la lista y muestra CAE, vencimiento y «Verificar en ARCA» sin recargar", async () => {
    getMock.mockResolvedValueOnce([pending]).mockResolvedValue([authorized])
    renderPage()

    expect(await screen.findByText(/En trámite/)).toBeInTheDocument()
    expect(screen.queryByText("71234567890123")).toBeNull()
    expect(rt.handlers.length).toBeGreaterThan(0)

    act(() => {
      for (const h of rt.handlers) h({ new: { status: "authorized" } })
    })

    expect(await screen.findByText("71234567890123")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /verificar en arca/i })).toBeInTheDocument()
    expect(screen.getByText(/vence/)).toBeInTheDocument()
    expect(getMock).toHaveBeenCalledTimes(2)
    expect(getMock).toHaveBeenLastCalledWith("/sales-orders")
  })

  it("un evento Realtime sin cambio de estado no vuelve a pedir la lista", async () => {
    getMock.mockResolvedValue([pending])
    renderPage()

    expect(await screen.findByText(/En trámite/)).toBeInTheDocument()
    act(() => {
      for (const h of rt.handlers) h({ new: { status: "pending_cae" } })
    })

    await waitFor(() => expect(screen.getByText(/En trámite/)).toBeInTheDocument())
    expect(getMock).toHaveBeenCalledTimes(1)
  })
})
