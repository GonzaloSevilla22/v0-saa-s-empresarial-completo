import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// stock-edicion-sucursal-piso (R2): dos rechazos de la EDICIÓN de una operación que antes
// terminaban en un 23514 (branch_stock_quantity_non_negative) y el backend devolvía como un 422
// genérico («Los datos no cumplen las restricciones de la base de datos»):
//
//   - rpc_atomic_update_sale_operation: el gate de stock pasó a ser POR SUCURSAL y rechaza con
//     los mismos literales P0409 del alta (`insufficient_branch_stock for product <uuid>` con
//     sucursal explícita, `Insufficient stock for product <uuid>` sin ella) — los que ya traduce
//     STOCK_ERROR. Estos tests fijan que la edición queda cubierta por ese mapa.
//   - rpc_atomic_update_purchase_operation: el chequeo previo de la reversa rechaza con
//     `purchase_edit_stock_consumed: de <producto> en la sucursal quedan X y la edición necesita
//     restar Y` (P0409), que sin mapeo el usuario vería crudo.

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"

describe("humanizeOperationError — editar una compra cuya mercadería ya se vendió", () => {
  const RAW = "purchase_edit_stock_consumed: de Yerba mate 1kg en la sucursal quedan 2.0000 y la edición necesita restar 4.0000"

  it("explica cuánto queda y cuánto habría que restar, sin el literal interno", () => {
    const { message, action } = humanizeOperationError(RAW)
    expect(message).toContain("«Yerba mate 1kg»")
    expect(message).toMatch(/quedan 2\b/)
    expect(message).toMatch(/restar 4\b/)
    expect(message).toMatch(/ya se vendi/i)
    expect(message).not.toContain("purchase_edit_stock_consumed")
    expect(message).not.toMatch(/\d\.0000/)
    expect(action).toBeDefined()
  })

  it("dice qué hacer: borrar la compra y volver a cargarla, o ajustar el stock; y que no se guardó nada", () => {
    const { message, action } = humanizeOperationError(RAW)
    expect(message).toMatch(/borr[aá] la compra/i)
    expect(message).toMatch(/ajust[aá] el stock/i)
    expect(message).toMatch(/no se guard[oó] ning[uú]n cambio/i)
    expect(action?.label).toBe("Ajustar stock")
    expect(action?.href).toBe("/stock")
  })

  it("un nombre con paréntesis y dos puntos no corta la captura", () => {
    const { message } = humanizeOperationError(
      "purchase_edit_stock_consumed: de Café (molido): 500g en la sucursal quedan 0.5000 y la edición necesita restar 3.0000",
    )
    expect(message).toContain("«Café (molido): 500g»")
    expect(message).toMatch(/quedan 0,5\b/)
    expect(message).toMatch(/restar 3\b/)
  })

  it("si el servidor mandó el id (producto sin nombre), resuelve el nombre con el lookup y, sin él, dice «uno de los productos»", () => {
    const withId = `purchase_edit_stock_consumed: de ${PRODUCT_ID} en la sucursal quedan 1.0000 y la edición necesita restar 2.0000`
    const lookup = (id: string) => (id === PRODUCT_ID ? "Aceite 500ml" : undefined)
    expect(humanizeOperationError(withId, lookup).message).toContain("«Aceite 500ml»")
    const sinLookup = humanizeOperationError(withId).message
    expect(sinLookup).toContain("uno de los productos")
    expect(sinLookup).not.toContain(PRODUCT_ID)
  })

  it("el literal sin cantidades (versión recortada) también se traduce, sin el token", () => {
    const { message } = humanizeOperationError("purchase_edit_stock_consumed")
    expect(message).toMatch(/ya se vendi/i)
    expect(message).not.toContain("purchase_edit_stock_consumed")
  })
})

describe("humanizeOperationError — editar una venta con la sucursal sin stock (gate por sucursal)", () => {
  it("«Insufficient stock for product <id>» (edición sin sucursal explícita) se traduce con el nombre del producto", () => {
    const { message, action } = humanizeOperationError(
      `Insufficient stock for product ${PRODUCT_ID}`,
      (id) => (id === PRODUCT_ID ? "Remera" : undefined),
    )
    expect(message).toContain("«Remera»")
    expect(message).toMatch(/no hay stock/i)
    expect(message).toMatch(/otra sucursal/i)
    expect(action?.href).toBe(`/stock?product=${PRODUCT_ID}`)
  })

  it("«insufficient_branch_stock for product <id>» (edición con sucursal explícita) nombra la sucursal elegida", () => {
    const { message } = humanizeOperationError(
      `insufficient_branch_stock for product ${PRODUCT_ID}`,
      (id) => (id === PRODUCT_ID ? "Remera" : undefined),
      "Centro",
    )
    expect(message).toContain("«Remera»")
    expect(message).toContain("la sucursal Centro")
  })

  it("el 23514 genérico del backend NO se confunde con un stock insuficiente", () => {
    const { message } = humanizeOperationError("Los datos no cumplen las restricciones de la base de datos.")
    expect(message).not.toMatch(/no hay stock/i)
  })
})
