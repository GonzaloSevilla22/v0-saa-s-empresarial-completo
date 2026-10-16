/**
 * remitos-compra (tanda B, D11, tarea 7.9) — el aviso contra la doble suma, en la
 * capa canónica de textos por sentido (`lib/delivery-note-status.ts`).
 *
 * El escenario que justifica el change es "recibo con remito y la factura llega
 * después": las otras dos puertas que vuelven a SUMAR el stock porque crean una
 * compra directa (el formulario de compra y la Factura IA) avisan que hay remitos
 * de compra pendientes y mandan a convertirlos desde el remito. Funciones puras: el
 * texto y el destino del enlace; el componente y los dos caminos tienen sus tests.
 */
import { describe, it, expect } from "vitest"
import {
  PENDING_PURCHASE_NOTES_LINK_LABEL,
  pendingPurchaseNotesHref,
  pendingPurchaseNotesNotice,
} from "@/lib/delivery-note-status"

describe("pendingPurchaseNotesNotice — con proveedor elegido (formulario de compra)", () => {
  it("un remito pendiente: singular, y la factura 'es de ese remito'", () => {
    expect(pendingPurchaseNotesNotice(1, "supplier")).toBe(
      "Este proveedor tiene 1 remito de compra pendiente. Si esta factura es de ese remito, convertilo desde el remito para no sumar el stock dos veces.",
    )
  })

  it("varios remitos pendientes: plural, y la factura 'es de uno de ellos'", () => {
    expect(pendingPurchaseNotesNotice(3, "supplier")).toBe(
      "Este proveedor tiene 3 remitos de compra pendientes. Si esta factura es de uno de ellos, convertilo desde el remito para no sumar el stock dos veces.",
    )
  })

  it("el conteo se escribe con el formato es-AR cuando pasa de mil", () => {
    expect(pendingPurchaseNotesNotice(1200, "supplier")).toContain("1.200 remitos de compra pendientes")
  })

  it.each([0, -1, Number.NaN])("sin remitos pendientes (%s) no hay aviso", (count) => {
    expect(pendingPurchaseNotesNotice(count, "supplier")).toBeNull()
  })
})

describe("pendingPurchaseNotesNotice — sin proveedor identificado (Factura IA)", () => {
  it("un remito pendiente en la cuenta: singular", () => {
    expect(pendingPurchaseNotesNotice(1, "account")).toBe(
      "Tenés 1 remito de compra pendiente. Si esta factura es de ese remito, convertilo desde el remito para no sumar el stock dos veces.",
    )
  })

  it("varios remitos pendientes en la cuenta: plural", () => {
    expect(pendingPurchaseNotesNotice(4, "account")).toBe(
      "Tenés 4 remitos de compra pendientes. Si esta factura es de uno de ellos, convertilo desde el remito para no sumar el stock dos veces.",
    )
  })

  it("sin remitos pendientes no hay aviso", () => {
    expect(pendingPurchaseNotesNotice(0, "account")).toBeNull()
  })
})

describe("pendingPurchaseNotesHref", () => {
  it("con proveedor: la pestaña De compra, pendientes, filtrada por ese proveedor", () => {
    expect(pendingPurchaseNotesHref("sup-1")).toBe("/remitos?sentido=compra&estado=pendientes&proveedor=sup-1")
  })

  it("sin proveedor: la pestaña De compra filtrada por pendientes", () => {
    expect(pendingPurchaseNotesHref()).toBe("/remitos?sentido=compra&estado=pendientes")
    expect(pendingPurchaseNotesHref(null)).toBe("/remitos?sentido=compra&estado=pendientes")
  })

  it("el id del proveedor se escapa (no puede romper la query)", () => {
    expect(pendingPurchaseNotesHref("a&b=c")).toBe("/remitos?sentido=compra&estado=pendientes&proveedor=a%26b%3Dc")
  })
})

describe("PENDING_PURCHASE_NOTES_LINK_LABEL", () => {
  it("es el rótulo del enlace a los pendientes", () => {
    expect(PENDING_PURCHASE_NOTES_LINK_LABEL).toBe("Ver remitos pendientes")
  })
})
