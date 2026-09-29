/**
 * lib/scan-resolution.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * balanza-etiquetas-pos (D6) — `resolveScan`, la ÚNICA función que decide qué
 * hacer con un código leído. Usada por el POS y por el formulario de venta;
 * ninguna de las dos pantallas reimplementa este orden.
 *
 * Orden de resolución: código de barras exacto → etiqueta de balanza → SKU
 * exacto → error (D6, desvío deliberado del dossier que proponía balanza
 * primero — ver D6 en design.md para el porqué).
 */

import { decodeScaleBarcode, scaleDecodeErrorMessage } from "@/lib/scale-barcode"
import { resolveScaleScan, type ScaleCartLine } from "@/lib/scale-cart"
import { validateEAN13 } from "@/lib/barcode-utils"
import type { ScaleSettings } from "@/lib/scale-layout"
import type { Product, UnitOfMeasure } from "@/lib/types"

// ─── Tipos ──────────────────────────────────────────────────────────────────

export type ScanResult =
  | { kind: "product"; product: Product }
  | { kind: "scale_line"; line: ScaleCartLine }
  | { kind: "error"; message: string }

export interface ScanContext {
  /** Productos vivos de la cuenta (padres con variantes se excluyen, D6). */
  products: Product[]
  units: UnitOfMeasure[]
  unitsById: Map<string, UnitOfMeasure>
  settings: ScaleSettings
}

// ─── Internos ─────────────────────────────────────────────────────────────────

/** Productos que SON padre de al menos una variante — excluidos de toda búsqueda (D6). */
function parentIds(products: Product[]): Set<string> {
  const ids = new Set<string>()
  for (const p of products) if (p.parentId) ids.add(p.parentId)
  return ids
}

function sellableProducts(products: Product[]): Product[] {
  const parents = parentIds(products)
  return products.filter((p) => !parents.has(p.id))
}

function findBySkuExact(products: Product[], code: string): Product | undefined {
  const upper = code.toUpperCase()
  return sellableProducts(products).find((p) => p.sku && p.sku.toUpperCase() === upper)
}

/**
 * Paso 1 (D6): coincidencia exacta con mayúsculas primero; si no hay, sin
 * distinguir mayúsculas SÓLO si da un único candidato. Con más de uno,
 * termina la resolución con un error (nunca sigue buscando).
 */
function resolveByBarcode(products: Product[], code: string): { product: Product } | { error: string } | null {
  const sellable = sellableProducts(products)
  const exact = sellable.filter((p) => p.barcode === code)
  if (exact.length === 1) return { product: exact[0] }
  if (exact.length > 1) return { error: `El código coincide con ${exact.length} productos` }

  const upper = code.toUpperCase()
  const caseInsensitive = sellable.filter((p) => p.barcode && p.barcode.toUpperCase() === upper)
  if (caseInsensitive.length === 1) return { product: caseInsensitive[0] }
  if (caseInsensitive.length > 1) return { error: `El código coincide con ${caseInsensitive.length} productos` }

  return null
}

function likelyScaleLabelMessage(code: string, reason: "disabled" | "no_layout_match"): string {
  if (reason === "disabled") {
    return "Parece una etiqueta de balanza, pero la lectura de etiquetas está deshabilitada — activala en Configuración → Balanza"
  }
  const header = code.slice(0, 2)
  return `Parece una etiqueta de balanza (cabecera ${header}) que no coincide con ningún formato configurado — revisá Configuración → Balanza`
}

function notFoundMessage(code: string, reason: "disabled" | "not_ean13" | "no_layout_match"): string {
  // Sólo un EAN-13 válido con cabecera de circulación restringida (empieza
  // con "2") amerita la explicación de "parece una etiqueta" (D6 paso 4).
  if ((reason === "disabled" || reason === "no_layout_match") && validateEAN13(code) && code.startsWith("2")) {
    return likelyScaleLabelMessage(code, reason)
  }
  return `Código "${code}" no encontrado`
}

// ─── API ────────────────────────────────────────────────────────────────────

/**
 * Resuelve un código leído por el lector (D6). Nunca lanza.
 */
export function resolveScan(code: string, ctx: ScanContext): ScanResult {
  // Paso 1: código de barras exacto.
  const byBarcode = resolveByBarcode(ctx.products, code)
  if (byBarcode) {
    if ("error" in byBarcode) return { kind: "error", message: byBarcode.error }
    return { kind: "product", product: byBarcode.product }
  }

  // Paso 2: etiqueta de balanza.
  const decoded = decodeScaleBarcode(code, ctx.settings)

  if (decoded.status === "ok") {
    const resolved = resolveScaleScan(decoded, { products: ctx.products, units: ctx.units, unitsById: ctx.unitsById })
    if (resolved.ok) return { kind: "scale_line", line: resolved.line }
    return { kind: "error", message: resolved.message }
  }

  if (decoded.status === "invalid" || decoded.status === "unsupported") {
    // Antes del error final se prueba el SKU exacto con el MISMO código: no
    // le robamos a un producto un SKU que casualmente tiene forma de etiqueta.
    const bySku = findBySkuExact(ctx.products, code)
    if (bySku) return { kind: "product", product: bySku }
    return { kind: "error", message: scaleDecodeErrorMessage(decoded) }
  }

  // not_scale → Paso 3: SKU exacto (sin distinguir mayúsculas).
  const bySku = findBySkuExact(ctx.products, code)
  if (bySku) return { kind: "product", product: bySku }

  // Paso 4: nada encontrado.
  return { kind: "error", message: notFoundMessage(code, decoded.reason) }
}
