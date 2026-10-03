/**
 * remitos-venta (D5/D11, tarea 4 — "cálculo del neto de stock para el aviso de
 * edición") — `lib/delivery-note-stock.ts`.
 *
 * Espejo, en el cliente, de la contabilidad del servidor: lo RETENIDO de un
 * remito sale de las líneas guardadas (`Σ quantity_base` por producto, en la
 * sucursal guardada), nunca del ledger. El aviso de edición muestra el ajuste
 * que el servidor va a hacer: un par espejo (vuelve lo retenido / sale lo
 * nuevo) SÓLO en los pares producto-sucursal que cambian.
 *
 * Reutiliza `exceedsStock`/`maxQuantityPerLine` de `lib/cart-utils` para
 * validar y `formatQuantity` de `lib/format-unit` para mostrar.
 */
import { describe, it, expect } from "vitest"
import {
  computeStockAdjustment,
  deliveryNoteAvailableFor,
  describeEmitNotice,
  describeHeldReturn,
  describeRemovalReturn,
  describeStockAdjustment,
  formatProductQuantity,
  heldByProduct,
} from "@/lib/delivery-note-stock"
import { exceedsStock, type SaleCartItem } from "@/lib/cart-utils"
import type { DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
import type { UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }

function saved(productId: string, quantityBase: string | number, name = productId): DeliveryNoteItemApiRow {
  return {
    id: `i-${productId}-${quantityBase}`,
    delivery_note_id: "dn-1",
    product_id: productId,
    unit_id: null,
    quantity: quantityBase,
    price: 100,
    subtotal: 100,
    quantity_base: quantityBase,
    name_snapshot: name,
    sku_snapshot: null,
    unit_cost_snapshot: 50,
    iva_rate_snapshot: null,
    line_no: 1,
  }
}

function cartLine(productId: string, quantityBase: number, name = productId): SaleCartItem {
  return {
    id: `l-${productId}-${quantityBase}-${Math.random()}`,
    productId,
    productName: name,
    unitPrice: 100,
    quantity: quantityBase,
    discount: 0,
    subtotal: 100,
    quantityBase,
  }
}

describe("heldByProduct — lo retenido sale de las líneas guardadas", () => {
  it("suma quantity_base por producto (varias líneas del mismo producto)", () => {
    const held = heldByProduct([saved("A", 2), saved("A", 1), saved("B", "0.4500")])
    expect(held.get("A")).toBe(3)
    expect(held.get("B")).toBe(0.45)
  })

  it("lee el numeric serializado como texto sin romper (5.0000)", () => {
    expect(heldByProduct([saved("A", "5.0000")]).get("A")).toBe(5)
  })

  it("sin líneas: vacío", () => {
    expect(heldByProduct([]).size).toBe(0)
  })
})

describe("deliveryNoteAvailableFor — una sola contabilidad en la edición", () => {
  const branchStock = (id: string) => ({ A: 0, B: 4 })[id as "A" | "B"] ?? 0

  it("misma sucursal que la guardada: stock de la sucursal + lo retenido", () => {
    const held = new Map([["A", 3]])
    const availableFor = deliveryNoteAvailableFor({ branchStockOf: branchStock, held, savedBranchId: "b1", chosenBranchId: "b1" })
    // retenido 3 con la sucursal en 0: se pueden conservar hasta 3
    expect(availableFor("A")).toBe(3)
    expect(availableFor("B")).toBe(4)
  })

  it("retenido 3 con la sucursal en 0: una línea nueva de 2 sobre las 3 retenidas se rechaza (no se cuenta dos veces)", () => {
    const held = new Map([["A", 3]])
    const availableFor = deliveryNoteAvailableFor({ branchStockOf: branchStock, held, savedBranchId: "b1", chosenBranchId: "b1" })
    // todas las líneas cuentan contra el disponible: 3 (la guardada) + 2 (la nueva) > 3
    const lines = [cartLine("A", 3), cartLine("A", 2)]
    expect(exceedsStock(lines, "A", 0, availableFor("A"))).toBe(true)
    // …y 3 en total sí entran
    expect(exceedsStock([cartLine("A", 3)], "A", 0, availableFor("A"))).toBe(false)
  })

  it("otra sucursal: lo retenido deja de sumar (vive en la sucursal guardada)", () => {
    const held = new Map([["A", 3]])
    const availableFor = deliveryNoteAvailableFor({ branchStockOf: branchStock, held, savedBranchId: "b1", chosenBranchId: "b2" })
    expect(availableFor("A")).toBe(0)
  })

  it("alta (sin remito guardado): sólo el stock de la sucursal elegida", () => {
    const availableFor = deliveryNoteAvailableFor({
      branchStockOf: branchStock,
      held: new Map(),
      savedBranchId: null,
      chosenBranchId: "b1",
    })
    expect(availableFor("B")).toBe(4)
  })

  it("sin sucursal elegida todavía: nada disponible (no se agregan líneas)", () => {
    const availableFor = deliveryNoteAvailableFor({
      branchStockOf: branchStock,
      held: new Map([["A", 3]]),
      savedBranchId: "b1",
      chosenBranchId: null,
    })
    expect(availableFor("A")).toBe(0)
    expect(availableFor("B")).toBe(0)
  })
})

describe("computeStockAdjustment — pares que cambian (D5)", () => {
  const adjust = (savedItems: DeliveryNoteItemApiRow[], savedBranch: string, nextLines: SaleCartItem[], nextBranch: string) =>
    computeStockAdjustment({ savedItems, savedBranchId: savedBranch, nextLines, nextBranchId: nextBranch })

  it("sin cambios de cantidad (sólo precio, cliente o notas): no mueve stock", () => {
    expect(adjust([saved("A", 2), saved("B", 1)], "b1", [cartLine("A", 2), cartLine("B", 1)], "b1")).toEqual([])
  })

  it("A=2/B=1 → A=2/B=3: un solo par espejo sobre B y cero sobre A", () => {
    const result = adjust([saved("A", 2), saved("B", 1)], "b1", [cartLine("A", 2), cartLine("B", 3)], "b1")
    expect(result).toEqual([
      { productId: "B", productName: "B", branchId: "b1", direction: "return", quantity: 1 },
      { productId: "B", productName: "B", branchId: "b1", direction: "out", quantity: 3 },
    ])
    expect(result.some((r) => r.productId === "A")).toBe(false)
  })

  it("reducción: vuelve lo retenido y sale lo nuevo (espejo completo del par, no el neto)", () => {
    const result = adjust([saved("A", 5)], "b1", [cartLine("A", 2)], "b1")
    expect(result.map((r) => [r.direction, r.quantity])).toEqual([
      ["return", 5],
      ["out", 2],
    ])
  })

  it("reducción a 0 (se quita la línea): sólo vuelve lo retenido", () => {
    const result = adjust([saved("A", 3)], "b1", [], "b1")
    expect(result).toEqual([{ productId: "A", productName: "A", branchId: "b1", direction: "return", quantity: 3 }])
  })

  it("producto nuevo: sólo sale", () => {
    const result = adjust([saved("A", 1)], "b1", [cartLine("A", 1), cartLine("C", 4)], "b1")
    expect(result).toEqual([{ productId: "C", productName: "C", branchId: "b1", direction: "out", quantity: 4 }])
  })

  it("cambio de producto: vuelve el viejo y sale el nuevo", () => {
    const result = adjust([saved("A", 2)], "b1", [cartLine("C", 2)], "b1")
    expect(result.map((r) => [r.productId, r.direction, r.quantity])).toEqual([
      ["A", "return", 2],
      ["C", "out", 2],
    ])
  })

  it("cambio de sucursal: vuelve todo a la vieja y sale todo de la nueva, aunque la cantidad no cambie", () => {
    const result = adjust([saved("A", 2), saved("B", 1)], "b1", [cartLine("A", 2), cartLine("B", 1)], "b2")
    expect(result).toEqual([
      { productId: "A", productName: "A", branchId: "b1", direction: "return", quantity: 2 },
      { productId: "B", productName: "B", branchId: "b1", direction: "return", quantity: 1 },
      { productId: "A", productName: "A", branchId: "b2", direction: "out", quantity: 2 },
      { productId: "B", productName: "B", branchId: "b2", direction: "out", quantity: 1 },
    ])
  })

  it("varias líneas del mismo producto se comparan por el TOTAL del producto", () => {
    // retenido 3 (2+1) y requerido 3 (una sola línea de 3): no cambia
    expect(adjust([saved("A", 2), saved("A", 1)], "b1", [cartLine("A", 3)], "b1")).toEqual([])
  })

  it("compara con tolerancia de 4 decimales: 0.1+0.2 contra 0.3 no es un cambio", () => {
    expect(adjust([saved("A", "0.3000")], "b1", [cartLine("A", 0.1), cartLine("A", 0.2)], "b1")).toEqual([])
  })

  it("la cantidad de la línea del carrito sin quantityBase se toma tal cual (fallback)", () => {
    const line = { ...cartLine("A", 4), quantityBase: undefined }
    const result = adjust([], "b1", [line], "b1")
    expect(result).toEqual([{ productId: "A", productName: "A", branchId: "b1", direction: "out", quantity: 4 }])
  })
})

describe("textos del aviso", () => {
  const branchName = (id: string) => ({ b1: "Centro", b2: "Showroom" })[id as "b1" | "b2"] ?? id
  const baseUnitOf = (productId: string): UnitOfMeasure | undefined => (productId === "B" ? KG : UN)

  it("formatProductQuantity: por unidades '3 × Producto'; medibles '0.450 kg de Producto'", () => {
    expect(formatProductQuantity(3, "Producto A", UN)).toBe("3 × Producto A")
    expect(formatProductQuantity(3, "Producto A", undefined)).toBe("3 × Producto A")
    expect(formatProductQuantity(0.45, "Producto B", KG)).toBe("0.450 kg de Producto B")
    expect(formatProductQuantity(2, "Yerba", KG)).toBe("2 kg de Yerba")
  })

  it("describeStockAdjustment: 'Vuelven … a Centro · Salen … de Centro'", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 2, "A")],
      savedBranchId: "b1",
      nextLines: [cartLine("A", 4, "A")],
      nextBranchId: "b1",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf)).toBe(
      "Vuelven 2 × A a Centro · Salen 4 × A de Centro",
    )
  })

  it("describeStockAdjustment con cambio de sucursal nombra cada una", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 2, "A")],
      savedBranchId: "b1",
      nextLines: [cartLine("A", 2, "A")],
      nextBranchId: "b2",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf)).toBe(
      "Vuelven 2 × A a Centro · Salen 2 × A de Showroom",
    )
  })

  it("describeStockAdjustment agrupa varios productos con coma en cada sentido", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 2, "A"), saved("B", "0.4500", "B")],
      savedBranchId: "b1",
      nextLines: [cartLine("A", 1, "A"), cartLine("B", 0.9, "B")],
      nextBranchId: "b1",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf)).toBe(
      "Vuelven 2 × A, 0.450 kg de B a Centro · Salen 1 × A, 0.900 kg de B de Centro",
    )
  })

  it("sólo reducción a 0: sólo la cláusula 'Vuelven'", () => {
    const adjustments = computeStockAdjustment({ savedItems: [saved("A", 3, "A")], savedBranchId: "b1", nextLines: [], nextBranchId: "b1" })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf)).toBe("Vuelven 3 × A a Centro")
  })

  it("sin ajuste: 'Este cambio no mueve stock'", () => {
    expect(describeStockAdjustment([], branchName, baseUnitOf)).toBe("Este cambio no mueve stock")
  })

  it("describeEmitNotice: 'Al emitir, se descuenta del stock de {sucursal}.'", () => {
    expect(describeEmitNotice("Centro")).toBe("Al emitir, se descuenta del stock de Centro.")
  })

  it("describeRemovalReturn (producto dado de baja que se quita): 'Quitarla devuelve N × producto al stock de {sucursal}.'", () => {
    expect(describeRemovalReturn("Remera", 3, "Centro", UN)).toBe("Quitarla devuelve 3 × Remera al stock de Centro.")
    expect(describeRemovalReturn("Yerba", 1.5, "Centro", KG)).toBe("Quitarla devuelve 1.500 kg de Yerba al stock de Centro.")
  })

  it("describeHeldReturn (diálogo de anulación): enumera todo lo que vuelve a la sucursal", () => {
    expect(describeHeldReturn([saved("A", 3, "Producto A"), saved("B", "0.4500", "Producto B")], "Sucursal Centro", baseUnitOf)).toBe(
      "Vuelven a Sucursal Centro: 3 × Producto A, 0.450 kg de Producto B",
    )
  })

  it("describeHeldReturn junta las líneas de un mismo producto", () => {
    expect(describeHeldReturn([saved("A", 2, "A"), saved("A", 1, "A")], "Centro", baseUnitOf)).toBe("Vuelven a Centro: 3 × A")
  })
})
