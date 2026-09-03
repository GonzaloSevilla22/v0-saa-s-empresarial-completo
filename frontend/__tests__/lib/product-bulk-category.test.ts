/**
 * productos-categorias-sku — troceo del lote (task 14.7): la selección se
 * trocea en requests de hasta 500 ids y los resultados se agregan, de forma
 * transparente para el usuario (D14: límite de transporte, no de producto).
 */

import { describe, it, expect, vi } from "vitest"
import { BULK_CATEGORY_CHUNK_SIZE, chunkIds, bulkRecategorizeInChunks } from "@/lib/product-bulk-category"

describe("chunkIds", () => {
  it("el tope es 500 y trocea en bloques de a lo sumo ese tamaño", () => {
    expect(BULK_CATEGORY_CHUNK_SIZE).toBe(500)
    const ids = Array.from({ length: 1200 }, (_, i) => `id-${i}`)
    const chunks = chunkIds(ids)
    expect(chunks.map((c) => c.length)).toEqual([500, 500, 200])
    expect(chunks.flat()).toEqual(ids)
  })

  it("una selección chica va en un solo bloque y la vacía en ninguno", () => {
    expect(chunkIds(["a", "b"])).toEqual([["a", "b"]])
    expect(chunkIds([])).toEqual([])
  })
})

describe("bulkRecategorizeInChunks", () => {
  it("llama al endpoint una vez por bloque y suma requested/updated", async () => {
    const ids = Array.from({ length: 1200 }, (_, i) => `id-${i}`)
    const send = vi.fn(async (chunk: string[], _categoryId: string) => ({ requested: chunk.length, updated: chunk.length - 1 }))

    const result = await bulkRecategorizeInChunks(ids, "cat-1", send)

    expect(send).toHaveBeenCalledTimes(3)
    expect(send.mock.calls[0][0]).toHaveLength(500)
    expect(send.mock.calls[2][0]).toHaveLength(200)
    expect(send.mock.calls[0][1]).toBe("cat-1")
    expect(result).toEqual({ requested: 1200, updated: 1197 })
  })

  it("deduplica ids antes de trocear", async () => {
    const send = vi.fn(async (chunk: string[], _categoryId: string) => ({ requested: chunk.length, updated: chunk.length }))
    const result = await bulkRecategorizeInChunks(["a", "a", "b"], "cat-1", send)
    expect(send).toHaveBeenCalledWith(["a", "b"], "cat-1")
    expect(result).toEqual({ requested: 2, updated: 2 })
  })
})
