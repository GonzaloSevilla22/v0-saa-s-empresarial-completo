/**
 * venta-editable-vs-promocion-legacy — "Facturar" de una venta cargada a mano,
 * de punta a punta en /ventas (con el backend mockeado en el borde HTTP):
 *   Facturar → POST /sales/{op}/promote-to-order → aparece "Emitir comprobante"
 *   → (punto-venta-seleccion) con DOS puntos de venta activos se abre el
 *   diálogo para elegir → POST /sales-orders/{so}/emit-invoice con el PV
 *   ELEGIDO → toast "en trámite" + refresco del listado (["sales"]).
 *   Antes de punto-venta-seleccion emitía a ciegas por `pointsOfSale[0]` (el
 *   de menor número, aunque estuviera inactivo): este test fijaba ese
 *   comportamiento y cambió de expectativa con el pedido del PO.
 * Caminos de error: la emisión rechaza por sales_order_out_of_sync → mensaje
 * traducido Y la fila vuelve a "Facturar" (el próximo clic re-prepara, que es
 * la salida del usuario); la preparación da 404 → mensaje traducido.
 *
 * Que la SQL corra no se prueba acá (esto es jsdom): lo prueban
 * supabase/tests/test_facturar_venta_manual.sql y el e2e con el stack local.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import type { Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

const { postMock, toastMock } = vi.hoisted(() => ({
  postMock: vi.fn(),
  toastMock: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))

vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: vi.fn(), post: postMock } }))
vi.mock("sonner", () => ({ toast: toastMock }))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { ivaCondition: "monotributista", delegacionAutorizada: true } }),
}))
// punto-venta-seleccion: dos PV ACTIVOS (el caso real de las dos cuentas que
// facturan en prod: 3 y 9999) + uno inactivo de menor número, que nunca se
// ofrece ni se envía.
vi.mock("@/hooks/data/use-points-of-sale", () => {
  const base = { fiscalProfileId: "fp-1", accountId: "acc-1", branchId: null, isDefault: false, createdAt: "2026-09-26T00:00:00Z" }
  return {
    usePointsOfSale: () => ({
      pointsOfSale: [
        { ...base, id: "pv-1", numero: 1, isActive: false },
        { ...base, id: "pv-3", numero: 3, isActive: true },
        { ...base, id: "pv-9999", numero: 9999, isActive: true },
      ],
      isLoading: false,
      isError: false,
    }),
  }
})
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({
  FiscalDocumentBadge: ({ initialStatus }: { initialStatus: string }) => <span>badge:{initialStatus}</span>,
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

import userEvent from "@testing-library/user-event"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

const SALE: Sale = {
  id: "s1", date: "2026-09-23", productId: "", productName: "Servicio de prueba",
  clientId: "", clientName: "Consumidor final", quantity: 2, unitPrice: 1234.5,
  total: 2469, currency: "ARS", operationId: "op-1", isFiscallyLocked: false, fiscal: null,
}

function renderList(sales: Sale[] = [SALE]) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const invalidate = vi.spyOn(queryClient, "invalidateQueries")
  const onRefetch = vi.fn()
  render(
    <QueryClientProvider client={queryClient}>
      <SaleOperationsList
        sales={sales} meta={meta} loading={false} error={null}
        dateFrom="" setDateFrom={vi.fn()} dateTo="" setDateTo={vi.fn()}
        paymentMethodId={null} setPaymentMethodId={vi.fn()} clearFilters={vi.fn()}
        onPageChange={vi.fn()} onPageSizeChange={vi.fn()}
        clients={[]} onDeleteOperation={vi.fn()} onEditOperation={vi.fn()} onRefetch={onRefetch}
      />
    </QueryClientProvider>,
  )
  // El detalle (donde vive "Facturar") se abre tocando la fila.
  fireEvent.click(screen.getAllByText("Servicio de prueba")[0])
  return { invalidate, onRefetch }
}

const invalidatedKeys = (spy: ReturnType<typeof vi.spyOn>) =>
  spy.mock.calls.map((c: unknown[]) => (c[0] as { queryKey?: readonly unknown[] })?.queryKey?.[0])

describe("SaleOperationsList — Facturar una venta cargada a mano", () => {
  beforeEach(() => {
    postMock.mockReset()
    Object.values(toastMock).forEach((f) => f.mockReset())
    sessionStorage.clear()
  })

  it("Facturar → prepara → «Emitir comprobante» → con dos PV abre el diálogo, emite con el ELEGIDO y refresca el listado", async () => {
    const user = userEvent.setup()
    postMock
      .mockResolvedValueOnce({ sales_order_id: "so-1", sale_operation_id: "op-1", replayed: false })
      .mockResolvedValueOnce({
        fiscal_document_id: "fd-1", comprobante_type: "factura_c", status: "pending_cae",
        punto_de_venta: 1, number: 12, sales_order_id: "so-1",
      })
    const { invalidate } = renderList()

    fireEvent.click(screen.getByRole("button", { name: "Facturar esta venta en AFIP" }))
    await waitFor(() => expect(postMock).toHaveBeenCalledWith("/sales/op-1/promote-to-order", {}))
    expect(toastMock.success).toHaveBeenCalledWith(
      "Venta lista para facturar. Tocá «Emitir comprobante» para mandarla a ARCA.",
    )

    const emit = await screen.findByRole("button", { name: /Emitir comprobante/ })
    expect(emit).toHaveTextContent("Emitir comprobante")
    fireEvent.click(emit)

    // Ya no emite a ciegas: con dos PV activos pide elegir (y el inactivo no aparece).
    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    expect(postMock).toHaveBeenCalledTimes(1) // sólo la promoción
    await user.click(screen.getByRole("combobox", { name: "Punto de venta" }))
    expect(screen.queryByRole("option", { name: /PV 0001/ })).toBeNull()
    await user.click(screen.getByRole("option", { name: /PV 9999/ }))
    await user.click(screen.getByRole("button", { name: /Confirmar y enviar al ARCA/ }))

    await waitFor(() =>
      expect(postMock).toHaveBeenLastCalledWith("/sales-orders/so-1/emit-invoice", { point_of_sale_id: "pv-9999" }),
    )
    await waitFor(() => expect(toastMock.success).toHaveBeenCalledWith("Comprobante enviado a ARCA — en trámite"))
    expect(invalidatedKeys(invalidate)).toContain("sales")
  })

  it("replay: la venta ya estaba preparada — el mensaje lo dice", async () => {
    postMock.mockResolvedValueOnce({ sales_order_id: "so-1", sale_operation_id: "op-1", replayed: true })
    renderList()
    fireEvent.click(screen.getByRole("button", { name: "Facturar esta venta en AFIP" }))
    await waitFor(() => expect(toastMock.info).toHaveBeenCalledWith(
      "Esta venta ya estaba preparada. Tocá «Emitir comprobante» para mandarla a ARCA.",
    ))
  })

  it("la emisión rechaza (sales_order_out_of_sync): mensaje traducido y la fila VUELVE a «Facturar»", async () => {
    const user = userEvent.setup()
    postMock
      .mockResolvedValueOnce({ sales_order_id: "so-1", sale_operation_id: "op-1", replayed: false })
      .mockRejectedValueOnce(new Error("Conflicto: sales_order_out_of_sync: la orden so-1 no coincide con su venta"))
    renderList()

    fireEvent.click(screen.getByRole("button", { name: "Facturar esta venta en AFIP" }))
    fireEvent.click(await screen.findByRole("button", { name: /Emitir comprobante/ }))
    await user.click(await screen.findByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 0003/ }))
    await user.click(screen.getByRole("button", { name: /Confirmar y enviar al ARCA/ }))

    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith(
      "La venta cambió después de prepararla para facturar. Tocá «Facturar» de nuevo para actualizarla.",
    ))
    expect(await screen.findByRole("button", { name: "Facturar esta venta en AFIP" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Emitir comprobante/ })).toBeNull()
  })

  it("la preparación da 404 (la venta cambió o se borró): mensaje traducido, sin «Emitir comprobante»", async () => {
    postMock.mockRejectedValueOnce(new Error("No encontrado: operation_not_found: operación op-1 no encontrada o ajena"))
    renderList()
    fireEvent.click(screen.getByRole("button", { name: "Facturar esta venta en AFIP" }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith(
      "Esta venta ya no existe o cambió mientras la preparábamos. Actualizá la lista y volvé a intentar.",
    ))
    expect(screen.queryByRole("button", { name: /Emitir comprobante/ })).toBeNull()
  })

  it("cuando la fila refrescada ya trae el comprobante vivo, manda el badge del listado (sin botón de emitir)", async () => {
    postMock.mockResolvedValueOnce({ sales_order_id: "so-1", sale_operation_id: "op-1", replayed: false })
    const queryClient = new QueryClient()
    const props = {
      meta, loading: false, error: null,
      dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
      paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
      onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
      clients: [], onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    }
    const { rerender } = render(
      <QueryClientProvider client={queryClient}><SaleOperationsList sales={[SALE]} {...props} /></QueryClientProvider>,
    )
    fireEvent.click(screen.getAllByText("Servicio de prueba")[0])
    fireEvent.click(screen.getByRole("button", { name: "Facturar esta venta en AFIP" }))
    await screen.findByRole("button", { name: /Emitir comprobante/ })

    const withDoc: Sale = {
      ...SALE,
      fiscal: { documentId: "fd-1", status: "pending_cae", label: "0001-00000012", submittedToArca: false, frozen: false, voidable: true },
    }
    rerender(<QueryClientProvider client={queryClient}><SaleOperationsList sales={[withDoc]} {...props} /></QueryClientProvider>)

    expect(screen.queryByRole("button", { name: /Emitir comprobante/ })).toBeNull()
    expect(screen.getByText("badge:pending_cae")).toBeInTheDocument()
    expect(screen.getByText("0001-00000012")).toBeInTheDocument()
  })
})
