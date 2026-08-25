/**
 * Regresión prod 2026-08-24: el PO vio
 * `Insufficient stock for product 0dd2e5bb-...` con el producto SÍ en stock
 * (estaba en otra sucursal — la venta descuenta de la sucursal de la operación).
 */
import { describe, expect, it } from "vitest"

import { humanizeOperationError } from "@/lib/operation-errors"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
const lookup = (id: string) =>
  id === PRODUCT_ID ? "Top Pupera Liso Talle 1 Violeta" : undefined

describe("humanizeOperationError — stock por sucursal", () => {
  it("EL CASO DEL PO: nombra el producto y explica que es por sucursal", () => {
    const out = humanizeOperationError(
      `Insufficient stock for product ${PRODUCT_ID}`,
      lookup,
      "Showroom",
    )

    expect(out).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out).toContain("Showroom")
    expect(out).toContain("otra sucursal")
    expect(out).not.toContain(PRODUCT_ID) // el UUID no le sirve a nadie
  })

  it("traduce también la variante con sucursal explícita", () => {
    const out = humanizeOperationError(
      `insufficient_branch_stock for product ${PRODUCT_ID}`,
      lookup,
      "Principal",
    )

    expect(out).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out).toContain("Principal")
  })

  it("sin nombre resoluble, no inventa: habla de 'uno de los productos'", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, () => undefined)

    expect(out).toContain("uno de los productos")
    expect(out).toContain("sucursal")
  })

  it("sin sucursal conocida usa una redacción neutra", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, lookup, null)

    expect(out).toContain("la sucursal de esta operación")
  })

  it("un error que no reconoce se devuelve intacto (nunca oculta información)", () => {
    const original = "credit_requires_client: la venta a cuenta corriente exige un cliente"
    expect(humanizeOperationError(original, lookup)).toBe(original)
  })

  it("mensaje vacío degrada a texto genérico", () => {
    expect(humanizeOperationError("", lookup)).toBe("Error desconocido")
  })
})
