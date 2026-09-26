/**
 * ventas-unidades-conversion (task 4.2): los tres tokens P0400 que emite
 * `_uom_normalize_quantity` (la única definición de conversión de unidades)
 * llegan al usuario con un mensaje accionable en vez del literal con uuids.
 */
import { describe, expect, it } from "vitest"

import { humanizeOperationError } from "@/lib/operation-errors"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
const UNIT_ID = "11111111-2222-3333-4444-555555555555"
const BASE_ID = "66666666-7777-8888-9999-000000000000"

const lookup = (id: string) => (id === PRODUCT_ID ? "Tomate" : undefined)

describe("humanizeOperationError — unidades de medida", () => {
  it("unit_type_mismatch: nombra el producto y explica que los tipos no se convierten", () => {
    const raw = `unit_type_mismatch: la unidad ${UNIT_ID} (volume) no es del mismo tipo que la unidad base ${BASE_ID} (weight) del producto ${PRODUCT_ID}`
    const out = humanizeOperationError(raw, lookup)
    expect(out.message).toContain("«Tomate»")
    expect(out.message).toContain("no es del mismo tipo")
    expect(out.message).not.toContain(PRODUCT_ID)
    expect(out.action).toBeUndefined()
  })

  it("unit_requires_base_unit: explica la salida y ofrece ir al producto", () => {
    const raw = `unit_requires_base_unit: la unidad ${UNIT_ID} (factor 0.0010000000) no es una unidad base y el producto ${PRODUCT_ID} no declara unidad base`
    const out = humanizeOperationError(raw, lookup)
    expect(out.message).toContain("«Tomate»")
    expect(out.message).toContain("unidad base")
    expect(out.action).toEqual({ label: "Editar producto", href: `/productos?q=${PRODUCT_ID}` })
  })

  it("quantity_below_precision: pide una cantidad mayor", () => {
    const raw = `quantity_below_precision: la cantidad 0.00004 en la unidad ${UNIT_ID} equivale a 0 en la unidad base del producto ${PRODUCT_ID}`
    const out = humanizeOperationError(raw, lookup)
    expect(out.message).toContain("«Tomate»")
    expect(out.message).toContain("demasiado chica")
  })

  it("sin lookup del nombre no imprime el uuid crudo", () => {
    const raw = `unit_type_mismatch: la unidad ${UNIT_ID} (volume) no es del mismo tipo que la unidad base ${BASE_ID} (weight) del producto ${PRODUCT_ID}`
    const out = humanizeOperationError(raw)
    expect(out.message).toContain("este producto")
    expect(out.message).not.toContain(PRODUCT_ID)
  })

  it("un error ajeno sigue pasando tal cual", () => {
    expect(humanizeOperationError("otra cosa").message).toBe("otra cosa")
  })
})
