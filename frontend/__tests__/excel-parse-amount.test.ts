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
import { parseAmount, parseAmountString, looksLikeThousandsGrouping } from "@/lib/excel"

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

describe("parseAmount — parenthesesNegative (candidatos-importadores, extracto bancario)", () => {
  it('"(1.234,56)" con parenthesesNegative → -1234.56', () => {
    expect(parseAmount("(1.234,56)", { parenthesesNegative: true })).toBe(-1234.56)
  })

  it('"(1.234,56)" SIN la opción → 1234.56 POSITIVO (paréntesis tratados como ruido por cleanNumericText, sin la opción no hay signo que preservar)', () => {
    expect(parseAmount("(1.234,56)")).toBe(1234.56)
  })

  it('"-350" con la opción sigue funcionando igual (paréntesis y "-" son independientes)', () => {
    expect(parseAmount("-350", { parenthesesNegative: true })).toBe(-350)
  })
})

describe("parseAmountString — helper canónico que preserva precisión (RN-D4, extracto bancario)", () => {
  it.each([
    ["1.234,56", "1234.56"],
    ["1,234.56", "1234.56"],
    ["-350", "-350"],
    ["-350,00", "-350.00"],
    ["$ -1.234,56", "-1234.56"],
    ["1234.56", "1234.56"],
    ["100.5", "100.5"],
  ])('"%s" → "%s" (string, sin pasar por float)', (raw, expected) => {
    expect(parseAmountString(raw, { loneCommaIsDecimal: true, parenthesesNegative: true })).toBe(expected)
  })

  it.each([["abc"], [""], ["   "]])('"%s" → null', (raw) => {
    expect(parseAmountString(raw)).toBeNull()
  })

  it("undefined → null", () => {
    expect(parseAmountString(undefined)).toBeNull()
  })

  it('"(1.234,56)" con parenthesesNegative → "-1234.56"', () => {
    expect(parseAmountString("(1.234,56)", { parenthesesNegative: true })).toBe("-1234.56")
  })

  it("preserva ceros decimales que un float perdería (0.10 no se convierte en 0.1)", () => {
    expect(parseAmountString("0,10", { loneCommaIsDecimal: true })).toBe("0.10")
  })

  it('"1.2.3" (2+ puntos) → null, nunca un valor parcial silencioso', () => {
    expect(parseAmountString("1.2.3", { loneCommaIsDecimal: true })).toBeNull()
    expect(parseAmount("1.2.3")).not.toBeNaN() // parseFloat parcial: 1.2 (comportamiento preexistente de parseAmount, sin cambios)
  })

  it('"12x" (letra residual real) → null — F2: antes el título del test no ejercitaba este caso y "12x" se colaba como 12', () => {
    expect(parseAmountString("12x")).toBeNull()
  })
})

describe('parseAmountString — F1 (BLOCKER): "$" antes del paréntesis no debe perder el signo negativo', () => {
  it('"$ (1.234,56)" con parenthesesNegative → "-1234.56" (regresión: daba "1234.56" sin el signo)', () => {
    expect(
      parseAmountString("$ (1.234,56)", { loneCommaIsDecimal: true, parenthesesNegative: true }),
    ).toBe("-1234.56")
  })

  it('"$(100)" con parenthesesNegative → "-100" (sin espacio entre $ y el paréntesis)', () => {
    expect(parseAmountString("$(100)", { parenthesesNegative: true })).toBe("-100")
  })
})

describe("parseAmountString — F2 (MAJOR): un sufijo/prefijo de letras descarta el valor en vez de leerlo en silencio", () => {
  it('"1.234,56 D" → null (antes se importaba en silencio como "1234.56")', () => {
    expect(
      parseAmountString("1.234,56 D", { loneCommaIsDecimal: true, parenthesesNegative: true }),
    ).toBeNull()
  })

  it('"ARS (100)" → null (antes daba "100" POSITIVO: perdía el signo Y aceptaba texto)', () => {
    expect(parseAmountString("ARS (100)", { parenthesesNegative: true })).toBeNull()
  })

  it('"12 kg" / "kg 12" → null (sufijo/prefijo de unidad, mismo defecto que "D"/"ARS")', () => {
    expect(parseAmountString("12 kg")).toBeNull()
    expect(parseAmountString("kg 12")).toBeNull()
  })

  it('"$ 1.234,56" (sólo el ruido admitido: "$" y espacios) sigue funcionando', () => {
    expect(parseAmountString("$ 1.234,56", { loneCommaIsDecimal: true })).toBe("1234.56")
  })
})

describe("parseAmount / parseAmountString — F7: el signo no debe divergir entre paréntesis y '-' interno", () => {
  it('parseAmount("(-100)", {parenthesesNegative:true}) → -100 (antes daba 100 por doble negativo)', () => {
    expect(parseAmount("(-100)", { parenthesesNegative: true })).toBe(-100)
  })

  it('parseAmountString("(-100)", {parenthesesNegative:true}) → "-100" (ya se comportaba así — referencia)', () => {
    expect(parseAmountString("(-100)", { parenthesesNegative: true })).toBe("-100")
  })
})

describe("looksLikeThousandsGrouping — separator opcional (R1, importador de productos)", () => {
  it('"1.500" con separator "." → true', () => {
    expect(looksLikeThousandsGrouping("1.500", ".")).toBe(true)
  })

  it('"1,500" con separator "." → false (separador distinto al pedido)', () => {
    expect(looksLikeThousandsGrouping("1,500", ".")).toBe(false)
  })

  it('"1.234.567" con separator "." → true (varios grupos)', () => {
    expect(looksLikeThousandsGrouping("1.234.567", ".")).toBe(true)
  })
})
