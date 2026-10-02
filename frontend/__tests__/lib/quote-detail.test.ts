/**
 * presupuestos-modulo (D10, tarea 5.8) — reglas puras del detalle del
 * presupuesto, en la capa canónica (`lib/quote-detail.ts`):
 *
 *  - `quoteActions`: la tabla de acciones por estado y rol de D10;
 *  - `isModifiedAfterSent`: "Modificado después de enviado";
 *  - `catalogPriceHint`: el precio de lista de hoy, sólo informativo, cuando
 *    difiere del precio efectivo cotizado.
 */
import { describe, it, expect } from "vitest"
import { catalogPriceHint, isModifiedAfterSent, quoteActions, quoteFileName } from "@/lib/quote-detail"
import type { QuoteApiRow, QuoteItemApiRow, QuoteStatus } from "@/lib/quote-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

type ActionsInput = Pick<QuoteApiRow, "status" | "is_expired" | "sent_at" | "sales_order_id">

function input(status: QuoteStatus, overrides: Partial<ActionsInput> = {}): ActionsInput {
  return { status, is_expired: false, sent_at: null, sales_order_id: null, ...overrides }
}

describe("quoteActions — con permiso (CAN_QUOTE)", () => {
  it("draft nunca enviado: editar, marcar enviado, venta (deshabilitada), rechazar, duplicar y eliminar", () => {
    const a = quoteActions(input("draft"), true)
    expect(a).toMatchObject({
      canEdit: true,
      canMarkSent: true,
      markSentOnShare: true,
      showSaleButton: true,
      canReject: true,
      canDuplicate: true,
      canDelete: true,
      showViewSale: false,
    })
  })

  it("draft reabierto (ya había salido: sent_at) NO se elimina", () => {
    const a = quoteActions(input("draft", { sent_at: "2026-09-30T12:00:00Z" }), true)
    expect(a.canDelete).toBe(false)
    expect(a.canEdit).toBe(true)
    expect(a.canMarkSent).toBe(true)
  })

  it("sent: editar, venta, rechazar y duplicar; no se elimina ni se vuelve a marcar enviado", () => {
    const a = quoteActions(input("sent", { sent_at: "2026-09-30T12:00:00Z" }), true)
    expect(a).toMatchObject({
      canEdit: true,
      canMarkSent: false,
      markSentOnShare: false,
      showSaleButton: true,
      canReject: true,
      canDuplicate: true,
      canDelete: false,
    })
  })

  it("enviado vencido (el barrido todavía no corrió): editar para ampliar, rechazar y duplicar; la venta queda deshabilitada por vencimiento", () => {
    const a = quoteActions(input("sent", { is_expired: true, sent_at: "2026-09-01T12:00:00Z" }), true)
    expect(a).toMatchObject({ canEdit: true, canReject: true, canDuplicate: true, saleBlockedByExpiry: true })
    expect(a.showSaleButton).toBe(true)
  })

  it("un presupuesto vigente no bloquea la venta por vencimiento", () => {
    expect(quoteActions(input("sent"), true).saleBlockedByExpiry).toBe(false)
  })

  it.each(["expired", "rejected"] as const)("%s: editar (lo reabre) y duplicar; sin venta, sin rechazar, sin eliminar", (status) => {
    const a = quoteActions(input(status, { sent_at: "2026-09-01T12:00:00Z" }), true)
    expect(a).toMatchObject({
      canEdit: true,
      canDuplicate: true,
      showSaleButton: false,
      canReject: false,
      canDelete: false,
      canMarkSent: false,
    })
  })

  it("accepted (convertido): sólo duplicar y ver la venta; no se edita", () => {
    const a = quoteActions(input("accepted", { sales_order_id: "so-1", sent_at: "2026-09-01T12:00:00Z" }), true)
    expect(a).toMatchObject({
      canEdit: false,
      canReject: false,
      canDelete: false,
      showSaleButton: false,
      canDuplicate: true,
      showViewSale: true,
    })
  })

  it("accepted sin orden asociada no ofrece 'Ver venta'", () => {
    expect(quoteActions(input("accepted"), true).showViewSale).toBe(false)
  })
})

