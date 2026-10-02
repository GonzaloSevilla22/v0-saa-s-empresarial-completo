/**
 * presupuestos-modulo (D12) — líneas del presupuesto que NO son un producto del
 * catálogo ("conceptos": un flete, una mano de obra) y armado del payload
 * `p_items` que une productos y servicios.
 *
 * Una línea de servicio no entra en `SaleCartItem`: su `productId` es
 * obligatorio, y `exceedsStock` y la fusión se indexan por producto. Vive en un
 * estado propio (`QuoteServiceLine[]`) con estos helpers puros. Los conceptos no
 * se fusionan: dos altas iguales son dos líneas.
 */
import { calcSaleSubtotal, unitPriceFromSubtotal, type SaleCartItem } from "@/lib/cart-utils"
import type { QuoteItemInput } from "@/lib/quote-types"

/** Tope de la descripción (el del schema del backend). */
export const SERVICE_DESCRIPTION_MAX = 200

export interface QuoteServiceLine {
  /** Identificador sólo del cliente (no se persiste). */
  id: string
  description: string
  quantity: number
  unitPrice: number
  /** Unidad opcional; se valida en servidor (del sistema o de la cuenta). */
  unitId?: string
  /** `unitPrice × quantity`, redondeado a 4 decimales. */
  subtotal: number
}

export interface ServiceLineInput {
  description: string
  quantity: number
  unitPrice: number
  unitId?: string
}

/** El motivo por el que la entrada no sirve, o `null` si es válida. */
export function validateServiceLineInput({ description, quantity, unitPrice }: ServiceLineInput): string | null {
  const text = description.trim()
  if (!text) return "Escribí la descripción del concepto"
  if (text.length > SERVICE_DESCRIPTION_MAX) {
    return `La descripción admite hasta ${SERVICE_DESCRIPTION_MAX} caracteres`
  }
  if (!(quantity > 0)) return "La cantidad debe ser mayor que cero"
  if (!(unitPrice >= 0)) return "El precio no puede ser negativo"
  return null
}

export function addServiceLine(lines: QuoteServiceLine[], input: ServiceLineInput): QuoteServiceLine[] {
  return [
    ...lines,
    {
      id: crypto.randomUUID(),
      description: input.description.trim(),
      quantity: input.quantity,
      unitPrice: input.unitPrice,
      unitId: input.unitId,
      subtotal: calcSaleSubtotal(input.unitPrice, input.quantity, 0),
    },
  ]
}

export function updateServiceLine(
  lines: QuoteServiceLine[],
  id: string,
  patch: Partial<ServiceLineInput>,
): QuoteServiceLine[] {
  return lines.map((line) => {
    if (line.id !== id) return line
    const quantity = patch.quantity ?? line.quantity
    const unitPrice = patch.unitPrice ?? line.unitPrice
    return {
      ...line,
      ...(patch.description !== undefined ? { description: patch.description.trim() } : {}),
      ...(patch.unitId !== undefined ? { unitId: patch.unitId } : {}),
      quantity,
      unitPrice,
      subtotal: calcSaleSubtotal(unitPrice, quantity, 0),
    }
  })
}

export function removeServiceLine(lines: QuoteServiceLine[], id: string): QuoteServiceLine[] {
  return lines.filter((line) => line.id !== id)
}

export interface BuildQuoteItemsInput {
  cartItems: SaleCartItem[]
  serviceLines: QuoteServiceLine[]
  /**
   * Ids (de línea de carrito o de servicio) en el orden en que el usuario las
   * cargó. Sin él: productos primero y después los servicios. Una línea que no
   * figura se agrega al final; un id que ya no existe se ignora.
   */
  loadOrder?: string[]
}

/**
 * El `p_items` de la RPC. Una línea de producto manda su precio unitario
 * EFECTIVO (`unitPriceFromSubtotal`, sin redondear a 4 decimales: RN-24-bis) y
 * su `subtotal`, así `precio × cantidad = subtotal` en el PDF; el descuento no
 * se manda aparte. Una de servicio va sin producto y con su descripción.
 */
export function buildQuoteItemsPayload({
  cartItems,
  serviceLines,
  loadOrder,
}: BuildQuoteItemsInput): QuoteItemInput[] {
  const byId = new Map<string, QuoteItemInput>()
  const natural: string[] = []

  for (const item of cartItems) {
    byId.set(item.id, {
      product_id: item.productId,
      unit_id: item.unitId ?? null,
      quantity: item.quantity,
      price: unitPriceFromSubtotal(item.subtotal, item.quantity),
      subtotal: item.subtotal,
    })
    natural.push(item.id)
  }
  for (const line of serviceLines) {
    byId.set(line.id, {
      product_id: null,
      unit_id: line.unitId ?? null,
      quantity: line.quantity,
      price: line.unitPrice,
      subtotal: line.subtotal,
      description: line.description,
    })
    natural.push(line.id)
  }

  const ordered: string[] = []
  const seen = new Set<string>()
  for (const id of loadOrder ?? []) {
    if (byId.has(id) && !seen.has(id)) {
      ordered.push(id)
      seen.add(id)
    }
  }
  for (const id of natural) if (!seen.has(id)) ordered.push(id)

  return ordered.map((id) => byId.get(id) as QuoteItemInput)
}
