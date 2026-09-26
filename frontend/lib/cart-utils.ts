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