describe("quoteActions — sin permiso (cashier u otro rol sin CAN_QUOTE)", () => {
  it.each(["draft", "sent", "expired", "rejected", "accepted"] as const)(
    "%s: no puede ninguna acción de escritura (ni marcar enviado al compartir)",
    (status) => {
      const a = quoteActions(input(status, { sales_order_id: "so-1" }), false)
      expect(a).toMatchObject({
        canEdit: false,
        canMarkSent: false,
        markSentOnShare: false,
        showSaleButton: false,
        canReject: false,
        canDuplicate: false,
        canDelete: false,
      })
    },
  )

  it("sí puede ver la venta generada (lectura)", () => {
    expect(quoteActions(input("accepted", { sales_order_id: "so-1" }), false).showViewSale).toBe(true)
  })
})

describe("isModifiedAfterSent", () => {
  it("true si se editó después de haberse enviado", () => {
    expect(isModifiedAfterSent({ sent_at: "2026-09-30T12:00:00Z", updated_at: "2026-10-01T09:00:00Z" })).toBe(true)
  })

  it("false si la última edición es anterior al envío", () => {
    expect(isModifiedAfterSent({ sent_at: "2026-10-01T12:00:00Z", updated_at: "2026-09-30T09:00:00Z" })).toBe(false)
  })

  it("false si nunca se envió o nunca se editó", () => {
    expect(isModifiedAfterSent({ sent_at: null, updated_at: "2026-10-01T09:00:00Z" })).toBe(false)
    expect(isModifiedAfterSent({ sent_at: "2026-09-30T12:00:00Z", updated_at: null })).toBe(false)
  })
})

describe("quoteFileName", () => {
  it("usa el número visible", () => {
    expect(quoteFileName("P-00000012")).toBe("presupuesto-P-00000012.pdf")
  })

  it("sin número (anterior al módulo) cae a un nombre genérico", () => {
    expect(quoteFileName(null)).toBe("presupuesto.pdf")
  })
})

describe("catalogPriceHint", () => {
  const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
  const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
  const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
  const unitsById = new Map([KG, G, UN].map((u) => [u.id, u]))

  function product(overrides: Partial<Product> & { id: string; price: number }): Product {
    return {
      name: "X", category: "Otros", cost: null, margin: null, stock: 1, minStock: 0, isVariant: false,
      stockControlType: "tracked", baseUnitId: "u-un", ...overrides,
    }
  }
  const REMERA = product({ id: "p-remera", price: 1500 })
  const PAPA = product({ id: "p-papa", price: 1800, baseUnitId: "u-kg" })

  function line(overrides: Partial<QuoteItemApiRow>): QuoteItemApiRow {
    return {
      id: "i-1", quote_id: "q-1", product_id: "p-remera", unit_id: "u-un", quantity: "1", price: "1000",
      subtotal: "1000", name_snapshot: "Remera", sku_snapshot: null, line_no: 1, ...overrides,
    }
  }

  it("devuelve el precio de lista de hoy cuando difiere del cotizado", () => {
    expect(catalogPriceHint(line({ price: "1000" }), [REMERA, PAPA], unitsById)).toBe(1500)
  })

  it("devuelve null si coincide (no hay nada que informar)", () => {
    expect(catalogPriceHint(line({ price: "1500" }), [REMERA, PAPA], unitsById)).toBeNull()
  })

  it("compara en la unidad de la línea (gramos a partir de $/kg)", () => {
    expect(catalogPriceHint(line({ product_id: "p-papa", unit_id: "u-g", price: "1.8" }), [REMERA, PAPA], unitsById)).toBeNull()
    expect(catalogPriceHint(line({ product_id: "p-papa", unit_id: "u-g", price: "1.5" }), [REMERA, PAPA], unitsById)).toBeCloseTo(1.8, 10)
  })

  it("una línea de servicio o con producto que ya no está no tiene precio de lista", () => {
    expect(catalogPriceHint(line({ product_id: null }), [REMERA], unitsById)).toBeNull()
    expect(catalogPriceHint(line({ product_id: "p-baja" }), [REMERA], unitsById)).toBeNull()
  })
})
