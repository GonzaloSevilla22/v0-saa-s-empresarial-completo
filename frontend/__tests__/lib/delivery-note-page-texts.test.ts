/**
 * remitos-compra (D11, tarea 4.6) — `DELIVERY_NOTE_PAGE_TEXTS` indexado por
 * SENTIDO: la redacción de los estados de página del remito (sin permiso,
 * cargando, error o no encontrado). El regreso vuelve al listado del sentido
 * (`deliveryNoteListHref`) y el permiso de compra nombra a quien recibe
 * mercadería (alineado con `CAN_RECEIVE_PURCHASE`: el vendedor no recibe).
 */
import { describe, it, expect } from "vitest"
import { DELIVERY_NOTE_PAGE_TEXTS } from "@/components/delivery-notes/delivery-note-page-texts"
import { deliveryNoteListHref } from "@/lib/delivery-note-status"

describe("DELIVERY_NOTE_PAGE_TEXTS[direction]", () => {
  it("venta: vuelve a /remitos y habilita 'vendedor o encargado de stock' (sin cambios)", () => {
    expect(DELIVERY_NOTE_PAGE_TEXTS.sale).toEqual({
      singular: "remito",
      loadingLabel: "Cargando remito…",
      backHref: "/remitos",
      backLabel: "Volver a remitos",
      permissionHint: "Pedile a un administrador del negocio que te habilite como vendedor o encargado de stock.",
    })
  })

  it("compra: vuelve a la pestaña De compra (/remitos?sentido=compra)", () => {
    expect(DELIVERY_NOTE_PAGE_TEXTS.purchase.backHref).toBe("/remitos?sentido=compra")
    expect(DELIVERY_NOTE_PAGE_TEXTS.purchase.backHref).toBe(deliveryNoteListHref("purchase"))
  })

  it("compra: el permiso nombra al encargado de stock y no al vendedor", () => {
    expect(DELIVERY_NOTE_PAGE_TEXTS.purchase.permissionHint).toBe(
      "Pedile a un administrador del negocio que te habilite como encargado de stock.",
    )
    expect(DELIVERY_NOTE_PAGE_TEXTS.purchase.permissionHint).not.toMatch(/vendedor/i)
  })

  it("el resto de la redacción es común a los dos sentidos", () => {
    expect(DELIVERY_NOTE_PAGE_TEXTS.purchase).toMatchObject({
      singular: "remito",
      loadingLabel: "Cargando remito…",
      backLabel: "Volver a remitos",
    })
  })

  it("el backHref de cada sentido viene del helper, nunca un literal propio", () => {
    for (const direction of ["sale", "purchase"] as const) {
      expect(DELIVERY_NOTE_PAGE_TEXTS[direction].backHref).toBe(deliveryNoteListHref(direction))
    }
  })
})
