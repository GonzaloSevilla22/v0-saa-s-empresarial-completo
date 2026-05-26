/**
 * Types for the product CSV/XLSX import pipeline.
 *
 * Row lifecycle:
 *   RawImportRow  (parsed from file, string values)
 *     → ValidatedImportRow  (after validation pass, typed values)
 *       → ResolvedImportRow (after parent-reference resolution)
 *         → ImportBatch     (chunked for DB upsert)
 */

// ─── CSV column schema ────────────────────────────────────────────────────────

/** Every column the importer understands in the CSV/XLSX file. */
export const IMPORT_COLUMN_MAP = [
  { csvHeader: "Tipo",         key: "tipo"         },  // "Padre" | "Variante" | "Producto" | ""
  { csvHeader: "Nombre",       key: "nombre"        },  // required for all rows
  { csvHeader: "SKU",          key: "sku"           },  // unique identifier for upserts
  { csvHeader: "SKU Padre",    key: "sku_padre"     },  // links a variant row to its parent
  { csvHeader: "Precio",       key: "precio"        },  // required for Variante / Producto
  { csvHeader: "Costo",        key: "costo"         },
  { csvHeader: "Categoría",    key: "categoria"     },
  { csvHeader: "Stock",        key: "stock"         },
  { csvHeader: "Stock mínimo", key: "stock_minimo"  },
  { csvHeader: "Código",       key: "codigo"        },  // barcode
  // Dynamic attribute columns — any column whose header starts with "Atributo:"
  // e.g. "Atributo: Color", "Atributo: Talle" → key/value pairs
] as const

export const REQUIRED_HEADERS_SIMPLE   = ["Nombre", "Precio"] as const
export const REQUIRED_HEADERS_VARIANTS = ["Nombre", "SKU", "SKU Padre"] as const

// ─── Row types ────────────────────────────────────────────────────────────────

/** Row type as it appears in the CSV. */
export type ImportRowType = "Padre" | "Variante" | "Producto" | ""

/** Raw parsed row — all values are strings (as they come from the CSV parser). */
export interface RawImportRow {
  /** Source line number in the file (1-based header, so data starts at 2). */
  lineNumber: number
  tipo:        string
  nombre:      string
  sku:         string
  sku_padre:   string
  precio:      string
  costo:       string
  categoria:   string
  stock:       string
  stock_minimo: string
  codigo:      string
  /** Extra attribute columns extracted by the parser, e.g. { "color": "Rojo", "talle": "XL" } */
  attributes:  Record<string, string>
}

/** A single attribute after validation. */
export interface ImportAttribute {
  key:        string
  value:      string
  sort_order: number
}

/** Row after validation — types are coerced, errors are attached. */
export interface ValidatedImportRow {
  lineNumber:   number
  rowType:      ImportRowType
  name:         string
  sku:          string | null
  skuParent:    string | null
  price:        number
  cost:         number
  category:     string
  stock:        number
  minStock:     number
  barcode:      string | null
  attributes:   ImportAttribute[]
  /** Non-fatal issues that don't block import but should be shown to the user. */
  warnings:     string[]
  /** Fatal issues — this row will NOT be imported. */
  errors:       string[]
}

/** Row after hierarchy resolution — parent_id is resolved from skuParent. */
export interface ResolvedImportRow extends ValidatedImportRow {
  /** Resolved UUID of the parent product (null for non-variants). */
  resolvedParentId: string | null
  isVariant:        boolean
  stockControlType: "tracked" | "untracked" | "variant_only"
}

// ─── Batch types ──────────────────────────────────────────────────────────────

/** Shape sent to the RPC bulk upsert function. */
export interface ProductUpsertPayload {
  name:               string
  sku:                string | null
  category:           string
  price:              number
  cost:               number
  stock:              number
  min_stock:          number
  barcode:            string | null
  parent_id:          string | null
  is_variant:         boolean
  stock_control_type: "tracked" | "untracked" | "variant_only"
  attributes:         ImportAttribute[]
}

// ─── Result types ─────────────────────────────────────────────────────────────

export interface ImportRowError {
  lineNumber: number
  sku:        string | null
  name:       string
  message:    string
}

export interface ImportResult {
  /** Number of new products inserted. */
  inserted:         number
  /** Number of existing products updated (matched by SKU). */
  updated:          number
  /** Number of parent catalogue entries created. */
  parents:          number
  /** Number of variant SKUs created or updated. */
  variants:         number
  /** Number of standalone products created or updated. */
  standalone:       number
  /** Rows skipped due to validation errors. */
  validationErrors: ImportRowError[]
  /** Rows that the DB rejected (constraint violations, etc.). */
  dbErrors:         ImportRowError[]
}

// ─── Validation constants ─────────────────────────────────────────────────────

export const VALID_CATEGORIES = new Set([
  "Electrónica", "Ropa", "Alimentos", "Hogar", "Salud", "Accesorios", "Otros",
])

export const VALID_ROW_TYPES = new Set<string>(["Padre", "Variante", "Producto", ""])

/** CSV attribute column prefix — columns matching this are parsed as attributes. */
export const ATTRIBUTE_PREFIX = "atributo:"  // case-insensitive

/** Maximum rows per DB batch call. */
export const IMPORT_BATCH_SIZE = 200
