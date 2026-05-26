/**
 * Import row validator.
 *
 * Converts RawImportRow (all strings) to ValidatedImportRow (typed values).
 * Collects per-row errors (blocking) and warnings (non-blocking).
 *
 * Rules:
 *   Producto / standalone:
 *     - nombre required
 *     - precio required and >= 0
 *
 *   Padre:
 *     - nombre required
 *     - precio NOT required (parent has no price of its own)
 *     - SKU required (needed to link children)
 *
 *   Variante:
 *     - nombre required
 *     - precio required and >= 0
 *     - SKU required
 *     - SKU Padre required
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

// ─── Public API ───────────────────────────────────────────────────────────────

export interface ValidationSummary {
  rows:          ValidatedImportRow[]
  /** Rows with at least one error — will not be imported. */
  invalidCount:  number
  /** Rows with only warnings — will be imported with caveats. */
  warningCount:  number
  /** Rows with no issues. */
  validCount:    number
  parentCount:   number
  variantCount:  number
  standaloneCount: number
}

export function validateImportRows(rawRows: RawImportRow[]): ValidationSummary {
  const rows: ValidatedImportRow[] = rawRows.map(validateRow)

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

// ─── Per-row validation ───────────────────────────────────────────────────────

function validateRow(raw: RawImportRow): ValidatedImportRow {
  const errors:   string[] = []
  const warnings: string[] = []

  // ── Row type ────────────────────────────────────────────────────────────────
  const rawTipo = raw.tipo.trim()
  if (rawTipo && !VALID_ROW_TYPES.has(rawTipo)) {
    errors.push(`Tipo desconocido: "${rawTipo}". Valores válidos: Padre, Variante, Producto (o vacío).`)
  }
  const rowType = (VALID_ROW_TYPES.has(rawTipo) ? rawTipo : "") as ImportRowType

  // ── Name ───────────────────────────────────────────────────────────────────
  const name = raw.nombre.trim()
  if (!name) errors.push("Nombre requerido.")

  // ── SKU ────────────────────────────────────────────────────────────────────
  const sku = raw.sku.trim() || null
  const skuParent = raw.sku_padre.trim() || null

  if (rowType === "Padre" && !sku) {
    errors.push("SKU requerido para filas de tipo Padre (los usa las Variantes como referencia).")
  }
  if (rowType === "Variante" && !sku) {
    errors.push("SKU requerido para filas de tipo Variante.")
  }
  if (rowType === "Variante" && !skuParent) {
    errors.push("SKU Padre requerido para filas de tipo Variante.")
  }

  // ── Price ──────────────────────────────────────────────────────────────────
  let price = 0
  if (rowType !== "Padre") {
    // Parents have no price
    const parsedPrice = parseAmount(raw.precio)
    if (raw.precio.trim()) {
      if (isNaN(parsedPrice) || parsedPrice < 0) {
        errors.push(`Precio inválido: "${raw.precio}". Debe ser un número mayor o igual a 0.`)
      } else {
        price = parsedPrice
      }
    } else {
      warnings.push("Precio no especificado — se usará 0.")
    }
  }

  // ── Cost ───────────────────────────────────────────────────────────────────
  let cost = 0
  if (raw.costo.trim()) {
    const parsedCost = parseAmount(raw.costo)
    if (isNaN(parsedCost) || parsedCost < 0) {
      warnings.push(`Costo inválido: "${raw.costo}" — se usará 0.`)
    } else {
      cost = parsedCost
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
    warnings.push(`Categoría desconocida: "${rawCategory}" — se asignará "Otros".`)
  }

  // ── Barcode ────────────────────────────────────────────────────────────────
  const barcode = raw.codigo.trim() || null

  // ── Attributes ─────────────────────────────────────────────────────────────
  const attributes: ImportAttribute[] = Object.entries(raw.attributes)
    .filter(([, v]) => v.trim() !== "")
    .map(([k, v], idx) => ({ key: k, value: v.trim(), sort_order: idx }))

  if (rowType === "Padre" && attributes.length > 0) {
    warnings.push("Los atributos en filas Padre se ignoran — deben ir en las Variantes.")
  }

  return {
    lineNumber: raw.lineNumber,
    rowType,
    name,
    sku,
    skuParent,
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
