/**
 * Hierarchy resolver.
 *
 * Takes validated rows and resolves parent→child relationships:
 *
 *   1. Collects all "Padre" rows by their SKU → builds a lookup map.
 *   2. For each "Variante" row, finds its parent by skuParent.
 *   3. Checks if the parent already exists in the database (for upserts where
 *      the parent was created in a previous import).
 *   4. Orders the output: parents first, then variants, then standalone.
 *      This guarantees INSERT order correctness for the bulk upsert RPC.
 *
 * Orphan detection:
 *   A variant whose skuParent is not found in the current batch AND not in the
 *   DB is flagged as an error (orphan).  A variant whose parent IS in the DB
 *   but not in the current batch is still valid — it gets resolvedParentId set
 *   from the DB lookup result.
 */

import { createClient } from "@/lib/supabase/client"
import type { ValidatedImportRow, ResolvedImportRow } from "@/lib/import/types"

// ─── Public API ───────────────────────────────────────────────────────────────

export interface ResolveResult {
  rows:          ResolvedImportRow[]
  /** Variants whose parent could not be found in the batch or in the DB. */
  orphanCount:   number
}

/**
 * Resolves parent→child relationships for a set of validated rows.
 *
 * @param validRows  Rows that passed validation (no errors).
 * @param userId     Authenticated user's UUID (for DB lookups).
 */
export async function resolveHierarchy(
  validRows: ValidatedImportRow[],
  userId: string,
): Promise<ResolveResult> {
  // ── Step 1: build SKU lookup from this batch ──────────────────────────────
  const batchParentSkus = new Map<string, string | null>()
  // Value: resolved UUID (null = not yet persisted, will be assigned by DB)
  for (const row of validRows) {
    if (row.rowType === "Padre" && row.sku) {
      batchParentSkus.set(row.sku, null)  // ID unknown until insert
    }
  }

  // ── Step 2: fetch existing products by SKU from DB ────────────────────────
  const variantParentSkus = new Set<string>()
  for (const row of validRows) {
    if (row.rowType === "Variante" && row.skuParent) {
      variantParentSkus.add(row.skuParent)
    }
  }

  // Only query SKUs that are NOT in the current batch
  const skusToQuery = [...variantParentSkus].filter(
    (sku) => !batchParentSkus.has(sku)
  )

  const dbParentIdBySku = new Map<string, string>()
  if (skusToQuery.length > 0) {
    const supabase = createClient()
    const { data } = await supabase
      .from("products")
      .select("id, sku")
      .eq("user_id", userId)
      .in("sku", skusToQuery)
    for (const p of data ?? []) {
      if (p.sku) dbParentIdBySku.set(p.sku, p.id)
    }
  }

  // ── Step 3: resolve each row ──────────────────────────────────────────────
  const resolved: ResolvedImportRow[] = []
  let orphanCount = 0

  // Ordering: parents first → variants → standalone
  const parents    = validRows.filter((r) => r.rowType === "Padre")
  const variants   = validRows.filter((r) => r.rowType === "Variante")
  const standalone = validRows.filter((r) => r.rowType !== "Padre" && r.rowType !== "Variante")

  // Parents
  for (const row of parents) {
    resolved.push({
      ...row,
      resolvedParentId: null,
      isVariant:        false,
      stockControlType: "variant_only",
    })
  }

  // Variants
  for (const row of variants) {
    const parentSku = row.skuParent
    let resolvedParentId: string | null = null
    let isOrphan = false

    if (parentSku) {
      if (batchParentSkus.has(parentSku)) {
        // Parent is in this batch — resolvedParentId will be filled by DB
        // We use a sentinel value so the RPC knows to look up the parent by SKU
        resolvedParentId = null  // RPC handles resolution
      } else if (dbParentIdBySku.has(parentSku)) {
        resolvedParentId = dbParentIdBySku.get(parentSku)!
      } else {
        isOrphan = true
        orphanCount++
      }
    }

    resolved.push({
      ...row,
      resolvedParentId,
      // Store the skuParent for the RPC to resolve if resolvedParentId is null
      // (the RPC will look it up from the already-inserted parent in the same batch)
      isVariant:        true,
      stockControlType: "tracked",
      errors: isOrphan
        ? [...row.errors, `SKU Padre "${parentSku}" no encontrado en el archivo ni en la base de datos.`]
        : row.errors,
    })
  }

  // Standalone
  for (const row of standalone) {
    resolved.push({
      ...row,
      resolvedParentId: null,
      isVariant:        false,
      stockControlType: "tracked",
    })
  }

  return { rows: resolved, orphanCount }
}
