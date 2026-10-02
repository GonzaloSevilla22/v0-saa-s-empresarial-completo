/**
 * presupuestos-modulo (D12, task 4.4) — funciones puras de carrito extraídas de
 * `components/forms/sale-form.tsx` a `lib/cart-utils.ts`:
 *
 *   addManualLineToCart · applyScanToCart · updateLineQuantity ·
 *   updateLineSubtotal · removeLine
 *
 * El formulario de venta y el de presupuesto comparten esta única definición.
 * La diferencia entre los dos es UNA bandera: `enforceStock` (la venta
 * rechaza lo que supera el disponible; el presupuesto sólo lo avisa).
 */
import { describe, it, expect } from "vitest"
import {
  addManualLineToCart,
  applyScanToCart,
  exceedsStock,
  removeLine,
  updateLineQuantity,
  updateLineSubtotal,
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
    stock: 10,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    baseUnitId: "u-un",
    ...overrides,
  }
}

const REMERA = product({ id: "p-remera", name: "Remera", price: 1000 })
const PAPA = product({ id: "p-papa", name: "Papa", price: 1800, baseUnitId: "u-kg", stock: 5 })

function ctx(products: Product[]) {
  return { unitsById: UNITS_BY_ID, products }
}

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

describe("addManualLineToCart", () => {
  it("línea nueva: toma nombre, unidad, normalización, paso y subtotal con descuento", () => {
    const r = addManualLineToCart(
      [],
      { product: REMERA, unitPrice: 1000, quantity: 3, discount: 10, unitId: "u-un" },
      ctx([REMERA]),
      { enforceStock: true },
    )
    expect(r.ok).toBe(true)
    if (!r.ok) throw new Error("expected ok")
    expect(r.merged).toBe(false)
    expect(r.items).toHaveLength(1)
    expect(r.items[0]).toMatchObject({
      productId: "p-remera",
      productName: "Remera",
      unitPrice: 1000,
      quantity: 3,
      discount: 10,
      subtotal: 2700,
      unitId: "u-un",
      unitSymbol: "u",
      quantityBase: 3,
      step: 1,
      minQty: 1,
    })
    expect(typeof r.items[0].id).toBe("string")
    expect(r.items[0].source).toBeUndefined()
  })

  it("el nombre de una variante lleva su padre (etiqueta canónica)", () => {
    const parent = product({ id: "p-pad", name: "Remera", price: 0, stockControlType: "variant_only" })
    const variant = product({ id: "p-v", name: "Roja M", price: 1200, parentId: "p-pad", isVariant: true })
    const r = addManualLineToCart(
      [],
      { product: variant, unitPrice: 1200, quantity: 1, discount: 0, unitId: "u-un" },
      ctx([parent, variant]),
      { enforceStock: true },
    )
    if (!r.ok) throw new Error("expected ok")
    expect(r.items[0].productName).toBe("Remera / Roja M")
  })

  it("fusiona con la línea del mismo producto y unidad: suma cantidad y recalcula con SU precio y descuento", () => {
    const existing = line({ id: "l1", productId: "p-remera", unitPrice: 900, quantity: 2, discount: 10, subtotal: 1620, quantityBase: 2 })
    const r = addManualLineToCart(
      [existing],
      { product: REMERA, unitPrice: 1000, quantity: 3, discount: 0, unitId: "u-un" },
      ctx([REMERA]),
      { enforceStock: true },
    )
    if (!r.ok) throw new Error("expected ok")
    expect(r.merged).toBe(true)
    expect(r.items).toHaveLength(1)
    expect(r.items[0]).toMatchObject({ id: "l1", quantity: 5, quantityBase: 5, unitPrice: 900, discount: 10, subtotal: 4050 })
  })

  it.each(["scale", "persisted"] as const)("NO fusiona sobre una línea con source '%s': crea una nueva", (source) => {
    const existing = line({ id: "l1", productId: "p-remera", source })
    const r = addManualLineToCart(
      [existing],
      { product: REMERA, unitPrice: 1000, quantity: 1, discount: 0, unitId: "u-un" },
      ctx([REMERA]),
      { enforceStock: false },
    )
    if (!r.ok) throw new Error("expected ok")
    expect(r.merged).toBe(false)
    expect(r.items).toHaveLength(2)
  })

  it("no fusiona si la unidad de la línea es otra", () => {
    const existing = line({ id: "l1", productId: "p-papa", unitId: "u-kg", unitSymbol: "kg" })
    const r = addManualLineToCart(
      [existing],
      { product: PAPA, unitPrice: 1.8, quantity: 500, discount: 0, unitId: "u-g" },
      ctx([PAPA]),
      { enforceStock: false },
    )
    if (!r.ok) throw new Error("expected ok")
    expect(r.merged).toBe(false)
    expect(r.items).toHaveLength(2)
  })

  it("unidad distinta de la base: normaliza a la base del producto y usa el paso del medible", () => {
    const r = addManualLineToCart(
      [],
      { product: PAPA, unitPrice: 1.8, quantity: 500, discount: 0, unitId: "u-g" },
      ctx([PAPA]),
      { enforceStock: true },
    )
    if (!r.ok) throw new Error("expected ok")
    expect(r.items[0]).toMatchObject({ unitId: "u-g", unitSymbol: "g", quantityBase: 0.5, step: 0.001, minQty: 0.001 })
  })

  describe("stock", () => {
    const cart = [line({ id: "l1", productId: "p-remera", quantity: 8, quantityBase: 8, subtotal: 8000 })]
    const staged = { product: REMERA, unitPrice: 1000, quantity: 3, discount: 0, unitId: "u-un" }

    it("enforceStock=true rechaza lo que supera el disponible, con el disponible en la unidad base", () => {
      const r = addManualLineToCart(cart, staged, ctx([REMERA]), { enforceStock: true })
      expect(r.ok).toBe(false)
      if (r.ok) throw new Error("expected rejection")
      expect(r.reason).toBe("insufficient_stock")
      expect(r.message).toBe("Stock insuficiente (disponible: 10 u)")
    })

    it("el rechazo coincide con el chequeo acumulativo exceedsStock", () => {
      expect(exceedsStock(cart, "p-remera", 3, REMERA.stock)).toBe(true)
      expect(exceedsStock(cart, "p-remera", 2, REMERA.stock)).toBe(false)
      const ok = addManualLineToCart(cart, { ...staged, quantity: 2 }, ctx([REMERA]), { enforceStock: true })
      expect(ok.ok).toBe(true)
    })

    it("la línea persistida (editar una venta) no cuenta contra el disponible", () => {
      const persisted = [line({ id: "l1", productId: "p-remera", quantity: 9, quantityBase: 9, source: "persisted" })]
      const r = addManualLineToCart(persisted, staged, ctx([REMERA]), { enforceStock: true })
      expect(r.ok).toBe(true)
    })

    it("enforceStock=false NO rechaza: agrega y avisa el disponible", () => {
      const r = addManualLineToCart(cart, staged, ctx([REMERA]), { enforceStock: false })
      expect(r.ok).toBe(true)
      if (!r.ok) throw new Error("expected ok")
      expect(r.stockWarning).toBe("Stock insuficiente (disponible: 10 u)")
      expect(r.items[0].quantity).toBe(11)
    })

    it("dentro del disponible no hay aviso aunque enforceStock sea false", () => {
      const r = addManualLineToCart([], staged, ctx([REMERA]), { enforceStock: false })
      if (!r.ok) throw new Error("expected ok")
      expect(r.stockWarning).toBeUndefined()
    })
  })
})

