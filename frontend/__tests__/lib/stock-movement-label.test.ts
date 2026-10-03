/**
 * remitos-venta (D11, tarea 5.9) — `movementLabel`: el rótulo de un movimiento
 * del kardex. Los del remito se distinguen por `reference_type` (el `type`
 * `sale` / `sale_return` es el mismo que el de la venta y NUNCA implica una fila
 * en `sales`), con el número formateado según el SENTIDO del remito.
 */
import { describe, it, expect } from "vitest"

import { DELIVERY_NOTE_REFERENCE_TYPES, isDeliveryNoteReference, movementLabel } from "@/lib/stock-movement-label"
import type { DeliveryNoteMovementRef } from "@/lib/stock-movement-label"

const refs = new Map<string, DeliveryNoteMovementRef>([
  ["dn-1", { number: 12, direction: "sale" }],
  ["dn-2", { number: 7, direction: "purchase" }],
  ["dn-3", { number: null, direction: "sale" }],
])

describe("isDeliveryNoteReference", () => {
  it.each(["delivery_note", "delivery_note_update", "delivery_note_reversal"])("%s es del remito", (type) => {
    expect(isDeliveryNoteReference(type)).toBe(true)
  })

  it.each(["sale", "purchase", "sale_reversal", "sale_update", "transfer", "", undefined, null])(
    "%s no es del remito",
    (type) => {
      expect(isDeliveryNoteReference(type)).toBe(false)
    },
  )

  it("expone el conjunto cerrado de reference_type del remito", () => {
    expect([...DELIVERY_NOTE_REFERENCE_TYPES].sort()).toEqual(["delivery_note", "delivery_note_reversal", "delivery_note_update"])
  })
})

describe("movementLabel — movimientos del remito", () => {
  it("emisión (y pata de aplicación de una edición): 'Remito R-…' con enlace al remito", () => {
    expect(movementLabel({ type: "sale", referenceType: "delivery_note", referenceId: "dn-1" }, "Venta", refs)).toEqual({
      text: "Remito R-00000012",
      href: "/remitos/dn-1",
    })
  })

  it("pata de reversa de una edición: 'Edición de remito R-…'", () => {
    expect(
      movementLabel({ type: "sale_return", referenceType: "delivery_note_update", referenceId: "dn-1" }, "Dev. venta", refs),
    ).toEqual({ text: "Edición de remito R-00000012", href: "/remitos/dn-1" })
  })

  it("anulación: 'Anulación de remito R-…'", () => {
    expect(
      movementLabel({ type: "sale_return", referenceType: "delivery_note_reversal", referenceId: "dn-1" }, "Dev. venta", refs),
    ).toEqual({ text: "Anulación de remito R-00000012", href: "/remitos/dn-1" })
  })

  it("el número se formatea según el sentido: un remito de compra lleva RC-, no la R de venta (remitos-compra D2)", () => {
    const { text } = movementLabel({ type: "purchase", referenceType: "delivery_note", referenceId: "dn-2" }, "Compra", refs)
    expect(text).toBe("Remito RC-00000007")
    expect(text).not.toMatch(/(^|\s)R-/)
  })

  it("edición y anulación de un remito de compra: 'Edición de remito RC-…' / 'Anulación de remito RC-…'", () => {
    expect(
      movementLabel({ type: "purchase_return", referenceType: "delivery_note_update", referenceId: "dn-2" }, "Dev. compra", refs),
    ).toEqual({ text: "Edición de remito RC-00000007", href: "/remitos/dn-2" })
    expect(
      movementLabel({ type: "purchase_return", referenceType: "delivery_note_reversal", referenceId: "dn-2" }, "Dev. compra", refs),
    ).toEqual({ text: "Anulación de remito RC-00000007", href: "/remitos/dn-2" })
  })

  it("si el remito no tiene número, o no se pudo resolver, dice 'Remito' sin número y conserva el enlace", () => {
    expect(movementLabel({ type: "sale", referenceType: "delivery_note", referenceId: "dn-3" }, "Venta", refs)).toEqual({
      text: "Remito",
      href: "/remitos/dn-3",
    })
    expect(movementLabel({ type: "sale", referenceType: "delivery_note", referenceId: "dn-9" }, "Venta", refs)).toEqual({
      text: "Remito",
      href: "/remitos/dn-9",
    })
    expect(movementLabel({ type: "sale", referenceType: "delivery_note", referenceId: "dn-1" }, "Venta")).toEqual({
      text: "Remito",
      href: "/remitos/dn-1",
    })
  })

  it("sin reference_id no hay enlace (y el rótulo sigue siendo el del remito)", () => {
    expect(movementLabel({ type: "sale", referenceType: "delivery_note" }, "Venta", refs)).toEqual({ text: "Remito", href: null })
  })
})

describe("movementLabel — el resto del kardex no cambia", () => {
  it.each([
    ["sale", "sale", "Venta"],
    ["purchase", "purchase", "Compra"],
    ["sale_return", "sale_reversal", "Dev. venta"],
    ["adjustment", undefined, "Ajuste"],
  ] as const)("type %s con reference_type %s conserva '%s'", (type, referenceType, base) => {
    expect(movementLabel({ type, referenceType, referenceId: "dn-1" }, base, refs)).toEqual({ text: base, href: null })
  })

  it("una venta con el mismo id que un remito no se confunde con él (se distingue por reference_type)", () => {
    expect(movementLabel({ type: "sale", referenceType: "sale", referenceId: "dn-1" }, "Venta", refs).text).toBe("Venta")
  })
})
