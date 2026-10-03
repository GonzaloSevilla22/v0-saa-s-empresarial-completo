/**
 * remitos-compra (D4/D5/D11, tarea 4.6) — `lib/delivery-note-stock.ts` por SENTIDO:
 * los textos de emisión, devolución y ajuste (en compra el remito SUMA lo que
 * recibe, así que dicen "se suma", "Salen de" y "Entran … · Salen …"), el
 * MÍNIMO por producto en la edición de compra (`max(0, aportado − stock vigente
 * de la sucursal)`, la misma contabilidad que el chequeo del neto del servidor,
 * sin atribuir origen a la diferencia) y el aviso al mover la recepción a otra
 * sucursal. Funciones puras. Los casos de venta siguen en `delivery-note-stock.test.ts`.
 */
import { describe, it, expect } from "vitest"
import {
  computeStockAdjustment,
  describeEmitNotice,
  describeHeldReturn,
  describePurchaseBranchMove,
  describePurchaseMinimum,
  describeRemovalReturn,
  describeStockAdjustment,
  purchaseBranchMoveBlockers,
  purchaseLinesBelowMinimum,
  purchaseMinimumByProduct,
} from "@/lib/delivery-note-stock"
import type { SaleCartItem } from "@/lib/cart-utils"
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

const baseUnitOf = (productId: string): UnitOfMeasure | undefined => (productId === "B" ? KG : UN)
const branchName = (branchId: string) => (branchId === "b-1" ? "Centro" : "Godoy Cruz")

describe("textos de compra: se SUMA lo que se recibe", () => {
  it("describeEmitNotice: 'Al emitir, se suma al stock de {sucursal}.'", () => {
    expect(describeEmitNotice("Centro", "purchase")).toBe("Al emitir, se suma al stock de Centro.")
  })

  it("describeEmitNotice de venta no cambia (sin direction y con 'sale')", () => {
    expect(describeEmitNotice("Centro")).toBe("Al emitir, se descuenta del stock de Centro.")
    expect(describeEmitNotice("Centro", "sale")).toBe("Al emitir, se descuenta del stock de Centro.")
  })

  it("describeRemovalReturn en compra: quitar la línea RESTA del stock de la sucursal", () => {
    expect(describeRemovalReturn("Remera", 3, "Centro", UN, "purchase")).toBe("Quitarla resta 3 × Remera del stock de Centro.")
    expect(describeRemovalReturn("Yerba", 1.5, "Centro", KG, "purchase")).toBe(
      "Quitarla resta 1.500 kg de Yerba del stock de Centro.",
    )
  })

  it("describeRemovalReturn de venta no cambia", () => {
    expect(describeRemovalReturn("Remera", 3, "Centro", UN, "sale")).toBe("Quitarla devuelve 3 × Remera al stock de Centro.")
  })

  it("describeHeldReturn en compra (diálogo de anulación): enumera lo que SALE de la sucursal", () => {
    expect(
      describeHeldReturn([saved("A", 10, "Producto A"), saved("B", "0.4500", "Producto B")], "Sucursal Centro", baseUnitOf, "purchase"),
    ).toBe("Salen de Sucursal Centro: 10 × Producto A, 0.450 kg de Producto B")
  })

  it("describeHeldReturn en compra junta las líneas de un mismo producto", () => {
    expect(describeHeldReturn([saved("A", 3, "Producto A"), saved("A", 2, "Producto A")], "Centro", baseUnitOf, "purchase")).toBe(
      "Salen de Centro: 5 × Producto A",
    )
  })

  it("describeHeldReturn de venta no cambia", () => {
    expect(describeHeldReturn([saved("A", 3, "Producto A")], "Centro", baseUnitOf)).toBe("Vuelven a Centro: 3 × Producto A")
  })
})

