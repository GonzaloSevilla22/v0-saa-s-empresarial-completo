/**
 * Ticket HTML: el precio unitario sale con su precisión
 * (ventas-unidades-conversion, cuarta revisión del PR #584, D-F′).
 *
 * Con D-F el precio es por unidad DE LA LÍNEA ($4,575/g). formatMoney lo
 * cortaba en 2 decimales y el ticket decía "100 g × $4,58 = $457,50"
 * (100 × 4,58 = 458): el cliente no podía reconstruir su subtotal.
 */
import { describe, it, expect } from "vitest"
import { generateReceiptHTML, type ReceiptOptions } from "@/lib/receipt"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"

const OPTS: ReceiptOptions = {
  businessName: "Fiambrería",
  unitSymbolFor: (unitId?: string) => (unitId === "u-g" ? "g" : undefined),
}

function item(overrides: Partial<Sale>): Sale {
  return {
    id: "s1", date: "2026-09-25", productId: "p1", productName: "Jamón",
    clientId: null, clientName: "Consumidor Final",
    quantity: 100, unitId: "u-g", unitPrice: 4.575, total: 457.5, currency: "ARS",
    ...overrides,
  } as Sale
}

function op(items: Sale[]): SaleOperation {
  return {
    key: "op1", operationId: "op1", date: "2026-09-25", clientId: "c1",
    clientName: "Consumidor Final", currency: "ARS", items,
    total: items.reduce((s, i) => s + i.total, 0), isGrouped: items.length > 1,
    paymentMethodId: null, branchId: null, canal: null, unitId: null,
    isFiscallyLocked: false, fiscal: null, isPaymentLocked: false,
    hasAccountCharge: false, hasCashMovement: false, hasBankMovement: false,
  }
}

const plain = (s: string) => s.replace(/\u00a0/g, " ")

describe("generateReceiptHTML — precio unitario con su precisión", () => {
  it("100 g a $4,575/g: el ticket dice $ 4,575 (no $ 4,58) y el subtotal $ 457,5", () => {
    const html = plain(generateReceiptHTML(op([item({})]), OPTS))
    expect(html).toContain("100 g")
    expect(html).toContain("$ 4,575")
    expect(html).not.toContain("$ 4,58")
  })

  it("333 g a $0,999/g: $ 0,999 (no $ 1)", () => {
    const html = plain(generateReceiptHTML(op([item({ quantity: 333, unitPrice: 0.999, total: 332.667 })]), OPTS))
    expect(html).toContain("$ 0,999")
  })

  it("un precio al centavo no cambia: $ 1.800", () => {
    const html = plain(generateReceiptHTML(op([item({ quantity: 1, unitId: undefined, unitPrice: 1800, total: 1800 })]), OPTS))
    expect(html).toContain("$ 1.800")
  })
})
