/**
 * Cart utilities shared between sale-form and purchase-form.
 *
 * ⚠️  Pure logic only — no persistence, no Supabase calls.
 *     Each form manages its own independent cart state and
 *     calls the appropriate service upon submission.
 */

// ─── Operation ID ─────────────────────────────────────────────────────────────

/**
 * Generates a UUID v4 to logically group all items submitted
 * from the same cart operation. Stored in `sales.operation_id`
 * and `purchases.operation_id` for future analytics / migration.
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
  /** Base unit price from the product catalogue. */
  unitPrice: number
  quantity: number
  /** Discount percentage applied to this item (0–100). */
  discount: number
  /** Pre-computed: unitPrice × qty × (1 − discount/100). */
  subtotal: number
}

export function calcSaleSubtotal(
  unitPrice: number,
  qty: number,
  discount: number,
): number {
  return unitPrice * qty * (1 - discount / 100)
}

// ─── Purchase Cart ────────────────────────────────────────────────────────────

export interface PurchaseCartItem {
  /** Frontend-only identifier (not persisted). */
  id: string
  productId: string
  productName: string
  unitCost: number
  quantity: number
  /** Pre-computed: unitCost × qty. */
  subtotal: number
}

export function calcPurchaseSubtotal(unitCost: number, qty: number): number {
  return unitCost * qty
}

// ─── Shared ───────────────────────────────────────────────────────────────────

export function calcCartTotal(items: { subtotal: number }[]): number {
  return items.reduce((sum, item) => sum + item.subtotal, 0)
}
