/**
 * Product import pipeline — parseo, validación y resolución de jerarquía.
 *
 * importador-productos-fastapi: este módulo deja de hablar con Supabase y
 * de trocear el archivo en sub-lotes (`createClient()`, `IMPORT_BATCH_SIZE`,
 * `chunkArray` — todos retirados, D13 del design). Su única responsabilidad
 * ahora es preparar el archivo hasta el punto en que está listo para viajar
 * al servidor como UNA SOLA unidad de trabajo: parsear → validar (cliente,
 * primera capa) → resolver la jerarquía (sin consultas a la base, D9) →
 * convertir cada fila a la forma que espera `POST /products/import`
 * (`ProductImportRow`, espejo de `ProductImportRowIn`).
 *
 * La llamada HTTP real vive en `useImportProducts()`
 * (`hooks/data/use-products.ts`), igual que `useImportExpenses()` — el
 * diálogo dispara la simulación (`dryRun: true`) al entrar al paso 2 y la
 * confirmación (`dryRun: false`) al confirmar, con la MISMA clave de
 * idempotencia (D8) y las MISMAS filas preparadas acá.
 */

import { parseImportFile }    from "@/lib/import/parser"
import { validateImportRows, type NewCategorySummary } from "@/lib/import/validator"
import { resolveHierarchy }   from "@/lib/import/resolver"
import type { ImportCategoryRef, ResolvedImportRow, ValidatedImportRow } from "@/lib/import/types"
import type { ProductImportRow } from "@/lib/types"

export interface PreparedImport {
  /** Todas las filas validadas (incluye las que tienen error de cliente). */
  validatedRows: ValidatedImportRow[]
  /** Sólo las filas sin error de cliente, con su jerarquía resuelta. */
  resolvedRows:  ResolvedImportRow[]
  /** `resolvedRows` convertidas al contrato de `POST /products/import`. */
  apiRows:       ProductImportRow[]
  parentCount:      number
  variantCount:     number
  standaloneCount:  number
  invalidCount:     number
  warningCount:     number
  newCategories:            NewCategorySummary[]
  newCategoryLimitExceeded: boolean
  maxNewCategories:         number
}

/**
 * Parsea, valida (primera capa, cliente) y resuelve la jerarquía de un
 * archivo — SIN llamar al servidor. El resultado (`apiRows`) es lo que el
 * diálogo manda como `rows` de la simulación y, sin cambios, de la
 * confirmación real (D7: la MISMA forma para las dos llamadas).
 */
export async function prepareProductImport(
  file: File,
  categories: readonly ImportCategoryRef[] = [],
): Promise<PreparedImport> {
  const parsed = await parseImportFile(file)
  if (!parsed.ok) throw new Error(parsed.error)

  const {
    rows: validatedRows, invalidCount, warningCount,
    parentCount, variantCount, standaloneCount,
    newCategories, newCategoryLimitExceeded, maxNewCategories,
  } = validateImportRows(parsed.rows, categories)

  // Superar el tope se comunica en el PASO 2 (alerta inline + botón
  // deshabilitado), igual que antes de este change — no se aborta el
  // parseo. La resolución de jerarquía y la conversión a `apiRows` corren
  // igual (son baratas y no escriben nada); es el diálogo quien decide no
  // disparar la simulación de servidor mientras el tope siga excedido.
  const validRows = validatedRows.filter((r) => r.errors.length === 0)
  const { rows: resolvedRows } = resolveHierarchy(validRows)
  const apiRows = resolvedRows.map(toApiRow)

  return {
    validatedRows, resolvedRows, apiRows,
    parentCount, variantCount, standaloneCount,
    invalidCount, warningCount,
    newCategories, newCategoryLimitExceeded, maxNewCategories,
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function toApiRow(row: ResolvedImportRow): ProductImportRow {
  const isPadre = row.rowType === "Padre"

  return {
    rowNo:    row.lineNumber,
    name:     row.name,
    // "" → ausencia (el servidor imputa la categoría por defecto de la cuenta).
    category: row.category || null,
    // Un Padre (variant_only) no tiene precio/stock propio — mismo criterio
    // que el importador tenía antes de este change.
    price:    isPadre ? 0 : row.price,
    // productos-costo-nullable (D10) + D12 de este change (null-preserving):
    // `null` = sin costo (alta) o "conservar" (edición) — nunca 0 por
    // default. Un Padre tampoco tiene costo propio: null, no 0.
    cost:     isPadre ? null : row.cost,
    stock:    isPadre ? 0 : row.stock,
    minStock: row.minStock,
    barcode:  row.barcode,
    sku:      row.sku,
    // D9: la referencia explícita viaja TAL CUAL — nunca se resuelve en el
    // cliente. resolvedParentId ya no lo produce ningún camino (el resolver
    // retiró las consultas a la base), así que sólo depende de isVariant.
    skuParent:  row.isVariant ? (row.skuParent ?? null)          : null,
    parentName: row.isVariant ? (row.resolvedParentName ?? null) : null,
    isVariant:        row.isVariant,
    stockControlType: row.stockControlType,
    attributes: row.isVariant
      ? row.attributes.map((a) => ({ key: a.key, value: a.value, sortOrder: a.sort_order }))
      : [],
  }
}
