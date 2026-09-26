/**
 * punto-venta-seleccion (task 4.5) — /ventas/ordenes, donde se facturan las
 * ventas del POS (el POS no emite inline; su banner "Facturar esta venta →"
 * lleva acá).
 *
 * Antes la página sólo mandaba un PV si había UNO activo; con dos o más
 * mandaba `null` y la RPC rechazaba con P0422 ambiguous_point_of_sale —
 * medido en prod el 2026-09-25: 2 de 2 cuentas que facturan tienen dos PV
 * activos, así que ninguna venta del POS se podía facturar. Ahora el botón
 * abre el diálogo y manda el PV elegido: nunca `null`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { postMock } = vi.hoisted(() => ({ postMock: vi.fn() }))
vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: vi.fn(), post: postMock } }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => <span>badge</span> }))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { ivaCondition: "monotributista", delegacionAutorizada: true } }),
}))
vi.mock("@/hooks/data/use-points-of-sale", () => {
  const base = { fiscalProfileId: "fp-1", accountId: "acc-1", branchId: null, isDefault: false, createdAt: "2026-09-26T00:00:00Z" }
  return {
    usePointsOfSale: () => ({
      pointsOfSale: [
        { ...base, id: "pv-3", numero: 3, isActive: true },
        { ...base, id: "pv-9999", numero: 9999, isActive: true },
      ],
      isLoading: false,
      isError: false,
    }),
  }
})
vi.mock("@/hooks/data/use-sales-orders", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/hooks/data/use-sales-orders")>()
  return {
    ...actual,
    useSalesOrders: () => ({
      data: [{
        id: "so-pos-1", status: "confirmed", total: "1500", fiscal_document_id: null,
        created_at: "2026-09-26T12:00:00Z",
      }],
      isLoading: false,
      error: null,
    }),
  }
})

import SalesOrdersPage from "@/app/(dashboard)/ventas/ordenes/page"

beforeEach(() => {
  postMock.mockReset()
  sessionStorage.clear()
})

describe("/ventas/ordenes — facturar una venta del POS con dos PV activos", () => {
  it("abre el diálogo y emite con el PV elegido (nunca null)", async () => {
    const user = userEvent.setup()
    postMock.mockResolvedValueOnce({
      fiscal_document_id: "fd-1", comprobante_type: "factura_c", status: "pending_cae",
      punto_de_venta: 9999, number: 1, sales_order_id: "so-pos-1",
    })
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { mutations: { retry: false } } })}>
        <SalesOrdersPage />
      </QueryClientProvider>,
    )

    await user.click(screen.getByRole("button", { name: /Emitir comprobante AFIP/ }))
    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    expect(postMock).not.toHaveBeenCalled()

    await user.click(screen.getByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 9999/ }))
    await user.click(screen.getByRole("button", { name: /Confirmar y enviar al ARCA/ }))

    await waitFor(() => expect(postMock).toHaveBeenCalledTimes(1))
    expect(postMock).toHaveBeenCalledWith("/sales-orders/so-pos-1/emit-invoice", { point_of_sale_id: "pv-9999" })
    const payload = postMock.mock.calls[0][1] as { point_of_sale_id: string | null }
    expect(payload.point_of_sale_id).not.toBeNull()
  })
})
