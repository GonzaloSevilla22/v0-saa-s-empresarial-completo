/**
 * formatComprobante / comprobanteTypeLabel — fiscal-emision-segura (G7, task 7.2).
 *
 * El formato es load-bearing: es el que usa ARCA y el que el PO vio en la
 * constatación de comprobantes ("Factura C 0003-00000002"). Si el padding se
 * rompe, el número que /admin/pagos muestra NO es el que se puede buscar en
 * ARCA, que es justo lo que G3 vino a hacer verificable.
 *
 * El caso `null` importa igual que el feliz: con `number` ausente no se
 * renderiza nada — un "—" en ese lugar parecería un número que no existe.
 */
import { describe, it, expect } from "vitest"

import { formatComprobante, comprobanteTypeLabel } from "@/lib/fiscal-comprobante"

describe("formatComprobante (G7)", () => {
  it("formatea PV en 4 dígitos y número en 8, como ARCA", () => {
    expect(formatComprobante(3, 2)).toBe("0003-00000002")
    expect(formatComprobante(1, 12345678)).toBe("0001-12345678")
    expect(formatComprobante(9999, 1)).toBe("9999-00000001")
  })

  it("devuelve null si falta cualquiera de los dos", () => {
    expect(formatComprobante(3, null)).toBeNull()
    expect(formatComprobante(null, 2)).toBeNull()
    expect(formatComprobante(undefined, undefined)).toBeNull()
  })

  it("no confunde 0 con ausente", () => {
    // PV 0 no es un PV real, pero `0` no es `null`: el helper no debe tratarlo
    // como "falta el dato" (un `if (!pv)` lo haría, y ahí se pierde el número).
    expect(formatComprobante(0, 2)).toBe("0000-00000002")
  })
})

describe("comprobanteTypeLabel (G7)", () => {
  it("traduce el tipo del dominio a la etiqueta de ARCA", () => {
    expect(comprobanteTypeLabel("factura_c")).toBe("Factura C")
    expect(comprobanteTypeLabel("factura_a")).toBe("Factura A")
    expect(comprobanteTypeLabel("nota_credito_b")).toBe("Nota CREDITO B")
  })

  it("no explota con un tipo ausente", () => {
    expect(comprobanteTypeLabel(null)).toBe("Comprobante")
    expect(comprobanteTypeLabel(undefined)).toBe("Comprobante")
  })
})
