/**
 * presupuestos-modulo (D12, task 4.4) — `lib/quote-lines.ts`: líneas de servicio
 * (concepto sin producto) del presupuesto y armado del payload `p_items` que
 * une productos y servicios con `price` = precio unitario efectivo.
 */
import { describe, it, expect } from "vitest"
import {
  addServiceLine,
  buildQuoteItemsPayload,
  removeServiceLine,
  updateServiceLine,
  validateServiceLineInput,
  type QuoteServiceLine,
} from "@/lib/quote-lines"
import type { SaleCartItem } from "@/lib/cart-utils"

function cartItem(overrides: Partial<SaleCartItem> & { id: string; productId: string }): SaleCartItem {
  return {
    productName: "Remera",
    unitPrice: 1000,
    quantity: 1,
    discount: 0,
    subtotal: 1000,
    unitId: "u-un",
    ...overrides,
  }
}

describe("validateServiceLineInput", () => {
  it("una descripción vacía o en blanco es inválida", () => {
    expect(validateServiceLineInput({ description: "", quantity: 1, unitPrice: 100 })).toMatch(/descripción/i)
    expect(validateServiceLineInput({ description: "   ", quantity: 1, unitPrice: 100 })).toMatch(/descripción/i)
  })
  it("la descripción tiene tope de 200 caracteres (el del schema)", () => {
    expect(validateServiceLineInput({ description: "a".repeat(200), quantity: 1, unitPrice: 100 })).toBeNull()
    expect(validateServiceLineInput({ description: "a".repeat(201), quantity: 1, unitPrice: 100 })).toMatch(/200/)
  })
  it("la cantidad debe ser mayor que cero", () => {
    expect(validateServiceLineInput({ description: "Flete", quantity: 0, unitPrice: 100 })).toMatch(/cantidad/i)
    expect(validateServiceLineInput({ description: "Flete", quantity: -1, unitPrice: 100 })).toMatch(/cantidad/i)
  })
  it("el precio no puede ser negativo pero puede ser cero", () => {
    expect(validateServiceLineInput({ description: "Flete", quantity: 1, unitPrice: -1 })).toMatch(/precio/i)
    expect(validateServiceLineInput({ description: "Bonificación", quantity: 1, unitPrice: 0 })).toBeNull()
  })
  it("una entrada válida no tiene error", () => {
    expect(validateServiceLineInput({ description: "Flete a domicilio", quantity: 2, unitPrice: 1500 })).toBeNull()
  })
})

describe("líneas de servicio", () => {
  it("addServiceLine recorta la descripción y calcula el subtotal", () => {
    const lines = addServiceLine([], { description: "  Flete  ", quantity: 2, unitPrice: 1500 })
    expect(lines).toHaveLength(1)
    expect(lines[0]).toMatchObject({ description: "Flete", quantity: 2, unitPrice: 1500, subtotal: 3000 })
    expect(typeof lines[0].id).toBe("string")
  })

  it("dos altas con los mismos datos son dos líneas (los conceptos no se fusionan)", () => {
    const once = addServiceLine([], { description: "Flete", quantity: 1, unitPrice: 100 })
    const twice = addServiceLine(once, { description: "Flete", quantity: 1, unitPrice: 100 })
    expect(twice).toHaveLength(2)
    expect(twice[0].id).not.toBe(twice[1].id)
  })

  it("updateServiceLine recalcula el subtotal y no toca las otras", () => {
    const lines = addServiceLine(addServiceLine([], { description: "A", quantity: 1, unitPrice: 10 }), {
      description: "B",
      quantity: 1,
      unitPrice: 20,
    })
    const next = updateServiceLine(lines, lines[0].id, { quantity: 3, unitPrice: 15 })
    expect(next[0]).toMatchObject({ quantity: 3, unitPrice: 15, subtotal: 45 })
    expect(next[1]).toBe(lines[1])
  })

  it("updateServiceLine recorta la descripción editada", () => {
    const lines = addServiceLine([], { description: "A", quantity: 1, unitPrice: 10 })
    expect(updateServiceLine(lines, lines[0].id, { description: "  Nuevo  " })[0].description).toBe("Nuevo")
  })

  it("removeServiceLine quita sólo la indicada", () => {
    const lines = addServiceLine(addServiceLine([], { description: "A", quantity: 1, unitPrice: 10 }), {
      description: "B",
      quantity: 1,
      unitPrice: 20,
    })
    expect(removeServiceLine(lines, lines[0].id).map((l) => l.description)).toEqual(["B"])
  })
})

describe("buildQuoteItemsPayload", () => {
  const service: QuoteServiceLine = {
    id: "s1",
    description: "Flete a domicilio",
    quantity: 2,
    unitPrice: 1500,
    subtotal: 3000,
  }

  it("un producto manda su precio unitario EFECTIVO (con el descuento adentro) y su subtotal", () => {
    const payload = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1", unitPrice: 1000, quantity: 3, discount: 10, subtotal: 2700 })],
      serviceLines: [],
    })
    expect(payload).toEqual([
      { product_id: "p1", unit_id: "u-un", quantity: 3, price: 900, subtotal: 2700 },
    ])
  })

  it("el precio efectivo no se redondea a 4 decimales (precio por gramo)", () => {
    const [item] = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1", unitId: "u-g", unitPrice: 1.23456, quantity: 450, subtotal: 555.552 })],
      serviceLines: [],
    })
    expect(item.price).toBe(1.23456)
    expect(item.quantity).toBe(450)
  })

  it("una línea de servicio va sin producto, con su descripción y su unidad si la tiene", () => {
    const payload = buildQuoteItemsPayload({ cartItems: [], serviceLines: [service] })
    expect(payload).toEqual([
      { product_id: null, unit_id: null, quantity: 2, price: 1500, subtotal: 3000, description: "Flete a domicilio" },
    ])
    const withUnit = buildQuoteItemsPayload({ cartItems: [], serviceLines: [{ ...service, unitId: "u-hora" }] })
    expect(withUnit[0].unit_id).toBe("u-hora")
  })

  it("un producto sin unidad manda unit_id null (no undefined)", () => {
    const [item] = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1", unitId: undefined })],
      serviceLines: [],
    })
    expect(item.unit_id).toBeNull()
  })

  it("sin orden de carga: productos primero y después los servicios", () => {
    const payload = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1" }), cartItem({ id: "c2", productId: "p2" })],
      serviceLines: [service],
    })
    expect(payload.map((i) => i.product_id)).toEqual(["p1", "p2", null])
  })

  it("con el orden de carga une las dos listas intercaladas como las cargó el usuario", () => {
    const payload = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1" }), cartItem({ id: "c2", productId: "p2" })],
      serviceLines: [service],
      loadOrder: ["c1", "s1", "c2"],
    })
    expect(payload.map((i) => i.product_id)).toEqual(["p1", null, "p2"])
  })

  it("una línea que no figura en el orden de carga se agrega al final (nada se pierde)", () => {
    const payload = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1" }), cartItem({ id: "c2", productId: "p2" })],
      serviceLines: [service],
      loadOrder: ["s1"],
    })
    expect(payload).toHaveLength(3)
    expect(payload[0].product_id).toBeNull()
    expect(payload.slice(1).map((i) => i.product_id)).toEqual(["p1", "p2"])
  })

  it("ignora ids del orden que ya no existen (línea borrada)", () => {
    const payload = buildQuoteItemsPayload({
      cartItems: [cartItem({ id: "c1", productId: "p1" })],
      serviceLines: [],
      loadOrder: ["zzz", "c1"],
    })
    expect(payload).toHaveLength(1)
  })
})
