/**
 * fix/comprobante-print-csp-nonce.
 *
 * "Ventas → Comprobante → Descargar / Imprimir" abre el HTML en una pestaña
 * `blob:`. Bajo la CSP con nonce (`lib/supabase/middleware.ts`), ese
 * documento sólo puede ejecutar su `<script>` de auto-impresión si lleva el
 * nonce vigente — y `handleDownload` tiene que leerlo del documento actual
 * (`lib/script-nonce.ts`) y pasárselo a `generateReceiptHTML`. Sin eso, la
 * pestaña se abre pero el diálogo de impresión nunca aparece: el bug
 * reportado por el PO.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import { SaleReceiptButton } from "@/components/ventas/sale-receipt-button"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() },
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: {
      businessName: "Mi Negocio",
      name: "Mi Negocio",
      phone: "2611234567",
      email: "negocio@test.com",
      avatar: undefined,
    },
  }),
}))

function makeItem(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-09-18",
    productId: "p1",
    productName: "Producto A",
    clientId: "c1",
    clientName: "Consumidor Final",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    ...overrides,
  }
}

function makeOp(overrides: Partial<SaleOperation> = {}): SaleOperation {
  return {
    key: "op1",
    operationId: "op1",
    date: "2026-09-18",
    clientId: "c1",
    clientName: "Consumidor Final",
    currency: "ARS",
    items: [makeItem()],
    total: 100,
    isGrouped: false,
    paymentMethodId: null,
    branchId: null,
    canal: null,
    unitId: null,
    isFiscallyLocked: false,
    fiscal: null,
    isPaymentLocked: false,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false,
    ...overrides,
  }
}

/** Abre el dropdown "Comprobante" y elige "Descargar / Imprimir". */
async function clickDownloadPrint() {
  const user = userEvent.setup()
  render(<SaleReceiptButton op={makeOp()} clientPhone={null} clientFirstName={null} />)

  await user.click(screen.getByRole("button", { name: /comprobante/i }))
  await user.click(await screen.findByText("Descargar / Imprimir"))
}

describe("SaleReceiptButton — Descargar / Imprimir bajo CSP con nonce", () => {
  let nonceScript: HTMLScriptElement | undefined

  afterEach(() => {
    nonceScript?.remove()
    nonceScript = undefined
    vi.restoreAllMocks()
  })

  it("el Blob que se abre en la pestaña nueva lleva el nonce vigente del documento", async () => {
    nonceScript = document.createElement("script")
    nonceScript.setAttribute("nonce", "DOC-N0NC3-123")
    document.head.appendChild(nonceScript)

    let capturedBlob: Blob | undefined
    const createObjectURLSpy = vi
      .spyOn(URL, "createObjectURL")
      .mockImplementation((blob: Blob | MediaSource) => {
        capturedBlob = blob as Blob
        return "blob:mock-url-1"
      })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    await waitFor(() => expect(createObjectURLSpy).toHaveBeenCalledTimes(1))
    expect(capturedBlob).toBeInstanceOf(Blob)
    const html = await capturedBlob!.text()
    expect(html).toContain('<script nonce="DOC-N0NC3-123">')

    expect(openSpy).toHaveBeenCalledWith("blob:mock-url-1", "_blank")
  })

  it("sin ningún <script nonce> en el documento, el Blob sale sin el atributo (no 'undefined' literal)", async () => {
    // Deliberadamente sin montar ningún <script nonce> esta vez.
    let capturedBlob: Blob | undefined
    vi.spyOn(URL, "createObjectURL").mockImplementation((blob: Blob | MediaSource) => {
      capturedBlob = blob as Blob
      return "blob:mock-url-2"
    })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(window, "open").mockReturnValue({} as Window)

    await clickDownloadPrint()

    await waitFor(() => expect(capturedBlob).toBeDefined())
    const html = await capturedBlob!.text()
    expect(html).toContain("<script>")
    expect(html).not.toContain("nonce=")
  })

  it("con el popup bloqueado (window.open devuelve null), cae al <a download>", async () => {
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:mock-url-3")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    vi.spyOn(window, "open").mockReturnValue(null)

    let clickedAnchor: { href: string; download: string } | undefined
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      clickedAnchor = { href: this.href, download: this.download }
    })

    await clickDownloadPrint()

    await waitFor(() => expect(clickedAnchor).toBeDefined())
    expect(clickedAnchor!.href).toContain("blob:mock-url-3")
    expect(clickedAnchor!.download).toBe("comprobante-op1.html")
  })
})
