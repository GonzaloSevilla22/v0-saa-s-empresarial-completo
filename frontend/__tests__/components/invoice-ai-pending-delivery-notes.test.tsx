/**
 * remitos-compra (tanda B, D11, tarea 7.9) — aviso contra la doble suma en la
 * FACTURA IA (`InvoiceAIButton`).
 *
 * "Recibo con remito y la factura llega después": subir la factura de esa mercadería
 * a la Factura IA crea una compra directa, que vuelve a SUMAR el stock. El flujo no
 * identifica al proveedor, así que si la CUENTA tiene remitos de compra pendientes,
 * el aviso aparece antes de confirmar (en la revisión), con el enlace a la pestaña De
 * compra filtrada por pendientes. Es un aviso: no bloquea la confirmación.
 *
 * Invariantes bajo test:
 *  - con pendientes en la cuenta: el aviso está en la pantalla de revisión, antes del
 *    botón de confirmar, y enlaza a los pendientes (sin filtro de proveedor);
 *  - sin pendientes: no hay aviso;
 *  - el aviso no bloquea: "Confirmar compra" sigue habilitado y registra la compra;
 *  - la consulta de pendientes NO se hace al montar el botón: sólo cuando se llega a
 *    la revisión (la pantalla de compras no pide remitos por cargar este botón).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { MatchedInvoiceLine } from "@/lib/invoice-types"

const mocks = vi.hoisted(() => ({
  useDeliveryNotes: vi.fn(),
  addPurchaseOperation: vi.fn(),
  processInvoice: vi.fn(),
  pending: 0,
}))

vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNotes: (filters: unknown) => {
    mocks.useDeliveryNotes(filters)
    return { data: { items: [], total: mocks.pending } }
  },
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: mocks.addPurchaseOperation }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), warning: vi.fn() } }))
vi.mock("@/lib/services/invoiceOcrService", () => ({
  invoiceOcrService: {
    getAliases: vi.fn().mockResolvedValue([]),
    processInvoice: (...args: unknown[]) => mocks.processInvoice(...args),
    saveAlias: vi.fn().mockResolvedValue(undefined),
    markConfirmed: vi.fn().mockResolvedValue(undefined),
  },
}))
vi.mock("@/lib/invoice-matcher", () => ({
  enrichLines: () => [LINE],
}))
vi.mock("@/components/invoice/InvoiceProductRow", () => ({
  InvoiceProductRow: () => <div data-testid="invoice-row" />,
}))
vi.mock("@/components/ui/scroll-area", () => ({
  ScrollArea: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}))

import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"

const LINE: MatchedInvoiceLine = {
  raw_description: "REMERA",
  description: "Remera",
  quantity: 2,
  unit: null,
  unit_price: 1500,
  discount_pct: null,
  subtotal: 3000,
  detected_unit_id: null,
  detected_unit_name: null,
  match: { type: "exact_name", product_id: "p-1", product_name: "Remera", unit_id: null, unit_symbol: null, confidence: 1 },
  confirmed_product_id: "p-1",
  confirmed_product_name: "Remera",
  confirmed_quantity: 2,
  confirmed_unit_price: 1500,
  confirmed_unit_id: null,
  confirmed_unit_symbol: null,
  included: true,
  is_new_product: false,
}

const PARSED = {
  supplier: { name: "Distribuidora Sur", cuit: null, address: null, invoice_type: "B" as const },
  invoice: { number: "0001-00000099", date: "2026-10-01", currency: "ARS" as const },
  totals: { subtotal: 3000, vat_amount: null, vat_rate: null, other_taxes: null, discount: null, total: 3000 },
  items: [],
  confidence: 0.95,
  warnings: [],
}

/** Sube un archivo y espera a estar en la pantalla de revisión. */
async function reachReview() {
  render(<InvoiceAIButton />)
  fireEvent.click(screen.getByRole("button", { name: /subir factura ia/i }))
  const input = document.querySelector('input[type="file"]') as HTMLInputElement
  fireEvent.change(input, { target: { files: [new File(["x"], "factura.png", { type: "image/png" })] } })
  await screen.findByText(/revisar compra/i)
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.pending = 0
  mocks.processInvoice.mockResolvedValue({ document_id: "doc-1", result: PARSED })
  mocks.addPurchaseOperation.mockResolvedValue(undefined)
})

describe("InvoiceAIButton — aviso contra la doble suma (remitos de compra pendientes)", () => {
  it("con remitos de compra pendientes en la cuenta, la revisión avisa y enlaza a los pendientes", async () => {
    mocks.pending = 3
    await reachReview()

    const note = screen.getByRole("note")
    expect(note).toHaveTextContent(/tenés 3 remitos de compra pendientes/i)
    expect(note).toHaveTextContent(/convertilo desde el remito para no sumar el stock dos veces/i)
    expect(screen.getByRole("link", { name: /ver remitos pendientes/i })).toHaveAttribute(
      "href",
      "/remitos?sentido=compra&estado=pendientes",
    )
    expect(mocks.useDeliveryNotes).toHaveBeenCalledWith({ direction: "purchase", status: "issued", pageSize: 1 })
  })

  it("el aviso está ANTES del botón de confirmar", async () => {
    mocks.pending = 1
    await reachReview()

    const note = screen.getByRole("note")
    const confirm = screen.getByRole("button", { name: /confirmar compra/i })
    expect(note.compareDocumentPosition(confirm) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("sin remitos pendientes no hay aviso", async () => {
    mocks.pending = 0
    await reachReview()

    expect(screen.queryByRole("note")).not.toBeInTheDocument()
  })

  it("el aviso NO bloquea: 'Confirmar compra' sigue habilitado y registra la compra", async () => {
    mocks.pending = 2
    await reachReview()

    expect(screen.getByRole("note")).toBeInTheDocument()
    const confirm = screen.getByRole("button", { name: /confirmar compra/i })
    expect(confirm).toBeEnabled()
    fireEvent.click(confirm)

    await waitFor(() => expect(mocks.addPurchaseOperation).toHaveBeenCalledTimes(1))
  })

  it("al montar el botón NO se consultan los remitos: sólo al llegar a la revisión", async () => {
    mocks.pending = 2
    render(<InvoiceAIButton />)
    expect(mocks.useDeliveryNotes).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: /subir factura ia/i }))
    expect(mocks.useDeliveryNotes).not.toHaveBeenCalled()
  })
})
