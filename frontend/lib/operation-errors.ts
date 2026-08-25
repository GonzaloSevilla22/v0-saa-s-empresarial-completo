/**
 * Traducción de errores de las RPCs de operaciones (venta/compra) a mensajes
 * que le sirvan al usuario.
 *
 * Origen (2026-08-24): el PO no podía vender y el mensaje era
 * `Insufficient stock for product 0dd2e5bb-2b93-4470-b4b6-52f008046112`.
 * Dos problemas: el UUID no le dice nada a nadie, y "no hay stock" es
 * literalmente falso — el producto TENÍA stock, pero en otra sucursal (la
 * venta descuenta de la sucursal de la operación, no del total del catálogo).
 * El mensaje mandaba a revisar el inventario, que era justo donde NO estaba
 * el problema.
 */

/** Devuelve el nombre del producto, o undefined si no se lo puede resolver. */
export type ProductNameLookup = (productId: string) => string | undefined

const STOCK_ERROR = /(?:insufficient_branch_stock|Insufficient stock) for product\s+([0-9a-f-]{36})/i

/**
 * Convierte el error crudo de una RPC de operación en un mensaje accionable.
 * Si no reconoce el error, devuelve el mensaje original (nunca lo oculta).
 */
export function humanizeOperationError(
  message: string,
  lookupProductName?: ProductNameLookup,
  branchName?: string | null,
): string {
  if (!message) return "Error desconocido"

  const stockMatch = message.match(STOCK_ERROR)
  if (stockMatch) {
    const productId = stockMatch[1]
    const name = lookupProductName?.(productId)
    const producto = name ? `«${name}»` : "uno de los productos"
    const sucursal = branchName ? `la sucursal ${branchName}` : "la sucursal de esta operación"
    return (
      `No hay stock de ${producto} en ${sucursal}. ` +
      `Puede haber unidades en otra sucursal: revisá el stock por sucursal o cambiá la sucursal de la venta.`
    )
  }

  return message
}
