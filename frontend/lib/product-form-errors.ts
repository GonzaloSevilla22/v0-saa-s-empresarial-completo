/**
 * Errores de guardado de los formularios de producto (simple, padre y variante).
 *
 * Una sola traducción para los tres: los rechazos tipados del backend salen por
 * el mapa canónico `humanizeOperationError` (castellano accionable), no con el
 * texto técnico del servidor.
 */

import { PythonApiError } from "@/lib/api/python-api-error"
import { humanizeOperationError } from "@/lib/operation-errors"

/**
 * El backend rechazó el cambio de unidad base por D11/D-C: el guard del
 * service responde `code: "base_unit_locked"`; si la carrera la gana otro
 * escritor, el trigger `trg_product_base_unit_guard` llega como P0409 con el
 * token al principio del `detail`.
 */
const BASE_UNIT_LOCKED_CODE = "base_unit_locked"

export function isBaseUnitLockedError(error: unknown): boolean {
  if (error instanceof PythonApiError && error.code === BASE_UNIT_LOCKED_CODE) return true
  return error instanceof Error && error.message.startsWith(`${BASE_UNIT_LOCKED_CODE}:`)
}

/**
 * stock-ledger-solo-rpc: los dos rechazos del backend ligados al stock se muestran
 * por el mapa canónico (castellano accionable, no el texto técnico): el 403 de
 * `require_account_role(CAN_STOCK)` del alta con stock inicial y el 422
 * `stock_adjust_required` de una edición que mandó un stock distinto del saldo.
 * Cualquier otro error devuelve `null`.
 */
function stockApiErrorMessage(error: unknown): string | null {
  if (!(error instanceof PythonApiError)) return null
  const isStockRole = error.status === 403 && /Rol de cuenta insuficiente/.test(error.message)
  if (error.code !== "stock_adjust_required" && !isStockRole) return null
  return humanizeOperationError(error.code ?? error.message, undefined, undefined, { documentLabel: "ajuste de stock" }).message
}

/**
 * productos-padre-variantes (D1/D2): el padre rechaza campos que no lleva
 * (`parent_field_not_allowed`) y el tipo del producto no se cambia
 * (`stock_control_type_locked`).
 */
const CATALOG_CODES: ReadonlySet<string> = new Set(["parent_field_not_allowed", "stock_control_type_locked"])

function catalogApiErrorMessage(error: unknown): string | null {
  if (!(error instanceof PythonApiError) || !error.code || !CATALOG_CODES.has(error.code)) return null
  return humanizeOperationError(error.code, undefined, undefined, { documentLabel: "producto" }).message
}

/** Mensaje para el toast cuando falla el alta o la edición de un producto. */
export function productSaveErrorMessage(error: unknown): string {
  return (
    stockApiErrorMessage(error) ??
    catalogApiErrorMessage(error) ??
    (error instanceof Error && error.message ? error.message : "Error al guardar producto")
  )
}
