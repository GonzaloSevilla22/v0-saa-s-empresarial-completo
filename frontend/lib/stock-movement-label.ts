/**
 * remitos-venta (D4/D11, tarea 5.9) — el rótulo de un movimiento del kardex,
 * en la capa canónica para que la fila del panel de `/stock` y su exportación
 * CSV digan lo mismo.
 *
 * El remito escribe movimientos con el MISMO `type` que la venta (`sale` al
 * emitir y `sale_return` al devolver), así que el `type` ya no alcanza para
 * rotularlos: un consumidor del ledger nunca asume que `type = 'sale'` es una
 * fila de `sales`. Los del remito se distinguen por `reference_type`:
 *
 *   `delivery_note`           emisión y pata de aplicación de una edición -> "Remito R-…"
 *   `delivery_note_update`    pata de reversa de una edición              -> "Edición de remito R-…"
 *   `delivery_note_reversal`  anulación                                   -> "Anulación de remito R-…"
 *
 * El número se formatea según el SENTIDO del remito
 * (`formatDeliveryNoteNumber`), nunca con una `R` escrita a mano, y se resuelve
 * aparte porque el panel lee `stock_movements` directo: si no se resolvió, el
 * rótulo es "Remito" sin número. El enlace va por `reference_id`, que no
 * depende del número. El sentido (entrada o salida) y el ícono siguen saliendo
 * del `type`.
 */
import { formatDeliveryNoteNumber } from "@/lib/internal-document-number"
import type { MovementType } from "@/lib/types"

export const DELIVERY_NOTE_REFERENCE_TYPES = ["delivery_note", "delivery_note_update", "delivery_note_reversal"] as const

export type DeliveryNoteReferenceType = (typeof DELIVERY_NOTE_REFERENCE_TYPES)[number]

/** Lo que hace falta del remito para formatear su número: se lee de `delivery_notes`. */
export interface DeliveryNoteMovementRef {
  number: number | null
  direction: "sale" | "purchase"
}

const PREFIX_BY_REFERENCE_TYPE: Record<DeliveryNoteReferenceType, string> = {
  delivery_note: "Remito",
  delivery_note_update: "Edición de remito",
  delivery_note_reversal: "Anulación de remito",
}

export function isDeliveryNoteReference(referenceType: string | null | undefined): referenceType is DeliveryNoteReferenceType {
  return !!referenceType && (DELIVERY_NOTE_REFERENCE_TYPES as readonly string[]).includes(referenceType)
}

export interface LabelledMovement {
  type: MovementType
  referenceType?: string | null
  referenceId?: string | null
}

export interface MovementLabel {
  text: string
  /** `/remitos/<reference_id>` para los movimientos del remito; `null` para el resto. */
  href: string | null
}

/**
 * El rótulo y el enlace de un movimiento. `baseLabel` es el que le corresponde
 * por `type` (el que ya usaba el panel) y es el que queda para todo lo que no es
 * del remito.
 */
export function movementLabel(
  movement: LabelledMovement,
  baseLabel: string,
  deliveryNotes?: ReadonlyMap<string, DeliveryNoteMovementRef>,
): MovementLabel {
  if (!isDeliveryNoteReference(movement.referenceType)) return { text: baseLabel, href: null }

  const prefix = PREFIX_BY_REFERENCE_TYPE[movement.referenceType]
  const ref = movement.referenceId ? deliveryNotes?.get(movement.referenceId) : undefined
  const number = ref ? formatDeliveryNoteNumber(ref.direction, ref.number) : null
  return {
    text: number ? `${prefix} ${number}` : prefix,
    href: movement.referenceId ? `/remitos/${movement.referenceId}` : null,
  }
}
