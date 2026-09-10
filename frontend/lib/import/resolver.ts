/**
 * Hierarchy resolver.
 *
 * Resolves the Padre→Variante relationship using three strategies in cascade:
 *
 *   Strategy 1 — SKU Padre (explicit, backward compatible)
 *     Variant has `skuParent` set → travels to the server as `sku_parent`.
 *
 *   Strategy 2 — Producto Padre (explicit name reference)
 *     Variant has `nameParent` set → travels to the server as `parent_name`.
 *
 *   Strategy 3 — Sequential grouping (implicit, professional default)
 *     Neither reference is set → assign to the nearest Padre row with a lower
 *     line number. This is how Shopify, Tienda Nube and WooCommerce work.
 *
 * Output ordering: parents first → variants → standalone.
 * This guarantees correct INSERT order in the bulk upsert RPC — the server
 * resolves BOTH the "same batch" and the "pre-existing in the account" case
 * with the SAME query (`SELECT ... FROM products WHERE account_id = ... AND
 * sku/name = ...`): by the time a variant row is processed, a parent earlier
 * in the same array is already committed within the same RPC call.
 *
 * importador-productos-fastapi (D9): este resolver YA NO consulta la base
 * (se retiraron los dos `createClient()` + `.from("products")` que existían
 * antes, alcanzados por `user_id`). Es redundante — `rpc_bulk_upsert_products`
 * YA resuelve `sku_parent`/`parent_name` contra `products` filtrando por
 * `account_id` — y tenía peor alcance (el cliente buscaba por usuario, no
 * por cuenta: un padre creado por OTRO miembro de la misma cuenta no
 * resolvía). Una referencia EXPLÍCITA que no resuelve EN EL MISMO ARCHIVO
 * viaja tal cual al servidor; si tampoco resuelve ahí, es error de fila —
 * nunca un producto independiente creado en silencio (BREAKING de
 * comportamiento declarado: antes, un `Producto Padre` sin match en ningún
 * lado se importaba como independiente sin avisar; ahora es un error visible
 * en la vista previa del servidor).
 *
 * Corrección post-review: retirar el round-trip a Supabase (D9) NO incluía
 * retirar la resolución IN-BATCH por nombre — es una operación pura sobre
 * el array ya parseado, no toca la base. El servidor resuelve `parent_name`
 * con un lookup EXACTO (`WHERE name = ...`, sin `lower()`), así que una
 * Variante cuyo `Producto Padre` difiere sólo en mayúsculas/minúsculas de
 * la fila Padre del MISMO archivo se resuelve ACÁ, case-insensitive, antes
 * de viajar — igual que hacía el resolver de C-21. Si no hay match en el
 * archivo, la referencia sigue viajando tal cual para que el servidor la
 * resuelva contra el resto de la cuenta (o falle como error de fila).
 *
 * Orphan policy (sin cambios): una Variante SIN NINGUNA referencia que no
 * tiene un Padre precediéndola en el archivo se importa como standalone con
 * un aviso — es la única rama que sigue siendo un default, porque la
 * AUSENCIA de referencia es una intención inequívoca (agrupación por
 * cercanía), no un error de tipeo.
 */

import type { ValidatedImportRow, ResolvedImportRow } from "@/lib/import/types"

export interface ResolveResult {
  rows:        ResolvedImportRow[]
  orphanCount: number
}

export function resolveHierarchy(validRows: ValidatedImportRow[]): ResolveResult {
  // ── Sequential grouping — build "nearest parent" map by line number ─────────
  // Walk rows in file order; track the most recent Padre seen.
  const sequentialParentByLine = new Map<number, ValidatedImportRow>()
  let currentSequentialParent: ValidatedImportRow | null = null

  const sorted = [...validRows].sort((a, b) => a.lineNumber - b.lineNumber)
  for (const row of sorted) {
    if (row.rowType === "Padre") {
      currentSequentialParent = row
    } else if (row.rowType === "Variante" && currentSequentialParent) {
      sequentialParentByLine.set(row.lineNumber, currentSequentialParent)
    }
  }

  // ── Strategy 2 — batch-level lookup by name, CASE-INSENSITIVE ───────────────
  // Única estrategia explícita que necesita mirar OTRAS filas del archivo:
  // Strategy 1 (sku_parent) viaja tal cual porque el servidor YA resuelve el
  // SKU con `lower()` de los dos lados (case-insensitive de por sí). El
  // nombre, en cambio, se resuelve EXACTO en el servidor — así que si no se
  // normaliza acá, una diferencia de capitalización dentro del MISMO archivo
  // pasa de "resuelve" a "error de fila" (y, con D3 todo-o-nada, a "archivo
  // entero rechazado").
  const batchParentByName = new Map<string, ValidatedImportRow>()
  for (const row of validRows) {
    if (row.rowType === "Padre") {
      batchParentByName.set(row.name.trim().toLowerCase(), row)
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

    // ── Variante: Strategy 1 — referencia explícita por SKU ───────────────────
    // Viaja tal cual como sku_parent. El servidor la resuelve DENTRO del
    // lote (padre ya insertado antes en el mismo array) o CONTRA la cuenta;
    // si no resuelve en ninguna de las dos, es error de fila (D9).
    if (row.skuParent) {
      variants.push({
        ...row,
        resolvedParentId:   null,
        resolvedParentName: null,
        isVariant:          true,
        stockControlType:   "tracked",
      })
      continue
    }

    // ── Strategy 2 — referencia explícita por nombre de Producto Padre ────────
    // Resolución IN-BATCH case-insensitive (ver comentario de la Map más
    // arriba). Si el Padre del archivo tiene SKU, se emite `skuParent`
    // (el servidor lo resuelve con `lower()`, sin ambigüedad de mayúsculas);
    // si no tiene SKU, se emite el `name` CANÓNICO del Padre (la capitalización
    // tal como aparece en su fila), que es lo que el lookup exacto del
    // servidor necesita. Sin match en el archivo, la referencia viaja tal
    // cual — el servidor la resuelve contra el resto de la cuenta o falla
    // como error de fila (D9).
    if (row.nameParent) {
      const batchParent = batchParentByName.get(row.nameParent.trim().toLowerCase())
      variants.push({
        ...row,
        skuParent:          batchParent?.sku ? batchParent.sku : row.skuParent,
        resolvedParentId:   null,
        resolvedParentName: batchParent ? (batchParent.sku ? null : batchParent.name) : row.nameParent,
        isVariant:          true,
        stockControlType:   "tracked",
      })
      continue
    }

    // ── Strategy 3 — agrupación secuencial (sin ninguna referencia) ───────────
    const seqParent = sequentialParentByLine.get(row.lineNumber)
    if (seqParent) {
      variants.push({
        ...row,
        skuParent:          seqParent.sku ? seqParent.sku : row.skuParent,
        resolvedParentName: seqParent.sku ? null : seqParent.name,
        resolvedParentId:   null,
        isVariant:          true,
        stockControlType:   "tracked",
      })
    } else {
      // Sin referencia y sin Padre que la preceda: sigue siendo el ÚNICO
      // caso donde el fallback es un standalone con aviso, no un error —
      // la ausencia de referencia es una intención inequívoca.
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
    }
  }

  // Parents first → variants → standalone (correct DB insert order)
  return {
    rows: [...parents, ...variants, ...standalone],
    orphanCount,
  }
}
