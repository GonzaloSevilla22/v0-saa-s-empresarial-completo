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
  /** Conversion factor to base unit — used for server-side stock accounting. */
  unitFactor?: number
  /** Visual qty × unitFactor — pre-normalized for local stock validation. */
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
  return _round4(subtotal / qty)
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
  /** Conversion factor to base unit. */
  unitFactor?: number
  /** Visual qty × unitFactor — pre-normalized for local validation. */
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
