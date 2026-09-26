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

import { calcSaleSubtotal } from "@/lib/cart-utils"
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

/**
 * Tercera revisión del PR #584 (MAJOR "precisión del precio", contrato D-F′,
 * provisorio hasta el sign-off del PO): re-expresado a una unidad chica, un
 * precio de catálogo con centavos necesita MÁS de 4 decimales — $1.234,56/kg
 * son $1,23456/g. Redondeado a 4 (1,2346), 450 g cobraban $555,57 en vez de
 * $555,552 → $555,55: el error crece con la cantidad (en mg, 1000×). El
 * precio de la línea conserva su precisión; sólo se limpia el ruido binario.
 */
const mg: UnitOfMeasure = { id: "mg", name: "Miligramo", symbol: "mg", type: "weight", factor: 0.000001, baseUnitId: "kg", isSystem: false }

describe("convertUnitPrice — D-F′: el precio de la línea no se redondea", () => {
  it("$1.234,56/kg → gramo: $1,23456 (no 1,2346)", () => {
    expect(convertUnitPrice(1234.56, kg, g, kg)).toBe(1.23456)
  })

  it("$4.575/kg → gramo: $4,575, y 100 g cobran exactamente $457,50", () => {
    const perGram = convertUnitPrice(4575, kg, g, kg)
    expect(perGram).toBe(4.575)
    expect(calcSaleSubtotal(perGram, 100, 0)).toBe(457.5)
  })

  it("450 g a $1.234,56/kg: el subtotal es $555,552, el mismo que 0,45 kg × $1.234,56 (antes 555,57)", () => {
    const perGram = convertUnitPrice(1234.56, kg, g, kg)
    expect(calcSaleSubtotal(perGram, 450, 0)).toBe(calcSaleSubtotal(1234.56, 0.45, 0))
    expect(calcSaleSubtotal(perGram, 450, 0)).toBe(555.552)
  })

  it("miligramo: $1.234,56/kg → $0,00123456/mg (con 4 decimales era $0,0012 — 450.000 mg cobraban $540)", () => {
    const perMg = convertUnitPrice(1234.56, kg, mg, kg)
    expect(perMg).toBe(0.00123456)
    expect(calcSaleSubtotal(perMg, 450_000, 0)).toBe(555.552)
  })

  it("ida y vuelta kg → g → kg restituye el precio con centavos exacto", () => {
    expect(convertUnitPrice(convertUnitPrice(1234.56, kg, g, kg), g, kg, kg)).toBe(1234.56)
  })

  it("limpia el ruido binario: $1,10/kg → $0,0011/g (1.1 × 0.001 = 0.0011000000000000001 en coma flotante)", () => {
    expect(convertUnitPrice(1.1, kg, g, kg)).toBe(0.0011)
  })
})
