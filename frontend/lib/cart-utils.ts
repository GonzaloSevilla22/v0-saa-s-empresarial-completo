/**
 * lib/cart-utils.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Cart types and pure math utilities shared between sale-form and purchase-form.
 *
 * ⚠️  Pure logic only — no persistence, no Supabase calls, no React.
 *     Each form manages its own independent cart state and calls the
 *     appropriate service upon submission.
 *
 * Precision contract
 * - All subtotals are rounded to 4 decimal places (matches NUMERIC(15,4) in DB)
 * - toFixed(4) via _round4 prevents floating-point drift (1.1 * 3 ≠ 3.3000…03)
 * - A line UNIT PRICE is NOT rounded to a fixed number of decimals
 *   (ventas-unidades-conversion D-F′): re-expressed per gram a catalogue price
 *   with cents needs 5 decimals ($1.234,56/kg = $1,23456/g) and, per mg, 8.
 *   `roundUnitPrice` only strips binary noise (15 significant digits); the
 *   price columns of every document line are unconstrained NUMERIC.
 */

import { getCanonicalLabel } from "@/lib/product-labels"
import { isProductoMedible, resolveUnit, unitInputMin } from "@/lib/unit-utils"
import type { Product, UnitOfMeasure } from "@/lib/types"

// ─── Operation ID ─────────────────────────────────────────────────────────────

/**
 * Generates a UUID v4 to logically group all items submitted from the same
 * cart operation. Stored in sales.operation_id / purchases.operation_id.
 */
export function generateOperationId(): string {
  return crypto.randomUUID()
}

// ─── Sale Cart ────────────────────────────────────────────────────────────────

export interface SaleCartItem {
  /** Frontend-only identifier (not persisted). */
  id: string
  productId: string
  productName: string
  /** Catalogue unit price (before discount). */
  unitPrice: number
  /** Visual quantity — in the selected unit (may be fractional for medibles). */
  quantity: number
  /** Discount percentage applied to this item (0–100). */
  discount: number
  /** Pre-computed: unitPrice × qty × (1 − discount/100), rounded to 4dp. */
  subtotal: number
  // ── Unit of measure ────────────────────────────────────────────────────────
  /** UUID of the selected unit; undefined = base unit (factor 1). */
  unitId?: string
  /** Symbol shown in cart and on receipt (e.g. "kg", "doc"). */
  unitSymbol?: string
  /**
   * Visual qty converted to the PRODUCT's base unit (ventas-unidades-conversion
   * D1/D5) — pre-normalized for local stock validation only; the server
   * normalizes again with the single SQL definition and is the one that decides.
   */
  quantityBase?: number
  // ── Input constraints (driven by unit type) ────────────────────────────────
  /** HTML input step: 1 for unitarios, 0.001 for medibles. */
  step?: number
  /** Minimum quantity: mirrors step. */
  minQty?: number
  /**
   * balanza-etiquetas-pos (D8): origen de la línea.
   * - `"scale"`:     una etiqueta de balanza leída en esta sesión — nunca se
   *   fusiona con otra alta (código común, SKU o manual): cada pesada es una
   *   línea propia con su propio importe.
   * - `"persisted"`: una línea rehidratada al editar una venta existente —
   *   tampoco se fusiona (su cantidad ya salió de `product.stock`) y no
   *   cuenta contra el disponible en `exceedsStock`.
   * - `undefined`:   una línea creada a mano o por código común/SKU en esta
   *   sesión — la única fusionable.
   */
  source?: "scale" | "persisted"
}

export function calcSaleSubtotal(
  unitPrice: number,
  qty: number,
  discount: number,
): number {
  return _round4(unitPrice * qty * (1 - discount / 100))
}

/**
 * Inverse of calcSaleSubtotal for the discount-free case: given a desired line
 * subtotal and quantity, returns the effective unit price (rounded to 4dp).
 *
 * Used when the user edits the Subtotal field directly to hit the exact price a
 * sale closed at (when a % discount can't land on a round number). The result
 * becomes the stored `amount` (effective unit price); discount resets to 0.
 *
 * Guards qty <= 0 → returns 0 to avoid division by zero / Infinity.
 */
export function unitPriceFromSubtotal(subtotal: number, qty: number): number {
  if (qty <= 0) return 0
  return roundUnitPrice(subtotal / qty)
}

/**
 * Cleans the binary floating-point noise of a line UNIT PRICE without
 * truncating its precision (ventas-unidades-conversion D-F′, provisional until
 * the PO signs off): 15 significant digits, the precision a double carries
 * reliably. Rounding to a fixed 4 decimals broke the line total as soon as the
 * unit is small — $1.234,56/kg is $1,23456/g, and 1,2346 × 450 g charged
 * $555,57 instead of $555,552 (in mg, 1000× worse); a subtotal typed on a line
 * in grams did not round-trip either (2000 / 450 → 4,4444 → $1.999,98).
 *
 * @example
 * roundUnitPrice(1234.56 * 0.001)   → 1.23456   (not 1.2345599999999999)
 * roundUnitPrice(1.1 * 0.001)       → 0.0011    (not 0.0011000000000000001)
 * roundUnitPrice(10000 / 3)         → 3333.33333333333
 */
export function roundUnitPrice(price: number): number {
  if (!Number.isFinite(price)) return price
  return Number(price.toPrecision(15))
}

// ─── Purchase Cart ────────────────────────────────────────────────────────────

