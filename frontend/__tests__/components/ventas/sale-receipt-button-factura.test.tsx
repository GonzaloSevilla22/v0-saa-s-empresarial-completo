/**
 * factura-fiscal-imprimible (D10, task 7.5) — SaleReceiptButton con una venta
 * cuyo comprobante está AUTORIZADO.
 *
 * - El menú pasa a "Factura" y ofrece ver/imprimir, descargar, descargar el
 *   duplicado (OQ-2) y verificar en ARCA; el comprobante interno sigue, pero
 *   rotulado "sin validez fiscal".
 * - "Enviar por WhatsApp" comparte LA FACTURA (no el comprobante interno), con
 *   un texto que la nombra.
 * - Un 409 de datos del emisor incompletos se muestra con una acción que lleva
 *   a /configuracion/fiscal.
 * Sin comprobante autorizado, todo queda como antes (cubierto por
 * sale-receipt-button.test.tsx).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { SaleOperation } from "@/lib/group-operations"
import type { Sale, SaleFiscalState } from "@/lib/types"

const { fetchInvoiceMock, toastMock } = vi.hoisted(() => ({
  fetchInvoiceMock: vi.fn(),
  toastMock: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))

vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map(), loading: false, error: null }),
}))
vi.mock("sonner", () => ({ toast: toastMock }))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { businessName: "Sumar", name: "Sumar", phone: "", email: "", avatar: undefined } }),
}))
vi.mock("@/lib/api/fiscal-invoice", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api/fiscal-invoice")>()
  return { ...actual, fetchFiscalInvoicePdf: fetchInvoiceMock }
})

import { SaleReceiptButton } from "@/components/ventas/sale-receipt-button"
import { FiscalInvoiceError } from "@/lib/api/fiscal-invoice"

const fiscal: SaleFiscalState = {
  documentId: "fd-1",
  status: "authorized",
  label: "0003-00000501",
  submittedToArca: true,
  frozen: false,
  voidable: false,
  cae: "71234567890123",
  caeDueDate: "2026-10-05",
  comprobanteType: "factura_c",
}

function makeOp(overrides: Partial<SaleOperation> = {}): SaleOperation {
  const item: Sale = {
    id: "s1", date: "2026-09-21", productId: "p1", productName: "Ciclista Lycra",
    clientId: "c1", clientName: "Ana", quantity: 1, unitPrice: 32500, total: 32500, currency: "ARS",
  }
  return {
    key: "op1", operationId: "op1", date: "2026-09-21", clientId: "c1", clientName: "Ana",
    currency: "ARS", items: [item], total: 32500, isGrouped: false, paymentMethodId: null,
    branchId: null, canal: null, unitId: null, isFiscallyLocked: true, fiscal,
    isPaymentLocked: false, hasAccountCharge: false, hasCashMovement: false, hasBankMovement: false,
    ...overrides,
  }
}

async function openMenu() {
  const user = userEvent.setup()
  render(<SaleReceiptButton op={makeOp()} clientPhone="2615551234" clientFirstName="Ana" />)
  await user.click(screen.getByRole("button", { name: /^factura/i }))
  return user
}

describe("SaleReceiptButton — factura autorizada", () => {
  const originalLocation = window.location
  const assignMock = vi.fn()

  beforeEach(() => {
    vi.clearAllMocks()
    fetchInvoiceMock.mockResolvedValue(new Blob(["%PDF-1.4"], { type: "application/pdf" }))
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:factura-1")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    Object.defineProperty(window, "location", {
      configurable: true,
      value: { ...originalLocation, assign: assignMock },
    })
  })
  afterEach(() => {
    vi.restoreAllMocks()
    Object.defineProperty(window, "location", { configurable: true, value: originalLocation })
  })

  it("el menú se llama «Factura» y ofrece las acciones de la factura y el interno aparte", async () => {
    await openMenu()

    for (const item of [
      "Ver / imprimir factura",
      "Descargar factura (PDF)",
      "Descargar duplicado",
      "Verificar en ARCA",
      "Comprobante interno (sin validez fiscal)",
      "Copiar texto",
    ]) {
      expect(await screen.findByText(item)).toBeInTheDocument()
    }
  })

  it("«Ver / imprimir factura» abre el PDF del endpoint en una pestaña nueva", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const user = await openMenu()

    await user.click(await screen.findByText("Ver / imprimir factura"))

    await waitFor(() => expect(fetchInvoiceMock).toHaveBeenCalledWith("fd-1", { disposition: "inline", copy: "original" }))
    expect(openSpy).toHaveBeenCalledWith("blob:factura-1", "_blank")
  })

  it("«Descargar duplicado» pide la copia DUPLICADO y la descarga", async () => {
    const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {})
    const user = await openMenu()

    await user.click(await screen.findByText("Descargar duplicado"))

    await waitFor(() =>
      expect(fetchInvoiceMock).toHaveBeenCalledWith("fd-1", { disposition: "attachment", copy: "duplicado" }),
    )
    await waitFor(() => expect(clickSpy).toHaveBeenCalled())
    const anchor = clickSpy.mock.contexts[0] as HTMLAnchorElement
    expect(anchor.download).toBe("factura-C-0003-00000501-duplicado.pdf")
  })

  it("«Verificar en ARCA» abre la constatación oficial", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const user = await openMenu()

    await user.click(await screen.findByText("Verificar en ARCA"))

    expect(openSpy).toHaveBeenCalledWith(
      "https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx",
      "_blank",
      "noopener,noreferrer",
    )
  })

  it("WhatsApp comparte la FACTURA con un texto que la nombra", async () => {
    const share = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { canShare: () => true, share })
    const fetchSpy = vi.spyOn(globalThis, "fetch")
    const user = userEvent.setup()
    render(<SaleReceiptButton op={makeOp()} clientPhone="2615551234" clientFirstName="Ana" />)

    await user.click(screen.getByRole("button", { name: /whatsapp/i }))

    await waitFor(() => expect(share).toHaveBeenCalledTimes(1))
    const data = share.mock.calls[0][0] as ShareData & { files: File[] }
    expect(data.files[0].name).toBe("factura-C-0003-00000501.pdf")
    expect(data.text).toContain("Factura C 0003-00000501")
    expect(fetchInvoiceMock).toHaveBeenCalledWith("fd-1", { disposition: "attachment", copy: "original" })
    // no se generó el comprobante interno
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("datos del emisor incompletos: aviso con acción a /configuracion/fiscal", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    fetchInvoiceMock.mockRejectedValue(new FiscalInvoiceError(
      "issuer_data_incomplete",
      "Para imprimir la factura falta completar el domicilio comercial.",
      ["domicilio_comercial"],
    ))
    const user = await openMenu()

    await user.click(await screen.findByText("Ver / imprimir factura"))

    await waitFor(() => expect(toastMock.error).toHaveBeenCalled())
    const [message, options] = toastMock.error.mock.calls[0] as [string, { action: { label: string; onClick: () => void } }]
    expect(message).toBe("Para imprimir la factura falta completar el domicilio comercial.")
    expect(options.action.label).toBe("Completar datos fiscales")
    options.action.onClick()
    expect(assignMock).toHaveBeenCalledWith("/configuracion/fiscal")
  })

  it("otro error: toast con el mensaje, sin acción", async () => {
    fetchInvoiceMock.mockRejectedValue(new FiscalInvoiceError(
      "invoice_date_unknown", "Estamos confirmando con ARCA la fecha de este comprobante.",
    ))
    const user = await openMenu()

    await user.click(await screen.findByText("Descargar factura (PDF)"))

    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith(
      "Estamos confirmando con ARCA la fecha de este comprobante.", undefined,
    ))
  })
})

describe("SaleReceiptButton — sin factura autorizada", () => {
  it.each([
    ["sin comprobante", null],
    ["pendiente", { ...fiscal, status: "pending_cae" as const, cae: null }],
  ])("%s: el menú sigue siendo «Comprobante»", async (_n, f) => {
    render(<SaleReceiptButton op={makeOp({ fiscal: f })} clientPhone={null} clientFirstName={null} />)

    expect(screen.getByRole("button", { name: /^comprobante/i })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /^factura/i })).toBeNull()
  })
})
