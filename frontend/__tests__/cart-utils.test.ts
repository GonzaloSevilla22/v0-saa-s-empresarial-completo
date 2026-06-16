import { describe, it, expect } from "vitest"
import { unitPriceFromSubtotal, calcSaleSubtotal } from "@/lib/cart-utils"

describe("unitPriceFromSubtotal", () => {
  it("con cantidad 1 devuelve el subtotal como precio unitario", () => {
    expect(unitPriceFromSubtotal(45000, 1)).toBe(45000)
  })

  it("reparte el subtotal entre la cantidad (caso divisible)", () => {
    expect(unitPriceFromSubtotal(45000, 3)).toBe(15000)
  })

  it("redondea a 4 decimales cuando no es divisible", () => {
    expect(unitPriceFromSubtotal(10000, 3)).toBe(3333.3333)
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
