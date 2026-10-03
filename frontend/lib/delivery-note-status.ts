/**
 * remitos-venta / remitos-compra (D3/D11) — rótulos del estado del remito,
 * pestañas del listado (por estado y por sentido), matriz estado × rol × sentido
 * de las acciones del detalle y la tabla de textos por sentido, en la capa
 * canónica para que el badge, las pestañas, el detalle y el diálogo de baja de
 * sucursal hablen del mismo estado con las mismas palabras. Funciones puras, sin
 * React. Ninguna pantalla arma su propio texto de sentido: sale de acá.
 *
 * Estados (D3): `issued` (pendiente de convertir), `converted` (la venta o la
 * compra ya existe) y `canceled` (terminal; deshizo el efecto sobre el stock).
 */
import type {
  DeliveryNoteDirection,
  DeliveryNoteHistoryEntry,
  DeliveryNoteStatus,
} from "@/lib/delivery-note-types"

/** El rótulo de cada estado, por sentido: sólo `converted` cambia ("en venta" / "en compra"). */
export const DELIVERY_NOTE_STATUS_LABELS: Record<DeliveryNoteDirection, Record<DeliveryNoteStatus, string>> = {
  sale: {
    issued: "Pendiente",
    converted: "Convertido en venta",
    canceled: "Anulado",
  },
  purchase: {
    issued: "Pendiente",
    converted: "Convertido en compra",
    canceled: "Anulado",
  },
}

// ── Pestañas de sentido y contrato `?sentido=` (remitos-compra, D11) ───────────

/** Valores de `?sentido=` — en castellano, como `?estado=` y `?cliente=`. */
export type DeliveryNoteSentido = "venta" | "compra"

/** Pestañas De venta / De compra de /remitos; el sentido lo resuelve el SERVIDOR (`direction`). */
export const DELIVERY_NOTE_SENTIDO_TABS: ReadonlyArray<{
  value: DeliveryNoteSentido
  label: string
  direction: DeliveryNoteDirection
}> = [
  { value: "venta", label: "De venta", direction: "sale" },
  { value: "compra", label: "De compra", direction: "purchase" },
]

/** La pestaña que preselecciona `?sentido=`; ausente o desconocido cae en "venta" (el default firmado). */
export function parseDeliveryNoteSentidoParam(raw: string | null | undefined): DeliveryNoteSentido {
  const tab = DELIVERY_NOTE_SENTIDO_TABS.find((t) => t.value === raw)
  return tab ? tab.value : "venta"
}

export function directionFromSentido(sentido: DeliveryNoteSentido): DeliveryNoteDirection {
  return sentido === "compra" ? "purchase" : "sale"
}

/**
 * A dónde vuelve el detalle, el alta o la edición de un remito: al listado DE SU
 * SENTIDO. `/remitos` abre "De venta" por defecto; un remito de compra vuelve a
 * `/remitos?sentido=compra` (con un `/remitos` fijo se perdería la pestaña).
 */
export function deliveryNoteListHref(direction: DeliveryNoteDirection): string {
  return direction === "purchase" ? "/remitos?sentido=compra" : "/remitos"
}

// ── Pestañas del listado y contrato `?estado=` (D11) ───────────────────────────

/** Valores de `?estado=` — en castellano, como el `?cliente=` de /presupuestos/nuevo. */
export type DeliveryNoteEstado = "todos" | "pendientes" | "convertidos" | "anulados"

/**
 * Pestañas de estado de /remitos (las de sentido son `DELIVERY_NOTE_SENTIDO_TABS`
 * y no cambian este contrato). El filtro de estado lo resuelve el SERVIDOR;
 * "todos" no manda `status`.
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
  /** Sentido del remito; sin él, venta (retrocompatible). */
  direction?: DeliveryNoteDirection
  /** Emite y edita: `CAN_DELIVER_SALE` en venta, `CAN_RECEIVE_PURCHASE` en compra. */
  canDeliver: boolean
  /** Convierte (tanda B): `CAN_SELL` en venta, `CAN_CONVERT_PURCHASE_DELIVERY_NOTE` en compra. */
  canSell: boolean
  /** `CAN_VOID_DELIVERY_NOTE`: anula (los dos sentidos). */
  canVoid: boolean
  /** El cliente fue dado de baja después de emitir (`client_deleted`). */
  clientDeleted?: boolean
  /** Compra: el proveedor fue dado de baja después de recibir (`supplier_deleted`). */
  supplierDeleted?: boolean
  /** Compra: líneas con precio 0 (`missing_price_count`); la conversión exige todos los precios. */
  missingPriceCount?: number
  /** Tanda B: la conversión existe. En la tanda A, "Venta"/"Compra" no se muestra. */
  conversionEnabled?: boolean
  /** Remito convertido cuya venta tiene un comprobante autorizado (D9). Sólo venta. */
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
  /** "Ver venta": sólo en un remito de venta convertido. */
  viewSale: boolean
  /** "Ver compra": sólo en un remito de compra convertido. */
  viewPurchase: boolean
  /** Texto que explica el estado cuando no se puede editar ni anular. */
  legend: string | null
}

