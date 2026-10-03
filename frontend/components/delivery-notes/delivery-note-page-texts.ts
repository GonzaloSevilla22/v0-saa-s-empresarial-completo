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
export interface DeliveryNoteScreenTexts {
  newTitle: string
  newSubtitle: string
  /** Lo que el rol no puede hacer: "Tu rol no permite {newAction}". */
  newAction: string
  editAction: string
  editSubtitle: string
}

export const DELIVERY_NOTE_SCREEN_TEXTS: Record<DeliveryNoteDirection, DeliveryNoteScreenTexts> = {
  sale: {
    newTitle: "Nuevo remito",
    newSubtitle: "Documentá la mercadería que entregás. Emitir un remito descuenta stock de la sucursal que elijas.",
    newAction: "emitir remitos",
    editAction: "editar remitos",
    editSubtitle: "Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.",
  },
  purchase: {
    newTitle: "Nuevo remito de compra",
    newSubtitle:
      "Registrá la mercadería que recibís de un proveedor. Emitir el remito suma stock a la sucursal que elijas.",
    newAction: "recibir remitos de compra",
    editAction: "editar remitos",
    editSubtitle: "Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.",
  },
}
