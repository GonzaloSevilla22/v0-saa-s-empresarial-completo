import type { Product } from "@/lib/types"

/**
 * Single source of truth for "is this a real inventory line?".
 *
 * A product holds its own stock — meaning it can be counted, adjusted and
 * reordered at its own level — unless it is one of two catalogue constructs:
 *
 *   - `variant_only` → parent catalogue entry. Its stock lives in the variant
 *     children, so the parent's own `stock` / `minStock` fields are placeholders
 *     and would otherwise render a bogus "Crítico" / "A reponer" row in the
 *     stock table.
 *   - `untracked`    → service / digital product. Stock never changes, so there
 *     is nothing to reposition.
 *
 * Fail-open: any other (or missing) control type — `tracked`, `undefined`, or an
 * unexpected legacy value such as `"unit"` — counts as a real inventory item, so
 * a product is never hidden because of an unrecognised enum value.
 *
 * Use this everywhere the UI reasons about the physical-stock universe (the
 * stock table, the low-stock alert, the per-row adjust action) so the pages stay
 * consistent with a single rule.
 */
export function holdsOwnStock(product: Pick<Product, "stockControlType">): boolean {
  return (
    product.stockControlType !== "variant_only" &&
    product.stockControlType !== "untracked"
  )
}

/**
 * Health of a stock line relative to its configured reorder threshold.
 *
 *   - `sin-umbral` → no threshold configured (`minStock <= 0`). The product is
 *     NOT assessed for criticality; it is never shown red. This mirrors the
 *     canonical DB rule, which excludes products with no threshold from every
 *     alert and KPI:
 *       · `check_branch_low_stock` (RN-23): `NEW.min_stock > 0 AND quantity <= min_stock`
 *       · `get_dashboard_critical_stock`: `min_stock > 0 AND stock <= min_stock`
 *   - `critico`    → at or below the threshold (out of / short of stock).
 *   - `bajo`       → within 50% above the threshold (approaching the limit).
 *   - `ok`         → comfortably above the threshold.
 */
export type StockStatus = "critico" | "bajo" | "ok" | "sin-umbral"

export function getStockStatus(stock: number, minStock: number): StockStatus {
  if (minStock <= 0) return "sin-umbral"
  if (stock <= minStock) return "critico"
  if (stock <= minStock * 1.5) return "bajo"
  return "ok"
}

/**
 * True when a product is at or below its configured reorder threshold — the
 * exact condition the DB uses to flag critical stock and fire low-stock alerts.
 * Products with no threshold (`minStock <= 0`) are never below it.
 *
 * Single source of truth for "cuenta como stock crítico"; use it wherever the UI
 * counts or filters low-stock products so every view agrees.
 */
export function isBelowThreshold(stock: number, minStock: number): boolean {
  return getStockStatus(stock, minStock) === "critico"
}