describe("applyScanToCart", () => {
  const productScan = (p: Product): ScanResult => ({ kind: "product", product: p })

  it("un error de lectura se rechaza con su mensaje", () => {
    const r = applyScanToCart([], { kind: "error", message: 'Código "123" no encontrado' }, ctx([REMERA]), { enforceStock: true })
    expect(r).toEqual({ kind: "rejected", label: 'Código "123" no encontrado' })
  })

  it("producto por unidades: agrega una línea y el rótulo es sólo el nombre", () => {
    const r = applyScanToCart([], productScan(REMERA), ctx([REMERA]), { enforceStock: true })
    expect(r.kind).toBe("added")
    if (r.kind !== "added") throw new Error("expected added")
    expect(r.label).toBe("Remera")
    expect(r.items).toHaveLength(1)
    expect(r.items[0]).toMatchObject({ productId: "p-remera", quantity: 1, unitPrice: 1000 })
  })

  it("el mismo producto escaneado dos veces suma sobre la línea (no crea otra)", () => {
    const first = applyScanToCart([], productScan(REMERA), ctx([REMERA]), { enforceStock: true })
    if (first.kind !== "added") throw new Error("expected added")
    const second = applyScanToCart(first.items, productScan(REMERA), ctx([REMERA]), { enforceStock: true })
    if (second.kind !== "added") throw new Error("expected added")
    expect(second.items).toHaveLength(1)
    expect(second.items[0].quantity).toBe(2)
  })

  it("producto medible: no agrega una cantidad arbitraria, pide la cantidad", () => {
    const r = applyScanToCart([], productScan(PAPA), ctx([PAPA]), { enforceStock: true })
    expect(r.kind).toBe("needs_quantity")
    if (r.kind !== "needs_quantity") throw new Error("expected needs_quantity")
    expect(r.product.id).toBe("p-papa")
    expect(r.label).toBe("Ingresá la cantidad de «Papa»")
  })

  describe("stock en la rama de producto por unidades", () => {
    const cart = [line({ id: "l1", productId: "p-remera", quantity: 10, quantityBase: 10 })]

    it("enforceStock=true: rechaza lo que supera el disponible", () => {
      const r = applyScanToCart(cart, productScan(REMERA), ctx([REMERA]), { enforceStock: true })
      expect(r).toEqual({ kind: "rejected", label: "Stock insuficiente (disponible: 10 u)" })
    })

    it("enforceStock=false: agrega igual y avisa", () => {
      const r = applyScanToCart(cart, productScan(REMERA), ctx([REMERA]), { enforceStock: false })
      expect(r.kind).toBe("added")
      if (r.kind !== "added") throw new Error("expected added")
      expect(r.stockWarning).toBe("Stock insuficiente (disponible: 10 u)")
      expect(r.items[0].quantity).toBe(11)
    })
  })

  describe("etiqueta de balanza", () => {
    const scaleLine = (qtyBase: number): ScanResult => ({
      kind: "scale_line",
      line: {
        productId: "p-papa",
        productName: "Papa",
        unitPrice: 1800,
        quantity: qtyBase,
        discount: 0,
        subtotal: 1800 * qtyBase,
        unitId: "u-kg",
        unitSymbol: "kg",
        quantityBase: qtyBase,
        step: 0.001,
        minQty: 0.001,
        source: "scale",
      },
    })

    it("agrega una línea nueva de origen balanza, con id propio", () => {
      const r = applyScanToCart([], scaleLine(1.25), ctx([PAPA]), { enforceStock: true })
      if (r.kind !== "added") throw new Error("expected added")
      expect(r.label).toBe("Papa")
      expect(r.items[0]).toMatchObject({ productId: "p-papa", quantity: 1.25, source: "scale" })
      expect(typeof r.items[0].id).toBe("string")
    })

    it("dos etiquetas del mismo producto son dos líneas (nunca se fusionan)", () => {
      const a = applyScanToCart([], scaleLine(1), ctx([PAPA]), { enforceStock: true })
      if (a.kind !== "added") throw new Error("expected added")
      const b = applyScanToCart(a.items, scaleLine(1), ctx([PAPA]), { enforceStock: true })
      if (b.kind !== "added") throw new Error("expected added")
      expect(b.items).toHaveLength(2)
      expect(b.items[0].id).not.toBe(b.items[1].id)
    })

    it("chequeo ACUMULATIVO: dos etiquetas que juntas superan el disponible (5 kg)", () => {
      const a = applyScanToCart([], scaleLine(3), ctx([PAPA]), { enforceStock: true })
      if (a.kind !== "added") throw new Error("expected added")
      const b = applyScanToCart(a.items, scaleLine(3), ctx([PAPA]), { enforceStock: true })
      expect(b).toEqual({ kind: "rejected", label: "Stock insuficiente (disponible: 5 kg)" })
    })

    it("enforceStock=false: la segunda etiqueta entra y se avisa el disponible", () => {
      const a = applyScanToCart([], scaleLine(3), ctx([PAPA]), { enforceStock: false })
      if (a.kind !== "added") throw new Error("expected added")
      const b = applyScanToCart(a.items, scaleLine(3), ctx([PAPA]), { enforceStock: false })
      if (b.kind !== "added") throw new Error("expected added")
      expect(b.items).toHaveLength(2)
      expect(b.stockWarning).toBe("Stock insuficiente (disponible: 5 kg)")
    })
  })
})

