/**
 * Client-side product matching for AI-extracted invoice lines.
 *
 * Strategy (applied in priority order):
 *   1. Exact barcode match          → confidence 1.0
 *   2. Exact normalized name match  → confidence 1.0
 *   3. Known alias match            → confidence 0.97
 *   4. Levenshtein similarity ≥0.80 → "high" match
 *   5. Word intersection  ≥0.60     → "partial" match
 *   6. No match                     → user must assign
 *
 * All comparisons are performed against the normalized (lowercase, accent-
 * stripped, punctuation-removed) form of both strings to maximize recall.
 */

import type { Product, UnitOfMeasure } from "@/lib/types"
import type {
  InvoiceLineRaw,
  MatchedInvoiceLine,
  ProductMatch,
  MatchType,
} from "@/lib/invoice-types"

// ── Text normalization ────────────────────────────────────────────────────────

const ACCENT_MAP: Record<string, string> = {
  á: "a", é: "e", í: "i", ó: "o", ú: "u",
  Á: "a", É: "e", Í: "i", Ó: "o", Ú: "u",
  ü: "u", Ü: "u", ñ: "n", Ñ: "n",
}

export function normalizeText(s: string): string {
  return s
    .toLowerCase()
    .replace(/[áéíóúüÁÉÍÓÚÜñÑ]/g, (c) => ACCENT_MAP[c] ?? c)
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

// ── Levenshtein similarity (0–1) ──────────────────────────────────────────────

function levenshtein(a: string, b: string): number {
  const m = a.length, n = b.length
  if (m === 0) return n
  if (n === 0) return m
  const dp: number[][] = Array.from({ length: m + 1 }, (_, i) =>
    Array.from({ length: n + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0))
  )
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i][j] =
        a[i - 1] === b[j - 1]
          ? dp[i - 1][j - 1]
          : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
    }
  }
  return dp[m][n]
}

export function stringSimilarity(a: string, b: string): number {
  if (!a && !b) return 1
  if (!a || !b) return 0
  const na = normalizeText(a)
  const nb = normalizeText(b)
  if (na === nb) return 1
  const dist = levenshtein(na, nb)
  return 1 - dist / Math.max(na.length, nb.length)
}

// ── Word intersection similarity ──────────────────────────────────────────────

function wordSets(s: string): Set<string> {
  return new Set(normalizeText(s).split(" ").filter((w) => w.length > 2))
}

export function wordIntersectionScore(a: string, b: string): number {
  const sa = wordSets(a)
  const sb = wordSets(b)
  if (sa.size === 0 || sb.size === 0) return 0
  let inter = 0
  for (const w of sa) if (sb.has(w)) inter++
  return inter / Math.max(sa.size, sb.size)
}

// ── Unit detection ────────────────────────────────────────────────────────────

const UNIT_KEYWORDS: Record<string, string[]> = {
  kg:  ["kg", "kilo", "kilos", "kilogramo", "kilogramos"],
  g:   ["g", "gr", "gramo", "gramos"],
  L:   ["l", "lt", "lts", "litro", "litros", "liter"],
  mL:  ["ml", "mililitro", "mililitros", "cc"],
  m:   ["m", "metro", "metros", "mtr"],
  cm:  ["cm", "centimetro", "centimetros"],
  u:   ["u", "un", "unid", "unidad", "unidades", "und"],
  doc: ["doc", "docena", "docenas"],
  cj6: ["cj", "caja", "cajas"],
}

/**
 * Given a unit string from the OCR (e.g. "kg", "litros", "UN"),
 * returns the matching UnitOfMeasure from the ERP catalog, or null.
 */
export function detectUnit(
  ocrUnit: string | null,
  units: UnitOfMeasure[],
): UnitOfMeasure | null {
  if (!ocrUnit) return null
  const norm = normalizeText(ocrUnit)

  // Exact symbol match first
  const bySymbol = units.find((u) => normalizeText(u.symbol) === norm)
  if (bySymbol) return bySymbol

  // Keyword match
  for (const [symbol, keywords] of Object.entries(UNIT_KEYWORDS)) {
    if (keywords.includes(norm)) {
      const unit = units.find((u) => normalizeText(u.symbol) === symbol.toLowerCase())
      if (unit) return unit
    }
  }

  // Fuzzy symbol match
  const fuzzy = units
    .map((u) => ({ u, score: stringSimilarity(u.symbol, ocrUnit) }))
    .sort((a, b) => b.score - a.score)[0]
  if (fuzzy && fuzzy.score >= 0.85) return fuzzy.u

  return null
}

