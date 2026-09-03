/**
 * productos-categorias-sku (D14, task 14.7) — troceo de la recategorización
 * en lote.
 *
 * El endpoint acepta hasta 500 ids por request (límite de TRANSPORTE, no de
 * producto: una cuenta puede tener 2.951 productos en "Otros"). El cliente
 * trocea la selección, manda un request por bloque y agrega los resultados
 * — invisible para el usuario.
 */

export const BULK_CATEGORY_CHUNK_SIZE = 500

export interface BulkCategoryResult {
  /** Ids distintos solicitados. */
  requested: number
  /** Filas realmente cambiadas (incluye variantes expandidas desde un padre). */
  updated: number
}

export function chunkIds(ids: readonly string[], size: number = BULK_CATEGORY_CHUNK_SIZE): string[][] {
  const chunks: string[][] = []
  for (let i = 0; i < ids.length; i += size) chunks.push(ids.slice(i, i + size))
  return chunks
}

export async function bulkRecategorizeInChunks(
  ids: readonly string[],
  categoryId: string,
  send: (chunk: string[], categoryId: string) => Promise<BulkCategoryResult>,
): Promise<BulkCategoryResult> {
  const unique = [...new Set(ids)]
  const total: BulkCategoryResult = { requested: 0, updated: 0 }
  for (const chunk of chunkIds(unique)) {
    const res = await send(chunk, categoryId)
    total.requested += res.requested
    total.updated += res.updated
  }
  return total
}
