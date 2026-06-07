/**
 * Import row validator.
 *
 * Converts RawImportRow (all strings) to ValidatedImportRow (typed values).
 * Collects per-row errors (fatal, row skipped) and warnings (informational only).
 *
 * SKU policy:
 *   SKU is NEVER required. It is optional on all row types.
 *   When present it is used as an upsert key (update existing product by SKU).
 *   When absent the row is still imported — duplicates are avoided via
 *   name + parent deduplication in the resolver.
 *
 * Fatal errors (row skipped):
 *   - nombre missing
 *   - precio invalid (non-numeric, negative) on Variante / Producto rows
 *
 * Warnings (row imported with caveats):
 *   - categoria unknown → assigned "Otros"
 *   - precio missing on Variante / Producto → defaults to 0
 *   - costo / stock invalid → defaults to 0
 *   - SKU present but seems like a duplicate hint
 */

import { parseAmount } from "@/lib/excel"
import {
  VALID_CATEGORIES,
  VALID_ROW_TYPES,
  type RawImportRow,
  type ValidatedImportRow,
  type ImportAttribute,
  type ImportRowType,
} from "@/lib/import/types"

export interface ValidationSummary {
  rows:           ValidatedImportRow[]
  invalidCount:   number
  warningCount:   number
  validCount:     number
  parentCount:    number
  variantCount:   number
  standaloneCount: number
}

export function validateImportRows(rawRows: RawImportRow[]): ValidationSummary {
  const rows = rawRows.map(validateRow)
  return {
    rows,
    invalidCount:    rows.filter((r) => r.errors.length > 0).length,
    warningCount:    rows.filter((r) => r.errors.length === 0 && r.warnings.length > 0).length,
    validCount:      rows.filter((r) => r.errors.length === 0).length,
    parentCount:     rows.filter((r) => r.rowType === "Padre").length,
    variantCount:    rows.filter((r) => r.rowType === "Variante").length,
    standaloneCount: rows.filter((r) => r.rowType === "Producto" || r.rowType === "").length,
  }
}

function validateRow(raw: RawImportRow): ValidatedImportRow {
  const errors:   string[] = []
  const warnings: string[] = []

  // ── Row type ────────────────────────────────────────────────────────────────
  const rawTipo = raw.tipo.trim()
  if (rawTipo && !VALID_ROW_TYPES.has(rawTipo)) {
    errors.push(`Tipo desconocido: "${rawTipo}". Valores válidos: Padre, Variante, Producto (o vacío).`)
  }
  const rowType = (VALID_ROW_TYPES.has(rawTipo) ? rawTipo : "") as ImportRowType

  // ── Name — only truly required field ───────────────────────────────────────
  const name = raw.nombre.trim()
  if (!name) errors.push("Nombre requerido.")

  // ── SKU — completely optional ───────────────────────────────────────────────
  // When present: used as upsert key (find existing product by SKU and update it).
  // When absent: product is inserted new (or deduplicated by name in resolver).
  const sku = raw.sku.trim() || null

  // ── Parent references — both optional ──────────────────────────────────────
  // skuParent: explicit SKU of the parent (backward compatible).
  // nameParent: explicit name of the parent (for files without SKUs).
  // If neither is set, the resolver uses sequential grouping (nearest Padre above).
  const skuParent  = raw.sku_padre.trim()       || null
  const nameParent = raw.producto_padre.trim()   || null

  // ── Price ──────────────────────────────────────────────────────────────────
  let price = 0
  if (rowType !== "Padre") {
    if (raw.precio.trim()) {
      const parsed = parseAmount(raw.precio)
      if (isNaN(parsed) || parsed < 0) {
        errors.push(`Precio inválido: "${raw.precio}". Debe ser un número ≥ 0.`)
      } else {
        price = parsed
      }
    }
    // Missing price on non-parent rows is NOT an error — defaults to 0 silently.
  }

  // ── Cost ───────────────────────────────────────────────────────────────────
  let cost = 0
  if (raw.costo.trim()) {
    const parsed = parseAmount(raw.costo)
    if (isNaN(parsed) || parsed < 0) {
      warnings.push(`Costo inválido: "${raw.costo}" — se usará 0.`)
    } else {
      cost = parsed
    }
  }

  // ── Stock ──────────────────────────────────────────────────────────────────
  let stock = 0
  if (rowType !== "Padre" && raw.stock.trim()) {
    const parsed = parseInt(raw.stock, 10)
    if (isNaN(parsed) || parsed < 0) {
      warnings.push(`Stock inválido: "${raw.stock}" — se usará 0.`)
    } else {
      stock = parsed
    }
  }

  // ── Min stock ──────────────────────────────────────────────────────────────
  let minStock = 0
  if (raw.stock_minimo.trim()) {
    const parsed = parseInt(raw.stock_minimo, 10)
    if (!isNaN(parsed) && parsed >= 0) minStock = parsed
  }

  // ── Category ───────────────────────────────────────────────────────────────
  const rawCategory = raw.categoria.trim()
  const category = VALID_CATEGORIES.has(rawCategory) ? rawCategory : "Otros"
  if (rawCategory && !VALID_CATEGORIES.has(rawCategory)) {
    warnings.push(`Categoría "${rawCategory}" desconocida — se asignará "Otros".`)
  }

  // ── Barcode ────────────────────────────────────────────────────────────────
  const barcode = raw.codigo.trim() || null

  // ── Dynamic attributes ─────────────────────────────────────────────────────
  const attributes: ImportAttribute[] = Object.entries(raw.attributes)
    .filter(([, v]) => v.trim() !== "")
    .map(([k, v], idx) => ({ key: k, value: v.trim(), sort_order: idx }))

  return {
    lineNumber: raw.lineNumber,
    rowType,
    name,
    sku,
    skuParent,
    nameParent,
    price,
    cost,
    category,
    stock,
    minStock,
    barcode,
    attributes,
    warnings,
    errors,
  }
}