describe("describeStockAdjustment en compra: 'Entran … · Salen …'", () => {
  it("subir una cantidad: sale lo aportado y entra lo nuevo (par espejo), las que SUMAN primero", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 2, "Producto A")],
      savedBranchId: "b-1",
      nextLines: [cartLine("A", 4, "Producto A")],
      nextBranchId: "b-1",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf, "purchase")).toBe(
      "Entran 4 × Producto A a Centro · Salen 2 × Producto A de Centro",
    )
  })

  it("cambio de sucursal: entra en la nueva y sale de la vieja, nombrando cada una", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 5, "Producto A")],
      savedBranchId: "b-1",
      nextLines: [cartLine("A", 5, "Producto A")],
      nextBranchId: "b-2",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf, "purchase")).toBe(
      "Entran 5 × Producto A a Godoy Cruz · Salen 5 × Producto A de Centro",
    )
  })

  it("producto agregado: sólo entra; producto quitado: sólo sale", () => {
    const added = computeStockAdjustment({
      savedItems: [],
      savedBranchId: "b-1",
      nextLines: [cartLine("A", 3, "Producto A")],
      nextBranchId: "b-1",
    })
    expect(describeStockAdjustment(added, branchName, baseUnitOf, "purchase")).toBe("Entran 3 × Producto A a Centro")

    const removed = computeStockAdjustment({
      savedItems: [saved("A", 3, "Producto A")],
      savedBranchId: "b-1",
      nextLines: [],
      nextBranchId: "b-1",
    })
    expect(describeStockAdjustment(removed, branchName, baseUnitOf, "purchase")).toBe("Salen 3 × Producto A de Centro")
  })

  it("editar sólo precio o notas no mueve stock (sin pares que cambian)", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 3, "Producto A")],
      savedBranchId: "b-1",
      nextLines: [cartLine("A", 3, "Producto A")],
      nextBranchId: "b-1",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf, "purchase")).toBe("Este cambio no mueve stock")
  })

  it("la venta conserva 'Vuelven … · Salen …'", () => {
    const adjustments = computeStockAdjustment({
      savedItems: [saved("A", 2, "Producto A")],
      savedBranchId: "b-1",
      nextLines: [cartLine("A", 4, "Producto A")],
      nextBranchId: "b-1",
    })
    expect(describeStockAdjustment(adjustments, branchName, baseUnitOf)).toBe(
      "Vuelven 2 × Producto A a Centro · Salen 4 × Producto A de Centro",
    )
  })
})

describe("purchaseMinimumByProduct — mínimo por producto en la edición", () => {
  const stockOf = (map: Record<string, number>) => (productId: string) => map[productId] ?? 0

  it("mínimo = aportado − stock vigente (10 aportadas, quedan 3 → no puede bajar de 7)", () => {
    const min = purchaseMinimumByProduct({ savedItems: [saved("A", 10)], savedBranchStockOf: stockOf({ A: 3 }) })
    expect(min.get("A")).toBe(7)
  })

  it("con el stock intacto o mayor que lo aportado no hay mínimo (max(0, …))", () => {
    const min = purchaseMinimumByProduct({
      savedItems: [saved("A", 10), saved("B", 4)],
      savedBranchStockOf: stockOf({ A: 10, B: 25 }),
    })
    expect(min.has("A")).toBe(false)
    expect(min.has("B")).toBe(false)
  })

  it("sin nada en la sucursal el mínimo es todo lo aportado", () => {
    const min = purchaseMinimumByProduct({ savedItems: [saved("A", 10)], savedBranchStockOf: stockOf({}) })
    expect(min.get("A")).toBe(10)
  })

  it("junta las líneas de un mismo producto (Σ quantity_base) y respeta decimales sin ruido binario", () => {
    const min = purchaseMinimumByProduct({
      savedItems: [saved("B", "0.3000"), saved("B", "0.4500")],
      savedBranchStockOf: stockOf({ B: 0.1 }),
    })
    expect(min.get("B")).toBe(0.65)
  })

  it("cada producto con su propio stock", () => {
    const min = purchaseMinimumByProduct({
      savedItems: [saved("A", 10), saved("B", 5)],
      savedBranchStockOf: stockOf({ A: 3, B: 5 }),
    })
    expect([...min.entries()]).toEqual([["A", 7]])
  })
})