describe("reductores de línea", () => {
  const items = [
    line({ id: "a", productId: "p-remera", unitPrice: 1000, quantity: 2, discount: 10, subtotal: 1800, quantityBase: 2 }),
    line({ id: "b", productId: "p-papa", unitId: "u-g", unitSymbol: "g", unitPrice: 1.8, quantity: 500, quantityBase: 0.5, subtotal: 900, step: 0.001, minQty: 0.001 }),
  ]

  describe("updateLineQuantity", () => {
    it("recalcula cantidad base y subtotal con el precio y el descuento de la línea", () => {
      const next = updateLineQuantity(items, "a", 4, ctx([REMERA, PAPA]))
      expect(next[0]).toMatchObject({ quantity: 4, quantityBase: 4, subtotal: 3600 })
      expect(next[1]).toBe(items[1]) // las demás líneas no se tocan
    })

    it("normaliza a la unidad base del producto (gramos -> kg)", () => {
      const next = updateLineQuantity(items, "b", 750, ctx([REMERA, PAPA]))
      expect(next[1]).toMatchObject({ quantity: 750, quantityBase: 0.75, subtotal: 1350 })
    })

    it("no baja del mínimo de la línea (un medible puede bajar de 1)", () => {
      expect(updateLineQuantity(items, "a", 0, ctx([REMERA, PAPA]))[0].quantity).toBe(1)
      expect(updateLineQuantity(items, "b", 0.0001, ctx([REMERA, PAPA]))[1].quantity).toBe(0.001)
    })

    it("una línea rehidratada sin minQty usa el mínimo de su unidad (no sube 0,45 kg a 1)", () => {
      const rehydrated = [line({ id: "c", productId: "p-papa", unitId: "u-kg", unitSymbol: "kg", unitPrice: 1800, quantity: 1, quantityBase: 1, subtotal: 1800, step: undefined, minQty: undefined })]
      const next = updateLineQuantity(rehydrated, "c", 0.4, ctx([PAPA]))
      expect(next[0].quantity).toBe(0.4)
    })
  })

  describe("updateLineSubtotal", () => {
    it("despeja el precio unitario efectivo y borra el descuento", () => {
      const next = updateLineSubtotal(items, "a", 1500)
      expect(next[0]).toMatchObject({ subtotal: 1500, unitPrice: 750, discount: 0 })
      expect(next[1]).toBe(items[1])
    })

    it("con cantidad fraccionaria el subtotal tipeado se reproduce", () => {
      const next = updateLineSubtotal(items, "b", 2000)
      expect(next[1].subtotal).toBe(2000)
      expect(Math.round(next[1].unitPrice * next[1].quantity * 100) / 100).toBe(2000)
    })
  })

  describe("removeLine", () => {
    it("quita la línea indicada y deja las otras", () => {
      expect(removeLine(items, "a").map((i) => i.id)).toEqual(["b"])
      expect(removeLine(items, "b").map((i) => i.id)).toEqual(["a"])
    })
    it("un id inexistente no cambia nada", () => {
      expect(removeLine(items, "zzz")).toHaveLength(2)
    })
  })
})
