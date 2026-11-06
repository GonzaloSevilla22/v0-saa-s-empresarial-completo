import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// productos-padre-variantes (task 9.4): los rechazos tipados del catálogo de
// productos salen por el mapa canónico de errores (castellano accionable), no
// por el texto técnico del backend. Mismo mapa que venta, compra y remito.

const CTX = { documentLabel: "producto" } as const

describe("humanizeOperationError — catálogo de productos (padre, unidad y precios en lote)", () => {
  it("parent_field_not_allowed explica que esos datos se cargan en cada variante", () => {
    const { message, action } = humanizeOperationError("parent_field_not_allowed", undefined, undefined, CTX)
    expect(message).toMatch(/variante/i)
    expect(message).toMatch(/precio/i)
    expect(message).not.toContain("parent_field_not_allowed")
    expect(action).toBeUndefined()
  })

  it("parent_field_not_allowed también se reconoce dentro del detail del servidor", () => {
    const { message } = humanizeOperationError(
      "parent_field_not_allowed: un producto con variantes no lleva price (field=price)",
      undefined, undefined, CTX,
    )
    expect(message).toMatch(/cada variante/i)
  })

  it("stock_control_type_locked dice que el tipo no se cambia y qué hacer", () => {
    const { message } = humanizeOperationError("stock_control_type_locked", undefined, undefined, CTX)
    expect(message).toMatch(/tipo/i)
    expect(message).toMatch(/crear|nuevo/i)
    expect(message).not.toContain("stock_control_type_locked")
  })

  it("unit_relabel_conflict explica que hay ventas o compras en otra unidad", () => {
    const { message } = humanizeOperationError("unit_relabel_conflict", undefined, undefined, CTX)
    expect(message).toMatch(/otra unidad/i)
    expect(message).not.toContain("unit_relabel_conflict")
  })

  it("base_unit_not_found: la unidad elegida ya no está disponible", () => {
    expect(humanizeOperationError("base_unit_not_found", undefined, undefined, CTX).message).toMatch(/unidad/i)
  })

  it.each([
    ["bulk_price_out_of_range", /entre|rango|porcentaje/i],
    ["bulk_price_too_many_ids", /500|demasiados/i],
    ["bulk_price_invalid_mode", /modo|dirección|valor/i],
  ])("%s tiene un texto accionable y no se muestra crudo", (code, expected) => {
    const { message } = humanizeOperationError(code, undefined, undefined, CTX)
    expect(message).toMatch(expected)
    expect(message).not.toContain(code)
  })

  it("insufficient_role en el catálogo dice que es de dueño o administrador (no habla de ventas)", () => {
    const { message } = humanizeOperationError("insufficient_role", undefined, undefined, CTX)
    expect(message).toMatch(/administrador|dueño/i)
    expect(message).not.toMatch(/ventas ni compras/i)
  })

  it("TRIANGULATE: sin el contexto de producto, insufficient_role conserva su texto de siempre", () => {
    const { message } = humanizeOperationError("insufficient_role")
    expect(message).not.toMatch(/catálogo/i)
  })
})
