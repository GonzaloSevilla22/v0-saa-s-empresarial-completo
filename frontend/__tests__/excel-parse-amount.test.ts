/**
 * `parseAmount` (`lib/excel`) — helper canónico de números en CSV/XLSX.
 *
 * Por defecto está pensado para IMPORTES: una coma sin punto seguida de tres
 * dígitos se lee como separador de miles ("1,250" → 1250), porque en pesos
 * tres decimales no existen. Para CANTIDADES FÍSICAS (stock en kg, litros,
 * metros) tres decimales son normales, así que la opción `loneCommaIsDecimal`
 * hace que la coma sin punto sea siempre decimal ("1,250" → 1.25).
 *
 * Los casos por defecto fijan el comportamiento que ya consumen los
 * importadores de productos (precio/costo) y gastos (monto).
 */
import { describe, it, expect } from "vitest"
import { parseAmount } from "@/lib/excel"

describe("parseAmount — comportamiento por defecto (importes)", () => {
  it.each([
    ["1,5", 1.5],
    ["2,50", 2.5],
    ["1.234,56", 1234.56],
    ["1,234.56", 1234.56],
    ["1,250", 1250],
    ["1234.56", 1234.56],
    ["12", 12],
  ])('"%s" → %s', (raw, expected) => {
    expect(parseAmount(raw)).toBe(expected)
  })

  it.each([["abc"], [""], ["   "]])('"%s" → NaN', (raw) => {
    expect(Number.isNaN(parseAmount(raw))).toBe(true)
  })

  it("undefined → NaN", () => {
    expect(Number.isNaN(parseAmount(undefined))).toBe(true)
  })
})

describe("parseAmount — loneCommaIsDecimal (cantidades físicas)", () => {
  const opts = { loneCommaIsDecimal: true }

  it.each([
    ["1,250", 1.25],
    ["3,999", 3.999],
    ["0,750", 0.75],
    ["1,2345", 1.2345],
    ["1,5", 1.5],
    ["2,50", 2.5],
    [",5", 0.5],
    ["12,", 12],
  ])('"%s" → %s (coma sin punto = decimal, sin heurística de miles)', (raw, expected) => {
    expect(parseAmount(raw, opts)).toBe(expected)
  })

  it.each([
    ["1.234,567", 1234.567],
    ["1,234.56", 1234.56],
    ["1.5", 1.5],
    ["12", 12],
    ["-1,5", -1.5],
  ])('"%s" → %s (el resto de los formatos no cambia)', (raw, expected) => {
    expect(parseAmount(raw, opts)).toBe(expected)
  })

  it('"1,5,2" (más de una coma sin punto) → NaN, no 152', () => {
    expect(Number.isNaN(parseAmount("1,5,2", opts))).toBe(true)
  })

  it("con la opción en false conserva la heurística de miles", () => {
    expect(parseAmount("1,250", { loneCommaIsDecimal: false })).toBe(1250)
  })
})
