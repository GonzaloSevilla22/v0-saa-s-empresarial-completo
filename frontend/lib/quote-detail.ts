/**
 * presupuestos-modulo (D10) — reglas puras del detalle del presupuesto, en la
 * capa canónica para que la pantalla no decida nada por su cuenta.
 *
 *  - `quoteActions`: la tabla de acciones por estado y rol de D10. La decisión de
 *    rol (`canQuote`) la toma el llamador con `hasCapability` sobre el CONJUNTO de
 *    roles; el backend es la barrera real (RPC `P0403`).
 *  - `isModifiedAfterSent`: "Modificado después de enviado".
 *  - `catalogPriceHint`: el precio de lista de hoy, sólo informativo.
 */
import { convertUnitPrice, resolveUnit } from "@/lib/unit-utils"
import type { QuoteApiRow, QuoteItemApiRow } from "@/lib/quote-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

export interface QuoteActions {
  /** Editar (en `expired`/`rejected` lo reabre como borrador). Todo estado menos `accepted`. */
  canEdit: boolean
  /** Botón explícito "Marcar como enviado". Sólo en `draft`. */
  canMarkSent: boolean
  /** Descargar o mandar por WhatsApp marca como enviado: sólo con permiso y en `draft`. */
  markSentOnShare: boolean
  /** El botón "Venta" se muestra (en la tanda A, siempre deshabilitado). */
  showSaleButton: boolean
  /** Con `showSaleButton`: el presupuesto está vencido (derivado), la venta se explica por eso. */
  saleBlockedByExpiry: boolean
  canReject: boolean
  canDuplicate: boolean
  /** Sólo un `draft` NUNCA enviado admite eliminarse. */
  canDelete: boolean
  /** `accepted` con una orden generada: enlace a la venta (lectura, sin exigir rol). */
  showViewSale: boolean
}

type QuoteActionsInput = Pick<QuoteApiRow, "status" | "is_expired" | "sent_at" | "sales_order_id">

export function quoteActions(quote: QuoteActionsInput, canQuote: boolean): QuoteActions {
  const open = quote.status === "draft" || quote.status === "sent"
  const showSaleButton = canQuote && open
  return {
    canEdit: canQuote && quote.status !== "accepted",
    canMarkSent: canQuote && quote.status === "draft",
    markSentOnShare: canQuote && quote.status === "draft",
    showSaleButton,
    saleBlockedByExpiry: showSaleButton && quote.is_expired,
    canReject: canQuote && open,
    canDuplicate: canQuote,
    canDelete: canQuote && quote.status === "draft" && !quote.sent_at,
    showViewSale: quote.status === "accepted" && !!quote.sales_order_id,
  }
}

/** ¿Se editó después de haberse enviado? (el cliente puede tener la versión vieja) */
export function isModifiedAfterSent(quote: Pick<QuoteApiRow, "sent_at" | "updated_at">): boolean {
  if (!quote.sent_at || !quote.updated_at) return false
  return new Date(quote.updated_at).getTime() > new Date(quote.sent_at).getTime()
}

/** Nombre del archivo del PDF: `presupuesto-P-00000012.pdf`. */
export function quoteFileName(numberLabel: string | null): string {
  return numberLabel ? `presupuesto-${numberLabel}.pdf` : "presupuesto.pdf"
}

const PRICE_EPSILON = 1e-9

/**
 * El precio de lista de HOY en la unidad de la línea, si difiere del precio
 * efectivo cotizado; `null` si coincide, si la línea es un concepto o si su
 * producto ya no está en el catálogo. Es informativo: nunca cambia lo cotizado.
 */
export function catalogPriceHint(
  line: QuoteItemApiRow,
  products: Product[],
  unitsById: Map<string, UnitOfMeasure>,
): number | null {
  if (!line.product_id) return null
  const product = products.find((p) => p.id === line.product_id)
  if (!product) return null
  const baseUnit = resolveUnit(product.baseUnitId, unitsById)
  const lineUnit = resolveUnit(line.unit_id ?? undefined, unitsById)
  const current = convertUnitPrice(product.price, baseUnit, lineUnit, baseUnit)
  return Math.abs(current - Number(line.price)) > PRICE_EPSILON ? current : null
}
