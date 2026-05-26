/**
 * Hierarchy resolver.
 *
 * Resolves the Padre→Variante relationship using three strategies in cascade:
 *
 *   Strategy 1 — SKU Padre (explicit, backward compatible)
 *     Variant has `skuParent` set → look up parent by SKU in batch, then DB.
 *
 *   Strategy 2 — Producto Padre (explicit name reference)
 *     Variant has `nameParent` set → look up parent by name in batch, then DB.
 *
 *   Strategy 3 — Sequential grouping (implicit, professional default)
 *     Neither reference is set → assign to the nearest Padre row with a lower
 *     line number. This is how Shopify, Tienda Nube and WooCommerce work.
 *     Example: a Padre on line 2 automatically owns Variante rows on lines 3–8
 *     until the next Padre row appears.
 *
 * Output ordering: parents first → variants → standalone.
 * This guarantees correct INSERT order in the bulk upsert RPC
 * (parent must exist before its variants are inserted).
 *
 * Orphan policy:
 *   A Variante that cannot be linked to any parent (none found in batch or DB,
 *   and no Padre row precedes it in the file) is imported as a standalone product
 *   with a warning rather than being blocked.
 */

import { createClient } from "@/lib/supabase/client"
import type { ValidatedImportRow, ResolvedImportRow } from "@/lib/import/types"

export interface ResolveResult {
  rows:        ResolvedImportRow[]
  orphanCount: number
}

export async function resolveHierarchy(
  validRows: ValidatedImportRow[],
  userId: string,
): Promise<ResolveResult> {

  // ── Build batch-level parent lookup maps ────────────────────────────────────
  // Key: parent SKU (for strategy 1) or parent name (for strategy 2 & 3)
  // Value: index into validRows (to keep insertion order)
  const batchParentBySku  = new Map<string, ValidatedImportRow>()
  const batchParentByName = new Map<string, ValidatedImportRow>()

  for (const row of validRows) {
    if (row.rowType !== "Padre") continue
    if (row.sku)  batchParentBySku.set(row.sku, row)
    // Always index by name for strategy 2 & 3 (name is always present)
    batchParentByName.set(row.name.trim().toLowerCase(), row)
  }

  // ── Collect SKUs / names that need a DB lookup ──────────────────────────────
  // Only look up parents NOT already in this batch.
  const skusToQuery:  string[] = []
  const namesToQuery: string[] = []

  for (const row of validRows) {
    if (row.rowType !== "Variante") continue
    if (row.skuParent && !batchParentBySku.has(row.skuParent)) {
      skusToQuery.push(row.skuParent)
    }
    if (row.nameParent && !batchParentByName.has(row.nameParent.trim().toLowerCase())) {
      namesToQuery.push(row.nameParent)
    }
  }

  // ── DB lookup for out-of-batch parents ─────────────────────────────────────
  const dbParentIdBySku  = new Map<string, string>()
  const dbParentIdByName = new Map<string, string>()

  if (skusToQuery.length > 0 || namesToQuery.length > 0) {
    const supabase = createClient()

    if (skusToQuery.length > 0) {
      const { data } = await supabase
        .from("products")
        .select("id, sku")
        .eq("user_id", userId)
        .eq("is_variant", false)
        .in("sku", [...new Set(skusToQuery)])
      for (const p of data ?? []) {
        if (p.sku) dbParentIdBySku.set(p.sku, p.id)
      }
    }

    if (namesToQuery.length > 0) {
      const { data } = await supabase
        .from("products")
        .select("id, name")
        .eq("user_id", userId)
        .eq("is_variant", false)
        .in("name", [...new Set(namesToQuery)])
      for (const p of data ?? []) {
        if (p.name) dbParentIdByName.set(p.name.trim().toLowerCase(), p.id)
      }
    }
  }

  // ── Sequential grouping — build "nearest parent" map by line number ─────────
  // Walk rows in file order; track the most recent Padre seen.
  const sequentialParentByLine = new Map<number, ValidatedImportRow>()
  let currentSequentialParent: ValidatedImportRow | null = null

  const sorted = [...validRows].sort((a, b) => a.lineNumber - b.lineNumber)
  for (const row of sorted) {
    if (row.rowType === "Padre") {
      currentSequentialParent = row
    } else if (row.rowType === "Variante") {
      if (currentSequentialParent) {
        sequentialParentByLine.set(row.lineNumber, currentSequentialParent)
      }
    }
  }

  // ── Resolve each row ────────────────────────────────────────────────────────
  const parents:    ResolvedImportRow[] = []
  const variants:   ResolvedImportRow[] = []
  const standalone: ResolvedImportRow[] = []
  let orphanCount = 0

  for (const row of validRows) {
    if (row.rowType === "Padre") {
      parents.push({
        ...row,
        resolvedParentId:   null,
        resolvedParentName: null,
        isVariant:          false,
        stockControlType:   "variant_only",
      })
      continue
    }

    if (row.rowType !== "Variante") {
      standalone.push({
        ...row,
        resolvedParentId:   null,
        resolvedParentName: null,
        isVariant:          false,
        stockControlType:   "tracked",
      })
      continue
    }

    // ── Variant: resolve parent ───────────────────────────────────────────────
    let resolvedParentId:   string | null = null
    let resolvedParentName: string | null = null  // used when parent has no SKU

    // Strategy 1: explicit SKU Padre
    if (row.skuParent) {
      if (batchParentBySku.has(row.skuParent)) {
        const batchParent = batchParentBySku.get(row.skuParent)!
        if (batchParent.sku) {
          resolvedParentName = null
          // Parent in same batch — RPC resolves by sku_parent
        } else {
          resolvedParentName = batchParent.name
        }
      } else if (dbParentIdBySku.has(row.skuParent)) {
        resolvedParentId = dbParentIdBySku.get(row.skuParent)!
      }
      // If not found anywhere: fall through to next strategy
    }

    // Strategy 2: explicit Producto Padre (name)
    if (!resolvedParentId && !row.skuParent && row.nameParent) {
      const key = row.nameParent.trim().toLowerCase()
      if (batchParentByName.has(key)) {
        resolvedParentName = batchParentByName.get(key)!.name
      } else if (dbParentIdByName.has(key)) {
        resolvedParentId = dbParentIdByName.get(key)!
      }
    }

    // Strategy 3: sequential grouping
    let seqSkuParent: string | null = null
    if (!resolvedParentId && !resolvedParentName && !row.skuParent && !row.nameParent) {
      const seqParent = sequentialParentByLine.get(row.lineNumber)
      if (seqParent) {
        if (seqParent.sku) {
          seqSkuParent = seqParent.sku
        } else {
          resolvedParentName = seqParent.name
        }
      } else {
        // No parent found by any strategy — import as standalone with warning
        orphanCount++
        standalone.push({
          ...row,
          resolvedParentId:   null,
          resolvedParentName: null,
          isVariant:          false,
          stockControlType:   "tracked",
          warnings: [
            ...row.warnings,
            "No se encontró un producto Padre para esta variante — se importará como producto independiente.",
          ],
        })
        continue
      }
    }

    variants.push({
      ...row,
      skuParent:        seqSkuParent ?? row.skuParent,
      resolvedParentId,
      resolvedParentName,
      isVariant:        true,
      stockControlType: "tracked",
    })
  }

  // Parents first → variants → standalone (correct DB insert order)
  return {
    rows: [...parents, ...variants, ...standalone],
    orphanCount,
  }
}
