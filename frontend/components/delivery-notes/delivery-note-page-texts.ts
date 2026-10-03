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
