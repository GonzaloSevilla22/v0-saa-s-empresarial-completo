/**
 * remitos-venta (tareas 5.1/5.2) — lógica pura del formulario del remito:
 * rehidratación de las líneas guardadas (sin `source: "persisted"`, D11), el
 * payload y las reglas que se chequean antes de llamar a la API.
 */
import { describe, it, expect } from "vitest"

import {
  buildDeliveryNoteItemsPayload,
  DELIVERY_NOTE_ADDRESS_MAX,
  DELIVERY_NOTE_NOTES_MAX,
  rehydrateDeliveryNoteLines,
  validateDeliveryNoteDraft,
  type DeliveryNoteDraftCheck,
} from "@/lib/delivery-note-form"
import type { DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const unitsById = new Map([KG, G, U].map((u) => [u.id, u]))

const HUEVO: Product = {
  id: "p-huevo", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 12, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u",
}
const QUESO: Product = {
  id: "p-queso", name: "Queso", category: "Fiambres", categoryId: "c1", cost: 600, price: 1800, margin: 60,
  stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const ctx = { unitsById, products: [HUEVO, QUESO] }

function row(overrides: Partial<DeliveryNoteItemApiRow> & { id: string }): DeliveryNoteItemApiRow {
  return {
    delivery_note_id: "dn-1",
    product_id: "p-huevo",
    unit_id: "u-u",
    quantity: "3",
    price: "90",
    subtotal: "270",
    quantity_base: "3",
    name_snapshot: "Huevo",
    sku_snapshot: null,
    unit_cost_snapshot: null,
    iva_rate_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

describe("rehydrateDeliveryNoteLines", () => {
  it("devuelve las líneas como líneas COMUNES: sin source, con el precio guardado y sin descuento (D11)", () => {
    const { cartItems } = rehydrateDeliveryNoteLines([row({ id: "i-1" })], ctx)
    expect(cartItems).toHaveLength(1)
    const [line] = cartItems
    expect(line.source).toBeUndefined()
    expect(line.productId).toBe("p-huevo")
    expect(line.unitPrice).toBe(90)
    expect(line.quantity).toBe(3)
    expect(line.discount).toBe(0)
    expect(line.subtotal).toBe(270)
    expect(line.unitId).toBe("u-u")
  })

  it("conserva el quantityBase que guardó el servidor (lo que la línea retiene)", () => {
    const { cartItems } = rehydrateDeliveryNoteLines(
      [row({ id: "i-1", product_id: "p-queso", unit_id: "u-g", quantity: "450", quantity_base: "0.45", price: "1.8", subtotal: "810", name_snapshot: "Queso" })],
      ctx,
    )
    expect(cartItems[0].quantity).toBe(450)
    expect(cartItems[0].quantityBase).toBeCloseTo(0.45, 4)
    expect(cartItems[0].unitSymbol).toBe("g")
  })

  it("ordena por line_no y deja al final las que no lo traen", () => {
    const { cartItems } = rehydrateDeliveryNoteLines(
      [
        row({ id: "i-3", line_no: null, quantity: "9", quantity_base: "9" }),
        row({ id: "i-2", line_no: 2, quantity: "5", quantity_base: "5" }),
        row({ id: "i-1", line_no: 1, quantity: "1", quantity_base: "1" }),
      ],
      ctx,
    )
    expect(cartItems.map((i) => i.quantity)).toEqual([1, 5, 9])
  })

  it("con el mismo line_no (o ninguno) respeta el orden en que llegaron", () => {
    const { cartItems } = rehydrateDeliveryNoteLines(
      [
        row({ id: "i-a", line_no: null, quantity: "4", quantity_base: "4" }),
        row({ id: "i-b", line_no: null, quantity: "7", quantity_base: "7" }),
      ],
      ctx,
    )
    expect(cartItems.map((i) => i.quantity)).toEqual([4, 7])
  })

  it("marca como no disponibles las líneas de un producto que ya no está en el catálogo vivo", () => {
    const result = rehydrateDeliveryNoteLines(
      [
        row({ id: "i-1" }),
        row({ id: "i-2", product_id: "p-viejo", name_snapshot: "Producto viejo", line_no: 2, product_deleted: true }),
      ],
      ctx,
    )
    expect(result.cartItems).toHaveLength(2)
    expect(result.cartItems[1].productName).toBe("Producto viejo")
    expect(result.deletedProductIds).toEqual(["p-viejo"])
    expect(result.deletedLineIds).toEqual([result.cartItems[1].id])
  })

  it("el flag product_deleted del servidor alcanza aunque el producto siga en el catálogo cargado", () => {
    const result = rehydrateDeliveryNoteLines([row({ id: "i-1", product_deleted: true })], ctx)
    expect(result.deletedProductIds).toEqual(["p-huevo"])
  })

  it("sin ninguna línea no hay nada marcado", () => {
    const result = rehydrateDeliveryNoteLines([], ctx)
    expect(result).toEqual({ cartItems: [], deletedLineIds: [], deletedProductIds: [] })
  })
})

describe("buildDeliveryNoteItemsPayload", () => {
  it("manda producto, unidad, cantidad, precio efectivo y subtotal por línea, en el orden del carrito", () => {
    const { cartItems } = rehydrateDeliveryNoteLines(
      [
        row({ id: "i-1", line_no: 1 }),
        row({ id: "i-2", product_id: "p-queso", unit_id: "u-kg", quantity: "2", price: "1800", subtotal: "3600", quantity_base: "2", name_snapshot: "Queso", line_no: 2 }),
      ],
      ctx,
    )
    expect(buildDeliveryNoteItemsPayload(cartItems)).toEqual([
      { product_id: "p-huevo", unit_id: "u-u", quantity: 3, price: 90, subtotal: 270 },
      { product_id: "p-queso", unit_id: "u-kg", quantity: 2, price: 1800, subtotal: 3600 },
    ])
  })

  it("un descuento queda adentro del precio efectivo y no viaja aparte", () => {
    const payload = buildDeliveryNoteItemsPayload([
      {
        id: "x", productId: "p-huevo", productName: "Huevo", unitPrice: 100, quantity: 2, discount: 10, subtotal: 180,
        unitId: "u-u",
      },
    ])
    expect(payload).toEqual([{ product_id: "p-huevo", unit_id: "u-u", quantity: 2, price: 90, subtotal: 180 }])
  })

  it("una línea sin unidad manda unit_id null", () => {
    const payload = buildDeliveryNoteItemsPayload([
      { id: "x", productId: "p-huevo", productName: "Huevo", unitPrice: 100, quantity: 1, discount: 0, subtotal: 100 },
    ])
    expect(payload[0].unit_id).toBeNull()
  })
})

describe("validateDeliveryNoteDraft", () => {
  const ok: DeliveryNoteDraftCheck = {
    clientId: "c-ana",
    clientDeleted: false,
    branchId: "b-1",
    branchName: "Centro",
    itemCount: 2,
    exceeding: [],
    address: "",
    notes: "",
  }

  it("un borrador completo no tiene problemas", () => {
    expect(validateDeliveryNoteDraft(ok)).toBeNull()
  })

  it("exige cliente", () => {
    expect(validateDeliveryNoteDraft({ ...ok, clientId: "" })).toMatch(/cliente/i)
  })

  it("un cliente dado de baja bloquea con el aviso accionable", () => {
    expect(validateDeliveryNoteDraft({ ...ok, clientDeleted: true })).toBe(
      "Cliente dado de baja — elegí uno vigente para guardar.",
    )
  })

  it("exige sucursal", () => {
    expect(validateDeliveryNoteDraft({ ...ok, branchId: null })).toMatch(/sucursal/i)
  })

  it("exige al menos una línea", () => {
    expect(validateDeliveryNoteDraft({ ...ok, itemCount: 0 })).toMatch(/producto/i)
  })

  it("las líneas que superan el disponible de la sucursal bloquean y nombran la sucursal y el producto", () => {
    const message = validateDeliveryNoteDraft({ ...ok, exceeding: ["Huevo", "Queso"] })
    expect(message).toMatch(/Centro/)
    expect(message).toMatch(/Huevo/)
    expect(message).toMatch(/Queso/)
  })

  it("el domicilio y las notas respetan sus topes", () => {
    expect(validateDeliveryNoteDraft({ ...ok, address: "x".repeat(DELIVERY_NOTE_ADDRESS_MAX + 1) })).toMatch(/domicilio/i)
    expect(validateDeliveryNoteDraft({ ...ok, notes: "x".repeat(DELIVERY_NOTE_NOTES_MAX + 1) })).toMatch(/notas/i)
    expect(validateDeliveryNoteDraft({ ...ok, address: "x".repeat(DELIVERY_NOTE_ADDRESS_MAX) })).toBeNull()
    expect(validateDeliveryNoteDraft({ ...ok, notes: "x".repeat(DELIVERY_NOTE_NOTES_MAX) })).toBeNull()
  })

  it("el cliente falta antes que la sucursal (el primer problema es el que se muestra)", () => {
    expect(validateDeliveryNoteDraft({ ...ok, clientId: "", branchId: null })).toMatch(/cliente/i)
  })
})
