/**
 * productos-padre-variantes (D9, D11) — redondeo compartido con la base y
 * sugerencia de precio a partir del costo.
 *
 * `roundToPesos` es la contraparte TS de `public.product_round_price`
 * (round(x, 0), mitad hacia afuera del cero): una tabla de casos única
 * (`supabase/tests/fixtures/product_round_price_cases.json`) la leen este test
 * y el gate SQL, así los dos lenguajes no divergen.
 */

import fs from "node:fs"
import path from "node:path"
import { describe, it, expect } from "vitest"
import {
  SUGGESTED_MARKUP_FACTOR,
  roundToPesos,
  suggestPriceFromCost,
  nextPriceOnCostChange,
} from "@/lib/product-pricing"

const FIXTURE = path.resolve(
  __dirname, "..", "..", "..", "supabase", "tests", "fixtures", "product_round_price_cases.json",
)
const cases = JSON.parse(fs.readFileSync(FIXTURE, "utf8")) as { input: number; expected: number }[]

describe("roundToPesos (paridad con product_round_price)", () => {
  it("la tabla compartida no está vacía", () => {
    expect(cases.length).toBeGreaterThanOrEqual(10)
  })

  it.each(cases)("redondea $input a $expected", ({ input, expected }) => {
    expect(roundToPesos(input)).toBe(expected)
  })

  it("la mitad se aleja del cero en los dos signos (a diferencia de Math.round a secas)", () => {
    expect(roundToPesos(-2.5)).toBe(-3)
    expect(roundToPesos(2.5)).toBe(3)
  })

  it("un valor negativo que redondea a cero devuelve 0, no -0", () => {
    expect(Object.is(roundToPesos(-0.2), 0)).toBe(true)
  })
})

describe("suggestPriceFromCost", () => {
  it("el factor por defecto es 1,5", () => {
    expect(SUGGESTED_MARKUP_FACTOR).toBe(1.5)
  })

  it("costo × 1,5 redondeado a pesos enteros", () => {
    expect(suggestPriceFromCost(1000)).toBe(1500)
    expect(suggestPriceFromCost(333)).toBe(500) // 499,5 → 500
    expect(suggestPriceFromCost(0.5)).toBe(1) // 0,75 → 1
  })

  it("acepta un factor propio", () => {
    expect(suggestPriceFromCost(1000, 2)).toBe(2000)
  })

  it.each([null, undefined, 0, -10, Number.NaN, Number.POSITIVE_INFINITY])(
    "sin costo utilizable (%s) no sugiere nada",
    (cost) => {
      expect(suggestPriceFromCost(cost as number | null)).toBeNull()
    },
  )
})

describe("nextPriceOnCostChange (nunca pisa un precio escrito)", () => {
  it("precio vacío o 0: toma la sugerencia y la recuerda", () => {
    expect(nextPriceOnCostChange({ cost: 1000, price: 0, lastSuggested: null }))
      .toEqual({ price: 1500, lastSuggested: 1500 })
  })

  it("precio igual a la última sugerencia: la actualiza con el costo nuevo", () => {
    expect(nextPriceOnCostChange({ cost: 2000, price: 1500, lastSuggested: 1500 }))
      .toEqual({ price: 3000, lastSuggested: 3000 })
  })

  it("precio escrito a mano (distinto de la sugerencia): no se toca", () => {
    expect(nextPriceOnCostChange({ cost: 2000, price: 1700, lastSuggested: 1500 }))
      .toEqual({ price: 1700, lastSuggested: 1500 })
  })

  it("precio escrito y sin sugerencia previa (edición con precio): no se toca", () => {
    expect(nextPriceOnCostChange({ cost: 2000, price: 900, lastSuggested: null }))
      .toEqual({ price: 900, lastSuggested: null })
  })

  it("costo borrado: conserva el precio vigente (no lo vacía)", () => {
    expect(nextPriceOnCostChange({ cost: null, price: 1500, lastSuggested: 1500 }))
      .toEqual({ price: 1500, lastSuggested: 1500 })
  })
})
