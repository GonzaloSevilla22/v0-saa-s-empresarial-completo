/**
 * productos-categorias-sku — useProductCategories (task 10.1 RED → 10.2 GREEN).
 *
 * Espejo de use-products.test.ts: QueryClientProvider real + pythonClient
 * mockeado. Cubre listado (activas / con inactivas), mapeo snake→camel,
 * mutaciones (crear devuelve la categoría MAPEADA — el alta inline del
 * selector necesita su id), tri-estado del PATCH (sólo viajan las claves
 * informadas) e invalidación de la query tras cada mutación.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import { queryKeys } from "@/lib/query-keys"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    patch:  vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const ROWS = [
  { id: "cat-ropa",  account_id: "acc-1", name: "Ropa",  is_active: true,  sort_order: 2, created_at: "2026-09-03T00:00:00Z" },
  { id: "cat-otros", account_id: "acc-1", name: "Otros", is_active: true,  sort_order: 7, created_at: "2026-09-03T00:00:00Z" },
  { id: "cat-salud", account_id: "acc-1", name: "Salud", is_active: false, sort_order: 5, created_at: "2026-09-03T00:00:00Z" },
]

function makeWrapper(client: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return React.createElement(QueryClientProvider, { client }, children)
  }
}

describe("useProductCategories", () => {
  let client: QueryClient

  beforeEach(() => {
    vi.clearAllMocks()
    client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    vi.mocked(pythonClient.get).mockResolvedValue(ROWS.filter((r) => r.is_active))
  })

  it("lista las activas por defecto y mapea snake_case → camelCase", async () => {
    const { result } = renderHook(() => useProductCategories(), { wrapper: makeWrapper(client) })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/product-categories")
    expect(result.current.productCategories).toEqual([
      { id: "cat-ropa",  accountId: "acc-1", name: "Ropa",  isActive: true, sortOrder: 2, createdAt: "2026-09-03T00:00:00Z" },
      { id: "cat-otros", accountId: "acc-1", name: "Otros", isActive: true, sortOrder: 7, createdAt: "2026-09-03T00:00:00Z" },
    ])
  })

  it("includeInactive=true pide ?include_inactive=true y usa otra query key", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(ROWS)
    const { result } = renderHook(() => useProductCategories(true), { wrapper: makeWrapper(client) })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/product-categories?include_inactive=true")
    expect(result.current.productCategories).toHaveLength(3)
    expect(client.getQueryData(queryKeys.productCategories.lists())).toBeDefined()
    expect(client.getQueryData(queryKeys.productCategories.active())).toBeUndefined()
  })

  it("crear envía {name, sort_order}, devuelve la categoría MAPEADA e invalida el catálogo", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue({
      id: "cat-new", account_id: "acc-1", name: "Ferretería", is_active: true, sort_order: 8, created_at: "2026-09-03T00:00:00Z",
    })
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useProductCategories(), { wrapper: makeWrapper(client) })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    let created: unknown
    await act(async () => {
      created = await result.current.createProductCategory({ name: "Ferretería" })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/product-categories", { name: "Ferretería", sort_order: null })
    expect(created).toEqual({
      id: "cat-new", accountId: "acc-1", name: "Ferretería", isActive: true, sortOrder: 8, createdAt: "2026-09-03T00:00:00Z",
    })
    expect(spy).toHaveBeenCalledWith({ queryKey: queryKeys.productCategories.all() })
  })

  it("actualizar sólo manda las claves informadas (renombrar no toca sort_order ni is_active)", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValue({ ...ROWS[0], name: "Indumentaria" })
    const { result } = renderHook(() => useProductCategories(), { wrapper: makeWrapper(client) })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.updateProductCategory({ id: "cat-ropa", name: "Indumentaria" })
    })
    expect(pythonClient.patch).toHaveBeenCalledWith("/product-categories/cat-ropa", { name: "Indumentaria" })

    await act(async () => {
      await result.current.updateProductCategory({ id: "cat-ropa", sortOrder: 9 })
    })
    expect(pythonClient.patch).toHaveBeenCalledWith("/product-categories/cat-ropa", { sort_order: 9 })

    await act(async () => {
      await result.current.updateProductCategory({ id: "cat-salud", isActive: true })
    })
    expect(pythonClient.patch).toHaveBeenCalledWith("/product-categories/cat-salud", { is_active: true })
  })

  it("desactivar pega a /deactivate e invalida; eliminar hace DELETE e invalida", async () => {
    vi.mocked(pythonClient.patch).mockResolvedValue({ ...ROWS[0], is_active: false })
    vi.mocked(pythonClient.delete).mockResolvedValue(undefined)
    const spy = vi.spyOn(client, "invalidateQueries")
    const { result } = renderHook(() => useProductCategories(true), { wrapper: makeWrapper(client) })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deactivateProductCategory("cat-ropa")
    })
    expect(pythonClient.patch).toHaveBeenCalledWith("/product-categories/cat-ropa/deactivate", {})

    await act(async () => {
      await result.current.deleteProductCategory("cat-salud")
    })
    expect(pythonClient.delete).toHaveBeenCalledWith("/product-categories/cat-salud")
    expect(spy.mock.calls.filter((c) => JSON.stringify(c[0]) === JSON.stringify({ queryKey: queryKeys.productCategories.all() }))).toHaveLength(2)
  })
})
