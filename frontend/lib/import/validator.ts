/**
 * Import row validator.
 *
 * Converts RawImportRow (all strings) to ValidatedImportRow (typed values).
 * Collects per-row errors (fatal, row skipped) and warnings (informational only).
 *
 * SKU policy:
 *   SKU is NEVER required. It is optional on all row types.
 *   When present it is used as an upsert key (update existing product by SKU,
 *   alcance de CUENTA y case-insensitive — productos-categorias-sku D4).
 *   When absent the row is still imported — duplicates are avoided via
 *   name + parent deduplication in the resolver.
 *   Two rows of the SAME file with the same SKU are warned: the second one
 *   updates the product the first one wrote (before this was silent).
 *
 * Category policy (productos-categorias-sku D6):
 *   The column is resolved against the ACCOUNT catalog (case-insensitive,
 *   whitespace-tolerant). An unknown category is marked `categoryIsNew` and
 *   announced in the summary — the server creates it inside the same
 *   transaction that inserts the products. A blank category leaves "" and the
 *   server imputes the account default. No fixed vocabulary survives here.
 *
 * Fatal errors (row skipped):
 *   - nombre missing
 *   - precio invalid (non-numeric, negative) on Variante / Producto rows
 *
 * Warnings (row imported with caveats):
 *   - precio missing on Variante / Producto → defaults to 0
 *   - costo / stock invalid → defaults to 0
 *   - SKU repeated within the file
 */

import { parseAmount } from "@/lib/excel"
import {
  MAX_NEW_CATEGORIES_PER_IMPORT,
  VALID_ROW_TYPES,
  type ImportCategoryRef,
  type RawImportRow,
  type ValidatedImportRow,
  type ImportAttribute,
  type ImportRowType,
} from "@/lib/import/types"

export interface NewCategorySummary {
  name: string
  rows: number
}

export interface ValidationSummary {
  rows:            ValidatedImportRow[]
  invalidCount:    number
  warningCount:    number
  validCount:      number
  parentCount:     number
  variantCount:    number
  standaloneCount: number
  /** Categorías que el servidor va a crear (sólo desde filas válidas), con cuántas filas usa cada una. */
  newCategories:   NewCategorySummary[]
  /** true si `newCategories.length > maxNewCategories` — la importación debe rechazarse. */
  newCategoryLimitExceeded: boolean
  maxNewCategories: number
}

/** Mensaje del rechazo por tope (D6) — lo muestran el paso de revisión y el importador. */
export function newCategoryLimitMessage(count: number, max: number): string {
  return (
    `El archivo introduce ${count} categorías nuevas y el tope es ${max}. ` +
    `Probablemente la columna "Categoría" esté mal mapeada (¿un código, una descripción o un precio?). ` +
    `Corregí el archivo y volvé a subirlo — no se creó ninguna categoría.`
  )
}

/** Mismo criterio que public.product_category_normalize_name y el backend. */
export function normalizeCategoryName(raw: string): string {
  return raw.trim().replace(/\s+/g, " ")
}

export function validateImportRows(
  rawRows: RawImportRow[],
  catalog: readonly ImportCategoryRef[] = [],
): ValidationSummary {
  // Nombre canónico por clave case-insensitive — incluye las DESACTIVADAS:
  // una categoría existente se reutiliza, nunca se duplica (el unique de la
  // DB lo rechazaría igual).
  const canonicalByKey = new Map<string, string>()
  for (const c of catalog) canonicalByKey.set(c.name.trim().toLowerCase(), c.name)

  const rows = rawRows.map((raw) => validateRow(raw, canonicalByKey))
  flagDuplicateSkus(rows)

  const newCategories = summariseNewCategories(rows)

  return {
    rows,
    invalidCount:    rows.filter((r) => r.errors.length > 0).length,
    warningCount:    rows.filter((r) => r.errors.length === 0 && r.warnings.length > 0).length,
    validCount:      rows.filter((r) => r.errors.length === 0).length,
    parentCount:     rows.filter((r) => r.rowType === "Padre").length,
    variantCount:    rows.filter((r) => r.rowType === "Variante").length,
    standaloneCount: rows.filter((r) => r.rowType === "Producto" || r.rowType === "").length,
    newCategories,
    newCategoryLimitExceeded: newCategories.length > MAX_NEW_CATEGORIES_PER_IMPORT,
    maxNewCategories: MAX_NEW_CATEGORIES_PER_IMPORT,
  }
}

function validateRow(raw: RawImportRow, canonicalByKey: Map<string, string>): ValidatedImportRow {
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
  const sku = raw.sku.trim() || null

  // ── Parent references — both optional ──────────────────────────────────────
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

  // ── Category — contra el catálogo del tenant (productos-categorias-sku D6) ─
  const normalizedCategory = normalizeCategoryName(raw.categoria)
  let category = ""
  let categoryIsNew = false
  if (normalizedCategory) {
    const canonical = canonicalByKey.get(normalizedCategory.toLowerCase())
    if (canonical !== undefined) {
      category = canonical
    } else {
      category = normalizedCategory
      categoryIsNew = true
    }
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
    categoryIsNew,
    stock,
    minStock,
    barcode,
    attributes,
    warnings,
    errors,
  }
}

/**
 * productos-categorias-sku (task 15.4/15.5): dos filas del mismo archivo con
 * el mismo SKU (case-insensitive) — la segunda actualiza el producto que
 * escribió la primera. Antes ocurría en silencio.
 */
function flagDuplicateSkus(rows: ValidatedImportRow[]): void {
  const linesBySku = new Map<string, number[]>()
  for (const r of rows) {
    if (!r.sku) continue
    const key = r.sku.toLowerCase()
    const lines = linesBySku.get(key) ?? []
    lines.push(r.lineNumber)
    linesBySku.set(key, lines)
  }
  for (const r of rows) {
    if (!r.sku) continue
    const lines = linesBySku.get(r.sku.toLowerCase()) ?? []
    if (lines.length < 2) continue
    const others = lines.filter((l) => l !== r.lineNumber)
    r.warnings.push(
      `SKU "${r.sku}" repetido en el archivo (también en la línea ${others.join(", ")}) — la última fila actualiza al mismo producto.`,
    )
  }
}

function summariseNewCategories(rows: ValidatedImportRow[]): NewCategorySummary[] {
  const byKey = new Map<string, NewCategorySummary>()
  for (const r of rows) {
    if (r.errors.length > 0 || !r.categoryIsNew) continue
    const key = r.category.toLowerCase()
    const entry = byKey.get(key)
    if (entry) entry.rows += 1
    else byKey.set(key, { name: r.category, rows: 1 })
  }
  return [...byKey.values()]
}
