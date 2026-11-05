/**
 * v31-ia-ratelimit-budget (D8, task 4.7): el diálogo «Leer factura con IA» de `InvoiceAIButton`.
 *  - con saldo muestra cuántas lecturas quedan y deja subir;
 *  - sin saldo oculta la zona de subida y ofrece «Ver planes»;
 *  - un rechazo por ráfaga se traduce («Esperá 40 segundos y volvé a intentar»);
 *  - después de cada intento se invalida ["aiUsage", userId] para refrescar el saldo.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"

import { InvoiceOcrError } from "@/lib/invoice-types"

const mocks = vi.hoisted(() => ({
  processInvoice: vi.fn(),
  invalidateQueries: vi.fn(),
  toastError: vi.fn(),
  usage: { ocrUsed: 12, ocrRemaining: 18, ocrLimit: 30, isLoading: false },
}))

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({ usePurchases: () => ({ addPurchaseOperation: vi.fn() }) }))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: mocks.invalidateQueries }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/hooks/auth/use-ai-usage", () => ({ useAiUsage: () => mocks.usage }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: mocks.toastError, warning: vi.fn() } }))
vi.mock("@/lib/services/invoiceOcrService", () => ({
  invoiceOcrService: {
    getAliases: vi.fn().mockResolvedValue([]),
    processInvoice: (...args: unknown[]) => mocks.processInvoice(...args),
  },
}))
vi.mock("@/lib/invoice-matcher", () => ({ enrichLines: () => [] }))
vi.mock("@/components/delivery-notes/PendingPurchaseNotesNotice", () => ({ PendingPurchaseNotesNotice: () => null }))

import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"

function openDialog() {
  render(<InvoiceAIButton />)
  fireEvent.click(screen.getByRole("button", { name: /subir factura ia/i }))
}
const fileInput = () => document.querySelector('input[type="file"]')

function pickFile() {
  fireEvent.change(fileInput() as HTMLInputElement, {
    target: { files: [new File(["x"], "factura.png", { type: "image/png" })] },
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.usage = { ocrUsed: 12, ocrRemaining: 18, ocrLimit: 30, isLoading: false }
})

describe("InvoiceAIButton — cupo de lecturas de factura", () => {
  it("con saldo 18 muestra «Te quedan 18 lecturas de factura este mes» y deja subir", () => {
    openDialog()
    expect(screen.getByText("Te quedan 18 lecturas de factura este mes")).toBeInTheDocument()
    expect(fileInput()).not.toBeNull()
  })

  it("con saldo 0 oculta la zona de subida y ofrece «Ver planes»", () => {
    mocks.usage = { ocrUsed: 5, ocrRemaining: 0, ocrLimit: 5, isLoading: false }
    openDialog()
    expect(fileInput()).toBeNull()
    expect(screen.getByText(/Usaste las 5 lecturas de factura de tu plan este mes\. Se renuevan el 1 de /)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver planes/i })).toHaveAttribute("href", "/planes")
  })

  it("mientras el saldo carga no bloquea ni muestra un aviso falso", () => {
    mocks.usage = { ocrUsed: 0, ocrRemaining: 0, ocrLimit: 0, isLoading: true }
    openDialog()
    expect(fileInput()).not.toBeNull()
    expect(screen.queryByText(/lecturas? de factura/i)).not.toBeInTheDocument()
  })

  it("un rechazo por ráfaga se traduce a «Esperá 40 segundos y volvé a intentar»", async () => {
    mocks.processInvoice.mockRejectedValue(new InvoiceOcrError("rate_limited", "x", { retryAfterSeconds: 40 }))
    openDialog()
    pickFile()
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith("Esperá 40 segundos y volvé a intentar"))
    expect(await screen.findAllByText("Esperá 40 segundos y volvé a intentar")).not.toHaveLength(0)
  })

  it("un error común (no tipado) conserva su mensaje", async () => {
    mocks.processInvoice.mockRejectedValue(new Error("Error subiendo archivo: boom"))
    openDialog()
    pickFile()
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith("Error subiendo archivo: boom"))
  })

  it("después de un intento (fallido) invalida el saldo ['aiUsage', userId]", async () => {
    mocks.processInvoice.mockRejectedValue(new InvoiceOcrError("quota_exceeded", "x"))
    openDialog()
    pickFile()
    await waitFor(() => expect(mocks.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["aiUsage", "u1"] }))
  })

  it("después de un intento exitoso también invalida el saldo", async () => {
    mocks.processInvoice.mockResolvedValue({
      document_id: "doc-1",
      result: { supplier: {}, invoice: {}, totals: {}, items: [], confidence: 1, warnings: [] },
    })
    openDialog()
    pickFile()
    await waitFor(() => expect(mocks.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["aiUsage", "u1"] }))
  })
})
