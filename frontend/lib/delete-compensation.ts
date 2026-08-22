/**
 * delete-guard-ledgers — operation-delete-compensation (frontend mirror).
 *
 * Deriva, DE LECTURA, qué va a pasar si se borra una operación de venta o
 * compra — nunca una columna denormalizada (misma regla D5 que ya rige
 * is_payment_locked/is_invoiced). Espeja el orden de guards del backend
 * (rpc_delete_sale_operation / rpc_delete_purchase_operation, D2/D3):
 *
 *   1. Comprobante fiscal emitido → NO borrable (P0423). El camino correcto
 *      es la Nota de Crédito.
 *   2. Dinero posteado (cuenta corriente / caja / banco) → borrable, pero
 *      el diálogo enumera qué libro se va a compensar antes de confirmar.
 *   3. Sin nada de lo anterior → borrable, confirmación simple.
 *
 * `party` sólo cambia el texto del ítem de cuenta corriente (cliente vs.
 * proveedor) — no hay lógica de negocio nueva acá, sólo redacción.
 */

export interface DeletableOperationFlags {
  isInvoiced?: boolean
  hasAccountCharge?: boolean
  hasCashMovement?: boolean
  hasBankMovement?: boolean
}

export interface DeleteCompensationInfo {
  /** false cuando el control de borrado debe aparecer deshabilitado. */
  deletable: boolean
  /** Razón visible cuando deletable=false (P0423). */
  blockedReason: string | null
  /** Ítems a enumerar en el diálogo antes de confirmar. Vacío cuando la
   * operación no tiene dinero posteado — el diálogo confirma sin enumerar
   * (task 9.5). */
  compensations: string[]
}

const FISCAL_BLOCKED_REASON =
  "No se puede borrar: la operación tiene un comprobante fiscal emitido. El camino correcto es emitir una Nota de Crédito."

export function getDeleteCompensation(
  flags: DeletableOperationFlags,
  party: "cliente" | "proveedor" = "cliente",
): DeleteCompensationInfo {
  if (flags.isInvoiced) {
    return { deletable: false, blockedReason: FISCAL_BLOCKED_REASON, compensations: [] }
  }

  const compensations: string[] = []
  if (flags.hasAccountCharge) {
    compensations.push(
      party === "proveedor"
        ? "Se revertirá el cargo registrado en la cuenta corriente del proveedor."
        : "Se revertirá el cargo registrado en la cuenta corriente del cliente.",
    )
  }
  if (flags.hasCashMovement) {
    compensations.push("Se registrará la salida correspondiente en la caja abierta actual.")
  }
  if (flags.hasBankMovement) {
    compensations.push("Se registrará el movimiento bancario inverso, pendiente de conciliar.")
  }

  return { deletable: true, blockedReason: null, compensations }
}
