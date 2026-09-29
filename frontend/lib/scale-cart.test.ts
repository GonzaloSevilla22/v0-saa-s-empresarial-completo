/**
 * balanza-etiquetas-pos (task 4.3) — RED→GREEN de `resolveScaleScan` (D7).
 * Tabla de ejemplos de D7 + los cinco errores de `ScaleLineError`.
 */
import { describe, it, expect } from "vitest"
import { resolveScaleScan, type ScaleCartContext } from "@/lib/scale-cart"
import type { ScaleDecodeResult } from "@/lib/scale-barcode"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const L: UnitOfMeasure = { id: "u-l", name: "Litro", symbol: "L", type: "volume", factor: 1, isSystem: true }
const UNIT: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }

const UNITS = [KG, G, L, UNIT]
const UNITS_BY_ID = new Map(UNITS.map((u) => [u.id, u]))

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

function ctxWith(products: Product[]): ScaleCartContext {
  return { products, units: UNITS, unitsById: UNITS_BY_ID }
}

function ok(
  layout: "weighed" | "unit",
  plu: number,
  value: { kind: "amount" | "weight" | "quantity"; amount: number },
): Extract<ScaleDecodeResult, { status: "ok" }> {
  return { status: "ok", layout, plu, value }
}

describe("resolveScaleScan — D7", () => {
  it("importe embebido cobra exactamente la etiqueta (Tomate, base kg)", () => {
    const tomate = product({ id: "p-tomate", name: "Tomate", price: 4.8, baseUnitId: "u-kg", scalePlu: 261 })
    const r = resolveScaleScan(ok("weighed", 261, { kind: "amount", amount: 13.63 }), ctxWith([tomate]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(2.84)
    expect(r.line.quantityBase).toBe(2.84)
    expect(r.line.subtotal).toBe(13.63)
    expect(Math.round(r.line.unitPrice * r.line.quantity * 100) / 100).toBe(13.63)
    expect(r.line.source).toBe("scale")
  })

  it("la cantidad se expresa en la unidad base del producto (Tomate, base gramo)", () => {
    const tomate = product({ id: "p-tomate-g", name: "Tomate", price: 4.5, baseUnitId: "u-g", scalePlu: 261 })
    const r = resolveScaleScan(ok("weighed", 261, { kind: "amount", amount: 13500 }), ctxWith([tomate]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(3000)
    expect(r.line.unitPrice).toBe(4.5)
    expect(r.line.subtotal).toBe(13500)
  })

  it("peso embebido usa el precio del catálogo (Papa, base kg)", () => {
    const papa = product({ id: "p-papa", name: "Papa", price: 1800, baseUnitId: "u-kg", scalePlu: 509 })
    const r = resolveScaleScan(ok("weighed", 509, { kind: "weight", amount: 1.25 }), ctxWith([papa]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(1.25)
    expect(r.line.unitPrice).toBe(1800)
    expect(r.line.subtotal).toBe(2250)
  })

  it("etiqueta por unidad con importe (Lechuga, base unidad)", () => {
    const lechuga = product({ id: "p-lechuga", name: "Lechuga", price: 4.5, baseUnitId: "u-un", scalePlu: 100 })
    const r = resolveScaleScan(ok("unit", 100, { kind: "amount", amount: 9 }), ctxWith([lechuga]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(2)
    expect(r.line.subtotal).toBe(9)
    expect(r.line.unitPrice).toBe(4.5)
  })

  it("etiqueta por unidad con cantidad embebida", () => {
    const lechuga = product({ id: "p-lechuga2", name: "Lechuga", price: 4.5, baseUnitId: "u-un", scalePlu: 101 })
    const r = resolveScaleScan(ok("unit", 101, { kind: "quantity", amount: 3 }), ctxWith([lechuga]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(3)
    expect(r.line.subtotal).toBe(13.5)
  })

  it("precio distinto en la balanza y en el catálogo: cobra la etiqueta con una cantidad derivada de 2,726 kg", () => {
    const tomate = product({ id: "p-tomate3", name: "Tomate", price: 5.0, baseUnitId: "u-kg", scalePlu: 261 })
    const r = resolveScaleScan(ok("weighed", 261, { kind: "amount", amount: 13.63 }), ctxWith([tomate]))
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.quantity).toBe(2.726)
    expect(r.line.subtotal).toBe(13.63)
  })

  it("TRIANGULATE: sale_mode_mismatch para un producto de base Litro con la etiqueta de peso", () => {
    const agua = product({ id: "p-agua", name: "Agua", price: 10, baseUnitId: "u-l", scalePlu: 700 })
    const r = resolveScaleScan(ok("weighed", 700, { kind: "amount", amount: 10 }), ctxWith([agua]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("sale_mode_mismatch")
  })

  it("TRIANGULATE: sale_mode_mismatch para un producto de base Litro con la etiqueta de unidad", () => {
    const agua = product({ id: "p-agua2", name: "Agua", price: 10, baseUnitId: "u-l", scalePlu: 701 })
    const r = resolveScaleScan(ok("unit", 701, { kind: "quantity", amount: 2 }), ctxWith([agua]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("sale_mode_mismatch")
  })

  it("mensaje exacto de sale_mode_mismatch: peso vs producto por unidad", () => {
    const lechuga = product({ id: "p-lechuga3", name: "Lechuga", price: 4.5, baseUnitId: "u-un", scalePlu: 261 })
    const r = resolveScaleScan(ok("weighed", 261, { kind: "amount", amount: 13.63 }), ctxWith([lechuga]))
    if (r.ok) throw new Error("expected error")
    expect(r.message).toBe(
      "La etiqueta es de venta por peso pero «Lechuga» se vende por unidad en Aliadata. Revisá el modo de venta del PLU en la balanza o la unidad del producto.",
    )
  })

  it("error: PLU sin producto asignado", () => {
    const r = resolveScaleScan(ok("weighed", 509, { kind: "amount", amount: 10 }), ctxWith([]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("plu_not_assigned")
    expect(r.message).toContain("509")
  })

  it("error: producto padre con variantes", () => {
    const padre = product({ id: "p-padre", name: "Buzo", price: 100, scalePlu: 42, stockControlType: "variant_only" })
    const r = resolveScaleScan(ok("unit", 42, { kind: "amount", amount: 100 }), ctxWith([padre]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("product_is_parent")
  })

  it("error: producto sin precio", () => {
    const sinPrecio = product({ id: "p-sinprecio", name: "Fideos", price: 0, baseUnitId: "u-un", scalePlu: 55 })
    const r = resolveScaleScan(ok("unit", 55, { kind: "amount", amount: 10 }), ctxWith([sinPrecio]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("product_without_price")
  })

  it("error: cantidad derivada menor a la precisión mínima (quantity_below_precision)", () => {
    const carisimo = product({ id: "p-carisimo", name: "Azafrán", price: 1_000_000, baseUnitId: "u-kg", scalePlu: 900 })
    const r = resolveScaleScan(ok("weighed", 900, { kind: "amount", amount: 0.5 }), ctxWith([carisimo]))
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error("expected error")
    expect(r.error).toBe("quantity_below_precision")
  })

  it("REFACTOR: unitPrice × quantity redondeado al centavo es exactamente el importe de la etiqueta", () => {
    const tomate = product({ id: "p-tomate4", name: "Tomate", price: 4.8, baseUnitId: "u-kg", scalePlu: 261 })
    const r = resolveScaleScan(ok("weighed", 261, { kind: "amount", amount: 13.63 }), ctxWith([tomate]))
    if (!r.ok) throw new Error("expected ok")
    const total = Math.round(r.line.unitPrice * r.line.quantity * 100) / 100
    expect(total).toBe(13.63)
  })

  it("la línea nace con source: scale y sin descuento", () => {
    const lechuga = product({ id: "p-lechuga4", name: "Lechuga", price: 4.5, baseUnitId: "u-un", scalePlu: 100 })
    const r = resolveScaleScan(ok("unit", 100, { kind: "amount", amount: 9 }), ctxWith([lechuga]))
    if (!r.ok) throw new Error("expected ok")
    expect(r.line.source).toBe("scale")
    expect(r.line.discount).toBe(0)
  })
})
