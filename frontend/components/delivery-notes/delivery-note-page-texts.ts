/**
 * remitos-venta (D11, tarea 5.5) — la redacción de los estados de página del
 * remito (sin permiso, cargando, error o no encontrado) sobre
 * `components/shared/DocumentPageStates`. Una sola definición para el alta, la
 * edición y el detalle.
 */
import type { DocumentPageTexts } from "@/components/shared/DocumentPageStates"

export const DELIVERY_NOTE_PAGE_TEXTS: DocumentPageTexts = {
  singular: "remito",
  loadingLabel: "Cargando remito…",
  backHref: "/remitos",
  backLabel: "Volver a remitos",
  permissionHint: "Pedile a un administrador del negocio que te habilite como vendedor o encargado de stock.",
}
