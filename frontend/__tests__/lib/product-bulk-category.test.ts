/**
 * productos-categorias-sku — troceo del lote (task 14.7): la selección se
 * trocea en requests de hasta 500 ids y los resultados se agregan, de forma
 * transparente para el usuario (D14: límite de transporte, no de producto).
 */

import { describe, it, expect, vi } from "vitest"
import { BULK_CATEGORY_CHUNK_SIZE, chunkIds, runInChunks, bulkRecategorizeInChunks } from "@/lib/product-bulk-category"

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

  it("si un bloque falla, el error original se propaga (sin cambio de comportamiento)", async () => {
    const boom = new Error("rol insuficiente")
    const send = vi.fn(async (): Promise<{ requested: number; updated: number }> => { throw boom })
    await expect(bulkRecategorizeInChunks(["a"], "cat-1", send)).rejects.toBe(boom)
  })
})

// productos-padre-variantes (D10, task 8.3) — el troceo se generaliza: el lote
// de precios lo reutiliza y, a diferencia de la categoría, informa el avance
// cuando un bloque falla a mitad de camino.
describe("runInChunks", () => {
  it("deduplica, trocea en bloques de 500 y devuelve un resultado por bloque", async () => {
    const ids = [...Array.from({ length: 1200 }, (_, i) => `id-${i}`), "id-0"]
    const send = vi.fn(async (chunk: string[], index: number) => ({ index, n: chunk.length }))

    const out = await runInChunks(ids, send)

    expect(send).toHaveBeenCalledTimes(3)
    expect(out.results).toEqual([{ index: 0, n: 500 }, { index: 1, n: 500 }, { index: 2, n: 200 }])
    expect(out.failure).toBeNull()
    expect(out.appliedIds).toBe(1200)
    expect(out.totalIds).toBe(1200)
  })

  it("un bloque que falla corta el lote y informa cuántos ids se habían procesado", async () => {
    const ids = Array.from({ length: 1200 }, (_, i) => `id-${i}`)
    const boom = new Error("falló el bloque 2")
    const send = vi.fn(async (chunk: string[], index: number) => {
      if (index === 1) throw boom
      return chunk.length
    })

    const out = await runInChunks(ids, send)

    expect(send).toHaveBeenCalledTimes(2) // el 3er bloque no se intenta
    expect(out.results).toEqual([500])
    expect(out.failure).toEqual({ index: 1, error: boom })
    expect(out.appliedIds).toBe(500)
    expect(out.totalIds).toBe(1200)
  })

  it("una selección vacía no llama a nadie", async () => {
    const send = vi.fn()
    const out = await runInChunks([], send)
    expect(send).not.toHaveBeenCalled()
    expect(out).toEqual({ results: [], failure: null, appliedIds: 0, totalIds: 0 })
  })
})