export const CLIENT_DELETED_CONVERT_REASON = "El cliente fue dado de baja: editá el remito y elegí uno vigente"
export const SUPPLIER_DELETED_CONVERT_REASON = "El proveedor fue dado de baja: editá el remito y elegí uno vigente"

/** Por qué "Compra" está deshabilitada: la compra exige precio de compra en todas las líneas (D8). */
export function MISSING_PRICE_CONVERT_REASON(count: number): string {
  const lines = count === 1 ? "1 línea" : `${count} líneas`
  return `Falta el precio de compra de ${lines}: editá el remito y cargalo para convertirlo`
}

const CONVERTED_LEGEND = "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente."
const CONVERTED_PURCHASE_LEGEND = "Para corregirlo, eliminá la compra: el remito vuelve a quedar pendiente."
const INVOICED_LEGEND = "La venta ya está facturada: para devolver mercadería se necesita una nota de crédito."

/** Por qué la conversión está deshabilitada (visible pero sin poder usarse), o `null`. */
function convertDisabledReason(ctx: DeliveryNoteActionContext): string | null {
  if (ctx.direction === "purchase") {
    if (ctx.supplierDeleted) return SUPPLIER_DELETED_CONVERT_REASON
    if ((ctx.missingPriceCount ?? 0) > 0) return MISSING_PRICE_CONVERT_REASON(ctx.missingPriceCount ?? 0)
    return null
  }
  return ctx.clientDeleted ? CLIENT_DELETED_CONVERT_REASON : null
}

/**
 * Qué se ofrece en el detalle de un remito según su estado y los roles del
 * usuario (decididos sobre el CONJUNTO de roles, `hasCapability`). El servidor
 * es la barrera real: esto sólo evita mostrar un botón que rebotaría con 403.
 *
 *  - `issued`:    compartir · editar (`canDeliver`) · venta o compra (`canSell`,
 *                 tanda B; en compra deshabilitada con motivo si falta un precio
 *                 o el proveedor fue dado de baja) · anular (`canVoid`).
 *  - `converted`: compartir · ver venta / ver compra. Sin editar ni anular:
 *                 primero se elimina la venta o la compra y el remito vuelve a
 *                 pendiente.
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
        disabledReason: convertVisible ? convertDisabledReason(ctx) : null,
      },
      cancel: ctx.canVoid,
      viewSale: false,
      viewPurchase: false,
      legend: null,
    }
  }

  if (status === "converted") {
    const purchase = ctx.direction === "purchase"
    return {
      share: true,
      edit: false,
      convert: noConvert,
      cancel: false,
      viewSale: !purchase,
      viewPurchase: purchase,
      legend: purchase ? CONVERTED_PURCHASE_LEGEND : ctx.saleInvoiced ? INVOICED_LEGEND : CONVERTED_LEGEND,
    }
  }

  return {
    share: true,
    edit: false,
    convert: noConvert,
    cancel: false,
    viewSale: false,
    viewPurchase: false,
    legend: null,
  }
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

/**
 * Cómo se lee una transición en el historial del detalle. "Emitido" (alta de un
 * remito de venta) o "Recibido" (alta de uno de compra), "Vuelto a pendiente"
 * (se eliminó la venta o la compra nacida del remito) y, para el resto, el
 * rótulo del estado de destino del sentido.
 */
export function deliveryNoteHistoryLabel(
  entry: DeliveryNoteHistoryEntry,
  direction: DeliveryNoteDirection = "sale",
): string {
  if (entry.from_status === null && entry.to_status === "issued") {
    return direction === "purchase" ? "Recibido" : "Emitido"
  }
  if (entry.from_status === "converted" && entry.to_status === "issued") return "Vuelto a pendiente"
  return DELIVERY_NOTE_STATUS_LABELS[direction][entry.to_status]
}

