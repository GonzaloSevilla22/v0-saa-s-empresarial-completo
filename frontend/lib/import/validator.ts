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

import { parseAmount, looksLikeThousandsGrouping } from "@/lib/excel"
import { formatNumber } from "@/lib/format"
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
  // Cantidad física (branch_stock.quantity es numeric(15,4)): admite decimales.
  // Con loneCommaIsDecimal, una coma sin punto es SIEMPRE decimal ("1,5" → 1.5);
  // un punto solo se lee como decimal (mismo contrato que precio/costo), y
  // "1.234,56" (con ambos separadores) sigue la heurística europea de parseAmount.
  // Dos o más puntos sin coma ("1.234.567") no tienen lectura válida y se
  // rechazan en vez de leerse parcialmente (parseFloat pararía en el 2do
  // punto). Una agrupación de tres dígitos con un solo separador ("1.500",
  // "1,500") se lee como decimal pero avisa la ambigüedad (también podría ser
  // miles — mismo detector que el importador de ajustes de stock). Más de 4
  // decimales se redondea (branch_stock.quantity es numeric(15,4)).
  let stock = 0
  if (rowType !== "Padre" && raw.stock.trim()) {
    const rawStock = raw.stock.trim()
    // Mismo texto que ve parseAmount (descarta ruido como "kg" o "$"): así el
    // pre-chequeo y el detector de ambigüedad no se evaden con un sufijo.
    const cleanedStock = rawStock.replace(/[^\d.,-]/g, "")
    const dotCount = (cleanedStock.match(/\./g) ?? []).length
    if (!cleanedStock.includes(",") && dotCount >= 2) {
      warnings.push(`Stock inválido: "${rawStock}" — se usará 0.`)
    } else {
      const parsed = parseAmount(rawStock, { loneCommaIsDecimal: true })
      if (isNaN(parsed) || parsed < 0) {
        warnings.push(`Stock inválido: "${rawStock}" — se usará 0.`)
      } else {
        let value = parsed
        if (looksLikeThousandsGrouping(cleanedStock)) {
          warnings.push(
            `Stock ambiguo: "${rawStock}" — se interpretó como ${formatNumber(value, 4)}. ` +
              `Usá coma para decimales y ningún separador para miles.`,
          )
        }
        const rounded = Math.round(value * 1e4) / 1e4
        if (Math.abs(rounded - value) > 1e-9) {
          warnings.push(`Stock "${rawStock}" se redondeó a ${formatNumber(rounded, 4)} (máximo 4 decimales).`)
          value = rounded
        }
        stock = value
      }
    }
  }

  // ── Min stock ──────────────────────────────────────────────────────────────
  // products.min_stock / branch_stock.min_stock son integer en DB — la RPC
  // castea el TEXTO del JSON con `::integer`, así que un valor no entero no
  // se redondea en silencio: lanza 22P02 y aborta el lote completo. Por eso
  // acá SIEMPRE se entrega un entero: un no entero ≥ 0 se redondea hacia
  // arriba (Math.ceil) con aviso; NaN o negativo caen a 0 ("sin umbral de
  // alerta" — min_stock = 0 es el predicado canónico que desactiva la alerta
  // de reposición, `lib/product-stock.ts`). Mismo tratamiento de ambigüedad
  // de agrupación de miles que el stock.
  let minStock = 0
  if (raw.stock_minimo.trim()) {
    const rawMin = raw.stock_minimo.trim()
    const cleanedMin = rawMin.replace(/[^\d.,-]/g, "")
    const dotCount = (cleanedMin.match(/\./g) ?? []).length
    if (!cleanedMin.includes(",") && dotCount >= 2) {
      warnings.push(`Stock mínimo inválido: "${rawMin}" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).`)
    } else {
      const parsed = parseAmount(rawMin, { loneCommaIsDecimal: true })
      if (isNaN(parsed) || parsed < 0) {
        warnings.push(`Stock mínimo inválido: "${rawMin}" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).`)
      } else {
        let value = parsed
        if (looksLikeThousandsGrouping(cleanedMin)) {
          warnings.push(
            `Stock mínimo ambiguo: "${rawMin}" — se interpretó como ${formatNumber(value, 4)}. ` +
              `Usá coma para decimales y ningún separador para miles.`,
          )
        }
        if (!Number.isInteger(value)) {
          const ceiled = Math.ceil(value)
          warnings.push(`Stock mínimo "${rawMin}" no admite decimales: se usará ${ceiled}.`)
          value = ceiled
        }
        minStock = value
      }
    }
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
