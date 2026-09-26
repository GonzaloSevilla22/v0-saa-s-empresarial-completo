/**
 * formatUnitPrice — el precio UNITARIO con la precisión que tiene
 * (ventas-unidades-conversion, cuarta revisión del PR #584, D-F′).
 *
 * Con D-F el precio de una línea es por unidad DE LA LÍNEA: $4.575/kg vendido
 * en gramos es $4,575/g. `formatMoney` corta en 2 decimales, así que el ticket
 * y el listado mostraban "100 g × $4,58 = $457,50" (100 × 4,58 = 458) y
 * "333 g × $1 = $332,67". Un precio al centavo se sigue mostrando igual que
 * con formatMoney; uno sub-centavo, con hasta 5 decimales (la precisión que
 * roundUnitPrice conserva), sin ruido binario.
 */
import { describe, it, expect } from "vitest"
import { formatMoney, formatUnitPrice } from "@/lib/format"

const plain = (s: string) => s.replace(/\u00a0/g, " ")

describe("formatUnitPrice", () => {
  it("precio sub-centavo en ARS: $4,575/g y $1,23456/g, con toda su precisión", () => {
    expect(plain(formatUnitPrice(4.575))).toBe("$ 4,575")
    expect(plain(formatUnitPrice(1.23456))).toBe("$ 1,23456")
    expect(plain(formatUnitPrice(0.999))).toBe("$ 0,999")
  })

  it("precio al centavo: idéntico a formatMoney (no cambia ningún ticket existente)", () => {
    for (const v of [1.8, 1800, 1234.56, 0, 99.9, 4.58]) {
      expect(formatUnitPrice(v)).toBe(formatMoney(v))
    }
  })

  it("ruido binario y más de 5 decimales: se muestra limpio, a 5 decimales como máximo", () => {
    expect(plain(formatUnitPrice(4.575 * (1 - 10 / 100)))).toBe("$ 4,1175")
    expect(plain(formatUnitPrice(1.234567))).toBe("$ 1,23457")
  })

  it("respeta la moneda (USD en en-US)", () => {
    expect(plain(formatUnitPrice(0.125, "USD"))).toBe("$0.125")
    expect(formatUnitPrice(12.5, "USD")).toBe(formatMoney(12.5, "USD"))
  })
})
