/**
 * remitos-venta (D5/D11, tareas 5.1/5.2) — lógica pura del formulario del
 * remito, en la capa canónica para que el componente no lleve reglas propias.
 *
 *  - `rehydrateDeliveryNoteLines`: vuelve a armar el carrito a partir de las
 *    líneas guardadas, para EDITAR. Las líneas entran como líneas COMUNES, sin
 *    `source: "persisted"` (D11): en la venta `persisted` excluye la línea del
 *    chequeo de stock porque su cantidad "ya salió"; en el remito el disponible
 *    ya suma lo retenido, así que TODAS las líneas cuentan contra él y mezclar
 *    las dos contabilidades contaría lo retenido dos veces. El `quantityBase`
 *    sale de lo que el servidor guardó (lo que la línea retiene).
 *  - `buildDeliveryNoteItemsPayload`: el `items` de la API.
 *  - `validateDeliveryNoteDraft`: las reglas que el formulario chequea antes de
 *    llamar a la API (el servidor las vuelve a validar: defensa en profundidad).
 *
 * Una línea cuyo producto ya no está en el catálogo vivo (o que el servidor
 * marca `product_deleted`) NO se descarta ni bloquea el guardado: la mercadería
 * ya se entregó (OQ-RV3). Se marca para mostrar "se conserva lo entregado", no
 * admitir que aumente y pedir confirmación al quitarla.
 *
 * Sin líneas de servicio: un remito documenta mercadería que sale del depósito
 * (OQ-RV11), así que no hay "Agregar concepto".
 */
import {
  calcSaleSubtotal,
  unitPriceFromSubtotal,
  type CartContext,
  type SaleCartItem,
} from "@/lib/cart-utils"
import type { DeliveryNoteItemApiRow, DeliveryNoteItemInput } from "@/lib/delivery-note-types"
import { getCanonicalLabel } from "@/lib/product-labels"
import { resolveUnit, unitInputMin, unitInputStep } from "@/lib/unit-utils"

/** Tope del domicilio de entrega (el del schema del backend). */
export const DELIVERY_NOTE_ADDRESS_MAX = 500
/** Tope de las notas (el del schema del backend). */
export const DELIVERY_NOTE_NOTES_MAX = 2000

export const CLIENT_DELETED_SAVE_MESSAGE = "Cliente dado de baja — elegí uno vigente para guardar."

export interface RehydratedDeliveryNote {
  cartItems: SaleCartItem[]
  /** Ids de línea de carrito cuyo producto ya no está en el catálogo vivo. */
  deletedLineIds: string[]
  /** Ids de esos productos, sin repetir. */
  deletedProductIds: string[]
}

type IndexedRow = { row: DeliveryNoteItemApiRow; index: number }

function byLineNo(a: IndexedRow, b: IndexedRow): number {
  const left = a.row.line_no ?? Number.POSITIVE_INFINITY
  const right = b.row.line_no ?? Number.POSITIVE_INFINITY
  return left === right ? a.index - b.index : left - right
}

export function rehydrateDeliveryNoteLines(items: DeliveryNoteItemApiRow[], ctx: CartContext): RehydratedDeliveryNote {
  const result: RehydratedDeliveryNote = { cartItems: [], deletedLineIds: [], deletedProductIds: [] }

  const ordered = items.map((row, index) => ({ row, index })).sort(byLineNo)

  for (const { row } of ordered) {
    const quantity = Number(row.quantity)
    const price = Number(row.price)
    const product = ctx.products.find((p) => p.id === row.product_id)
    const lineUnit = resolveUnit(row.unit_id ?? undefined, ctx.unitsById)
    const baseUnit = resolveUnit(product?.baseUnitId, ctx.unitsById)
    const effectiveUnit = lineUnit ?? baseUnit
    const parent = product?.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined

    const item: SaleCartItem = {
      id: crypto.randomUUID(),
      productId: row.product_id,
      productName: product ? getCanonicalLabel(product, parent) : (row.name_snapshot ?? "Producto"),
      unitPrice: price,
      quantity,
      discount: 0,
      subtotal: calcSaleSubtotal(price, quantity, 0),
      unitId: row.unit_id ?? undefined,
      unitSymbol: lineUnit?.symbol,
      quantityBase: Number(row.quantity_base),
      step: unitInputStep(effectiveUnit),
      minQty: unitInputMin(effectiveUnit),
    }
    result.cartItems.push(item)

    if (!product || row.product_deleted) {
      result.deletedLineIds.push(item.id)
      if (!result.deletedProductIds.includes(row.product_id)) result.deletedProductIds.push(row.product_id)
    }
  }

  return result
}

/**
 * El `items` de la API. Cada línea manda su precio unitario EFECTIVO
 * (`unitPriceFromSubtotal`, sin redondear a 4 decimales: RN-24-bis) y su
 * `subtotal`, así `precio × cantidad = subtotal` en el PDF; el descuento no se
 * manda aparte.
 */
export function buildDeliveryNoteItemsPayload(cartItems: SaleCartItem[]): DeliveryNoteItemInput[] {
  return cartItems.map((item) => ({
    product_id: item.productId,
    unit_id: item.unitId ?? null,
    quantity: item.quantity,
    price: unitPriceFromSubtotal(item.subtotal, item.quantity),
    subtotal: item.subtotal,
  }))
}

export interface DeliveryNoteDraftCheck {
  clientId: string
  /** El cliente elegido es el congelado del remito, dado de baja después de emitir. */
  clientDeleted: boolean
  branchId: string | null
  /** Nombre de la sucursal elegida, para los textos. */
  branchName: string
  itemCount: number
  /** Nombres de los productos cuyas líneas superan el disponible de la sucursal elegida. */
  exceeding: string[]
  address: string
  notes: string
}

/** El primer motivo por el que el remito no se puede guardar, o `null`. */
export function validateDeliveryNoteDraft(draft: DeliveryNoteDraftCheck): string | null {
  if (!draft.clientId) return "Elegí un cliente: el remito se entrega a alguien."
  if (draft.clientDeleted) return CLIENT_DELETED_SAVE_MESSAGE
  if (!draft.branchId) return "Elegí la sucursal de la que sale la mercadería."
  if (draft.itemCount === 0) return "Agregá al menos un producto."
  if (draft.exceeding.length > 0) {
    return `No alcanza el stock de ${draft.branchName} para: ${draft.exceeding.join(", ")}. Bajá las cantidades o transferí stock.`
  }
  if (draft.address.length > DELIVERY_NOTE_ADDRESS_MAX) {
    return `El domicilio de entrega admite hasta ${DELIVERY_NOTE_ADDRESS_MAX} caracteres.`
  }
  if (draft.notes.length > DELIVERY_NOTE_NOTES_MAX) {
    return `Las notas admiten hasta ${DELIVERY_NOTE_NOTES_MAX} caracteres.`
  }
  return null
}
