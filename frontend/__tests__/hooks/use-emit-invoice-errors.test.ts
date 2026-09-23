/**
 * venta-editable-vs-promocion-legacy — mensajes de "Emitir comprobante" (paso 2,
 * POST /sales-orders/{id}/emit-invoice) para los rechazos nuevos del servidor.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: vi.fn(), post: vi.fn() } }))

import { pythonClient } from "@/lib/api/python-client"
import { translateEmitInvoiceError, useEmitInvoice } from "@/hooks/data/use-sales-orders"

describe("translateEmitInvoiceError", () => {
  it("sales_order_out_of_sync: la venta cambió — tocar «Facturar» de nuevo la actualiza", () => {
    expect(translateEmitInvoiceError(
      "Conflicto: sales_order_out_of_sync: la orden x no coincide con su venta (orden 1000.00, venta 111.00, líneas 1)",
    )).toBe("La venta cambió después de prepararla para facturar. Tocá «Facturar» de nuevo para actualizarla.")
  })

  it("sales_order_not_found: la venta ya no está disponible", () => {
    expect(translateEmitInvoiceError("No encontrado: sales_order_not_found: orden de venta no encontrada o no pertenece a la cuenta"))
      .toBe("Esta venta ya no está disponible para facturar (se borró o se editó). Actualizá la lista.")
  })

  it("order_not_confirmed con estado canceled: la venta se borró", () => {
    expect(translateEmitInvoiceError(
      "Payload inválido: order_not_confirmed: la orden debe estar en estado confirmed para facturar (estado actual: canceled)",
    )).toBe("Esta venta se borró: no hay nada que facturar. Actualizá la lista.")
  })

  it("order_not_confirmed SIN canceled conserva el texto de siempre", () => {
    expect(translateEmitInvoiceError(
      "Payload inválido: order_not_confirmed: la orden debe estar en estado confirmed para facturar (estado actual: draft)",
    )).toBe("La venta debe estar confirmada para emitir un comprobante.")
  })

  it("already_invoiced no cambia", () => {
    expect(translateEmitInvoiceError("Conflicto: already_invoiced: la orden ya tiene un comprobante fiscal asociado"))
      .toBe("Esta venta ya tiene un comprobante emitido.")
  })
})

describe("useEmitInvoice — refresco del listado de ventas", () => {
  beforeEach(() => vi.clearAllMocks())

  it("al emitir invalida también ['sales'] para que la fila pase a 'En trámite' con el número", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      fiscal_document_id: "fd-1", comprobante_type: "factura_c", status: "pending_cae",
      punto_de_venta: 1, number: 7, sales_order_id: "so-1",
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const wrapper = ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children)

    const { result } = renderHook(() => useEmitInvoice("so-1"), { wrapper })
    await act(async () => { await result.current.mutateAsync({ point_of_sale_id: "pv-1" }) })

    const keys = spy.mock.calls.map((c) => (c[0] as { queryKey?: readonly unknown[] })?.queryKey?.[0])
    expect(keys).toContain("sales")
    expect(keys).toContain("salesOrders")
  })
})
