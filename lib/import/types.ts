/**
 * Types for the product CSV/XLSX import pipeline.
 *
 * Row lifecycle:
 *   RawImportRow  (parsed from file, string values)
 *     → ValidatedImportRow  (after validation pass, typed values)
 *       → ResolvedImportRow (after parent-reference resolution)
 *         → ImportBatch     (chunked for DB upsert)
 *
 * Parent→Variant relationship resolution (in priority order):
 *   1. sku_padre   — explicit SKU reference (backward compatible)
 *   2. producto_padre — explicit parent name reference
 *   3. Sequential grouping — variant belongs to the nearest Padre row above it
 */

// ─── CSV column schema ────────────────────────────────────────────────────────

export const IMPORT_COLUMN_MAP = [
  { csvHeader: "Tipo",            key: "tipo"           },
  { csvHeader: "Nombre",          key: "nombre"          },
  { csvHeader: "SKU",             key: "sku"             },
  { csvHeader: "SKU Padre",       key: "sku_padre"       },
  { csvHeader: "Producto Padre",  key: "producto_padre"  },
  { csvHeader: "Precio",          key: "precio"          },
  { csvHeader: "Costo",           key: "costo"           },
  { csvHeader: "Categoría",       key: "categoria"       },
  { csvHeader: "Stock",           key: "stock"           },
  { csvHeader: "Stock mínimo",    key: "stock_minimo"    },
  { csvHeader: "Código",          key: "codigo"          },
] as const

/** Only the name is strictly required. Everything else is optional. */
export const REQUIRED_HEADERS = ["Nombre"] as const

// ─── Row types ────────────────────────────────────────────────────────────────

export type ImportRowType = "Padre" | "Variante" | "Producto" | ""

export interface RawImportRow {
  lineNumber:      number
  tipo:            string
  nombre:          string
  sku:             string
  sku_padre:       string
  /** Explicit parent name — alternative to sku_padre for files without SKUs. */
  producto_padre:  string
  precio:          string
  costo:           string
  categoria:       string
  stock:           string
  stock_minimo:    string
  codigo:          string
  attributes:      Record<string, string>
}

export interface ImportAttribute {
  key:        string
  value:      string
  sort_order: number
}

export interface ValidatedImportRow {
  lineNumber:    number
  rowType:       ImportRowType
  name:          string
  /** Optional — used as upsert key when present. */
  sku:           string | null
  /** Explicit parent reference by SKU (optional). */
  skuParent:     string | null
  /** Explicit parent reference by name (optional). */
  nameParent:    string | null
  price:         number
  cost:          number
  category:      string
  stock:         number
  minStock:      number
  barcode:       string | null
  attributes:    ImportAttribute[]
  warnings:      string[]
  errors:        string[]
}

export interface ResolvedImportRow extends ValidatedImportRow {
  resolvedParentId:   string | null
  /** Parent name used for same-batch resolution when parent has no SKU. */
  resolvedParentName: string | null
  isVariant:          boolean
  stockControlType:   "tracked" | "untracked" | "variant_only"
}

// ─── Batch / RPC payload ──────────────────────────────────────────────────────

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
  /** Resolved by RPC using sku when parent is in same batch and has a SKU. */
  sku_parent?:        string
  /** Resolved by RPC using name when parent is in same batch and has no SKU. */
  parent_name?:       string
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
  inserted:         number
  updated:          number
  parents:          number
  variants:         number
  standalone:       number
  validationErrors: ImportRowError[]
  dbErrors:         ImportRowError[]
}

// ─── Constants ────────────────────────────────────────────────────────────────

export const VALID_CATEGORIES = new Set([
  "Electrónica", "Ropa", "Alimentos", "Hogar", "Salud", "Accesorios", "Otros",
])

export const VALID_ROW_TYPES = new Set<string>(["Padre", "Variante", "Producto", ""])

export const ATTRIBUTE_PREFIX = "atributo:"

export const IMPORT_BATCH_SIZE = 200
