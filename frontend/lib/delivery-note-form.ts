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
 *    Por SENTIDO (remitos-compra, D11): en compra la contraparte es el proveedor,
 *    la sucursal es la de destino, no hay domicilio ni control de faltante en el
 *    alta, y la edición tiene un mínimo por producto
 *    (`lib/delivery-note-stock`: `purchaseLinesBelowMinimum`).
 *  - `missingPriceLineCount` / `describeMissingPrices`: el remito de compra admite
 *    precio 0 al recibir (la factura llega después); el formulario avisa cuántas
 *    líneas quedan sin precio porque la conversión en compra las exige.
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
import type {
  DeliveryNoteDirection,
  DeliveryNoteItemApiRow,
  DeliveryNoteItemInput,
} from "@/lib/delivery-note-types"
import { getCanonicalLabel } from "@/lib/product-labels"
import { resolveUnit, unitInputMin, unitInputStep } from "@/lib/unit-utils"

/** Tope del domicilio de entrega (el del schema del backend). */
export const DELIVERY_NOTE_ADDRESS_MAX = 500
/** Tope de las notas (el del schema del backend). */
export const DELIVERY_NOTE_NOTES_MAX = 2000

/** Tope del número del remito del proveedor (el del schema del backend, `supplier_reference`). */
export const DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX = 100

export const CLIENT_DELETED_SAVE_MESSAGE = "Cliente dado de baja — elegí uno vigente para guardar."
export const SUPPLIER_DELETED_SAVE_MESSAGE = "Proveedor dado de baja — elegí uno vigente para guardar."

/** Aviso de una línea nueva de compra cuyo costo de catálogo es nulo (entra con precio 0). */
export const PURCHASE_LINE_NO_PRICE_NOTICE =
  "Sin precio: lo vas a poder cargar antes de convertir el remito en compra"

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
  /** Sentido del remito; sin él, venta (retrocompatible). */
  direction?: DeliveryNoteDirection
  /** Venta: el cliente elegido. Sin uso en compra. */
  clientId?: string
  /** Venta: el cliente elegido es el congelado del remito, dado de baja después de emitir. */
  clientDeleted?: boolean
  /** Compra: el proveedor elegido. */
  supplierId?: string
  /** Compra: el proveedor elegido es el congelado del remito, dado de baja después de recibir. */
  supplierDeleted?: boolean
  /** Compra: número del remito del proveedor (opcional, hasta 100 caracteres). */
  supplierReference?: string
  branchId: string | null
  /** Nombre de la sucursal elegida, para los textos. */
  branchName: string
  itemCount: number
  /** Venta: nombres de los productos cuyas líneas superan el disponible de la sucursal elegida. */
  exceeding: string[]
  /** Compra, edición: nombres de los productos cuyas líneas quedan por debajo de su mínimo. */
  belowMinimum?: string[]
  /** Venta: domicilio de entrega. En compra no existe y no se valida. */
  address: string
  notes: string
}

/** El primer motivo por el que el remito no se puede guardar, o `null`. */
export function validateDeliveryNoteDraft(draft: DeliveryNoteDraftCheck): string | null {
  if (draft.direction === "purchase") return validatePurchaseDraft(draft)
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

/**
 * Las reglas del remito de COMPRA. No hay control de faltante en el alta (entra
 * mercadería, no hay disponible que superar) ni domicilio de entrega; en la
 * edición, bajar de lo que todavía está en la sucursal se rechaza antes de la red
 * (el servidor lo vuelve a rechazar con `delivery_note_stock_consumed`).
 */
function validatePurchaseDraft(draft: DeliveryNoteDraftCheck): string | null {
  if (!draft.supplierId) return "Elegí un proveedor: el remito se recibe de alguien."
  if (draft.supplierDeleted) return SUPPLIER_DELETED_SAVE_MESSAGE
  if (!draft.branchId) return "Elegí la sucursal a la que entra la mercadería."
  if (draft.itemCount === 0) return "Agregá al menos un producto."
  const below = draft.belowMinimum ?? []
  if (below.length > 0) {
    return `No se puede bajar la cantidad de: ${below.join(", ")}. Esa mercadería ya no está toda en el stock de ${draft.branchName}: subí la cantidad o ajustá el stock.`
  }
  if ((draft.supplierReference ?? "").length > DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX) {
    return `El número del remito del proveedor admite hasta ${DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX} caracteres.`
  }
  if (draft.notes.length > DELIVERY_NOTE_NOTES_MAX) {
    return `Las notas admiten hasta ${DELIVERY_NOTE_NOTES_MAX} caracteres.`
  }
  return null
}

/**
 * Cuántas líneas del carrito quedan con precio 0. El precio efectivo sale del
 * subtotal (como lo manda `buildDeliveryNoteItemsPayload`), no de `unitPrice`.
 */
export function missingPriceLineCount(cartItems: Pick<SaleCartItem, "subtotal" | "quantity">[]): number {
  return cartItems.filter((item) => unitPriceFromSubtotal(item.subtotal, item.quantity) === 0).length
}

/**
 * El aviso del formulario de compra con líneas sin precio (se puede emitir igual:
 * el remito suma stock sin precios, y la conversión en compra los exige), o
 * `null` si no falta ninguno.
 */
export function describeMissingPrices(count: number): string | null {
  if (count <= 0) return null
  const lines = count === 1 ? "1 línea sin precio" : `${count} líneas sin precio`
  return `${lines}: lo vas a poder cargar antes de convertir el remito en compra.`
}
