/**
 * remitos-venta (D3/D11) — rótulos del estado del remito, pestañas del listado
 * y matriz estado × rol de las acciones del detalle, en la capa canónica para
 * que el badge, las pestañas, el detalle y el diálogo de baja de sucursal hablen
 * del mismo estado con las mismas palabras. Funciones puras, sin React.
 *
 * Estados (D3): `issued` (pendiente de convertir), `converted` (la venta ya
 * existe) y `canceled` (terminal, repuso el stock).
 */
import type { DeliveryNoteHistoryEntry, DeliveryNoteStatus } from "@/lib/delivery-note-types"

export const DELIVERY_NOTE_STATUS_LABELS: Record<DeliveryNoteStatus, string> = {
  issued: "Pendiente",
  converted: "Convertido en venta",
  canceled: "Anulado",
}

// ── Pestañas del listado y contrato `?estado=` (D11) ───────────────────────────

/** Valores de `?estado=` — en castellano, como el `?cliente=` de /presupuestos/nuevo. */
export type DeliveryNoteEstado = "todos" | "pendientes" | "convertidos" | "anulados"

/**
 * Pestañas de /remitos. NO hay pestañas de sentido (De venta / De compra,
 * OQ-RV6): `remitos-compra` las suma sin cambiar este contrato. El filtro de
 * estado lo resuelve el SERVIDOR; "todos" no manda `status`.
 */
export const DELIVERY_NOTE_ESTADO_TABS: ReadonlyArray<{
  value: DeliveryNoteEstado
  label: string
  /** Estado del servidor que la pestaña pide; `undefined` = sin filtro. */
  status: DeliveryNoteStatus | undefined
}> = [
  { value: "todos", label: "Todos", status: undefined },
  { value: "pendientes", label: "Pendientes", status: "issued" },
  { value: "convertidos", label: "Convertidos", status: "converted" },
  { value: "anulados", label: "Anulados", status: "canceled" },
]

/** La pestaña que preselecciona `?estado=`; ausente o desconocido cae en "todos". */
export function parseDeliveryNoteEstadoParam(raw: string | null | undefined): DeliveryNoteEstado {
  const tab = DELIVERY_NOTE_ESTADO_TABS.find((t) => t.value === raw)
  return tab ? tab.value : "todos"
}

// ── Acciones del detalle: matriz estado × rol (D11) ────────────────────────────

export interface DeliveryNoteActionContext {
  /** `CAN_DELIVER_SALE`: emite y edita. */
  canDeliver: boolean
  /** `CAN_SELL`: convierte en venta (tanda B). */
  canSell: boolean
  /** `CAN_VOID_DELIVERY_NOTE`: anula. */
  canVoid: boolean
  /** El cliente fue dado de baja después de emitir (`client_deleted`). */
  clientDeleted?: boolean
  /** Tanda B: la conversión en venta existe. En la tanda A, "Venta" no se muestra. */
  conversionEnabled?: boolean
  /** Remito convertido cuya venta tiene un comprobante autorizado (D9). */
  saleInvoiced?: boolean
}

export interface DeliveryNoteActions {
  /** Descargar / WhatsApp: cualquier miembro, en cualquier estado (PDF con sello si está anulado). */
  share: boolean
  edit: boolean
  convert: {
    visible: boolean
    /** Por qué "Venta" está deshabilitado (visible pero sin poder usarse). */
    disabledReason: string | null
  }
  cancel: boolean
  /** "Ver venta": sólo en un remito convertido. */
  viewSale: boolean
  /** Texto que explica el estado cuando no se puede editar ni anular. */
  legend: string | null
}

export const CLIENT_DELETED_CONVERT_REASON = "El cliente fue dado de baja: editá el remito y elegí uno vigente"

const CONVERTED_LEGEND = "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente."
const INVOICED_LEGEND = "La venta ya está facturada: para devolver mercadería se necesita una nota de crédito."

/**
 * Qué se ofrece en el detalle de un remito según su estado y los roles del
 * usuario (decididos sobre el CONJUNTO de roles, `hasCapability`). El servidor
 * es la barrera real: esto sólo evita mostrar un botón que rebotaría con 403.
 *
 *  - `issued`:    compartir · editar (`canDeliver`) · venta (`canSell`, tanda B)
 *                 · anular (`canVoid`).
 *  - `converted`: compartir · ver venta. Sin editar ni anular: primero se elimina
 *                 la venta y el remito vuelve a pendiente.
 *  - `canceled`:  sólo compartir (PDF con sello ANULADO).
 */
export function deliveryNoteActions(
  status: DeliveryNoteStatus,
  ctx: DeliveryNoteActionContext,
): DeliveryNoteActions {
  const noConvert = { visible: false, disabledReason: null }

  if (status === "issued") {
    const convertVisible = !!ctx.conversionEnabled && ctx.canSell
    return {
      share: true,
      edit: ctx.canDeliver,
      convert: {
        visible: convertVisible,
        disabledReason: convertVisible && ctx.clientDeleted ? CLIENT_DELETED_CONVERT_REASON : null,
      },
      cancel: ctx.canVoid,
      viewSale: false,
      legend: null,
    }
  }

  if (status === "converted") {
    return {
      share: true,
      edit: false,
      convert: noConvert,
      cancel: false,
      viewSale: true,
      legend: ctx.saleInvoiced ? INVOICED_LEGEND : CONVERTED_LEGEND,
    }
  }

  return { share: true, edit: false, convert: noConvert, cancel: false, viewSale: false, legend: null }
}

/**
 * El motivo con que se anuló el remito, del historial de estados (la transición
 * a `canceled` más reciente). `null` si no hay transición o no trae motivo: nunca
 * se inventa uno.
 */
export function canceledReason(history: readonly DeliveryNoteHistoryEntry[]): string | null {
  const cancellations = history.filter((entry) => entry.to_status === "canceled")
  const latest = [...cancellations].sort((a, b) => a.occurred_at.localeCompare(b.occurred_at)).pop()
  const reason = latest?.reason?.trim()
  return reason ? reason : null
}
