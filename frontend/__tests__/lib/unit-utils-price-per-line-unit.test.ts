/**
 * Corrección del PR #584 (hallazgo BLOQUEANTE de la segunda revisión,
 * "el importe ignora la conversión de unidades"): el precio de una línea es
 * POR UNIDAD DE LA LÍNEA (contrato D-F, provisorio hasta el sign-off del PO) —
 * así `amount × quantity` sigue siendo el total que el servidor recalcula en
 * `rpc_create_sale_operation` y el `subtotal` que `_c29_confirm_order_core`
 * toma del cliente, igual que en las 1.018 ventas históricas.
 *
 * El precio del catálogo está en la unidad BASE del producto; al elegir otra
 * unidad se re-expresa con el MISMO factor que `toBaseQuantity`, así que
 * precio(línea) × cantidad(línea) = precio(base) × cantidad(base).
 */
import { describe, expect, it } from "vitest"

import { convertUnitPrice, toBaseQuantity } from "@/lib/unit-utils"
import type { UnitOfMeasure } from "@/lib/types"

const kg: UnitOfMeasure = { id: "kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const g: UnitOfMeasure = { id: "g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "kg", isSystem: true }
const u: UnitOfMeasure = { id: "u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const doc: UnitOfMeasure = { id: "doc", name: "Docena", symbol: "doc", type: "unit", factor: 12, baseUnitId: "u", isSystem: true }

describe("convertUnitPrice — el precio se re-expresa en la unidad de la línea", () => {
  it("$1.800/kg → gramo: $1,80 por g (100 g cobran $180, no $180.000)", () => {
    const perGram = convertUnitPrice(1800, kg, g, kg)
    expect(perGram).toBe(1.8)
    expect(perGram * 100).toBeCloseTo(180, 4)
  })

  it("$100/u → Docena: $1.200 por docena", () => {
    expect(convertUnitPrice(100, u, doc, u)).toBe(1200)
  })

  it("costo $900/kg → gramo: 500 g cuestan $450", () => {
    expect(convertUnitPrice(900, kg, g, kg) * 500).toBeCloseTo(450, 4)
  })

  it("vuelta atrás: gramo → kg devuelve el precio original (el usuario cambia de idea)", () => {
    expect(convertUnitPrice(convertUnitPrice(1800, kg, g, kg), g, kg, kg)).toBe(1800)
  })

  it("misma unidad, o sin unidad en ambas puntas → identidad", () => {
    expect(convertUnitPrice(1234.5, kg, kg, kg)).toBe(1234.5)
    expect(convertUnitPrice(1234.5, undefined, undefined, undefined)).toBe(1234.5)
  })

  it("'sin unidad' equivale a la unidad base del producto (espejo de toBaseQuantity)", () => {
    expect(convertUnitPrice(1800, undefined, g, kg)).toBe(1.8)
    expect(convertUnitPrice(1.8, g, undefined, kg)).toBe(1800)
  })

  it("invariante: precio(línea) × cantidad(línea) = precio(base) × cantidad(base)", () => {
    const qtyLine = 450
    const priceBase = 1800
    const priceLine = convertUnitPrice(priceBase, kg, g, kg)
    expect(priceLine * qtyLine).toBeCloseTo(priceBase * toBaseQuantity(qtyLine, g, kg), 4)
  })
})
