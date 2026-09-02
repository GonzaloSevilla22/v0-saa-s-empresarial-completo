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
  /**
   * gastos-forma-pago (D8): el gasto tiene movimiento de caja y NO hay sesión
   * abierta en esa caja. La compensación se postea contra la sesión abierta de
   * hoy y jamás toca la original (el ledger es append-only por sesión), así que
   * sin caja abierta `rpc_delete_expense` responde `P0426`. Es el MISMO EXISTS
   * que evalúa el servidor, derivado en el backend — no una regla de cliente.
   * Ausente/false en ventas y compras: su borrado no tiene este bloqueo.
   */
  isDeleteBlocked?: boolean
  /**
   * qa-integral-modulos G10 (H12): el borrado de una COMPRA revierte además
   * el stock que la compra ingresó (rpc_delete_purchase_operation emite el
   * espejo REVERSE — stock-movements-edicion), y el diálogo no lo decía.
   * Lo pasa el listado de compras; ausente en ventas y gastos (el informe
   * no los observó y su redacción sería otra).
   */
  reversesStock?: boolean
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

/** Documento sobre el que se deriva — sólo cambia la redacción, no la lógica.
 * caja-compras-cobranzas (task 12.2): suma "compra" — la compra ahora
 * también puede tener movimiento de caja posteado (D7). */
export type DeletableDocument = "operacion" | "gasto" | "compra"

/** caja-compras-cobranzas (task 12.2): la redacción original era literal
 * para "el gasto" — sirve también a "la compra" desde D7. Frase completa por
 * documento (no una plantilla con género interpolado) para no arriesgar una
 * concordancia rota. */
const NO_OPEN_SESSION_BLOCKED_REASON: Record<DeletableDocument, string> = {
  operacion: "No se puede borrar: la operación descontó de una caja que ya está cerrada. Abrí la caja para poder borrarla.",
  gasto: "No se puede borrar: el gasto descontó de una caja que ya está cerrada. Abrí la caja para poder borrarlo.",
  compra: "No se puede borrar: la compra descontó de una caja que ya está cerrada. Abrí la caja para poder borrarla.",
}

export function getDeleteCompensation(
  flags: DeletableOperationFlags,
  party: "cliente" | "proveedor" = "cliente",
  document: DeletableDocument = "operacion",
): DeleteCompensationInfo {
  if (flags.isInvoiced) {
    return { deletable: false, blockedReason: FISCAL_BLOCKED_REASON, compensations: [] }
  }
  if (flags.isDeleteBlocked) {
    return { deletable: false, blockedReason: NO_OPEN_SESSION_BLOCKED_REASON[document], compensations: [] }
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
    // El signo es opuesto según el documento: borrar una venta SACA plata de
    // la caja; borrar un gasto o una compra la REPONE (expense/purchase_
    // payment son negativos, sus reversas positivas). Decir "salida" en un
    // gasto o una compra sería mentir sobre el arqueo (caja-compras-
    // cobranzas, task 12.2: compra se suma a la misma rama que gasto).
    compensations.push(
      document === "gasto" || document === "compra"
        ? "Se registrará el ingreso correspondiente en la caja abierta actual."
        : "Se registrará la salida correspondiente en la caja abierta actual.",
    )
  }
  if (flags.hasBankMovement) {
    compensations.push("Se registrará el movimiento bancario inverso, pendiente de conciliar.")
  }
  if (flags.reversesStock) {
    // Redacción alineada al tooltip del lápiz bloqueado de la misma fila
    // ("revierte el cargo y repone el stock") — H12 pedía que el diálogo
    // dijera lo mismo que ya decía el tooltip.
    compensations.push(
      "Se revertirá el ingreso de stock de esta compra (el stock vuelve al estado previo).",
    )
  }

  return { deletable: true, blockedReason: null, compensations }
}
