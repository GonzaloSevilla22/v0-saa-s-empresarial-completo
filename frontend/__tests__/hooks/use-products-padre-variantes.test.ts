/**
 * productos-padre-variantes (task 8.4): `useRelabelProductUnit` (corregir la
 * unidad de la familia, con vista previa dry-run) y `useBulkAdjustPrices`
 * (precios en lote: troceo en 500, suma de dry-runs, avance parcial ante la
 * falla de un bloque, invalidación del listado).
 *
 * Los `Decimal` del backend viajan como STRING en el JSON: los hooks los parsean.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useRelabelProductUnit, useBulkAdjustPrices } from "@/hooks/data/use-products"
import { queryKeys } from "@/lib/query-keys"
import { PythonApiError } from "@/lib/api/python-api-error"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const invalidate = vi.spyOn(queryClient, "invalidateQueries")
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, invalidate }
}

const RELABEL_RAW = {
  changed: true,
  root_id: "root-1",
  unit_before: "u-un",
  unit_after: "u-kg",
  variants: 3,
  variants_with_own_unit: 1,
  products_with_stock: 2,
  movements: 14,
  conflict_unit: null,
}

describe("useRelabelProductUnit", () => {
  beforeEach(() => vi.clearAllMocks())

  it("dry-run: POST /products/{id}/relabel-unit con dry_run=true y mapea la respuesta a camelCase", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue(RELABEL_RAW)
    const { wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useRelabelProductUnit(), { wrapper })

    let out: Awaited<ReturnType<typeof result.current.relabel>> | undefined
    await act(async () => {
      out = await result.current.relabel({ productId: "prod-1", baseUnitId: "u-kg", dryRun: true })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/products/prod-1/relabel-unit", { base_unit_id: "u-kg", dry_run: true })
    expect(out).toEqual({
      changed: true, rootId: "root-1", unitBefore: "u-un", unitAfter: "u-kg",
      variants: 3, variantsWithOwnUnit: 1, productsWithStock: 2, movements: 14, conflictUnit: null,
    })
    // La vista previa no escribe: no hay nada que refrescar.
    expect(invalidate).not.toHaveBeenCalled()
  })

  it("aplicación (dryRun=false): manda dry_run=false e invalida el listado de productos", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue(RELABEL_RAW)
    const { wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useRelabelProductUnit(), { wrapper })

    await act(async () => {
      await result.current.relabel({ productId: "prod-1", baseUnitId: "u-kg", dryRun: false })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/products/prod-1/relabel-unit", { base_unit_id: "u-kg", dry_run: false })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.products.all() })
  })

  it("TRIANGULATE: un conflicto en dry-run llega en conflictUnit (no lanza); al aplicar, el 409 se propaga", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ...RELABEL_RAW, changed: false, conflict_unit: "u-g" })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useRelabelProductUnit(), { wrapper })

    let preview: Awaited<ReturnType<typeof result.current.relabel>> | undefined
    await act(async () => {
      preview = await result.current.relabel({ productId: "prod-1", baseUnitId: "u-kg", dryRun: true })
    })
    expect(preview?.conflictUnit).toBe("u-g")

    const conflict = new PythonApiError("hay líneas en g", 409, { code: "unit_relabel_conflict" })
    vi.mocked(pythonClient.post).mockRejectedValueOnce(conflict)
    await expect(
      act(async () => { await result.current.relabel({ productId: "prod-1", baseUnitId: "u-kg", dryRun: false }) }),
    ).rejects.toBe(conflict)
  })
})

function bulkRaw(over: Partial<Record<string, unknown>> = {}) {
  return {
    requested: 2, eligible: 2, changed: 2, unchanged: 0, skipped_parents: 0, clamped: 0,
    sample: [{ id: "p1", name: "Remera", price_before: "1000.00", price_after: "1100.00" }],
    ...over,
  }
}

const BASE = { mode: "percent" as const, direction: "increase" as const, value: 10 }

describe("useBulkAdjustPrices", () => {
  beforeEach(() => vi.clearAllMocks())

  it("PATCH /products/bulk-price con el payload del contrato; parsea los precios string a número", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValue(bulkRaw())
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useBulkAdjustPrices(), { wrapper })

    let out: Awaited<ReturnType<typeof result.current.adjust>> | undefined
    await act(async () => {
      out = await result.current.adjust({ ...BASE, productIds: ["p1", "p2"], dryRun: true })
    })

    expect(pythonClient.patch).toHaveBeenCalledWith("/products/bulk-price", {
      product_ids: ["p1", "p2"], mode: "percent", direction: "increase", value: 10, dry_run: true,
    })
    expect(out?.failure).toBeNull()
    expect(out?.result).toEqual({
      requested: 2, eligible: 2, changed: 2, unchanged: 0, skippedParents: 0, clamped: 0,
      sample: [{ id: "p1", name: "Remera", priceBefore: 1000, priceAfter: 1100 }],
    })
  })

  it("más de 500 ids: un request por bloque; la vista previa suma los contadores y toma la muestra del primero", async () => {
    vi.mocked(pythonClient.patch)
      .mockResolvedValueOnce(bulkRaw({ requested: 500, eligible: 500, changed: 400, unchanged: 100, skipped_parents: 2, clamped: 1 }))
      .mockResolvedValueOnce(bulkRaw({
        requested: 200, eligible: 190, changed: 150, unchanged: 40, skipped_parents: 3, clamped: 4,
        sample: [{ id: "otra", name: "Del segundo bloque", price_before: "1", price_after: "2" }],
      }))
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useBulkAdjustPrices(), { wrapper })
    const ids = Array.from({ length: 700 }, (_, i) => `id-${i}`)

    let out: Awaited<ReturnType<typeof result.current.adjust>> | undefined
    await act(async () => {
      out = await result.current.adjust({ ...BASE, productIds: ids, dryRun: true })
    })

    expect(pythonClient.patch).toHaveBeenCalledTimes(2)
    const sent = vi.mocked(pythonClient.patch).mock.calls.map((c) => (c[1] as { product_ids: string[] }).product_ids.length)
    expect(sent).toEqual([500, 200])
    expect(out?.result).toMatchObject({ requested: 700, eligible: 690, changed: 550, unchanged: 140, skippedParents: 5, clamped: 5 })
    expect(out?.result.sample.map((s) => s.id)).toEqual(["p1"]) // muestra del primer bloque
    expect(out?.appliedIds).toBe(700)
  })

  it("aplicar invalida el listado de productos; la vista previa no", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValue(bulkRaw())
    const { wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useBulkAdjustPrices(), { wrapper })

    await act(async () => { await result.current.adjust({ ...BASE, productIds: ["p1"], dryRun: true }) })
    expect(invalidate).not.toHaveBeenCalled()

    await act(async () => { await result.current.adjust({ ...BASE, productIds: ["p1"], dryRun: false }) })
    await waitFor(() => expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.products.all() }))
  })

  it("aplicar con un bloque que falla: devuelve el avance parcial (bloques aplicados) y el error, sin lanzar", async () => {
    const boom = new PythonApiError("Rol de cuenta insuficiente", 403, { code: "insufficient_role" })
    vi.mocked(pythonClient.patch)
      .mockResolvedValueOnce(bulkRaw({ requested: 500, eligible: 500, changed: 480, unchanged: 20 }))
      .mockRejectedValueOnce(boom)
    const { wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useBulkAdjustPrices(), { wrapper })
    const ids = Array.from({ length: 700 }, (_, i) => `id-${i}`)

    let out: Awaited<ReturnType<typeof result.current.adjust>> | undefined
    await act(async () => {
      out = await result.current.adjust({ ...BASE, productIds: ids, dryRun: false })
    })

    expect(out?.failure).toEqual({ index: 1, error: boom })
    expect(out?.appliedIds).toBe(500)
    expect(out?.totalIds).toBe(700)
    expect(out?.result.changed).toBe(480)
    // Hubo escritura parcial: el listado tiene que refrescarse igual.
    await waitFor(() => expect(invalidate).toHaveBeenCalledWith({ queryKey: queryKeys.products.all() }))
  })

  it("una vista previa que falla lanza el error (sin avance parcial que mostrar)", async () => {
    const boom = new PythonApiError("valor fuera de rango", 422, { code: "bulk_price_out_of_range" })
    vi.mocked(pythonClient.patch).mockRejectedValue(boom)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useBulkAdjustPrices(), { wrapper })

    await expect(
      act(async () => { await result.current.adjust({ ...BASE, productIds: ["p1"], dryRun: true }) }),
    ).rejects.toBe(boom)
  })
})