// ── Product matching ──────────────────────────────────────────────────────────

export interface ProductAlias {
  alias:      string
  product_id: string
}

/**
 * Finds the best matching ERP product for a given OCR description.
 * Returns a ProductMatch with confidence score and match type.
 */
export function matchProduct(
  ocrDescription: string,
  ocrBarcode:     string | null,
  products:       Product[],
  aliases:        ProductAlias[],
  units:          UnitOfMeasure[],
): ProductMatch {
  const noMatch: ProductMatch = {
    type: "none", product_id: null, product_name: null,
    unit_id: null, unit_symbol: null, confidence: 0,
  }
  if (!ocrDescription && !ocrBarcode) return noMatch

  // 1. Exact barcode match
  if (ocrBarcode) {
    const byBarcode = products.find(
      (p) => p.barcode && p.barcode.toUpperCase() === ocrBarcode.toUpperCase(),
    )
    if (byBarcode) {
      const unit = byBarcode.baseUnitId ? units.find((u) => u.id === byBarcode.baseUnitId) ?? null : null
      return {
        type: "exact_barcode", product_id: byBarcode.id, product_name: byBarcode.name,
        unit_id: unit?.id ?? null, unit_symbol: unit?.symbol ?? null, confidence: 1.0,
      }
    }
  }

  // 2. Exact normalized name match
  const normOcr = normalizeText(ocrDescription)
  const byName  = products.find((p) => normalizeText(p.name) === normOcr)
  if (byName) {
    const unit = byName.baseUnitId ? units.find((u) => u.id === byName.baseUnitId) ?? null : null
    return {
      type: "exact_name", product_id: byName.id, product_name: byName.name,
      unit_id: unit?.id ?? null, unit_symbol: unit?.symbol ?? null, confidence: 1.0,
    }
  }

  // 3. Alias match
  const aliasNorm  = normalizeText(ocrDescription)
  const aliasMatch = aliases.find((a) => normalizeText(a.alias) === aliasNorm)
  if (aliasMatch) {
    const product = products.find((p) => p.id === aliasMatch.product_id)
    if (product) {
      const unit = product.baseUnitId ? units.find((u) => u.id === product.baseUnitId) ?? null : null
      return {
        type: "alias", product_id: product.id, product_name: product.name,
        unit_id: unit?.id ?? null, unit_symbol: unit?.symbol ?? null, confidence: 0.97,
      }
    }
  }

  // 4 & 5. Fuzzy: Levenshtein + word intersection
  const scored = products.map((p) => {
    const lev  = stringSimilarity(ocrDescription, p.name)
    const word = wordIntersectionScore(ocrDescription, p.name)
    return { p, score: Math.max(lev, word * 0.95) }
  }).sort((a, b) => b.score - a.score)

  const best = scored[0]
  if (!best || best.score < 0.45) return noMatch

  const matchType: MatchType =
    best.score >= 0.90 ? "high" :
    best.score >= 0.60 ? "partial" :
    "none"

  if (matchType === "none") return noMatch

  const unit = best.p.baseUnitId ? units.find((u) => u.id === best.p.baseUnitId) ?? null : null
  return {
    type: matchType, product_id: best.p.id, product_name: best.p.name,
    unit_id: unit?.id ?? null, unit_symbol: unit?.symbol ?? null,
    confidence: Math.round(best.score * 100) / 100,
  }
}

// ── Full line enrichment ──────────────────────────────────────────────────────

/**
 * Enriches each raw invoice line with a product match and default
 * confirmed values (editable by the user in the review modal).
 */
export function enrichLines(
  rawLines:  InvoiceLineRaw[],
  products:  Product[],
  units:     UnitOfMeasure[],
  aliases:   ProductAlias[],
): MatchedInvoiceLine[] {
  return rawLines.map((line) => {
    const detectedUnit = detectUnit(line.unit, units)
    const match = matchProduct(line.description, null, products, aliases, units)

    return {
      ...line,
      detected_unit_id:   detectedUnit?.id   ?? null,
      detected_unit_name: detectedUnit?.name ?? null,
      match,
      confirmed_product_id:   match.product_id,
      confirmed_product_name: match.product_name ?? line.description,
      confirmed_quantity:     Math.max(0.001, line.quantity ?? 1),
      confirmed_unit_price:   line.unit_price ?? 0,
      confirmed_unit_id:      match.unit_id ?? detectedUnit?.id ?? null,
      confirmed_unit_symbol:  match.unit_symbol ?? detectedUnit?.symbol ?? null,
      included:               true,
      is_new_product:         match.type === "none",
    }
  })
}