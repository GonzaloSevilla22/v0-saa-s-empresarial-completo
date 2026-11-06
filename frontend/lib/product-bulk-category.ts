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

export interface ChunkRunFailure {
  /** Índice (base 0) del bloque que falló. */
  index: number
  error: unknown
}

export interface ChunkRunOutcome<R> {
  /** Resultado de cada bloque que SÍ se aplicó, en orden. */
  results: R[]
  /** El bloque que cortó el lote, o `null` si terminó completo. */
  failure: ChunkRunFailure | null
  /** Ids (distintos) de los bloques aplicados. */
  appliedIds: number
  /** Ids (distintos) del lote entero. */
  totalIds: number
}

/**
 * productos-padre-variantes (D10) — troceo genérico: deduplica, trocea en
 * bloques de `BULK_CATEGORY_CHUNK_SIZE` y manda un request por bloque, en
 * orden. Cada bloque es atómico en el servidor, el lote completo no: si un
 * bloque falla el lote se CORTA (los siguientes no se intentan) y el resultado
 * dice cuántos ids se habían aplicado, para que la pantalla informe un avance
 * parcial en vez de afirmar un éxito o un fracaso total. Nunca lanza.
 */
export async function runInChunks<R>(
  ids: readonly string[],
  send: (chunk: string[], index: number) => Promise<R>,
): Promise<ChunkRunOutcome<R>> {
  const unique = [...new Set(ids)]
  const results: R[] = []
  let appliedIds = 0
  const chunks = chunkIds(unique)
  for (let index = 0; index < chunks.length; index += 1) {
    try {
      results.push(await send(chunks[index], index))
    } catch (error: unknown) {
      return { results, failure: { index, error }, appliedIds, totalIds: unique.length }
    }
    appliedIds += chunks[index].length
  }
  return { results, failure: null, appliedIds, totalIds: unique.length }
}

export async function bulkRecategorizeInChunks(
  ids: readonly string[],
  categoryId: string,
  send: (chunk: string[], categoryId: string) => Promise<BulkCategoryResult>,
): Promise<BulkCategoryResult> {
  const outcome = await runInChunks(ids, (chunk) => send(chunk, categoryId))
  // La recategorización conserva su contrato: el primer error se propaga.
  if (outcome.failure) throw outcome.failure.error
  return outcome.results.reduce<BulkCategoryResult>(
    (total, res) => ({ requested: total.requested + res.requested, updated: total.updated + res.updated }),
    { requested: 0, updated: 0 },
  )
}
