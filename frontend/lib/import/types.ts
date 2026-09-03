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
 *
 * productos-categorias-sku (D6): la columna Categoría se resuelve contra el
 * catálogo del tenant (case-insensitive, tolerante a espacios) y una
 * desconocida SE CREA en el servidor, dentro de la misma transacción que
 * inserta los productos. Ya no existe un vocabulario fijo propio del
 * importador (VALID_CATEGORIES se retiró).
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

/** Lo mínimo que el validador necesita del catálogo de la cuenta. */
export interface ImportCategoryRef {
  id:       string
  name:     string
  isActive: boolean
}

export interface ValidatedImportRow {
  lineNumber:    number
  rowType:       ImportRowType
  name:          string
  /** Optional — used as upsert key when present (alcance de CUENTA, case-insensitive). */
  sku:           string | null
  /** Explicit parent reference by SKU (optional). */
  skuParent:     string | null
  /** Explicit parent reference by name (optional). */
  nameParent:    string | null
  price:         number
  cost:          number
  /**
   * Nombre canónico del catálogo si la categoría existe; el nombre normalizado
   * (trim + colapso de espacios) si es nueva; "" si la fila no trae categoría
   * (el servidor imputa la categoría por defecto de la cuenta).
   */
  category:      string
  /** true = no existe en el catálogo del tenant y el servidor la va a crear. */
  categoryIsNew: boolean
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

/**
 * productos-categorias-sku (D6 / OQ-1, sign-off PO 2026-09-03): tope de
 * categorías NUEVAS distintas por importación. Superarlo casi siempre es una
 * columna mal mapeada (un código, una descripción, un precio), no un
 * catálogo legítimo. El servidor (rpc_bulk_upsert_products) aplica el mismo
 * valor por llamada como defensa en profundidad.
 */
export const MAX_NEW_CATEGORIES_PER_IMPORT = 50

export const VALID_ROW_TYPES = new Set<string>(["Padre", "Variante", "Producto", ""])

export const ATTRIBUTE_PREFIX = "atributo:"

export const IMPORT_BATCH_SIZE = 200