// ── Textos por sentido (D11) ───────────────────────────────────────────────────

/** Cómo se dice, en `DeactivateBranchDialog`, que hay remitos pendientes en la sucursal. */
export interface PendingBranchNotesText {
  /** "remitos pendientes que retienen": va después del número en negrita. */
  noun: string
  /** Lo que sigue al sustantivo, hasta el punto final. */
  tail: string
  /** Qué hacer para poder desactivarla. */
  advice: string
  /** Rótulo del enlace al listado filtrado. */
  linkLabel: string
}

export interface DeliveryNoteDirectionTexts {
  /** Rótulo de la sucursal en el detalle. */
  branchLabel: string
  /** Aviso de un remito anulado, sin el motivo. */
  canceledNotice: (branchName: string) => string
  /** Aviso de un remito convertido. */
  convertedNotice: string
  /** Toast de un alta exitosa (venta: emitido y descontado; compra: recibido y sumado). */
  emitToast: (numberLabel: string | null | undefined, branchName: string) => string
  /** Toast de una anulación exitosa. */
  cancelToast: (numberLabel: string, branchName: string) => string
  cancelReasonPlaceholder: string
  /** Botón de conversión y enlace al documento generado. */
  convertLabel: string
  viewOperationLabel: string
  pendingBranchNotes: (count: number) => PendingBranchNotesText
}

/**
 * Una sola tabla de textos que dependen del sentido. Los de `delivery-note-stock`
 * (avisos de emisión y devolución) y `delivery-note-form` (validaciones) viven en
 * sus módulos, indexados por el mismo `direction`.
 */
export const DELIVERY_NOTE_TEXTS: Record<DeliveryNoteDirection, DeliveryNoteDirectionTexts> = {
  sale: {
    branchLabel: "Sale de:",
    canceledNotice: (branchName) => `Remito anulado: el stock volvió a ${branchName}.`,
    convertedNotice: "Este remito se convirtió en una venta. El stock ya se había descontado al emitirlo.",
    emitToast: (numberLabel, branchName) =>
      numberLabel
        ? `Remito ${numberLabel} emitido: se descontó el stock de ${branchName}`
        : `Remito emitido: se descontó el stock de ${branchName}`,
    cancelToast: (numberLabel, branchName) => `Remito ${numberLabel} anulado: el stock volvió a ${branchName}`,
    cancelReasonPlaceholder: "Ej: el cliente devolvió la mercadería",
    convertLabel: "Venta",
    viewOperationLabel: "Ver venta",
    pendingBranchNotes: (count) => ({
      noun: count === 1 ? "remito pendiente que retiene" : "remitos pendientes que retienen",
      tail: "mercadería de esta sucursal. No se puede desactivar mientras haya alguno.",
      advice: "Convertilos en venta o anulalos (un administrador o el dueño) y volvé a intentarlo.",
      linkLabel: "Ver remitos pendientes",
    }),
  },
  purchase: {
    branchLabel: "Ingresa a:",
    canceledNotice: (branchName) => `Remito anulado: el stock salió de ${branchName}.`,
    convertedNotice: "Este remito se convirtió en una compra; el stock ya se había sumado al recibirlo.",
    emitToast: (numberLabel, branchName) =>
      numberLabel
        ? `Remito ${numberLabel} recibido: se sumó el stock a ${branchName}`
        : `Remito recibido: se sumó el stock a ${branchName}`,
    cancelToast: (numberLabel, branchName) => `Remito ${numberLabel} anulado: el stock salió de ${branchName}`,
    cancelReasonPlaceholder: "Ej.: el proveedor se llevó la mercadería",
    convertLabel: "Compra",
    viewOperationLabel: "Ver compra",
    pendingBranchNotes: (count) => ({
      noun: count === 1 ? "remito de compra pendiente que aportó" : "remitos de compra pendientes que aportaron",
      tail: "stock a esta sucursal. No se puede desactivar mientras haya alguno.",
      advice: "Convertilos en compra o anulalos (un administrador o el dueño) y volvé a intentarlo.",
      linkLabel: "Ver remitos de compra pendientes",
    }),
  },
}
