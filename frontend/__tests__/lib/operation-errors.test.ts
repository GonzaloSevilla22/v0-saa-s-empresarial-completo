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

    expect(out.message).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out.message).toContain("Showroom")
    expect(out.message).toContain("otra sucursal")
    expect(out.message).not.toContain(PRODUCT_ID) // el UUID no le sirve a nadie
  })

  it("traduce también la variante con sucursal explícita", () => {
    const out = humanizeOperationError(
      `insufficient_branch_stock for product ${PRODUCT_ID}`,
      lookup,
      "Principal",
    )

    expect(out.message).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out.message).toContain("Principal")
  })

  it("sin nombre resoluble, no inventa: habla de 'uno de los productos'", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, () => undefined)

    expect(out.message).toContain("uno de los productos")
    expect(out.message).toContain("sucursal")
  })

  it("sin sucursal conocida usa una redacción neutra", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, lookup, null)

    expect(out.message).toContain("la sucursal de esta operación")
  })

  it("un error que no reconoce se devuelve intacto y SIN acción (nunca oculta información)", () => {
    const original = "credit_requires_client: la venta a cuenta corriente exige un cliente"
    const out = humanizeOperationError(original, lookup)
    expect(out.message).toBe(original)
    expect(out.action).toBeUndefined()
  })

  it("mensaje vacío degrada a texto genérico, sin acción", () => {
    const out = humanizeOperationError("", lookup)
    expect(out.message).toBe("Error desconocido")
    expect(out.action).toBeUndefined()
  })

  // sucursal-guard-vaciado-auditoria (G3, task 7.4): el error de stock ofrece
  // un camino directo a transferir el producto involucrado.
  it("el error de stock por sucursal trae una acción hacia /stock con el producto preseleccionado", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, lookup, "Showroom")

    expect(out.action).toEqual({
      label: "Transferir stock",
      href: `/stock?product=${PRODUCT_ID}`,
    })
  })
})
