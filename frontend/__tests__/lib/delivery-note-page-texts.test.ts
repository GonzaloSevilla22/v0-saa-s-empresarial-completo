/**
 * remitos-compra (D11, tarea 4.6) — `DELIVERY_NOTE_PAGE_TEXTS` indexado por
 * SENTIDO: la redacción de los estados de página del remito (sin permiso,
 * cargando, error o no encontrado). El regreso vuelve al listado del sentido
 * (`deliveryNoteListHref`) y el permiso de compra nombra a quien recibe
 * mercadería (alineado con `CAN_RECEIVE_PURCHASE`: el vendedor no recibe).
 */
import { describe, it, expect } from "vitest"
import {
  DELIVERY_NOTE_PAGE_TEXTS,
  DELIVERY_NOTE_SCREEN_TEXTS,
} from "@/components/delivery-notes/delivery-note-page-texts"
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

// ── remitos-compra (tarea 5.5): títulos y avisos de las pantallas de alta y edición ──

describe("DELIVERY_NOTE_SCREEN_TEXTS[direction] — alta y edición", () => {
  it("venta: los textos de siempre", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale).toMatchObject({
      newTitle: "Nuevo remito",
      newSubtitle: "Documentá la mercadería que entregás. Emitir un remito descuenta stock de la sucursal que elijas.",
      newAction: "emitir remitos",
      editAction: "editar remitos",
      editSubtitle: "Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.",
    })
  })

  it("compra: recibir SUMA stock y el permiso habla de recibir remitos de compra", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase).toMatchObject({
      newTitle: "Nuevo remito de compra",
      newSubtitle:
        "Registrá la mercadería que recibís de un proveedor. Emitir el remito suma stock a la sucursal que elijas.",
      newAction: "recibir remitos de compra",
      editAction: "editar remitos",
    })
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.newSubtitle).not.toMatch(/descuenta/i)
  })

  it("la edición dice lo mismo en los dos sentidos (ajusta el stock sólo donde cambia)", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.editSubtitle).toBe(DELIVERY_NOTE_SCREEN_TEXTS.sale.editSubtitle)
  })
})

// ── remitos-compra (tarea 5.4): los textos del listado, por sentido ─────────────

describe("DELIVERY_NOTE_SCREEN_TEXTS[direction].list — el listado /remitos", () => {
  it("venta: los textos de siempre", () => {
    const list = DELIVERY_NOTE_SCREEN_TEXTS.sale.list
    expect(list.subtitle).toBe("Entregá mercadería con un remito: descuenta stock al emitirse y lo pasás a venta cuando cobrás.")
    expect(list.newCta).toBe("Nuevo remito")
    expect(list.searchLabel).toBe("Buscar por cliente o número")
    expect(list.searchPlaceholder).toBe("Buscar por cliente o número (R-12)")
    expect(list.counterpartHeader).toBe("Cliente")
    expect(list.counterpartMissing).toBe("Sin cliente")
    expect(list.branchHeader).toBe("Sucursal")
    expect(list.summaryNoPending).toBe("No hay remitos pendientes de convertir en venta.")
    expect(list.emptyDefault).toEqual({
      title: "Todavía no hay remitos",
      body: "Un remito documenta la mercadería que entregás antes de cobrar. El remito descuenta stock al emitirse y se convierte en venta cuando cobrás.",
    })
  })

  it("compra: recibir suma stock y se convierte en compra cuando llega la factura", () => {
    const list = DELIVERY_NOTE_SCREEN_TEXTS.purchase.list
    expect(list.newCta).toBe("Nuevo remito de compra")
    expect(list.searchLabel).toBe("Buscar por proveedor o número")
    expect(list.searchPlaceholder).toBe("Buscar por proveedor, número (RC-12) o N° del proveedor")
    expect(list.counterpartHeader).toBe("Proveedor")
    expect(list.counterpartMissing).toBe("Sin proveedor")
    expect(list.branchHeader).toBe("Destino")
    expect(list.summaryNoPending).toBe("No hay remitos de compra pendientes de convertir en compra.")
    expect(list.emptyDefault).toEqual({
      title: "Todavía no hay remitos de compra",
      body: "El remito de compra suma stock al recibir la mercadería y se convierte en compra cuando llega la factura.",
    })
  })

  it("el sustantivo de los pendientes cambia de número y de sentido", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale.list.pendingNoun(1)).toBe("remito pendiente")
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale.list.pendingNoun(4)).toBe("remitos pendientes")
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.list.pendingNoun(1)).toBe("remito de compra pendiente")
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.list.pendingNoun(3)).toBe("remitos de compra pendientes")
  })

  it("los vacíos filtrados nombran a la contraparte y a la sucursal de cada sentido", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale.list.emptyCounterpart.title).toBe("Este cliente todavía no tiene remitos")
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.list.emptyCounterpart.title).toBe(
      "Este proveedor todavía no tiene remitos de compra",
    )
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale.list.emptyBranch.title).toBe("Esta sucursal no tiene remitos")
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.list.emptyBranch.title).toBe("Esta sucursal no tiene remitos de compra")
  })

  it("la búsqueda sin resultados sugiere el formato de búsqueda de cada sentido", () => {
    expect(DELIVERY_NOTE_SCREEN_TEXTS.sale.list.emptySearch.body).toBe(
      "Probá con el nombre del cliente o con el número (por ejemplo R-12).",
    )
    expect(DELIVERY_NOTE_SCREEN_TEXTS.purchase.list.emptySearch.body).toBe(
      "Probá con el nombre del proveedor, con el número (por ejemplo RC-12) o con el N° de remito del proveedor.",
    )
  })
})
