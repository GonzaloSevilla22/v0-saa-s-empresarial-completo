/**
 * remitos-compra (D11, tarea 5.2) — `priceSource: "price" | "cost"` en la capa
 * canónica del carrito.
 *
 * El remito de COMPRA es el mismo editor de líneas que el de venta, pero la
 * línea nace con el COSTO del catálogo y no con el precio de venta: sin esto, la
 * compra convertida, el cargo al proveedor y el total quedarían a precio de
 * venta. `priceSource` es opcional y su default es `"price"`: la venta, el
 * presupuesto y el POS siguen exactamente igual (sus tests no se tocaron).
 *
 *  - `catalogPriceOf(product, source)`: el precio de catálogo según la fuente
 *    (`cost` nulo = dato ausente, entra a 0).
 *  - `applyScanToCart` y `addScannedProductLine` precargan la fuente elegida en
 *    la línea NUEVA por código; una línea existente conserva el precio que el
 *    usuario le dejó. Una etiqueta de balanza se reprecia al costo (la etiqueta
 *    trae el importe de VENTA y la cantidad en peso).
 *  - `addManualLineToCart` no cambia: el precio ya viene en la línea en
 *    preparación (`StagedProductLine`), que es quien lee la fuente.
 */
import { describe, it, expect } from "vitest"
import {
  addManualLineToCart,
  addScannedProductLine,
  applyScanToCart,
  catalogPriceOf,
  type SaleCartItem,
} from "@/lib/cart-utils"
import type { ScanResult } from "@/lib/scan-resolution"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS_BY_ID = new Map([KG, UN].map((u) => [u.id, u]))

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 10,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    baseUnitId: "u-un",
    ...overrides,
  }
}

const REMERA = product({ id: "p-remera", name: "Remera", price: 1000, cost: 400 })
const SIN_COSTO = product({ id: "p-sin", name: "Sin costo", price: 500, cost: null })
const COSTO_CERO = product({ id: "p-cero", name: "Costo cero", price: 500, cost: 0 })
const PAPA = product({ id: "p-papa", name: "Papa", price: 1800, cost: 900, baseUnitId: "u-kg", scalePlu: 7 })
const ctx = (products: Product[]) => ({ unitsById: UNITS_BY_ID, products })

describe("catalogPriceOf", () => {
  it("por defecto y con 'price' devuelve el precio de venta", () => {
    expect(catalogPriceOf(REMERA)).toBe(1000)
    expect(catalogPriceOf(REMERA, "price")).toBe(1000)
  })

  it("con 'cost' devuelve el costo", () => {
    expect(catalogPriceOf(REMERA, "cost")).toBe(400)
  })

  it("con 'cost' y costo nulo devuelve 0 (dato ausente: la línea entra sin precio), no el precio de venta", () => {
    expect(catalogPriceOf(SIN_COSTO, "cost")).toBe(0)
  })

  it("con 'cost' y costo 0 declarado devuelve 0", () => {
    expect(catalogPriceOf(COSTO_CERO, "cost")).toBe(0)
  })
})

describe("addScannedProductLine con priceSource", () => {
  it("la línea nueva sin fuente nace con el precio de venta (retrocompatible)", () => {
    const result = addScannedProductLine([], REMERA, ctx([REMERA]))
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items[0].unitPrice).toBe(1000)
    expect(result.items[0].subtotal).toBe(1000)
  })

  it("la línea nueva con 'cost' nace con el costo", () => {
    const result = addScannedProductLine([], REMERA, ctx([REMERA]), "cost")
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items[0].unitPrice).toBe(400)
    expect(result.items[0].subtotal).toBe(400)
  })

  it("con 'cost' y costo nulo nace en 0", () => {
    const result = addScannedProductLine([], SIN_COSTO, ctx([SIN_COSTO]), "cost")
    if (!("items" in result)) throw new Error("expected items")
    expect(result.items[0].unitPrice).toBe(0)
    expect(result.items[0].subtotal).toBe(0)
  })

  it("una línea existente conserva el precio que el usuario le dejó al sumar otra unidad", () => {
    const first = addScannedProductLine([], REMERA, ctx([REMERA]), "cost")
    if (!("items" in first)) throw new Error("expected items")
    const edited: SaleCartItem[] = first.items.map((item) => ({ ...item, unitPrice: 450, subtotal: 450 }))
    const second = addScannedProductLine(edited, REMERA, ctx([REMERA]), "cost")
    if (!("items" in second)) throw new Error("expected items")
    expect(second.items).toHaveLength(1)
    expect(second.items[0].quantity).toBe(2)
    expect(second.items[0].unitPrice).toBe(450)
    expect(second.items[0].subtotal).toBe(900)
  })
})