describe("describePurchaseMinimum — el texto del mínimo (no atribuye origen)", () => {
  it("'En Centro quedan 3: este remito no puede bajar de 7'", () => {
    expect(describePurchaseMinimum(7, 3, "Centro", UN)).toBe("En Centro quedan 3: este remito no puede bajar de 7")
  })

  it("productos medibles llevan su unidad", () => {
    expect(describePurchaseMinimum(0.65, 0.1, "Centro", KG)).toBe(
      "En Centro quedan 0.100 kg: este remito no puede bajar de 0.650 kg",
    )
  })

  it("no habla de ventas ni de salidas: el stock de la sucursal mezcla otras entradas", () => {
    expect(describePurchaseMinimum(7, 3, "Centro", UN)).not.toMatch(/vendi|salieron|consumi/i)
  })
})

describe("purchaseBranchMoveBlockers — mover la recepción a otra sucursal", () => {
  const stockOf = (map: Record<string, number>) => (productId: string) => map[productId] ?? 0

  it("bloquea los productos que la sucursal vieja ya no tiene completos", () => {
    const blockers = purchaseBranchMoveBlockers({
      savedItems: [saved("A", 10, "Producto A"), saved("B", 2, "Producto B")],
      savedBranchStockOf: stockOf({ A: 3, B: 2 }),
    })
    expect(blockers).toEqual([{ productId: "A", productName: "Producto A", held: 10, remaining: 3 }])
  })

  it("si la sucursal vieja tiene todo lo aportado (o más), no bloquea", () => {
    expect(
      purchaseBranchMoveBlockers({
        savedItems: [saved("A", 10), saved("B", 2)],
        savedBranchStockOf: stockOf({ A: 10, B: 40 }),
      }),
    ).toEqual([])
  })

  it("describePurchaseBranchMove: 'En Centro quedan 3 de las 10 que entraron con este remito: no se puede mover a otra sucursal'", () => {
    expect(describePurchaseBranchMove({ productId: "A", productName: "Producto A", held: 10, remaining: 3 }, "Centro", UN)).toBe(
      "En Centro quedan 3 de las 10 que entraron con este remito: no se puede mover a otra sucursal",
    )
  })

  it("describePurchaseBranchMove con unidad medible", () => {
    expect(describePurchaseBranchMove({ productId: "B", productName: "Yerba", held: 2.5, remaining: 1 }, "Centro", KG)).toBe(
      "En Centro quedan 1 kg de los 2.500 kg que entraron con este remito: no se puede mover a otra sucursal",
    )
  })
})

describe("purchaseLinesBelowMinimum — qué impide guardar", () => {
  const minimums = new Map([["A", 7]])

  it("una línea por debajo del mínimo se reporta por nombre", () => {
    expect(
      purchaseLinesBelowMinimum({
        savedItems: [saved("A", 10, "Producto A")],
        minimums,
        nextLines: [cartLine("A", 5, "Producto A")],
      }),
    ).toEqual(["Producto A"])
  })

  it("exactamente el mínimo se puede guardar", () => {
    expect(
      purchaseLinesBelowMinimum({ savedItems: [saved("A", 10)], minimums, nextLines: [cartLine("A", 7)] }),
    ).toEqual([])
  })

  it("quitar la línea entera (0) con mínimo > 0 también está por debajo", () => {
    expect(purchaseLinesBelowMinimum({ savedItems: [saved("A", 10, "Producto A")], minimums, nextLines: [] })).toEqual(["Producto A"])
  })

  it("varias líneas del mismo producto cuentan sumadas", () => {
    expect(
      purchaseLinesBelowMinimum({
        savedItems: [saved("A", 10)],
        minimums,
        nextLines: [cartLine("A", 4), cartLine("A", 4)],
      }),
    ).toEqual([])
  })

  it("subir por encima de lo aportado nunca está por debajo del mínimo", () => {
    expect(
      purchaseLinesBelowMinimum({ savedItems: [saved("A", 10)], minimums, nextLines: [cartLine("A", 50)] }),
    ).toEqual([])
  })

  it("sin mínimos no se reporta nada", () => {
    expect(
      purchaseLinesBelowMinimum({ savedItems: [saved("A", 10)], minimums: new Map(), nextLines: [] }),
    ).toEqual([])
  })
})