export interface PurchaseCartItem {
  /** Frontend-only identifier (not persisted). */
  id: string
  productId: string
  productName: string
  unitCost: number
  /** Visual quantity — in the selected unit (may be fractional for medibles). */
  quantity: number
  /** Pre-computed: unitCost × qty, rounded to 4dp. */
  subtotal: number
  // ── Unit of measure ────────────────────────────────────────────────────────
  /** UUID of the selected unit; undefined = base unit (factor 1). */
  unitId?: string
  /** Symbol shown in cart (e.g. "kg", "doc"). */
  unitSymbol?: string
  /** Visual qty converted to the PRODUCT's base unit — local validation only. */
  quantityBase?: number
  // ── Input constraints (driven by unit type) ────────────────────────────────
  /** HTML input step: 1 for unitarios, 0.001 for medibles. */
  step?: number
  /** Minimum quantity: mirrors step. */
  minQty?: number
}

export function calcPurchaseSubtotal(unitCost: number, qty: number): number {
  return _round4(unitCost * qty)
}

// ─── Shared ───────────────────────────────────────────────────────────────────

export function calcCartTotal(items: { subtotal: number }[]): number {
  return _round4(items.reduce((sum, item) => sum + item.subtotal, 0))
}

// ─── Internal ─────────────────────────────────────────────────────────────────

/** Rounds to 4 decimal places — matches NUMERIC(15,4) precision in the DB. */
function _round4(n: number): number {
  return Math.round(n * 10_000) / 10_000
}


// ─── balanza-etiquetas-pos (D7/D8) ─────────────────────────────────────────────

/**
 * Chequeo de stock ACUMULATIVO (D7, OQ-9): suma el `quantityBase` de todas
 * las líneas del carrito del MISMO producto agregadas en esta sesión
 * (`source !== "persisted"` — al editar una venta, esas líneas ya salieron de
 * `product.stock`) más `addBase`, y compara contra `stock`. Usado tanto por
 * una etiqueta de balanza como por el alta manual (POS y formulario de venta),
 * en sus dos ramas (fusión y línea nueva) — antes cada pantalla sólo medía la
 * línea que estaba tocando, lo que dejaba pasar dos etiquetas que juntas
 * superaban el disponible.
 */
export function exceedsStock(
  items: Pick<SaleCartItem, "productId" | "source" | "quantityBase">[],
  productId: string,
  addBase: number,
  stock: number,
): boolean {
  const sumBase = items
    .filter((item) => item.productId === productId && item.source !== "persisted")
    .reduce((sum, item) => sum + (item.quantityBase ?? 0), 0)
  return sumBase + addBase > stock
}

export interface AddScannedProductLineContext {
  unitsById: Map<string, UnitOfMeasure>
  /** Catálogo completo — para resolver el nombre del producto con su padre. */
  products: Product[]
}

export type AddScannedProductLineResult =
  | { items: SaleCartItem[] }
  | { needsQuantity: true }

/**
 * Alta de un producto encontrado por CÓDIGO COMÚN o SKU (D6/D8) — nunca por
 * una etiqueta de balanza (esa la resuelve `resolveScaleScan`, D7). Reglas:
 *
 * - Producto **por unidades**: suma `unitInputMin` a la línea NO-balanza
 *   (`source` ausente) del mismo producto y unidad base, conservando el
 *   `unitPrice` de esa línea (un precio editado a mano no se pisa con el del
 *   catálogo); si no hay una línea así, crea una con el precio del catálogo.
 *   Nunca fusiona sobre una línea `"scale"` ni `"persisted"`.
 * - Producto **medible** (peso, volumen, longitud, personalizada): NO agrega
 *   una cantidad mínima arbitraria — devuelve `{ needsQuantity: true }` para
 *   que la pantalla deje el producto elegido en su selector con el foco en
 *   "Cantidad".
 */
export function addScannedProductLine(
  items: SaleCartItem[],
  product: Product,
  ctx: AddScannedProductLineContext,
): AddScannedProductLineResult {
  const baseUnit = resolveUnit(product.baseUnitId, ctx.unitsById)

  if (isProductoMedible(baseUnit)) {
    return { needsQuantity: true }
  }

  // Fix F4 (revisión adversarial PR #599): el alta MANUAL (POS y formulario
  // de venta) guarda `unitId: product.baseUnitId` para un producto con
  // unidad base con nombre propio (nunca `undefined`) — comparar contra
  // `!item.unitId` nunca encontraba esa línea y creaba una segunda. La
  // comparación correcta es "la unidad base del producto", igual que el
  // alta manual (`(item.unitId ?? '') === unitId`, D8).
  const existingIndex = items.findIndex(
    (item) =>
      item.productId === product.id &&
      !item.source &&
      (item.unitId ?? product.baseUnitId ?? "") === (product.baseUnitId ?? ""),
  )
  const addQty = unitInputMin(baseUnit)

  if (existingIndex >= 0) {
    const existing = items[existingIndex]
    const newQty = existing.quantity + addQty
    const nextItems = items.slice()
    nextItems[existingIndex] = {
      ...existing,
      quantity: newQty,
      quantityBase: newQty,
      subtotal: calcSaleSubtotal(existing.unitPrice, newQty, existing.discount),
    }
    return { items: nextItems }
  }

  const parent = product.parentId ? ctx.products.find((p) => p.id === product.parentId) : undefined
  const newLine: SaleCartItem = {
    id: crypto.randomUUID(),
    productId: product.id,
    productName: getCanonicalLabel(product, parent),
    unitPrice: product.price,
    quantity: addQty,
    discount: 0,
    subtotal: calcSaleSubtotal(product.price, addQty, 0),
    // F4: la línea nueva nace con la MISMA unidad que el alta manual
    // (`product.baseUnitId`), no `undefined` — así un escaneo posterior del
    // mismo producto la encuentra y fusiona en vez de crear una tercera.
    unitId: product.baseUnitId || undefined,
    unitSymbol: baseUnit?.symbol,
    quantityBase: addQty,
    step: addQty,
    minQty: addQty,
  }
  return { items: [...items, newLine] }
}
