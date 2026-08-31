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
 *
 * sucursal-guard-vaciado-auditoria (G3, task 7.4): el aviso ya explicaba que
 * podía haber unidades en otra sucursal, pero dejaba al usuario buscando
 * dónde se transfiere. `humanizeOperationError` pasa a devolver, además del
 * texto, una acción opcional (etiqueta + destino) hacia la transferencia del
 * producto involucrado — CAMBIO DE CONTRATO (string -> objeto). Se migran
 * los dos call sites existentes en el mismo PR (regla del proyecto: al
 * endurecer un contrato, migrar TODOS los callers) — sale-form.tsx era el
 * único consumidor.
 */

/** Devuelve el nombre del producto, o undefined si no se lo puede resolver. */
export type ProductNameLookup = (productId: string) => string | undefined

export interface OperationErrorAction {
  label: string
  /** Ruta a la que navegar — /stock con el producto preseleccionado. */
  href: string
}

export interface HumanizedOperationError {
  message: string
  /** Presente sólo cuando el error reconocido tiene una acción que lo destraba. */
  action?: OperationErrorAction
}

const STOCK_ERROR = /(?:insufficient_branch_stock|Insufficient stock) for product\s+([0-9a-f-]{36})/i

// qa-integral-modulos G10 (H21a): tres details crudos que el QA vio impresos
// tal cual al usuario — mismo mapa, sin crear otro (regla del proyecto).
const RN_B4_ERROR = /RN-B4: el producto "([^"]+)" tiene stock \(([\d.]+)\)/i
const AMOUNTS_MISMATCH_ERROR =
  /amounts_mismatch(?::\s*Σ líneas \((-?[\d.]+)\) ≠ Σ movimientos \((-?[\d.]+)\))?/
const PERIODO_INVALIDO_ERROR = /periodo_invalido/

const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

/**
 * Convierte el error crudo de una RPC de operación en un mensaje accionable.
 * Si no reconoce el error, devuelve el mensaje original sin acción (nunca lo
 * oculta).
 */
export function humanizeOperationError(
  message: string,
  lookupProductName?: ProductNameLookup,
  branchName?: string | null,
): HumanizedOperationError {
  if (!message) return { message: "Error desconocido" }

  const stockMatch = message.match(STOCK_ERROR)
  if (stockMatch) {
    const productId = stockMatch[1]
    const name = lookupProductName?.(productId)
    const producto = name ? `«${name}»` : "uno de los productos"
    const sucursal = branchName ? `la sucursal ${branchName}` : "la sucursal de esta operación"
    return {
      message:
        `No hay stock de ${producto} en ${sucursal}. ` +
        `Puede haber unidades en otra sucursal: revisá el stock por sucursal o cambiá la sucursal de la venta.`,
      action: {
        label: "Transferir stock",
        href: `/stock?product=${productId}`,
      },
    }
  }

  const rnB4Match = message.match(RN_B4_ERROR)
  if (rnB4Match) {
    const [, name, rawQty] = rnB4Match
    const qty = Number(rawQty) // "6.0000" → 6, sin los 4 decimales internos
    const unidades = qty === 1 ? "1 unidad" : `${qty.toLocaleString("es-AR")} unidades`
    return {
      message:
        `No se puede borrar «${name}» porque todavía tiene stock (${unidades}). ` +
        `Llevá su stock a 0 (vendé, ajustá o transferí las unidades) y volvé a intentarlo.`,
    }
  }

  const mismatchMatch = message.match(AMOUNTS_MISMATCH_ERROR)
  if (mismatchMatch) {
    const [, rawLines, rawMovs] = mismatchMatch
    const detalle =
      rawLines != null && rawMovs != null
        ? `las líneas seleccionadas del extracto suman ${fmtMoney(Number(rawLines))} y los movimientos ${fmtMoney(Number(rawMovs))}`
        : "lo seleccionado del extracto y los movimientos tienen totales distintos"
    return {
      message: `Las sumas no coinciden: ${detalle}. Ajustá la selección hasta que los dos totales sean iguales.`,
    }
  }

  if (PERIODO_INVALIDO_ERROR.test(message)) {
    return {
      message:
        "El período está invertido: la fecha «Desde» tiene que ser anterior o igual a «Hasta».",
    }
  }

  return { message }
}
