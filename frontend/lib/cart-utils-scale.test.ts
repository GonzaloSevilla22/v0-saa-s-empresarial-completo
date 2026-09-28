/**
 * balanza-etiquetas-pos (task 4.4) — RED→GREEN de `exceedsStock` y
 * `addScannedProductLine` (D7/D8) en `lib/cart-utils.ts`.
 */
import { describe, it, expect } from "vitest"
import { exceedsStock, addScannedProductLine, type SaleCartItem } from "@/lib/cart-utils"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UNIT: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS_BY_ID = new Map([KG, UNIT].map((u) => [u.id, u]))

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 1000,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    ...overrides,
  }
}

function line(overrides: Partial<SaleCartItem> & { productId: string }): SaleCartItem {
  return {
    id: crypto.randomUUID(),
    productName: "x",
    unitPrice: 1,
    quantity: 1,
    discount: 0,
    subtotal: 1,
    ...overrides,
  }
}

describe("exceedsStock — D7/OQ-9", () => {
  it("stock 3 kg: una línea de 2 kg + una nueva de 2 kg → excede", () => {
    const items = [line({ productId: "p1", quantityBase: 2, source: "scale" })]
    expect(exceedsStock(items, "p1", 2, 3)).toBe(true)
  })

  it("stock 3 kg: sólo una línea nueva de 2 kg → no excede", () => {
    expect(exceedsStock([], "p1", 2, 3)).toBe(false)
  })

  it("TRIANGULATE: las líneas 'persisted' no cuentan contra el disponible", () => {
    const items = [line({ productId: "p1", quantityBase: 2.84, source: "persisted" })]
    // La persistida ya está descontada del stock — sumar 1kg más con 3kg
    // disponibles no debería excederse.
    expect(exceedsStock(items, "p1", 1, 3)).toBe(false)
  })

  it("una línea de otro producto no cuenta", () => {
    const items = [line({ productId: "otro", quantityBase: 5, source: "scale" })]
    expect(exceedsStock(items, "p1", 2, 3)).toBe(false)
  })

  it("una línea sin source (manual/código) SÍ cuenta", () => {
    const items = [line({ productId: "p1", quantityBase: 2 })]
    expect(exceedsStock(items, "p1", 2, 3)).toBe(true)
  })
})

describe("addScannedProductLine — D8", () => {
  it("producto por unidades sin línea existente: crea una con el precio del catálogo", () => {
    const lechuga = product({ id: "p-lechuga", name: "Lechuga", price: 4.5, baseUnitId: "u-un" })
    const result = addScannedProductLine([], lechuga, { unitsById: UNITS_BY_ID, products: [lechuga] })
    expect("items" in result).toBe(true)
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items).toHaveLength(1)
    expect(result.items[0].quantity).toBe(1)
    expect(result.items[0].unitPrice).toBe(4.5)
    expect(result.items[0].subtotal).toBe(4.5)
  })

  it("producto por unidades con línea existente (sin source): suma unitInputMin conservando su unitPrice", () => {
    const lechuga = product({ id: "p-lechuga", name: "Lechuga", price: 4.5, baseUnitId: "u-un" })
    const existing = line({ productId: "p-lechuga", quantity: 1, unitPrice: 4.0, subtotal: 4.0 })
    const result = addScannedProductLine([existing], lechuga, { unitsById: UNITS_BY_ID, products: [lechuga] })
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items).toHaveLength(1)
    expect(result.items[0].quantity).toBe(2)
    // Conserva el precio EDITADO de la línea (4.0), no el del catálogo (4.5).
    expect(result.items[0].unitPrice).toBe(4.0)
    expect(result.items[0].subtotal).toBe(8.0)
  })

  it("TRIANGULATE: nunca fusiona sobre una línea source: scale", () => {
    const lechuga = product({ id: "p-lechuga", name: "Lechuga", price: 4.5, baseUnitId: "u-un" })
    const scaleLine = line({ productId: "p-lechuga", quantity: 2, unitPrice: 4.5, subtotal: 9, source: "scale" })
    const result = addScannedProductLine([scaleLine], lechuga, { unitsById: UNITS_BY_ID, products: [lechuga] })
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items).toHaveLength(2)
    expect(result.items[0]).toEqual(scaleLine) // intacta
  })

  it("TRIANGULATE: nunca fusiona sobre una línea source: persisted", () => {
    const lechuga = product({ id: "p-lechuga", name: "Lechuga", price: 4.5, baseUnitId: "u-un" })
    const persistedLine = line({ productId: "p-lechuga", quantity: 3, unitPrice: 4.5, subtotal: 13.5, source: "persisted" })
    const result = addScannedProductLine([persistedLine], lechuga, { unitsById: UNITS_BY_ID, products: [lechuga] })
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items).toHaveLength(2)
    expect(result.items[0]).toEqual(persistedLine)
  })

  it("producto medible (base Kilogramo) → needsQuantity, sin tocar el carrito", () => {
    const tomate = product({ id: "p-tomate", name: "Tomate", price: 4.8, baseUnitId: "u-kg" })
    const items = [line({ productId: "otro" })]
    const result = addScannedProductLine(items, tomate, { unitsById: UNITS_BY_ID, products: [tomate] })
    expect(result).toEqual({ needsQuantity: true })
  })

  it("resuelve el nombre canónico con el padre cuando el producto es una variante", () => {
    const padre = product({ id: "p-padre", name: "Buzo", price: 0 })
    const variante = product({ id: "p-var", name: "Talle M", price: 100, baseUnitId: "u-un", parentId: "p-padre" })
    const result = addScannedProductLine([], variante, { unitsById: UNITS_BY_ID, products: [padre, variante] })
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items[0].productName).toBe("Buzo / Talle M")
  })
})
