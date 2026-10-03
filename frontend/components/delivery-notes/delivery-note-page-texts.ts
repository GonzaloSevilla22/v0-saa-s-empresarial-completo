/**
 * remitos-venta / remitos-compra (D11, tarea 5.5) — la redacción de los estados
 * de página del remito (sin permiso, cargando, error o no encontrado) sobre
 * `components/shared/DocumentPageStates`. Una sola definición para el alta, la
 * edición y el detalle, indexada por SENTIDO: el regreso vuelve al listado del
 * sentido (`deliveryNoteListHref`, no a un `/remitos` fijo que abriría "De
 * venta") y el permiso de compra nombra a quien recibe mercadería.
 */
import type { DocumentPageTexts } from "@/components/shared/DocumentPageStates"
import { deliveryNoteListHref } from "@/lib/delivery-note-status"
import type { DeliveryNoteDirection } from "@/lib/delivery-note-types"

export const DELIVERY_NOTE_PAGE_TEXTS: Record<DeliveryNoteDirection, DocumentPageTexts> = {
  sale: {
    singular: "remito",
    loadingLabel: "Cargando remito…",
    backHref: deliveryNoteListHref("sale"),
    backLabel: "Volver a remitos",
    permissionHint: "Pedile a un administrador del negocio que te habilite como vendedor o encargado de stock.",
  },
  purchase: {
    singular: "remito",
    loadingLabel: "Cargando remito…",
    backHref: deliveryNoteListHref("purchase"),
    backLabel: "Volver a remitos",
    // Alineado con CAN_RECEIVE_PURCHASE: el vendedor despacha, no recibe mercadería.
    permissionHint: "Pedile a un administrador del negocio que te habilite como encargado de stock.",
  },
}

/**
 * Los títulos y avisos de las pantallas de alta y edición, por sentido (D11). La
 * redacción que depende del sentido vive acá y no en cada página: el alta de
 * venta descuenta stock; la de compra lo suma.
 */
/** Un título y su bajada, para los estados vacíos del listado. */
export interface DeliveryNoteEmptyText {
  title: string
  body: string
}

/** La redacción del listado `/remitos` que depende del sentido. */
export interface DeliveryNoteListTexts {
  subtitle: string
  /** El botón de alta del encabezado. */
  newCta: string
  searchLabel: string
  searchPlaceholder: string
  /** Encabezado de la columna de la contraparte y rótulo cuando no se conoce. */
  counterpartHeader: string
  counterpartMissing: string
  /** Encabezado de la columna de la sucursal. */
  branchHeader: string
  summaryNoPending: string
  /** "remito pendiente" / "remitos de compra pendientes", según la cantidad. */
  pendingNoun: (count: number) => string
  emptySearch: DeliveryNoteEmptyText
  emptyDefault: DeliveryNoteEmptyText
  /** Filtrado por el cliente (venta) o el proveedor (compra). */
  emptyCounterpart: DeliveryNoteEmptyText
  emptyBranch: DeliveryNoteEmptyText
}

export interface DeliveryNoteScreenTexts {
  list: DeliveryNoteListTexts
  newTitle: string
  newSubtitle: string
  /** Lo que el rol no puede hacer: "Tu rol no permite {newAction}". */
  newAction: string
  editAction: string
  editSubtitle: string
}

export const DELIVERY_NOTE_SCREEN_TEXTS: Record<DeliveryNoteDirection, DeliveryNoteScreenTexts> = {
  sale: {
    list: {
      subtitle: "Entregá mercadería con un remito: descuenta stock al emitirse y lo pasás a venta cuando cobrás.",
      newCta: "Nuevo remito",
      searchLabel: "Buscar por cliente o número",
      searchPlaceholder: "Buscar por cliente o número (R-12)",
      counterpartHeader: "Cliente",
      counterpartMissing: "Sin cliente",
      branchHeader: "Sucursal",
      summaryNoPending: "No hay remitos pendientes de convertir en venta.",
      pendingNoun: (count) => (count === 1 ? "remito pendiente" : "remitos pendientes"),
      emptySearch: {
        title: "Ningún remito coincide con la búsqueda",
        body: "Probá con el nombre del cliente o con el número (por ejemplo R-12).",
      },
      emptyDefault: {
        title: "Todavía no hay remitos",
        body: "Un remito documenta la mercadería que entregás antes de cobrar. El remito descuenta stock al emitirse y se convierte en venta cuando cobrás.",
      },
      emptyCounterpart: {
        title: "Este cliente todavía no tiene remitos",
        body: "Cuando le entregues mercadería con un remito, va a aparecer acá.",
      },
      emptyBranch: {
        title: "Esta sucursal no tiene remitos",
        body: "Cuando salga mercadería de esta sucursal con un remito, va a aparecer acá.",
      },
    },
    newTitle: "Nuevo remito",
    newSubtitle: "Documentá la mercadería que entregás. Emitir un remito descuenta stock de la sucursal que elijas.",
    newAction: "emitir remitos",
    editAction: "editar remitos",
    editSubtitle: "Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.",
  },
  purchase: {
    list: {
      subtitle:
        "Registrá la mercadería que recibís con un remito: suma stock al recibirse y la pasás a compra cuando llega la factura.",
      newCta: "Nuevo remito de compra",
      searchLabel: "Buscar por proveedor o número",
      searchPlaceholder: "Buscar por proveedor, número (RC-12) o N° del proveedor",
      counterpartHeader: "Proveedor",
      counterpartMissing: "Sin proveedor",
      branchHeader: "Destino",
      summaryNoPending: "No hay remitos de compra pendientes de convertir en compra.",
      pendingNoun: (count) => (count === 1 ? "remito de compra pendiente" : "remitos de compra pendientes"),
      emptySearch: {
        title: "Ningún remito coincide con la búsqueda",
        body: "Probá con el nombre del proveedor, con el número (por ejemplo RC-12) o con el N° de remito del proveedor.",
      },
      emptyDefault: {
        title: "Todavía no hay remitos de compra",
        body: "El remito de compra suma stock al recibir la mercadería y se convierte en compra cuando llega la factura.",
      },
      emptyCounterpart: {
        title: "Este proveedor todavía no tiene remitos de compra",
        body: "Cuando recibas mercadería de este proveedor con un remito, va a aparecer acá.",
      },
      emptyBranch: {
        title: "Esta sucursal no tiene remitos de compra",
        body: "Cuando entre mercadería a esta sucursal con un remito de compra, va a aparecer acá.",
      },
    },
    newTitle: "Nuevo remito de compra",
    newSubtitle:
      "Registrá la mercadería que recibís de un proveedor. Emitir el remito suma stock a la sucursal que elijas.",
    newAction: "recibir remitos de compra",
    editAction: "editar remitos",
    editSubtitle: "Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.",
  },
}
