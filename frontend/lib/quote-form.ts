/**
 * presupuestos-modulo (D12) — lógica pura del formulario de presupuesto, en la
 * capa canónica para que el componente no lleve reglas propias.
 *
 *  - `rehydrateQuoteLines`: vuelve a armar el carrito y los conceptos a partir
 *    de las líneas persistidas, para EDITAR (precio efectivo guardado, descuento
 *    0, igual que `sale-form`) o DUPLICAR (precio de HOY del catálogo,
 *    reexpresado a la unidad de la línea, con el aviso de lo que cambió).
 *  - `defaultQuoteValidUntil` / `validateQuoteDraft`: validez por defecto de la
 *    cuenta y las reglas que el formulario chequea antes de llamar a la API
 *    (el servidor las vuelve a validar: defensa en profundidad).
 *
 * Una línea cuyo producto ya no está en el catálogo vivo NO se descarta: queda
 * en el carrito, marcada, y bloquea el guardado. Sin esto, guardar sin tocarla
 * fallaría con `product_not_found` y el mensaje accionable de la conversión
 * ("editá el presupuesto") no tendría salida.
 */
import { getCanonicalLabel } from "@/lib/product-labels"
import {
  calcSaleSubtotal,
  type CartContext,
  type SaleCartItem,
} from "@/lib/cart-utils"
import type { QuoteServiceLine } from "@/lib/quote-lines"
import type { QuoteItemApiRow } from "@/lib/quote-types"
import { addDaysToIsoDate } from "@/lib/receivables-aging"
import { convertUnitPrice, resolveUnit, toBaseQuantity, unitInputMin, unitInputStep } from "@/lib/unit-utils"

/** Tope de las notas (el del schema del backend y el `CHECK` de la columna). */
export const QUOTE_NOTES_MAX = 2000

export type RehydrateMode = "edit" | "duplicate"

export interface QuotePriceChange {
  name: string
  /** Precio unitario efectivo con que se había cotizado. */
  previous: number
  /** Precio de hoy del catálogo, en la unidad de la línea. */
  current: number
}

export interface RehydratedQuote {
  cartItems: SaleCartItem[]
  serviceLines: QuoteServiceLine[]
  /** Ids (de línea de carrito o de concepto) en el orden en que se cargaron. */
  loadOrder: string[]
  /** Ids de línea de carrito cuyo producto ya no está en el catálogo vivo. */
  unavailableIds: string[]
  /** Sólo en `duplicate`: las líneas cuyo precio de hoy difiere del cotizado. */
  priceChanges: QuotePriceChange[]
}

const PRICE_EPSILON = 1e-9

function byLineNo(a: { row: QuoteItemApiRow; index: number }, b: { row: QuoteItemApiRow; index: number }): number {
  const left = a.row.line_no ?? Number.POSITIVE_INFINITY
  const right = b.row.line_no ?? Number.POSITIVE_INFINITY
  return left === right ? a.index - b.index : left - right
}

export function rehydrateQuoteLines(
  items: QuoteItemApiRow[],
  ctx: CartContext,
  mode: RehydrateMode,
): RehydratedQuote {
  const result: RehydratedQuote = {
    cartItems: [],
    serviceLines: [],
    loadOrder: [],
    unavailableIds: [],
    priceChanges: [],
  }

  const ordered = items.map((row, index) => ({ row, index })).sort(byLineNo)

  for (const { row } of ordered) {
    const quantity = Number(row.quantity)
    const quotedPrice = Number(row.price)

    // ── Concepto (línea de servicio): conserva su precio también al duplicar ──
    if (!row.product_id) {
      const line: QuoteServiceLine = {
        id: crypto.randomUUID(),
        description: row.name_snapshot ?? "",
        quantity,
        unitPrice: quotedPrice,
        unitId: row.unit_id ?? undefined,
        subtotal: calcSaleSubtotal(quotedPrice, quantity, 0),
      }
      result.serviceLines.push(line)
      result.loadOrder.push(line.id)
      continue
    }

    // ── Línea de producto ────────────────────────────────────────────────────
    const product = ctx.products.find((p) => p.id === row.product_id)
    const lineUnit = resolveUnit(row.unit_id ?? undefined, ctx.unitsById)
    const baseUnit = resolveUnit(product?.baseUnitId, ctx.unitsById)
    const effectiveUnit = lineUnit ?? baseUnit

    let unitPrice = quotedPrice
    if (mode === "duplicate" && product) {
      // El precio de catálogo está en la unidad BASE: se reexpresa a la de la línea.
      unitPrice = convertUnitPrice(product.price, baseUnit, lineUnit, baseUnit)
      if (Math.abs(unitPrice - quotedPrice) > PRICE_EPSILON) {
        result.priceChanges.push({
          name: row.name_snapshot ?? product.name,
          previous: quotedPrice,
          current: unitPrice,
        })
      }
    }

    const parent = product?.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined
    const item: SaleCartItem = {
      id: crypto.randomUUID(),
      productId: row.product_id,
      productName: product ? getCanonicalLabel(product, parent) : (row.name_snapshot ?? "Producto"),
      unitPrice,
      quantity,
      discount: 0,
      subtotal: calcSaleSubtotal(unitPrice, quantity, 0),
      unitId: row.unit_id ?? undefined,
      unitSymbol: lineUnit?.symbol,
      quantityBase: toBaseQuantity(quantity, lineUnit, baseUnit),
      step: unitInputStep(effectiveUnit),
      minQty: unitInputMin(effectiveUnit),
    }
    result.cartItems.push(item)
    result.loadOrder.push(item.id)
    if (!product) result.unavailableIds.push(item.id)
  }

  return result
}

/** `hoy + días de validez de la cuenta`, como fecha ISO de negocio. */
export function defaultQuoteValidUntil(todayIso: string, validityDays: number): string {
  return addDaysToIsoDate(todayIso, validityDays)
}

export interface QuoteDraftCheck {
  clientId: string
  /** Líneas de producto + conceptos. */
  itemCount: number
  validUntil: string
  /** Hoy, fecha de negocio ART (`YYYY-MM-DD`). */
  today: string
  notes: string
  /** Líneas cuyo producto ya no está en el catálogo vivo. */
  unavailableCount: number
}

/** El primer motivo por el que el presupuesto no se puede guardar, o `null`. */
export function validateQuoteDraft(draft: QuoteDraftCheck): string | null {
  if (!draft.clientId) return "Elegí un cliente: el presupuesto se le manda a alguien."
  if (draft.itemCount === 0) return "Agregá al menos un producto o concepto."
  if (draft.unavailableCount > 0) {
    return "Hay productos no disponibles: quitalos o reemplazalos antes de guardar."
  }
  if (!draft.validUntil) return "Indicá la validez del presupuesto (hasta cuándo vale)."
  if (draft.validUntil < draft.today) return "La validez tiene que ser hoy o una fecha posterior."
  if (draft.notes.length > QUOTE_NOTES_MAX) {
    return `Las notas admiten hasta ${QUOTE_NOTES_MAX} caracteres.`
  }
  return null
}
