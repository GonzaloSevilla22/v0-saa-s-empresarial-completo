/**
 * ventas-unidades-conversion (task 4.1): `lib/unit-utils` es el espejo exacto
 * de `_uom_normalize_quantity` (la única definición SQL) para la validación
 * local de stock y para el selector de unidades compatible.
 */
import { describe, expect, it } from "vitest"

import { compatibleUnits, isBaseUnit, isUnitCompatible, toBaseQuantity } from "@/lib/unit-utils"
import type { UnitOfMeasure } from "@/lib/types"

const kg: UnitOfMeasure = { id: "kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const g: UnitOfMeasure = { id: "g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "kg", isSystem: true }
const tn: UnitOfMeasure = { id: "tn", name: "Tonelada", symbol: "tn", type: "weight", factor: 1000, baseUnitId: "kg", isSystem: true }
const L: UnitOfMeasure = { id: "L", name: "Litro", symbol: "L", type: "volume", factor: 1, isSystem: true }
const mL: UnitOfMeasure = { id: "mL", name: "Mililitro", symbol: "mL", type: "volume", factor: 0.001, baseUnitId: "L", isSystem: true }
const m: UnitOfMeasure = { id: "m", name: "Metro", symbol: "m", type: "length", factor: 1, isSystem: true }
const cm: UnitOfMeasure = { id: "cm", name: "Centímetro", symbol: "cm", type: "length", factor: 0.01, baseUnitId: "m", isSystem: true }
const u: UnitOfMeasure = { id: "u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const doc: UnitOfMeasure = { id: "doc", name: "Docena", symbol: "doc", type: "unit", factor: 12, baseUnitId: "u", isSystem: true }
const cj6: UnitOfMeasure = { id: "cj6", name: "Caja x 6", symbol: "cj6", type: "unit", factor: 6, baseUnitId: "u", isSystem: true }

const ALL = [cm, m, u, cj6, doc, mL, L, g, kg, tn]

describe("toBaseQuantity — relativa a la unidad base del PRODUCTO (D1)", () => {
  it("base kg + 450 g → 0.45 (el caso de la verdulería)", () => {
    expect(toBaseQuantity(450, g, kg)).toBe(0.45)
  })
  it("misma unidad que la base → identidad exacta", () => {
    expect(toBaseQuantity(0.45, kg, kg)).toBe(0.45)
  })
  it("base g + 0.5 kg → 500 (relativa al producto, no al tipo)", () => {
    expect(toBaseQuantity(0.5, kg, g)).toBe(500)
  })
  it("base kg + 0.002 tn → 2", () => {
    expect(toBaseQuantity(0.002, tn, kg)).toBe(2)
  })
  it("base u + 2 docenas → 24", () => {
    expect(toBaseQuantity(2, doc, u)).toBe(24)
  })
  it("sin unidad → factor 1; sin base → factor de la unidad (status quo)", () => {
    expect(toBaseQuantity(3, undefined)).toBe(3)
    expect(toBaseQuantity(3, undefined, kg)).toBe(3)
    expect(toBaseQuantity(2, kg, undefined)).toBe(2)
  })
  it("redondea a 4 decimales: 450 × 0.001 no arrastra ruido binario", () => {
    expect(toBaseQuantity(450, g, kg)).toBe(0.45)
    expect(toBaseQuantity(3, g, kg)).toBe(0.003)
    expect(toBaseQuantity(0.1, g, kg)).toBe(0.0001)
  })
})

describe("compatibleUnits — la única regla del selector (D3/D5)", () => {
  it("producto en kg ofrece sólo peso: kg, g, tn", () => {
    expect(compatibleUnits(ALL, kg).map((x) => x.id)).toEqual(["g", "kg", "tn"])
  })
  it("producto en litros ofrece sólo volumen", () => {
    expect(compatibleUnits(ALL, L).map((x) => x.id)).toEqual(["mL", "L"])
  })
  it("producto por unidad ofrece u, cj6 y doc", () => {
    expect(compatibleUnits(ALL, u).map((x) => x.id)).toEqual(["u", "cj6", "doc"])
  })
  it("producto sin unidad base ofrece sólo unidades base (factor 1, sin padre)", () => {
    expect(compatibleUnits(ALL, undefined).map((x) => x.id)).toEqual(["m", "u", "L", "kg"])
    expect(compatibleUnits(ALL, null).map((x) => x.id)).toEqual(["m", "u", "L", "kg"])
  })
  it("una unidad con factor 1 pero con padre no es base", () => {
    const alias: UnitOfMeasure = { ...kg, id: "kg2", baseUnitId: "kg" }
    expect(isBaseUnit(alias)).toBe(false)
    expect(compatibleUnits([...ALL, alias], undefined).map((x) => x.id)).not.toContain("kg2")
  })
})

describe("isUnitCompatible — para invalidar la unidad elegida al cambiar de producto", () => {
  it("g sobre kg sí; g sobre L no; g sin base no; kg sin base sí", () => {
    expect(isUnitCompatible(g, kg)).toBe(true)
    expect(isUnitCompatible(g, L)).toBe(false)
    expect(isUnitCompatible(g, undefined)).toBe(false)
    expect(isUnitCompatible(kg, undefined)).toBe(true)
    expect(isUnitCompatible(undefined, kg)).toBe(true)
  })
})
