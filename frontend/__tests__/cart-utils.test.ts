import { describe, it, expect } from "vitest"
import { unitPriceFromSubtotal, calcSaleSubtotal } from "@/lib/cart-utils"

describe("unitPriceFromSubtotal", () => {
  it("con cantidad 1 devuelve el subtotal como precio unitario", () => {
    expect(unitPriceFromSubtotal(45000, 1)).toBe(45000)
  })

  it("reparte el subtotal entre la cantidad (caso divisible)", () => {
    expect(unitPriceFromSubtotal(45000, 3)).toBe(15000)
  })

  // ventas-unidades-conversion, tercera revisión (D-F′): el precio unitario
  // derivado del subtotal conserva su precisión (sólo se limpia el ruido
  // binario, 15 dígitos significativos). Con 4 decimales, un subtotal tipeado
  // sobre una línea en gramos no se reproducía: 2000 / 450 g = 4,4444 →
  // 4,4444 × 450 = $1.999,98 (antes: "redondea a 4 decimales", 3333,3333).
  it("no divisible: conserva la precisión del precio (sólo limpia el ruido binario)", () => {
    expect(unitPriceFromSubtotal(10000, 3)).toBe(3333.33333333333)
  })

  it("un subtotal tipeado sobre una línea en gramos se reproduce al centavo: $2.000 por 450 g", () => {
    const unitPrice = unitPriceFromSubtotal(2000, 450)
    expect(calcSaleSubtotal(unitPrice, 450, 0)).toBe(2000)
  })

  it("triangulación: $10.000 por 3 u vuelve a dar $10.000 (con 4 decimales: $9.999,9999)", () => {
    expect(calcSaleSubtotal(unitPriceFromSubtotal(10000, 3), 3, 0)).toBe(10000)
  })

  it("soporta cantidades fraccionarias (medibles)", () => {
    expect(unitPriceFromSubtotal(5000, 2.5)).toBe(2000)
  })

  it("devuelve 0 si la cantidad es 0 o negativa (sin dividir por cero)", () => {
    expect(unitPriceFromSubtotal(45000, 0)).toBe(0)
    expect(unitPriceFromSubtotal(45000, -1)).toBe(0)
  })

  it("es la inversa de calcSaleSubtotal sin descuento (roundtrip)", () => {
    const subtotal = 45000
    const qty = 3
    const unitPrice = unitPriceFromSubtotal(subtotal, qty)
    expect(calcSaleSubtotal(unitPrice, qty, 0)).toBe(subtotal)
  })
})
