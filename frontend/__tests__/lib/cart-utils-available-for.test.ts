/**
 * remitos-venta (D11, tarea 4.6) — "disponible por sucursal en la capa
 * canónica": `CartStockOptions.availableFor?: (productId) => number`.
 *
 * Con la opción presente, `addManualLineToCart` y `applyScanToCart` (sus tres
 * ramas) comparan contra ESE disponible en lugar de `product.stock` (el agregado
 * del catálogo, que con stock en otra sucursal dejaría pasar lo que el servidor
 * rechaza). Sin la opción nada cambia: los tests de venta y de presupuesto
 * (`cart-utils-lines.test.ts`) siguen verdes sin tocarlos.
 *
 * Además: `maxQuantityPerLine` (el tope de cada input de cantidad, en la unidad
 * de la línea, para `CartItemList.maxQtyMap`) y `linesExceedingAvailable` (las
 * líneas que ya no alcanzan al cambiar de sucursal, para marcarlas sin borrarlas).
 */
import { describe, it, expect } from "vitest"
import {
  addManualLineToCart,
  applyScanToCart,
  linesExceedingAvailable,
  maxQuantityPerLine,
  type SaleCartItem,
} from "@/lib/cart-utils"
import type { ScanResult } from "@/lib/scan-resolution"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS_BY_ID = new Map([KG, G, UN].map((u) => [u.id, u]))

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 10, // el AGREGADO del catálogo, no el de la sucursal
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    baseUnitId: "u-un",
    ...overrides,
  }
}

const REMERA = product({ id: "p-remera", name: "Remera", price: 1000 })
const PAPA = product({ id: "p-papa", name: "Papa", price: 1800, baseUnitId: "u-kg", stock: 20 })
const ctx = (products: Product[]) => ({ unitsById: UNITS_BY_ID, products })

function line(overrides: Partial<SaleCartItem> & { id: string; productId: string }): SaleCartItem {
  return {
    productName: "X",
    unitPrice: 1000,
    quantity: 1,
    discount: 0,
    subtotal: 1000,
    unitId: "u-un",
    unitSymbol: "u",
    quantityBase: 1,
    step: 1,
    minQty: 1,
    ...overrides,
  }
}

/** Stock de la sucursal elegida: 2 de remera, 5 kg de papa. */
const BRANCH_STOCK: Record<string, number> = { "p-remera": 2, "p-papa": 5 }
const availableFor = (productId: string) => BRANCH_STOCK[productId] ?? 0

describe("addManualLineToCart con availableFor", () => {
  const staged = { product: REMERA, unitPrice: 1000, quantity: 3, discount: 0, unitId: "u-un" }

  it("con stock 2 en la sucursal y 10 en el agregado, agregar 3 se rechaza SÓLO si se pasa availableFor", () => {
    const withoutOption = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: true })
    expect(withoutOption.ok).toBe(true) // el agregado (10) alcanza: la venta/presupuesto no cambian

    const withOption = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: true, availableFor })
    expect(withOption.ok).toBe(false)
    if (withOption.ok) throw new Error("expected rejection")
    expect(withOption.reason).toBe("insufficient_stock")
  })

  it("el rechazo informa el disponible de la sucursal, no el del catálogo", () => {
    const r = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: true, availableFor })
    if (r.ok) throw new Error("expected rejection")
    expect(r.message).toBe("Stock insuficiente (disponible: 2 u)")
    expect(r.message).not.toContain("10")
  })

  it("dentro del disponible de la sucursal se agrega", () => {
    const r = addManualLineToCart([], { ...staged, quantity: 2 }, ctx([REMERA]), { enforceStock: true, availableFor })
    expect(r.ok).toBe(true)
  })

  it("el chequeo es acumulativo: lo que ya hay en el carrito cuenta contra el disponible de la sucursal", () => {
    const cart = [line({ id: "l1", productId: "p-remera", quantity: 1, quantityBase: 1 })]
    const r = addManualLineToCart(cart, { ...staged, quantity: 2 }, ctx([REMERA]), { enforceStock: true, availableFor })
    expect(r.ok).toBe(false)
  })

  it("un disponible MAYOR que el agregado también manda (en el remito, lo retenido suma)", () => {
    // 10 en el agregado, pero la sucursal del remito tiene 4 libres + 8 retenidos = 12.
    const r = addManualLineToCart(
      [],
      { ...staged, quantity: 11 },
      ctx([REMERA]),
      { enforceStock: true, availableFor: () => 12 },
    )
    expect(r.ok).toBe(true)
  })

  it("normaliza a la base antes de comparar: 3000 g de papa (3 kg) entran en 5 kg; 6000 g no", () => {
    const ok = addManualLineToCart(
      [],
      { product: PAPA, unitPrice: 1.8, quantity: 3000, discount: 0, unitId: "u-g" },
      ctx([PAPA]),
      { enforceStock: true, availableFor },
    )
    expect(ok.ok).toBe(true)
    const no = addManualLineToCart(
      [],
      { product: PAPA, unitPrice: 1.8, quantity: 6000, discount: 0, unitId: "u-g" },
      ctx([PAPA]),
      { enforceStock: true, availableFor },
    )
    expect(no.ok).toBe(false)
    if (no.ok) throw new Error("expected rejection")
    expect(no.message).toBe("Stock insuficiente (disponible: 5 kg)")
  })

  it("enforceStock=false con availableFor: agrega y avisa el disponible de la sucursal", () => {
    const r = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: false, availableFor })
    if (!r.ok) throw new Error("expected ok")
    expect(r.stockWarning).toBe("Stock insuficiente (disponible: 2 u)")
  })
})

