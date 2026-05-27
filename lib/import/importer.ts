/**
 * Product import orchestrator.
 *
 * Wires together: parser → validator → resolver → bulk upsert RPC.
 *
 * SKU is optional throughout the pipeline.
 * Parent→Variant relationships are resolved by sequential grouping when
 * no explicit SKU Padre or Producto Padre is provided.
 */

import { createClient } from "@/lib/supabase/client"
import { parseImportFile }    from "@/lib/import/parser"
import { validateImportRows } from "@/lib/import/validator"
import { resolveHierarchy }   from "@/lib/import/resolver"
import {
  IMPORT_BATCH_SIZE,
  type ImportResult,
  type ImportRowError,
  type ProductUpsertPayload,
  type ResolvedImportRow,
} from "@/lib/import/types"

export type ImportProgressCallback = (params: {
  phase: "parsing" | "validating" | "resolving" | "uploading"
  done:  number
  total: number
}) => void

export interface ImportProductsOptions {
  file:        File
  userId:      string
  onProgress?: ImportProgressCallback
}

export async function importProductsFromFile({
  file,
  userId,
  onProgress,
}: ImportProductsOptions): Promise<ImportResult> {
  const result: ImportResult = {
    inserted: 0, updated: 0,
    parents: 0, variants: 0, standalone: 0,
    validationErrors: [], dbErrors: [],
  }

  // Phase 1: Parse
  onProgress?.({ phase: "parsing", done: 0, total: 1 })
  const parsed = await parseImportFile(file)
  if (!parsed.ok) throw new Error(parsed.error)
  onProgress?.({ phase: "parsing", done: 1, total: 1 })

  // Phase 2: Validate
  onProgress?.({ phase: "validating", done: 0, total: parsed.rows.length })
  const { rows: validatedRows } = validateImportRows(parsed.rows)

  const invalidRows = validatedRows.filter((r) => r.errors.length > 0)
  const validRows   = validatedRows.filter((r) => r.errors.length === 0)

  for (const row of invalidRows) {
    result.validationErrors.push({
      lineNumber: row.lineNumber,
      sku:        row.sku,
      name:       row.name,
      message:    row.errors.join(" | "),
    })
  }
  onProgress?.({ phase: "validating", done: validatedRows.length, total: validatedRows.length })

  if (validRows.length === 0) return result

  // Phase 3: Resolve hierarchy
  onProgress?.({ phase: "resolving", done: 0, total: validRows.length })
  const { rows: resolvedRows } = await resolveHierarchy(validRows, userId)
  onProgress?.({ phase: "resolving", done: resolvedRows.length, total: resolvedRows.length })

  const importable = resolvedRows  // all resolved rows are importable (orphans → standalone)

  // Phase 4: Batch upsert
  const supabase = createClient()
  const chunks   = chunkArray(importable, IMPORT_BATCH_SIZE)
  let uploaded   = 0

  for (const chunk of chunks) {
    onProgress?.({ phase: "uploading", done: uploaded, total: importable.length })

    const payloads: ProductUpsertPayload[] = chunk.map(toPayload)

    const { data, error } = await supabase.rpc("rpc_bulk_upsert_products", {
      p_rows:    payloads,
      p_user_id: userId,
    })

    if (error) {
      for (const row of chunk) {
        result.dbErrors.push({
          lineNumber: row.lineNumber,
          sku:        row.sku,
          name:       row.name,
          message:    error.message,
        })
      }
    } else {
      const res = data as { inserted: number; updated: number; errors: any[] }
      result.inserted += res.inserted ?? 0
      result.updated  += res.updated  ?? 0
      for (const e of res.errors ?? []) {
        result.dbErrors.push({
          lineNumber: 0,
          sku:        e.sku ?? null,
          name:       e.name ?? "",
          message:    e.message ?? "DB error",
        })
      }
    }

    uploaded += chunk.length
  }

  for (const row of importable) {
    if (row.rowType === "Padre") result.parents++
    else if (row.isVariant)      result.variants++
    else                         result.standalone++
  }

  return result
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function toPayload(row: ResolvedImportRow): ProductUpsertPayload {
  const payload: ProductUpsertPayload = {
    name:               row.name,
    sku:                row.sku,
    category:           row.category,
    price:              row.rowType === "Padre" ? 0 : row.price,
    cost:               row.rowType === "Padre" ? 0 : row.cost,
    stock:              row.rowType === "Padre" ? 0 : row.stock,
    min_stock:          row.minStock,
    barcode:            row.barcode,
    parent_id:          row.resolvedParentId,
    is_variant:         row.isVariant,
    stock_control_type: row.stockControlType,
    attributes:         row.isVariant ? row.attributes : [],
  }

  if (row.isVariant && !row.resolvedParentId) {
    // Parent is in the same batch — RPC resolves by SKU or by name
    if (row.skuParent) {
      payload.sku_parent = row.skuParent
    } else if (row.resolvedParentName) {
      payload.parent_name = row.resolvedParentName
    }
  }

  return payload
}

function chunkArray<T>(arr: T[], size: number): T[][] {
  const chunks: T[][] = []
  for (let i = 0; i < arr.length; i += size) chunks.push(arr.slice(i, i + size))
  return chunks
}
