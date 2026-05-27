import type { Product } from "@/lib/types"

/**
 * Visual breadcrumb for dropdowns and selectors.
 * Uses "›" as a decorative separator — never use this string for storage or search.
 *
 * - Variant: "Campera Algodón Frizado Kaese › Talle 4 Azul"
 * - Standalone / name already contains parent: product.name as-is
 */
export function getDisplayName(product: Product, parent?: Product): string {
  if (!parent) return product.name
  if (product.name.toLowerCase().startsWith(parent.name.toLowerCase())) return product.name
  return `${parent.name} › ${product.name}`
}

/**
 * Stable label for in-session persistence (cart, toasts, partial-success tracking).
 * Uses "/" — ASCII-safe, export-friendly, consistent across sessions.
 *
 * NOTE: sales.productName in the DB is populated via JOIN (r.product?.name),
 * not from this field. Changing this string has no impact on stored records.
 *
 * - Variant:     "Campera Algodón Frizado Kaese / Talle 4 Azul"
 * - Standalone:  "Remera Lisa"
 */
export function getCanonicalLabel(product: Product, parent?: Product): string {
  if (!parent) return product.name
  if (product.name.toLowerCase().startsWith(parent.name.toLowerCase())) return product.name
  return `${parent.name} / ${product.name}`
}

/**
 * Bare variant name — no parent context.
 * Use in narrow spaces where context is already established (cart column, chips, badges).
 */
export function getShortLabel(product: Product): string {
  return product.name
}

/**
 * Export-ready label for CSV, PDF, and receipts.
 * Appends SKU in parentheses when available.
 *
 * - With SKU:    "Campera Algodón Frizado Kaese / Talle 4 Azul (CAF-T4-AZU)"
 * - Without SKU: "Campera Algodón Frizado Kaese / Talle 4 Azul"
 */
export function getExportLabel(product: Product, parent?: Product): string {
  const base = getCanonicalLabel(product, parent)
  return product.sku ? `${base} (${product.sku})` : base
}

/**
 * Full-text search blob — lowercase, diacritics stripped.
 * Includes all tokens: variant name, parent name, SKU, barcode.
 *
 * Suitable for fuzzy matching, command palette scoring, and future OCR matching.
 * Never display this string — it is index-only.
 */
export function getSearchableLabel(product: Product, parent?: Product): string {
  return [product.name, parent?.name, product.sku, product.barcode]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
}
