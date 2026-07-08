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