describe("applyScanToCart con availableFor", () => {
  const scanProduct: ScanResult = { kind: "product", product: REMERA }

  it("producto por código: rechaza cuando la sucursal no alcanza aunque el agregado sí", () => {
    const cart = [line({ id: "l1", productId: "p-remera", quantity: 2, quantityBase: 2 })]
    const without = applyScanToCart(cart, scanProduct, ctx([REMERA]), { enforceStock: true })
    expect(without.kind).toBe("added")
    const withOption = applyScanToCart(cart, scanProduct, ctx([REMERA]), { enforceStock: true, availableFor })
    expect(withOption.kind).toBe("rejected")
    if (withOption.kind !== "rejected") throw new Error("expected rejected")
    expect(withOption.label).toBe("Stock insuficiente (disponible: 2 u)")
  })

  it("producto por código: con disponible de sobra agrega la línea", () => {
    const r = applyScanToCart([], scanProduct, ctx([REMERA]), { enforceStock: true, availableFor })
    expect(r.kind).toBe("added")
  })

  it("etiqueta de balanza: compara contra el disponible de la sucursal, no contra product.stock", () => {
    const scale: ScanResult = {
      kind: "scale_line",
      line: {
        productId: "p-papa",
        productName: "Papa",
        unitPrice: 1800,
        quantity: 6,
        discount: 0,
        subtotal: 10800,
        unitId: "u-kg",
        unitSymbol: "kg",
        quantityBase: 6,
        step: 0.001,
        minQty: 0.001,
        source: "scale",
      },
    }
    const without = applyScanToCart([], scale, ctx([PAPA]), { enforceStock: true })
    expect(without.kind).toBe("added") // el agregado (20 kg) alcanza
    const withOption = applyScanToCart([], scale, ctx([PAPA]), { enforceStock: true, availableFor })
    expect(withOption.kind).toBe("rejected") // la sucursal sólo tiene 5 kg
  })
})

describe("maxQuantityPerLine — tope de cada input de cantidad", () => {
  it("una línea sola: el disponible, en su unidad", () => {
    const items = [line({ id: "l1", productId: "p-remera", quantity: 1, quantityBase: 1 })]
    expect(maxQuantityPerLine(items, availableFor, ctx([REMERA]))).toEqual({ l1: 2 })
  })

  it("dos líneas del mismo producto: cada una puede llegar hasta lo que deja la otra", () => {
    const items = [
      line({ id: "l1", productId: "p-remera", quantity: 1, quantityBase: 1 }),
      line({ id: "l2", productId: "p-remera", quantity: 1, quantityBase: 1, source: "scale" }),
    ]
    expect(maxQuantityPerLine(items, availableFor, ctx([REMERA]))).toEqual({ l1: 1, l2: 1 })
  })

  it("convierte a la unidad de la línea: 5 kg disponibles son 5000 g", () => {
    const items = [line({ id: "l1", productId: "p-papa", unitId: "u-g", unitSymbol: "g", quantity: 100, quantityBase: 0.1 })]
    expect(maxQuantityPerLine(items, availableFor, ctx([PAPA]))).toEqual({ l1: 5000 })
  })

  it("no baja de 0 cuando la sucursal no alcanza (lo que sobra se marca, no se vuelve negativo)", () => {
    const items = [line({ id: "l1", productId: "p-remera", quantity: 5, quantityBase: 5 })]
    const other = [line({ id: "l2", productId: "p-remera", quantity: 5, quantityBase: 5 })]
    expect(maxQuantityPerLine([...items, ...other], availableFor, ctx([REMERA]))).toEqual({ l1: 0, l2: 0 })
  })

  it("un producto sin disponible conocido (sin fila en la sucursal) tiene tope 0", () => {
    const items = [line({ id: "l1", productId: "p-otro", quantity: 1, quantityBase: 1 })]
    expect(maxQuantityPerLine(items, availableFor, ctx([REMERA]))).toEqual({ l1: 0 })
  })
})

describe("linesExceedingAvailable — líneas que no alcanzan en la sucursal elegida", () => {
  it("vacío cuando todo entra", () => {
    const items = [line({ id: "l1", productId: "p-remera", quantity: 2, quantityBase: 2 })]
    expect(linesExceedingAvailable(items, availableFor)).toEqual([])
  })

  it("marca TODAS las líneas de un producto cuyo total supera el disponible", () => {
    const items = [
      line({ id: "l1", productId: "p-remera", quantity: 2, quantityBase: 2 }),
      line({ id: "l2", productId: "p-remera", quantity: 1, quantityBase: 1 }),
      line({ id: "l3", productId: "p-papa", unitId: "u-kg", unitSymbol: "kg", quantity: 1, quantityBase: 1 }),
    ]
    expect(linesExceedingAvailable(items, availableFor)).toEqual(["l1", "l2"])
  })

  it("al cambiar de sucursal el mismo carrito se re-valida contra el nuevo disponible", () => {
    const items = [line({ id: "l1", productId: "p-remera", quantity: 8, quantityBase: 8 })]
    expect(linesExceedingAvailable(items, availableFor)).toEqual(["l1"])
    expect(linesExceedingAvailable(items, () => 12)).toEqual([])
  })
})
