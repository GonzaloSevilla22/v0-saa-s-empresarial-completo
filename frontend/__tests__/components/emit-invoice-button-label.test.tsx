/**
 * venta-editable-vs-promocion-legacy — EmitInvoiceButton gana `label` y
 * `onEmitFailed` (opcionales). En /ventas el segundo paso dice "Emitir
 * comprobante" (el primero ya se llamó "Facturar"); en /ventas/ordenes el
 * default sigue siendo "Facturar". `onEmitFailed` avisa al contenedor que la
 * emisión falló, para que la fila vuelva a su estado inicial.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const { postMock, getMock } = vi.hoisted(() => ({ postMock: vi.fn(), getMock: vi.fn() }))
vi.mock("@/lib/api/python-client", () => ({ pythonClient: { get: getMock, post: postMock } }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => <span>badge</span> }))

import { EmitInvoiceButton } from "@/components/fiscal/EmitInvoiceButton"

function wrap(node: React.ReactNode) {
  return <QueryClientProvider client={new QueryClient()}>{node}</QueryClientProvider>
}

// punto-venta-seleccion: el botón lee los puntos de venta por sí mismo. Con UN
// PV activo emite directo al primer clic (lo que estos tests ejercitan); la
// selección con varios la cubre emit-invoice-button-point-of-sale.test.tsx.
const ONE_ACTIVE_PV = [{
  id: "pv-1", numero: 1, is_active: true, is_default: false,
  fiscal_profile_id: "fp-1", account_id: "acc-1", branch_id: null, created_at: "2026-09-26T00:00:00Z",
}]

describe("EmitInvoiceButton — label y onEmitFailed", () => {
  beforeEach(() => {
    postMock.mockReset()
    getMock.mockReset()
    getMock.mockImplementation(async (path: string) => (path === "/fiscal/points-of-sale" ? ONE_ACTIVE_PV : null))
  })

  it("sin label sigue diciendo «Facturar» (pantalla /ventas/ordenes intacta)", () => {
    render(wrap(<EmitInvoiceButton salesOrderId="so-1" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" />))
    expect(screen.getByRole("button")).toHaveTextContent("Facturar")
  })

  it("con label muestra el texto pedido", () => {
    render(wrap(<EmitInvoiceButton salesOrderId="so-1" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" label="Emitir comprobante" />))
    expect(screen.getByRole("button")).toHaveTextContent("Emitir comprobante")
  })

  it("si la emisión falla llama onEmitFailed una vez; si sale bien, no", async () => {
    const onEmitFailed = vi.fn()
    postMock.mockRejectedValueOnce(new Error("Conflicto: sales_order_out_of_sync: x"))
    render(wrap(<EmitInvoiceButton salesOrderId="so-1" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" onEmitFailed={onEmitFailed} />))
    await waitFor(() => expect(screen.getByRole("button")).toBeEnabled())
    fireEvent.click(screen.getByRole("button"))
    await waitFor(() => expect(onEmitFailed).toHaveBeenCalledTimes(1))
  })

  it("TRIANGULATE: con emisión exitosa onEmitFailed NO se llama y aparece el badge", async () => {
    const onEmitFailed = vi.fn()
    postMock.mockResolvedValueOnce({ fiscal_document_id: "fd-1", comprobante_type: "factura_c", status: "pending_cae", punto_de_venta: 1, number: 3, sales_order_id: "so-1" })
    render(wrap(<EmitInvoiceButton salesOrderId="so-1" salesOrderStatus="confirmed" fiscalDocumentId={null} ivaConditionEmisor="monotributista" onEmitFailed={onEmitFailed} />))
    await waitFor(() => expect(screen.getByRole("button")).toBeEnabled())
    fireEvent.click(screen.getByRole("button"))
    expect(await screen.findByText("badge")).toBeInTheDocument()
    expect(onEmitFailed).not.toHaveBeenCalled()
  })
})
