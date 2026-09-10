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
 *   - stock ambiguo (punto único con grupos de 3 dígitos, p.ej. "1.500") →
 *     se interpreta como decimal pero se avisa que también podría ser miles
 *   - stock con más de 4 decimales → se redondea (numeric(15,4))
 *   - stock_minimo no entero (≥ 0) → se redondea hacia arriba (Math.ceil)
 *   - stock_minimo inválido (NaN / negativo) → 0, "sin umbral de alerta"
 *   - SKU repeated within the file
 */

import { amountAmbiguityWarning, parseAmount, parseQuantity } from "@/lib/excel"
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
        const ambiguity = amountAmbiguityWarning("Precio", raw.precio, parsed)
        if (ambiguity) warnings.push(ambiguity)
      }
    }
    // Missing price on non-parent rows is NOT an error — defaults to 0 silently.
  }

  // ── Cost ───────────────────────────────────────────────────────────────────
  // productos-costo-nullable (D10): celda vacía ≠ "0" — vacía deja el
  // producto SIN costo (null), nunca se imputa 0 por default. Una fila
  // Padre (variant_only) tampoco tiene costo propio: el de cada variante es
  // el que cuenta, mismo criterio que `price` arriba — pero (hallazgo de
  // revisión) eso sólo debe descartar el VALOR, nunca los avisos: una
  // columna Costo mal mapeada en un Padre es la misma señal de archivo roto
  // que en cualquier otra fila, así que el parseo corre siempre y sólo la
  // ASIGNACIÓN queda condicionada a `rowType !== "Padre"`.
  let cost: number | null = null
  if (raw.costo.trim()) {
    const parsed = parseAmount(raw.costo)
    if (isNaN(parsed) || parsed < 0) {
      // Decirle al usuario que se usó 0 cuando 0 significa un costo cero
      // DECLARADO sería una mentira nueva — la fila queda sin costo.
      warnings.push(`Costo inválido: "${raw.costo}" — se dejará sin costo.`)
    } else {
      const ambiguity = amountAmbiguityWarning("Costo", raw.costo, parsed)
      if (ambiguity) warnings.push(ambiguity)
      if (rowType !== "Padre") cost = parsed
    }
  }

  // ── Stock ──────────────────────────────────────────────────────────────────
  // Cantidad física (branch_stock.quantity es numeric(15,4)): admite decimales.
  // Reglas (2+ puntos sin coma inválido, agrupación de miles ambigua avisada,
  // redondeo a 4 decimales) centralizadas en el helper canónico compartido
  // con el importador de ajustes de stock — ver `parseQuantity` en lib/excel.
  let stock = 0
  if (rowType !== "Padre" && raw.stock.trim()) {
    const { value, warnings: stockWarnings } = parseQuantity(raw.stock, { label: "Stock", maxDecimals: 4 })
    warnings.push(...stockWarnings)
    if (value !== null) stock = value
  }

  // ── Min stock ──────────────────────────────────────────────────────────────
  // products.min_stock / branch_stock.min_stock son integer en DB — la RPC
  // castea el TEXTO del JSON con `::integer`, así que un valor no entero no
  // se redondea en silencio: lanza 22P02 y aborta el lote completo. Por eso
  // acá SIEMPRE se entrega un entero (helper canónico, `integer: true`).
  let minStock = 0
  if (raw.stock_minimo.trim()) {
    const { value, warnings: minStockWarnings } = parseQuantity(raw.stock_minimo, {
      label: "Stock mínimo",
      integer: true,
    })
    warnings.push(...minStockWarnings)
    if (value !== null) minStock = value
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