describe("applyScanToCart con priceSource", () => {
  const scanProduct = (p: Product): ScanResult => ({ kind: "product", product: p })

  it("sin fuente, el código crea la línea al precio de venta (venta y presupuesto no cambian)", () => {
    const result = applyScanToCart([], scanProduct(REMERA), ctx([REMERA]), { enforceStock: false })
    if (result.kind !== "added") throw new Error("expected added")
    expect(result.items[0].unitPrice).toBe(1000)
  })

  it("con 'cost' el código crea la línea al costo", () => {
    const result = applyScanToCart([], scanProduct(REMERA), ctx([REMERA]), { enforceStock: false, priceSource: "cost" })
    if (result.kind !== "added") throw new Error("expected added")
    expect(result.items[0].unitPrice).toBe(400)
    expect(result.items[0].subtotal).toBe(400)
  })

  it("con 'cost' y costo nulo el código crea la línea en 0", () => {
    const result = applyScanToCart([], scanProduct(SIN_COSTO), ctx([SIN_COSTO]), { enforceStock: false, priceSource: "cost" })
    if (result.kind !== "added") throw new Error("expected added")
    expect(result.items[0].unitPrice).toBe(0)
  })

  it("una etiqueta de balanza se reprecia al costo y conserva el peso y su origen", () => {
    const scale: ScanResult = {
      kind: "scale_line",
      line: {
        productId: PAPA.id,
        productName: "Papa",
        unitPrice: 1800,
        quantity: 0.5,
        discount: 0,
        subtotal: 900,
        unitId: "u-kg",
        unitSymbol: "kg",
        quantityBase: 0.5,
        step: 0.001,
        minQty: 0.001,
        source: "scale",
      },
    }
    const result = applyScanToCart([], scale, ctx([PAPA]), { enforceStock: false, priceSource: "cost" })
    if (result.kind !== "added") throw new Error("expected added")
    expect(result.items[0]).toMatchObject({ unitPrice: 900, quantity: 0.5, subtotal: 450, source: "scale" })
  })

  it("una etiqueta de balanza sin fuente conserva el importe de venta de la etiqueta", () => {
    const scale: ScanResult = {
      kind: "scale_line",
      line: {
        productId: PAPA.id,
        productName: "Papa",
        unitPrice: 1800,
        quantity: 0.5,
        discount: 0,
        subtotal: 900,
        unitId: "u-kg",
        unitSymbol: "kg",
        quantityBase: 0.5,
        step: 0.001,
        minQty: 0.001,
        source: "scale",
      },
    }
    const result = applyScanToCart([], scale, ctx([PAPA]), { enforceStock: false })
    if (result.kind !== "added") throw new Error("expected added")
    expect(result.items[0]).toMatchObject({ unitPrice: 1800, subtotal: 900 })
  })
})

describe("addManualLineToCart con priceSource", () => {
  it("el alta manual usa el precio de la línea en preparación: la fuente no lo pisa", () => {
    const staged = { product: REMERA, unitPrice: 123, quantity: 2, discount: 0, unitId: "u-un" }
    const result = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: false, priceSource: "cost" })
    if (!result.ok) throw new Error("expected ok")
    expect(result.items[0].unitPrice).toBe(123)
    expect(result.items[0].subtotal).toBe(246)
  })
})
